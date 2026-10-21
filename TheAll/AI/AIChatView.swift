import AppKit
import SwiftUI

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
                ForEach(session.models) { model in Text(model.title).tag(model.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 300, alignment: showsRefresh ? .leading : .trailing)
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
    private var theme: AppTheme { session.theme }

    var body: some View {
        let _ = session.locale
        VStack(spacing: 0) {
            HStack {
                Label(session.provider?.tool ?? "AI", systemImage: "sparkles").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Button(L10n.string("ai.settings"), action: onEdit).buttonStyle(.borderless).font(.caption)
            }
            .padding(12)
            .background(Color(nsColor: theme.sidebar))
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
                AIChatComposer(text: $chat.input, theme: theme, onFocus: onFocus, onSend: send)
                    .frame(height: 88)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: theme.border)))
                HStack(spacing: 8) {
                    Button(action: onChooseDirectory) {
                        Label(chat.directory, systemImage: "folder")
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: theme.textSecondary))
                    .disabled(!chat.canChangeDirectory)
                    .help(chat.directory + "\n" + L10n.string(chat.canChangeDirectory ? "ai.directory.choose" : "ai.directory.busy"))
                    .accessibilityLabel(L10n.string("ai.directory.choose") + ": " + chat.directory)
                    Spacer(minLength: 0)
                    AIModelPicker(session: session, selection: Binding(get: { chat.model }, set: { session.selectModel($0) }), showsRefresh: false)
                    if chat.isBusy {
                        Button(L10n.string("ai.chat.stop")) { chat.interrupt() }
                            .disabled(!chat.canInterrupt)
                    } else {
                        Button(L10n.string("ai.chat.send"), action: send)
                            .buttonStyle(.borderedProminent)
                            .disabled(!chat.isReady || chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .padding(12)
            .background(Color(nsColor: theme.sidebar))
        }
        .foregroundStyle(Color(nsColor: theme.textPrimary))
        .background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear { if session.models.isEmpty { session.refreshModels() } }
    }

    private var transcript: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
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
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(message.role == .user ? L10n.string("ai.chat.you") : session.provider?.tool ?? "AI")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: message.role == .user ? theme.accent : theme.textSecondary))
                                    Text(message.role == .user ? AttributedString(message.text) :
                                        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                                        .textSelection(.enabled).font(.system(size: 14)).lineSpacing(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(message.role == .user ? 12 : 0)
                                .background {
                                    if message.role == .user {
                                        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: theme.accentMuted))
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
                    }.padding(.horizontal, 20).padding(.top, 20)
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
        chat.send()
        forceScroll += 1
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
private struct AIChatComposer: NSViewRepresentable {
    @Binding var text: String
    let theme: AppTheme
    let onFocus: () -> Void
    let onSend: () -> Void

    final class Editor: NSTextView {
        var onFocus: (() -> Void)?
        var onSend: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                onSend?()
            } else { super.keyDown(with: event) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatComposer
        init(_ parent: AIChatComposer) { self.parent = parent }
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
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.font = .systemFont(ofSize: 14)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(L10n.string("ai.chat.input"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.string != text { editor.string = text }
        editor.onFocus = onFocus
        editor.onSend = onSend
        editor.textColor = theme.textPrimary
        editor.insertionPointColor = theme.accent
        editor.backgroundColor = theme.canvas
        scroll.backgroundColor = theme.canvas
    }
}
