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
