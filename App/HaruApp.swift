import HaruKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct HaruApp: App {
    var body: some Scene {
        WindowGroup { ConversationView() }
    }
}

private enum HaruVoice: String, CaseIterable {
    case male, female, custom

    var label: String {
        switch self {
        case .male: "男性"
        case .female: "女性"
        case .custom: "登録済みの声"
        }
    }

    var reference: URL? {
        switch self {
        case .male: HaruReferenceVoice.male.url
        case .female: HaruReferenceVoice.female.url
        case .custom: Self.savedReference
        }
    }

    static let savedReference = URL.applicationSupportDirectory.appending(path: "haru-reference.wav")
}

private struct ConversationView: View {
    private enum ImportKind { case model, reference }

    private struct StoredModel: Identifiable {
        let engine: HaruEngine
        let url: URL
        let location: String
        let bytes: Int?

        var id: URL { url }
    }

    private static let accent = Color(red: 0.55, green: 0.90, blue: 1)
    private static let liveAccent = Color(red: 1, green: 0.57, blue: 0.55)
    private static let actionText = Color(red: 0.05, green: 0.10, blue: 0.17)

    @StateObject private var audio = HaruConversation()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .title2) private var actionIconSize = 28.0
    @AppStorage("haru.modelBookmark") private var bookmark = Data()
    @AppStorage("haru.ggufBookmark") private var ggufBookmark = Data()
    @AppStorage("haru.engine") private var engine: HaruEngine = .mlx
    @AppStorage("haru.voice") private var voice: HaruVoice = .male
    @AppStorage("haru.conversationInstructions") private var instructions: String?
    @State private var model: URL?
    @State private var storedModels: [StoredModel] = []
    @State private var modelToDelete: StoredModel?
    @State private var confirmModelDeletion = false
    @State private var hasCustomVoice = false
    @State private var checkingFiles = true
    @State private var showSettings = false
    @State private var showTiming = false
    @State private var importKind: ImportKind = .model
    @State private var showImporter = false
    @State private var importing = false
    @State private var error: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadProgress: HaruModelDownloadProgress?
    @State private var downloadMessage: String?

    private var canConfigure: Bool { audio.status == .idle && !checkingFiles && !importing && downloadTask == nil }
    private var installed: URL { engine.downloadedModelURL }
    private var isLive: Bool { audio.status == .running }
    private var showEnd: Bool { isLive || audio.status == .paused }
    private var actionAccent: Color { isLive ? Self.liveAccent : Self.accent }
    private var actionEnabled: Bool { !checkingFiles && !importing && audio.status != .closing }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 12) {
                        VStack(spacing: 28) {
                            VStack(spacing: 10) {
                                Text(statusLabel)
                                    .font(.largeTitle.bold())
                                    .accessibilityAddTraits(.isHeader)
                                if let statusHint {
                                    Text(statusHint)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.center)
                            primaryAction
                        }
                        conversationControls
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 56))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                }
            }
            .background {
                LinearGradient(colors: [
                    Color(red: 17 / 255, green: 28 / 255, blue: 53 / 255),
                    Color(red: 9 / 255, green: 14 / 255, blue: 29 / 255),
                    Color(red: 17 / 255, green: 22 / 255, blue: 38 / 255),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            }
            .navigationTitle("Haru-4B")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("設定", systemImage: "slider.horizontal.3") { showSettings = true }
                        .labelStyle(.iconOnly)
                        .disabled(audio.status != .idle)
                }
            }
            .sheet(isPresented: $showSettings) { settings }
            .task {
                restoreFiles()
                checkingFiles = false
            }
            .onChange(of: engine) { _, _ in
                error = nil
                downloadMessage = nil
                restoreFiles()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { downloadTask?.cancel() }
                if phase == .active, canConfigure { restoreFiles() }
            }
            .onChange(of: audio.status) { _, status in
                if status == .idle { showTiming = false }
            }
        }
        .tint(Self.accent)
        .preferredColorScheme(.dark)
    }

    private var statusLabel: String {
        if checkingFiles { return "準備を確認中" }
        if importing { return "ファイルを確認中" }
        if downloadTask != nil { return "モデルを準備中" }
        return switch audio.status {
        case .loading: "会話を準備中"
        case .connecting: "マイクに接続中"
        case .running: "マイクはオン"
        case .idle: model == nil ? "モデルの準備" : "マイクはオフ"
        case .paused: "マイクはオフ"
        case .closing: "会話を終了中"
        }
    }

    private var statusHint: String? {
        if checkingFiles || importing { return nil }
        if downloadTask != nil { return downloadStatus }
        return switch audio.status {
        case .idle: model == nil ? "会話するにはモデルが必要です。" : "マイクをオンにすると会話が始まります。"
        case .loading: "モデルを読み込んでいます。"
        case .running: "そのまま日本語で話してください。"
        case .paused: "マイクをオンにすると会話を再開します。"
        case .connecting, .closing: nil
        }
    }

    private var actionLabel: (title: String, icon: String) {
        if downloadTask != nil { return ("ダウンロード状況", "arrow.down.circle") }
        if audio.status == .idle && model == nil { return ("モデルを追加", "plus.circle") }
        return switch audio.status {
        case .loading: ("準備をキャンセル", "xmark")
        case .running, .connecting: ("マイクをオフ", "mic.slash.fill")
        case .idle, .paused, .closing: ("マイクをオン", "mic.fill")
        }
    }

    private var primaryAction: some View {
        let label = actionLabel
        return Button {
            if downloadTask != nil || (audio.status == .idle && model == nil) {
                showSettings = true
            } else {
                toggleMicrophone()
            }
        } label: {
            VStack(spacing: 10) {
                if audio.status == .loading || audio.status == .closing || checkingFiles || importing {
                    ProgressView().tint(Self.actionText).accessibilityHidden(true)
                } else {
                    Image(systemName: label.icon)
                        .font(.system(size: actionIconSize, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(label.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 108)
            .foregroundStyle(Self.actionText)
            .background(actionAccent, in: RoundedRectangle(cornerRadius: 28))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 246)
        .opacity(actionEnabled ? 1 : 0.52)
        .disabled(!actionEnabled)
    }

    @ViewBuilder private var conversationControls: some View {
        VStack(spacing: 4) {
            ProgressView(value: audio.inputLevel)
                .tint(actionAccent)
                .frame(width: 80, height: 14)
                .opacity(isLive ? 1 : 0)
                .accessibilityLabel("マイク入力レベル")
                .accessibilityHidden(!isLive)
            Button("会話を終了", systemImage: "phone.down", action: audio.stop)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
                .opacity(showEnd ? 1 : 0)
                .disabled(!showEnd)
                .accessibilityHidden(!showEnd)
        }
        if let message = error ?? audio.failure?.localizedDescription {
            Text(message)
                .foregroundStyle(Self.liveAccent)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if error == nil, let failure = audio.failure, case HaruError.microphone = failure,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Button("設定でマイクを許可") { openURL(url) }
            }
        }
        if let inferenceMs = audio.inferenceMs {
            DisclosureGroup(isExpanded: $showTiming) {
                VStack(spacing: 5) {
                    LabeledContent("推論の中央値", value: "\(Int(inferenceMs.rounded())) ms")
                    if audio.playbackMs != nil {
                        Text("往復は入力フレームの末尾から対応する出力の再生までの推定です。")
                    }
                }
                .padding(.top, 5)
            } label: {
                if let playbackMs = audio.playbackMs {
                    Label("音声の往復 約 \(playbackMs) ms", systemImage: "clock")
                } else {
                    Label("応答時間", systemImage: "clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .tint(.secondary)
            .frame(maxWidth: 246)
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("会話の指示") {
                        HaruInstructionsEditor(instructions: $instructions)
                    }
                }
                Section("返答の声") {
                    Picker("声", selection: $voice) {
                        ForEach(HaruVoice.allCases.filter { $0 != .custom || hasCustomVoice }, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .disabled(!canConfigure)
                    Button("参照音声をファイルから選ぶ") { choose(.reference) }
                        .disabled(!canConfigure)
                }
                Section("モデル") {
                    Picker("推論エンジン", selection: $engine) {
                        ForEach(HaruEngine.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .disabled(!canConfigure)
                    if downloadTask != nil {
                        ProgressView(value: Double(downloadProgress?.sourceBytesRead ?? 0),
                                     total: Double(engine.downloadBytes)) { Text(downloadStatus) }
                        Button("一時停止") { downloadTask?.cancel() }
                    } else if model == nil {
                        downloadActions
                    } else {
                        Label("モデル準備済み", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        if model != installed {
                            DisclosureGroup("モデルを取得") { downloadActions }
                        }
                    }
                    Button(engine == .mlx ? "Haru-JAフォルダーを選ぶ" : "GGUFファイルを選ぶ") { choose(.model) }
                        .disabled(!canConfigure)
                    if !storedModels.isEmpty {
                        DisclosureGroup("保存したモデルを管理") {
                            ForEach(storedModels) { stored in
                                Button(role: .destructive) {
                                    modelToDelete = stored
                                    confirmModelDeletion = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label("\(stored.engine.label)のモデルを削除", systemImage: "trash")
                                        Text(storageDescription(for: stored))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(!canConfigure)
                    }
                    if let downloadMessage {
                        Text(downloadMessage).font(.footnote)
                    }
                }
                if importing || error != nil {
                    Section {
                        if importing { ProgressView("ファイルを確認中") }
                        if let error { Text(error).foregroundStyle(Self.liveAccent) }
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showSettings = false }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importKind == .reference ? [.audio]
                            : engine == .mlx ? [.folder] : [UTType(filenameExtension: "gguf") ?? .data],
                          onCompletion: importFile)
            .alert("モデルを削除しますか？", isPresented: $confirmModelDeletion, presenting: modelToDelete) { stored in
                Button("削除", role: .destructive) { deleteModel(stored) }
                Button("キャンセル", role: .cancel) {}
            } message: { stored in
                Text("\(stored.engine.label)のモデル（\(storageDescription(for: stored))）をこのアプリから削除します。再び使うには、ダウンロードするかファイルを用意してください。")
            }
            .task {
                if canConfigure { restoreFiles() }
            }
        }
    }

    private func storageDescription(for stored: StoredModel) -> String {
        guard let bytes = stored.bytes else { return stored.location }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(stored.location) · \(size)"
    }

    private func refreshStoredModels() {
        let locations = HaruEngine.allCases.flatMap { engine in
            [(engine, engine.downloadedModelURL, "ダウンロード済み"),
             (engine, engine.sharedModelURL, "ファイル共有で追加")]
        }
        storedModels = locations.compactMap { engine, url, location in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return StoredModel(engine: engine, url: url, location: location, bytes: try? engine.modelBytes(at: url))
        }
    }

    private func deleteModel(_ stored: StoredModel) {
        guard canConfigure else { return }
        let saved = stored.engine == .mlx ? bookmark : ggufBookmark
        var stale = false
        let selected = try? URL(resolvingBookmarkData: saved, options: [.withoutUI], relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        let wasBookmarked = selected?.resolvingSymlinksInPath().path == stored.url.resolvingSymlinksInPath().path
        do {
            try FileManager.default.removeItem(at: stored.url)
            if wasBookmarked {
                if stored.engine == .mlx { bookmark = Data() } else { ggufBookmark = Data() }
            }
            error = nil
            downloadMessage = "\(stored.engine.label)のモデルを削除しました。"
        } catch {
            downloadMessage = error.localizedDescription
        }
        restoreFiles()
    }

    @ViewBuilder private var downloadActions: some View {
        Button(engine.canResumeDownload ? "ダウンロードを再開" : "モデルをダウンロード", action: downloadModel)
            .disabled(!canConfigure)
        Text(engine == .mlx ? "通信量は約10.5 GB。日本語用モデルとして約5.5 GBを保存します。"
             : "Q5_Kを約5.05 GB取得します。Q4_K（約4.52 GB）もGGUFファイルから読み込めます。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if engine.hasPartialDownload {
            Button("途中のデータを削除", role: .destructive, action: deletePartialDownload)
                .disabled(!canConfigure)
        }
    }

    private func restoreFiles() {
        refreshStoredModels()
        let saved = engine == .mlx ? bookmark : ggufBookmark
        model = storedModels.first { $0.engine == engine && $0.bytes != nil }?.url
        if !saved.isEmpty {
            do {
                var stale = false
                let selected = try URL(resolvingBookmarkData: saved, options: [.withoutUI], relativeTo: nil,
                                       bookmarkDataIsStale: &stale)
                if stale {
                    error = "モデルの場所を選び直してください。"
                } else {
                    model = selected
                }
            } catch {
                self.error = "モデルの場所を選び直してください。"
            }
        }
        hasCustomVoice = FileManager.default.fileExists(atPath: HaruVoice.savedReference.path)
        if !hasCustomVoice && voice == .custom { voice = .male }
    }

    private var downloadStatus: String {
        switch downloadProgress?.phase {
        case .downloading, nil: engine == .mlx ? "公式モデルをダウンロード中" : "GGUFをダウンロード中"
        case .converting: "日本語用モデルに変換中"
        case .checking: "モデルを検証中"
        }
    }

    private func downloadModel() {
        #if targetEnvironment(simulator)
        downloadMessage = "モデルの準備はiPhone実機で試してください。"
        #else
        guard canConfigure else { return }
        downloadMessage = nil
        downloadProgress = nil
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let selected = engine
        downloadTask = Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                let installed = try await selected.prepareModel { progress in
                    await MainActor.run { downloadProgress = progress }
                }
                result = .success(installed)
            } catch {
                result = .failure(error)
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
                downloadTask = nil
                switch result {
                case .success(let installed):
                    if selected == .mlx { bookmark = Data() } else { ggufBookmark = Data() }
                    model = installed
                    refreshStoredModels()
                    error = nil
                    downloadMessage = "モデルを保存しました。"
                case .failure(let failure):
                    downloadMessage = cancelled ? "ダウンロードを一時停止しました。" : failure.localizedDescription
                }
            }
        }
        #endif
    }

    private func deletePartialDownload() {
        guard canConfigure else { return }
        do {
            try engine.discardPartialDownload()
            downloadProgress = nil
            downloadMessage = "途中のデータを削除しました。"
        } catch {
            downloadMessage = error.localizedDescription
        }
    }

    private func choose(_ kind: ImportKind) {
        error = nil
        importKind = kind
        showImporter = true
    }

    private func importFile(_ result: Result<URL, Error>) {
        let kind = importKind
        let selectedEngine = engine
        importing = true
        Task {
            defer { importing = false }
            do {
                let url = try result.get()
                let newBookmark = try await Task.detached(priority: .userInitiated) { () -> Data? in
                    if kind == .model {
                        _ = try selectedEngine.modelBytes(at: url)
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
                    }
                    let destination = HaruVoice.savedReference
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try HaruReferenceVoice.importFile(from: url, to: destination)
                    return nil
                }.value
                if let newBookmark {
                    if selectedEngine == .mlx { bookmark = newBookmark } else { ggufBookmark = newBookmark }
                    model = url
                } else {
                    hasCustomVoice = true
                    voice = .custom
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func toggleMicrophone() {
        error = nil
        switch audio.status {
        case .idle:
            guard let model, let reference = voice.reference else { return }
            do { try audio.start(engine: engine, model: model, reference: reference, instructions: instructions) }
            catch { self.error = error.localizedDescription }
        case .running, .connecting:
            audio.mute()
        case .paused:
            audio.resume()
        case .loading:
            audio.stop()
        case .closing:
            break
        }
    }
}

private struct HaruInstructionsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var instructions: String?
    @State private var draft: String

    init(instructions: Binding<String?>) {
        _instructions = instructions
        _draft = State(initialValue: instructions.wrappedValue ?? HaruConversationInstructions.defaultText)
    }

    private var normalized: String { HaruConversationInstructions.normalize(draft) }
    private var isValid: Bool { HaruConversationInstructions.isValid(normalized) }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 190)
                    .accessibilityLabel("会話の指示")
            } footer: {
                if isValid {
                    Text("保存すると次に始める会話から反映されます。空欄で保存すると、この指示を省きます。")
                } else if normalized.unicodeScalars.count > HaruConversationInstructions.characterLimit {
                    Text("\(HaruConversationInstructions.characterLimit)文字以内にしてください。")
                } else {
                    Text("使えない文字が含まれています。")
                }
            }
            Section {
                Button("デフォルトに戻す") {
                    instructions = nil
                    draft = HaruConversationInstructions.defaultText
                }
                .disabled(instructions == nil && draft == HaruConversationInstructions.defaultText)
            }
        }
        .navigationTitle("会話の指示")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    instructions = normalized == HaruConversationInstructions.defaultText ? nil : normalized
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }
}
