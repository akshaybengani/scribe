import AVFoundation
import ScreenCaptureKit
import CoreMedia
import SwiftUI

// MARK: - Writing and metering (usable from audio threads)

/// Takes buffers in any format and writes 16 kHz mono AAC, the small speech-quality file the app stores.
final class AACWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private(set) var frames: Int64 = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        file = f
        format = f.processingFormat
    }

    func write(_ buf: AVAudioPCMBuffer) {
        guard let file, buf.frameLength > 0 else { return }
        if converter == nil || converterInput != buf.format {
            converter = AVAudioConverter(from: buf.format, to: format)
            converterInput = buf.format
        }
        guard let conv = converter else { return }
        let ratio = format.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buf
        }
        if status != .error, out.frameLength > 0 {
            try? file.write(from: out)
            frames += Int64(out.frameLength)
        }
    }

    /// Closes the file; AAC data is only finalised when the file object is released.
    func finish() { file = nil }
    var seconds: Double { Double(frames) / format.sampleRate }
}

/// Holds the loudest recent value so the UI timer can sample it without touching audio threads.
final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func update(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_001))             // about -60 (silence) ... 0 (loud)
        let level = pow(max(0, min(1, (db + 55) / 55)), 1.6)  // emphasise speech over room noise
        lock.lock(); peak = max(peak, level); lock.unlock()
    }

    func take() -> Float {
        lock.lock(); defer { lock.unlock() }
        let v = peak
        peak = 0
        return v
    }
}

/// Channel 0 of a multichannel float buffer, as a mono buffer at the same sample rate.
func firstChannel(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let src = buf.floatChannelData,
          let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength),
          let dst = out.floatChannelData else { return nil }
    let n = Int(buf.frameLength)
    if buf.format.isInterleaved {
        let stride = Int(buf.format.channelCount)
        for i in 0..<n { dst[0][i] = src[0][i * stride] }
    } else {
        dst[0].update(from: src[0], count: n)
    }
    out.frameLength = buf.frameLength
    return out
}

final class PauseFlag: @unchecked Sendable {
    var paused = false
}

/// Mixes the microphone and computer audio into one 16 kHz mono file.
///
/// The microphone buffers come straight from a tap on the engine's input node, which is the only
/// graph that reliably delivers audio (routing the input through a mixer node returned digital
/// silence on macOS 26 and 27). The microphone is the clock: for every microphone chunk, the same
/// number of computer audio samples is taken from a small queue and added. A gap in computer audio
/// simply adds silence, and a gap in the microphone never stalls the file.
final class MonoMixer: @unchecked Sendable {
    private let writer: AACWriter
    private let lock = NSLock()
    private var system: [Float] = []
    private let maxQueued = 16_000 * 2                 // never let computer audio lag the mic by more than 2 s
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var micConv: AVAudioConverter?
    private var micIn: AVAudioFormat?
    private var sysConv: AVAudioConverter?
    private var sysIn: AVAudioFormat?
    /// No microphone: computer audio is written as it arrives, and `padSilence` keeps the clock.
    private let systemOnly: Bool
    /// Samples written so far. Only read in system-only mode, where every write holds `lock`.
    private var written = 0

    init(writer: AACWriter, systemOnly: Bool = false) {
        self.writer = writer
        self.systemOnly = systemOnly
    }

    func pushMic(_ buf: AVAudioPCMBuffer) {
        guard let samples = Self.mono16k(buf, to: target, conv: &micConv, last: &micIn), !samples.isEmpty else { return }
        var out = samples
        lock.lock()
        let n = min(out.count, system.count)
        if n > 0 {
            for i in 0..<n { out[i] += system[i] }
            system.removeFirst(n)
        }
        lock.unlock()
        write(out)
    }

    func pushSystem(_ buf: AVAudioPCMBuffer) {
        guard let samples = Self.mono16k(buf, to: target, conv: &sysConv, last: &sysIn), !samples.isEmpty else { return }
        lock.lock()
        if systemOnly {
            write(samples)
            lock.unlock()
            return
        }
        system.append(contentsOf: samples)
        if system.count > maxQueued { system.removeFirst(system.count - maxQueued) }
        lock.unlock()
    }

    /// System-only mode: computer audio may send nothing while the Mac is silent. Writes silence up to
    /// `seconds` of recorded (unpaused) time, so the file keeps real time and the timer keeps moving.
    func padSilence(toSeconds seconds: Double) {
        guard systemOnly else { return }
        lock.lock()
        let missing = min(Int(seconds * 16_000) - written, 16_000 * 5)
        if missing > 0 { write([Float](repeating: 0, count: missing)) }
        lock.unlock()
    }

    private func write(_ samples: [Float]) {
        guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { return }
        for i in 0..<samples.count { dst[i] = max(-1, min(1, samples[i])) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        writer.write(buf)
        written += samples.count
    }

    /// Converts any buffer to 16 kHz mono float samples. Each source keeps its own converter.
    private static func mono16k(_ buf: AVAudioPCMBuffer, to target: AVAudioFormat,
                                conv: inout AVAudioConverter?, last: inout AVAudioFormat?) -> [Float]? {
        guard buf.frameLength > 0 else { return nil }
        if conv == nil || last != buf.format {
            conv = AVAudioConverter(from: buf.format, to: target)
            last = buf.format
        }
        guard let c = conv else { return nil }
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        c.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

// MARK: - System audio (Teams, Meet, browser calls) via ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    private var stream: SCStream?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let state: PauseFlag
    private let queue = DispatchQueue(label: "scribe.system-audio")
    private var converter: AVAudioConverter?
    var onStop: (@Sendable (String) -> Void)?

    init(state: PauseFlag, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        self.state = state
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw TranscribeError.message("No display found to capture system audio from.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true      // never record Scribe's own playback
        cfg.width = 2; cfg.height = 2               // video is required by the API but unused
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, !state.paused, let buf = pcm(from: sampleBuffer) else { return }
        onBuffer(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error.localizedDescription)
    }

    /// CMSampleBuffer from ScreenCaptureKit -> 48 kHz stereo float buffer the mixer expects.
    private func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let inFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        if inFormat == Self.format { return buf }

        if converter == nil || converter?.inputFormat != inFormat { converter = AVAudioConverter(from: inFormat, to: Self.format) }
        guard let conv = converter,
              let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames + 1024) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buf
        }
        return out.frameLength > 0 ? out : nil
    }
}

// MARK: - Recorder

/// Records the microphone, and optionally everything the Mac is playing (Teams, Meet, browser calls),
/// mixed into one mono AAC file. Each source has its own level meter for the waveform lanes.
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var micLevels: [Float] = []
    @Published private(set) var systemLevels: [Float] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var hasSystemAudio = false
    /// False for a computer-audio-only recording.
    @Published private(set) var hasMic = false
    @Published var micDenied = false
    @Published var screenDenied = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var mixer: MonoMixer?
    private var heardMic = false
    private var writer: AACWriter?
    private var capture: SystemAudioCapture?
    private var timer: Timer?
    private let micMeter = Meter()
    private let sysMeter = Meter()
    private let flag = PauseFlag()
    private let maxLevels = 600
    private var micTapInstalled = false
    /// Unpaused recording time, for padding a computer-audio-only file with silence.
    private var activeSince: Date?
    private var activeBefore: Double = 0
    private var activeSeconds: Double { activeBefore + (activeSince.map { Date().timeIntervalSince($0) } ?? 0) }

    /// True while the microphone runs through Apple's voice processing (echo cancellation).
    @Published private(set) var echoCancelling = false

    func start(to url: URL, withMic: Bool = true, withSystemAudio: Bool, echoCancel: Bool = true) async -> Bool {
        errorMessage = nil
        micDenied = false
        screenDenied = false
        guard withMic || withSystemAudio else {
            errorMessage = "Turn on the microphone or computer audio to record."
            return false
        }
        if withMic {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                micDenied = true
                return false
            }
        }
        if withSystemAudio && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            screenDenied = true
            return false
        }

        flag.paused = false
        micLevels = []
        systemLevels = []
        elapsed = 0
        do {
            let w = try AACWriter(url: url)
            writer = w

            let mix = MonoMixer(writer: w, systemOnly: !withMic)
            mixer = mix
            heardMic = false
            let flag = self.flag, micMeter = self.micMeter, sysMeter = self.sysMeter
            if withMic {
                let input = engine.inputNode
                // Apple's voice processing (the FaceTime echo canceller) removes whatever this Mac plays,
                // including other apps such as Teams, from the microphone, so speakers are not recorded twice.
                // Measured on a MacBook Air: speaker bleed from another app fell from -14.5 to -48 dBFS.
                echoCancelling = false
                if echoCancel {
                    do {
                        try input.setVoiceProcessingEnabled(true)
                        // Do not turn down the call's own audio while recording.
                        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                        echoCancelling = true
                    } catch {
                        errorMessage = "Echo cancellation could not start, so speaker sound may be recorded twice. Use headphones for this call."
                    }
                } else if input.isVoiceProcessingEnabled {
                    try? input.setVoiceProcessingEnabled(false)
                }
                let inFormat = input.outputFormat(forBus: 0)
                guard inFormat.sampleRate > 0 else {
                    errorMessage = "No microphone input is available."
                    cleanup()
                    return false
                }

                // A plain tap on the input node. Do not connect the input to a mixer: that graph delivers
                // digital silence. The engine has no output, so nothing is ever played back.
                // With voice processing the input has several channels: channel 0 is the cleaned voice, the
                // rest are reference signals that still contain the speakers. Keep channel 0 only.
                let cleanOnly = echoCancelling && inFormat.channelCount > 1
                input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { raw, _ in
                    guard let buf = cleanOnly ? firstChannel(raw) : raw else { return }
                    micMeter.update(buf)
                    if !flag.paused { mix.pushMic(buf) }
                }
                micTapInstalled = true
                engine.prepare()
                try engine.start()
            }
            hasMic = withMic

            if withSystemAudio {
                let cap = SystemAudioCapture(state: flag) { buf in
                    sysMeter.update(buf)
                    mix.pushSystem(buf)
                }
                cap.onStop = { [weak self] message in
                    Task { @MainActor in self?.errorMessage = "Computer audio capture stopped: \(message)" }
                }
                do {
                    try await cap.start()
                    capture = cap
                    hasSystemAudio = true
                } catch {
                    // Without the microphone there is nothing left to record.
                    if !withMic {
                        errorMessage = "Computer audio could not start (\(error.localizedDescription))."
                        screenDenied = true
                        cleanup()
                        return false
                    }
                    // Mic-only is still useful; say so instead of failing the whole recording.
                    errorMessage = "Computer audio could not start (\(error.localizedDescription)). Recording the microphone only."
                    screenDenied = true
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            cleanup()
            return false
        }

        isRecording = true
        isPaused = false
        activeBefore = 0
        activeSince = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard isRecording, !isPaused else { return }
        if hasMic {
            let level = micMeter.take()
            if level > 0.001 { heardMic = true }
            // Exactly zero for the first seconds means the system is handing us silence, not a quiet room.
            // Voice processing also suppresses room noise, so allow longer before calling it silence.
            if !heardMic, elapsed > (echoCancelling ? 15 : 4), errorMessage == nil {
                errorMessage = "The microphone is delivering silence. Check System Settings, Privacy and Security, Microphone, that Scribe is switched on and that the right input device is chosen in Sound settings."
            }
            micLevels.append(level)
            if micLevels.count > maxLevels { micLevels.removeFirst(micLevels.count - maxLevels) }
        } else {
            // Half a second of slack so real computer audio that is still on its way is never overwritten.
            mixer?.padSilence(toSeconds: activeSeconds - 0.5)
        }
        if hasSystemAudio {
            systemLevels.append(sysMeter.take())
            if systemLevels.count > maxLevels { systemLevels.removeFirst(systemLevels.count - maxLevels) }
        }
        elapsed = writer?.seconds ?? elapsed
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        flag.paused = isPaused
        if isPaused {
            activeBefore = activeSeconds
            activeSince = nil
        } else {
            activeSince = Date()
        }
    }

    /// Stops and returns the recorded length in seconds.
    func stop() async -> Double {
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        let cap = capture
        capture = nil
        await cap?.stop()
        let duration = writer?.seconds ?? elapsed
        cleanup()
        // Back to an idle screen: no leftover timer or waveform from the recording that just ended.
        elapsed = 0
        micLevels = []
        systemLevels = []
        return duration
    }

    private func cleanup() {
        if micTapInstalled { engine.inputNode.removeTap(onBus: 0) }
        micTapInstalled = false
        if engine.isRunning { engine.stop() }
        activeSince = nil
        mixer = nil
        writer?.finish()
        writer = nil
        hasSystemAudio = false
        hasMic = false
        echoCancelling = false
    }
}

// MARK: - Playback

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        current = 0
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            p.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        timer?.invalidate()
        isPlaying = false
        current = 0
    }

    func seek(_ t: Double) {
        player?.currentTime = max(0, min(t, duration))
        current = player?.currentTime ?? 0
    }

    private func tick() { current = player?.currentTime ?? 0 }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.current = 0
        }
    }
}

// MARK: - Waveform

/// Voice Memos style: a thin centre line with rounded vertical bars that grow with loudness,
/// newest on the right, scrolling left.
struct WaveformView: View {
    let levels: [Float]
    var active: Bool
    var tint: Color = .red

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let barWidth: CGFloat = 3, gap: CGFloat = 2.5
            let step = barWidth + gap
            let fit = max(1, Int(size.width / step))

            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

            let shown = levels.suffix(fit)
            var x = size.width - CGFloat(shown.count) * step
            for v in shown {
                let h = max(3, CGFloat(v) * (size.height - 8))
                let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(active ? tint : .secondary.opacity(0.6)))
                x += step
            }
        }
        .accessibilityLabel("Audio level waveform")
    }
}
