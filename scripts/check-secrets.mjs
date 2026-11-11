#!/usr/bin/env node
// Blocks commits that would publish secrets or personal financial data.
// Ballast is a public repo that handles bank data, so this runs as a git
// pre-commit / pre-merge-commit hook (.githooks/) and in CI (secrets-guard.yml).
//
//   node scripts/check-secrets.mjs --staged   files in the index (hook mode)
//   node scripts/check-secrets.mjs --all      every tracked file (CI mode)
//
// Reviewed false positives go in .secrets-guard-allow, one per line:
//   <rule-id> <path-glob>
// Exit codes: 0 clean, 1 findings, 2 the check itself failed.

import { execFileSync, spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";

// Path rules: files that must never be committed, whatever they contain.
const PATH_RULES = [
  { id: "env-file", re: /(^|\/)\.env(\.[^/]*)?$/i, allow: /\.(example|erb)$/i,
    why: "environment file (holds credentials)" },
  { id: "db-dump", re: /\.(sql|dump|pgdump|backup|bak|sqlite3?|db)(\.(gz|zst|bz2|xz|zip))?$/i,
    why: "database dump or database file" },
  { id: "db-dump", re: /(^|\/)dump\.rdb$/i, why: "Redis dump" },
  { id: "bank-export", re: /\.(ofx|qfx|qif|qbo)$/i, why: "bank export file" },
  { id: "bank-export", re: /\.csv$/i, allow: /^test\/fixtures\//,
    why: "CSV outside test/fixtures (bank exports are personal data)" },
  { id: "key-file", re: /\.(pem|key|p12|pfx|jks)$/i, why: "key or certificate file" },
  { id: "key-file", re: /(^|\/)config\/(master\.key|credentials\/[^/]+\.key)$/, why: "Rails master key" },
  { id: "screenshot", re: /(screen.?shot|capture)[^/]*\.(png|jpe?g|webp|gif|bmp)$|(^|\/)\.playwright-mcp\//i,
    why: "screenshot (may show real accounts)" },
  { id: "backup-dir", re: /(^|\/)(backups?|pg_?backups?)\//i, why: "file inside a backup folder" },
];

// Content rules: checked on every text file.
const CONTENT_RULES = [
  { id: "simplefin-url", why: "SimpleFIN access URL (reads every linked account)",
    re: /https?:\/\/[^\s"'`<>\/@:]+:[^\s"'`<>\/@]+@[^\s"'`<>\/]*simplefin/i },
  { id: "private-key", why: "private key block", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { id: "secret-key-base", why: "Rails SECRET_KEY_BASE value",
    re: /SECRET_KEY_BASE\s*[=:]\s*["']?[0-9a-f]{64,}/i },
  { id: "aws-key", why: "AWS access key id", re: /\b(AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { id: "github-token", why: "GitHub token", re: /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b/ },
  { id: "anthropic-key", why: "Anthropic API key", re: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { id: "openai-key", why: "OpenAI API key", re: /\bsk-(proj-)?[A-Za-z0-9]{32,}\b/ },
];

// SimpleFIN setup tokens are base64 of a claim URL; decode long base64 runs.
const B64_RUN = /[A-Za-z0-9+/]{40,}={0,2}/g;
function hasEncodedSimplefin(text) {
  for (const m of text.matchAll(B64_RUN)) {
    const decoded = Buffer.from(m[0], "base64").toString("latin1");
    if (/simplefin/i.test(decoded)) return true;
  }
  return false;
}

function globToRe(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*\*/g, "\0").replace(/\*/g, "[^/]*").replace(/\0/g, ".*").replace(/\?/g, "[^/]");
  return new RegExp(`^${esc}$`);
}

function loadAllowlist() {
  const file = ".secrets-guard-allow";
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split(/\r?\n/)
    .map((l) => l.replace(/#.*/, "").trim()).filter(Boolean)
    .map((l) => {
      const [rule, glob] = l.split(/\s+/);
      if (!rule || !glob) throw new Error(`bad .secrets-guard-allow line: ${l}`);
      return { rule, re: globToRe(glob) };
    });
}

function listIndexEntries() {
  // mode, sha, stage, path for every file in the index (or staged changes only).
  const out = execFileSync("git", ["ls-files", "-s", "-z"], { maxBuffer: 1 << 28 }).toString();
  let entries = out.split("\0").filter(Boolean).map((line) => {
    const tab = line.indexOf("\t");
    const [fmode, sha] = line.slice(0, tab).split(" ");
    return { fmode, sha, path: line.slice(tab + 1) };
  }).filter((e) => e.fmode !== "160000"); // skip submodules
  if (mode === "--staged") {
    const changed = new Set(execFileSync("git",
      ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], { maxBuffer: 1 << 28 })
      .toString().split("\0").filter(Boolean));
    entries = entries.filter((e) => changed.has(e.path));
  }
  return entries;
}

// Stream blob contents through one `git cat-file --batch` process.
function readBlobs(shas) {
  return new Promise((resolve, reject) => {
    const proc = spawn("git", ["cat-file", "--batch"]);
    const chunks = [];
    proc.stdout.on("data", (c) => chunks.push(c));
    proc.on("error", reject);
    proc.on("close", (code) => {
      if (code !== 0) return reject(new Error(`git cat-file exited ${code}`));
      const buf = Buffer.concat(chunks);
      const blobs = new Map();
      let pos = 0;
      while (pos < buf.length) {
        const nl = buf.indexOf(10, pos);
        const [sha, , size] = buf.slice(pos, nl).toString().split(" ");
        const len = Number(size);
        blobs.set(sha, buf.subarray(nl + 1, nl + 1 + len));
        pos = nl + 1 + len + 1;
      }
      resolve(blobs);
    });
    proc.stdin.end([...new Set(shas)].join("\n") + "\n");
  });
}

async function main() {
  const allow = loadAllowlist();
  const allowed = (rule, path) => allow.some((a) => a.rule === rule && a.re.test(path));
  const entries = listIndexEntries();
  const findings = [];

  for (const e of entries) {
    for (const r of PATH_RULES) {
      if (r.re.test(e.path) && !(r.allow && r.allow.test(e.path)) && !allowed(r.id, e.path)) {
        findings.push(`${e.path}: [${r.id}] ${r.why}`);
      }
    }
  }

  const blobs = await readBlobs(entries.map((e) => e.sha));
  for (const e of entries) {
    const data = blobs.get(e.sha);
    if (!data || data.subarray(0, 8000).includes(0)) continue; // binary
    const text = data.toString("utf8");
    for (const r of CONTENT_RULES) {
      if (r.re.test(text) && !allowed(r.id, e.path)) findings.push(`${e.path}: [${r.id}] ${r.why}`);
    }
    if (hasEncodedSimplefin(text) && !allowed("simplefin-token", e.path)) {
      findings.push(`${e.path}: [simplefin-token] base64 SimpleFIN setup token`);
    }
  }

  if (findings.length) {
    console.error("check-secrets: blocked. These files look like secrets or personal data:");
    for (const f of findings) console.error(`  ${f}`);
    console.error("Unstage them. If one is a reviewed false positive, add `<rule-id> <path>` to .secrets-guard-allow.");
    process.exitCode = 1;
  } else {
    console.log(`check-secrets: ${entries.length} file(s) clean (${mode}).`);
  }
}

const mode = process.argv[2] ?? "--staged";
if (!["--staged", "--all"].includes(mode)) {
  console.error(`check-secrets: unknown mode ${mode} (use --staged or --all)`);
  process.exitCode = 2;
} else {
  main().catch((err) => {
    console.error(`check-secrets: failed: ${err.stack ?? err}`);
    process.exitCode = 2;
  });
}
