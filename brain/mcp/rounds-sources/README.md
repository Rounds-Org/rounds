# rounds-sources — the Rounds medical-sources MCP server

A **zero-dependency** Node MCP stdio server that implements the medical-sources engine
described in `docs/ARCHITECTURE.md` §5 (corpora, deterministic trust-ranking tiers,
enforcement model). It is the tool server the Rounds brain (`source-retriever` subagent)
talks to — it is **not** a wrapper around Claude.

- **Runtime:** pure Node 18+ ESM. **No npm dependencies.** Uses the global `fetch`.
- **Run it:** `node index.mjs` — nothing to install. (This matters: it ships to end users
  who only have Node.)
- **Transport:** newline-delimited JSON-RPC 2.0 over stdin/stdout, implemented by hand
  (no `@modelcontextprotocol/sdk`). `stdout` is the protocol channel; **all diagnostics go
  to stderr only.** The server never crashes on a bad request — it replies with a JSON-RPC
  error and keeps running.

## Corpora

| Source | Used by | Notes |
|---|---|---|
| **PubMed/MEDLINE E-utilities** (esearch + esummary) | `search_literature` | Always sends `tool=rounds&email=rounds-app@users.noreply.github.com`. Politely rate-limited (~3 req/s without a key; ~10 req/s with `ROUNDS_NCBI_API_KEY`). Omitting `tool`/`email` risks an NCBI IP block. |
| **Europe PMC REST** | `search_literature` | Second literature source — preprints, `citedByCount`, MeSH headings, open-access flag. |
| **ClinicalTrials.gov API v2** | `find_trials` | `https://clinicaltrials.gov/api/v2/studies`. |
| **openFDA** `/drug/label.json` | `drug_label` | Authoritative regulatory **fact** (tier T0). The openFDA disclaimer is returned verbatim. |

## Tools

Every tool returns its payload as a JSON string inside the standard MCP shape
`{ content: [ { type: "text", text: "<json>" } ] }`. On failure a tool returns a
structured error result (`isError: true`) — it never throws out of the JSON-RPC handler.

### `search_literature({ query, maxResults = 8, tierFilter? })`
Queries PubMed **and** Europe PMC in parallel, de-duplicates (DOI → PMID → fuzzy title;
preprints collapse into the published record), computes a trust tier + score, **drops
`Retracted Publication`**, flags Expressions of Concern, and sorts by tier then score.

- `tierFilter` (optional): array of tiers to keep, e.g. `["T1","T2"]`.
- Returns normalized citations:
  `{ id, source, title, journal, year, pubTypes[], url, doi, pmid, citedBy, trustTier, trustScore, concern, whyTrusted }`
  plus the NCBI disclaimer and a `note`.

### `find_trials({ condition, status = "RECRUITING", maxResults = 8 })`
ClinicalTrials.gov v2. Filters by recruitment status to produce an actionable list.
Returns `{ nctId, title, status, phase, conditions[], url, locationsCount, countries[] }`.

### `drug_label({ name })`
openFDA label search by brand **or** generic name. Returns key fields
(`indications`, `dosage`, `warnings`, `boxedWarning`, `contraindications`,
`drugInteractions`, `adverseReactions`) + the **openFDA disclaimer verbatim**.
Tier **T0** — authoritative fact, not evidence-graded.

### `rank_sources({ citations })`
Applies the deterministic ranking model to a caller-supplied citation list. Returns them
sorted with `trustTier`, `trustScore`, `scoreComponents`, `tierReasons`, and a one-line
`whyTrusted`. Drops retracted publications.

## Trust-ranking model (deterministic — no LLM judgment)

Tier is derived from `PublicationType` + MeSH (highest tier wins on multi-type records):

| Tier | From | Base weight |
|---|---|---|
| PRIMARY | the user's own uploaded records | (separate class) |
| T0 | openFDA drug label (fact) | 0.95 |
| T1 | Practice Guideline / Guideline / Cochrane / NICE / USPSTF | 1.00 |
| T2 | Meta-Analysis / Systematic Review | 0.90 |
| T3 | RCT / Controlled Clinical Trial | 0.75 |
| T4 | Cohort/observational — from MeSH `Cohort Studies`, **not** PublicationType (+ Europe PMC `Observational Study` PubType) | 0.55 |
| T5 | Case Report / narrative review / mechanism | 0.35 |
| T6 | preprint / un-indexed / forum | 0.15 |

`score = baseWeight(tier) × reputation × recency × (0.5 + 0.5·relevance)`

- **reputation** (0.6–1.0): MEDLINE-indexed → 0.8; **journal allowlist** (Cochrane, NEJM,
  Lancet, JAMA, BMJ, flagships) → 1.0. The allowlist is matched on the **whole journal
  name** (exact or `"<name> <subtitle>"` prefix), never a naive substring — so
  *"European Journal of Sport Science"* is **not** promoted by `science`, and *"International
  Journal of Clinical Oncology"* is **not** promoted by `journal of clinical oncology`.
- **recency**: exponential decay (guideline/RCT half-life ~7y, observational ~5y), floored;
  never raises a score above its tier weight.
- **relevance**: API rank position + a marker-in-title boost.
- **Retraction** → hard drop. **Expression of Concern** → `concern: true` flag, not a drop.
- **MeSH-lag fallback (gap #27):** brand-new records are un-indexed for weeks (no MeSH/
  PubType). A title heuristic + the journal allowlist assigns a sensible tier so a landmark
  RCT in *Lancet* isn't wrongly dropped to T6.

## Configuration (all optional env vars)

| Env var | Effect |
|---|---|
| `ROUNDS_NCBI_API_KEY` | Raises the PubMed rate limit to ~10 req/s. |
| `ROUNDS_OPENFDA_API_KEY` | Raises the openFDA rate limit. |
| `ROUNDS_HTTP_TIMEOUT_MS` | Per-request network timeout (default 15000). |

## Registering with Claude Code

`.mcp.json`:

```json
{ "mcpServers": { "rounds-sources": {
  "command": "node",
  "args": ["/absolute/path/to/brain/mcp/rounds-sources/index.mjs"]
} } }
```

## Verified end-to-end test

The following command was run against the real local `claude` CLI (v2.1.172, Node
v22.11.0) and confirmed a `tool_use` for `mcp__rounds-sources__search_literature` fired
and returned real, T1-ranked citations:

```bash
# 1) write the temp config
cat > /tmp/rounds-mcp.json <<'EOF'
{"mcpServers":{"rounds-sources":{"command":"node","args":["/Users/mikhailegorov/Development/rounds/rounds/brain/mcp/rounds-sources/index.mjs"]}}}
EOF

# 2) run claude headless against it
claude -p "Use the rounds-sources search_literature tool to find guidelines on iron deficiency anemia. List the top 3 titles with their trust tier." \
  --output-format stream-json --verbose --strict-mcp-config \
  --mcp-config /tmp/rounds-mcp.json \
  --allowedTools "mcp__rounds-sources__search_literature"
```

Observed in the stream:

- `system/init`: `mcp_servers: [{"name":"rounds-sources","status":"connected"}]`, all four
  `mcp__rounds-sources__*` tools registered.
- `assistant` → `tool_use`: `mcp__rounds-sources__search_literature` with
  `{"query":"iron deficiency anemia diagnosis management guideline","tierFilter":["T1"],"maxResults":10}`.
- `tool_result`: 10 ranked **T1** guideline citations (KDIGO 2026, AGA Clinical Practice
  Update, British Society of Gastroenterology, …), each with `trustTier`, `trustScore`, and
  `whyTrusted`.
- `result`: `is_error: false`.

## Manual smoke test (no Claude needed)

Pipe JSON-RPC frames straight in:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_literature","arguments":{"query":"ferritin iron deficiency anemia treatment","maxResults":5}}}' \
  | node index.mjs
```

## Honesty note

This server only *retrieves and ranks* sources. The sources-only / propose-not-prescribe /
emergency-escalation guardrails live in the brain's hooks, subagents, and the native UI
(see `docs/ARCHITECTURE.md` §6). The ranking is deterministic and auditable, but it does not
replace clinical judgment.
