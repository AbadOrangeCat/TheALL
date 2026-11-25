import AppKit
import WebKit
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

// Keep the menu attached to the actual control in the visible composer's window.
private struct AIReasoningEffortPicker: NSViewRepresentable {
    @Binding var selection: String
    let efforts: [String]
    let accent: NSColor

    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }

        @objc func choose(_ sender: NSPopUpButton) {
            if let effort = sender.selectedItem?.representedObject as? String {
                selection.wrappedValue = effort
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.autoenablesItems = false
        button.setAccessibilityIdentifier("chat-reasoning-effort")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let obsolete = !selection.isEmpty && !efforts.contains(selection)
        let values = [""] + (obsolete ? [selection] : []) + efforts
        let defaultTitle = L10n.string("ai.effort.default")
        if button.itemArray.compactMap({ $0.representedObject as? String }) != values
            || button.item(at: 0)?.title != defaultTitle {
            button.removeAllItems()
            for value in values {
                button.addItem(withTitle: value.isEmpty ? defaultTitle : value)
                button.lastItem?.representedObject = value
            }
        }
        for item in button.itemArray {
            item.isEnabled = !obsolete || item.representedObject as? String != selection
        }
        button.selectItem(at: values.firstIndex(of: selection) ?? 0)
        button.isEnabled = !efforts.isEmpty
        button.contentTintColor = accent
        button.toolTip = L10n.string(efforts.isEmpty ? "ai.effort.unavailable" : "ai.effort.title")
        button.setAccessibilityLabel(L10n.string("ai.effort.title"))
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
            AIReasoningEffortPicker(selection: $chat.reasoningEffort, efforts: chat.supportedReasoningEfforts, accent: theme.accent)
                .frame(minWidth: 64, maxWidth: 130)
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
                    HStack {
                        Text(message.role == .user ? L10n.string("ai.chat.you") : providerTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(nsColor: message.role == .user ? theme.accent : theme.textSecondary))
                        Spacer(minLength: 8)
                        if message.role == .assistant && !message.text.isEmpty {
                            AIChatCopyButton(text: message.text, label: "ai.markdown.copyReply", identifier: "chat-copy-reply")
                                .foregroundStyle(Color(nsColor: theme.textSecondary))
                        }
                    }
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
    /// Folded step rows the user opened or closed; others use their default.
    var stepExpansion: [String: Bool] = [:]
    var showsPhotoPicker = false
    var importingPhotos = false
    var photoError: String?
    var previewPhoto: AIChatImage?
    var photoDropTargeted = false
    var editorPhotoDropTargeted = false
}

/// The Mac transcript keeps a bounded number of message rows, like the phone's
/// "Load earlier messages" pages. Each row is its own SwiftUI host, so a long
/// conversation with thousands of tool steps would otherwise keep thousands of
/// view graphs alive in every open tab.
enum AIChatTranscriptWindow {
    static let page = 100

    /// Where the newest page starts.
    static func latestStart(_ messages: [AIChatMessage], page: Int = page) -> Int {
        earlierStart(messages, before: messages.count, page: page)
    }

    /// Where the transcript starts after revealing one more page before `start`.
    /// Begins at the question that opens that round when one is within half a page.
    static func earlierStart(_ messages: [AIChatMessage], before start: Int, page: Int = page) -> Int {
        let target = max(0, min(start, messages.count) - page)
        guard target > 0 else { return 0 }
        let floor = max(0, target - page / 2)
        return messages[floor...target].lastIndex { $0.role == .user && !$0.isSteering } ?? target
    }
}

/// One transcript row: a message, or a run of thinking and progress steps folded together.
enum AIChatTranscriptItem: Equatable {
    case message(AIChatMessage)
    case steps(id: String, [AIChatMessage])

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .steps(let id, _): return id
        }
    }
}

/// Display only: thinking and progress notes take one compact row per run of
/// steps instead of a row each. Messages, history and the CLI context are unchanged.
/// Mirrors `turns(…, { running })` in MobileWeb.bundle/core.js.
enum AIChatTranscriptLayout {
    /// A running turn's replies that already have later steps (including hidden
    /// tool calls) are progress notes; only the newest one can still be the answer.
    /// A finished turn marks its notes `isIntermediate` itself.
    static func runningNotes(_ messages: [AIChatMessage], isBusy: Bool) -> Set<String> {
        guard isBusy, messages.count > 1 else { return [] }
        let start = (messages.lastIndex { $0.role == .user && !$0.isSteering } ?? -1) + 1
        guard start < messages.count - 1 else { return [] }
        return Set(messages[start..<(messages.count - 1)]
            .filter { $0.role == .assistant && !$0.isError && !$0.isIntermediate }.map(\.id))
    }

    /// Errors always stay visible as their own rows.
    static func isStep(_ message: AIChatMessage, notes: Set<String>) -> Bool {
        !message.isError && (message.role == .thinking || message.isIntermediate || notes.contains(message.id))
    }

    static func items<C: Collection>(_ messages: C, notes: Set<String>) -> [AIChatTranscriptItem] where C.Element == AIChatMessage {
        var items: [AIChatTranscriptItem] = []
        for message in messages {
            guard isStep(message, notes: notes) else { items.append(.message(message)); continue }
            if case .steps(let id, var steps)? = items.last {
                steps.append(message)
                items[items.count - 1] = .steps(id: id, steps)
            } else {
                items.append(.steps(id: "steps:" + message.id, [message]))
            }
        }
        return items
    }

    /// One line describing the newest step, shown on the folded row while a turn runs.
    static func preview(_ message: AIChatMessage?, limit: Int = 160) -> String {
        let markup = CharacterSet(charactersIn: "#>*`-").union(.whitespaces)
        let line = (message?.text ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: markup).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
            .last { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
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
    private let activityHost: NSHostingView<AIChatActivityMap>
    private var welcome: NSView!
    private var status: NSView!
    private var chromeHosts: [NSHostingView<AIChatView>] = []
    private var layoutWidth: CGFloat = 0
    private var importAttachments: (NSPasteboard) -> Bool = { _ in false }
    private let earlier = NSButton(title: "", target: nil, action: nil)
    /// First message the user asked to see by loading earlier pages.
    private var pinnedFirstID: String?
    /// First message currently shown; kept while the user reads above the bottom
    /// so new messages never shift the rows under them.
    private var shownFirstID: String?
    private var atBottom = true
    private var releaseEarlier: DispatchWorkItem?

    init(session: AITerminalSession, chat: AIChatSession, onFocus: @escaping () -> Void,
         onEdit: @escaping () -> Void, onChooseDirectory: @escaping () -> Void = {},
         onRestoreLegacy: @escaping (AIChatLegacyConversation) -> Void = { _ in }) {
        let presentation = AIChatPresentation()
        self.presentation = presentation
        self.session = session
        self.chat = chat
        self.activityHost = NSHostingView(rootView: AIChatActivityMap(session: session, chat: chat))
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
        earlier.target = self
        earlier.action = #selector(showEarlier)
        earlier.isBordered = false
        earlier.font = .systemFont(ofSize: 12, weight: .medium)
        earlier.setAccessibilityIdentifier("chat-show-earlier")
        document.addSubview(stack)
        addSubview(header)
        addSubview(scroll)
        addSubview(composer)
        addSubview(jump)
        activityHost.identifier = NSUserInterfaceItemIdentifier("chat-activity-map")
        activityHost.sizingOptions = [.intrinsicContentSize]
        activityHost.safeAreaRegions = []
        activityHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityHost)
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
            activityHost.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6),
            activityHost.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8),
            jump.widthAnchor.constraint(equalToConstant: 36),
            jump.heightAnchor.constraint(equalToConstant: 36),
            jump.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -12),
            jump.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -12)
        ])
        scroll.onBottomChange = { [weak self, weak jump] atBottom in
            presentation.isAtBottom = atBottom
            jump?.isHidden = atBottom
            self?.atBottom = atBottom
        }
        scroll.observeDocument()
        observeScrollRequest()
        observeMapVisibility()
        observeTranscript()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        releaseEarlier?.cancel()
        releaseEarlier = nil
        guard window == nil else { return }
        // A tab left in the background drops pages loaded beyond the newest one.
        // The delay keeps a split or tab reorder, which re-parents the pane, intact.
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.window == nil, self.pinnedFirstID != nil || self.shownFirstID != nil else { return }
            self.pinnedFirstID = nil
            self.shownFirstID = nil
            self.updateTranscript()
        }
        releaseEarlier = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: release)
    }

    @objc private func showEarlier() {
        let all = chat.visibleMessages
        let first = shownFirstID.flatMap { id in all.firstIndex { $0.id == id } } ?? transcriptStart(all)
        guard first > 0 else { return }
        pinnedFirstID = all[AIChatTranscriptWindow.earlierStart(all, before: first)].id
        // Keep the rows on screen where they are while older ones appear above.
        let height = document.frame.height
        let origin = scroll.contentView.bounds.origin
        updateTranscript()
        scroll.layoutSubtreeIfNeeded()
        let added = document.frame.height - height
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + max(0, added)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Index of the first message to show.
    private func transcriptStart(_ all: [AIChatMessage]) -> Int {
        let latest = AIChatTranscriptWindow.latestStart(all)
        func index(_ id: String?) -> Int? { id.flatMap { id in all.firstIndex { $0.id == id } } }
        // Pages the user loaded stay until the tab has been in the background for a while.
        if let pinned = index(pinnedFirstID) { return min(pinned, latest) }
        pinnedFirstID = nil
        if !atBottom, let shown = index(shownFirstID) { return min(shown, latest) }
        return latest
    }

    override func layout() {
        super.layout()
        // Width is a content input, not scroll position. Giving SwiftUI a finite
        // width lets intrinsic height include wrapping before AppKit lays out rows.
        let sceneWidth = floor(min(300, scroll.bounds.width - 32, (scroll.bounds.height - 84) * 460 / 430))
        let sceneHeight = floor(max(0, scroll.bounds.height - 84))
        if activityHost.rootView.sceneWidth != sceneWidth || activityHost.rootView.sceneHeight != sceneHeight {
            var map = activityHost.rootView
            map.sceneWidth = sceneWidth
            map.sceneHeight = sceneHeight
            activityHost.rootView = map
        }
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

    private func observeMapVisibility() {
        let visible = withObservationTracking {
            chat.hasLiveActivity
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeMapVisibility() }
        }
        activityHost.rootView.live = visible
        activityHost.isHidden = !visible
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
        let all = chat.visibleMessages
        let start = transcriptStart(all)
        let messages = all[start...]
        shownFirstID = messages.first?.id
        let activeID = chat.activeThinkingID
        var views: [NSView] = all.isEmpty ? [welcome] : []
        if start > 0 {
            earlier.title = L10n.string("ai.chat.showEarlier", start)
            earlier.contentTintColor = session.theme.accent
            views.append(earlier)
        }
        let items = AIChatTranscriptLayout.items(messages,
            notes: AIChatTranscriptLayout.runningNotes(chat.messages, isBusy: chat.isBusy))
        // Rows outside the window are released with their SwiftUI graphs.
        let ids = Set(items.map(\.id))
        rows = rows.filter { ids.contains($0.key) }
        let width = max(1, (layoutWidth > 0 ? layoutWidth : 760) - 2 * DT.Space.lg)
        let firstID = all.first?.id
        // Steps after the last question belong to the running turn.
        let runningFrom = chat.isBusy ? items.lastIndex { if case .message(let m) = $0 { m.role == .user && !m.isSteering } else { false } } ?? -1 : items.count
        var activeSteps = false
        for (position, item) in items.enumerated() {
            let content: AIChatNativeRow.Content
            switch item {
            case .message(let message):
                content = .message(AIChatMessageRow(message: message,
                    showsDivider: message.role == .user && !message.isSteering && message.id != firstID,
                    providerTitle: session.provider?.tool ?? "AI", directory: chat.directory,
                    theme: session.theme, locale: session.locale, imageStore: chat.imageStore, fileStore: chat.fileStore,
                    isActive: activeID == message.id, expanded: expansion(for: message).wrappedValue,
                    onExpansionChange: { [weak self] in self?.expansion(for: message).wrappedValue = $0 },
                    onOpenPhoto: { [weak self] in self?.presentation.previewPhoto = $0 }))
            case .steps(let id, let steps):
                let active = position > runningFrom
                activeSteps = activeSteps || (active && position == items.count - 1)
                // A finished turn without an answer opens its steps: they are all it produced.
                var answered = false
                if position + 1 < items.count, case .message(let next) = items[position + 1] { answered = next.role != .user || next.isSteering }
                let presentation = presentation
                content = .steps(AIChatStepsRow(id: id, steps: steps, directory: chat.directory, theme: session.theme,
                    locale: session.locale, isActive: active,
                    expanded: presentation.stepExpansion[id] ?? (!active && !answered),
                    onExpansionChange: { presentation.stepExpansion[id] = $0 }))
            }
            let row = AIChatNativeRow(width: width, content: content)
            let host: NSHostingView<AIChatNativeRow>
            if let existing = rows[item.id] {
                host = existing
                if host.rootView != row { host.rootView = row }
            } else {
                host = NSHostingView(rootView: row)
                host.sizingOptions = [.intrinsicContentSize]
                host.safeAreaRegions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                host.setContentHuggingPriority(.required, for: .vertical)
                rows[item.id] = host
            }
            views.append(host)
        }
        // A running step row already shows its spinner and newest step.
        if chat.showsThinkingPlaceholder && !activeSteps { views.append(status) }
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

/// A pane-local overlay. Its observation and layout are independent of the
/// transcript so that a tool notification never needs to reflow message rows.
private struct AIChatActivityMap: View {
    let session: AITerminalSession
    let chat: AIChatSession
    var live = false
    var sceneHeight: CGFloat = 0
    var sceneWidth: CGFloat = 0
    @State private var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var theme: AppTheme { session.theme }

    var body: some View {
        let _ = session.locale
        let compact = sceneWidth < 200
        let expanded = live && !compact && !collapsed
        let showAgents = chat.subagents.filter { $0.status == .running }.count >= 2
        let listHeight = min(144, sceneHeight * 0.30, CGFloat(chat.subagents.count) * 44)
        let chartHeight = min(sceneWidth * 430 / 460, sceneHeight - (showAgents ? listHeight + 52 : 0))
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Color(nsColor: theme.accent))
                    Text(L10n.string("ai.activity.title")).font(.caption.weight(.semibold))
                    if !compact {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(compact)
            if expanded {
                LotMapScene(provider: session.provider?.tool ?? "AI", rows: chat.activityMap, quota: chat.accountQuota,
                            locale: session.locale.identifier(.bcp47), labels: Dictionary(uniqueKeysWithValues: AIActivityStation.displayOrder.map {
                                ($0, L10n.string("ai.activity." + $0))
                            }), reduceMotion: reducedMotion, dark: theme.isDark)
                    .frame(width: sceneWidth, height: max(0, chartHeight) + (chat.accountQuota.isEmpty ? 0 : 22))
                if showAgents {
                    AIChatSubagentStrip(agents: chat.subagents, theme: theme, listHeight: listHeight)
                        .frame(width: sceneWidth)
                }
            }
        }
        .padding(10)
        .foregroundStyle(Color(nsColor: theme.textPrimary))
        .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: DT.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DT.Radius.card).strokeBorder(Color(nsColor: theme.border)))
        .fixedSize()
        .onChange(of: chat.isBusy) { _, busy in if busy { collapsed = false } }
    }

}

// The desktop and paired web clients draw the same locally bundled scene.
// Only station counts and display strings cross the WebKit boundary.
private struct LotMapScene: NSViewRepresentable, Equatable {
    let provider: String
    let rows: [AIActivityStation]
    let quota: [AIQuotaWindow]
    let locale: String
    let labels: [String: String]
    let reduceMotion: Bool
    let dark: Bool

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var scene: LotMapScene?
        var ready = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            publish(to: webView)
        }

        func publish(to webView: WKWebView) {
            guard ready, let scene else { return }
            let rows: [[String: Any]] = scene.rows.map {
                ["station": $0.station, "active": $0.active, "completed": $0.completed, "failed": $0.failed]
            }
            let quota = scene.quota.map { window -> [String: Any] in
                var row = ["windowMinutes": window.windowMinutes, "remainingPercent": window.remainingPercent]
                row["resetsAt"] = window.resetsAt
                return row
            }
            let payload: [String: Any] = ["provider": scene.provider, "rows": rows, "quota": quota,
                                          "locale": scene.locale, "quotaLabel": L10n.string("ai.activity.quota"),
                                          "labels": scene.labels, "reduceMotion": scene.reduceMotion,
                                          "theme": scene.dark ? "dark" : "light"]
            webView.callAsyncJavaScript("window.updateLotMap(payload)", arguments: ["payload": payload],
                                        in: nil, in: .page, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let root = Bundle.main.url(forResource: "MobileWeb", withExtension: "bundle") {
            view.loadFileURL(root.appendingPathComponent("lot-map.html"), allowingReadAccessTo: root)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.scene != self else { return }
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        context.coordinator.scene = self
        context.coordinator.publish(to: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
    }
}

/// Subagent activity inside the expanded Lot Map.
/// Motion adapted from SmoothUI AI Task List (MIT; bundled third-party notice).
private struct AIChatSubagentStrip: View {
    let agents: [AIChatSubagent]
    let theme: AppTheme
    let listHeight: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string("ai.subagents.title"), systemImage: "person.2")
                    .font(Font(DT.Font.smallB))
                Spacer()
                Text(L10n.string("ai.subagents.active", agents.filter { $0.status == .running }.count))
                    .font(.caption).monospacedDigit().foregroundStyle(Color(nsColor: theme.textSecondary))
            }
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(agents) { AIChatSubagentRow(agent: $0, theme: theme) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: listHeight)
        }
        .padding(12)
        .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: DT.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DT.Radius.card)
            .strokeBorder(Color(nsColor: theme.border), lineWidth: DT.Stroke.hairline))
        .accessibilityIdentifier("chat-subagent-status")
    }
}

private struct AIChatSubagentRow: View {
    let agent: AIChatSubagent
    let theme: AppTheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var drawn: CGFloat = 0
    @State private var underline = false
    private var color: Color { Color(nsColor: agent.status == .done ? theme.success : agent.status == .failed ? theme.danger : theme.textSecondary) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5).stroke(color, lineWidth: 1.4)
                if agent.status == .done {
                    Path { path in
                        path.move(to: CGPoint(x: 3.5, y: 7.5)); path.addLine(to: CGPoint(x: 6, y: 10)); path.addLine(to: CGPoint(x: 10.5, y: 4.5))
                    }.trim(from: 0, to: drawn).stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                } else if agent.status == .failed || agent.status == .stopped {
                    Image(systemName: agent.status == .failed ? "xmark" : "minus").font(.system(size: 9)).foregroundStyle(color)
                }
            }.frame(width: 14, height: 14).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title).font(.system(size: 13)).lineLimit(1).help(agent.title)
                if !agent.detail.isEmpty {
                    Text(agent.detail).font(.caption).lineLimit(1).help(agent.detail)
                        .foregroundStyle(Color(nsColor: theme.textSecondary))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.string("ai.subagents." + agent.status.rawValue)).font(.caption)
                .foregroundStyle(Color(nsColor: theme.textSecondary))
        }
        .frame(height: 38, alignment: .top)
        .opacity(agent.status == .done ? 0.65 : 1)
        .offset(y: agent.status == .done && !reducedMotion ? 1 : 0)
        .animation(reducedMotion ? nil : .spring(duration: 0.25, bounce: 0.1), value: agent.status)
        .overlay(alignment: .bottom) {
            if agent.status == .running && !reducedMotion {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Color(nsColor: theme.accent).opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width / 2)
                        .offset(x: underline ? geometry.size.width : -geometry.size.width / 2)
                }.frame(height: 1).clipped()
                    .onAppear { underline = false; withAnimation(.timingCurve(0.645, 0.045, 0.355, 1, duration: 1.4).repeatForever(autoreverses: false)) { underline = true } }
            }
        }
        .onAppear { drawCheck() }
        .onChange(of: agent.status) { _, _ in drawCheck() }
        .accessibilityElement(children: .combine)
    }
    private func drawCheck() {
        drawn = 0
        withAnimation(reducedMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { drawn = agent.status == .done ? 1 : 0 }
    }
}

private struct AIChatNativeRow: View, Equatable {
    enum Content: Equatable {
        case message(AIChatMessageRow)
        case steps(AIChatStepsRow)
    }
    let width: CGFloat
    let content: Content
    private var theme: AppTheme {
        switch content {
        case .message(let row): return row.theme
        case .steps(let row): return row.theme
        }
    }
    var body: some View {
        Group {
            switch content {
            case .message(let row): row.equatable()
            case .steps(let row): row.equatable()
            }
        }
            .frame(maxWidth: DT.Chat.contentWidth)
            .frame(width: width, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(nsColor: theme.textPrimary))
            .tint(Color(nsColor: theme.accent))
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

/// Thinking and progress notes of one run, folded to a single line. Expanding
/// shows every step in full, selectable like any reply.
private struct AIChatStepsRow: View, Equatable {
    let id: String
    let steps: [AIChatMessage]
    let directory: String
    let theme: AppTheme
    let locale: Locale
    let isActive: Bool
    let expanded: Bool
    let onExpansionChange: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.steps == rhs.steps && lhs.directory == rhs.directory && lhs.theme == rhs.theme
            && lhs.locale == rhs.locale && lhs.isActive == rhs.isActive && lhs.expanded == rhs.expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onExpansionChange(!expanded) } label: {
                HStack(spacing: 6) {
                    if isActive { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(L10n.string("ai.chat.steps", steps.count))
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-steps")
            if !expanded, isActive {
                let preview = AIChatTranscriptLayout.preview(steps.last)
                if !preview.isEmpty {
                    Text(verbatim: preview).font(.caption).lineLimit(1).truncationMode(.tail).padding(.top, 4)
                        .accessibilityIdentifier("chat-steps-preview")
                }
            }
            if expanded {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string(step.role == .thinking ? "ai.chat.thinking" : "ai.chat.progress"))
                            .font(.caption2.weight(.semibold))
                        AIChatMarkdown(text: step.text, directory: directory, theme: theme).equatable()
                    }
                    .padding(.top, DT.Space.md)
                }
            }
        }
        .foregroundStyle(Color(nsColor: theme.textSecondary))
        .padding(DT.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DT.Radius.window, style: .continuous)
            .strokeBorder(Color(nsColor: theme.border), lineWidth: DT.Stroke.hairline))
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
            if window?.firstResponder === self, selectedRange().length == 0 {
                scrollRangeToVisible(selectedRange())
            }
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
        // Clip the fixed viewport, so the growing text document can draw natively.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = DT.Radius.card
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        // Keep wrapping, document height and caret scrolling on the same layout
        // manager, including the line-fragment queries used by history navigation.
        let editor = Editor(usingTextLayoutManager: false)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
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
        // Setting NSTextView.textColor reapplies attributes to the entire draft.
        if editor.textColor != theme.textPrimary { editor.textColor = theme.textPrimary }
        editor.insertionPointColor = theme.accent
        editor.backgroundColor = theme.canvas
        scroll.backgroundColor = theme.canvas
    }
}
