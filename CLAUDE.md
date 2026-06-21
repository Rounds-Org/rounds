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

## Brain prompt regeneration

`rounds/Brain/BrainResources.swift` is a generated file. After editing any file in `brain/prompts/` or `brain/claude/CLAUDE.md`, bump `brainVersion` in `tools/gen_brain_resources.py` and run `python3 tools/gen_brain_resources.py` to regenerate it — otherwise the running app sees stale prompts.
<!-- auto-added 2026-06-21 -->
When adding a **new** prompt file to `brain/prompts/`, also add a `write(BrainResources.<name>, to: vault.promptsDir.appendingPathComponent("<name>.md"))` call in `rounds/Brain/BrainInstaller.swift` — otherwise the new prompt is embedded in the binary but never written to disk at vault setup time.
<!-- auto-added 2026-06-21 -->
