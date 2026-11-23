package com.simbridge.sim_bridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * BLE peripheral: advertises the Sim Bridge service, serves the PSM
 * characteristic, accepts L2CAP channels, and offers the GATT fallback
 * pipe. Bytes flow to the Dart side through the callbacks; the plugin
 * turns them into `com.simbridge/ble/events` events.
 *
 * Port of Tether's `link/BlePeripheral.kt` + `link/Transport.kt`
 * (Transport interface inlined here, since Dart owns the link layer).
 */
@SuppressLint("MissingPermission")
class BlePeripheral(private val ctx: Context) {
    companion object {
        const val TAG = "SimBridge"
        val SERVICE: UUID = UUID.fromString("5ABF5C3C-2BF1-4B1C-9E8E-5D153F835BD5")
        val PSM_CHAR: UUID = UUID.fromString("6C0D1EB1-67F4-4181-9752-9CC90D6EFF88")
        val RX_CHAR: UUID = UUID.fromString("214E1CD9-F397-4A0F-BB6C-ED1D8C7A38A5")
        val TX_CHAR: UUID = UUID.fromString("7BA52139-0888-4234-A49D-0271E0F2A647")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Notify-only "wake" characteristic: a notification wakes a suspended iOS app reliably. */
        val WAKE_CHAR: UUID = UUID.fromString("9A3F1C52-7E0B-4D8A-B1E6-2C5D4F7A8E31")

        /** Link pulse length: how long the link stays up while paired without a session. */
        const val PULSE_UP_MS = 3_000L
    }

    /** Bytes received on any pipe. */
    var onBytes: ((address: String, bytes: ByteArray) -> Unit)? = null

    /** A pipe ended (remote close / link loss). */
    var onClosed: ((address: String) -> Unit)? = null

    /** The central started a new session on the same GATT connection; `first` is its first record. */
    var onPeerRestart: ((address: String, first: ByteArray) -> Unit)? = null
    var onMtuChanged: ((address: String, mtu: Int) -> Unit)? = null
    var onConnected: ((address: String) -> Unit)? = null
    var onDisconnected: ((address: String) -> Unit)? = null

    private val manager = ctx.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = manager.adapter
    private var server: BluetoothGattServer? = null
    private var l2cap: BluetoothServerSocket? = null
    private var advSet: AdvertisingSet? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private val gattPipes = ConcurrentHashMap<String, GattTransport>()
    private val l2capPipes = ConcurrentHashMap<String, L2capTransport>()
    private var wakeChar: BluetoothGattCharacteristic? = null
    private val wakeSubscribers = ConcurrentHashMap.newKeySet<String>()
    private val devices = ConcurrentHashMap<String, BluetoothDevice>()
    private val mtus = ConcurrentHashMap<String, Int>()

    /** Last connection parameters per link, for diagnostics. */
    val linkParams = ConcurrentHashMap<String, String>()
    @Volatile var psm = 0; private set
    @Volatile var running = false; private set
    @Volatile var advertising = false; private set

    val enabled get() = adapter?.isEnabled == true

    @Synchronized fun start() {
        if (running || !enabled) return
        running = true
        try {
            startL2cap()
            startGatt()
            startAdvertising()
            Log.i(TAG, "peripheral up, psm=$psm")
        } catch (t: Throwable) {
            Log.e(TAG, "peripheral start failed", t)
            stop()
        }
    }

    @Synchronized fun stop() {
        running = false
        advertising = false
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertisingSet(advCallback) }
        startPending = false
        advSet = null
        runCatching { l2cap?.close() }
        l2cap = null
        l2capPipes.values.forEach { it.close() }
        l2capPipes.clear()
        gattPipes.values.forEach { it.close() }
        gattPipes.clear()
        runCatching { server?.close() }
        server = null
        dropKeepers()
    }

    /** Writes record bytes to the peer (whichever pipe is open for it). */
    fun write(address: String, bytes: ByteArray): Boolean {
        l2capPipes[address]?.let { return runCatching { it.write(bytes); true }.getOrDefault(false) }
        gattPipes[address]?.let { return runCatching { it.write(bytes); true }.getOrDefault(false) }
        // No pipe for this address yet: try any open pipe (single-peer product).
        l2capPipes.values.firstOrNull()?.let { return runCatching { it.write(bytes); true }.getOrDefault(false) }
        gattPipes.values.firstOrNull()?.let { return runCatching { it.write(bytes); true }.getOrDefault(false) }
        return false
    }

    fun isConnected(address: String?): Boolean =
        if (address != null) l2capPipes.containsKey(address) || gattPipes.containsKey(address)
        else l2capPipes.isNotEmpty() || gattPipes.isNotEmpty()

    private fun startL2cap() {
        val ss = adapter!!.listenUsingInsecureL2capChannel() // insecure on purpose: see LinkSecurity
        l2cap = ss
        psm = ss.psm
        Thread({
            while (running) {
                try {
                    val sock = ss.accept()
                    Log.i(TAG, "l2cap accepted from ${sock.remoteDevice.address}")
                    val t = L2capTransport(sock)
                    l2capPipes[sock.remoteDevice.address] = t
                    onConnected?.invoke(sock.remoteDevice.address)
                    t.start(
                        onBytes = { b, n -> onBytes?.invoke(sock.remoteDevice.address, b.copyOf(n)) },
                        onClosed = {
                            l2capPipes.remove(sock.remoteDevice.address)
                            onClosed?.invoke(sock.remoteDevice.address)
                        },
                    )
                } catch (e: IOException) {
                    if (running) {
                        // The listener died while we still run (Bluetooth hiccup): open a new one, or every later
                        // link would wait for the L2CAP timeout and fall back to GATT.
                        Log.w(TAG, "l2cap accept failed: ${e.message}; reopening the listener")
                        Thread.sleep(1000)
                        if (running) runCatching { startL2cap() }
                    }
                    break
                }
            }
        }, "l2cap-accept").start()
    }

    private fun startGatt() {
        val s = manager.openGattServer(ctx, gattCallback) ?: throw IOException("no GATT server")
        server = s
        // No characteristic or descriptor asks for link encryption: the link is secured by the app's own pairing
        // (P-256 + AES-GCM), never by a Bluetooth bond.
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(
            BluetoothGattCharacteristic(PSM_CHAR, BluetoothGattCharacteristic.PROPERTY_READ, LinkSecurity.CHAR_READ)
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                RX_CHAR,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_WRITE,
                LinkSecurity.CHAR_WRITE,
            )
        )
        val tx = BluetoothGattCharacteristic(TX_CHAR, BluetoothGattCharacteristic.PROPERTY_NOTIFY, LinkSecurity.CHAR_READ)
        tx.addDescriptor(BluetoothGattDescriptor(CCCD, LinkSecurity.DESC_READ_WRITE))
        service.addCharacteristic(tx)
        txChar = tx
        val wake = BluetoothGattCharacteristic(WAKE_CHAR, BluetoothGattCharacteristic.PROPERTY_NOTIFY, LinkSecurity.CHAR_READ)
        wake.addDescriptor(BluetoothGattDescriptor(CCCD, LinkSecurity.DESC_READ_WRITE))
        service.addCharacteristic(wake)
        wakeChar = wake
        s.addService(service)
        val androidMask = BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED or BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED_MITM or
            BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED or BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED_MITM or
            BluetoothGattCharacteristic.PERMISSION_WRITE_SIGNED or BluetoothGattCharacteristic.PERMISSION_WRITE_SIGNED_MITM
        check(androidMask == LinkSecurity.SECURE_MASK && BluetoothGattCharacteristic.PERMISSION_READ == LinkSecurity.PERMISSION_READ &&
            BluetoothGattCharacteristic.PERMISSION_WRITE == LinkSecurity.PERMISSION_WRITE) { "LinkSecurity constants differ from Android's" }
        securityCheck = LinkSecurity.check(service.characteristics.map { c -> c.uuid.toString() to (listOf(c.permissions) + c.descriptors.map { it.permissions }) })
        if (securityCheck != "ok") Log.e(TAG, "GATT security check: $securityCheck")
    }

    /** "ok" when nothing in the service asks for link encryption. */
    @Volatile var securityCheck = "not started"; private set

    /** A start was requested and its callback has not come yet: never start (or stop) another one meanwhile. */
    @Volatile private var startPending = false

    private fun advParams() = AdvertisingSetParameters.Builder()
        .setLegacyMode(true)
        .setConnectable(true)
        .setScannable(true)
        // ~100 ms while nobody is linked (quick reconnects), ~250 ms while linked: less radio time taken
        // from the connection events (call audio) and less battery.
        .setInterval(if (linked) AdvertisingSetParameters.INTERVAL_MEDIUM else AdvertisingSetParameters.INTERVAL_LOW)
        .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
        .build()

    /**
     * One advertising set for the life of the service. Stopping and starting sets on every link change (to switch
     * the interval) leaked them: a stop while a start was still pending orphaned that set, it kept its slot, and
     * after enough link changes Android refused all advertising ("too many advertisers"), so the iPhone could not
     * find the phone. Interval changes now go to the same set.
     */
    private fun startAdvertising() {
        if (advSet != null || startPending) return
        val adv = adapter!!.bluetoothLeAdvertiser ?: throw IOException("no advertiser")
        val params = advParams()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE))
            .setIncludeDeviceName(false)
            .build()
        startPending = true
        try { adv.startAdvertisingSet(params, data, AdvertiseData.Builder().build(), null, null, advCallback) }
        catch (t: Throwable) { startPending = false; throw t }
    }

    private val advCallback = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            startPending = false
            advSet = set
            advertising = status == ADVERTISE_SUCCESS
            // The link changed while the start was pending: give the set the interval wanted now.
            if (status == ADVERTISE_SUCCESS && set != null && linked != startedLinked) applyInterval(set)
            Log.i(TAG, "advertising started status=$status txPower=$txPower")
        }

        override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
            advertising = false
            if (set === advSet) advSet = null
            stoppingOurselves = false
        }
    }

    /**
     * The iPhone can only find the Android phone again while it advertises. Samsung's stack can stop an advertising
     * set (seen after Bluetooth reconfigurations); nothing restarted it. Called every 10 s by the Dart side.
     */
    @Volatile private var linked = false
    @Volatile private var stoppingOurselves = false

    /** The interval the running set was last given (see [applyInterval]). */
    @Volatile private var startedLinked = false

    /** Pause, change the interval, resume: the same set, so nothing leaks. */
    private fun applyInterval(set: AdvertisingSet) {
        startedLinked = linked
        runCatching {
            set.enableAdvertising(false, 0, 0)
            set.setAdvertisingParameters(advParams())
            set.enableAdvertising(true, 0, 0)
        }
    }

    @Synchronized fun setLinked(on: Boolean) {
        if (linked == on || !running) { linked = on; return }
        linked = on
        advSet?.let { applyInterval(it) } // no set yet: onAdvertisingSetStarted applies it
    }

    @Synchronized fun ensureAdvertising() {
        if (!running || !enabled || advertising || startPending) return
        val set = advSet
        if (set != null) {
            runCatching { set.enableAdvertising(true, 0, 0) }
            return
        }
        runCatching { startAdvertising() }
    }

    /** Sends a 1-byte notification on the wake characteristic (wakes the iPhone app from suspension). */
    fun wake(address: String) {
        val s = server ?: return
        val c = wakeChar ?: return
        if (address !in wakeSubscribers) return
        val d = devices[address] ?: return
        runCatching { s.notifyCharacteristicChanged(d, c, false, byteArrayOf(1)) }
    }

    // ---------------------------------------------------------------- LE link holding / pulsing

    /**
     * LE link to the paired iPhone, opened by us (a GATT *client* over LE), in two modes:
     * - held for as long as a session with it is up: while the phones are also linked over classic Bluetooth
     *   (tethering) iOS runs GATT over whichever link it has and moves it to LE when one appears, dropping the
     *   session; holding LE keeps it there. Released the moment the session ends: a link we hold blocks a freshly
     *   started app's connect on iOS.
     * - pulsed while paired without a session: up for [PULSE_UP_MS], then dropped. A link coming up completes the
     *   pending connect of a suspended or relaunched app even when iOS cannot follow our rotating address.
     * Connection priority is requested through the held link (the GATT server API cannot): HIGH during calls.
     */
    private val keepers = ConcurrentHashMap<String, BluetoothGatt>()
    private val keeperUp = ConcurrentHashMap.newKeySet<String>()
    private val held = ConcurrentHashMap.newKeySet<String>()
    private val wantedPriority = ConcurrentHashMap<String, Int>()
    private val pulseTimer = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "le-pulse").apply { isDaemon = true } }

    private fun openLe(address: String, onUp: (BluetoothGatt) -> Unit) {
        if (!running || !BluetoothAdapter.checkBluetoothAddress(address) || keepers.containsKey(address)) return
        val d = runCatching { adapter?.getRemoteDevice(address) }.getOrNull() ?: return
        runCatching {
            keepers[address] = d.connectGatt(ctx, false, object : android.bluetooth.BluetoothGattCallback() {
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) { keeperUp.add(address); onUp(g) }
                    else if (newState == android.bluetooth.BluetoothProfile.STATE_DISCONNECTED) {
                        keeperUp.remove(address)
                        if (keepers[address] === g) keepers.remove(address)
                        runCatching { g.close() }
                    }
                }
            }, BluetoothDevice.TRANSPORT_LE)
        }.onFailure { Log.w(TAG, "LE link not opened: ${it.message}") }
    }

    /** A session with this central is up: hold the LE link (see above). */
    fun holdLe(address: String) {
        held.add(address)
        if (address in keeperUp) {
            keepers[address]?.let { runCatching { it.requestConnectionPriority(wantedPriority[address] ?: BluetoothGatt.CONNECTION_PRIORITY_BALANCED) } }
            return
        }
        openLe(address) { g ->
            g.requestConnectionPriority(wantedPriority[address] ?: BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
        }
    }

    /** The session ended: let the link go at once (a held link blocks the app's next connect). */
    fun releaseLe(address: String) {
        held.remove(address); wantedPriority.remove(address)
        keepers.remove(address)?.let { g -> keeperUp.remove(address); runCatching { g.disconnect(); g.close() } }
    }

    /** Paired, no session: bring an LE link up briefly, then drop it unless a session came up meanwhile. */
    fun pulseLe(address: String) {
        // The Dart side decides when to pulse (it knows the pairing state); here only: no session, no link yet.
        if (address in held || keepers.containsKey(address) || address in leLinks) return
        openLe(address) { _ ->
            pulseTimer.schedule({ if (address !in held) releaseLe(address) }, PULSE_UP_MS, TimeUnit.MILLISECONDS)
        }
        // Not even connected after a while (out of range): give the attempt up, the next pulse tries again.
        pulseTimer.schedule({ if (address !in held && address !in keeperUp) releaseLe(address) }, 10_000, TimeUnit.MILLISECONDS)
    }

    /**
     * Close the central's LE connection (we have no session on it any more). iOS keeps the connection of an app that
     * died for up to ~40 s, and while any LE link to us exists it does not complete the reopened app's new connect;
     * closing it lets the next pulse bring a fresh link up, which completes it.
     */
    fun closeLeConnection(address: String) {
        val s = server ?: return
        val d = devices[address] ?: return
        if (address !in leLinks) return
        runCatching { s.cancelConnection(d) }
    }

    /** Nothing is paired any more: no link is held or pulsed. */
    fun dropKeepers() {
        held.clear()
        keepers.keys.toList().forEach { releaseLe(it) }
    }

    fun tune(address: String, high: Boolean) {
        val prio = if (high) BluetoothGatt.CONNECTION_PRIORITY_HIGH else BluetoothGatt.CONNECTION_PRIORITY_BALANCED
        wantedPriority[address] = prio
        val g = keepers[address]?.takeIf { address in keeperUp && address in held } ?: return
        runCatching { g.requestConnectionPriority(prio) }
        Log.i(TAG, "link priority ${if (high) "high" else "balanced"} requested")
    }

    fun untune(address: String) = tune(address, high = false)

    private val txSubscribers = ConcurrentHashMap.newKeySet<String>()

    /** Centrals with an LE link right now (from the ACL broadcasts); a GATT pipe without one runs over classic. */
    private val leLinks = ConcurrentHashMap.newKeySet<String>()

    /** Per GATT pipe: whether it was opened over LE (true) or classic Bluetooth (false). */
    private val pipeOnLe = ConcurrentHashMap<String, Boolean>()

    /**
     * ACL up / down for a central. iOS runs GATT over whichever transport it has and moves it when the other one
     * appears or goes; a session on a GATT pipe dies with its bearer, so end it at once (the central sets up again
     * on the new bearer) instead of leaving a stale pipe that keeps sending its queue into the new one.
     */
    fun onAcl(address: String?, le: Boolean, up: Boolean) {
        address ?: return
        if (le) { if (up) leLinks.add(address) else leLinks.remove(address) }
        val onLe = pipeOnLe[address] ?: return
        // iOS runs GATT over whichever transport it has and moves it when the other one appears or goes: a
        // session on the old bearer is then dead even if no GATT disconnect arrives for it.
        val ends = if (le) (up && !onLe) || (!up && onLe) else (!up && !onLe)
        if (ends) {
            Log.i(TAG, "gatt pipe for $address ends: ${if (le) "LE" else "classic"} link ${if (up) "up" else "down"}")
            pipeOnLe.remove(address)
            gattPipes.remove(address)?.close()
        }
    }

    /** A new GATT pipe (and session) for this central; an older pipe of the same central is closed first. */
    private fun openPipe(s: BluetoothGattServer, device: BluetoothDevice): GattTransport {
        val hadPipe = gattPipes.remove(device.address)?.also { it.close() } != null
        val t = GattTransport(s, device, txChar!!)
        t.mtu = mtus[device.address] ?: 23
        pipeOnLe[device.address] = device.address in leLinks
        // A fresh pipe on the same connection means a new session: its first record restarts the link layer.
        t.restartPending = hadPipe
        t.onPeerRestart = { first ->
            onPeerRestart?.invoke(device.address, first)
        }
        t.onBytes = { b, n -> onBytes?.invoke(device.address, b.copyOf(n)) }
        t.onClosed = { onClosed?.invoke(device.address) }
        gattPipes[device.address] = t
        Log.i(TAG, "gatt fallback pipe opened for ${device.address}")
        t.start()
        return t
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.i(TAG, "gatt ${device.address} state=$newState status=$status bond=${device.bondState}")
            if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                devices[device.address] = device
                onConnected?.invoke(device.address)
                // 2M PHY roughly halves air time per packet (lower latency, more headroom for audio).
                runCatching { server?.setPreferredPhy(device, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED) }
            }
            if (newState == android.bluetooth.BluetoothProfile.STATE_DISCONNECTED) {
                gattPipes.remove(device.address)?.close()
                txSubscribers.remove(device.address)
                mtus.remove(device.address)
                wakeSubscribers.remove(device.address)
                devices.remove(device.address)
                onDisconnected?.invoke(device.address)
            }
        }

        /**
         * Hidden in the SDK stubs (so no `override`), but ART dispatches it by signature: the real
         * connection interval (×1.25 ms), peripheral latency and supervision timeout of each link.
         */
        @Suppress("unused")
        fun onConnectionUpdated(device: BluetoothDevice, interval: Int, latency: Int, timeout: Int, status: Int) {
            linkParams[device.address] = "interval %.2f ms, latency %d, timeout %d ms".format(interval * 1.25, latency, timeout * 10)
            Log.i(TAG, "link ${device.address}: ${linkParams[device.address]}")
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.i(TAG, "mtu ${device.address} = $mtu")
            mtus[device.address] = mtu
            gattPipes[device.address]?.mtu = mtu
            onMtuChanged?.invoke(device.address, mtu)
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                                                 characteristic: BluetoothGattCharacteristic) {
            val s = server ?: return
            if (characteristic.uuid == PSM_CHAR) {
                val v = byteArrayOf((psm and 0xff).toByte(), (psm shr 8).toByte())
                s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, v.copyOfRange(minOf(offset, 2), 2))
            } else {
                s.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                                              preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            val s = server ?: return
            if (descriptor.uuid == CCCD && descriptor.characteristic.uuid == WAKE_CHAR) {
                val on = value != null && value.isNotEmpty() && value[0].toInt() and 1 == 1
                if (on) wakeSubscribers.add(device.address) else wakeSubscribers.remove(device.address)
                devices[device.address] = device
                Log.i(TAG, "wake notifications ${if (on) "on" else "off"} for ${device.address}")
            } else if (descriptor.uuid == CCCD && descriptor.characteristic.uuid == TX_CHAR) {
                val on = value != null && value.isNotEmpty() && value[0].toInt() and 1 == 1
                // A (re)subscription always starts a fresh pipe: the central is setting up a new session.
                if (on) { txSubscribers.add(device.address); openPipe(s, device) }
                else { txSubscribers.remove(device.address); gattPipes.remove(device.address)?.close() }
            }
            if (responseNeeded) s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
                                                  preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            if (characteristic.uuid == RX_CHAR && value != null) {
                // A pipe whose session ended is never reused; a subscribed central writing again gets a fresh one.
                val p = gattPipes[device.address]?.takeIf { !it.isClosed }
                    ?: server?.takeIf { device.address in txSubscribers }?.let { openPipe(it, device) }
                p?.received(value)
            }
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            gattPipes[device.address]?.notificationSent()
        }
    }
}

/** L2CAP connection-oriented channel (primary transport). */
@SuppressLint("MissingPermission")
private class L2capTransport(private val socket: BluetoothSocket) {
    val address: String = socket.remoteDevice?.address ?: "?"
    private val out = socket.outputStream
    @Volatile private var closed = false

    fun start(onBytes: (ByteArray, Int) -> Unit, onClosed: () -> Unit) {
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            val buf = ByteArray(4096)
            try {
                val input = socket.inputStream
                while (!closed) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) onBytes(buf, n)
                }
            } catch (e: IOException) {
                if (!closed) Log.i(BlePeripheral.TAG, "l2cap read ended: ${e.message}")
            } finally {
                close()
                onClosed()
            }
        }, "l2cap-rx").start()
    }

    fun write(bytes: ByteArray) {
        if (closed) throw IOException("closed")
        synchronized(out) {
            out.write(bytes)
            out.flush()
        }
    }

    fun close() {
        if (closed) return
        closed = true
        runCatching { socket.close() }
    }
}

/**
 * GATT fallback: RX writes and TX notifications carry the same byte stream as L2CAP,
 * chunked to MTU-3. Notifications are flow-controlled by onNotificationSent.
 */
@SuppressLint("MissingPermission")
private class GattTransport(
    private val server: BluetoothGattServer,
    private val device: BluetoothDevice,
    private val tx: BluetoothGattCharacteristic,
) {
    val address: String = device.address
    @Volatile var mtu = 23
    private val chunks = LinkedBlockingQueue<ByteArray>()
    private val sent = java.util.concurrent.Semaphore(1)
    val isClosed get() = closed

    /** Set by the peripheral: the central started a new session on this GATT connection (its first record). */
    var onPeerRestart: ((ByteArray) -> Unit)? = null
    var onBytes: ((ByteArray, Int) -> Unit)? = null
    var onClosed: (() -> Unit)? = null
    @Volatile private var closed = false

    /** True while this pipe is a fresh one on a connection that already had a pipe: its first record restarts. */
    @Volatile var restartPending = false

    fun start() {
        Thread({
            try {
                var retry: ByteArray? = null // a chunk the stack refused: sent again first, so order is kept
                while (!closed) {
                    val c = retry ?: chunks.poll(1, TimeUnit.SECONDS)?.also { queued.addAndGet(-it.size) } ?: continue
                    retry = null
                    val acquired = sent.tryAcquire(2, TimeUnit.SECONDS)
                    if (!acquired) Log.w(BlePeripheral.TAG, "gatt notify ack timeout")
                    awaitingAck = true
                    val rc = server.notifyCharacteristicChanged(device, tx, false, c)
                    if (rc != android.bluetooth.BluetoothStatusCodes.SUCCESS) {
                        awaitingAck = false
                        if (acquired) sent.release()
                        Thread.sleep(10)
                        retry = c
                    }
                }
            } catch (_: InterruptedException) {
            }
        }, "gatt-tx").start()
    }

    fun received(value: ByteArray) {
        // A fresh pipe on the same connection means a new session: its first record restarts the link layer
        // (the Dart side treats peerRestart the same as bytes of a new session).
        if (restartPending) {
            restartPending = false
            onPeerRestart?.invoke(value)
            return
        }
        onBytes?.invoke(value, value.size)
    }

    /** A TX notification was delivered. Wake notifications share the callback: only an awaited one counts. */
    @Volatile private var awaitingAck = false
    fun notificationSent() { if (awaitingAck) { awaitingAck = false; sent.release() } }

    /** Bytes queued but not yet notified: the writer waits above [MAX_QUEUED] (back-pressure, see write). */
    private val queued = java.util.concurrent.atomic.AtomicInteger(0)

    fun write(bytes: ByteArray) {
        if (closed) throw IOException("closed")
        // Back-pressure: without it a sync put megabytes into this queue at once (a GATT pipe moves a few kB/s at a
        // 23-byte MTU), the session could not answer anything for minutes, and a stale pipe kept sending for long.
        while (queued.get() > MAX_QUEUED) { if (closed) throw IOException("closed"); Thread.sleep(5) }
        val step = (mtu - 3).coerceAtLeast(20)
        var i = 0
        while (i < bytes.size) {
            val end = minOf(bytes.size, i + step)
            queued.addAndGet(end - i)
            chunks.put(bytes.copyOfRange(i, end))
            i = end
        }
    }

    fun close() {
        if (closed) return
        closed = true
        chunks.clear()
        onClosed?.invoke()
    }

    companion object { const val MAX_QUEUED = 32 * 1024 }
}
