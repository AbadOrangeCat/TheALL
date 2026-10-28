# TheAll mobile web client validation

The installable app shell lives in `TheAll/Mobile/MobileWeb.bundle`. It has no npm runtime dependencies or build step. The Mac serves it at the same HTTPS origin as the API. iOS/iPadOS Safari and Android Chrome can add it to the home screen.

## Checks

```sh
node --test mobile-tests/*.test.mjs
node mobile-tests/browser-smoke.mjs
```

The first command uses only Node's standard library. The second starts an isolated headless Chrome profile and a mock API on localhost. It never contacts a real TheAll instance, uses no real API key, and cleans up its browser profile. Set `CHROME_BIN` if Chrome is installed at a different path; set `SCREENSHOT_PATH` to choose the preview destination. It checks pairing, latest/older history, resume eligibility, safe rendering, small-screen layout, drafts, uncertain request retries, offline controls, question inputs, initial-offline recovery, history invalidation after a Mac restart, real browser WebSocket upgrade/push/reconnect/fallback, read-only and workspace scope changes, revocation, and five-language switching/persistence. A screenshot is saved outside the repository for inspection.

## Behavior and integration contract

- The API owns all persistent workspace/chat state. The web app only holds transcripts, drafts, model choices, question answers, and pending actions in memory. It does not write these to local storage, session storage, IndexedDB or Cache Storage.
- A pairing token is read from `#pair=…` and the entire fragment is immediately removed with `history.replaceState`. Pairing sends the token in a JSON POST; normal API calls use the server's HttpOnly cookie. Client-side rendering never receives provider credentials.
- All fetches use `credentials: same-origin`, `cache: no-store`. POSTs use JSON and `X-TheAll-Client: 1`. Each business action freezes its UUID `requestId` and the current server `bootID`. Network errors, unknown server outcomes and `409 code=request_pending` retain the action. A definite Mac rejection (`code=operation_failed`) keeps the draft but permits editing; a lost backend acknowledgement (`code=outcome_unknown`) retains the original action. Only an explicit user retry sends that exact action again. No background mutation retries, queue or offline sends exist.
- A changed server generation is handled by the server's bootID validation. An old pending action is never silently assigned the new generation. Other 409 responses are displayed as explicit rejections; the user can inspect the chat before starting a new action.
- The client uses same-origin cookie-authenticated `/api/events` WebSocket notifications (no token in URL). A `hello` stops regular polling and triggers a fresh snapshot. `changed` notifications coalesce for 200 ms; JSON ping/pong runs every 20 seconds with a 10-second timeout. Reconnects back off from 500 ms to 10 seconds and only refetch snapshots. Disconnected clients fall back to polling every second for a busy selected chat, five seconds while idle, and fifteen seconds in the background. `revoked` immediately removes loaded data and returns to pairing. Conversation selection generations prevent an older chat response from replacing a new selection. Polling retains loaded history, reading position, drafts, model selection and question inputs.
- `access: { workspaceId: string|null, writable: boolean }` comes from pair/session/workspaces/chat snapshots and WebSocket hello. Missing access keeps legacy all-workspace write access. Read-only sessions hide mutations; scoped sessions can only create chats in the authorized workspace. A changed scope removes unauthorized cached content. Server authorization remains authoritative.
- Language selectors on pairing and the workspace sidebar support English, Simplified Chinese, French, Japanese, and Korean. Only the selected language is saved as `theall.language` in localStorage; changing it preserves in-memory drafts, transcript position and expanded thinking.
- History uses absolute `start` indices, `total`, and `before` pagination. Missing ranges are never presented as complete history. A changed bootID or inconsistent overlapping message IDs drops stale pages; fetching older history includes one overlapping message. `isReady || canResume` enables sending, allowing the server to resume a saved conversation on demand.
- `thinking` and `isIntermediate` messages are grouped per turn. On a formal assistant answer the group folds; a user can reopen it independently. Routine tool entries are hidden; tool errors remain visible. User messages use a distinct tinted surface. Message content is rendered through text nodes, with fenced code and HTTP(S) links only; HTML never executes.
- Service workers cache only the allowlisted public app shell. `/api/*`, non-GET, unknown query-bearing and external requests are never intercepted or cached. A navigation with exactly one valid `?chat=UUID` may fall back to the cached public root shell offline; its query is never cached. Installed-shell offline mode explains that the Mac cannot be reached and prevents execution.

- The notification settings button appears in the header and sidebar on mobile and is hidden in the desktop host. It reports HTTPS, iOS Home Screen, browser support, denied permission, old server, and enabled/disabled states. Permission is requested only from the Enable button gesture. Notification routes use the existing authenticated same-origin JSON requests and anti-CSRF header; read-only paired devices may manage their own subscription. Server status and a matching current PushManager application key are both required before showing enabled. A changed pairing identity discards stale browser subscriptions; disconnect removes the local subscription and reports cleanup failure. Language changes update an existing enabled subscription without prompting again.
- Push notifications contain only a generic localized completion message, with no workspace, transcript, key, or path. The worker displays directly from the payload without fetching API data. It stores only opaque delivery IDs and timestamps in a bounded IndexedDB store for push/click deduplication; notification bodies and subscription keys are never cached. A notification click accepts only this origin’s root with a UUID chat parameter; an active app receives an acknowledged message without losing drafts. Startup links and messages wait for authentication and resolve only against the latest authorized workspace list. Missing or expired grants return to normal pairing; notification clicks never send chat messages or repeat operations.
- Final assistant messages optionally expose `completedAt` (UTC ISO8601), `durationMs` (nonnegative number), and `completionStatus` (`completed`, `failed`, `interrupted`). The client formats local completion time and elapsed units in the selected language; old messages without timing are unchanged. Model capabilities expose `reasoningEfforts` and optional `defaultReasoningEffort`; `defaultModel` resolves the model picker’s empty/default selection. The effort control stays visible but disabled when no selectable levels are available. It offers the selected model’s actual options plus an empty provider-default choice, preserves compatible choices and resets unsupported choices only on an explicit model change. The frozen send request contains `reasoningEffort`.

Serve these exact static paths (and `/` as `index.html`):

```
/index.html
/app.js
/core.js
/live.js
/photos.js
/notifications.js
/timing.js
/effort.js
/i18n.js
/styles.css
/manifest.webmanifest
/sw.js
/icons/icon-192.png
/icons/icon-512.png
/icons/apple-touch-icon.png
```

Use JavaScript MIME for JS files, `application/manifest+json` for the manifest, PNG MIME for icons. Serve `/sw.js` at the origin root for its root scope. Scripts, CSS and fonts load from the same origin; no CDN assets are needed. The icons are the user's supplied TheAll artwork, resized to 192, 512 and 180 pixels.

## Device acceptance still required

The automated browser test uses a mock API. Verify against the integrated Mac API over the configured HTTPS relay, install on a real iPhone and Android device, and check reconnect after Mac sleep, phone keyboard/rotation, device revocation, a CLI turn, a pending question, and simultaneous desktop/phone messages. For task-completion alerts, install the HTTPS Web App on a real iPhone and Android phone, explicitly enable alerts, lock the phone, complete a desktop task, and verify the phone and paired Apple Watch / Wear OS routing under their notification and Focus settings. Physical-device notification delivery remains a manual acceptance check; this test never requests real notification permission or sends a real push. Native App Store packages and running tasks while the Mac is asleep are outside this client.
