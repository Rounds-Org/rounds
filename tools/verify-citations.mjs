#!/usr/bin/env node
// Anti-hallucination check: independently resolve every cited PMID/DOI and confirm the
// title matches what the assistant claimed. Catches fabricated or mismatched citations.
//
// Usage: node tools/verify-citations.mjs [vaultPath]   (default: ~/Rounds)
//        node tools/verify-citations.mjs --sources path/to/sources.json
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const EMAIL = 'rounds-app@users.noreply.github.com'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const norm = (s) => (s || '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim()

function tokenOverlap(a, b) {
  const A = new Set(norm(a).split(' ').filter((w) => w.length > 3))
  const B = new Set(norm(b).split(' ').filter((w) => w.length > 3))
  if (!A.size || !B.size) return 0
  let hit = 0
  for (const w of A) if (B.has(w)) hit++
  return hit / Math.min(A.size, B.size)
}

async function pubmedTitle(pmid) {
  const url = `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=${pmid}&retmode=json&tool=rounds&email=${EMAIL}`
  const r = await fetch(url)
  if (!r.ok) return null
  const j = await r.json()
  const rec = j?.result?.[pmid]
  if (!rec || rec.error) return null
  return rec.title || null
}

async function crossrefTitle(doi) {
  const url = `https://api.crossref.org/works/${encodeURIComponent(doi)}?mailto=${EMAIL}`
  const r = await fetch(url)
  if (!r.ok) return null
  const j = await r.json()
  return j?.message?.title?.[0] || null
}

function collectSources(vault) {
  const out = []
  const pushFrom = (arr, where) => {
    for (const s of arr || []) {
      const pmid = s.pmid || (typeof s.url === 'string' && (s.url.match(/pubmed\.ncbi\.nlm\.nih\.gov\/(\d+)/) || [])[1])
      const doi = s.doi || (typeof s.url === 'string' && (s.url.match(/doi\.org\/(.+)$/) || [])[1])
      if (s.trustTier === 'PRIMARY' || s.tier === 'PRIMARY' || s.type === 'primary_record') continue
      out.push({ where, id: s.id || s.ref, title: s.title, tier: s.trustTier || s.tier, pmid, doi })
    }
  }
  const peopleDir = path.join(vault, 'people')
  for (const person of safeReaddir(peopleDir)) {
    const hyps = path.join(peopleDir, person, 'hypotheses')
    for (const h of safeReaddir(hyps)) {
      const f = path.join(hyps, h, 'hypothesis.json')
      if (fs.existsSync(f)) pushFrom(readJSON(f)?.sources, `${person}/${h}`)
    }
  }
  for (const f of safeReaddir(path.join(vault, 'chats'))) {
    if (f.endsWith('.sources.json')) pushFrom(readJSON(path.join(vault, 'chats', f)), `chat/${f}`)
  }
  return out
}

const safeReaddir = (d) => { try { return fs.readdirSync(d) } catch { return [] } }
const readJSON = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')) } catch { return null } }

async function main() {
  const args = process.argv.slice(2)
  let sources
  if (args[0] === '--sources') {
    sources = (readJSON(args[1]) || []).map((s) => ({ where: args[1], id: s.id || s.ref, title: s.title, tier: s.trustTier || s.tier, pmid: s.pmid, doi: s.doi }))
  } else {
    const vault = args[0] || path.join(os.homedir(), 'Rounds')
    sources = collectSources(vault)
  }

  if (!sources.length) { console.log('No non-primary citations found to verify.'); return }
  console.log(`Verifying ${sources.length} cited source(s)...\n`)

  let real = 0, fabricated = 0, unverifiable = 0
  for (const s of sources) {
    let resolvedTitle = null, via = null
    if (s.pmid) { resolvedTitle = await pubmedTitle(s.pmid); via = `PMID ${s.pmid}`; await sleep(350) }
    if (!resolvedTitle && s.doi) { resolvedTitle = await crossrefTitle(s.doi); via = `DOI ${s.doi}`; await sleep(200) }

    if (!s.pmid && !s.doi) {
      unverifiable++
      console.log(`  ?  [${s.tier}] ${trunc(s.title)}  — no PMID/DOI to verify`)
      continue
    }
    if (!resolvedTitle) {
      fabricated++
      console.log(`  ✗  ${via} did NOT resolve — possible fabrication: ${trunc(s.title)}`)
      continue
    }
    const overlap = tokenOverlap(s.title, resolvedTitle)
    if (overlap >= 0.55) {
      real++
      console.log(`  ✓  ${via} resolves, title matches (${overlap.toFixed(2)}) [${s.tier}]`)
    } else {
      fabricated++
      console.log(`  ✗  ${via} resolves but TITLE MISMATCH (${overlap.toFixed(2)})`)
      console.log(`       claimed:  ${trunc(s.title)}`)
      console.log(`       actual:   ${trunc(resolvedTitle)}`)
    }
  }

  console.log(`\nResult: ${real} real, ${fabricated} fabricated/mismatched, ${unverifiable} unverifiable (no id).`)
  process.exitCode = fabricated > 0 ? 1 : 0
}

const trunc = (s) => (s || '').slice(0, 90)
main().catch((e) => { console.error('verifier error:', e.message); process.exitCode = 2 })
