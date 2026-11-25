import Foundation
import HaruSpeechCpp

final class HaruSpeechCppSession: HaruFrameSession {
    private final class Output {
        var samples: [Float] = []
        var text = ""
    }

    private static let maxSeconds = 120
    private let model: OpaquePointer
    private let dialogue: OpaquePointer
    private let output: Output
    private var turnTaking = HaruTurnTaking()
    private var speechOutput: HaruSpeechOutput
    let first: [Float]

    var maxInputFrames: Int { Self.maxSeconds * 24_000 / HaruSession.frameSamples - 1 }
    var lastText: String { output.text }

    init(model file: URL, reference: URL, instructions: String? = nil, seed: UInt64, isCancelled: () -> Bool) throws {
        var parameters: OpaquePointer?
        try Self.check(haru_speech_load_params_new(&parameters))
        defer { haru_speech_load_params_free(parameters) }
        try Self.check(haru_speech_load_params_set_device(parameters, "MTL0"))
        try Self.check(haru_speech_load_params_set_warmup(parameters, 1))
        var loaded: OpaquePointer?
        var stream: OpaquePointer?
        let output = Output()
        var keep = false
        defer {
            if !keep {
                haru_speech_dialogue_free(stream)
                haru_speech_model_free(loaded)
            }
        }
        try Self.check(haru_speech_model_load(file.path, parameters, &loaded))
        guard let loaded else { throw HaruError.invalidPack("GGUF") }
        guard !isCancelled() else { throw CancellationError() }
        var info: OpaquePointer?
        try Self.check(haru_speech_model_get_info(loaded, &info))
        defer { haru_speech_model_info_free(info) }
        guard let architecture = haru_speech_model_info_architecture(info), String(cString: architecture) == "haru" else {
            throw HaruError.invalidPack("Haru-4BのGGUFを選んでください")
        }
        try Self.check(haru_speech_voice_add(loaded, "reference", reference.path))
        guard !isCancelled() else { throw CancellationError() }

        var request: OpaquePointer?
        try Self.check(haru_speech_request_new(loaded, &request))
        defer { haru_speech_request_free(request) }
        // The MLX card has the same fields. The speech.cpp renderer tokenizes them for this GGUF.
        let card: [(speech_option, String)] = [
            (SPEECH_OPT_LANGUAGE, "ja"),
            (SPEECH_OPT_VOICE, "reference"),
            (SPEECH_OPT_NAME, "ハル"),
            (SPEECH_OPT_PERSONA, "自分はハル。気さくで聞き上手。日本語の普段の話し言葉で話す。"),
            (SPEECH_OPT_BACKCHANNEL, "low"),
            (SPEECH_OPT_OTHER_NAME, "未設定"),
            (SPEECH_OPT_RELATIONSHIP, "気軽に話せる友人同士。"),
            (SPEECH_OPT_SITUATION, instructions ?? HaruConversationInstructions.defaultText),
        ]
        for (option, value) in card {
            try Self.check(haru_speech_request_set_string(request, option, value))
        }
        try Self.check(haru_speech_request_set_int(request, SPEECH_OPT_SEED, Int64(seed & ((1 << 53) - 1))))
        try Self.check(haru_speech_request_set_float(request, SPEECH_OPT_TEMPERATURE, Double(HaruSession.conversationTemperature)))
        try Self.check(haru_speech_request_set_float(request, SPEECH_OPT_EOP_BIAS, Double(HaruSession.conversationEndOfPauseBias)))
        try Self.check(haru_speech_request_set_float(request, SPEECH_OPT_MAX_SECONDS, Double(Self.maxSeconds)))

        let context = Unmanaged.passUnretained(output).toOpaque()
        try Self.check(haru_speech_dialogue_start(request, Int32(HaruSession.sampleRate), { samples, count, text, context in
            guard let samples, count == HaruSession.frameSamples, let context else { return 1 }
            let output = Unmanaged<Output>.fromOpaque(context).takeUnretainedValue()
            output.samples = Array(UnsafeBufferPointer(start: samples, count: count))
            output.text = text.map { String(cString: $0) } ?? ""
            return 0
        }, context, &stream))
        guard let stream, output.samples.count == HaruSession.frameSamples else { throw HaruError.audioFormat }
        guard !isCancelled() else { throw CancellationError() }
        var first = output.samples
        var gate = HaruSpeechOutput()
        let flags = haru_speech_dialogue_haru_last_frame_flags(stream)
        _ = gate.process(&first, hasText: flags & SPEECH_HARU_TEXT.rawValue != 0)
        model = loaded
        dialogue = stream
        self.first = first
        speechOutput = gate
        self.output = output
        keep = true
    }

    deinit {
        haru_speech_dialogue_free(dialogue)
        haru_speech_model_free(model)
    }

    func infer(_ samples: [Float]) throws -> [Float] {
        guard samples.count == HaruSession.frameSamples else { throw HaruError.audioFormat }
        let turn: speech_haru_turn
        switch turnTaking.observe(samples) {
        case .normal: turn = turnTaking.isUserSpeaking ? SPEECH_HARU_LISTENING : SPEECH_HARU_NORMAL
        case .start: turn = SPEECH_HARU_START_REPLY
        case .continueReply: turn = SPEECH_HARU_CONTINUE_REPLY
        }
        output.samples.removeAll(keepingCapacity: true)
        output.text = ""
        try samples.withUnsafeBufferPointer {
            try Self.check(haru_speech_dialogue_push_haru(dialogue, $0.baseAddress, $0.count, turn))
        }
        guard output.samples.count == HaruSession.frameSamples else { throw HaruError.audioFormat }
        let flags = haru_speech_dialogue_haru_last_frame_flags(dialogue)
        let hasText = flags & SPEECH_HARU_TEXT.rawValue != 0
        let isEndOfPause = flags & SPEECH_HARU_END_OF_PAUSE.rawValue != 0
        var frame = output.samples
        _ = speechOutput.process(&frame, hasText: hasText)
        turnTaking.didGenerate(frame, isText: hasText, isEndOfPause: isEndOfPause)
        return frame
    }

    func resetTurnTaking() {
        turnTaking = HaruTurnTaking()
        speechOutput = HaruSpeechOutput()
    }

    private static func check(_ status: speech_status) throws {
        guard status == SPEECH_OK else {
            let message = haru_speech_last_error().map { String(cString: $0) } ?? "実行に失敗しました"
            throw HaruError.invalidPack("speech.cpp: \(message)")
        }
    }
}
