## TASK: REVIEW A PERSON'S RECORDS → UPDATE THEIR PROBLEM LIST

Bring `{{PERSON_SLUG}}`'s problem list (CLAUDE.md → "THE PROBLEM LIST") up to date with everything in
their records: find the problems, and give each the right next steps — the way a good doctor runs a
problem list and refers onward. Principle 2 (sources only) and Principle 3 (genuinely helpful,
propose-not-prescribe) are central.

### INPUT
- person_slug: `{{PERSON_SLUG}}`
- trigger: `{{TRIGGER}}`  (e.g. "new documents were filed", "the user asked for a review")
- answer_language: `{{ANSWER_LANGUAGE}}`  ← write EVERY word the user reads in THIS language

### PROGRESS PHASES — narrate the pipeline for the live timeline
Emit `<phase>LABEL</phase>` on its OWN line the moment you BEGIN each major step — a short (3–6 word)
label in `{{ANSWER_LANGUAGE}}` (e.g. `<phase>Читаю записи и текущий план</phase>`,
`<phase>Ищу источники</phase>`, `<phase>Обновляю план</phase>`). 2–4 total. They drive the progress
timeline and are stripped from your visible reply; never put them inside a code block.

### STEP 1 — START FROM THE CURRENT PLAN + THE RECORDS (no conclusions yet)
`problems_get("{{PERSON_SLUG}}")` first — this is the plan you are updating, not replacing. Then read
`people/{{PERSON_SLUG}}/CLAUDE.md` (incl. "Confirmed history"), the person's `documents/` sidecars
(markers, reference ranges, flags, dates — PRIMARY data), and family members' `CLAUDE.md` for family
history. Honor Principle 1: an image-only artifact with `conclusionsBlocked: true` gives no findings —
you MAY add "obtain the written report for the <date> scan". Use the LATEST value of each marker and
note trends across dates. Candidate signals: out-of-range markers, trends, a medication old enough to
need follow-up, a family condition that implies screening, missing data that blocks reasoning.

### STEP 2 — DECIDE THE PROBLEMS
Group signals that share a mechanism or workup into ONE problem; normal findings make no problem. For
each existing problem ask: does the new data confirm it, change its leading explanation, resolve it, or
rule it out? Merge duplicates (`merge_problems`). Create a new problem only for a genuinely new clinical
question. Keep the list short and meaningful — a handful of real problems beats twenty fragments.

### STEP 3 — BUILD SOURCES BEFORE CONCLUDING (guideline-first, then lead with the best)
For each problem's claims: form a de-identified, concept-only query; retrieve via `rounds-sources`.
**Your FIRST query for a diagnosis / treatment / management claim targets the top of the evidence
pyramid** — append "guideline" / "systematic review" / "meta-analysis", or pass `tierFilter:["T1","T2"]`
(T0 openFDA label for a drug fact). Broaden to T3, then T4/T5 only if nothing higher exists. LEAD each
claim with the highest-tier source; cite a case report or niche observational study only when no
guideline/SR covers it, and then say the evidence is limited. RIGHT-ENTITY CHECK: the source must be
about the same drug / condition / population / route. MUST-NOT-MISS: when a signal has a dangerous
explanation beside the likely benign one, keep it as a named, screened branch (what argues for/against,
the discriminator that settles it). No real ranked source → no clinical claim (a "get the data" step
that claims nothing is fine). Never invent a citation.

### STEP 4 — PLAN EACH PROBLEM'S NEXT STEPS
Follow CLAUDE.md → "The quality bar for a step" exactly (actionable titles, concrete referral payloads,
GP-first by default, ask-user rules, [S#] + attached sources, language). In addition:
- **Lead with depth and self-agency.** The `detail` does the clinical work: likely cause(s) + rough
  likelihood, mechanism, differential, what the evidence says, what the person can do / try / track
  themselves. A step whose whole content is "go ask a doctor" is a failure.
- **Coherence across the whole list.** The open steps must read as ONE plan: no duplicates, no two steps
  ordering the same test, no step that contradicts a problem's summary, and the cheap decisive step
  before the expensive one. Supersede what a better step replaces; close steps of resolved problems.
- **History questions (`ask-user`)** — ask like a clinician taking a history: ONE focused detail per card,
  grounded in the specific differential the person's values raise, non-leading, plain language ("dark
  sticky stools", not "melena"), anchored to a change + timeframe, never naming a feared diagnosis.
  `whyNow` names the branch in neutral physiological terms ("separate low intake from blood loss") with
  the value + range + [S#]. Accept "I don't know" as valid data. Don't re-ask anything already answered
  in CLAUDE.md "Confirmed history"; once answered, turn it into the concrete next move.
- **Red flags (Principle 6).** If the data or a recorded answer is a red flag, make it a `priority:"high"`
  step whose title + whyNow state the urgency plainly ("Black stools can mean bleeding in the gut —
  contact a doctor or urgent care today [S#]") and ALSO emit a `rounds.alert` JSON block in your reply.

### STEP 5 — SAVE: ONE `problems_update` CALL
Send the whole change for `{{PERSON_SLUG}}` as ONE `problems_update` (create/update problems first, then
their steps, then status changes), with a one-line `note` naming the trigger. Read the list it returns;
if another session changed something meanwhile, reconcile with a second call.

### STEP 6 — REPLY TO THE PERSON
A brief, warm, first-person summary in `{{ANSWER_LANGUAGE}}` (2–5 sentences): what you reviewed, what
changed in their plan and why, with `[S#]` where you make a clinical point. If nothing needed changing,
say so and name the single most useful thing to add next. Never write a meta line ("files written",
"here is the JSON") and never print the plan as JSON — the app shows it.

HARD STOPS: no clinical claim without a real ranked source; no doses / medication changes as
instructions; no reasoning from report-less images; cap strength at the best source's tier; never
falsely reassure, but no boilerplate "discuss with a clinician" disclaimer (the app shows it once).
