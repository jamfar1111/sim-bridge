import Flutter
import Foundation
import UIKit

/// Flutter plugins for the native iOS bridges. Registered from
/// `AppDelegate.didInitializeImplicitFlutterEngine` (see below).
///
/// Channels (full contract in NATIVE_CHANNELS.md):
/// - `com.simbridge/ble` + `com.simbridge/ble/events` — BLE central (see `BleCentral`).
/// - `com.simbridge/callkit` + `com.simbridge/callkit/events` — CallKit (see `CallKitManager`).
/// - `com.simbridge/audio` + `com.simbridge/audio/events` — call audio engine (see `CallAudioEngine`).

// MARK: - BLE

final class BlePlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BlePlugin()
        let methods = FlutterMethodChannel(name: "com.simbridge/ble", binaryMessenger: registrar.messenger())
        methods.setMethodCallHandler(instance.handle)
        let events = FlutterEventChannel(name: "com.simbridge/ble/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        instance.central.onBytes = { data in instance.emit(data) }
        instance.central.onPeerRestart = { data in
            instance.emit(["t": "peerRestart", "bytes": FlutterStandardTypedData(bytes: data)])
        }
        instance.central.onConnected = { address in
            instance.emit(["t": "connected", "address": address])
            instance.pendingConnect?(nil)
            instance.pendingConnect = nil
        }
        instance.central.onDisconnected = { address in
            instance.emit(["t": "disconnected", "address": address])
        }
        instance.central.onClosed = {
            instance.emit(["t": "closed"])
        }
    }

    private let central = BleCentral()
    private var sink: FlutterEventSink?
    private var pendingConnect: FlutterResult?

    private func emit(_ event: Any) {
        // CoreBluetooth callbacks arrive on the central's queue; the sink is driven from the main thread.
        DispatchQueue.main.async { self.sink?(event) }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startAdvertising":
            // iOS is the central: there is nothing to advertise. The Dart side starts the link with `connect`.
            result(true)
        case "stopAdvertising":
            result(nil)
        case "connect":
            let address = (call.arguments as? [String: Any])?["address"] as? String ?? ""
            if central.isConnected { result(nil); return }
            pendingConnect = result
            central.connect(address: address)
            // If the transport does not come up, fail the call instead of hanging Dart forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.pendingConnect != nil else { return }
                self.pendingConnect?(
                    FlutterError(code: "timeout", message: "BLE connect timed out", details: nil))
                self.pendingConnect = nil
            }
        case "disconnect":
            pendingConnect = nil
            central.disconnect()
            result(nil)
        case "write":
            guard let args = call.arguments as? [String: Any],
                  let bytes = args["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "bad_args", message: "write needs 'bytes'", details: nil))
                return
            }
            central.write(bytes.data)
            result(nil)
        case "wake":
            // Wake notifications flow peripheral → central; the iPhone is the central, so this is a no-op.
            result(nil)
        case "tune":
            // iOS manages connection parameters itself; there is no per-connection priority API.
            result(nil)
        case "isConnected":
            result(central.isConnected)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension BlePlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

// MARK: - CallKit

final class CallKitPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CallKitPlugin()
        let methods = FlutterMethodChannel(name: "com.simbridge/callkit", binaryMessenger: registrar.messenger())
        methods.setMethodCallHandler(instance.handle)
        let events = FlutterEventChannel(name: "com.simbridge/callkit/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        instance.manager.onAction = { action in
            DispatchQueue.main.async { instance.sink?(action) }
        }
    }

    private let manager = CallKitManager()
    private var sink: FlutterEventSink?

    private func args(_ call: FlutterMethodCall) -> [String: Any] {
        call.arguments as? [String: Any] ?? [:]
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        Task { @MainActor in
            switch call.method {
            case "reportCall":
                if let map = self.args(call)["call"] as? [String: Any],
                   let info = SimCallInfo.from(map) {
                    self.manager.handle(info)
                }
                result(nil)
            case "reconcile":
                let list = (self.args(call)["calls"] as? [[String: Any]] ?? []).compactMap(SimCallInfo.from)
                self.manager.reconcile(with: list)
                result(nil)
            case "linkLost":
                self.manager.linkLost()
                result(nil)
            case "dialAccepted":
                self.manager.dialAccepted()
                result(nil)
            case "dialFailed":
                self.manager.dialFailed(self.args(call)["err"] as? String ?? "failed")
                result(nil)
            case "startOutgoing":
                let a = self.args(call)
                self.manager.startOutgoing(number: a["num"] as? String ?? "",
                                           sub: (a["sub"] as? NSNumber)?.intValue)
                result(nil)
            case "answer":
                if let cid = self.args(call)["cid"] as? String { self.manager.answer(cid: cid) }
                result(nil)
            case "end":
                if let cid = self.args(call)["cid"] as? String { self.manager.end(cid: cid) }
                result(nil)
            case "setMuted":
                let a = self.args(call)
                if let cid = a["cid"] as? String, let uuid = self.manager.uuid(for: cid) {
                    self.manager.setMuted(uuid, a["on"] as? Bool ?? false)
                }
                result(nil)
            case "setHeld":
                let a = self.args(call)
                if let cid = a["cid"] as? String, let uuid = self.manager.uuid(for: cid) {
                    self.manager.setHeld(uuid, a["on"] as? Bool ?? false)
                }
                result(nil)
            case "dtmf":
                let a = self.args(call)
                if let cid = a["cid"] as? String, let uuid = self.manager.uuid(for: cid) {
                    self.manager.dtmf(uuid, a["d"] as? String ?? "")
                }
                result(nil)
            case "take":
                if let cid = self.args(call)["cid"] as? String { self.manager.take(cid) }
                result(nil)
            case "setSpeaker":
                self.manager.setSpeaker(self.args(call)["on"] as? Bool ?? false)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

extension CallKitPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

// MARK: - Audio

final class AudioPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AudioPlugin()
        let methods = FlutterMethodChannel(name: "com.simbridge/audio", binaryMessenger: registrar.messenger())
        methods.setMethodCallHandler(instance.handle)
        let events = FlutterEventChannel(name: "com.simbridge/audio/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        CallAudioEngine.shared.onCapturedFrame = { codec, seq, payload in
            let event: [String: Any] = [
                "t": "captured",
                "codec": codec,
                "seq": Int(seq),
                "payload": FlutterStandardTypedData(bytes: payload),
            ]
            DispatchQueue.main.async { instance.sink?(event) }
        }
    }

    private let engine = CallAudioEngine.shared
    private var sink: FlutterEventSink?
    private let opusEncode = OpusCoder()
    private let opusDecode = OpusCoder()

    private func args(_ call: FlutterMethodCall) -> [String: Any] {
        call.arguments as? [String: Any] ?? [:]
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "audioStart":
            let a = args(call)
            engine.configure(codec: a["codec"] as? String ?? "opus",
                             rate: (a["rate"] as? NSNumber)?.doubleValue ?? 16000,
                             bitrate: (a["bitrate"] as? NSNumber)?.intValue ?? 32000)
            result(nil)
        case "audioStop":
            engine.stop()
            result(nil)
        case "playFrame":
            let a = args(call)
            guard let payload = (a["payload"] as? FlutterStandardTypedData)?.data else {
                result(FlutterError(code: "bad_args", message: "playFrame needs 'payload'", details: nil))
                return
            }
            engine.receive(codec: (a["codec"] as? NSNumber)?.intValue ?? 1,
                           seq: UInt16((a["seq"] as? NSNumber)?.intValue ?? 0),
                           payload: payload)
            result(nil)
        case "setMuted":
            engine.muted = args(call)["on"] as? Bool ?? false
            result(nil)
        case "setRingback":
            engine.ringback = args(call)["on"] as? Bool ?? false
            result(nil)
        case "supportedCodecs":
            result(CallAudioEngine.supportedCodecs)
        case "opusEncode":
            guard let pcmData = (args(call)["pcm"] as? FlutterStandardTypedData)?.data,
                  let coder = opusEncode else {
                result(FlutterError(code: "opus", message: "Opus encoder unavailable", details: nil))
                return
            }
            // Native endianness on iOS is little-endian, so the PCM bytes copy straight into Int16 samples.
            let pcm = pcmData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            if let frame = coder.encode(pcm) {
                result(FlutterStandardTypedData(bytes: frame))
            } else {
                result(FlutterError(code: "opus", message: "encode failed", details: nil))
            }
        case "opusDecode":
            guard let frameData = (args(call)["frame"] as? FlutterStandardTypedData)?.data,
                  let coder = opusDecode else {
                result(FlutterError(code: "opus", message: "Opus decoder unavailable", details: nil))
                return
            }
            let pcm = coder.decode(frameData)
            var bytes = Data(capacity: pcm.count * 2)
            pcm.withUnsafeBytes { bytes.append($0.bindMemory(to: UInt8.self)) }
            result(FlutterStandardTypedData(bytes: bytes))
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension AudioPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
