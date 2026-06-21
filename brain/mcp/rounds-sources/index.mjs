#!/usr/bin/env node
// rounds-sources — a zero-dependency MCP stdio server for the Rounds health-research app.
//
// Implements the medical-sources engine described in docs/ARCHITECTURE.md §5:
//   - search_literature : PubMed E-utilities + Europe PMC, normalized + trust-tiered
//   - find_trials       : ClinicalTrials.gov API v2
//   - drug_label        : openFDA /drug/label.json (T0 authoritative fact)
//   - rank_sources      : deterministic trust-ranking model over a citation list
//
// Pure Node 18+ ESM. NO npm dependencies. Uses the global `fetch`. Runs as `node index.mjs`.
// Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout, implemented by hand.
// stdout is the protocol channel — diagnostics go to stderr ONLY.

'use strict';

// ---------------------------------------------------------------------------
// Constants / configuration
// ---------------------------------------------------------------------------

const SERVER_NAME = 'rounds-sources';
const SERVER_VERSION = '1.0.0';
const PROTOCOL_VERSION = '2024-11-05';

// NCBI requires identifying every request. Sending these is mandatory — omitting them
// risks an unrecoverable NCBI IP block (ARCHITECTURE.md §5).
const NCBI_TOOL = 'rounds';
const NCBI_EMAIL = 'rounds-app@users.noreply.github.com';
const NCBI_API_KEY = process.env.ROUNDS_NCBI_API_KEY || ''; // optional; raises the rate limit

// Public API base URLs.
const EUTILS_BASE = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils';
const EUROPEPMC_BASE = 'https://www.ebi.ac.uk/europepmc/webservices/rest';
const CTGOV_BASE = 'https://clinicaltrials.gov/api/v2/studies';
const OPENFDA_BASE = 'https://api.fda.gov/drug/label.json';

// The openFDA disclaimer must be surfaced verbatim (ARCHITECTURE.md §5).
const OPENFDA_DISCLAIMER =
  'Do not rely on openFDA to make decisions regarding medical care. While we make ' +
  'every effort to ensure that data is accurate, you should assume all results are ' +
  'unvalidated. We may limit or otherwise restrict your access to the API in line with ' +
  'our Terms of Service.';

const NCBI_DISCLAIMER =
  'Citations and abstracts are retrieved from the U.S. National Library of Medicine ' +
  '(PubMed/MEDLINE) and Europe PMC. NLM does not endorse any product or service, and ' +
  'these records are not a substitute for professional medical advice.';

const DEFAULT_TIMEOUT_MS = 15000;
const NETWORK_TIMEOUT_MS = Number(process.env.ROUNDS_HTTP_TIMEOUT_MS || DEFAULT_TIMEOUT_MS);

// ---------------------------------------------------------------------------
// Logging — stderr ONLY. stdout is reserved for JSON-RPC frames.
// ---------------------------------------------------------------------------

function log(...args) {
  try {
    process.stderr.write('[rounds-sources] ' + args.map(stringifyArg).join(' ') + '\n');
  } catch {
    /* never let logging crash the server */
  }
}
function stringifyArg(a) {
  if (typeof a === 'string') return a;
  try {
    return JSON.stringify(a);
  } catch {
    return String(a);
  }
}

// ---------------------------------------------------------------------------
// Polite rate limiting — a simple token-bucket-ish serial queue per host.
// PubMed without a key: ~3 req/s. With a key: ~10 req/s.
// ---------------------------------------------------------------------------

function makeRateLimiter(minIntervalMs) {
  let last = 0;
  let chain = Promise.resolve();
  return function schedule(fn) {
    chain = chain.then(async () => {
      const now = Date.now();
      const wait = Math.max(0, last + minIntervalMs - now);
      if (wait > 0) await sleep(wait);
      last = Date.now();
      return fn();
    });
    // Isolate failures so one rejection doesn't poison the queue.
    const result = chain;
    chain = chain.catch(() => {});
    return result;
  };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// 3 req/s without a key (~334ms), 10 req/s with a key (~110ms).
const ncbiLimiter = makeRateLimiter(NCBI_API_KEY ? 110 : 340);
const generalLimiter = makeRateLimiter(120); // other hosts: be polite, ~8 req/s

// ---------------------------------------------------------------------------
// HTTP helpers (global fetch, with timeout + graceful failure)
// ---------------------------------------------------------------------------

async function httpGet(url, { accept = 'application/json' } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), NETWORK_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      method: 'GET',
      signal: controller.signal,
      headers: {
        Accept: accept,
        'User-Agent': `rounds-sources/${SERVER_VERSION} (+https://github.com/rounds-app)`,
      },
    });
    const text = await res.text();
    if (!res.ok) {
      const err = new Error(`HTTP ${res.status} for ${redact(url)}`);
      err.status = res.status;
      err.body = text.slice(0, 500);
      throw err;
    }
    return text;
  } finally {
    clearTimeout(timer);
  }
}

async function httpGetJson(url, opts) {
  const text = await httpGet(url, { accept: 'application/json', ...opts });
  return JSON.parse(text);
}

// Keep query params out of logs (defense in depth; queries are concept-only anyway).
function redact(url) {
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}`;
  } catch {
    return String(url).split('?')[0];
  }
}

// ---------------------------------------------------------------------------
// Trust-ranking model (ARCHITECTURE.md §5) — deterministic, no LLM judgment.
// ---------------------------------------------------------------------------

// Tier base weights.
const TIER_WEIGHT = {
  PRIMARY: 1.0, // the user's own records — a separate authority class
  T0: 0.95, // openFDA drug label — authoritative FACT, not evidence-graded
  T1: 1.0, // Practice Guideline / Cochrane / NICE / USPSTF
  T2: 0.9, // Meta-Analysis / Systematic Review
  T3: 0.75, // RCT / Controlled Clinical Trial
  T4: 0.55, // Cohort / observational (from MeSH, not PublicationType)
  T5: 0.35, // Case Report / narrative review / mechanism
  T6: 0.15, // preprint / unindexed / forum
};

// Recency half-lives (years) by tier class.
const TIER_HALFLIFE_YEARS = {
  T1: 7,
  T2: 7,
  T3: 7,
  T4: 5,
  T5: 5,
  T6: 5,
  T0: 100, // labels don't decay meaningfully
  PRIMARY: 100,
};

// One-line human-readable rationale per tier.
const TIER_LABEL = {
  PRIMARY: "the patient's own uploaded record",
  T0: 'authoritative regulatory drug label (fact, not evidence-graded)',
  T1: 'clinical practice guideline / Cochrane / NICE / USPSTF',
  T2: 'systematic review or meta-analysis',
  T3: 'randomized or controlled clinical trial',
  T4: 'cohort / observational study',
  T5: 'case report, narrative review, or mechanism study',
  T6: 'preprint, un-indexed record, or low-confidence source',
};

// Journal allowlist → reputation 1.0 even with MeSH lag.
//
// Matched against the FULL normalized journal name (exact or whole-name prefix),
// NOT as a naive substring — a substring match wrongly promotes "International
// Journal of Clinical Oncology" (matches "journal of clinical oncology") or
// "European Journal of Sport Science" (matches "science"). Distinctive short
// abbreviations are listed explicitly so they only match the real journal.
const JOURNAL_ALLOWLIST = [
  'cochrane database of systematic reviews',
  'n engl j med',
  'new england journal of medicine',
  'the new england journal of medicine',
  'lancet',
  'the lancet',
  'jama',
  'jama internal medicine',
  'jama network open',
  'journal of the american medical association',
  'bmj',
  'the bmj',
  'british medical journal',
  'annals of internal medicine',
  'ann intern med',
  'nature medicine',
  'nat med',
  'nature',
  'science',
  'cell',
  'circulation',
  'blood',
  'gut',
  'gastroenterology',
  'journal of clinical oncology',
  'j clin oncol',
  'european heart journal',
  'eur heart j',
  'diabetes care',
  'pediatrics',
];

// Publication types that indicate retraction / concern.
const RETRACTION_TYPES = new Set([
  'retracted publication',
  'retraction of publication',
]);

// PublicationType → tier (lower-cased). Highest tier wins on multi-type records.
const PUBTYPE_TIER = [
  // T1 — guidelines
  ['practice guideline', 'T1'],
  ['guideline', 'T1'],
  ['consensus development conference', 'T1'],
  // T2 — synthesis
  ['meta-analysis', 'T2'],
  ['systematic review', 'T2'],
  // T3 — trials
  ['randomized controlled trial', 'T3'],
  ['controlled clinical trial', 'T3'],
  ['clinical trial, phase iii', 'T3'],
  ['clinical trial, phase iv', 'T3'],
  ['pragmatic clinical trial', 'T3'],
  ['clinical trial', 'T3'],
  // T5 — case/narrative/mechanism
  ['case reports', 'T5'],
  ['review', 'T5'], // a narrative "Review" (NOT systematic) — only if nothing higher matched
  ['comment', 'T5'],
  ['editorial', 'T5'],
  ['letter', 'T5'],
];

const TIER_ORDER = ['PRIMARY', 'T0', 'T1', 'T2', 'T3', 'T4', 'T5', 'T6'];
function tierRank(t) {
  const i = TIER_ORDER.indexOf(t);
  return i === -1 ? TIER_ORDER.length : i;
}
function bestTier(a, b) {
  return tierRank(a) <= tierRank(b) ? a : b;
}

// Title heuristics for the MeSH-lag fallback (brand-new records have no MeSH/PubType yet).
function tierFromTitleHeuristic(title) {
  const t = (title || '').toLowerCase();
  if (/\bpractice guideline\b|\bclinical guideline\b|\bguideline(s)?\b/.test(t)) return 'T1';
  if (/\bmeta-analysis\b|\bmeta analysis\b|\bsystematic review\b/.test(t)) return 'T2';
  if (/\brandomi(z|s)ed controlled trial\b|\brandomi(z|s)ed,? double-blind\b|\bphase (ii|iii|iv) trial\b/.test(t))
    return 'T3';
  if (/\bcohort\b|\bprospective study\b|\bcase-control\b|\bobservational\b/.test(t)) return 'T4';
  if (/\bcase report\b|\bcase series\b/.test(t)) return 'T5';
  return null;
}

// Compute the trust tier from a normalized citation.
// Returns { tier, retracted, concern, reasons[] }.
function computeTier(citation) {
  const reasons = [];
  const pubTypes = (citation.pubTypes || []).map((p) => String(p).toLowerCase());
  const meshTerms = (citation.meshTerms || []).map((m) => String(m).toLowerCase());

  // Retraction → hard drop.
  const retracted = pubTypes.some((p) => RETRACTION_TYPES.has(p));
  if (retracted) reasons.push('marked as Retracted Publication');

  // Expression of Concern → flag, do not hard-drop.
  const concern =
    pubTypes.includes('expression of concern') ||
    /expression of concern/i.test(citation.title || '') ||
    (citation.commentsCorrections || []).some((c) => /expression of concern/i.test(c));
  if (concern) reasons.push('has an Expression of Concern');

  // Tier from PublicationType (highest wins).
  let tier = null;
  for (const [needle, cand] of PUBTYPE_TIER) {
    if (pubTypes.some((p) => p === needle || p.includes(needle))) {
      tier = tier ? bestTier(tier, cand) : cand;
    }
  }
  if (tier) reasons.push(`PublicationType → ${tier}`);

  // T4 cohort/observational comes primarily from MeSH, NOT PublicationType — for MEDLINE
  // the cohort PublicationType returns nothing, so the doc specifies reading MeSH
  // ("Cohort Studies"[MeSH] etc.). Europe PMC, however, DOES expose an "Observational
  // Study" PublicationType, so we honor that as a secondary signal.
  const hasCohortMesh = meshTerms.some(
    (m) =>
      m.includes('cohort studies') ||
      m.includes('prospective studies') ||
      m.includes('follow-up studies') ||
      m.includes('case-control studies') ||
      m.includes('longitudinal studies')
  );
  const hasObservationalPubType = pubTypes.some(
    (p) => p.includes('observational study') || p.includes('comparative study')
  );
  if (hasCohortMesh || hasObservationalPubType) {
    const meshTier = 'T4';
    tier = tier ? bestTier(tier, meshTier) : meshTier;
    reasons.push(hasCohortMesh ? 'MeSH cohort/observational → T4' : 'PublicationType Observational Study → T4');
  }

  // MeSH-lag fallback: un-indexed brand-new record (no PubType, no MeSH).
  // Use journal allowlist + a title heuristic so a landmark RCT isn't wrongly dropped to T6.
  if (!tier) {
    const heur = tierFromTitleHeuristic(citation.title);
    if (heur) {
      tier = heur;
      reasons.push(`MeSH-lag fallback: title heuristic → ${heur}`);
    } else if (isAllowlistedJournal(citation.journal)) {
      // A flagship journal with no indexing yet — treat as primary research (T3-ish), not forum.
      tier = 'T3';
      reasons.push('MeSH-lag fallback: flagship journal, un-indexed → T3');
    }
  }

  // Preprints / nothing → T6.
  if (!tier) {
    if (citation.source === 'EuropePMC' && citation.isPreprint) {
      tier = 'T6';
      reasons.push('preprint → T6');
    } else {
      tier = 'T6';
      reasons.push('un-classified / un-indexed → T6');
    }
  }

  return { tier, retracted, concern, reasons };
}

function normalizeJournal(j) {
  return String(j || '')
    .toLowerCase()
    .replace(/[.]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}
// Generic single words that are real flagship names but would over-match as prefixes
// (e.g. "nature" must not promote "nature reviews disease primers"? — that one is fine,
// but "cell" must not promote "cell reports" only loosely). For these, require an EXACT
// whole-name match; everything else may match as a "<name> <subtitle>" prefix.
const ALLOWLIST_EXACT_ONLY = new Set([
  'science',
  'cell',
  'gut',
  'nature',
  'blood',
  'pediatrics',
]);

function isAllowlistedJournal(journal) {
  const n = normalizeJournal(journal);
  if (!n) return false;
  // Whole-name match only: the normalized journal must EQUAL an allowlist entry, or
  // (for multi-word flagship names) start with the entry followed by a word boundary
  // (handles trailing subtitles like "lancet oncology" — still a Lancet-family
  // flagship). This avoids the substring trap where "European Journal of Sport
  // Science" matched "science" or "International Journal of Clinical Oncology"
  // matched "journal of clinical oncology".
  return JOURNAL_ALLOWLIST.some((a) => {
    if (n === a) return true;
    if (ALLOWLIST_EXACT_ONLY.has(a)) return false;
    return n.startsWith(a + ' ');
  });
}

// Reputation 0.6–1.0.
function computeReputation(citation) {
  let rep = 0.6;
  if (citation.medlineIndexed) rep = Math.max(rep, 0.8);
  if (isAllowlistedJournal(citation.journal)) rep = 1.0;
  // A high cited-by count is a mild reputation signal.
  if (typeof citation.citedBy === 'number' && citation.citedBy >= 100) {
    rep = Math.min(1.0, rep + 0.1);
  }
  return Math.min(1.0, Math.max(0.6, rep));
}

// Recency factor in (0,1]. Never raises a score above its tier weight.
function computeRecency(citation, tier) {
  const year = Number(citation.year);
  if (!year || Number.isNaN(year)) return 0.7; // unknown date → mild penalty
  const nowYear = new Date().getUTCFullYear();
  const age = Math.max(0, nowYear - year);
  const halfLife = TIER_HALFLIFE_YEARS[tier] || 7;
  // exponential decay with floor so old-but-foundational work isn't zeroed.
  const factor = Math.pow(0.5, age / halfLife);
  return Math.max(0.4, Math.min(1.0, factor));
}

// Relevance from API rank position (0..1) + a marker-in-title boost.
function computeRelevance(citation) {
  let base = typeof citation._apiRelevance === 'number' ? citation._apiRelevance : 0.6;
  if (citation._titleBoost) base = Math.min(1.0, base + 0.15);
  return Math.max(0, Math.min(1.0, base));
}

// score = baseWeight(tier) × reputation × recency × (0.5 + 0.5·relevance)
function computeScore(citation, tier) {
  const base = TIER_WEIGHT[tier] ?? 0.15;
  const reputation = computeReputation(citation);
  const recency = computeRecency(citation, tier);
  const relevance = computeRelevance(citation);
  const score = base * reputation * recency * (0.5 + 0.5 * relevance);
  return {
    score: round3(score),
    components: {
      base: round3(base),
      reputation: round3(reputation),
      recency: round3(recency),
      relevance: round3(relevance),
    },
  };
}

function round3(n) {
  return Math.round(n * 1000) / 1000;
}

function whyTrusted(citation, tier, concern) {
  const bits = [];
  bits.push(TIER_LABEL[tier] || tier);
  if (citation.journal) bits.push(citation.journal);
  if (citation.year) bits.push(String(citation.year));
  if (typeof citation.citedBy === 'number' && citation.citedBy > 0) {
    bits.push(`${citation.citedBy} citations`);
  }
  let s = capitalize(bits.join(', '));
  if (concern) s += ' — flagged with an Expression of Concern; treat with caution';
  return s;
}

function capitalize(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

// Apply ranking to an array of normalized citations.
// Drops retracted; tags tier/score/whyTrusted; sorts by (tierRank asc, score desc).
function rankCitations(citations) {
  const out = [];
  for (const c of citations) {
    const { tier, retracted, concern, reasons } = computeTier(c);
    if (retracted) {
      log(`dropped retracted: ${c.id || c.title}`);
      continue;
    }
    const { score, components } = computeScore(c, tier);
    out.push({
      ...c,
      trustTier: tier,
      trustScore: score,
      scoreComponents: components,
      concern: concern || false,
      whyTrusted: whyTrusted(c, tier, concern),
      tierReasons: reasons,
    });
  }
  out.sort((a, b) => {
    const tr = tierRank(a.trustTier) - tierRank(b.trustTier);
    if (tr !== 0) return tr;
    return b.trustScore - a.trustScore;
  });
  return out;
}

// ---------------------------------------------------------------------------
// De-duplication: DOI → PMID → fuzzy title (preprint collapses into published).
// ---------------------------------------------------------------------------

function dedupeCitations(citations) {
  const byKey = new Map();
  const order = [];
  for (const c of citations) {
    const key = dedupeKey(c);
    if (byKey.has(key)) {
      // Merge: prefer the published (non-preprint) record, keep max citedBy.
      const existing = byKey.get(key);
      byKey.set(key, mergeCitations(existing, c));
    } else {
      byKey.set(key, c);
      order.push(key);
    }
  }
  return order.map((k) => byKey.get(k));
}

function dedupeKey(c) {
  if (c.doi) return 'doi:' + String(c.doi).toLowerCase().trim();
  if (c.pmid) return 'pmid:' + String(c.pmid).trim();
  // fuzzy: normalized title
  const t = String(c.title || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
  return 'title:' + t.slice(0, 80);
}

function mergeCitations(a, b) {
  // Prefer the one that is NOT a preprint and HAS more metadata.
  const primary = a.isPreprint && !b.isPreprint ? b : a;
  const other = primary === a ? b : a;
  return {
    ...other,
    ...primary,
    citedBy: Math.max(a.citedBy || 0, b.citedBy || 0) || primary.citedBy,
    pubTypes: dedupeArr([...(a.pubTypes || []), ...(b.pubTypes || [])]),
    meshTerms: dedupeArr([...(a.meshTerms || []), ...(b.meshTerms || [])]),
    doi: primary.doi || other.doi,
    pmid: primary.pmid || other.pmid,
    medlineIndexed: a.medlineIndexed || b.medlineIndexed,
  };
}

function dedupeArr(arr) {
  return Array.from(new Set(arr.filter(Boolean)));
}

// ---------------------------------------------------------------------------
// Source: PubMed E-utilities (esearch + esummary)
// ---------------------------------------------------------------------------

function ncbiCommonParams() {
  const p = new URLSearchParams();
  p.set('tool', NCBI_TOOL);
  p.set('email', NCBI_EMAIL);
  if (NCBI_API_KEY) p.set('api_key', NCBI_API_KEY);
  return p;
}

async function pubmedSearch(query, maxResults) {
  const citations = [];
  try {
    // 1) esearch → PMIDs
    const esearchParams = ncbiCommonParams();
    esearchParams.set('db', 'pubmed');
    esearchParams.set('term', query);
    esearchParams.set('retmax', String(Math.min(Math.max(maxResults, 1), 50)));
    esearchParams.set('retmode', 'json');
    esearchParams.set('sort', 'relevance');
    const esearchUrl = `${EUTILS_BASE}/esearch.fcgi?${esearchParams.toString()}`;
    const esearch = await ncbiLimiter(() => httpGetJson(esearchUrl));
    const idlist =
      (esearch && esearch.esearchresult && esearch.esearchresult.idlist) || [];
    if (idlist.length === 0) return citations;

    // 2) esummary → metadata for each PMID
    const esummaryParams = ncbiCommonParams();
    esummaryParams.set('db', 'pubmed');
    esummaryParams.set('id', idlist.join(','));
    esummaryParams.set('retmode', 'json');
    const esummaryUrl = `${EUTILS_BASE}/esummary.fcgi?${esummaryParams.toString()}`;
    const esummary = await ncbiLimiter(() => httpGetJson(esummaryUrl));
    const result = (esummary && esummary.result) || {};
    const uids = result.uids || idlist;

    uids.forEach((uid, idx) => {
      const r = result[uid];
      if (!r) return;
      citations.push(normalizePubmed(r, uid, idx, idlist.length, query));
    });
  } catch (e) {
    log('pubmed error:', e.message);
  }
  return citations;
}

function normalizePubmed(r, uid, idx, total, query) {
  const pubTypes = Array.isArray(r.pubtype) ? r.pubtype.slice() : [];
  const year = parseYear(r.pubdate || r.epubdate || r.sortpubdate);
  let doi = '';
  if (Array.isArray(r.articleids)) {
    const d = r.articleids.find((a) => a.idtype === 'doi');
    if (d) doi = d.value;
  }
  const journal = r.fulljournalname || r.source || '';
  const titleLc = String(r.title || '').toLowerCase();
  const titleBoost = queryTerms(query).some((t) => t.length > 3 && titleLc.includes(t));
  // MEDLINE-indexed heuristic: pubstatus/records carrying a full journal name + MeSH.
  const medlineIndexed = !!r.fulljournalname;
  return {
    id: doi ? `doi:${doi}` : `pmid:${uid}`,
    source: 'PubMed',
    title: cleanText(r.title),
    journal,
    year,
    pubTypes,
    meshTerms: [], // esummary does not return MeSH; computeTier handles the gap via fallback
    url: `https://pubmed.ncbi.nlm.nih.gov/${uid}/`,
    doi,
    pmid: String(uid),
    citedBy: undefined,
    isPreprint: pubTypes.some((p) => /preprint/i.test(p)),
    commentsCorrections: [],
    medlineIndexed,
    _apiRelevance: total > 0 ? 1 - idx / Math.max(total, 1) : 0.6,
    _titleBoost: titleBoost,
  };
}

// ---------------------------------------------------------------------------
// Source: Europe PMC REST (preprints + citedByCount + isOpenAccess)
// ---------------------------------------------------------------------------

async function europePmcSearch(query, maxResults) {
  const citations = [];
  try {
    const params = new URLSearchParams();
    params.set('query', query);
    params.set('format', 'json');
    params.set('pageSize', String(Math.min(Math.max(maxResults, 1), 50)));
    params.set('resultType', 'core');
    const url = `${EUROPEPMC_BASE}/search?${params.toString()}`;
    const data = await generalLimiter(() => httpGetJson(url));
    const results =
      (data && data.resultList && data.resultList.result) || [];
    results.forEach((r, idx) => {
      citations.push(normalizeEuropePmc(r, idx, results.length, query));
    });
  } catch (e) {
    log('europepmc error:', e.message);
  }
  return citations;
}

function normalizeEuropePmc(r, idx, total, query) {
  const pubTypes = [];
  if (r.pubTypeList && Array.isArray(r.pubTypeList.pubType)) {
    pubTypes.push(...r.pubTypeList.pubType);
  } else if (typeof r.pubType === 'string') {
    pubTypes.push(r.pubType);
  }
  const meshTerms = [];
  if (r.meshHeadingList && Array.isArray(r.meshHeadingList.meshHeading)) {
    for (const m of r.meshHeadingList.meshHeading) {
      if (m && m.descriptorName) meshTerms.push(m.descriptorName);
    }
  }
  const isPreprint =
    String(r.source || '').toUpperCase() === 'PPR' ||
    pubTypes.some((p) => /preprint/i.test(p));
  const doi = r.doi || '';
  const pmid = r.pmid || '';
  const year = parseYear(r.firstPublicationDate || r.pubYear);
  const journal =
    (r.journalInfo && r.journalInfo.journal && r.journalInfo.journal.title) ||
    r.journalTitle ||
    (isPreprint ? 'Preprint' : '');
  const titleLc = String(r.title || '').toLowerCase();
  const titleBoost = queryTerms(query).some((t) => t.length > 3 && titleLc.includes(t));
  let url = '';
  if (doi) url = `https://doi.org/${doi}`;
  else if (pmid) url = `https://europepmc.org/abstract/MED/${pmid}`;
  else if (r.id && r.source) url = `https://europepmc.org/abstract/${r.source}/${r.id}`;
  return {
    id: doi ? `doi:${doi}` : pmid ? `pmid:${pmid}` : `epmc:${r.source}-${r.id}`,
    source: 'EuropePMC',
    title: cleanText(r.title),
    journal,
    year,
    pubTypes,
    meshTerms,
    url,
    doi,
    pmid: pmid ? String(pmid) : '',
    citedBy: typeof r.citedByCount === 'number' ? r.citedByCount : undefined,
    isPreprint,
    isOpenAccess: r.isOpenAccess === 'Y',
    commentsCorrections: [],
    medlineIndexed: String(r.source || '').toUpperCase() === 'MED',
    _apiRelevance: total > 0 ? 1 - idx / Math.max(total, 1) : 0.6,
    _titleBoost: titleBoost,
  };
}

// ---------------------------------------------------------------------------
// Tool: search_literature
// ---------------------------------------------------------------------------

async function tool_search_literature(args) {
  const query = String(args.query || '').trim();
  const maxResults = clampInt(args.maxResults, 8, 1, 25);
  const tierFilter = normalizeTierFilter(args.tierFilter);

  if (!query) {
    return { citations: [], note: 'No query provided.', disclaimer: NCBI_DISCLAIMER };
  }

  // Fan out to both corpora in parallel; each fails independently.
  const fetchCount = Math.min(maxResults * 2, 25); // over-fetch to survive de-dup
  const [pm, epmc] = await Promise.all([
    pubmedSearch(query, fetchCount),
    europePmcSearch(query, fetchCount),
  ]);

  const merged = dedupeCitations([...pm, ...epmc]);
  let ranked = rankCitations(merged); // drops retracted

  if (tierFilter && tierFilter.length) {
    ranked = ranked.filter((c) => tierFilter.includes(c.trustTier));
  }

  const top = ranked.slice(0, maxResults).map(shapeCitationOut);

  const note =
    top.length === 0
      ? 'No citations matched (after ranking/filtering). Try a broader query or remove the tier filter.'
      : `Returned ${top.length} ranked citation(s) from PubMed + Europe PMC. Retracted publications were dropped.`;

  return {
    query,
    citations: top,
    counts: { pubmed: pm.length, europepmc: epmc.length, afterDedup: merged.length, afterRank: ranked.length },
    disclaimer: NCBI_DISCLAIMER,
    note,
  };
}

function shapeCitationOut(c) {
  return {
    id: c.id,
    source: c.source,
    title: c.title,
    journal: c.journal || null,
    year: c.year || null,
    pubTypes: c.pubTypes || [],
    url: c.url,
    doi: c.doi || null,
    pmid: c.pmid || null,
    citedBy: typeof c.citedBy === 'number' ? c.citedBy : null,
    trustTier: c.trustTier,
    trustScore: c.trustScore,
    concern: c.concern || false,
    whyTrusted: c.whyTrusted,
  };
}

// ---------------------------------------------------------------------------
// Tool: find_trials — ClinicalTrials.gov API v2
// ---------------------------------------------------------------------------

async function tool_find_trials(args) {
  const condition = String(args.condition || '').trim();
  const status = String(args.status || 'RECRUITING').trim().toUpperCase();
  const maxResults = clampInt(args.maxResults, 8, 1, 25);

  if (!condition) {
    return { trials: [], note: 'No condition provided.' };
  }

  const trials = [];
  try {
    const params = new URLSearchParams();
    params.set('query.cond', condition);
    params.set('pageSize', String(maxResults));
    params.set('countTotal', 'true');
    // Status filter (CT.gov v2 accepts a pipe-separated overallStatus filter).
    if (status && status !== 'ANY' && status !== 'ALL') {
      params.set('filter.overallStatus', status);
    }
    // Only request the fields we need.
    params.set(
      'fields',
      [
        'NCTId',
        'BriefTitle',
        'OverallStatus',
        'Phase',
        'Condition',
        'LocationCountry',
        'LocationFacility',
      ].join(',')
    );
    const url = `${CTGOV_BASE}?${params.toString()}`;
    const data = await generalLimiter(() => httpGetJson(url));
    const studies = (data && data.studies) || [];
    for (const s of studies) {
      trials.push(normalizeTrial(s));
    }
  } catch (e) {
    log('ctgov error:', e.message);
    return {
      condition,
      status,
      trials: [],
      note: `ClinicalTrials.gov request failed (${e.message}). Returning an empty list.`,
    };
  }

  return {
    condition,
    status,
    trials,
    note:
      trials.length === 0
        ? `No ${status} trials found for "${condition}".`
        : `Found ${trials.length} trial(s) for "${condition}" with status ${status}.`,
  };
}

function normalizeTrial(s) {
  const proto = s.protocolSection || {};
  const idMod = proto.identificationModule || {};
  const statusMod = proto.statusModule || {};
  const designMod = proto.designModule || {};
  const condMod = proto.conditionsModule || {};
  const contactsMod = proto.contactsLocationsModule || {};
  const nctId = idMod.nctId || '';
  const locations = Array.isArray(contactsMod.locations) ? contactsMod.locations : [];
  return {
    nctId,
    title: idMod.briefTitle || idMod.officialTitle || '',
    status: statusMod.overallStatus || '',
    phase: Array.isArray(designMod.phases) ? designMod.phases.join(', ') : (designMod.phases || 'N/A'),
    conditions: Array.isArray(condMod.conditions) ? condMod.conditions : [],
    url: nctId ? `https://clinicaltrials.gov/study/${nctId}` : '',
    locationsCount: locations.length,
    countries: dedupeArr(locations.map((l) => l.country)).slice(0, 10),
  };
}

// ---------------------------------------------------------------------------
// Tool: drug_label — openFDA /drug/label.json (T0 authoritative fact)
// ---------------------------------------------------------------------------

async function tool_drug_label(args) {
  const name = String(args.name || '').trim();
  if (!name) {
    return { results: [], disclaimer: OPENFDA_DISCLAIMER, note: 'No drug name provided.' };
  }

  try {
    // Search brand name OR generic name.
    const escaped = name.replace(/"/g, '');
    const search = `(openfda.brand_name:"${escaped}"+openfda.generic_name:"${escaped}")`;
    const params = new URLSearchParams();
    params.set('search', search);
    params.set('limit', '1');
    if (process.env.ROUNDS_OPENFDA_API_KEY) {
      params.set('api_key', process.env.ROUNDS_OPENFDA_API_KEY);
    }
    const url = `${OPENFDA_BASE}?${params.toString()}`;
    const data = await generalLimiter(() => httpGetJson(url));
    const results = (data && data.results) || [];
    if (results.length === 0) {
      return {
        name,
        label: null,
        trustTier: 'T0',
        disclaimer: OPENFDA_DISCLAIMER,
        note: `No openFDA label found for "${name}".`,
      };
    }
    const r = results[0];
    const openfda = r.openfda || {};
    const label = {
      brandName: firstOf(openfda.brand_name),
      genericName: firstOf(openfda.generic_name),
      manufacturer: firstOf(openfda.manufacturer_name),
      route: firstOf(openfda.route),
      indications: joinField(r.indications_and_usage),
      dosage: joinField(r.dosage_and_administration),
      warnings: joinField(r.warnings || r.warnings_and_cautions),
      boxedWarning: joinField(r.boxed_warning),
      contraindications: joinField(r.contraindications),
      adverseReactions: joinField(r.adverse_reactions),
      drugInteractions: joinField(r.drug_interactions),
    };
    return {
      name,
      trustTier: 'T0',
      label,
      whyTrusted: 'openFDA structured product label — authoritative regulatory fact (not evidence-graded)',
      disclaimer: OPENFDA_DISCLAIMER,
      note: `openFDA label for ${label.brandName || label.genericName || name}.`,
    };
  } catch (e) {
    log('openfda error:', e.message);
    return {
      name,
      label: null,
      trustTier: 'T0',
      disclaimer: OPENFDA_DISCLAIMER,
      note: `openFDA request failed (${e.message}). Returning no label.`,
    };
  }
}

function firstOf(v) {
  if (Array.isArray(v)) return v[0] || null;
  return v || null;
}
function joinField(v) {
  if (!v) return null;
  if (Array.isArray(v)) {
    const joined = v.join('\n\n').trim();
    return joined ? truncate(joined, 4000) : null;
  }
  return truncate(String(v), 4000);
}

// ---------------------------------------------------------------------------
// Tool: rank_sources — apply the deterministic model to a caller-supplied list
// ---------------------------------------------------------------------------

async function tool_rank_sources(args) {
  const input = Array.isArray(args.citations) ? args.citations : [];
  if (input.length === 0) {
    return { citations: [], note: 'No citations provided to rank.' };
  }
  // Accept loosely-shaped citations; normalize a couple of common field aliases.
  const normalized = input.map((c) => ({
    id: c.id || (c.doi ? `doi:${c.doi}` : c.pmid ? `pmid:${c.pmid}` : undefined),
    source: c.source || 'provided',
    title: c.title || '',
    journal: c.journal || '',
    year: c.year || parseYear(c.date),
    pubTypes: c.pubTypes || c.publicationTypes || c.pubtype || [],
    meshTerms: c.meshTerms || c.mesh || [],
    url: c.url || '',
    doi: c.doi || '',
    pmid: c.pmid ? String(c.pmid) : '',
    citedBy: typeof c.citedBy === 'number' ? c.citedBy : (typeof c.citedByCount === 'number' ? c.citedByCount : undefined),
    isPreprint: !!c.isPreprint,
    commentsCorrections: c.commentsCorrections || [],
    medlineIndexed: !!c.medlineIndexed,
    _apiRelevance: typeof c.relevance === 'number' ? c.relevance : 0.6,
    _titleBoost: false,
  }));

  const ranked = rankCitations(normalized).map((c) => ({
    ...shapeCitationOut(c),
    scoreComponents: c.scoreComponents,
    tierReasons: c.tierReasons,
  }));

  const droppedRetracted = normalized.length - ranked.length;
  return {
    citations: ranked,
    note: `Ranked ${ranked.length} citation(s)${droppedRetracted > 0 ? `; dropped ${droppedRetracted} retracted` : ''}. Sorted by trust tier then score.`,
  };
}

// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------

function parseYear(s) {
  if (!s) return null;
  const m = String(s).match(/(\d{4})/);
  return m ? Number(m[1]) : null;
}
function queryTerms(q) {
  return String(q || '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .split(/\s+/)
    .filter(Boolean);
}
function cleanText(s) {
  return String(s || '')
    .replace(/<[^>]+>/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}
function truncate(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n) + '…' : s;
}
function clampInt(v, dflt, lo, hi) {
  let n = Number(v);
  if (!Number.isFinite(n)) n = dflt;
  n = Math.floor(n);
  return Math.min(hi, Math.max(lo, n));
}
function normalizeTierFilter(tf) {
  if (!tf) return null;
  const arr = Array.isArray(tf) ? tf : [tf];
  const valid = new Set(TIER_ORDER);
  return arr.map((t) => String(t).toUpperCase()).filter((t) => valid.has(t));
}

// ---------------------------------------------------------------------------
// Tool registry + dispatch
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'search_literature',
    description:
      'Search medical literature (PubMed/MEDLINE E-utilities + Europe PMC) and return normalized, ' +
      'trust-tiered citations. Computes a deterministic trust tier (T1 guideline … T6 preprint) and ' +
      'score from PublicationType/MeSH, drops retracted publications, flags Expressions of Concern, ' +
      'and applies a MeSH-lag journal-allowlist fallback. Use for any clinically meaningful claim. ' +
      'BEST PRACTICE: search guideline-first — make your first call target the top of the evidence ' +
      'pyramid (add "guideline"/"systematic review" to the query, or pass tierFilter:["T1","T2"]) and ' +
      'lead your claim with the highest-tier result; broaden to lower tiers only if nothing higher exists.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Concept-only, de-identified search query (no patient identifiers). e.g. "ferritin iron deficiency anemia treatment guideline".',
        },
        maxResults: { type: 'integer', description: 'Max citations to return (default 8, max 25).', default: 8 },
        tierFilter: {
          type: 'array',
          items: { type: 'string', enum: TIER_ORDER },
          description: 'Optional list of trust tiers to keep, e.g. ["T1","T2"] for guidelines + systematic reviews only.',
        },
      },
      required: ['query'],
    },
  },
  {
    name: 'find_trials',
    description:
      'Find clinical trials from ClinicalTrials.gov API v2 for a condition. Returns nctId, title, status, ' +
      'phase, conditions, url, and a location count. Filter by recruitment status to get an actionable list.',
    inputSchema: {
      type: 'object',
      properties: {
        condition: { type: 'string', description: 'The condition/disease to search trials for (concept-only).' },
        status: {
          type: 'string',
          description: 'Recruitment status filter (e.g. RECRUITING, ACTIVE_NOT_RECRUITING, COMPLETED, ANY). Default RECRUITING.',
          default: 'RECRUITING',
        },
        maxResults: { type: 'integer', description: 'Max trials to return (default 8, max 25).', default: 8 },
      },
      required: ['condition'],
    },
  },
  {
    name: 'drug_label',
    description:
      'Look up an authoritative FDA drug label via openFDA (/drug/label.json). Returns indications, dosage, ' +
      'warnings, boxed warning, contraindications, interactions + the openFDA disclaimer verbatim. ' +
      'Trust tier T0 — an authoritative regulatory fact, NOT evidence-graded literature.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Brand or generic drug name, e.g. "metformin" or "Tylenol".' },
      },
      required: ['name'],
    },
  },
  {
    name: 'rank_sources',
    description:
      'Apply the deterministic Rounds trust-ranking model to a caller-supplied list of citations. ' +
      'Returns them sorted by trust tier then score, each annotated with trustTier, trustScore, and a ' +
      'one-line whyTrusted explanation. Drops retracted publications.',
    inputSchema: {
      type: 'object',
      properties: {
        citations: {
          type: 'array',
          description: 'Citations to rank. Each may include id, title, journal, year, pubTypes[], meshTerms[], doi, pmid, citedBy.',
          items: { type: 'object' },
        },
      },
      required: ['citations'],
    },
  },
];

const TOOL_HANDLERS = {
  search_literature: tool_search_literature,
  find_trials: tool_find_trials,
  drug_label: tool_drug_label,
  rank_sources: tool_rank_sources,
};

async function callTool(name, args) {
  const handler = TOOL_HANDLERS[name];
  if (!handler) {
    return mcpToolError(`Unknown tool: ${name}`);
  }
  try {
    const result = await handler(args || {});
    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    };
  } catch (e) {
    log(`tool ${name} threw:`, e && e.stack ? e.stack : e);
    // Never throw out of the JSON-RPC handler — return a structured error result.
    return mcpToolError(`Tool ${name} failed: ${e && e.message ? e.message : String(e)}`);
  }
}

function mcpToolError(message) {
  return {
    isError: true,
    content: [{ type: 'text', text: JSON.stringify({ error: message, citations: [] }, null, 2) }],
  };
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 over newline-delimited stdio (implemented by hand)
// ---------------------------------------------------------------------------

function writeMessage(obj) {
  try {
    process.stdout.write(JSON.stringify(obj) + '\n');
  } catch (e) {
    log('failed to write message:', e.message);
  }
}

function jsonRpcResult(id, result) {
  writeMessage({ jsonrpc: '2.0', id, result });
}
function jsonRpcError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  writeMessage({ jsonrpc: '2.0', id: id ?? null, error });
}

async function handleRequest(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;

  try {
    switch (method) {
      case 'initialize': {
        jsonRpcResult(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        });
        return;
      }
      case 'notifications/initialized': {
        // No reply for notifications.
        return;
      }
      case 'ping': {
        if (!isNotification) jsonRpcResult(id, {});
        return;
      }
      case 'tools/list': {
        jsonRpcResult(id, { tools: TOOLS });
        return;
      }
      case 'tools/call': {
        const name = params && params.name;
        const args = (params && params.arguments) || {};
        const result = await callTool(name, args);
        jsonRpcResult(id, result);
        return;
      }
      default: {
        if (isNotification) {
          log('ignoring unknown notification:', method);
          return;
        }
        jsonRpcError(id, -32601, `Method not found: ${method}`);
        return;
      }
    }
  } catch (e) {
    log('handler error:', e && e.stack ? e.stack : e);
    if (!isNotification) {
      jsonRpcError(id, -32603, 'Internal error', String(e && e.message ? e.message : e));
    }
  }
}

// ---------------------------------------------------------------------------
// stdin reader: buffer bytes, split on newlines, parse each line as one frame.
// ---------------------------------------------------------------------------

function startServer() {
  let buffer = '';
  let stdinEnded = false;
  let inFlight = 0;
  process.stdin.setEncoding('utf8');

  // Exit only once stdin has closed AND no request is still being processed —
  // otherwise an in-flight network call (e.g. a search that closed stdin right after
  // sending the frame) would be aborted before its response is written.
  function maybeExit() {
    if (stdinEnded && inFlight === 0) {
      log('stdin closed and no in-flight requests; exiting.');
      process.exit(0);
    }
  }

  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let nl;
    while ((nl = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);
      const trimmed = line.trim();
      if (!trimmed) continue;
      let msg;
      try {
        msg = JSON.parse(trimmed);
      } catch (e) {
        log('failed to parse JSON-RPC line:', e.message);
        jsonRpcError(null, -32700, 'Parse error');
        continue;
      }
      // Fire-and-forget; each request is independent. Never crash on a bad one.
      inFlight++;
      Promise.resolve(handleRequest(msg))
        .catch((e) => {
          log('unhandled request error:', e && e.stack ? e.stack : e);
        })
        .finally(() => {
          inFlight--;
          maybeExit();
        });
    }
  });

  process.stdin.on('end', () => {
    stdinEnded = true;
    maybeExit();
  });

  process.stdin.on('error', (e) => {
    log('stdin error:', e.message);
  });

  // Keep the process alive on uncaught issues rather than crashing the transport.
  process.on('uncaughtException', (e) => {
    log('uncaughtException:', e && e.stack ? e.stack : e);
  });
  process.on('unhandledRejection', (e) => {
    log('unhandledRejection:', e && e.stack ? e.stack : e);
  });

  log(`${SERVER_NAME} v${SERVER_VERSION} ready on stdio (protocol ${PROTOCOL_VERSION}).`);
}

startServer();
