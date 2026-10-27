# AI chats

The app product is **TheAll.app**, version **0.1.5**. Debug windows and menus use **TheAll dev**; Release uses **TheAll**. Every new tab, split pane,
and workspace starts at a Claude / OpenAI selector. Restored leaves reopen their saved chat. Existing panes
retain their connection form, process, conversation, and draft across navigation.

Choose a project folder, then select a provider to reuse its saved API connection, or enter an API key and
optional Base URL. The model field is a dropdown. The connection form's refresh button loads models
from that endpoint; the chat loads its catalog automatically and has no refresh button. The default or previously saved model remains available if
model discovery fails. The API list describes endpoint availability, not a promise
that every listed model supports the coding agent's tools or context requirements.

After connecting, TheAll provides a native chat transcript and input box. The model
dropdown sits directly to the left of Send/Stop below the input; the clickable working-folder path is at the left edge of that row. The model-change hint appears only after changing the model and disappears when a message is submitted with that selection. Changing it affects the **next submitted message**:
it does not interrupt a running turn, replace the process, erase history, or alter
the draft. Send with the button or Cmd+Return; Return inserts a newline. Stop
interrupts the active turn. In the native composer, Up on the first visual line recalls
older questions from the current conversation; Down on the last visual line moves
forward and restores the draft and caret saved before browsing. Recalled questions
can be edited and sent again without changing their original transcript entries.
History is also available after restoring a saved conversation. Multiline cursor
movement, selected text, modified arrows and input-method candidate selection stay
native. A phone message arriving during browsing is included on the next browsing
pass; it does not replace the saved desktop draft. All tool operations run automatically, including file edits,
deletions, dependency installation, tests and pushes, as explicitly selected by the user.
Only questions requiring a user answer appear above the input. Routine Bash/Read/tool records are
hidden; actual provider thinking/summary text is shown expanded during generation.
After a successful final reply, thinking and intermediate progress messages collapse
individually; clicking a disclosure reveals its original content. Expansion choices
persist while scrolling. Failed/interrupted turns remain visible. Claude uses the
canonical result and stop reasons; Codex uses message phases, retaining partial/final
answers and conservatively keeping multiple final blocks for older protocols.
User questions have an accent-tinted card and a colored leading border, separate from
the plain answer and muted thinking styles. The busy spinner precedes the current turn's Thinking label, with a label-only placeholder until thinking text arrives. It pauses while a question is pending and stops at turn completion; the composer has no busy spinner.
Tool failures remain available, and hiding routine records never hides pending questions.
Claude stream/final thinking blocks and Codex reasoning summaries are deduplicated;
encrypted signatures and redacted blocks are never rendered. Reading older messages does not force
the transcript back to the latest output. A button at the transcript's bottom right appears only while away from the bottom
and returns to the latest message. Native NSScrollView clip/document observations keep
its visibility accurate during scrolling, resizing and collapsing messages.
A horizontal divider before each subsequent user question separates conversation rounds.

After the first successfully submitted question, a workspace with a default name
gets a concise title extracted locally from that question. This requires no extra API
request. The name and completed naming state persist across restarts; later questions
or other split panes do not overwrite it. Manual names, including manually confirming
the same default name, are preserved. The owning workspace is found by terminal ID,
so switching workspaces while submission is pending cannot rename the wrong one.
Old saved workspaces with Default/workspace N names remain eligible; custom names are retained.

Connections are separate macOS Keychain items per provider and app bundle ID.
Endpoint, key, model, and Claude authentication method are saved together. Model
selection updates the matching saved connection for subsequent panes without
changing other already-open chats. A concurrent connection edit in another pane
is never overwritten with stale credentials. Keys never enter workspace persistence,
shell history, command-line arguments, or repository configuration.

Keychain operations never open a system authentication dialog. `PersistentAICredentialStore`
uses a dedicated, signed helper over private stdin/stdout pipes. It validates both
the helper on disk and the actual child process before sending a key; the helper
validates its actual parent process against the app identifier and certificate.
The helper has hardened runtime enabled without debugging or library-validation
exceptions. It starts with a clean environment and never logs credential data.

The helper is installed once in `Application Support/<bundleID>/CredentialHelper/<certificateHash>/v1/`
and reused byte-for-byte across app rebuilds. This is necessary because modern
file-based Keychains enforce a CDHash partition for self-signed executables in
addition to the certificate ACL. A fixed certificate alone does not stabilize that
partition. Do not delete, overwrite or re-sign an installed helper during updates.
A future helper upgrade must use the old helper to migrate to a new namespace.

Current connections use `.ai-connections.v3`. Accessible v2/legacy connections
migrate automatically; inaccessible legacy data remains untouched and the form
asks for a one-time API-key re-entry into the new store. Non-secret migration
markers prevent Forget from resurrecting old records. Locked or inaccessible
current items still return an error. Keys remain protected Keychain items, never
plaintext Application Support files or broadly accessible ACL entries.

Local builds require a persistent signing certificate configured by
`scripts/setup-local-signing.sh` or an Apple development identity; keep it across
rebuilds and do not override it with `CODE_SIGN_IDENTITY=-`.
See [local signing](build.md#theall-本地签名与钥匙串).

## Photos

Drag image files into the desktop conversation or input box, use the photo button beside the working folder, or paste a screenshot/image with **⌘V**. The drop area highlights while hovering. Up to four photos can be attached; dropping only adds a draft attachment and never sends a message or inserts a file path into the text. Thumbnails appear above the input; click to preview or remove one before sending. Photos can be sent with a question or without text. The selected provider/model must support image input.

The desktop accepts system-decodable images, including JPEG, PNG and HEIC, up to 20 MB per source. It corrects orientation, reduces the longest side to 2048 pixels, and creates a metadata-free JPEG/PNG copy of at most 2 MB. Originals are not changed. Prepared photos are saved privately in `ChatHistory/Attachments`; history and unsent desktop drafts retain references across restarts. The app sends the prepared copy to the AI endpoint through Claude Code or Codex when you press Send. Missing/unreadable attachments report an error and are not silently omitted.

Photo selection/import does not send a message. A failed send or rejected model switch preserves attachments. Recalling older text with ↑ / ↓ does not automatically reattach historical photos. Remote messages keep the desktop text and photo draft intact.

The phone Web App offers the same selection, removal and history previews. It compresses each upload to at most 512 KiB before sending; an unsupported browser photo format shows a conversion error. Phone drafts remain in memory per conversation. History photos require the same device/workspace authorization as their messages and are never cached by the Service Worker.

## Conversation persistence

Native chats are saved per terminal UUID in `Application Support/<bundleID>/ChatHistory/`.
Atomic JSON snapshots include provider, model, folder, text/photo draft, messages with photo references and the backend
session ID. A serial background writer checkpoints continuous changes every 300ms;
application termination and pane detachment flush pending changes. The directory is
0700 and files are 0600. API connections/credentials remain in Keychain, not snapshots.

Photo messages or drafts use snapshot v2; this build reads both v1 and v2. Older builds reject v2 rather than overwrite a conversation while dropping its photos. Keep this build or a newer one to reopen chats that contain photos.

Relaunch immediately restores the visible history, including completed progress
collapse flags, then reconnects to the original Claude session or Codex thread. Missing
credentials or backend history produce an error with the local transcript/draft intact;
the app never silently starts an empty thread. Interrupted work is not automatically
resubmitted. Changing connection settings preserves the same provider's chat.

Older versions did not persist the terminal-to-session mapping. The setup screen and empty Claude chats offer
“Restore an older Claude conversation…”, which lists transcripts from this app's Claude
configuration directory, with title, date and folder. Explicitly choose one to import;
no guessed match or shared CLI-home scan is performed. Import stops the empty
backend first, keeps the selected model and draft, and checkpoints the chosen session
under the current terminal UUID so later reopenings go straight to that conversation. Original JSONL files are untouched.
This legacy importer is for Claude; new snapshots restore both Claude and Codex.

## Backends

- `AILaunchConfiguration` creates executable, argv and per-process environment.
  `AIChatProcess` uses private stdin/stdout pipes; there is no shell-command injection.
- Claude Code runs persistently in `--print --input-format stream-json
  --output-format stream-json --verbose --include-partial-messages
  --permission-prompt-tool stdio --dangerously-skip-permissions` mode. The host acknowledges the SDK `initialize`
  and `set_model` control protocol, then sends the next user message. It waits for
  the model acknowledgement before sending, and keeps the draft on failure.
  `result` ends a turn, not the process. Background questions survive parent-turn
  completion until answered or cancelled. Tested with Claude Code **2.1.308**.
- Claude retains the app-owned `CLAUDE_CONFIG_DIR` and `--setting-sources ''` used by
  the previous connection implementation. Keys are `ANTHROPIC_API_KEY` or the
  selected `ANTHROPIC_AUTH_TOKEN`; endpoint is `ANTHROPIC_BASE_URL`. The default is
  `https://api.anthropic.com`. Gateways must support Anthropic Messages. A changed
  model can trigger Claude's own model-validation request before the next prompt.
- Codex uses `app-server --listen stdio://`, initializes one thread, and submits
  each turn using that thread's ID plus the chosen `model`. The CLI default is
  resolved through `model/list`, so choosing Default after another model actually
  sends the default model. Its custom provider remains `theall` with
  `THEALL_OPENAI_API_KEY`, `wire_api="responses"`, and
  `requires_openai_auth=false`. Default Base URL is `https://api.openai.com/v1`.
  No `codex login` or writes to the user's auth.json/config.toml are performed.
  Launch configuration sets `approval_policy="never"` and `sandbox_mode="danger-full-access"`.
  `thread/start` explicitly uses `approvalPolicy="never"` and `sandbox="danger-full-access"`;
  every `turn/start` repeats `approvalPolicy="never"` and
  `sandboxPolicy={"type":"dangerFullAccess"}`, including after changing folders.
  Stop waits for `turn/started`. Tested with Codex **0.162.1**.
- Tool execution does not show Allow cards. Native full-access modes are the primary
  policy; compatibility permission callbacks are also answered automatically.
  Claude forwards the original input unchanged for all tools except `AskUserQuestion`.
  Codex accepts command/file requests, handles legacy decision formats, and returns
  requested permissions. This also covers child-agent requests and numeric ID zero.
  No shell parsing, command rewriting, or shared persistent permission rules are used.
  Structured questions still require real answers; they are never filled in by the
  automatic permission handler. Unknown protocol requests return explicit errors
  rather than being left waiting. CLI updates need protocol compatibility testing,
  particularly Claude's SDK stdio transport.
- `AIModelCatalog` requests OpenAI `<base>/models` or Anthropic `<base>/v1/models`
  (without duplicating `/v1`) using the selected authentication. It follows
  Anthropic pagination, refuses redirects, uses an ephemeral URLSession, and does
  not display raw gateway error bodies. Failed discovery leaves existing choices.
- Executables are found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  and inherited PATH. No software is installed automatically. Remote endpoints
  require HTTPS; loopback HTTP is allowed for local gateways.

## Scope and persistence

The native composer replaces the CLI's terminal UI. Existing processes in an
already-running older build are unchanged until that app is restarted; they are
not imported into new native chats. Within a running pane, model switches preserve
the entire backend conversation. App-relaunch conversation restore, migration of
legacy shell actions/resume settings, and sidebar status-hook integration remain
separate future work. Connection settings ends the current chat after confirmation.

The working directory starts from the pane's saved/inherited directory, falling
back to the user's home directory. It is selectable before connection and through
the folder path at the bottom of the chat. Changes are persisted in TerminalPwdStore
for pane inheritance and relaunch. Switching waits for an idle chat with no pending questions.
Claude restarts with the same `--resume` session ID, the selected process cwd,
and automatic execution enabled. Codex keeps its
process/thread and sends `cwd` on each `turn/start`. Both preserve transcript and
draft. A restart failure leaves those visible and allows choosing a folder again.
Conversation output and draft are retained in
memory by TheAll; the CLIs may maintain their normal local session records. CLI
exit leaves the visible transcript and unsent draft intact and disables sending.

The underlying Ghostty view remains available to existing code. It now resets
synthetic link-hover modifiers before wheel events and briefly redraws a visible
unfocused pane when scrolling without moving keyboard focus.

## Validation

`AIChatTests` covers persistent conversation IDs, selecting during generation,
unsent drafts, failed model changes, default-model restoration, stream deduplication,
automatic tool replies (including numeric ID zero and child-agent requests),
structured questions, current-turn thinking indicators, thinking/tool visibility,
folder changes, and model request URL/authentication. Protocol fixtures cover the
reported shell loops, pipelines, npm/pytest commands, writes, deletion, dependency
installation and push requests without executing those payloads.

The chat tests also launch the real installed CLIs against
`TheAllTests/Fixtures/ai_gateway.py`, with fake keys, isolated config directories and
a temporary working directory. Two turns must use different models and retain
history, then change the project folder and continue the same conversation. Both
backends execute a local `npm test` fixture through a shell pipeline without a
pending approval; the test checks its output and the file written by the script.
This integration case skips if the CLIs are not installed; it never sends to a real
provider. AppKit preview tests cover conversation dividers, the native composer and model footer,
and pressing the bottom button after scrolling up. First-message callbacks are checked
for success, failure and once-only delivery; `WorkspaceStoreTests` covers naming ownership,
manual protection, old-data migration and persistence across restarts.
`AITerminalTests` uses isolated Keychains with fake keys to cover helper installation,
new helper processes, modern partition ACLs, legacy migration,
inaccessible ACLs, re-entry, Forget, locking, and restoration of the process
interaction setting. `TerminalScrollingTests` uses a real Ghostty PTY mouse-report
fixture to check hover/scroll modifiers and preservation of focus.

Run `python3 TheAllTests/Fixtures/credential_helper_relaunch.py` to verify the
production helper/store with two differently compiled, identically signed client
apps. It uses its own temporary certificate and modern Keychain, proves relaunch
and app rebuilds preserve access, rejects an unrelated signed parent, and removes
all fixtures afterward. Temporary signing keys use an isolated legacy-format
Keychain to avoid signing authorization prompts; fake API items use modern format.

References: [Codex app server](https://learn.chatgpt.com/docs/app-server),
[Claude SDK configuration](https://code.claude.com/docs/en/agent-sdk/configuration),
[Claude approvals and questions](https://code.claude.com/docs/en/agent-sdk/user-input).

## Branding and updates

App branding, source paths, targets and the module use TheAll. Defaults, config
keys and hook environment variables use the `theall` / `THEALL` namespace.
An existing signed installation can retain its application identifier through
ignored local configuration; an explicit previous namespace enables one-time
settings migration before stores initialize. See [Build guide](build.md).
Legacy Keychain connections migrate as described above. The current LICENSE,
separately granted permissions and third-party component licenses apply.
Automatic updates remain inactive until TheAll has its own feed and signing
key. No release is published by a local build.
