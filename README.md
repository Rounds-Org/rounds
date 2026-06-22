# Rounds

**Your health researcher. Runs on your Mac. Powered by Claude Code.**

[![Latest release](https://img.shields.io/github/v/release/Rounds-Org/rounds?label=download&sort=semver)](https://github.com/Rounds-Org/rounds/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Rounds-Org/rounds/total)](https://github.com/Rounds-Org/rounds/releases)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
[![License](https://img.shields.io/github/license/Rounds-Org/rounds)](LICENSE)

### ⬇️ [Download the latest release](https://github.com/Rounds-Org/rounds/releases/latest)

> macOS app. Requires [Claude Code](https://claude.com/code) and [Node.js](https://nodejs.org)
> already installed. The build is signed and **notarized by Apple** — just open the DMG, drag
> Rounds to Applications, and launch it. Updates install themselves from inside the app. Or
> [build from source](#build-from-source).

Clarity about your health.

Rounds is a native macOS app that helps you and your family gather, organize, and
make sense of your own medical records — and walk into the right doctor's office with
the strongest possible case. It runs on your Mac, uses the copy of Claude Code you
already have installed, and keeps your data local.

It is open-source (MIT), there is no Rounds backend, and it is not a substitute for a
doctor.

---

## What it is, honestly

Most people don't lose time because no answer exists. They lose it because they're
stuck in a local bubble — a stack of PDFs they can't read, no idea which specialist to
see, no time to read the literature, and a fifteen-minute appointment that goes by
before they've asked the right question.

Rounds is built to pull a family out of that bubble. It reads your records, finds the
relevant published evidence, and hands you an argument: *here is your value, here is
what the guideline says, here is the question to ask, here is the specialist to see.*

That's the whole pitch. It is **not** "AI instead of a doctor." Everything it says is
grounded in retrieved sources (it names likely causes, odds, tests, and treatment options
only when a real source backs them — never from the model's memory), it doesn't write
prescriptions, and it can't replace a clinician. Its job is to get you to the right one,
better prepared, with sources in hand.

## Safety principles

These are not aspirations. They are enforced in the shipped build by code, not just by
asking the model nicely.

1. **Images are observations; interpretation comes from sources.** Rounds may look at a
   photo (a nail, a rash, a printed lab report) and describe what's visible, and it
   transcribes text from a document photo. But every clinical *interpretation* of what it
   sees must come from sources it retrieves — and for radiology (X‑ray/CT/MRI/ultrasound)
   it prefers the written report over reading the imagery.
2. **Sources only — never from the model's own memory.** Every clinically meaningful
   statement is grounded in retrieved, trust-ranked published sources (or your own
   records), with an inline citation. If no real source supports a claim, Rounds says
   so and declines. "I couldn't find a source" is a valid, intended answer.
3. **Propose, never prescribe.** Rounds behaves like a thoughtful GP who refers you
   onward with a strong argument. It does not give a definitive diagnosis and never
   tells you to start, stop, or change a medication.
4. **Confirm before it files anything.** A wrong person, relationship, or date corrupts
   your records for good, so Rounds drafts a classification and asks you to confirm
   before it saves a document or writes to memory.
5. **Emergency escalation.** Critical or panic-range values, and answers that signal
   acute danger, get an urgent banner that bypasses the calm "discuss when convenient"
   framing and tells you to seek care today.
6. **An always-visible disclaimer.** Every screen carries a fixed, non-dismissible
   reminder that Rounds is a research tool, can be wrong, and is not a doctor.

A note for forks: these guardrails protect the **default shipped experience**. They are
deterministic and hard to talk the model out of, but we do not claim they are
un-circumventable by someone who deliberately modifies the code. Please don't weaken
them.

## How it works

- Rounds drives **the Claude Code CLI you already have installed.** It is a conductor,
  not a brain. The app spawns your local `claude`, streams the output into a native UI,
  and reads and writes plain files in a vault at `~/Rounds`.
- **There is no Rounds backend.** No account, no server, no telemetry pipeline for your
  health data.
- **Your data stays on your Mac.** The only things that ever leave the machine are
  **de-identified, concept-only queries** to public medical APIs (PubMed, ClinicalTrials.gov,
  openFDA, and similar), and a small static version check for the update banner. Names,
  dates of birth, addresses, and record IDs never go into a query. Rounds sends concepts
  like *"low ferritin, adult male, iron supplementation,"* not your file.
- **The intelligence lives in legible files.** Behavior is a versioned "brain" of
  Markdown prompts and a small Node tool server, not buried in compiled app code. That's
  what contributors mostly improve, and it's auditable in the open.

## Requirements

- **macOS 14 or later** (Apple Silicon or Intel)
- **The Claude Code CLI** installed and signed in (`claude`)
- **Node.js** (for the local sources tool server)
- **An active Claude subscription.** Rounds uses your own Claude Code. You fund your own
  usage — there is no Rounds-hosted model and no markup.

## Quick start

1. Install [Claude Code](https://claude.com/claude-code) and sign in. Confirm it works:
   ```
   claude --version
   ```
2. Install Node.js if you don't have it (`node -v` to check).
3. Download the latest Rounds build from
   [Releases](https://github.com/Rounds-Org/rounds/releases/latest), or build from source
   (below).
4. Launch Rounds. Onboarding checks for `claude` and Node, registers the local sources
   tool, and creates your vault at `~/Rounds`.
5. Drag in a lab report or scan. Rounds will ask a couple of confirming questions, file
   it, and offer to research next steps.

## Build from source

```sh
git clone https://github.com/Rounds-Org/rounds.git
cd rounds
xcodebuild -project rounds.xcodeproj -scheme rounds -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/rounds.app
```

Or just `open rounds.xcodeproj` in Xcode 16+ and hit Run. The "brain" (the contract,
prompts, and the local sources MCP) is embedded in the app and installed to `~/Rounds`
on first launch — no external files needed.

### Want a feature?

Rounds is a thin, open client over Claude Code — so the easiest way to extend it is to
ask your own Claude Code to do it: clone this repo and tell it what you want. PRs welcome.

## Privacy

Everything stays on your Mac by default. The full list of what leaves the machine —
the de-identified medical queries and the static version poll — and the optional,
opt-out, content-free analytics, is documented in
**[docs/PRIVACY.md](docs/PRIVACY.md)**. Please read it.

## Architecture

Rounds is a thin native Swift shell over a versioned "brain" of files. The shell spawns
your local `claude`, streams its output, and enforces safety at the boundary; the brain
(prompts, subagents, hooks, and the sources tool server) holds the product's
intelligence. The full design, including the safety planes and the sources engine, is in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Contributing

Most of what makes Rounds good lives in readable Markdown and a little Node, so you can
improve it without touching Swift. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the
repo layout and the safety rules contributions must hold to.

## License

MIT. See [LICENSE](LICENSE).

---

> ### Medical disclaimer
>
> **Rounds is a research assistant, not a doctor.** It can be wrong. It does not
> diagnose, prescribe, or replace professional medical care. Nothing it produces is
> medical advice. Everything is for discussion with a qualified clinician. If you think
> you may have a medical emergency, contact your doctor or your local emergency services
> immediately.
