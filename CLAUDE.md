# Rounds — Project Rules

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

## Claude Code must run unrestricted

Do NOT use `--disallowedTools` to hard-block Bash, WebSearch, sub-agents, or any other Claude Code tool. Run with `--permission-mode bypass` and surface any permission prompts in the UI. The user explicitly corrected a design that blocked these tools.
<!-- auto-added 2026-06-21 -->

## Slash command autocomplete in MentionField

`MentionField` shows a dropdown of Claude Code slash commands when the user types `/` at the start of their message. The list (`app.slashCommands`) is populated live from the `slash_commands` array in Claude Code's `system:init` event — do NOT hardcode it or remove this live-update path, since user-installed skills would then disappear from autocomplete.
<!-- auto-added 2026-06-22 -->

## Sparkle auto-updater

Rounds uses Sparkle (SPM: `sparkle-project/Sparkle >= 2.5.0`) for in-app updates — one click downloads, verifies, and relaunches. Do NOT remove `INFOPLIST_FILE = Info.plist` from build settings or revert to `GENERATE_INFOPLIST_FILE = YES`: the explicit `Info.plist` at the project root is required because Sparkle's EdDSA public key (`SUPublicEDKey`) lives there and a generated plist would discard it silently.
<!-- auto-added 2026-06-22 -->

## Notarization

Notarize with `xcrun notarytool submit ... --keychain-profile "rounds-notary"`. The profile was set up once via `xcrun notarytool store-credentials`.
<!-- auto-added 2026-06-22 -->
Release builds must NOT include the `com.apple.security.get-task-allow` entitlement — Apple rejects notarization if it's present. Always archive/build with the Release configuration (or strip the entitlement explicitly); Debug builds inject it automatically.
<!-- auto-added 2026-06-22 -->

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

## Chat session persistence: front-matter sessionId and --resume

Chat `.md` files store `sessionId: <id>` in their front-matter (written by `persistChat`, parsed by `VaultStore.frontMatter()`). `WarmSession` reads this via `config.resumeSessionId` and passes `--resume <id>` at startup — without it, reopened chats lose all Claude Code multi-turn memory. Do NOT change the `sessionId:` front-matter key or skip the `--resume` arg in `WarmSession`.
<!-- auto-added 2026-06-22 -->

## Slash commands all pass through to Claude Code

There are currently NO Rounds-native intercepted slash commands — every `/`-prefixed message is forwarded raw to Claude Code (see the `chatPrompt()` pass-through rule above). `ChatRuntime` has no `handleRoundsCommand()` anymore; it was only used for `/remote-control`, which was removed because Claude Code Remote Control is interactive-only and a no-op in Rounds' stream-json mode (see the `rounds-remote-control` memory). If you reintroduce a Rounds-native command, intercept it in `ChatRuntime.send()` BEFORE the turn is dispatched, AND keep the Dashboard ask box's `!text.hasPrefix("/")` guard in sync — otherwise `/`-commands silently land in the symptom interview instead of a chat.
<!-- auto-added 2026-06-22 -->
