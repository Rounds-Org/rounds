#!/bin/bash
# Document-path eval harness for the Rounds CORE (next-step generation from filed documents).
# Mirrors AppState.generateHypotheses(): runs the real hypotheses.md brain prompt against a person
# whose documents/ folder holds real medical images, using the live rounds-sources MCP. The model
# Reads the images directly (Claude Code's Read renders them), transcribes, and reasons — a strong
# end-to-end test of the document lane. Uses SOURCE prompts so no app rebuild is needed.
#
# Usage: tools/eval-hypotheses.sh <name> <person_slug> <answer_language> <src_dir> [file1 file2 ...]
#   <src_dir> is a folder; [fileN] are basenames inside it (omit to use ALL files in src_dir).
# Example:
#   tools/eval-hypotheses.sh mom-onco mom Russian "$HOME/Desktop/mom medical test/renamed files" \
#     "05 - Протокол биопсии.jpg" "34 - Биопсия операционная.jpg" "39 - Заключение ОД стр 1.jpg"
set -e
REPO="/Users/mikhailegorov/Development/rounds/rounds"
VAULT="$HOME/Rounds"
CWD="/tmp/eval-vault-hyp"
MODEL="${EVAL_MODEL:-sonnet}"
NAME="$1"; SLUG="$2"; LANG="$3"; SRC="$4"; shift 4 || true
OUT="/tmp/evals"; mkdir -p "$OUT"
# fresh throwaway vault each run so stale sidecars/hypotheses don't leak between runs
rm -rf "$CWD"; mkdir -p "$CWD/people/$SLUG/documents" "$CWD/people/$SLUG/hypotheses"
cat > "$CWD/people/$SLUG/CLAUDE.md" <<MD
# About $SLUG
Patient on file. No confirmed narrative history recorded yet — derive everything from the filed
documents in documents/. Transcribe what you read; treat dates, markers, and reference ranges as PRIMARY.
MD
cp "$VAULT/.rounds-brain/mcp.json" "$CWD/mcp.json" 2>/dev/null || true

# stage the chosen documents as documents/<idx>/source.<ext>.
# remaining args ("$@") are the chosen basenames; if none given, use ALL files in SRC.
if [ "$#" -eq 0 ]; then
  OLDIFS="$IFS"; IFS=$'\n'; set -- $(cd "$SRC" && ls); IFS="$OLDIFS"
fi
i=0
DOCLIST=""
for f in "$@"; do
  i=$((i+1))
  ext="${f##*.}"
  d="$CWD/people/$SLUG/documents/doc$(printf '%02d' $i)"
  mkdir -p "$d"
  cp "$SRC/$f" "$d/source.$ext"
  DOCLIST="$DOCLIST"$'\n'"- people/$SLUG/documents/doc$(printf '%02d' $i)/source.$ext   (original filename: $f)"
done

PROMPT=$(python3 - "$SLUG" "$LANG" "$DOCLIST" <<'PY'
import sys, pathlib
c=pathlib.Path("/Users/mikhailegorov/Development/rounds/rounds/brain/prompts/hypotheses.md").read_text()
slug, lang, doclist = sys.argv[1], sys.argv[2], sys.argv[3]
p=(c.replace("{{PERSON_SLUG}}",slug)
    .replace("{{ANSWER_LANGUAGE}}",lang)
    .replace("{{TRIGGER}}","new documents were just filed; review them and propose next steps"))
p+=f"\n\n--- FILED DOCUMENTS (use Read to open each image; transcribe + treat as PRIMARY data) ---{doclist}\n\nNo sidecars exist yet — Read each image yourself to extract values, dates, and reference ranges."
print(p)
PY
)
CONTRACT=$(cat "$REPO/brain/prompts/system_compact.txt")
echo "▶ running document eval: $NAME (person=$SLUG, lang=$LANG, model=$MODEL, $i docs)"
( cd "$CWD" && claude -p "$PROMPT" --model "$MODEL" \
    --append-system-prompt "$CONTRACT" \
    --strict-mcp-config --mcp-config "$CWD/mcp.json" \
    --permission-mode bypassPermissions \
    --allowedTools "Read Glob Grep Write WebFetch mcp__rounds-sources" \
    --disallowedTools "Bash Task WebSearch ToolSearch KillShell" \
    < /dev/null > "$OUT/$NAME.txt" 2>&1 )
echo "✔ saved $OUT/$NAME.txt"
