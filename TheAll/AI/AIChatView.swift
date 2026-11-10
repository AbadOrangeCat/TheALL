import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

struct AIModelPicker: View {
    @Bindable var session: AITerminalSession
    @Binding var selection: String
    var showsRefresh = true

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("ai.model"), selection: $selection) {
                Text(L10n.string("ai.models.default")).tag("")
                if !selection.isEmpty, !session.models.contains(where: { $0.id == selection }) {
                    Text(selection).tag(selection)
                }
                ForEach(session.models.filter { !$0.id.isEmpty }) { model in Text(model.title).tag(model.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .frame(minWidth: 96, maxWidth: 300, alignment: showsRefresh ? .leading : .trailing)
            if showsRefresh {
                if session.isLoadingModels { ProgressView().controlSize(.small) }
                Button { session.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(session.isLoadingModels)
                    .help(L10n.string("ai.models.refresh"))
                    .accessibilityLabel(L10n.string("ai.models.refresh"))
            }
        }
    }
}

enum AIChatCompletionLabel {
    static func text(for message: AIChatMessage, locale: Locale) -> String? {
        guard message.role == .assistant, let raw = message.completedAt,
              let duration = message.durationMs, duration.isFinite, duration >= 0 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var completed = parser.date(from: raw)
        if completed == nil {
            parser.formatOptions = [.withInternetDateTime]
            completed = parser.date(from: raw)
        }
        guard let completed else { return nil }
        let date = DateFormatter()
        date.locale = locale
        date.dateStyle = .short
        date.timeStyle = .medium
        let elapsed = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        elapsed.calendar = calendar
        elapsed.allowedUnits = duration >= 3_600_000 ? [.hour, .minute, .second] :
            duration >= 60_000 ? [.minute, .second] : [.second]
        elapsed.unitsStyle = .abbreviated
        elapsed.zeroFormattingBehavior = .dropAll
        let seconds = min(duration / 1_000, 315_576_000)
        let durationText = elapsed.string(from: max(1, seconds.rounded(.up))) ?? "1s"
        let statusKey = message.completionStatus == "failed" ? "ai.chat.failedAt" :
            message.completionStatus == "interrupted" ? "ai.chat.stoppedAt" : "ai.chat.completedAt"
        let timing = L10n.string(statusKey, date.string(from: completed)) + " · " + L10n.string("ai.chat.duration", durationText)
        guard let effort = message.reasoningEffort, !effort.isEmpty else { return timing }
        return timing + " · " + L10n.string(message.reasoningEffortVerified ? "ai.effort.confirmed" : "ai.effort.requested", effort)
    }
}

struct AIChatView: View {
    @Bindable var session: AITerminalSession
    @Bindable var chat: AIChatSession
    var onFocus: () -> Void
    var onEdit: () -> Void
    var onChooseDirectory: () -> Void = {}
    var onRestoreLegacy: (AIChatLegacyConversation) -> Void = { _ in }
    @Bindable var presentation: AIChatPresentation
    let region: Region
    var contentWidth: CGFloat? = nil
    enum Region { case header, composer, welcome, status, jump }
    private var theme: AppTheme { session.theme }

    var body: some View {
        let _ = session.locale
        Group {
            switch region {
            case .header: header
            case .composer: composer
            case .welcome: welcome
            case .status: thinkingStatus
            case .jump: jumpButton
            }
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Color(nsColor: theme.textPrimary))
        .background { if region != .jump { Color(nsColor: theme.canvas) } }
        .tint(Color(nsColor: theme.accent))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onDrop(of: [.fileURL, .image], isTargeted: $presentation.photoDropTargeted, perform: dropPhotos)
        .overlay {
            if !presentation.importingPhotos, presentation.photoDropTargeted || presentation.editorPhotoDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: theme.accentMuted).opacity(0.8))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: theme.accent), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    Label(L10n.string("ai.files.drop"), systemImage: "paperclip")
                        .font(.headline).padding(16)
                        .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: 8))
                }.padding(6).allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack {
            Label(session.provider?.tool ?? "AI", systemImage: "sparkles")
                .font(Font(DT.Font.title))
            Spacer(minLength: 8)
            Button(action: onEdit) {
                Label(L10n.string("ai.settings"), systemImage: "slider.horizontal.3")
                    .font(Font(DT.Font.smallB)).frame(minHeight: DT.Chat.controlHeight)
            }.buttonStyle(.borderless)
        }
        .padding(.horizontal, DT.Space.lg)
        .padding(.vertical, DT.Space.xs)
        .background(Color(nsColor: theme.sidebar))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: theme.border)).frame(height: DT.Stroke.hairline) }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let error = chat.errorMessage {
                Text(error).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = session.historyError {
                Text(error).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !chat.approvals.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(chat.approvals) { approval in
                            AIQuestionCard(approval: approval, theme: theme) { allow, answers in
                                chat.answerApproval(approval.id, allow: allow, answers: answers)
                            }
                        }
                    }.padding(.horizontal, 16)
                }.frame(maxHeight: 230)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !chat.draftImages.isEmpty {
                    AIChatPhotos(images: chat.draftImages, store: chat.imageStore, theme: theme,
                        onOpen: { presentation.previewPhoto = $0 }, onRemove: { image in
                            chat.draftImages.removeAll { $0.id == image.id }
                        })
                }
                if !chat.draftFiles.isEmpty {
                    AIChatFiles(files: chat.draftFiles, store: chat.fileStore, theme: theme, onRemove: { file in
                        chat.draftFiles.removeAll { $0.id == file.id }
                    })
                }
                if presentation.importingPhotos {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("ai.files.preparing")).font(.caption)
                    }
                }
                if let photoError = presentation.photoError {
                    Text(photoError).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                }
                AIChatComposer(text: $chat.input, conversation: ObjectIdentifier(chat),
                    history: { chat.messages.filter { $0.role == .user }.map(\.text) },
                    theme: theme, onFocus: onFocus, onSend: send, onPasteImages: pastePhotos,
                    acceptsPhotoDrops: !presentation.importingPhotos,
                    onPhotoDragTargeted: { presentation.editorPhotoDropTargeted = $0 })
                    .frame(height: DT.Chat.editorHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DT.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DT.Radius.card, style: .continuous)
                        .strokeBorder(Color(nsColor: theme.border), lineWidth: DT.Stroke.hairline))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DT.Space.sm) {
                        directoryControls
                        Spacer(minLength: DT.Space.md)
                        modelControls(showsStop: true)
                    }
                    VStack(alignment: .leading, spacing: DT.Space.sm) {
                        HStack(spacing: DT.Space.sm) {
                            directoryControls
                            Spacer(minLength: 0)
                            if chat.isBusy { stopButton }
                        }
                        HStack(spacing: DT.Space.sm) {
                            Spacer(minLength: 0)
                            modelControls(showsStop: false)
                        }
                    }
                }
                HStack(alignment: .top) {
                    if !chat.isReady, chat.errorMessage == nil {
                        Text(L10n.string("ai.chat.connecting"))
                    } else if chat.showsModelChangeHint {
                        Text(L10n.string("ai.chat.modelHint"))
                    }
                    Spacer(minLength: 8)
                    Text("⌘↩ " + L10n.string(chat.isBusy ? "ai.chat.steer" : "ai.chat.send"))
                }.font(.caption2).foregroundStyle(Color(nsColor: theme.textSecondary))
                if let error = session.modelError {
                    Text(error).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                }
            }
            .frame(maxWidth: DT.Chat.contentWidth)
            .padding(DT.Space.lg)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: theme.sidebar))
            .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: theme.border)).frame(height: DT.Stroke.hairline) }
        }
        .onAppear { if chat.catalogModels.isEmpty, !session.isLoadingModels { session.refreshModels() } }
        .fileImporter(isPresented: $presentation.showsPhotoPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): attachPhotos(urls.map(AIChatAttachmentImport.file))
            case .failure: presentation.photoError = L10n.string("ai.images.unavailable")
            }
        }
        .sheet(item: $presentation.previewPhoto) { image in
            AIChatPhotoPreview(image: image, store: chat.imageStore, theme: theme)
        }
    }

    private var directoryControls: some View {
        HStack(spacing: DT.Space.sm) {
            Button { presentation.showsPhotoPicker = true } label: {
                Image(systemName: "paperclip")
                    .frame(width: DT.Chat.controlHeight, height: DT.Chat.controlHeight)
            }
            .buttonStyle(.borderless)
            .disabled(presentation.importingPhotos || (chat.draftImages.count >= AIChatImageStore.maximumCount && chat.draftFiles.count >= AIChatFileStore.maximumCount))
            .help(L10n.string("ai.files.add"))
            .accessibilityLabel(L10n.string("ai.files.add"))
            .accessibilityIdentifier("chat-add-photos")
            Button(action: onChooseDirectory) {
                Label(chat.directory, systemImage: "folder")
                    .font(Font(DT.Font.smallB)).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 72, maxWidth: 220, minHeight: DT.Chat.controlHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: theme.textSecondary))
            .disabled(!chat.canChangeDirectory)
            .help(chat.directory + "\n" + L10n.string(chat.canChangeDirectory ? "ai.directory.choose" : "ai.directory.busy"))
            .accessibilityLabel(L10n.string("ai.directory.choose") + ": " + chat.directory)
        }
    }

    private func modelControls(showsStop: Bool) -> some View {
        HStack(spacing: DT.Space.sm) {
            AIModelPicker(session: session, selection: Binding(get: { chat.model }, set: { session.selectModel($0) }), showsRefresh: false)
            Picker(L10n.string("ai.effort.title"), selection: $chat.reasoningEffort) {
                Text(L10n.string("ai.effort.default")).tag("")
                if !chat.reasoningEffort.isEmpty, !chat.supportedReasoningEfforts.contains(chat.reasoningEffort) {
                    Text(chat.reasoningEffort).tag(chat.reasoningEffort).disabled(true)
                }
                ForEach(chat.supportedReasoningEfforts, id: \.self) { effort in Text(effort).tag(effort) }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.large)
            .frame(minWidth: 64, maxWidth: 130)
            .disabled(chat.supportedReasoningEfforts.isEmpty)
            .help(L10n.string(chat.supportedReasoningEfforts.isEmpty ? "ai.effort.unavailable" : "ai.effort.title"))
            .accessibilityLabel(L10n.string("ai.effort.title"))
            .accessibilityIdentifier("chat-reasoning-effort")
            Button(L10n.string(chat.isBusy ? "ai.chat.steer" : "ai.chat.send"), action: send)
                .buttonStyle(.borderedProminent)
                .disabled(!chat.canSend || presentation.importingPhotos)
                .controlSize(.large).fixedSize()
                .accessibilityIdentifier("chat-submit")
            if chat.isBusy && showsStop { stopButton }
        }
        .frame(minHeight: DT.Chat.controlHeight)
    }

    private var stopButton: some View {
        Button { chat.interrupt() } label: {
            Image(systemName: "stop.fill")
                .frame(width: DT.Chat.controlHeight, height: DT.Chat.controlHeight)
        }
        .buttonStyle(.borderless)
        .disabled(!chat.canInterrupt)
        .help(L10n.string("ai.chat.stop"))
        .accessibilityLabel(L10n.string("ai.chat.stop"))
        .accessibilityIdentifier("chat-stop")
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("ai.chat.welcome")).font(.title2.weight(.semibold))
            Text(L10n.string("ai.chat.welcomeDetail")).font(.callout)
                .foregroundStyle(Color(nsColor: theme.textSecondary))
            if chat.provider == .claude, !chat.isBusy {
                AILegacyHistoryButton(session: session, onRestore: onRestoreLegacy).padding(.top, 8)
            }
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingStatus: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(L10n.string("ai.chat.thinking")).font(.caption.weight(.medium))
            Spacer()
        }.foregroundStyle(Color(nsColor: theme.textSecondary))
    }

    @ViewBuilder private var jumpButton: some View {
        if !presentation.isAtBottom, !chat.visibleMessages.isEmpty {
            Button { presentation.forceScroll += 1 } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(nsColor: theme.sidebar), in: Circle())
                    .overlay(Circle().stroke(Color(nsColor: theme.borderStrong), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(L10n.string("ai.chat.latest"))
            .accessibilityLabel(L10n.string("ai.chat.latest"))
            .accessibilityIdentifier("chat-scroll-to-bottom")
        }
    }

    private func send() {
        guard !presentation.importingPhotos else { return }
        chat.send()
        presentation.forceScroll += 1
    }

    fileprivate func pastePhotos(_ pasteboard: NSPasteboard) -> Bool {
        guard AIChatAttachmentImport.containsAttachments(pasteboard) else { return false }
        guard let photos = AIChatAttachmentImport.read(pasteboard), !photos.isEmpty else {
            presentation.photoError = L10n.string("ai.files.invalid")
            return true
        }
        attachPhotos(photos)
        return true
    }

    private func dropPhotos(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !presentation.importingPhotos else { return false }
        importPhotos(count: providers.count) { imageStore, fileStore in
            try await AIChatAttachmentImport.importProviders(providers, imageStore: imageStore, fileStore: fileStore)
        }
        return true
    }

    private func attachPhotos(_ sources: [AIChatAttachmentImport]) {
        guard !sources.isEmpty else { return }
        importPhotos(count: sources.count) { imageStore, fileStore in
            try await Task.detached(priority: .userInitiated) {
                try AIChatAttachmentImport.importBatch(sources, imageStore: imageStore, fileStore: fileStore)
            }.value
        }
    }

    private func importPhotos(count: Int, operation: @escaping (AIChatImageStore, AIChatFileStore) async throws -> AIChatAttachmentImport.Batch) {
        guard !presentation.importingPhotos else { return }
        guard count <= AIChatImageStore.maximumCount + AIChatFileStore.maximumCount else {
            presentation.photoError = L10n.string("ai.files.tooMany")
            return
        }
        let target = chat
        guard target.beginAttachmentImport() else { return }
        presentation.importingPhotos = true
        presentation.photoError = nil
        Task { @MainActor in
            defer { presentation.importingPhotos = false; target.endAttachmentImport() }
            do {
                let batch = try await operation(target.imageStore, target.fileStore)
                do {
                    guard target.draftImages.count + batch.images.count <= AIChatImageStore.maximumCount else { throw AIChatImageStore.ImageError.tooMany }
                    try AIChatFileStore.validate(target.draftFiles + batch.files)
                } catch {
                    batch.discard(imageStore: target.imageStore, fileStore: target.fileStore)
                    throw error
                }
                target.draftImages.append(contentsOf: batch.images)
                target.draftFiles.append(contentsOf: batch.files)
            } catch { presentation.photoError = error.localizedDescription }
        }
    }


}

/// A text delta changes one message. Keep the remaining rows independent of the
/// observable session so their layout, Markdown and completion labels stay intact.
private struct AIChatMessageRow: View, Equatable {
    let message: AIChatMessage
    let showsDivider: Bool
    let providerTitle: String
    let directory: String
    let theme: AppTheme
    let locale: Locale
    let imageStore: AIChatImageStore
    let fileStore: AIChatFileStore
    let isActive: Bool
    let expanded: Bool
    let onExpansionChange: (Bool) -> Void
    let onOpenPhoto: (AIChatImage) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.showsDivider == rhs.showsDivider &&
        lhs.providerTitle == rhs.providerTitle && lhs.directory == rhs.directory &&
        lhs.theme == rhs.theme && lhs.locale == rhs.locale &&
        lhs.imageStore === rhs.imageStore && lhs.fileStore === rhs.fileStore &&
        lhs.isActive == rhs.isActive && lhs.expanded == rhs.expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DT.Space.lg) {
            if showsDivider {
                Rectangle().fill(Color(nsColor: theme.borderStrong))
                    .frame(height: 2).padding(.vertical, 12)
                    .accessibilityHidden(true)
            }
            if message.isIntermediate {
                AIThinkingMessage(text: message.text, directory: directory, theme: theme, isActive: false,
                    title: L10n.string(message.role == .thinking ? "ai.chat.thinking" : "ai.chat.progress"),
                    expanded: Binding(get: { expanded }, set: onExpansionChange))
            } else if message.role == .tool {
                DisclosureGroup {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } label: {
                    Label(L10n.string("ai.chat.toolFailed"), systemImage: "exclamationmark.triangle")
                        .font(.caption).lineLimit(1)
                }.foregroundStyle(Color(nsColor: theme.textSecondary))
            } else if message.role == .thinking {
                AIThinkingMessage(text: message.text, directory: directory, theme: theme, isActive: isActive,
                    title: L10n.string("ai.chat.thinking"), expanded: Binding(get: { expanded }, set: onExpansionChange))
            } else {
                VStack(alignment: .leading, spacing: DT.Space.sm) {
                    Text(message.role == .user ? L10n.string("ai.chat.you") : providerTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(nsColor: message.role == .user ? theme.accent : theme.textSecondary))
                    if !message.images.isEmpty {
                        AIChatPhotos(images: message.images, store: imageStore, theme: theme,
                            onOpen: onOpenPhoto)
                    }
                    if !message.files.isEmpty {
                        AIChatFiles(files: message.files, store: fileStore, theme: theme)
                    }
                    if !message.text.isEmpty {
                        if message.role == .user {
                            Text(verbatim: message.text).textSelection(.enabled).font(.system(size: 14)).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AIChatMarkdown(text: message.text, directory: directory, theme: theme).equatable()
                        }
                    }
                    if message.isSteering && message.isError {
                        Text(L10n.string("ai.chat.steerNotApplied"))
                            .font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                    }
                    if let timing = AIChatCompletionLabel.text(for: message, locale: locale) {
                        Text(timing).font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .padding(.top, DT.Space.xs).lineSpacing(3)
                            .foregroundStyle(Color(nsColor: theme.textSecondary))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat-completion-time")
                    }
                }
                .padding(DT.Space.lg)
                .background {
                    if message.role == .user {
                        RoundedRectangle(cornerRadius: DT.Chat.messageRadius, style: .continuous).fill(Color(nsColor: theme.accentMuted))
                    }
                }
                .overlay(alignment: .leading) {
                    if message.role == .user {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.accent))
                            .frame(width: 3).padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

@Observable
final class AIChatPresentation {
    var isAtBottom = true
    var forceScroll = 0
    var expandedIntermediateIDs = Set<String>()
    var collapsedThinkingIDs = Set<String>()
    var showsPhotoPicker = false
    var importingPhotos = false
    var photoError: String?
    var previewPhoto: AIChatImage?
    var photoDropTargeted = false
    var editorPhotoDropTargeted = false
}

/// AppKit owns scrolling and row geometry. Stable, individually hosted messages
/// keep a streaming update from invalidating the entire SwiftUI transcript.
final class AIChatNativePane: NSView {
    private let presentation: AIChatPresentation
    private let session: AITerminalSession
    private let chat: AIChatSession
    private let scroll = AIChatNativeScrollView()
    private let document = AIChatNativeDocument()
    private let stack = NSStackView()
    private var rows: [String: NSHostingView<AIChatNativeRow>] = [:]
    private var welcome: NSView!
    private var status: NSView!
    private var chromeHosts: [NSHostingView<AIChatView>] = []
    private var layoutWidth: CGFloat = 0
    private var importAttachments: (NSPasteboard) -> Bool = { _ in false }

    init(session: AITerminalSession, chat: AIChatSession, onFocus: @escaping () -> Void,
         onEdit: @escaping () -> Void, onChooseDirectory: @escaping () -> Void = {},
         onRestoreLegacy: @escaping (AIChatLegacyConversation) -> Void = { _ in }) {
        let presentation = AIChatPresentation()
        self.presentation = presentation
        self.session = session
        self.chat = chat
        super.init(frame: .zero)
        func host(_ region: AIChatView.Region) -> NSHostingView<AIChatView> {
            let view = NSHostingView(rootView: AIChatView(session: session, chat: chat, onFocus: onFocus,
                onEdit: onEdit, onChooseDirectory: onChooseDirectory, onRestoreLegacy: onRestoreLegacy,
                presentation: presentation, region: region))
            view.sizingOptions = [.intrinsicContentSize]
            view.safeAreaRegions = []
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        let header = host(.header), composer = host(.composer), jump = host(.jump)
        chromeHosts = [header, composer]
        welcome = host(.welcome)
        status = host(.status)
        importAttachments = { [weak composer] in composer?.rootView.pastePhotos($0) ?? false }
        registerForDraggedTypes(AIChatPhotoImport.draggedTypes)
        jump.isHidden = true
        header.setContentHuggingPriority(.required, for: .vertical)
        composer.setContentHuggingPriority(.required, for: .vertical)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.wantsLayer = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DT.Space.lg
        stack.detachesHiddenViews = true
        document.addSubview(stack)
        addSubview(header)
        addSubview(scroll)
        addSubview(composer)
        addSubview(jump)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: DT.Space.lg),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -DT.Space.lg),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: DT.Space.lg),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -44),
            jump.widthAnchor.constraint(equalToConstant: 36),
            jump.heightAnchor.constraint(equalToConstant: 36),
            jump.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -12),
            jump.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -12)
        ])
        scroll.onBottomChange = { [weak jump] atBottom in
            presentation.isAtBottom = atBottom
            jump?.isHidden = atBottom
        }
        scroll.observeDocument()
        observeScrollRequest()
        observeTranscript()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Width is a content input, not scroll position. Giving SwiftUI a finite
        // width lets intrinsic height include wrapping before AppKit lays out rows.
        guard bounds.width > 0, layoutWidth != bounds.width else { return }
        layoutWidth = bounds.width
        for host in chromeHosts { host.rootView.contentWidth = layoutWidth }
        for host in [welcome, status].compactMap({ $0 as? NSHostingView<AIChatView> }) {
            host.rootView.contentWidth = max(1, layoutWidth - 2 * DT.Space.lg)
        }
        updateTranscript()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !presentation.importingPhotos && sender.draggingSourceOperationMask.contains(.copy)
            && AIChatAttachmentImport.containsAttachments(sender.draggingPasteboard)
        presentation.photoDropTargeted = accepts
        return accepts ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { presentation.photoDropTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { presentation.photoDropTargeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { presentation.photoDropTargeted = false }
        guard draggingEntered(sender) == .copy else { return false }
        return importAttachments(sender.draggingPasteboard)
    }

    private func observeScrollRequest() {
        let request = withObservationTracking { presentation.forceScroll } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeScrollRequest() }
        }
        scroll.requestBottom(request)
    }

    private func observeTranscript() {
        withObservationTracking {
            updateTranscript()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeTranscript() }
        }
    }

    private func updateTranscript() {
        let messages = chat.visibleMessages
        let activeID = chat.activeThinkingID
        var views: [NSView] = messages.isEmpty ? [welcome] : []
        let ids = Set(messages.map(\.id))
        rows = rows.filter { ids.contains($0.key) }
        for (index, message) in messages.enumerated() {
            let row = AIChatNativeRow(width: max(1, (layoutWidth > 0 ? layoutWidth : 760) - 2 * DT.Space.lg),
                row: AIChatMessageRow(message: message,
                showsDivider: message.role == .user && !message.isSteering && index > 0,
                providerTitle: session.provider?.tool ?? "AI", directory: chat.directory,
                theme: session.theme, locale: session.locale, imageStore: chat.imageStore, fileStore: chat.fileStore,
                isActive: activeID == message.id, expanded: expansion(for: message).wrappedValue,
                onExpansionChange: { [weak self] in self?.expansion(for: message).wrappedValue = $0 },
                onOpenPhoto: { [weak self] in self?.presentation.previewPhoto = $0 }))
            let host: NSHostingView<AIChatNativeRow>
            if let existing = rows[message.id] {
                host = existing
                if host.rootView != row { host.rootView = row }
            } else {
                host = NSHostingView(rootView: row)
                host.sizingOptions = [.intrinsicContentSize]
                host.safeAreaRegions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                host.setContentHuggingPriority(.required, for: .vertical)
                rows[message.id] = host
            }
            views.append(host)
        }
        if chat.showsThinkingPlaceholder { views.append(status) }
        arrange(views)
        document.layer?.backgroundColor = session.theme.canvas.cgColor
        scroll.backgroundColor = session.theme.canvas
        scroll.drawsBackground = true
    }

    private func arrange(_ views: [NSView]) {
        guard stack.arrangedSubviews != views else { return }
        for view in stack.arrangedSubviews where !views.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() where stack.arrangedSubviews.indices.contains(index) == false || stack.arrangedSubviews[index] !== view {
            if view.superview != nil {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            stack.insertArrangedSubview(view, at: index)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func expansion(for message: AIChatMessage) -> Binding<Bool> {
        let presentation = presentation
        return Binding(get: {
            message.isIntermediate ? presentation.expandedIntermediateIDs.contains(message.id) : !presentation.collapsedThinkingIDs.contains(message.id)
        }, set: { expanded in
            if message.isIntermediate {
                if expanded { presentation.expandedIntermediateIDs.insert(message.id) }
                else { presentation.expandedIntermediateIDs.remove(message.id) }
            } else {
                if expanded { presentation.collapsedThinkingIDs.remove(message.id) }
                else { presentation.collapsedThinkingIDs.insert(message.id) }
            }
        })
    }
}

private struct AIChatNativeRow: View, Equatable {
    let width: CGFloat
    let row: AIChatMessageRow
    var body: some View {
        row.equatable()
            .frame(maxWidth: DT.Chat.contentWidth)
            .frame(width: width, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(nsColor: row.theme.textPrimary))
            .tint(Color(nsColor: row.theme.accent))
            .environment(\.colorScheme, row.theme.isDark ? .dark : .light)
    }
}

private final class AIChatNativeDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class AIChatNativeScrollView: NSScrollView {
    var onBottomChange: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var followsBottom = true
    private var lastRequest: Int?
    private var lastAtBottom: Bool?
    private var updatePending = false
    private var layoutChanged = true
    private var adjustingPosition = false
    private var viewportSize = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .automatic
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func observeDocument() {
        guard let documentView else { return }
        documentView.postsFrameChangedNotifications = true
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: documentView, queue: .main) { [weak self] _ in
            self?.scheduleUpdate(layout: true)
        })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            self?.scheduleUpdate()
        })
        observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: self, queue: .main) { [weak self] _ in
            guard let self, !self.adjustingPosition else { return }
            self.followsBottom = self.atBottom
            self.scheduleUpdate()
        })
    }

    override func tile() {
        super.tile()
        if viewportSize != contentView.bounds.size {
            viewportSize = contentView.bounds.size
            scheduleUpdate(layout: true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleUpdate(layout: true) }
    }

    func requestBottom(_ request: Int) {
        guard lastRequest != request else { return }
        lastRequest = request
        followsBottom = true
        scheduleUpdate(layout: true)
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        guard let documentView else { return }
        followsBottom = false
        let top = documentView.isFlipped ? documentView.bounds.minY
            : max(documentView.bounds.minY, documentView.bounds.maxY - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: top))
        reflectScrolledClipView(contentView)
        scheduleUpdate()
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        followsBottom = true
        scheduleUpdate(layout: true)
    }

    private var atBottom: Bool {
        guard let documentView else { return true }
        if documentView.bounds.height <= contentView.bounds.height { return true }
        let distance = documentView.isFlipped
            ? documentView.bounds.maxY - documentVisibleRect.maxY
            : documentVisibleRect.minY - documentView.bounds.minY
        return distance <= 1
    }

    private func scheduleUpdate(layout: Bool = false) {
        layoutChanged = layoutChanged || layout
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.updatePosition()
        }
    }

    private func updatePosition() {
        guard window != nil, let documentView, contentView.bounds.width > 0 else { return }
        let shouldFollow = layoutChanged && followsBottom
        layoutChanged = false
        if shouldFollow {
            let bottom = documentView.isFlipped
                ? max(documentView.bounds.minY, documentView.bounds.maxY - contentView.bounds.height)
                : documentView.bounds.minY
            if abs(contentView.bounds.minY - bottom) > 0.5 {
                adjustingPosition = true
                contentView.scroll(to: NSPoint(x: 0, y: bottom))
                reflectScrolledClipView(contentView)
                adjustingPosition = false
            }
        }
        let position = atBottom
        if lastAtBottom != position {
            lastAtBottom = position
            onBottomChange(position)
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

private struct AIThinkingMessage: View {
    let text: String
    let directory: String
    let theme: AppTheme
    let isActive: Bool
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            AIChatMarkdown(text: text, directory: directory, theme: theme).equatable().padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                if isActive { ProgressView().controlSize(.small) }
                else { Image(systemName: "sparkles") }
                Text(title)
            }.font(.caption.weight(.medium))
        }.foregroundStyle(Color(nsColor: theme.textSecondary))
            .padding(DT.Space.md)
            .overlay(RoundedRectangle(cornerRadius: DT.Radius.window, style: .continuous)
                .strokeBorder(Color(nsColor: theme.border), lineWidth: DT.Stroke.hairline))
    }
}

private struct AIQuestionCard: View {
    let approval: AIChatApproval
    let theme: AppTheme
    let reply: (Bool, [String: [String]]) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "questionmark.bubble").font(.callout.weight(.semibold))
            ForEach(approval.questions) { question in
                Text(question.prompt).font(.callout)
                if !question.options.isEmpty {
                    Menu(L10n.string("ai.chat.chooseAnswer")) {
                        ForEach(question.options, id: \.self) { option in
                            Button(option) {
                                if question.multiple, let old = answers[question.id], !old.isEmpty {
                                    answers[question.id] = old + ", " + option
                                } else { answers[question.id] = option }
                            }
                        }
                    }.menuStyle(.borderlessButton)
                }
                if question.secret {
                    SecureField(L10n.string("ai.chat.answer"), text: answer(question.id)).textFieldStyle(.roundedBorder)
                } else {
                    TextField(L10n.string("ai.chat.answer"), text: answer(question.id)).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button(L10n.string("ai.chat.deny")) { reply(false, [:]) }
                Spacer()
                Button(L10n.string("ai.chat.sendAnswer")) {
                    reply(true, answers.mapValues { [$0] })
                }.buttonStyle(.borderedProminent)
                    .disabled(approval.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(12).background(Color(nsColor: theme.accentMuted), in: RoundedRectangle(cornerRadius: 8))
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}

/// Native editing keeps marked text, selection, paste and undo under AppKit's
/// control. Wheel events over the transcript never depend on this focus.
struct AIChatComposer: NSViewRepresentable {
    @Binding var text: String
    let conversation: ObjectIdentifier
    let history: () -> [String]
    let theme: AppTheme
    let onFocus: () -> Void
    let onSend: () -> Void
    var onPasteImages: ((NSPasteboard) -> Bool)? = nil
    var acceptsPhotoDrops = true
    var onPhotoDragTargeted: ((Bool) -> Void)? = nil

    final class Editor: NSTextView {
        var onFocus: (() -> Void)?
        var onSend: (() -> Void)?
        var onPasteImages: ((NSPasteboard) -> Bool)?
        var acceptsPhotoDrops = true
        var onPhotoDragTargeted: ((Bool) -> Void)?
        var history: (() -> [String])?
        private var conversation: ObjectIdentifier?
        private let editingUndoManager = UndoManager()
        override var undoManager: UndoManager? { editingUndoManager }
        private struct Draft {
            var text: String
            var selection: NSRange
        }
        private var savedDraft: Draft?
        private var historyEntries: [String] = []
        private var historyEdits: [Int: Draft] = [:]
        private var historyIndex: Int?

        func synchronize(text: String, conversation: ObjectIdentifier) {
            if self.conversation != conversation || string != text {
                resetHistory()
                editingUndoManager.removeAllActions()
                if string != text { string = text }
            }
            self.conversation = conversation
        }

        private func resetHistory() {
            savedDraft = nil
            historyEntries = []
            historyEdits = [:]
            historyIndex = nil
        }

        override func didChangeText() {
            // Undo restores text, not the browsing cursor. Treat the restored
            // text as a fresh draft so it cannot overwrite another entry's edit.
            if editingUndoManager.isUndoing || editingUndoManager.isRedoing { resetHistory() }
            super.didChangeText()
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }
        override func paste(_ sender: Any?) {
            if !hasMarkedText(), onPasteImages?(.general) == true { return }
            super.paste(sender)
        }
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + AIChatPhotoImport.draggedTypes
        }
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            super.readablePasteboardTypes + AIChatPhotoImport.draggedTypes
        }
        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if onPasteImages != nil, AIChatAttachmentImport.containsAttachments(pasteboard) {
                return onPasteImages?(pasteboard) ?? false
            }
            return super.readSelection(from: pasteboard, type: type)
        }
        override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
            if onPasteImages != nil, AIChatAttachmentImport.containsAttachments(dragInfo.draggingPasteboard) {
                let accepts = acceptsPhotoDrops && dragInfo.draggingSourceOperationMask.contains(.copy)
                onPhotoDragTargeted?(accepts)
                return accepts ? .copy : []
            }
            onPhotoDragTargeted?(false)
            return super.dragOperation(for: dragInfo, type: type)
        }
        override func cleanUpAfterDragOperation() {
            onPhotoDragTargeted?(false)
            super.cleanUpAfterDragOperation()
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if onPasteImages != nil, AIChatAttachmentImport.containsAttachments(sender.draggingPasteboard) {
                defer { cleanUpAfterDragOperation() }
                guard acceptsPhotoDrops, sender.draggingSourceOperationMask.contains(.copy) else { return false }
                return onPasteImages?(sender.draggingPasteboard) ?? false
            }
            return super.performDragOperation(sender)
        }
        override func keyDown(with event: NSEvent) {
            // Real arrow events also carry function/numericPad flags. Modified
            // arrows, selections and IME candidate navigation stay with AppKit.
            if (event.keyCode == 126 || event.keyCode == 125), isEditable,
               event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
               !hasMarkedText(), selectedRanges.count == 1, selectedRange().length == 0 {
                let older = event.keyCode == 126
                if isAtHistoryBoundary(older: older), recallHistory(older: older) { return }
            }
            if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                onSend?()
            } else { super.keyDown(with: event) }
        }

        private func isAtHistoryBoundary(older: Bool) -> Bool {
            if string.isEmpty { return true }
            guard let layoutManager, let textContainer else { return false }
            layoutManager.ensureLayout(for: textContainer)
            let length = (string as NSString).length
            let caret = selectedRange().location
            guard caret <= length, layoutManager.numberOfGlyphs > 0 else { return false }
            let hasTrailingLine = layoutManager.extraLineFragmentTextContainer === textContainer
            if caret == length, hasTrailingLine { return !older }
            var line = NSRange()
            var glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            // A caret at a soft wrap may belong to the end of the preceding line.
            let followsNewline = caret > 0 && UnicodeScalar((string as NSString).character(at: caret - 1))
                .map { CharacterSet.newlines.contains($0) } == true
            if caret > 0, caret < length, !followsNewline, selectionAffinity == .upstream,
               glyph == line.location, glyph > 0 {
                glyph = layoutManager.glyphIndexForCharacter(at: caret - 1)
                layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            }
            return older ? line.location == 0 : NSMaxRange(line) == layoutManager.numberOfGlyphs && !hasTrailingLine
        }

        private func recallHistory(older: Bool) -> Bool {
            if historyIndex == nil {
                guard older else { return false }
                let entries = (history?() ?? []).filter { !$0.isEmpty }
                guard !entries.isEmpty else { return false }
                // Freeze this browsing pass: a phone submission can append to
                // the transcript without replacing the desktop's saved draft.
                historyEntries = entries
                savedDraft = Draft(text: string, selection: selectedRange())
                historyIndex = entries.count
            }
            guard let index = historyIndex else { return false }
            if index < historyEntries.count {
                historyEdits[index] = Draft(text: string, selection: selectedRange())
            }
            let next = older ? max(0, index - 1) : index + 1
            if next == index { return true }
            if next >= historyEntries.count {
                if let savedDraft { replaceDraft(savedDraft) }
                resetHistory()
            } else {
                historyIndex = next
                let recalled = historyEntries[next]
                replaceDraft(historyEdits[next] ?? Draft(text: recalled,
                    selection: NSRange(location: (recalled as NSString).length, length: 0)))
            }
            return true
        }

        private func replaceDraft(_ draft: Draft) {
            breakUndoCoalescing()
            insertText(draft.text, replacementRange: NSRange(location: 0, length: (string as NSString).length))
            setSelectedRange(draft.selection)
            scrollRangeToVisible(selectedRange())
            breakUndoCoalescing()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatComposer
        init(_ parent: AIChatComposer) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { view.undoManager }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = Editor(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: DT.Space.md, height: DT.Space.md)
        editor.font = .systemFont(ofSize: 14)
        editor.delegate = context.coordinator
        editor.updateDragTypeRegistration()
        editor.setAccessibilityLabel(L10n.string("ai.chat.input"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.synchronize(text: text, conversation: conversation)
        editor.history = history
        editor.onFocus = onFocus
        editor.onSend = onSend
        editor.onPasteImages = onPasteImages
        editor.acceptsPhotoDrops = acceptsPhotoDrops
        editor.onPhotoDragTargeted = onPhotoDragTargeted
        editor.textColor = theme.textPrimary
        editor.insertionPointColor = theme.accent
        editor.backgroundColor = theme.canvas
        scroll.backgroundColor = theme.canvas
    }
}
