# Privacy

Rounds is built so your health data stays on your Mac. This note explains, in plain
language, what stays local, what leaves the machine, and what the optional analytics can
and cannot see.

There is no Rounds backend. We never receive your documents, your records, or your
results. We couldn't — there's nowhere for them to go.

## What stays local

**Everything about your health.** Your documents, lab values, scans, notes, the records
in your `~/Rounds` vault, your family roster, the questions and answers, the generated
hypotheses and chats — all of it lives only on your Mac, in plain files you own. Deleting
the vault deletes your data. Nothing about it is sent anywhere.

## What leaves your Mac

Two things, and only these:

1. **De-identified, concept-only medical queries.** To find published evidence, Rounds
   queries public medical APIs — **PubMed, ClinicalTrials.gov, and openFDA** (and similar
   public sources). These queries carry *concepts only.* Before anything is sent,
   identifiers are stripped: names are omitted, exact dates become a year or an age band,
   location is reduced to a country, and record IDs are removed. What goes out looks like
   *"low ferritin, adult male, iron supplementation"* — never your name, your file, or
   your free-form text. For the first such queries in a session, Rounds shows you the
   exact concept-only query before it sends it.
2. **A static version check.** Rounds polls a small static file to know whether a newer
   version exists, so it can show the update banner. This is a plain version number
   request and carries none of your data.

These public APIs are operated by third parties (the NIH/NCBI, the FDA, and so on) under
their own terms. Like any web request, they can see the IP address it came from. That's
why the queries are de-identified before they leave: the request itself never contains
anything that points back to you.

## Optional analytics (Amplitude)

Rounds can send anonymous, **content-free** product analytics through Amplitude, to
understand which features are used and where things break. This is **opt-out at
onboarding** — you can turn it off before any event is ever sent.

**The allowlist — what analytics is allowed to contain:**

- Non-sensitive **event names** (for example: app launched, onboarding completed,
  document filed, hypothesis generated, report exported).
- A small set of **enums and counts** (for example: a document type like "lab_panel",
  the *number* of documents in a vault, a step number, an error category).

**What analytics never contains — ever:**

- Document contents, marker names, or any health value.
- Names, dates of birth, relationships, or any identifier.
- Free-form text you typed, query text, file names, or file paths.
- Anything that could reconstruct what's in your records.

Analytics is filtered through a single chokepoint in the app: if a field isn't on the
allowlist, it does not get sent.

**What Amplitude inherently collects.** As an analytics provider, Amplitude
automatically records some technical metadata with each event: a generated device
identifier, your IP address (which it resolves to a coarse geographic region and then
discards the raw IP for that purpose), your operating system, and the Rounds version.
This is standard for analytics SDKs and applies only if you leave analytics on.

If you turn analytics off at onboarding, none of the above is sent — not the events, not
the device id, nothing.

## In short

- Your health data: **local only, never sent.**
- Medical lookups: **de-identified, concept-only,** to public APIs.
- Update check: a **static version poll,** no personal data.
- Analytics: **off-able, content-free,** allowlisted event names and counts only.

For how this is enforced in the architecture, see
[ARCHITECTURE.md](ARCHITECTURE.md) (§5 sources/de-identification and §6 safety).
