import CoreBluetooth
import Flutter
import Foundation

/// BLE service/characteristic UUIDs. Must match the Android peripheral
/// (`BlePeripheral.kt`) and the Dart protocol.
enum SimBridgeUUID {
    static let service = CBUUID(string: "5ABF5C3C-2BF1-4B1C-9E8E-5D153F835BD5")
    static let psm = CBUUID(string: "6C0D1EB1-67F4-4181-9752-9CC90D6EFF88")
    static let rx = CBUUID(string: "214E1CD9-F397-4A0F-BB6C-ED1D8C7A38A5")
    static let tx = CBUUID(string: "7BA52139-0888-4234-A49D-0271E0F2A647")
    static let wake = CBUUID(string: "9A3F1C52-7E0B-4D8A-B1E6-2C5D4F7A8E31")
}

/// BLE central side of the Sim Bridge link: discovery, L2CAP (or GATT
/// fallback), endless reconnect. A transport only — framing, handshake
/// and records live in Dart (`lib/src/link/`), so this class only moves
/// bytes between CoreBluetooth and the `com.simbridge/ble` channel.
///
/// Port of the transport mechanics of Tether's `TetherLink.swift`
/// (TetherCore), minus its handshake/session (Dart's job here).
final class BleCentral: NSObject {
    /// Bytes received on the open pipe.
    var onBytes: ((Data) -> Void)?
    /// The pipe ended (remote close / link loss).
    var onClosed: (() -> Void)?
    /// The peer started a new session on the same pipe; `bytes` is its first record.
    var onPeerRestart: ((Data) -> Void)?
    var onConnected: ((String) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var log: (String) -> Void = { NSLog("[ble] %@", $0) }

    private let queue = DispatchQueue(label: "com.simbridge.ble-central", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var transport = "none"
    private var outBuffer = Data()
    private var settingUp = false
    private var l2capTimer: DispatchWorkItem?
    private var retryItem: DispatchWorkItem?
    private var connectWatchdog: DispatchWorkItem?
    private var connectedThisAttempt = false
    private var cancelledByUs: UUID?
    private var failures: [Date] = []
    /// A transport was open before: the next bytes start a new session.
    private var restartPending = false
    /// The peripheral identifier Dart paired with (from the QR code flow).
    private var knownPeripheralID: UUID?

    var isConnected: Bool { transport != "none" && peripheral?.state == .connected }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.simbridge.ble-central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
    }

    // MARK: - entry points (called from the plugin, on the platform thread)

    /// Starts scanning for the Android peripheral (or reconnects to the known one).
    func start(peripheralID: UUID?) {
        queue.async {
            self.knownPeripheralID = peripheralID ?? self.knownPeripheralID
            self.startIfReady()
        }
    }

    /// Connects to a peripheral by identifier, or scans when `address` is empty.
    func connect(address: String) {
        queue.async {
            if let id = UUID(uuidString: address) {
                self.knownPeripheralID = id
                if let p = self.central.retrievePeripherals(withIdentifiers: [id]).first {
                    self.connect(p)
                    return
                }
            }
            self.startIfReady()
        }
    }

    func disconnect() {
        queue.async {
            self.retryItem?.cancel(); self.retryItem = nil
            if let p = self.peripheral {
                if p.state == .connected { self.cancelledByUs = p.identifier }
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.resetTransport()
        }
    }

    func write(_ bytes: Data) {
        queue.async {
            self.outBuffer.append(bytes)
            self.flush()
        }
    }

    // MARK: - internals

    private func startIfReady() {
        guard central.state == .poweredOn else { return }
        guard peripheral?.state != .connected && peripheral?.state != .connecting else { return }
        if let id = knownPeripheralID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        log("scanning for the Android phone")
        central.scanForPeripherals(withServices: [SimBridgeUUID.service], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        if p.state != .connected { connectedThisAttempt = false }
        connectWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let cur = self.peripheral, cur.state == .connecting, !self.settingUp else { return }
            self.log("connect still pending after 10 s: renewing")
            self.central.cancelPeripheralConnection(cur)
            self.startIfReady()
        }
        connectWatchdog = w
        queue.asyncAfter(deadline: .now() + 10, execute: w)
        // Never times out: iOS keeps it pending until the Android phone is in range, also while suspended.
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: false])
    }

    private func disconnectPeripheral(reason: String) {
        resetTransport()
        log("disconnect: \(reason)")
        if let p = peripheral {
            if p.state == .connected { cancelledByUs = p.identifier }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
    }

    /// Ends the transport (channel, buffers, timers) but not the Bluetooth connection.
    /// Dart is told the pipe ended, so its connection closes and the next session starts fresh.
    private func resetTransport() {
        let hadTransport = transport != "none"
        l2capTimer?.cancel(); l2capTimer = nil
        if let ch = channel {
            ch.inputStream?.close()
            ch.outputStream?.close()
        }
        channel = nil
        outBuffer = Data()
        transport = "none"
        settingUp = false
        if hadTransport { onClosed?() }
    }

    private func failAndRetry(_ reason: String) {
        log("link failed: \(reason)")
        // The transport ended but the Bluetooth connection is still up (the Android phone closed the channel,
        // a stalled stream): start a new transport on it. Cancelling and connecting again does not work then:
        // iOS does not complete a new connect while an LE link still exists, and that link stays up for tens
        // of seconds. Twice in a row at most.
        if let p = peripheral, p.state == .connected, restarts < 2, central.state == .poweredOn {
            restarts += 1
            resetTransport()
            restartPending = true
            log("restarting the transport on the open connection (\(reason))")
            settingUp = true
            p.delegate = self
            armSetupWatchdog()
            p.discoverServices([SimBridgeUUID.service])
            return
        }
        restarts = 0
        disconnectPeripheral(reason: reason)
        reconnectSoon()
    }

    private var restarts = 0

    private func reconnectSoon() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if failures.count <= 3 {
            if let id = knownPeripheralID, central.state == .poweredOn,
               let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                log("reconnecting at once")
                connect(p)
            }
            scheduleRetry(after: 1) // also scans, in case the Android phone's identifier changed
        } else {
            // Backing off: no pending connect, but a scan, which iOS keeps running while suspended and
            // which wakes us when the Android phone advertises.
            if central.state == .poweredOn { central.scanForPeripherals(withServices: [SimBridgeUUID.service], options: nil) }
            scheduleRetry(after: Double(min(30, 2 * failures.count)))
        }
    }

    private var setupWatchdog: DispatchWorkItem?
    private func armSetupWatchdog() {
        setupWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected, self.peripheral?.state == .connected else { return }
            self.failAndRetry("setup timed out")
        }
        setupWatchdog = item
        queue.asyncAfter(deadline: .now() + 12, execute: item)
    }

    private func scheduleRetry(after seconds: Double) {
        retryItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.retryItem = nil; self?.startIfReady() }
        retryItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func openTransport(_ name: String) {
        transport = name
        // restartPending stays set until the first bytes arrive (received() clears it): those bytes
        // are the first record of a new session on the same pipe.
        restarts = 0
        retryItem?.cancel(); retryItem = nil
        setupWatchdog?.cancel(); setupWatchdog = nil
        failures.removeAll()
        log("transport up over \(name)")
        if let id = peripheral?.identifier.uuidString { onConnected?(id) }
    }

    private func flush() {
        if let ch = channel {
            guard let out = ch.outputStream else { return }
            while !outBuffer.isEmpty && out.hasSpaceAvailable {
                let n = outBuffer.withUnsafeBytes { out.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: min($0.count, 2048)) }
                if n <= 0 { break }
                outBuffer.removeFirst(n)
            }
        } else if let p = peripheral, let rx = rxChar {
            let chunk = max(20, p.maximumWriteValueLength(for: .withoutResponse))
            while !outBuffer.isEmpty && p.canSendWriteWithoutResponse {
                let n = min(chunk, outBuffer.count)
                p.writeValue(outBuffer.prefix(n), for: rx, type: .withoutResponse)
                outBuffer.removeFirst(n)
            }
        }
    }

    private func received(_ data: Data) {
        if restartPending {
            restartPending = false
            onPeerRestart?(data)
            return
        }
        onBytes?(data)
    }
}

extension BleCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startIfReady()
        case .unauthorized: log("bluetooth unauthorized")
        default:
            disconnectPeripheral(reason: "bluetooth \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            log("restored peripheral \(p.identifier) state \(p.state.rawValue)")
            peripheral = p
            p.delegate = self
            connectedThisAttempt = p.state == .connected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let cur = peripheral {
            if cur.state == .connected || cur.identifier == p.identifier && cur.state == .connecting { return }
            // The pending connect targets a stale identifier (Android phone Bluetooth reset / new address): switch.
            if cur.state == .connecting { central.cancelPeripheralConnection(cur) }
        }
        log("discovered \(p.identifier) rssi \(RSSI)")
        central.stopScan()
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectWatchdog?.cancel(); connectWatchdog = nil
        connectedThisAttempt = true
        log("connected \(p.identifier)")
        cancelledByUs = nil
        if settingUp { return }
        settingUp = true
        armSetupWatchdog()
        p.discoverServices([SimBridgeUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        failAndRetry("connect failed: \(error.map { "\($0)" } ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // The disconnect we caused ourselves (failAndRetry already reconnected): not a second failure.
        if cancelledByUs == p.identifier { cancelledByUs = nil; log("disconnected (by us)"); return }
        // A connect that never connected and ends without an error was cancelled by us: not a failure.
        if error == nil && !connectedThisAttempt { log("pending connect cancelled"); return }
        guard p == peripheral || peripheral == nil else { return }
        log("disconnected: \(error.map { "\($0)" } ?? "-")")
        disconnectPeripheral(reason: "peripheral disconnected")
        onDisconnected?(p.identifier.uuidString)
        reconnectSoon()
    }
}

extension BleCentral: CBPeripheralDelegate {
    /// The Android phone changed its GATT database (its service restarted): if we were still setting up, look again.
    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == SimBridgeUUID.service }) else { return }
        log("Android phone services changed")
        if settingUp && channel == nil && transport == "none" { p.discoverServices([SimBridgeUUID.service]) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SimBridgeUUID.service }) else {
            failAndRetry("service not found"); return
        }
        p.discoverCharacteristics([SimBridgeUUID.psm, SimBridgeUUID.rx, SimBridgeUUID.tx, SimBridgeUUID.wake], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid {
            // Nothing here needs link encryption: the app's own pairing secures the link, never a Bluetooth bond.
            case SimBridgeUUID.psm: p.readValue(for: c)
            case SimBridgeUUID.rx: rxChar = c
            case SimBridgeUUID.tx: txChar = c
            case SimBridgeUUID.wake: p.setNotifyValue(true, for: c) // notifications wake us when suspended
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == SimBridgeUUID.psm {
            guard error == nil, let v = c.value, v.count >= 2 else {
                // No L2CAP without the PSM, but the link does not need it: an Android phone build that still asks
                // for encryption, a broken bond left by Bluetooth tethering, or a GATT connection over the classic
                // link all still work over the GATT transport.
                startGattFallback("PSM read failed: \(error?.localizedDescription ?? "empty")")
                if channel == nil, transport == "none", txChar == nil || rxChar == nil {
                    failAndRetry("PSM read failed: \(error?.localizedDescription ?? "empty")")
                }
                return
            }
            let psm = CBL2CAPPSM(UInt16(v[v.startIndex]) | UInt16(v[v.startIndex + 1]) << 8)
            log("opening L2CAP psm \(psm)")
            p.openL2CAPChannel(psm)
            let fallback = DispatchWorkItem { [weak self] in self?.startGattFallback("L2CAP timeout") }
            l2capTimer = fallback
            queue.asyncAfter(deadline: .now() + 6, execute: fallback)
        } else if c.uuid == SimBridgeUUID.tx, let v = c.value {
            received(v)
        } else if c.uuid == SimBridgeUUID.wake {
            // Nothing to do: being woken up is the point. Pending L2CAP bytes are delivered next.
        }
    }

    func peripheral(_ p: CBPeripheral, didOpen ch: CBL2CAPChannel?, error: Error?) {
        l2capTimer?.cancel(); l2capTimer = nil
        if channel != nil || transport != "none" {
            // Late or duplicate channel (e.g. GATT fallback already running): never restart a live transport.
            ch?.inputStream?.close(); ch?.outputStream?.close()
            return
        }
        guard let ch, error == nil else {
            startGattFallback("L2CAP open failed: \(error?.localizedDescription ?? "?")"); return
        }
        guard let input = ch.inputStream, let output = ch.outputStream else {
            startGattFallback("L2CAP without streams"); return
        }
        channel = ch
        input.delegate = self
        output.delegate = self
        CFReadStreamSetDispatchQueue(input as CFReadStream, queue)
        CFWriteStreamSetDispatchQueue(output as CFWriteStream, queue)
        input.open()
        output.open()
        openTransport("l2cap")
    }

    private func startGattFallback(_ why: String) {
        guard channel == nil, transport == "none", let p = peripheral, let tx = txChar, rxChar != nil else { return }
        log("GATT fallback: \(why)")
        p.setNotifyValue(true, for: tx)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if c.uuid == SimBridgeUUID.tx, c.isNotifying, channel == nil, transport == "none" { openTransport("gatt") }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { flush() }
}

extension BleCentral: StreamDelegate {
    func stream(_ s: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            guard let input = s as? InputStream else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                received(Data(buf[0..<n]))
            }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            // Only the current channel's streams count (both of them report the end; a closed channel's late events
            // must not end the transport that replaced it).
            guard let ch = channel, s === (ch.inputStream as Stream?) || s === (ch.outputStream as Stream?) else { return }
            failAndRetry("L2CAP stream ended")
        default:
            break
        }
    }
}
