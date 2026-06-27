# Rounds — Project Rules

## Amplitude analytics key is injected at build time — never commit it

The repo is PUBLIC. The Amplitude ingestion key must NOT live in any tracked file. It is injected at build time: `Info.plist` has `AmplitudeAPIKey = $(AMPLITUDE_API_KEY)`; `tools/notarize.sh` sources the gitignored `secrets/amplitude.env` (`AMPLITUDE_API_KEY=…`) and passes it as an xcodebuild build setting; `AnalyticsService.apiKey` reads `Bundle.main.object(forInfoDictionaryKey: "AmplitudeAPIKey")` and treats an empty value or an unexpanded `$(` placeholder as DISABLED. So a clean public-repo build (no `secrets/`) ships with analytics off. Do NOT hardcode the key in `AnalyticsService.swift`, `Info.plist`, or `notarize.sh`; do NOT remove the Info.plist key or the secrets-sourcing line (that silently disables analytics in releases). Keep the `sanitize()` allowlist chokepoint intact — only event-name + enum/numeric props ever leave, never content.

## Mid-stream sends queue — do NOT re-add an isStreaming send-guard

Typing + Enter/click while a turn is streaming is allowed: the message is QUEUED (grey deletable chips in the input bar, `ChatRuntime.queued`) and auto-dispatched FIFO the instant the turn ends. Do NOT re-add `app.isStreaming`/`isStreaming` guards to the send path — there are TWO widgets that each had one (`MentionField.trySend` + its send-button `.disabled`, and `ChatView.send`); re-adding any of them silently makes the queue unreachable. `runQueue` owns `isStreaming` for the WHOLE drain (set true in `ChatRuntime.send` before the Task, reset only on NON-cancelled completion so a Stop→immediately-send can't be clobbered). `stop()` clears `queued`. The warm session is strictly one-turn-at-a-time (`runQueue` awaits each `runTurn` fully before the next), so never start a second `WarmSession.send` concurrently.

## App Sandbox

App Sandbox is intentionally disabled (`ENABLE_APP_SANDBOX = NO` in project.pbxproj).
Rounds spawns the `claude` CLI as a subprocess; sandboxing blocks that exec and produces no useful error.
<!-- auto-added 2026-06-20 -->

## Cmd+W on Home tab

`cmd+w` on the Home tab must be a no-op — do NOT close the app or window. Only chat/file tabs should close on `cmd+w`.
<!-- auto-added 2026-06-20 -->

## Sources panel placement

`SourcesPanel` must live inside the center pane, NOT as a third column in `HSplitView`. A third column causes the left sidebar to jump in width whenever sources appear/disappear.
<!-- auto-added 2026-06-20 -->

## Slash command pass-through in chatPrompt

`chatPrompt()` in `AppState.swift` detects messages that start with `/` and returns them **raw** — no health-context framing, no reference block — so Claude Code's own command machinery (e.g. `/help`, `/model`, skills) can handle them. Do not remove or reorder this check when editing `chatPrompt()`.
<!-- auto-added 2026-06-21 -->

## Brain prompt regeneration

`rounds/Brain/BrainResources.swift` is a generated file. After editing any file in `brain/prompts/` or `brain/claude/CLAUDE.md`, bump `brainVersion` in `tools/gen_brain_resources.py` and run `python3 tools/gen_brain_resources.py` to regenerate it — otherwise the running app sees stale prompts.
<!-- auto-added 2026-06-21 -->
When adding a **new** prompt file to `brain/prompts/`, also add a `write(BrainResources.<name>, to: vault.promptsDir.appendingPathComponent("<name>.md"))` call in `rounds/Brain/BrainInstaller.swift` — otherwise the new prompt is embedded in the binary but never written to disk at vault setup time.
<!-- auto-added 2026-06-21 -->

## No medical disclaimers in UI or brain output

Do NOT add static disclaimer text (e.g. "not medical advice", "consult your doctor") to the chat footer, input area, or any other UI surface. Do NOT instruct the brain prompt to append such caveats to responses. The user found this annoying; appropriate framing lives in the system prompt, not in repeated UI noise.
<!-- auto-added 2026-06-21 -->

## Chat scroll: sticky-bottom only

Auto-scroll to the bottom during streaming ONLY if the user is already at the bottom (`atBottom == true`). If the user has scrolled up, do NOT force-scroll. Resume auto-scroll once the user returns to the bottom.
<!-- auto-added 2026-06-21 -->

## UI font scaling (⌘+/⌘−)

macOS ignores SwiftUI's Dynamic Type / `@Environment(\.font)` scaling, so `cmd+`/`cmd-` zoom MUST be implemented via `scaleEffect` on the root view, with a `GeometryReader` that adjusts the logical frame to `size / scale` so the scaled content still fills the window. Do NOT try to propagate a font size through the environment — it won't affect most controls.
<!-- auto-added 2026-06-21 -->
After `.scaleEffect(s, anchor: .topLeading)` you MUST add a second `.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)` — without it hit-testing uses the un-zoomed coordinate space and clicks land on the wrong targets. Also use `anchor: .topLeading` (not `.center`) or the view overflows the window at larger scales.
<!-- auto-added 2026-06-21 -->

## Tab drag-and-drop in CenterTabBar

Use `.draggable(item.id)` + `.dropDestination(for: String.self)` (NOT `onDrag`/`onDrop`/`DropDelegate`) for tab reordering. The `DropDelegate` approach silently breaks on macOS and produces no movement.
<!-- auto-added 2026-06-21 -->

## Nested drop zones flicker: debounce the overlay OFF transition

When an outer `onDrop` and inner drop zones each have an `isTargeted` binding, the drag hand-off between them momentarily reports "no target", causing the overlay to flicker. Drive overlay visibility from a latched `showDropZones` bool: set it immediately when ANY `isTargeted` turns true, and clear it only after a ~180 ms `DispatchWorkItem` debounce (cancel on re-entry). Do NOT drive overlay visibility from `dropTargeted` alone when multiple zones share the drag.
<!-- auto-added 2026-06-26 -->

## Claude Code must run unrestricted (full power = true bypass, no gating)

In **Full Power** mode (the default, `fullPowerActive`), chat runs Claude Code FULLY UNRESTRICTED — exactly like the VS Code extension in bypass mode. There is NO per-action approval dialog and NO hard-deny list. Concretely:
- `baseRun` passes `--permission-mode bypassPermissions` (`mode = .bypass`) when full power.
- `PermissionBroker.writeEffectiveSettings` clears `permissions.deny` to `[]`, sets `permissions.defaultMode = "bypassPermissions"`, and **drops the PreToolUse hook** for full power. (Safe mode keeps the brain's restrictive deny-list, still no hook.)
- Do NOT reintroduce `--disallowedTools` blocks or a blocking PreToolUse permission hook in full power. The user repeatedly and explicitly asked for an unrestricted Claude Code they fully trust; a gating dialog caused real bugs (Bash hard-denied → no PDFs; Write timed out into deny after 180 s → "files won't create").

The `permission-hook.mjs` + `PendingPermission`/`respondPermission` dialog code still exists but is **dormant** (never wired in either mode now). It's kept only as scaffolding if a future opt-in "ask me about shell" mode is wanted. Do NOT re-enable it by default.
<!-- updated 2026-06-24: was a blocking-dialog design; user wanted full trust -->
<!-- auto-added 2026-06-21 -->

## Slash command autocomplete in MentionField

`MentionField` shows a dropdown of Claude Code slash commands when the user types `/` at the start of their message. The list (`app.slashCommands`) is populated live from the `slash_commands` array in Claude Code's `system:init` event — do NOT hardcode it or remove this live-update path, since user-installed skills would then disappear from autocomplete.
<!-- auto-added 2026-06-22 -->

## Sparkle auto-updater

Rounds uses Sparkle (SPM: `sparkle-project/Sparkle >= 2.5.0`) for in-app updates — one click downloads, verifies, and relaunches. Do NOT remove `INFOPLIST_FILE = Info.plist` from build settings or revert to `GENERATE_INFOPLIST_FILE = YES`: the explicit `Info.plist` at the project root is required because Sparkle's EdDSA public key (`SUPublicEDKey`) lives there and a generated plist would discard it silently.
<!-- auto-added 2026-06-22 -->
Sparkle's default check interval is 24 h — far too infrequent for a Mac app that stays open for months. Set `updateCheckInterval = 3600` (Sparkle's enforced minimum) and register `NSWorkspace.didWakeNotification` + `NSApplication.didBecomeActiveNotification` observers in `SparkleUpdater.start()` to trigger a silent background re-check on wake/activation. Both the Info.plist key (`SUScheduledCheckInterval`) and the in-code assignment must be set.
<!-- auto-added 2026-06-24 -->

## Notarization

Notarize with `xcrun notarytool submit ... --keychain-profile "rounds-notary"`. The profile was set up once via `xcrun notarytool store-credentials`.
<!-- auto-added 2026-06-22 -->
Release builds must NOT include the `com.apple.security.get-task-allow` entitlement — Apple rejects notarization if it's present. Always archive/build with the Release configuration (or strip the entitlement explicitly); Debug builds inject it automatically.
<!-- auto-added 2026-06-22 -->
The app carries `rounds.entitlements` (`CODE_SIGN_ENTITLEMENTS`, both configs) with `com.apple.security.device.audio-input` — required for microphone/voice input under the hardened runtime. `tools/notarize.sh` re-signs the bundle inside-out, and the FINAL `codesign` of the main `.app` MUST pass `--entitlements "$ROOT/rounds.entitlements"`; a bare `codesign --sign` re-seal strips entitlements and silently kills mic access in the shipped build. Keep that flag, and keep the Sparkle nested helpers re-signed WITHOUT `--entitlements` (they don't need it).
<!-- auto-added 2026-06-27 -->

## macOS 14.0 deployment target and Compat.swift shims

`MACOSX_DEPLOYMENT_TARGET = 14.0`. Several SwiftUI APIs require macOS 15+ and must NOT be used directly — use the shims in `rounds/Views/Compat.swift` instead: `.linkCursor()` (not `.pointerStyle(.link)`), `.onHeightChange { }` (not `.onGeometryChange`). When adding new SwiftUI API, verify it's available on macOS 14 before using it; if not, add a compat shim.
<!-- auto-added 2026-06-22 -->

## PTY remote-control: local JSONL does not capture turns

In `--remote-control` PTY mode, conversation messages are NOT written to the local session JSONL — only an `ai-title` line appears there. To read turns back in Rounds, scrape the PTY output stream directly; do NOT tail the transcript file.
<!-- auto-added 2026-06-22 -->

## Remote control in stream-json mode: use control_request, not --remote-control flag

The `--remote-control` CLI flag is interactive-only and does nothing in stream-json mode. To enable remote control from Rounds' existing stream-json session, send a `control_request` on stdin after `system/init`: `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"remote_control","enabled":true,"name":"..."}}`. The `control_response` contains `session_url` for phone pairing. Phone messages arrive as ordinary `user` messages on the same stdout stream. Disable with `enabled:false`. This is an internal SDK protocol surface that can change between CLI versions.
<!-- auto-added 2026-06-22 -->
Pass `--replay-user-messages` at spawn time so phone-typed turns echo back on stdout and are rendered in the local Rounds transcript. Without this flag, messages sent from the phone are invisible locally.
<!-- auto-added 2026-06-22 -->
Phone-driven `.finished` turns MUST be parsed with the full `ProtocolParser.parse()` pipeline, NOT just `stripForDisplay()`. Without it, sources go stale, alerts are dropped, hypotheses are not saved, and step cards do not dismiss after the phone reply.
<!-- auto-added 2026-06-22 -->

## Chat session persistence: front-matter sessionId and --resume

Chat `.md` files store `sessionId: <id>` in their front-matter (written by `persistChat`, parsed by `VaultStore.frontMatter()`). `WarmSession` reads this via `config.resumeSessionId` and passes `--resume <id>` at startup — without it, reopened chats lose all Claude Code multi-turn memory. Do NOT change the `sessionId:` front-matter key or skip the `--resume` arg in `WarmSession`.
<!-- auto-added 2026-06-22 -->

## Chat input draft persistence across tab switches

Per-chat unsent draft text and `@`-references must live on `ChatRuntime` (as `draft` and `draftReferences`), NOT in `@State` inside `ChatView`. SwiftUI destroys `@State` when the view leaves the tab, silently clearing whatever the user had typed. `ChatRuntime` outlives the view and preserves the draft correctly.
<!-- auto-added 2026-06-22 -->

## Text selection in long-form markdown body

`MarkdownText`'s per-block renderer only lets the user select text within a single paragraph. For full cross-paragraph selection (e.g. expanded `HypothesisCard` body), render as `Text(MarkdownText.fullAttributed(content)).textSelection(.enabled)` instead. Exception: if the content contains tables (`MarkdownText.hasTable()`), keep the block renderer — `AttributedString` can't replicate the grid layout.
<!-- auto-added 2026-06-22 -->

## Full-power chat: file writes & shell just run (no hook, no dialog)

OBSOLETE design note (kept for context): full power used to route `Write|Edit|MultiEdit` through a blocking PreToolUse hook that surfaced a Rounds Allow/Deny dialog. That gating is GONE — see "Claude Code must run unrestricted" above. Full power now runs `bypassPermissions` with an empty deny-list and no hook, so Write/Edit/MultiEdit/Bash all execute directly. Do NOT re-add a hook matcher or `--disallowedTools` for these.
<!-- updated 2026-06-24 -->
<!-- auto-added 2026-06-23 -->

## Chat file message delimiters

Chat `.md` files use `<!-- rounds:msg role=<role> -->` HTML comment sentinels as message boundaries (written by `persistChat`, parsed by `loadChat`). Do NOT revert to `## role` headers — an assistant response containing a `## Heading` would be parsed as a role boundary and silently truncate the message on reload. Legacy files with `## role` are still parsed (bare role lines only, not in-body headings).
The sentinel also carries a message's attachments: `<!-- rounds:msg role=<role> refs=<base64-json of [Reference]> -->`. `persistChat` writes `refs=` when a message has references and `loadTranscript` decodes them back into `ChatMessage.references` — do NOT drop this, or file attachments (the thumbnails/inline images in the transcript) vanish on close/reopen even though the files survive in `chats/attachments/<chatId>/`. base64 has no spaces, so the role/refs split (`split(separator:" ", maxSplits:1)`) stays unambiguous.
<!-- auto-added 2026-06-23 -->

## Chat input: native NSTextView required

SwiftUI's `TextField(axis: .vertical).lineLimit(...)` does NOT scroll on macOS when text overflows the visible area. The chat input uses `ChatInputEditor` (`NSViewRepresentable` wrapping `NSTextView`) — do NOT replace it with a SwiftUI `TextField`.
<!-- auto-added 2026-06-23 -->

## ClaudeEngine: insert paragraph break between streaming text blocks

Claude's `stream-json` output emits narration segments (between tool calls) as separate `content_block_start`/`content_block_end` text blocks. Without a separator, the end of one block runs directly into the next ("…his case.Let me read…"). In `ClaudeEngine.swift`, emit `.textDelta("\n\n")` on every `content_block_start` where `content_block.type == "text"`.
<!-- auto-added 2026-06-23 -->

## WarmSession turn watchdog: idle timeout, not fixed duration

Do NOT use a fixed-duration turn timeout (e.g. 300 s) — it kills legitimate long-running turns (deep searches, building documents). Use an activity-based idle timeout instead: reset `lastActivityAt` on every stdout event; fire `finishTurn` only if the turn has been completely silent for `idleTimeout` seconds. A re-arming polling loop (every 30 s) is cheaper than a one-shot `asyncAfter` that can't distinguish "working" from "hung".
<!-- auto-added 2026-06-24 -->

## Amplitude analytics key: build-time secret injection

The Amplitude ingestion key is NEVER committed. Store it in `secrets/amplitude.env` (gitignored) as `AMPLITUDE_API_KEY=<key>`. `tools/notarize.sh` sources that file and passes the key to xcodebuild; `Info.plist` holds `$(AMPLITUDE_API_KEY)` which resolves at build time. `AnalyticsService.swift` reads `AmplitudeAPIKey` from `Bundle.main` and treats an empty value or unexpanded `$(` placeholder as "analytics disabled — no network calls". A clean checkout with no `secrets/` file silently disables analytics, which is correct for open-source builds.
<!-- auto-added 2026-06-25 -->

## Claude Code sign-in requires a real Terminal — `/login` is a no-op inside Rounds

Rounds spawns Claude Code non-interactively (no TTY, no browser flow). `/login` silently does nothing here. Users must sign in once in **Terminal** (`claude` → follow prompts) before Rounds can use Claude Code.
Auth is probed at startup via `claude auth status --json` → `ToolPaths.loggedIn`; `claudeNeedsLogin` (installed but `loggedIn == false`) blocks `checklistComplete` and shows a sign-in row in onboarding.
`ChatRuntime.looksLikeClaudeAuthError()` intercepts the "Not logged in · Please run /login" output and replaces it with clear Terminal-based instructions. Do NOT remove this interception or add `/login` as a chat command.
<!-- auto-added 2026-06-25 -->

## Slash commands all pass through to Claude Code

There are currently NO Rounds-native intercepted slash commands — every `/`-prefixed message is forwarded raw to Claude Code (see the `chatPrompt()` pass-through rule above). `ChatRuntime` has no `handleRoundsCommand()` anymore; it was only used for `/remote-control`, which was removed because Claude Code Remote Control is interactive-only and a no-op in Rounds' stream-json mode (see the `rounds-remote-control` memory). If you reintroduce a Rounds-native command, intercept it in `ChatRuntime.send()` BEFORE the turn is dispatched, AND keep the Dashboard ask box's `!text.hasPrefix("/")` guard in sync — otherwise `/`-commands silently land in the symptom interview instead of a chat.
<!-- auto-added 2026-06-22 -->
