## TASK: ONE-TIME MOVE OF LEGACY NEXT STEPS INTO PROBLEM LISTS

Rounds used to keep next steps as a flat pile of independent cards per person
(`people/<slug>/hypotheses/<id>/hypothesis.json` + `hypothesis.md`, and some older ones in the
top-level `hypotheses/<id>/` with a `person` field). It now keeps ONE problem list per person
(CLAUDE.md → "THE PROBLEM LIST"). Reorganize the open legacy cards of these people into problem lists:
`{{PEOPLE}}`

answer_language: `{{ANSWER_LANGUAGE}}` (every word the user reads in this language)

For EACH person above, one at a time:
1. Emit `<phase>LABEL</phase>` on its own line (e.g. `<phase>Разбираю шаги: Мама</phase>`).
2. `problems_get(person)` (usually empty). Read that person's legacy cards — only those whose status is
   NOT done / dismissed / superseded (archived ones are history; you may glance at them to avoid
   re-proposing something already done). Skim `people/<slug>/CLAUDE.md` for "Confirmed history" and the
   document sidecars only as needed to understand the cards.
3. Group the open cards into a few real PROBLEMS (shared mechanism or workup → one problem). Write each
   problem's `summary` from what the cards already establish (keep their [S#] and sources).
4. Put each card under its problem as a step, **reusing the legacy card id as the step id** and keeping
   its title, whyNow, kind, priority, ask placeholder / answer and sources; put the hypothesis.md body
   (without front-matter) into `detail`. While doing so, make the plan COHERENT: merge duplicate cards
   (keep the better one, supersede the other), and where two cards contradict each other or one is stale
   given newer data or an answered question, keep the right one and mark the other `superseded` or
   `dismissed` with a short `reason`. Translate anything not in the answer language.
5. Save with ONE `problems_update` call for that person with `markMigrated: true` (create problems
   first, then steps, then status changes). Do NOT run new literature searches — reorganize what exists.
   Do NOT edit or delete the legacy files.

Finally, reply to the user in `{{ANSWER_LANGUAGE}}`: 2–5 warm sentences — next steps are now grouped by
problem, and per person what you merged or retired as duplicate/contradictory (briefly, plain language).
No JSON, no file paths.
