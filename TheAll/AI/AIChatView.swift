import AppKit
import SwiftUI
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
    @State private var followOutput = true
    @State private var isAtBottom = true
    @State private var forceScroll = 0
    @State private var expandedIntermediateIDs = Set<String>()
    @State private var collapsedThinkingIDs = Set<String>()
    @State private var showsPhotoPicker = false
    @State private var importingPhotos = false
    @State private var photoError: String?
    @State private var previewPhoto: AIChatImage?
    @State private var photoDropTargeted = false
    @State private var editorPhotoDropTargeted = false
    private var theme: AppTheme { session.theme }

    var body: some View {
        let _ = session.locale
        VStack(spacing: 0) {
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
            transcript
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
                        onOpen: { previewPhoto = $0 }, onRemove: { image in
                            chat.draftImages.removeAll { $0.id == image.id }
                        })
                }
                if importingPhotos {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("ai.images.preparing")).font(.caption)
                    }
                }
                if let photoError {
                    Text(photoError).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                }
                AIChatComposer(text: $chat.input, conversation: ObjectIdentifier(chat),
                    history: { chat.messages.filter { $0.role == .user }.map(\.text) },
                    theme: theme, onFocus: onFocus, onSend: send, onPasteImages: pastePhotos,
                    acceptsPhotoDrops: !importingPhotos,
                    onPhotoDragTargeted: { editorPhotoDropTargeted = $0 })
                    .frame(height: DT.Chat.editorHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DT.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DT.Radius.card, style: .continuous)
                        .strokeBorder(Color(nsColor: theme.border), lineWidth: DT.Stroke.hairline))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DT.Space.sm) {
                        directoryControls
                        Spacer(minLength: DT.Space.md)
                        modelControls
                    }
                    VStack(alignment: .leading, spacing: DT.Space.sm) {
                        directoryControls
                        HStack(spacing: DT.Space.sm) {
                            Spacer(minLength: 0)
                            modelControls
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
                    Text("⌘↩ " + L10n.string("ai.chat.send"))
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
        .foregroundStyle(Color(nsColor: theme.textPrimary))
        .background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onDrop(of: [.fileURL, .image], isTargeted: $photoDropTargeted, perform: dropPhotos)
        .overlay {
            if !importingPhotos, photoDropTargeted || editorPhotoDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: theme.accentMuted).opacity(0.8))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: theme.accent), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    Label(L10n.string("ai.images.drop"), systemImage: "photo.badge.plus")
                        .font(.headline).padding(16)
                        .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: 8))
                }.padding(6).allowsHitTesting(false)
            }
        }
        .onAppear { if chat.catalogModels.isEmpty, !session.isLoadingModels { session.refreshModels() } }
        .fileImporter(isPresented: $showsPhotoPicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): attachPhotos(urls.map(AIChatPhotoImport.file))
            case .failure: photoError = L10n.string("ai.images.unavailable")
            }
        }
        .sheet(item: $previewPhoto) { image in
            AIChatPhotoPreview(image: image, store: chat.imageStore, theme: theme)
        }
    }

    private var directoryControls: some View {
        HStack(spacing: DT.Space.sm) {
            Button { showsPhotoPicker = true } label: {
                Image(systemName: "photo.badge.plus")
                    .frame(width: DT.Chat.controlHeight, height: DT.Chat.controlHeight)
            }
            .buttonStyle(.borderless)
            .disabled(importingPhotos || chat.draftImages.count >= AIChatImageStore.maximumCount)
            .help(L10n.string("ai.images.add"))
            .accessibilityLabel(L10n.string("ai.images.add"))
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

    private var modelControls: some View {
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
            Group {
                if chat.isBusy {
                    Button(L10n.string("ai.chat.stop")) { chat.interrupt() }
                        .disabled(!chat.canInterrupt)
                } else {
                    Button(L10n.string("ai.chat.send"), action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(!chat.canSend || importingPhotos)
                }
            }
            .controlSize(.large).fixedSize()
        }
        .frame(minHeight: DT.Chat.controlHeight)
    }

    private var transcript: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DT.Space.lg) {
                        if chat.visibleMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.string("ai.chat.welcome")).font(.title2.weight(.semibold))
                                Text(L10n.string("ai.chat.welcomeDetail")).font(.callout)
                                    .foregroundStyle(Color(nsColor: theme.textSecondary))
                                if chat.provider == .claude, !chat.isBusy {
                                    AILegacyHistoryButton(session: session, onRestore: onRestoreLegacy)
                                        .padding(.top, 8)
                                }
                            }.padding(.vertical, 24)
                        }
                        ForEach(Array(chat.visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if message.role == .user, index > 0 {
                                Rectangle().fill(Color(nsColor: theme.borderStrong))
                                    .frame(height: 2).padding(.vertical, 12)
                                    .accessibilityHidden(true)
                            }
                            if message.isIntermediate {
                                AIThinkingMessage(text: message.text, theme: theme, isActive: false,
                                    title: L10n.string(message.role == .thinking ? "ai.chat.thinking" : "ai.chat.progress"),
                                    expanded: expansion(for: message))
                            } else if message.role == .tool {
                                DisclosureGroup {
                                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                } label: {
                                    Label(L10n.string("ai.chat.toolFailed"), systemImage: "exclamationmark.triangle")
                                        .font(.caption).lineLimit(1)
                                }.foregroundStyle(Color(nsColor: theme.textSecondary))
                            } else if message.role == .thinking {
                                AIThinkingMessage(text: message.text, theme: theme, isActive: chat.activeThinkingID == message.id,
                                    title: L10n.string("ai.chat.thinking"), expanded: expansion(for: message))
                            } else {
                                VStack(alignment: .leading, spacing: DT.Space.sm) {
                                    Text(message.role == .user ? L10n.string("ai.chat.you") : session.provider?.tool ?? "AI")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: message.role == .user ? theme.accent : theme.textSecondary))
                                    if !message.images.isEmpty {
                                        AIChatPhotos(images: message.images, store: chat.imageStore, theme: theme,
                                            onOpen: { previewPhoto = $0 })
                                    }
                                    if !message.text.isEmpty {
                                    Text(message.role == .user ? AttributedString(message.text) :
                                        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                                        .textSelection(.enabled).font(.system(size: 14)).lineSpacing(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if let timing = AIChatCompletionLabel.text(for: message, locale: session.locale) {
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
                        if chat.showsThinkingPlaceholder {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L10n.string("ai.chat.thinking")).font(.caption.weight(.medium))
                            }.foregroundStyle(Color(nsColor: theme.textSecondary))
                        }
                        // Keep the bottom anchor at the actual end of the content.
                        Color.clear.frame(height: 44).id("bottom")
                    }.frame(maxWidth: DT.Chat.contentWidth)
                        .padding(.horizontal, DT.Space.lg).padding(.top, DT.Space.lg)
                        .frame(maxWidth: .infinity)
                        .background(AIChatScrollPosition { atBottom, nearBottom in
                            isAtBottom = atBottom
                            followOutput = nearBottom
                        })
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.revision) { _, _ in
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: forceScroll) { _, _ in
                    followOutput = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom, !chat.visibleMessages.isEmpty {
                        Button { forceScroll += 1 } label: {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(Color(nsColor: theme.sidebar), in: Circle())
                                .overlay(Circle().stroke(Color(nsColor: theme.borderStrong), lineWidth: 1))
                        }
                        .buttonStyle(.plain).padding(12)
                        .help(L10n.string("ai.chat.latest"))
                        .accessibilityLabel(L10n.string("ai.chat.latest"))
                        .accessibilityIdentifier("chat-scroll-to-bottom")
                    }
                }
            }
        }
    }

    private func send() {
        guard !importingPhotos else { return }
        chat.send()
        forceScroll += 1
    }

    private func pastePhotos(_ pasteboard: NSPasteboard) -> Bool {
        guard AIChatPhotoImport.containsImages(pasteboard) else { return false }
        guard let photos = AIChatPhotoImport.read(pasteboard), !photos.isEmpty else {
            photoError = L10n.string("ai.images.invalid")
            return true
        }
        attachPhotos(photos)
        return true
    }

    private func dropPhotos(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !importingPhotos else { return false }
        importPhotos(count: providers.count) { store in
            try await AIChatPhotoImport.importProviders(providers, store: store)
        }
        return true
    }

    private func attachPhotos(_ sources: [AIChatPhotoImport]) {
        guard !sources.isEmpty else { return }
        importPhotos(count: sources.count) { store in
            try await Task.detached(priority: .userInitiated) {
                try AIChatPhotoImport.importBatch(sources, store: store)
            }.value
        }
    }

    private func importPhotos(count: Int, operation: @escaping (AIChatImageStore) async throws -> [AIChatImage]) {
        guard !importingPhotos else { return }
        guard chat.draftImages.count + count <= AIChatImageStore.maximumCount else {
            photoError = L10n.string("ai.images.tooMany")
            return
        }
        importingPhotos = true
        photoError = nil
        let target = chat
        let imageStore = target.imageStore
        Task { @MainActor in
            defer { importingPhotos = false }
            do {
                let images = try await operation(imageStore)
                guard target.draftImages.count + images.count <= AIChatImageStore.maximumCount else {
                    for image in images { try? target.imageStore.remove(image) }
                    photoError = L10n.string("ai.images.tooMany")
                    return
                }
                target.draftImages.append(contentsOf: images)
            } catch { photoError = error.localizedDescription }
        }
    }

    private func expansion(for message: AIChatMessage) -> Binding<Bool> {
        Binding(get: {
            message.isIntermediate ? expandedIntermediateIDs.contains(message.id) : !collapsedThinkingIDs.contains(message.id)
        }, set: { expanded in
            if message.isIntermediate {
                if expanded { expandedIntermediateIDs.insert(message.id) }
                else { expandedIntermediateIDs.remove(message.id) }
            } else {
                if expanded { collapsedThinkingIDs.remove(message.id) }
                else { collapsedThinkingIDs.insert(message.id) }
            }
        })
    }
}

/// Native clip offsets stay accurate when SwiftUI lazily lays out messages,
/// resizes a split pane, or collapses completed progress.
private struct AIChatScrollPosition: NSViewRepresentable {
    let onChange: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange; view.scheduleUpdate() }

    final class Probe: NSView {
        var onChange: (Bool, Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var updatePending = false
        private var lastPosition: (Bool, Bool)?

        init(onChange: @escaping (Bool, Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
        override func layout() { super.layout(); scheduleUpdate() }

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                self.updatePosition()
            }
        }

        private func updatePosition() {
            let enclosing = enclosingScrollView
            if scrollView !== enclosing {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                scrollView = enclosing
                lastPosition = nil
                if let enclosing, let document = enclosing.documentView {
                    enclosing.contentView.postsBoundsChangedNotifications = true
                    enclosing.contentView.postsFrameChangedNotifications = true
                    document.postsFrameChangedNotifications = true
                    for (name, view) in [(NSView.boundsDidChangeNotification, enclosing.contentView),
                                         (NSView.frameDidChangeNotification, enclosing.contentView),
                                         (NSView.frameDidChangeNotification, document)] {
                        observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                            self?.scheduleUpdate()
                        })
                    }
                }
            }
            guard let scrollView, let document = scrollView.documentView else { return }
            let remaining = document.isFlipped
                ? document.bounds.maxY - scrollView.documentVisibleRect.maxY
                : scrollView.documentVisibleRect.minY - document.bounds.minY
            let position = (remaining <= 1, remaining <= 45)
            guard lastPosition?.0 != position.0 || lastPosition?.1 != position.1 else { return }
            lastPosition = position
            onChange(position.0, position.1)
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

private struct AIThinkingMessage: View {
    let text: String
    let theme: AppTheme
    let isActive: Bool
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .font(.callout).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
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
            if onPasteImages != nil, AIChatPhotoImport.containsImages(pasteboard) {
                return onPasteImages?(pasteboard) ?? false
            }
            return super.readSelection(from: pasteboard, type: type)
        }
        override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
            if onPasteImages != nil, AIChatPhotoImport.containsImages(dragInfo.draggingPasteboard) {
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
            if onPasteImages != nil, AIChatPhotoImport.containsImages(sender.draggingPasteboard) {
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
