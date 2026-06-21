#!/usr/bin/env node
//
// Rounds permission bridge — a Claude Code PreToolUse hook.
// Claude runs this before a gated tool (Bash, WebSearch, Task, …). We hand the request to the
// Rounds app via files and wait for the user's Allow/Deny, then return the decision.
//
//   stdin  : { tool_name, tool_input, tool_use_id, cwd, ... }
//   stdout : { hookSpecificOutput: { hookEventName:"PreToolUse", permissionDecision, permissionDecisionReason } }
//
// Handshake dir: <vault>/.rounds/perm/  (vault = the input's cwd, which is the Rounds vault root)
//   - always-allow.json : ["Bash", ...]  tools the user chose "always allow" → instant allow
//   - req-<id>.json     : written by us, picked up by the app
//   - res-<id>.json     : written by the app  { decision:"allow"|"deny", reason }
//

import fs from 'node:fs';
import path from 'node:path';

function decide(decision, reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision,
      permissionDecisionReason: reason || '',
    },
  }));
  process.exit(0);
}

let buf = '';
process.stdin.on('data', (d) => (buf += d));
process.stdin.on('end', async () => {
  let input = {};
  try { input = JSON.parse(buf || '{}'); } catch {}
  const tool = input.tool_name || 'a tool';
  const cwd = input.cwd || process.cwd();
  const permDir = path.join(cwd, '.rounds', 'perm');
  const id = (input.tool_use_id || `${Date.now()}`).replace(/[^A-Za-z0-9_-]/g, '');

  try { fs.mkdirSync(permDir, { recursive: true }); } catch {}

  // Fast path: the user already chose "always allow" for this tool.
  try {
    const list = JSON.parse(fs.readFileSync(path.join(permDir, 'always-allow.json'), 'utf8'));
    if (Array.isArray(list) && list.includes(tool)) decide('allow', 'You allowed this tool for the session.');
  } catch {}

  // Ask the app.
  const reqPath = path.join(permDir, `req-${id}.json`);
  const resPath = path.join(permDir, `res-${id}.json`);
  try {
    fs.writeFileSync(reqPath, JSON.stringify({
      id, tool_name: tool, tool_input: input.tool_input || {}, ts: Date.now(),
    }));
  } catch {
    decide('allow', 'Rounds could not record the request; allowing.'); // never hard-block on our own error
  }

  const deadline = Date.now() + 180_000; // 3 min
  const poll = () => {
    let res = null;
    try { res = JSON.parse(fs.readFileSync(resPath, 'utf8')); } catch {}
    if (res) {
      try { fs.unlinkSync(reqPath); } catch {}
      try { fs.unlinkSync(resPath); } catch {}
      const allow = res.decision === 'allow';
      decide(allow ? 'allow' : 'deny', res.reason || (allow ? 'You approved this in Rounds.' : 'You declined this in Rounds.'));
    }
    if (Date.now() > deadline) {
      try { fs.unlinkSync(reqPath); } catch {}
      decide('deny', 'No response from Rounds — declined for safety.');
    }
    setTimeout(poll, 250);
  };
  poll();
});
