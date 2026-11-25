import AVFoundation
import Synchronization

public enum HaruReferenceVoice: Sendable {
    case male, female

    public var url: URL? {
        let name = self == .male ? "ja-conversation-reference" : "ja-conversation-reference-female"
        return Bundle.module.url(forResource: name, withExtension: "wav")
    }

    public static func importFile(from source: URL, to destination: URL) throws {
        try readHaruFile(at: source) { try HaruAudio.importReference(from: $0, to: destination) }
    }
}

private final class HaruMicInput {
    private static let slots = 16
    private static let maxFrames = 4096
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let samples: UnsafeMutablePointer<Float>
    private let counts: UnsafeMutablePointer<Int>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let source: DispatchSourceUserDataAdd
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let capture: ([Float], Double) -> Void
    private let level: (Float) -> Void
    private var lastLevelTime = 0.0

    init(source format: AVAudioFormat, format target: AVAudioFormat,
         capture: @escaping ([Float], Double) -> Void, level: @escaping (Float) -> Void) throws {
        // Downmix in the callback and convert the sample rate on a separate queue.
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(Self.maxFrames)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity:
                AVAudioFrameCount(ceil(Double(Self.maxFrames) * target.sampleRate / mono.sampleRate)) + 64),
              let converter = AVAudioConverter(from: mono, to: target) else { throw HaruError.audioFormat }
        self.input = input
        self.output = output
        self.converter = converter
        self.capture = capture
        self.level = level
        samples = .allocate(capacity: Self.slots * Self.maxFrames)
        counts = .allocate(capacity: Self.slots)
        hostTimes = .allocate(capacity: Self.slots)
        samples.initialize(repeating: 0, count: Self.slots * Self.maxFrames)
        counts.initialize(repeating: 0, count: Self.slots)
        hostTimes.initialize(repeating: 0, count: Self.slots)
        let queue = DispatchQueue(label: "haru.capture", qos: .userInitiated)
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.activate()
    }

    deinit {
        samples.deallocate()
        counts.deallocate()
        hostTimes.deallocate()
    }

    func stop() { source.cancel() }

    // One writer on the Core Audio thread, one reader on the capture queue.
    // The callback copies into preallocated storage and never waits for the model.
    func push(_ buffers: UnsafePointer<AudioBufferList>, count: Int, hostTime: UInt64) {
        guard count > 0, count <= Self.maxFrames else { return }
        let head = writeIndex.load(ordering: .relaxed)
        let next = (head + 1) % Self.slots
        guard next != readIndex.load(ordering: .acquiring) else { return }
        let target = samples.advanced(by: head * Self.maxFrames)
        target.update(repeating: 0, count: count)
        var channels = 0
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let width = Int(buffer.mNumberChannels)
            guard width > 0, Int(buffer.mDataByteSize) >= count * width * MemoryLayout<Float>.size else { continue }
            channels += width
            for i in 0..<count {
                for channel in 0..<width { target[i] += data[i * width + channel] }
            }
        }
        guard channels > 0 else { return }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<count { target[i] *= scale }
        }
        counts[head] = count
        hostTimes[head] = hostTime
        writeIndex.store(next, ordering: .releasing)
        source.add(data: 1)
    }

    private func drain() {
        guard let target = input.floatChannelData?[0] else { return }
        var tail = readIndex.load(ordering: .relaxed)
        while tail != writeIndex.load(ordering: .acquiring) {
            let count = counts[tail]
            let hostTime = hostTimes[tail]
            target.update(from: samples.advanced(by: tail * Self.maxFrames), count: count)
            input.frameLength = AVAudioFrameCount(count)
            tail = (tail + 1) % Self.slots
            readIndex.store(tail, ordering: .releasing)

            output.frameLength = 0
            var sent = false
            let status = converter.convert(to: output, error: nil) { [input] _, state in
                state.pointee = sent ? .noDataNow : .haveData
                if sent { return nil }
                sent = true
                return input
            }
            guard status != .error, output.frameLength > 0, let floats = output.floatChannelData?[0] else { continue }
            let pcm = Array(UnsafeBufferPointer(start: floats, count: Int(output.frameLength)))
            let time = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime)
                : ProcessInfo.processInfo.systemUptime - Double(pcm.count) / output.format.sampleRate
            capture(pcm, time)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelTime >= 0.08 {
                lastLevelTime = now
                let rms = sqrt(pcm.reduce(Float.zero) { $0 + $1 * $1 } / Float(pcm.count))
                let value = min(1, max(0, (20 * log10(max(rms, 0.0001)) + 55) / 45))
                DispatchQueue.main.async { [level] in level(value) }
            }
        }
    }
}

final class HaruAudio {
    let engine = AVAudioEngine()
    let usesVoiceProcessing: Bool
    let playback: HaruPlayback
    private let session = AVAudioSession.sharedInstance()
    private let format = AVAudioFormat(standardFormatWithSampleRate: HaruSession.sampleRate, channels: 1)!
    private var tappedInput: AVAudioInputNode?
    private var sourceNode: AVAudioSourceNode?
    private var mic: HaruMicInput?
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var previousBufferDuration: TimeInterval?
    private var previousEchoPreference: Bool?
    private(set) var startedAt: TimeInterval = 0
    private(set) var routeLatencyMs = 0

    init(voiceProcessing: Bool) {
        usesVoiceProcessing = voiceProcessing
        playback = HaruPlayback(measure: false)
    }

    func start(first: [Float], capture: @escaping ([Float], Double) -> Void,
               level: @escaping (Float) -> Void) throws {
        previous = (session.category, session.mode, session.categoryOptions)
        previousBufferDuration = session.preferredIOBufferDuration
        do {
            try session.setCategory(.playAndRecord, mode: usesVoiceProcessing ? .voiceChat : .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? session.setPreferredIOBufferDuration(0.01)
            if !usesVoiceProcessing, #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
                previousEchoPreference = session.prefersEchoCancelledInput
                try? session.setPrefersEchoCancelledInput(true)
            }
            try session.setActive(true)
            let input = engine.inputNode
            if usesVoiceProcessing { try input.setVoiceProcessingEnabled(true) }
            let source = input.outputFormat(forBus: 0)
            guard source.sampleRate > 0, source.channelCount > 0,
                  source.commonFormat == .pcmFormatFloat32 else { throw HaruError.audioFormat }
            playback.enqueue(first, capturedEnd: 0)
            let sourceNode = AVAudioSourceNode(format: format) { [playback] silence, time, count, buffers in
                guard let buffer = UnsafeMutableAudioBufferListPointer(buffers).first,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self),
                      buffer.mNumberChannels == 1, buffer.mDataByteSize >= count * 4
                else { return kAudio_ParamError }
                let hostTime = time.pointee.mHostTime
                let timestamp = hostTime == 0 ? ProcessInfo.processInfo.systemUptime : AVAudioTime.seconds(forHostTime: hostTime)
                silence.pointee = ObjCBool(playback.render(samples, count: Int(count), at: timestamp))
                return noErr
            }
            self.sourceNode = sourceNode
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            let mic = try HaruMicInput(source: source, format: format, capture: { [playback] samples, time in
                playback.begin(firstCapture: time)
                capture(samples, time)
            }, level: level)
            self.mic = mic
            // Capture from the input node's tap instead of connecting a custom
            // sink node into the input graph. Some iOS routes/devices reject
            // that graph with CoreAudio's opaque "nope" (1852797029) error.
            input.installTap(onBus: 0, bufferSize: 1024, format: source) { buffer, time in
                mic.push(buffer.audioBufferList, count: Int(buffer.frameLength), hostTime: time.hostTime)
            }
            tappedInput = input
            engine.prepare()
            try engine.start()
            startedAt = ProcessInfo.processInfo.systemUptime
            routeLatencyMs = Int(((session.inputLatency + session.outputLatency) * 1000).rounded())
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        engine.stop()
        mic?.stop()
        mic = nil
        if let tappedInput {
            tappedInput.removeTap(onBus: 0)
            self.tappedInput = nil
        }
        if let sourceNode { engine.detach(sourceNode); self.sourceNode = nil }
        if let previous {
            if #available(iOS 18.2, *), let previousEchoPreference {
                try? session.setPrefersEchoCancelledInput(previousEchoPreference)
                self.previousEchoPreference = nil
            }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
            if let previousBufferDuration, previousBufferDuration > 0 {
                try? session.setPreferredIOBufferDuration(previousBufferDuration)
            }
            self.previousBufferDuration = nil
            self.previous = nil
        }
    }

    func restart() throws {
        engine.prepare()
        try engine.start()
    }

    static func readReference(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let count = AVAudioFrameCount(min(file.length, Int64(source.sampleRate * 10)))
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count),
              let format = AVAudioFormat(standardFormatWithSampleRate: HaruSession.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(ceil(Double(count) * format.sampleRate / source.sampleRate)) + 64)
        else { throw HaruError.audioFormat }
        try file.read(into: input, frameCount: count)
        var sent = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            state.pointee = sent ? .endOfStream : .haveData
            if sent { return nil }
            sent = true
            return input
        }
        guard status != .error, let samples = output.floatChannelData?[0], output.frameLength > 0 else {
            if let error { throw error }
            throw HaruError.audioFormat
        }
        let audio = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        guard audio.allSatisfy(\.isFinite) else { throw HaruError.referenceAudio }
        let window = 480
        let voiced = stride(from: 0, to: max(0, audio.count - window + 1), by: window).filter { start in
            audio[start..<(start + window)].reduce(Float.zero) { $0 + $1 * $1 } > Float(window) * 0.00003162
        }
        guard let first = voiced.first, let last = voiced.last, last - first >= window * 10 else {
            throw HaruError.referenceAudio
        }
        return Array(audio[max(0, first - 4800)..<min(audio.count, last + window + 4800)])
    }

    static func importReference(from source: URL, to destination: URL) throws {
        let samples = try readReference(source)
        let format = AVAudioFormat(standardFormatWithSampleRate: HaruSession.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData?[0] else { throw HaruError.referenceAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { target.update(from: base, count: source.count) }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".haru-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeReference(buffer, to: staging)
        try Data(contentsOf: staging).write(to: destination, options: .atomic)
    }

    private static func writeReference(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        if #available(iOS 18.0, *) { file.close() }
    }
}
