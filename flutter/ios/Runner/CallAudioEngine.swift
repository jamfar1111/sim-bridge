import AVFoundation
import Foundation
import os

/// G.711 µ-law, bit-exact with the Android implementation and the Dart port (`lib/src/protocol/audio.dart`).
enum G711 {
    static func encode(_ sample: Int16) -> UInt8 {
        let bias: Int32 = 0x84
        let clip: Int32 = 32635
        var s = Int32(sample)
        let sign: Int32 = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        if s > clip { s = clip }
        s += bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (s & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (s >> (exponent + 3)) & 0x0f
        return UInt8(truncatingIfNeeded: ~(sign | (exponent << 4) | mantissa))
    }

    static func decode(_ byte: UInt8) -> Int16 {
        let u = Int32(~byte & 0xff)
        let sign = u & 0x80
        let exponent = (u >> 4) & 0x07
        let mantissa = u & 0x0f
        var s = ((mantissa << 3) + 0x84) << exponent
        s -= 0x84
        return Int16(sign != 0 ? -s : s)
    }

    static func encode(_ pcm: [Int16]) -> Data { Data(pcm.map(encode)) }
    static func decode(_ data: Data) -> [Int16] { data.map(decode) }
}

/// Audio-channel codec ids. Must match the Dart side (`lib/src/protocol/audio.dart`) and Android.
enum AudioCodecID: Int {
    case opus = 1
    case pcmu = 2
}

/// 20 ms mono voice codec.
protocol VoiceCoder: AnyObject {
    var id: AudioCodecID { get }
    var rate: Double { get }
    func encode(_ pcm: [Int16]) -> Data?
    func decode(_ data: Data) -> [Int16]
}

final class PcmuCoder: VoiceCoder {
    let id = AudioCodecID.pcmu
    let rate = 8000.0
    func encode(_ pcm: [Int16]) -> Data? { G711.encode(pcm) }
    func decode(_ data: Data) -> [Int16] { G711.decode(data) }
}

/// Opus through AudioToolbox (raw RFC 6716 packets, interoperable with Android's Concentus Opus).
final class OpusCoder: VoiceCoder {
    let id = AudioCodecID.opus
    let rate: Double
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter

    init?(rate: Double = 16000, bitrate: Int = 32000) {
        self.rate = rate
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true) else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: UInt32(rate / 50), mBytesPerFrame: 0, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd),
              let enc = AVAudioConverter(from: pcm, to: opus),
              let dec = AVAudioConverter(from: opus, to: pcm) else { return nil }
        enc.bitRate = bitrate
        pcmFormat = pcm; opusFormat = opus; encoder = enc; decoder = dec
    }

    func encode(_ pcm: [Int16]) -> Data? {
        guard !pcm.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(pcm.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { buf.int16ChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
        let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 2, maximumPacketSize: 1500)
        var fed = false
        var err: NSError?
        _ = encoder.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard out.packetCount > 0, let desc = out.packetDescriptions?[0] else { return nil }
        return Data(bytes: out.data.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
    }

    func decode(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }
        let cb = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: max(1, data.count))
        data.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        cb.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                 mDataByteSize: UInt32(data.count))
        cb.packetCount = 1
        cb.byteLength = UInt32(data.count)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(rate / 50 * 3)) else { return [] }
        var fed = false
        var err: NSError?
        _ = decoder.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return cb
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }
}

/// Two-way call audio. The engine starts when CallKit activates the audio session:
/// mic → voice processing (echo cancellation) → sink node → codec → Dart (link), and
/// Dart (link) → codec → playout buffer → source node → speaker. Until the far end is heard on an
/// outgoing call, a local ringback tone plays.
///
/// Port of Tether's `CallAudio.swift`, with the link replaced by callbacks to the Flutter plugin:
/// `onCapturedFrame` carries encoded 20 ms frames to Dart, `receive(codec:seq:payload:)` plays
/// frames Dart received. Codec choice comes from `configure(codec:rate:bitrate:)` (Dart drives it
/// from the audio-start handshake); Opus is preferred, G.711 µ-law is the fallback.
final class CallAudioEngine: @unchecked Sendable {
    static let shared = CallAudioEngine()
    static var supportedCodecs: [String] { OpusCoder() != nil ? ["opus", "pcmu"] : ["pcmu"] }

    /// An encoded 20 ms mic frame, for Dart to send as an audio record (`codec`, `seq`, `payload`).
    var onCapturedFrame: ((Int, UInt16, Data) -> Void)?

    private let q = DispatchQueue(label: "com.simbridge.audio", qos: .userInteractive)
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sink: AVAudioSinkNode?
    private var coder: VoiceCoder?
    private var sessionActive = false
    private var running = false
    private var playout = PlayoutBuffer(rate: 16000)
    private var playRate = 16000.0
    private var captureConverter: AVAudioConverter?
    private var captureRing = SampleRing(capacity: 48000)
    private var captureMono: AVAudioFormat?
    private var pump: DispatchSourceTimer?
    private var routeObserver: NSObjectProtocol?
    private var captureFormat: AVAudioFormat?
    private var captureAcc: [Int16] = []
    private var seq: UInt16 = 0
    private var lastSeq: UInt16?
    private var flagsUnfair = os_unfair_lock()
    /// Flags shared with the real-time render thread: an unfair lock held for a few instructions (no NSLock there).
    private func flags<T>(_ body: () -> T) -> T { os_unfair_lock_lock(&flagsUnfair); defer { os_unfair_lock_unlock(&flagsUnfair) }; return body() }
    private var _muted = false
    private var _ringback = false
    private var ringPhase = 0.0
    private var ringClock = 0
    private var heardRemote = false

    struct Stats {
        var ioBufferMs = 0.0; var inputLatencyMs = 0.0; var outputLatencyMs = 0.0; var playoutMs = 0.0
        var underruns = 0; var trimmedMs = 0.0; var lost = 0
        /// Frame arrival spacing over the link: mean |gap − 20 ms| and the worst gap seen.
        var jitterMs = 0.0; var worstGapMs = 0.0; var frames = 0
    }
    private(set) var stats = Stats()
    private var lastArrival: UInt64 = 0
    private var jitterSum = 0.0

    var muted: Bool {
        get { flags { _muted } }
        set { flags { _muted = newValue } }
    }

    /// Local ringback while an outgoing call is dialing; cleared when the call connects or real audio arrives.
    var ringback: Bool {
        get { flags { _ringback } }
        set { flags { _ringback = newValue; if newValue { heardRemote = false } } }
    }
    /// Our ringback should sound now (dialing, and nothing audible from the far end yet).
    var ringbackAudible: Bool { flags { _ringback && !heardRemote } }

    static func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth]) // hands-free route for calls (A2DP has no microphone)
        try? s.setPreferredSampleRate(16000)
        try? s.setPreferredIOBufferDuration(0.01) // 10 ms I/O buffer
    }

    /// Codec for the call, from Dart (audio-start handshake). Opus preferred, PCMU fallback.
    func configure(codec: String, rate: Double, bitrate: Int = 32000) {
        q.async {
            self.coder = codec == "opus" ? (OpusCoder(rate: rate, bitrate: bitrate) ?? PcmuCoder()) : PcmuCoder()
            self.lastSeq = nil
            if self.sessionActive {
                if self.running && (self.coder?.rate ?? 16000) != self.playRate { self.stopLocked() }
                self.startLocked()
            }
        }
    }

    /// A decoded-then-encoded frame arrived from Dart (audio record payload). Decoded right away and queued for playout.
    func receive(codec: Int, seq: UInt16, payload: Data) {
        q.async { self.receiveLocked(codec: codec, seq: seq, payload: payload) }
    }

    func sessionActivated() {
        q.async {
            self.noVoiceProcessing = false // try echo cancellation again on every call
            self.sessionActive = true
            self.startLocked()
        }
    }

    func sessionDeactivated() {
        q.async { self.sessionActive = false; self.stopLocked() }
    }

    func stop() {
        q.async { self.stopLocked(); self.coder = nil; self.ringback = false; self.muted = false; self.seq = 0 }
    }

    /// Voice processing (echo cancellation) could not start with the current devices: run without it.
    private var noVoiceProcessing = false

    private func startLocked() {
        guard !running else { return }
        let rate = coder?.rate ?? 16000
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(!noVoiceProcessing) } catch { NSLog("[audio] voice processing: %@", "\(error)") }
        let inFormat = input.outputFormat(forBus: 0)
        // Touch the output node before the main mixer exists (the I/O layout this engine was tuned with).
        _ = engine.outputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let codecFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            NSLog("[audio] no input format"); return
        }
        playRate = rate
        playout = PlayoutBuffer(rate: rate)
        captureFormat = codecFormat
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1) else { return }
        captureMono = mono
        captureConverter = AVAudioConverter(from: mono, to: codecFormat)
        captureRing = SampleRing(capacity: Int(inFormat.sampleRate))

        // Playback: the render thread pulls straight from the playout buffer (no scheduled backlog).
        let buffer = playout
        let src = AVAudioSourceNode(format: playFormat) { [weak self] _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            buffer.pull(into: out, count: n)
            // While dialing, the downlink is often silence (on VoLTE the ringback is played by the phone itself,
            // not sent): play our own ringback until real audio (network ringback, the answer) is heard.
            if let self, self.ringbackAudible { self.fillRingback(out, count: n, rate: rate) }
            return noErr
        }
        // Capture: the sink node gets each I/O buffer (≈10 ms). It only copies channel 0 into a ring;
        // a 5 ms pump on the audio queue converts and encodes (nothing allocates on the real-time thread).
        let ring = captureRing
        let interleaved = inFormat.isInterleaved
        let channels = Int(inFormat.channelCount)
        let snk = AVAudioSinkNode { _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = list.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.write(data, Int(frameCount), stride: interleaved ? channels : 1)
            return noErr
        }
        engine.attach(src)
        engine.attach(snk)
        engine.connect(input, to: snk, format: inFormat)
        engine.connect(src, to: engine.mainMixerNode, format: playFormat)
        source = src
        sink = snk
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[audio] engine start failed (voice processing %@): %@", noVoiceProcessing ? "off" : "on", "\(error)")
            teardownNodes()
            if !noVoiceProcessing {
                // The output unit would not initialize with voice processing: retry plainly.
                noVoiceProcessing = true
                engine.reset()
                startLocked()
            }
            return
        }
        captureAcc.removeAll()
        // `seq` keeps counting across engine restarts (route changes): the Android phone drops frames whose number goes back.
        lastArrival = 0; jitterSum = 0
        stats = Stats()
        running = true
        let p = DispatchSource.makeTimerSource(queue: q)
        p.schedule(deadline: .now() + 0.005, repeating: 0.005, leeway: .milliseconds(1)) // 5 ms: frames leave ≤ 5 ms after capture
        p.setEventHandler { [weak self] in self?.drainCapture() }
        p.resume()
        pump = p
        // Speaker / AirPods / route changes reconfigure the engine and stop it: rebuild it.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                guard self.running else { return }
                NSLog("[audio] engine configuration changed: restarting")
                self.stopLocked()
                self.startLocked()
            }
        }
        let s = AVAudioSession.sharedInstance()
        stats.ioBufferMs = s.ioBufferDuration * 1000
        stats.inputLatencyMs = s.inputLatency * 1000
        stats.outputLatencyMs = s.outputLatency * 1000
        NSLog("[audio] started @ %.0f Hz; io %.1f ms, in %.1f ms, out %.1f ms, voice processing %@, input %.0f Hz × %d",
              rate, stats.ioBufferMs, stats.inputLatencyMs, stats.outputLatencyMs,
              noVoiceProcessing ? "off" : "on", inFormat.sampleRate, Int(inFormat.channelCount))
    }

    private func teardownNodes() {
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil; sink = nil
    }

    private func stopLocked() {
        guard running else { return }
        running = false
        pump?.cancel(); pump = nil
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        engine.stop()
        teardownNodes()
        stats.underruns = playout.underruns
        stats.trimmedMs = Double(playout.trimmed) / playRate * 1000
        stats.playoutMs = Double(playout.target) / playRate * 1000
        stats.jitterMs = stats.frames > 1 ? jitterSum / Double(stats.frames - 1) : 0
        NSLog("[audio] stopped: playout target %.0f ms, underruns %d, trimmed %.0f ms, lost %d, frames %d, jitter %.1f ms, worst gap %.0f ms",
              stats.playoutMs, stats.underruns, stats.trimmedMs, stats.lost, stats.frames, stats.jitterMs, stats.worstGapMs)
    }

    private func receiveLocked(codec: Int, seq: UInt16, payload: Data) {
        guard running, let coder, codec == coder.id.rawValue else { return }
        if let last = lastSeq {
            let gap = Int(Int16(bitPattern: seq &- last))
            if gap <= 0 { return }               // late / duplicate: drop
            if gap > 1 { stats.lost += gap - 1 }
        }
        lastSeq = seq
        let now = DispatchTime.now().uptimeNanoseconds
        if lastArrival != 0 {
            let gap = Double(now - lastArrival) / 1e6
            jitterSum += abs(gap - 20)
            stats.worstGapMs = max(stats.worstGapMs, gap)
        }
        lastArrival = now
        stats.frames += 1
        let pcm = coder.decode(payload)
        if ringbackAudible {
            // Network ringback or the answer is audible: stop the local tone.
            let energy = pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, pcm.count))
            if energy.squareRoot() > 300 {
                flags { heardRemote = true; _ringback = false }
                NSLog("[audio] far end audible: local ringback off")
            }
        }
        playout.push(pcm)
    }

    private func drainCapture() {
        guard running, let coder, let conv = captureConverter, let format = captureFormat, let mono = captureMono else { return }
        let n = captureRing.available
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(captureRing.read(into: buf.floatChannelData![0], n))
        let ratio = format.sampleRate / mono.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        captureAcc.append(contentsOf: UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
        let frame = Int(coder.rate / 50)
        let silent = muted
        while captureAcc.count >= frame {
            let chunk = silent ? [Int16](repeating: 0, count: frame) : Array(captureAcc.prefix(frame))
            captureAcc.removeFirst(frame)
            if let payload = coder.encode(chunk) {
                onCapturedFrame?(coder.id.rawValue, seq, payload)
                seq &+= 1
            }
        }
    }

    /// 425 Hz, 1 s on / 4 s off (the ITU-recommended ringback used by Iranian and most European networks).
    private func fillRingback(_ out: UnsafeMutablePointer<Float>, count: Int, rate: Double) {
        for i in 0..<count {
            // 1 s on / 4 s off with 5 ms ramps at each edge (no clicks).
            let pos = ringClock % Int(rate * 5), edge = Int(rate * 0.005)
            let env: Double = pos >= Int(rate) ? 0 : Double(min(pos, Int(rate) - pos, edge)) / Double(edge)
            out[i] = Float(0.12 * env * sin(ringPhase))
            ringPhase += 2 * .pi * 425 / rate
            if ringPhase > 2 * .pi { ringPhase -= 2 * .pi }
            ringClock += 1
        }
    }
}
