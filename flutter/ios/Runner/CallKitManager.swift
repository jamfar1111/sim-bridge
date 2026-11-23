import AVFoundation
import CallKit
import Foundation
import UIKit

/// A live call, as Dart sends it (`CallInfo` in `lib/src/protocol/messages.dart`).
struct SimCallInfo {
    let cid: String
    let num: String
    let name: String?
    let state: String // "ringing" | "dialing" | "connecting" | "active" | "holding" | "ended"
    let dir: String   // "in" | "out"
    let sub: Int?
    let since: Int64?
    let cause: String?
    let hold: Bool
    let elsewhere: Bool?
    let where_: String?

    var isEnded: Bool { state == "ended" }
    var isIncoming: Bool { dir == "in" }
    var isElsewhere: Bool { elsewhere == true }

    static func from(_ map: [String: Any]) -> SimCallInfo? {
        guard let cid = map["cid"] as? String,
              let num = map["num"] as? String,
              let state = map["state"] as? String,
              let dir = map["dir"] as? String,
              let hold = map["hold"] as? Bool else { return nil }
        return SimCallInfo(
            cid: cid, num: num, name: map["name"] as? String, state: state, dir: dir,
            sub: (map["sub"] as? NSNumber)?.intValue,
            since: (map["since"] as? NSNumber)?.int64Value,
            cause: map["cause"] as? String, hold: hold,
            elsewhere: map["elsewhere"] as? Bool, where_: map["where"] as? String)
    }
}

/// What the iPhone does with a call state for a call it already hung up (the Android phone may still send states
/// that were on their way): drop them, ask again if the Android phone still reports the call 2 s later, forget
/// after an end. Port of TetherCore's `HangUpGuard`.
struct HangUpGuard {
    enum Verdict { case pass, drop, dropAndResend }
    private var hungUp: [String: Date] = [:]

    mutating func hungUp(_ cid: String, at: Date = Date()) { hungUp[cid] = at }
    mutating func reset() { hungUp.removeAll() }

    mutating func check(cid: String, ended: Bool, now: Date = Date()) -> Verdict {
        guard let t = hungUp[cid] else { return .pass }          // any other call, including every new one
        if ended { hungUp[cid] = nil; return .pass }               // the end we wanted: let it close what is left
        let age = now.timeIntervalSince(t)
        if age > 30 { hungUp[cid] = nil; return .drop }            // give up asking; never resurrect it
        if age > 2 { hungUp[cid] = now; return .dropAndResend }
        return .drop
    }
}

/// Maps the Android phone's calls onto CallKit (native incoming screen, lock screen too).
///
/// Unlike Tether's `CallController`, this class has no link and no in-app screen: Dart owns both.
/// It reports call states into CallKit and turns the user's CallKit actions (answer / end / hold /
/// mute / DTMF / dial / take) into `callkit.action` events for Dart, which sends them over the link
/// as `call.answer` / `call.end` / … messages. Actions this class created itself to mirror something
/// done on the Android phone are marked `mirrored` and are not echoed back.
///
/// Channel: `com.simbridge/callkit` (methods) + `com.simbridge/callkit/events` (actions).
/// The Dart side of this contract is documented in NATIVE_CHANNELS.md.
@MainActor
final class CallKitManager: NSObject {
    /// An action the user took in CallKit, for Dart to send over the link.
    var onAction: (([String: Any]) -> Void)?
    var log: (String) -> Void = { NSLog("[calls] %@", $0) }

    private let provider: CXProvider
    private let controller = CXCallController()
    /// Calls whose audio is on another client, by Android phone call id (shown as "answered elsewhere"; "Move here" sends `call.take`).
    private(set) var remote: [String: SimCallInfo] = [:]

    /// Android phone call id ↔ CallKit UUID.
    private var uuids: [String: UUID] = [:]
    private var cids: [UUID: String] = [:]
    private var lastState: [String: String] = [:]
    private var info: [UUID: SimCallInfo] = [:]
    /// Outgoing call started on the iPhone, waiting for the Android phone to report its call id.
    private var pendingOutgoing: UUID?
    private var pendingSub: Int?
    /// Actions we created ourselves to mirror something done on the Android phone (must not be echoed back).
    private var mirrored = Set<UUID>()
    private var answeredHere = Set<UUID>()
    private var reportedConnecting = Set<UUID>()
    private var reportedConnected = Set<UUID>()
    /// CallKit has performed the start action for these outgoing calls (reports before that are dropped).
    private var startPerformed = Set<UUID>()
    /// The user hung up an outgoing call before the Android phone reported it: end it as soon as it shows up.
    private var cancelledDialAt: Date?
    /// Numbers of the dial in flight and of the one hung up before the Android phone reported it.
    private var pendingNumber = "", cancelledNumber = ""
    /// Holds we asked for ourselves (a hold done on the Android phone is mirrored into CallKit instead).
    private var holdRequested = Set<UUID>()
    private var dialWatchdog: Task<Void, Never>?
    /// Calls ended from our own call screen: CallKit's end action that follows must not act twice.
    private var endedHere = Set<UUID>()
    /// Android phone call ids hung up here: late updates for them must not bring the call back.
    private var hungUp = HangUpGuard()
    /// The user's speaker choice for the current call; applied whenever the audio session is (re)activated.
    private var speakerWanted = false

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 2
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber]
        config.includesCallsInRecents = false // the app has its own Recents synced from the Android phone
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // The speaker button follows the real route (CallKit's own speaker button, AirPods, a cable…).
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
    }

    var hasCalls: Bool { !uuids.isEmpty || pendingOutgoing != nil }

    /// Screen off at the ear, like a native call: proximity monitoring while a call is up and its audio is on the
    /// earpiece (not on speaker, headphones or AirPods). CallKit does this for its own screen only.
    func updateProximity() {
        let live = hasCalls
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let earpiece = outputs.isEmpty || outputs.contains { $0.portType == .builtInReceiver }
        let want = live && earpiece && !speakerWanted
        if UIDevice.current.isProximityMonitoringEnabled != want {
            UIDevice.current.isProximityMonitoringEnabled = want
        }
    }

    private func routeChanged() {
        defer { updateProximity() }
        guard hasCalls else { return }
        speakerWanted = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    /// Re-applies the speaker choice (an override only works on an active session).
    func applySpeaker() {
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerWanted ? .speaker : .none) }
        catch { NSLog("[calls] speaker override failed: %@", "\(error)") }
        routeChanged()
    }

    func setSpeaker(_ on: Bool) {
        speakerWanted = on
        applySpeaker()
    }

    // MARK: - CallKit reporting

    private func reportIncoming(_ uuid: UUID, _ update: CXCallUpdate, then: @escaping @MainActor () -> Void) {
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            Task { @MainActor in
                guard let error else { then(); return }
                self.log("report incoming failed: \(error)")
                // CallKit refused it (Focus filter, too many calls…): forget the binding, so that if the call is
                // answered on the Android phone it shows up here as a started call with audio instead of a half-bound one.
                if let cid = self.cids[uuid] {
                    self.uuids[cid] = nil; self.cids[uuid] = nil; self.info[uuid] = nil
                    self.lastState[cid] = "unreported"
                }
                self.cleanup(uuid, flash: false)
            }
        }
    }

    private func reportEnded(_ uuid: UUID, _ reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    private func reportUpdated(_ uuid: UUID, _ update: CXCallUpdate) {
        provider.reportCall(with: uuid, updated: update)
    }

    /// Runs a call action as a CallKit transaction.
    private func run(_ action: CXCallAction, mirrored: Bool = false) {
        if mirrored { self.mirrored.insert(action.callUUID) }
        controller.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            self.log("\(type(of: action)) failed: \(error)")
            // A refused mirrored action must not make the user's next action look mirrored (and not be sent).
            if mirrored { Task { @MainActor in self.mirrored.remove(action.callUUID) } }
        }
    }

    // MARK: - from the Android phone (via Dart)

    func handle(_ c: SimCallInfo) {
        switch hungUp.check(cid: c.cid, ended: c.isEnded) {
        case .pass: break
        case .drop: return
        case .dropAndResend:
            // Still not ended on the Android phone 2 s after we hung up: ask again.
            onAction?(["t": c.state == "ringing" ? "reject" : "end", "cid": c.cid])
            return
        }
        let prev = lastState[c.cid]
        lastState[c.cid] = c.isEnded ? nil : c.state
        let handle = CXHandle(type: .phoneNumber, value: c.num)
        let name = c.name

        if c.isEnded { remote[c.cid] = nil }
        if !c.isEnded && c.isElsewhere {
            // Answered / dialed / moved to another client: stop ringing or playing here, offer "Move here".
            remote[c.cid] = c
            lastState[c.cid] = c.state
            if let uuid = uuids.removeValue(forKey: c.cid) {
                cids[uuid] = nil
                info[uuid] = nil
                reportEnded(uuid, .answeredElsewhere)
                cleanup(uuid)
            }
            return
        }
        remote[c.cid] = nil

        if c.isEnded {
            guard let uuid = uuids.removeValue(forKey: c.cid) else { return }
            cids[uuid] = nil
            info[uuid] = nil
            let reason: CXCallEndedReason
            if prev == "ringing", c.isIncoming { reason = .unanswered }
            else if let cause = c.cause, cause.localizedCaseInsensitiveContains("busy") { reason = .failed }
            else { reason = .remoteEnded }
            reportEnded(uuid, reason)
            cleanup(uuid)
            return
        }

        if uuids[c.cid] == nil {
            if c.isIncoming && c.state == "ringing" {
                // Report to CallKit before anything else: this is what makes the iPhone ring.
                let uuid = UUID()
                bind(c.cid, uuid)
                let update = CXCallUpdate()
                update.remoteHandle = handle
                update.localizedCallerName = name ?? c.num
                update.hasVideo = false
                update.supportsHolding = c.hold
                update.supportsDTMF = true
                update.supportsGrouping = false
                update.supportsUngrouping = false
                reportIncoming(uuid, update) {}
            } else if let t = cancelledDialAt, Date().timeIntervalSince(t) < 30, !cancelledNumber.isEmpty, !c.isIncoming,
                      digits(c.num) == digits(cancelledNumber),
                      pendingOutgoing == nil || digits(c.num) != digits(pendingNumber) {
                // The dial the user already hung up on (a quick redial to another number must not take its place).
                cancelledDialAt = nil; cancelledNumber = ""
                lastState[c.cid] = nil
                onAction?(["t": "end", "cid": c.cid])
                return
            } else if let uuid = pendingOutgoing {
                pendingOutgoing = nil
                dialWatchdog?.cancel()
                bind(c.cid, uuid)
            } else if let t = cancelledDialAt, Date().timeIntervalSince(t) < 30, cancelledNumber.isEmpty, !c.isIncoming {
                // The dial the user already hung up on before its number was known: end it on the Android phone instead of
                // showing it (a call to a known other number, or an incoming one, is never taken for it).
                cancelledDialAt = nil
                lastState[c.cid] = nil
                onAction?(["t": "end", "cid": c.cid])
                return
            } else {
                // Dialed or answered on the Android phone, moved here, or live when we reconnected: show it here as a
                // started call (an incoming-call report would ring for a call that is already connected).
                let uuid = UUID()
                bind(c.cid, uuid)
                run(CXStartCallAction(call: uuid, handle: handle), mirrored: true)
            }
        }
        guard let uuid = uuids[c.cid] else { return }
        info[uuid] = c

        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.localizedCallerName = name ?? c.num
        update.supportsHolding = c.hold
        update.supportsDTMF = true
        reportUpdated(uuid, update)

        switch c.state {
        case "dialing", "connecting":
            reportOutgoingProgress(uuid)
            if !c.isIncoming { CallAudioEngine.shared.ringback = true }
        case "active":
            CallAudioEngine.shared.ringback = false
            reportOutgoingProgress(uuid)
            if c.isIncoming && prev == "ringing" && !answeredHere.contains(uuid) { mirrorAnswer(uuid) }
            if prev == "holding" && holdRequested.remove(uuid) == nil { run(CXSetHeldCallAction(call: uuid, onHold: false), mirrored: true) }
        case "holding":
            // Held on the Android phone (e.g. a second call answered there): CallKit must know, or its buttons act on the wrong call.
            if prev == "active" && holdRequested.remove(uuid) == nil { run(CXSetHeldCallAction(call: uuid, onHold: true), mirrored: true) }
        default:
            break
        }
        updateProximity()
    }

    /// Reports outgoing progress to CallKit once per stage, and only after CallKit performed the start action.
    private func reportOutgoingProgress(_ uuid: UUID) {
        // Calls we started in CallKit: our own dials and mirrored ones (dialed / answered on the Android phone, moved here).
        guard let c = info[uuid], startPerformed.contains(uuid) else { return }
        if reportedConnecting.insert(uuid).inserted {
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        }
        if c.state == "active" || c.state == "holding", reportedConnected.insert(uuid).inserted {
            provider.reportOutgoingCall(with: uuid, connectedAt: c.since.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date())
        }
    }

    private func mirrorAnswer(_ uuid: UUID) {
        run(CXAnswerCallAction(call: uuid), mirrored: true)
    }

    /// "Move here": the Android phone switches call audio to this client and re-sends the state without `elsewhere`.
    func take(_ cid: String) {
        guard remote[cid] != nil else { return }
        remote[cid] = nil
        lastState[cid] = nil
        onAction?(["t": "take", "cid": cid])
    }

    private func bind(_ cid: String, _ uuid: UUID) {
        uuids[cid] = uuid
        cids[uuid] = cid
    }

    private func cleanup(_ uuid: UUID, flash: Bool = true) {
        answeredHere.remove(uuid); reportedConnecting.remove(uuid); reportedConnected.remove(uuid); mirrored.remove(uuid)
        startPerformed.remove(uuid)
        if !hasCalls {
            CallAudioEngine.shared.stop()
            speakerWanted = false
        }
        updateProximity()
    }

    /// After a reconnect: end CallKit calls the Android phone no longer has.
    func reconcile(with list: [SimCallInfo]) {
        let live = Set(list.filter { !$0.isEnded }.map(\.cid))
        for cid in remote.keys where !live.contains(cid) { remote[cid] = nil }
        for (cid, uuid) in uuids where !live.contains(cid) {
            reportEnded(uuid, .remoteEnded)
            uuids[cid] = nil; cids[uuid] = nil; lastState[cid] = nil; info[uuid] = nil
            cleanup(uuid)
        }
    }

    /// Link lost: we can no longer control the calls, so end them here (they continue on the Android phone).
    func linkLost() {
        for (_, uuid) in uuids { reportEnded(uuid, .failed) }
        uuids.removeAll(); cids.removeAll(); lastState.removeAll(); info.removeAll(); remote.removeAll()
        if let p = pendingOutgoing { reportEnded(p, .failed); pendingOutgoing = nil }
        hungUp.reset(); endedHere.removeAll(); answeredHere.removeAll(); startPerformed.removeAll(); mirrored.removeAll()
        reportedConnecting.removeAll(); reportedConnected.removeAll(); cancelledDialAt = nil; speakerWanted = false
        holdRequested.removeAll(); dialWatchdog?.cancel(); pendingNumber = ""; cancelledNumber = ""
        CallAudioEngine.shared.stop()
        updateProximity()
    }

    /// The Android phone accepted the dial: if it never reports a call for it (Telecom dropped it), fail it after 30 s
    /// instead of showing "dialing" with our ringback for ever.
    func dialAccepted() {
        guard let p = pendingOutgoing else { return }
        dialWatchdog?.cancel()
        dialWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.pendingOutgoing == p else { return }
            self.log("dial: no call from the Android phone after 30 s")
            self.dialFailed("no call")
        }
    }

    func dialFailed(_ err: String) {
        if let p = pendingOutgoing {
            reportEnded(p, .failed)
            pendingOutgoing = nil
            dialWatchdog?.cancel()
            CallAudioEngine.shared.ringback = false // another call may still be live: its audio must not carry our ringback
            cleanup(p, flash: false)
        }
    }

    // MARK: - from the iPhone UI (via Dart)

    func startOutgoing(number: String, sub: Int?) {
        let clean = digits(number)
        guard !clean.isEmpty else { return }
        let uuid = UUID()
        pendingSub = sub
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: clean))
        controller.request(CXTransaction(action: action)) { error in
            if let error {
                self.log("start failed: \(error)")
                Task { @MainActor in self.onAction?(["t": "dialFailed", "num": clean, "err": "\(error)"]) }
            }
        }
    }

    /// Hang up from our call screen: done here at once, then CallKit is told; if CallKit refuses (it may not know
    /// the call yet), its call is ended by report.
    func end(_ uuid: UUID) {
        endedHere.insert(uuid)
        performEnd(uuid)
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard let error else { return }
            self?.log("end transaction failed: \(error)")
            Task { @MainActor in
                self?.endedHere.remove(uuid)
                self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            }
        }
    }

    func answer(_ uuid: UUID) { run(CXAnswerCallAction(call: uuid)) }
    func setMuted(_ uuid: UUID, _ on: Bool) { run(CXSetMutedCallAction(call: uuid, muted: on)) }
    func setHeld(_ uuid: UUID, _ on: Bool) { run(CXSetHeldCallAction(call: uuid, onHold: on)) }
    func dtmf(_ uuid: UUID, _ digit: String) { run(CXPlayDTMFCallAction(call: uuid, digits: digit, type: .singleTone)) }

    /// Answers a ringing call by its Android phone id.
    func answer(cid: String) { if let u = uuids[cid] { answer(u) } }
    /// Ends a call by its Android-side id.
    func end(cid: String) { if let u = uuids[cid] { end(u) } }

    func cid(for uuid: UUID) -> String? { cids[uuid] }
    func uuid(for cid: String) -> UUID? { uuids[cid] }
}

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            self.uuids.removeAll(); self.cids.removeAll(); self.lastState.removeAll(); self.info.removeAll()
            self.pendingOutgoing = nil; self.mirrored.removeAll(); self.answeredHere.removeAll()
            self.reportedConnecting.removeAll(); self.reportedConnected.removeAll(); self.startPerformed.removeAll()
            self.remote.removeAll(); self.hungUp.reset(); self.endedHere.removeAll()
            CallAudioEngine.shared.stop()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            self.performStart(action.callUUID, number: action.handle.value)
            action.fulfill()
            if self.reportedConnecting.insert(action.callUUID).inserted {
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            }
            self.reportOutgoingProgress(action.callUUID) // replay state that arrived before the action ran
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.performAnswer(action.callUUID); action.fulfill() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            // Already done when the end came from our own screen.
            if self.endedHere.remove(action.callUUID) == nil { self.performEnd(action.callUUID) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in self.performMute(action.callUUID, action.isMuted); action.fulfill() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in if self.performHold(action.callUUID, action.isOnHold) { action.fulfill() } else { action.fail() } }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor in self.performDtmf(action.callUUID, action.digits); action.fulfill() }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.log("audio session activated")
            CallAudioEngine.shared.sessionActivated()
            if self.speakerWanted { self.applySpeaker() } // chosen while the call was still connecting
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in CallAudioEngine.shared.sessionDeactivated() }
    }
}

// MARK: - The actions themselves (from the CallKit delegate)

extension CallKitManager {
    func performStart(_ uuid: UUID, number: String) {
        CallAudioEngine.configureSession()
        if mirrored.remove(uuid) == nil {
            pendingOutgoing = uuid
            pendingNumber = number
            CallAudioEngine.shared.ringback = true
            var event: [String: Any] = ["t": "dial", "num": number]
            if let sub = pendingSub { event["sub"] = sub }
            onAction?(event)
        }
        startPerformed.insert(uuid)
    }

    func performAnswer(_ uuid: UUID) {
        answeredHere.insert(uuid)
        CallAudioEngine.configureSession()
        if mirrored.remove(uuid) == nil, let cid = cids[uuid] {
            onAction?(["t": "answer", "cid": cid])
        }
    }

    func performEnd(_ uuid: UUID) {
        log("end from this iPhone (\(cids[uuid] ?? "no call id yet"))")
        CallAudioEngine.shared.ringback = false
        if let cid = cids[uuid] {
            let ringing = lastState[cid] == "ringing"
            onAction?(["t": ringing ? "reject" : "end", "cid": cid])
            hungUp.hungUp(cid)
            uuids[cid] = nil
            cids[uuid] = nil
            lastState[cid] = nil
            info[uuid] = nil
        } else if pendingOutgoing == uuid {
            pendingOutgoing = nil
            cancelledDialAt = Date()
            cancelledNumber = pendingNumber
            dialWatchdog?.cancel()
        }
        cleanup(uuid)
    }

    func performMute(_ uuid: UUID, _ on: Bool) {
        CallAudioEngine.shared.muted = on
        var event: [String: Any] = ["t": "mute", "on": on]
        if let cid = cids[uuid] { event["cid"] = cid }
        onAction?(event)
    }

    func performHold(_ uuid: UUID, _ on: Bool) -> Bool {
        guard let cid = cids[uuid] else { return false }
        if mirrored.remove(uuid) != nil { return true } // mirroring a hold done on the Android phone: nothing to send
        holdRequested.insert(uuid)
        onAction?(["t": "hold", "cid": cid, "on": on])
        return true
    }

    func performDtmf(_ uuid: UUID, _ digits: String) {
        guard let cid = cids[uuid] else { return }
        for d in digits { onAction?(["t": "dtmf", "cid": cid, "d": String(d)]) }
    }
}

/// Digits only (Persian/Arabic digits included), for comparing numbers however they are written.
private func digits(_ s: String) -> String {
    String(s.unicodeScalars.compactMap { scalar -> Character? in
        let v = scalar.value
        if v >= 48 && v <= 57 { return Character(scalar) }                       // 0-9
        if v >= 0x660 && v <= 0x669 { return Character(UnicodeScalar(v - 0x660 + 48)!) } // Arabic-Indic
        if v >= 0x6F0 && v <= 0x6F9 { return Character(UnicodeScalar(v - 0x6F0 + 48)!) } // Extended Arabic-Indic (Persian)
        return nil
    })
}
