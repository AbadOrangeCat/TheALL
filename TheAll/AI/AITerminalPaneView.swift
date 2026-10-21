import AppKit
import SwiftUI

/// The cached leaf of every split: connection setup followed by a native AI chat.
final class AITerminalPaneView: NSView {
    let session: AITerminalSession
    var workingDirectory: () -> String = { NSHomeDirectory() } {
        didSet { if session.chat == nil { session.directory = workingDirectory() } }
    }
    var onDirectoryChanged: ((String) -> Void)?
    var onFocusRequested: (() -> Void)?
    private var content: NSView?
    private let makeTransport: () -> any AIChatTransport

    init(session: AITerminalSession = AITerminalSession(),
         managesLifecycle: Bool = true,
         makeTransport: @escaping () -> any AIChatTransport = { AIChatProcess() }) {
        self.session = session
        self.makeTransport = makeTransport
        super.init(frame: .zero)
        if managesLifecycle {
            session.onLaunch = { [weak self] in self?.start($0) }
            session.onStop = { [weak self] in self?.showSetup() }
        }
        showSetup()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: AppTheme, locale: Locale) {
        session.theme = theme
        session.locale = locale
    }

    private func showSetup() {
        content?.removeFromSuperview()
        let hosting = NSHostingView(rootView: AITerminalContent(session: session, onChooseDirectory: { [weak self] in
            self?.chooseDirectory()
        }, onRestore: { [weak self] conversation in
            self?.restoreLegacyConversation(conversation)
        }, onForget: { [weak self] in
            self?.confirm(title: "ai.forget.title", detail: "ai.forget.detail", button: "ai.forget") {
                self?.session.forgetConnection()
            }
        }, onFocus: { [weak self] in self?.onFocusRequested?() }, onEdit: { [weak self] in
            self?.confirm(title: "ai.stop.title", detail: "ai.stop.detail", button: "ai.stop.confirm") {
                self?.session.editConnection()
            }
        }))
        content = hosting
        addSubview(hosting)
        needsLayout = true
    }

    private func start(_ configuration: AILaunchConfiguration) {
        session.startChat(configuration, directory: session.directory, transport: makeTransport())
        showChat()
    }

    func restoreHistory(for terminalID: UUID, store: AIChatHistoryStore = .shared) {
        session.restoreHistory(for: terminalID, store: store, transport: makeTransport())
        if session.chat != nil {
            onDirectoryChanged?(session.directory)
            showChat()
        }
    }

    private func restoreLegacyConversation(_ conversation: AIChatLegacyConversation) {
        guard session.restoreLegacyConversation(conversation, transport: makeTransport()) else { return }
        onDirectoryChanged?(session.directory)
        showChat()
    }

    private func showChat() {
        DispatchQueue.main.async { [weak self] in self?.focusComposer() }
    }

    private func chooseDirectory() {
        guard let window, session.chat?.canChangeDirectory != false else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("ai.directory.choose")
        panel.directoryURL = URL(fileURLWithPath: session.chat?.directory ?? session.directory)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let chat = self.session.chat, !chat.changeDirectory(url.path) { return }
            self.session.directory = url.path
            self.onDirectoryChanged?(url.path)
        }
    }

    func focusComposer() {
        guard session.chat != nil, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        if let input = content.flatMap({ editor(in: $0) }), window?.firstResponder !== input {
            window?.makeFirstResponder(input)
        }
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }

    private func confirm(title: String, detail: String, button: String, action: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string(title)
        alert.informativeText = L10n.string(detail)
        alert.addButton(withTitle: L10n.string(button))
        alert.addButton(withTitle: L10n.string("ai.cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }
}

private struct AITerminalContent: View {
    @Bindable var session: AITerminalSession
    let onChooseDirectory: () -> Void
    let onRestore: (AIChatLegacyConversation) -> Void
    let onForget: () -> Void
    let onFocus: () -> Void
    let onEdit: () -> Void

    var body: some View {
        if let chat = session.chat {
            AIChatView(session: session, chat: chat, onFocus: onFocus, onEdit: onEdit,
                onChooseDirectory: onChooseDirectory, onRestoreLegacy: onRestore)
        } else {
            AIConnectionForm(session: session, onChooseDirectory: onChooseDirectory,
                             onRestore: onRestore, onForget: onForget)
        }
    }
}

private struct AIConnectionForm: View {
    @Bindable var session: AITerminalSession
    let onChooseDirectory: () -> Void
    let onRestore: (AIChatLegacyConversation) -> Void
    let onForget: () -> Void
    private var theme: AppTheme { session.theme }
    private func text(_ key: String) -> String { L10n.string("ai." + key) }

    var body: some View {
        // Observe locale even though strings are resolved through L10n for the
        // AppKit-hosted form, matching the language preference of the rest of UI.
        let _ = session.locale
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TheAll")
                    } icon: {
                        Image("TheAllLogo").resizable().renderingMode(.original)
                            .scaledToFit().frame(width: 16, height: 16)
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: theme.accent))
                    Button(action: onChooseDirectory) {
                        Label(session.directory, systemImage: "folder")
                            .font(.caption).lineLimit(2).truncationMode(.middle)
                    }.buttonStyle(.borderless).help(L10n.string("ai.directory.choose"))
                    if let provider = session.provider {
                        connectionFields(provider)
                    } else {
                        Text(text("choose.title")).font(.system(size: 26, weight: .semibold))
                        Text(text("choose.detail"))
                            .foregroundStyle(Color(nsColor: theme.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 12) {
                            ForEach(AIProvider.allCases) { provider in
                                HStack(spacing: 0) {
                                    Button { session.choose(provider) } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: provider == .claude ? "sparkle" : "command")
                                                .font(.system(size: 22)).frame(width: 28)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(provider.title).font(.headline)
                                                Text(provider.tool).font(.caption)
                                                    .foregroundStyle(Color(nsColor: theme.textSecondary))
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "arrow.right")
                                        }.padding(18).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Button { session.choose(provider, edit: true) } label: {
                                        Image(systemName: "slider.horizontal.3").padding(16)
                                    }
                                    .buttonStyle(.plain)
                                    .help(text("settings"))
                                    .accessibilityLabel(provider.title + " " + text("settings"))
                                }
                                .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: theme.border)))
                            }
                        }
                        Label(text("storage"), systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = session.errorMessage {
                        Text(error).font(.callout).foregroundStyle(Color(nsColor: theme.danger))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let error = session.historyError {
                        Text(error).font(.callout).foregroundStyle(Color(nsColor: theme.danger))
                    }
                    if session.provider != .openai {
                        AILegacyHistoryButton(session: session, onRestore: onRestore)
                    }
                }
                .frame(maxWidth: 460)
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .foregroundStyle(Color(nsColor: theme.textPrimary))
        .background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    @ViewBuilder private func connectionFields(_ provider: AIProvider) -> some View {
        Button { session.back() } label: { Label(text("back"), systemImage: "chevron.left") }
            .buttonStyle(.plain).foregroundStyle(Color(nsColor: theme.textSecondary))
        Text(provider.tool).font(.system(size: 26, weight: .semibold))
        Text(text(session.hasSavedConnection ? "saved" : "configure"))
            .foregroundStyle(Color(nsColor: theme.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API Key").font(.callout.weight(.medium))
                SecureField("API Key", text: $session.draft.apiKey).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text("url")).font(.callout.weight(.medium))
                TextField(provider.defaultBaseURL, text: $session.draft.baseURL).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Base URL")
                Text(text(provider == .claude ? "claude.urlHint" : "openai.urlHint"))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text("model")).font(.callout.weight(.medium))
                AIModelPicker(session: session, selection: $session.draft.model)
                if let error = session.modelError {
                    Text(error).font(.caption).foregroundStyle(Color(nsColor: theme.danger))
                }
            }
            if provider == .claude {
                Toggle(text("bearer"), isOn: $session.draft.useBearerToken).font(.caption)
            }
        }
        Text(text("validation")).font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(text("saveOpen")) { session.saveAndLaunch() }
                .buttonStyle(.borderedProminent)
                .disabled(session.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer(minLength: 8)
            Button(text("forget"), role: .destructive, action: onForget).buttonStyle(.borderless)
        }
    }
}

struct AILegacyHistoryButton: View {
    @Bindable var session: AITerminalSession
    let onRestore: (AIChatLegacyConversation) -> Void
    @State private var legacyConversations: [AIChatLegacyConversation] = []
    @State private var showsLegacyHistory = false
    @State private var selectedLegacyConversation: AIChatLegacyConversation?
    @State private var loadingHistory = false
    @State private var legacyError: String?
    private var theme: AppTheme { session.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.string("ai.history.restoreLegacy")) { loadLegacyHistory() }
                .buttonStyle(.borderless).disabled(loadingHistory || session.historyError != nil)
            if loadingHistory { ProgressView().controlSize(.small) }
            if let legacyError {
                Text(legacyError).font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary))
            }
        }
        .sheet(isPresented: $showsLegacyHistory, onDismiss: {
            let selected = selectedLegacyConversation
            selectedLegacyConversation = nil
            if let selected { onRestore(selected) }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("ai.history.restoreLegacy")).font(.headline)
                Text(L10n.string("ai.history.legacyDetail")).font(.callout)
                    .foregroundStyle(Color(nsColor: theme.textSecondary))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(legacyConversations) { conversation in
                            Button {
                                selectedLegacyConversation = conversation
                                showsLegacyHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(conversation.title).font(.body).lineLimit(2)
                                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary))
                                    Text(conversation.directory).font(.caption).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(Color(nsColor: theme.textSecondary))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack { Spacer(); Button(L10n.string("ai.cancel")) { showsLegacyHistory = false } }
            }.padding(20).frame(width: 540, height: 420)
                .foregroundStyle(Color(nsColor: theme.textPrimary)).background(Color(nsColor: theme.canvas))
        }
    }

    private func loadLegacyHistory() {
        loadingHistory = true
        legacyError = nil
        let root = AILaunchConfiguration.claudeConfigurationDirectory
        Task { @MainActor in
            do {
                legacyConversations = try await Task.detached(priority: .userInitiated) {
                    try AIChatLegacyHistory.conversations(root: root)
                }.value
                if legacyConversations.isEmpty { legacyError = L10n.string("ai.history.none") }
                else { showsLegacyHistory = true }
            } catch { legacyError = L10n.string("ai.history.loadFailed") }
            loadingHistory = false
        }
    }

}
