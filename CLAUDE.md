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

## Rounds-level slash commands vs Claude Code commands

Rounds-native commands (e.g. `/remote-control`) are intercepted by `ChatRuntime.handleRoundsCommand()` BEFORE the message is sent to Claude Code — they never reach the model. The Dashboard ask box also guards `!text.hasPrefix("/")` before routing to the symptom interview. Keep BOTH checks in sync: adding a new Rounds command → add it to `handleRoundsCommand()`; editing the Dashboard routing → preserve the `/`-prefix bypass or `/`-commands silently land in the symptom interview instead of a chat.
<!-- auto-added 2026-06-22 -->
