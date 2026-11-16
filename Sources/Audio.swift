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

final class PauseFlag: @unchecked Sendable {
    var paused = false
}

// MARK: - System audio (Teams, Meet, browser calls) via ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    private var stream: SCStream?
    private let player: AVAudioPlayerNode
    private let state: PauseFlag
    private let queue = DispatchQueue(label: "scribe.system-audio")
    private var converter: AVAudioConverter?
    var onStop: (@Sendable (String) -> Void)?

    init(player: AVAudioPlayerNode, state: PauseFlag) {
        self.player = player
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
        player.scheduleBuffer(buf, completionHandler: nil)
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
    @Published var micDenied = false
    @Published var screenDenied = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var mixer: AVAudioMixerNode?
    private var player: AVAudioPlayerNode?
    private var writer: AACWriter?
    private var capture: SystemAudioCapture?
    private var timer: Timer?
    private let micMeter = Meter()
    private let sysMeter = Meter()
    private let flag = PauseFlag()
    private let maxLevels = 600

    func start(to url: URL, withSystemAudio: Bool) async -> Bool {
        errorMessage = nil
        micDenied = false
        screenDenied = false
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            micDenied = true
            return false
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

            let mix = AVAudioMixerNode()
            engine.attach(mix)
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else {
                errorMessage = "No microphone input is available."
                cleanup()
                return false
            }
            engine.connect(input, to: mix, format: inFormat)
            // The mixer must reach the output for the engine to run it; silence the output so the
            // microphone is never played back through the speakers.
            engine.connect(mix, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0

            let flag = self.flag, micMeter = self.micMeter, sysMeter = self.sysMeter
            mix.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
                if !flag.paused { w.write(buf) }
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buf, _ in micMeter.update(buf) }
            mixer = mix

            if withSystemAudio {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: mix, format: SystemAudioCapture.format)
                p.installTap(onBus: 0, bufferSize: 2048, format: SystemAudioCapture.format) { buf, _ in sysMeter.update(buf) }
                player = p
            }

            engine.prepare()
            try engine.start()

            if withSystemAudio, let p = player {
                p.play()
                let cap = SystemAudioCapture(player: p, state: flag)
                cap.onStop = { [weak self] message in
                    Task { @MainActor in self?.errorMessage = "Computer audio capture stopped: \(message)" }
                }
                do {
                    try await cap.start()
                    capture = cap
                    hasSystemAudio = true
                } catch {
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard isRecording, !isPaused else { return }
        micLevels.append(micMeter.take())
        if micLevels.count > maxLevels { micLevels.removeFirst(micLevels.count - maxLevels) }
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
        return duration
    }

    private func cleanup() {
        mixer?.removeTap(onBus: 0)
        engine.inputNode.removeTap(onBus: 0)
        player?.removeTap(onBus: 0)
        player?.stop()
        if engine.isRunning { engine.stop() }
        if let m = mixer { engine.detach(m) }
        if let p = player { engine.detach(p) }
        mixer = nil
        player = nil
        writer?.finish()
        writer = nil
        hasSystemAudio = false
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
