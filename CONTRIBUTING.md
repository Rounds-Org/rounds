# Contributing to Rounds

Thanks for helping. Rounds is a health tool, so the bar for changes is higher than usual
— please read the safety rules below before you open a PR.

## Repo layout

```
app/      The native macOS app (SwiftUI + AppKit). The "conductor": it spawns the
          user's local Claude Code, streams the output into a native UI, enforces the
          safety gates, and reads/writes the ~/Rounds vault. (Currently the rounds/
          and rounds.xcodeproj/ Xcode project.)
brain/    The shippable "brain" — the part most contributors improve. CLAUDE.md, the
          skill and subagent prompts, the hooks, and the rounds-sources MCP (a small
          Node tool server that talks to public medical APIs). This is where most of
          the product's quality and behavior actually lives.
docs/     The architecture (docs/ARCHITECTURE.md) and privacy note (docs/PRIVACY.md).
evals/    The safety golden-set — fixtures and expected behavior that pin down the six
          principles so a prompt change can't quietly regress them.
```

## Where the quality lives

Rounds deliberately pushes most of its intelligence out of compiled Swift and into
legible Markdown and a little Node, under `brain/`. That means:

- You can meaningfully improve Rounds — better prompts, better source ranking, better
  intake questions — **without writing any Swift.**
- Changes to behavior are reviewable in plain text, which matters for an auditable health
  tool.

If you're new, the brain is the best place to start.

## Safety-critical rules (non-negotiable)

These hold for every contribution. A PR that breaks one will not be merged.

1. **Never weaken the six principles.** No conclusions from images without a text
   report; sources only (never from the model's own memory); propose, never prescribe;
   confirm before filing; emergency escalation; always-visible disclaimer. See
   `docs/ARCHITECTURE.md` §6 for the full text. If your change touches a prompt, a hook,
   or a UI gate, confirm it does not loosen any of these.
2. **Every clinical claim stays source-grounded.** Any clinically meaningful statement
   must come from a retrieved, trust-ranked source or the user's own records, with a
   citation. Do not add behavior that lets the model answer a clinical question from its
   own training memory. "No source found" must stay a valid, intended outcome — never
   paper over it.
3. **Keep de-identification intact.** Nothing that could identify a person (name, DOB,
   address, record ID, free-form text) may reach a network call. Egress is concept-only
   queries plus the static version poll, and nothing more.
4. **Don't expand what leaves the Mac.** New corpora or network calls need an explicit
   reason and must stay de-identified. New analytics events must follow the allowlist in
   `docs/PRIVACY.md` — non-sensitive names and counts only, never content.
5. **Add or update an eval when you change safety behavior.** If you touch a principle's
   enforcement, add a case to `evals/` so it can't silently regress later.

## A note on guardrails and forks

The guardrails protect the **default shipped build.** They are deterministic and
designed to be hard to talk the model out of — but we do not claim they are
un-circumventable by a fork that deliberately removes them. The expectation for
contributors is simple: keep them strong, and don't ship a change that makes the default
experience less safe.

## Submitting changes

- Open an issue first for anything non-trivial, especially safety-adjacent work.
- Keep PRs focused. Explain what you changed and, for brain changes, why the behavior is
  better and still safe.
- Run the relevant evals and note the result in your PR.

Questions about the design? Read `docs/ARCHITECTURE.md` first — it covers most of them.
