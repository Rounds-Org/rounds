#!/bin/bash
# Scenario eval harness for the Rounds CORE (symptom-first complaint flow).
# Runs the real complaint.md brain prompt against a scenario (symptom text + optional photos),
# using the live rounds-sources MCP, and saves the raw output for review. Iterative: tune prompts,
# re-run, compare. Uses SOURCE prompts (brain/prompts) so you don't need to rebuild the app.
#
# Usage: tools/eval-scenario.sh <name> "<symptom text>" [photo1 photo2 ...]
set -e
REPO="/Users/mikhailegorov/Development/rounds/rounds"
VAULT="$HOME/Rounds"                       # for the installed MCP (mcp.json with node paths)
MODEL="${EVAL_MODEL:-sonnet}"
LANG="${EVAL_LANG:-English}"          # answer language; override to test the ANSWER_LANGUAGE path
PERSON="${EVAL_PERSON:-_self}"        # person slug; override for an other-person (child, parent) case
NAME="$1"; SYMPTOM="$2"; shift 2 || true; PHOTOS="$*"
CWD="/tmp/eval-vault-$NAME"          # per-run throwaway cwd so parallel runs don't cross-contaminate
rm -rf "$CWD"
OUT="/tmp/evals"; mkdir -p "$OUT" "$CWD/people/$PERSON"
# minimal person context in the throwaway vault
cat > "$CWD/people/$PERSON/CLAUDE.md" <<MD
# About $PERSON
No known chronic conditions on file. No confirmed history recorded yet for this complaint.
MD
cp "$VAULT/.rounds-brain/mcp.json" "$CWD/mcp.json" 2>/dev/null || true

PHOTOBLOCK=""
if [ -n "$PHOTOS" ]; then
  PHOTOBLOCK=$'\nAttached photos (use Read to observe them — they are PRIMARY data; interpret only from sources):'
  for p in $PHOTOS; do PHOTOBLOCK="$PHOTOBLOCK"$'\n- '"$p"; done
fi

PROMPT=$(python3 - "$SYMPTOM" "$PHOTOBLOCK" "$LANG" "$PERSON" <<'PY'
import sys, pathlib
c=pathlib.Path("/Users/mikhailegorov/Development/rounds/rounds/brain/prompts/complaint.md").read_text()
sym, photos, lang, person = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p=(c.replace("{{PERSON_SLUG}}",person)
    .replace("{{ANSWER_LANGUAGE}}",lang)
    .replace("{{COMPLAINT_ID}}","cmp_eval").replace("{{TRIGGER}}","the user described a new symptom"))
p+=f"\n\n--- THE COMPLAINT ---\nTitle: {sym[:70]}\nWhat the user said: {sym}\nOpened: 2026-06-21\nConfirmed history so far: see people/_self/CLAUDE.md (none yet).{photos}"
print(p)
PY
)
CONTRACT=$(cat "$REPO/brain/prompts/system_compact.txt")
echo "▶ running scenario: $NAME (model=$MODEL, photos: ${PHOTOS:-none})"
( cd "$CWD" && claude -p "$PROMPT" --model "$MODEL" \
    --append-system-prompt "$CONTRACT" \
    --strict-mcp-config --mcp-config "$CWD/mcp.json" \
    --permission-mode bypassPermissions \
    --allowedTools "Read Glob Grep WebFetch mcp__rounds-sources" \
    --disallowedTools "Bash Task WebSearch ToolSearch KillShell" \
    < /dev/null > "$OUT/$NAME.txt" 2>&1 )
echo "✔ saved $OUT/$NAME.txt"
