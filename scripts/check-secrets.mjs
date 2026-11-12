#!/usr/bin/env node
// Blocks commits that would publish secrets or personal financial data.
// Ballast is a public repo that handles bank data, so this runs as a git
// pre-commit / pre-merge-commit hook (.githooks/) and in CI (secrets-guard.yml).
//
//   node scripts/check-secrets.mjs --staged         files in the index (hook mode)
//   node scripts/check-secrets.mjs --all            every tracked file (CI mode)
//   node scripts/check-secrets.mjs --range A..B     every file version added or
//       modified by each commit in A..B, so a secret committed and then deleted
//       in a later commit is still caught (CI mode; history stays public).
//   node scripts/check-secrets.mjs --range REV      the same for every commit
//       reachable from REV (CI mode when a push or PR has no usable base).
//
// Reviewed false positives go in .secrets-guard-allow, one per line:
//   <rule-id> <path-glob>
// Exit codes: 0 clean, 1 findings, 2 the check itself failed.

import { execFileSync, spawn } from "node:child_process";
import { gunzipSync, constants as zlibConstants } from "node:zlib";

const ARCHIVE_WHY = "compressed file or archive: the content rules can't read inside it";

// Path rules: files that must never be committed, whatever they contain.
const PATH_RULES = [
  { id: "env-file", re: /(^|\/)\.env(rc|\.[^/]*)?$/i, allow: /\.(example|erb)$/i,
    why: "environment file (holds credentials)" },
  { id: "db-dump", re: /\.(sql|dump|pgdump|backup|bak|sqlite3?|db)(\.(gz|zst|bz2|xz|zip))?$/i,
    why: "database dump or database file" },
  { id: "archive", re: /\.(gz|tgz|zip|7z|bz2|tbz2?|xz|txz|zst|tzst|rar|tar|lz|lz4|lzma|z|cab|cpio)$/i,
    why: ARCHIVE_WHY },
  { id: "db-dump", re: /(^|\/)dump\.rdb$/i, why: "Redis dump" },
  { id: "bank-export", re: /\.(ofx|qfx|qif|qbo)$/i, why: "bank export file" },
  { id: "bank-export", re: /\.(csv|tsv|pdf|xlsx?)$/i, allow: /^test\/fixtures\//,
    why: "CSV, TSV, PDF or spreadsheet outside test/fixtures (bank statements are personal data)" },
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
  { id: "private-key", why: "private key block", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----(\r?\n|\\n)[A-Za-z0-9+\/]{40,}/ },
  { id: "secret-key-base", why: "Rails SECRET_KEY_BASE value",
    re: /SECRET_KEY_BASE\s*[=:]\s*["']?[0-9a-f]{64,}/i },
  { id: "aws-key", why: "AWS access key id", re: /\b(AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { id: "github-token", why: "GitHub token", re: /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b/ },
  { id: "anthropic-key", why: "Anthropic API key", re: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { id: "openai-key", why: "OpenAI API key", re: /\bsk-(proj|svcacct|admin)-[A-Za-z0-9_-]{32,}|\bsk-[A-Za-z0-9]{32,}\b/ },
];

// Compressed or archive data, recognised by its first bytes whatever the file
// is called (a gzip renamed .txt, a zip spreadsheet such as .ods).
function archiveMagic(buf) {
  const starts = (...bytes) => bytes.every((b, i) => buf[i] === b);
  if (starts(0x1f, 0x8b)) return "gzip";
  if (starts(0x50, 0x4b) && [0x0304, 0x0506, 0x0708].includes((buf[2] << 8) | buf[3])) return "zip";
  if (starts(0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c)) return "7z";
  if (starts(0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00)) return "xz";
  if (starts(0x28, 0xb5, 0x2f, 0xfd)) return "zstd";
  if (starts(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07)) return "rar";
  if (starts(0x42, 0x5a, 0x68) && buf[3] >= 0x31 && buf[3] <= 0x39
      && /^(1AY&SY|\x17rE8P\x90)$/.test(buf.subarray(4, 10).toString("latin1"))) return "bzip2";
  if (/^ustar(\0| {2}\0)/.test(buf.subarray(257, 265).toString("latin1"))) return "tar";
  return null;
}

// Content hits for a text, including text hidden in base64: SimpleFIN setup
// tokens are base64 of a claim URL, and a whole file (a CSV, an .env, a
// gzip of either) can be pasted in as base64. Runs wrapped over several lines
// (`base64` wraps at 76; JSON strings carry literal \n) are joined first.
// The run can start mid-token (`path=/tmp/<token>`, `x+<token>`), so decode
// from each of the 4 alignments. Node's base64 decoder also takes base64url.
const B64_RUN = /[A-Za-z0-9+/_-]{40,}={0,2}(?:(?:\r?\n|(?:\\r)?\\n)[ \t]*[A-Za-z0-9+/_-]{4,}={0,2})*/g;
const B64_BREAKS = /\r|\n|\\r|\\n|[ \t]/g;
// A pasted gzip is unpacked to scan it; this caps a decompression bomb.
const GUNZIP_MAX = 64 << 20;
function contentHits(text, depth = 0) {
  const hits = new Map();
  for (const r of CONTENT_RULES) if (r.re.test(text)) hits.set(r.id, r);
  for (const m of text.matchAll(B64_RUN)) {
    const run = m[0].replace(B64_BREAKS, "");
    for (let off = 0; off < 4; off++) {
      const bytes = Buffer.from(run.slice(off), "base64");
      const decoded = bytes.toString("latin1");
      if (/simplefin/i.test(decoded)) hits.set("simplefin-token", { id: "simplefin-token", why: "base64 SimpleFIN setup token or URL" });
      for (const r of CONTENT_RULES) if (r.re.test(decoded)) hits.set(r.id, { id: r.id, why: `${r.why}, base64-encoded` });
      const kind = archiveMagic(bytes);
      if (!kind) continue;
      const archiveHit = { id: "archive", why: `base64-encoded ${kind} data, a ${ARCHIVE_WHY}` };
      if (kind !== "gzip") { hits.set("archive", archiveHit); continue; }
      // gzip's 2-byte magic turns up by chance in long random base64 (hashes),
      // so a gzip counts only when it unpacks. Text inside is scanned; binary
      // inside, or a third level of nesting, is blocked unread.
      let inner;
      try {
        inner = gunzipSync(bytes, { finishFlush: zlibConstants.Z_SYNC_FLUSH, maxOutputLength: GUNZIP_MAX });
      } catch (err) {
        if (err.code === "ERR_BUFFER_TOO_LARGE") hits.set("archive", archiveHit);
        continue; // otherwise not gzip data, just a chance match of the magic bytes
      }
      const innerText = depth < 2 ? decodeText(inner) : null;
      if (innerText === null) { hits.set("archive", archiveHit); continue; }
      for (const h of contentHits(innerText, depth + 1).values()) {
        hits.set(h.id, { id: h.id, why: `${h.why}, inside base64 gzip` });
      }
    }
  }
  return hits;
}

// Text as a string, or null for binary. Windows PowerShell 5.1 writes UTF-16
// with `>` and Out-File; those files contain NUL bytes but are still text.
function decodeText(buf) {
  if (buf[0] === 0xff && buf[1] === 0xfe) return buf.subarray(2).toString("utf16le");
  if (buf[0] === 0xfe && buf[1] === 0xff) {
    const b = buf.subarray(2, 2 + ((buf.length - 2) & ~1));
    return Buffer.from(b).swap16().toString("utf16le");
  }
  const head = buf.subarray(0, 8000);
  if (!head.includes(0)) return buf.toString("utf8");
  // BOM-less UTF-16: NULs sit in every other byte.
  let evenNul = 0, oddNul = 0;
  for (let i = 0; i < head.length; i++) if (head[i] === 0) (i % 2 ? oddNul++ : evenNul++);
  const half = head.length / 2;
  if (oddNul > half * 0.9 && evenNul === 0) return buf.toString("utf16le");
  if (evenNul > half * 0.9 && oddNul === 0) {
    const even = buf.length - (buf.length % 2);
    return Buffer.from(buf.subarray(0, even)).swap16().toString("utf16le");
  }
  return null;
}

// `*` = within one folder, `**` = any depth; a leading `**/` (or `/**/`) also
// matches zero folders, so `**/name` covers a root-level `name`.
function globToRe(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/^\*\*\//, "\u0001").replace(/\/\*\*\//g, "/\u0001")
    .replace(/\*\*/g, "\0").replace(/\*/g, "[^/]*").replace(/\0/g, ".*").replace(/\?/g, "[^/]")
    .replace(/\u0001/g, "(?:.*/)?");
  return new RegExp(`^${esc}$`);
}

// Read the allowlist from the index, like the scanned files, so an unstaged
// exemption can't let a staged secret through.
function loadAllowlist() {
  let text;
  try {
    text = execFileSync("git", ["show", ":.secrets-guard-allow"], { stdio: ["ignore", "pipe", "ignore"] }).toString();
  } catch {
    return []; // not in the index
  }
  return text.split(/\r?\n/)
    .map((l) => l.replace(/#.*/, "").trim()).filter(Boolean)
    .map((l) => {
      const [rule, glob] = l.split(/\s+/);
      if (!rule || !glob) throw new Error(`bad .secrets-guard-allow line: ${l}`);
      // A glob made only of wildcards and slashes turns the rule off everywhere.
      if (/^[*?/]+$/.test(glob)) {
        throw new Error(`.secrets-guard-allow line "${l}" names no file: a pattern made only of *, ** , ? and / would switch the ${rule} rule off for every path. Name the reviewed file or folder.`);
      }
      return { rule, re: globToRe(glob) };
    });
}

function git(args) {
  return execFileSync("git", args, { maxBuffer: 1 << 30 }).toString();
}

// { sha, path, commit? } for each file version to scan.
function listIndexEntries() {
  // mode, sha, stage, path for every file in the index (or staged changes only).
  let entries = git(["ls-files", "-s", "-z"]).split("\0").filter(Boolean).map((line) => {
    const tab = line.indexOf("\t");
    const [fmode, sha] = line.slice(0, tab).split(" ");
    return { fmode, sha, path: line.slice(tab + 1) };
  }).filter((e) => e.fmode !== "160000"); // skip submodules
  if (mode === "--staged") {
    const changed = new Set(git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"])
      .split("\0").filter(Boolean));
    entries = entries.filter((e) => changed.has(e.path));
  }
  return entries;
}

// Every blob a commit in the range added or modified. Merges use the combined
// diff (-c): only paths whose result differs from every parent, i.e. what the
// merge itself introduced; the parents' own changes come from their commits.
function listRangeEntries(range) {
  const commits = git(["rev-list", "--end-of-options", range]);
  const out = execFileSync("git",
    ["diff-tree", "--stdin", "-z", "-r", "-c", "--root", "--no-renames", "--no-abbrev"],
    { input: commits, maxBuffer: 1 << 30 }).toString();
  const seen = new Set();
  const entries = [];
  let commit = null;
  const tokens = out.split("\0");
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i].trim();
    if (!t) continue;
    if (!t.startsWith(":")) { commit = t; continue; }
    const path = tokens[++i];
    const parents = t.match(/^:+/)[0].length;
    const fields = t.slice(parents).split(" ");
    const fmode = fields[parents];
    const sha = fields[2 * parents + 1];
    if (!/^[0-9a-f]{40,64}$/.test(sha ?? "")) throw new Error(`git diff-tree: unexpected line ${t}`);
    if (/^0+$/.test(sha) || fmode === "160000") continue; // deleted, or a submodule
    const key = `${sha}\0${path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push({ sha, path, commit });
  }
  return { entries, commitCount: commits.split("\n").filter(Boolean).length };
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
      try {
        while (pos < buf.length) {
          const nl = buf.indexOf(10, pos);
          const header = buf.subarray(pos, nl === -1 ? buf.length : nl).toString();
          const [sha, , size] = header.split(" ");
          // A missing object prints "<sha> missing" with no size; stop rather
          // than skip every file after it and report clean.
          if (nl === -1 || !/^\d+$/.test(size ?? "")) throw new Error(`git cat-file: cannot read object: ${header}`);
          const len = Number(size);
          blobs.set(sha, buf.subarray(nl + 1, nl + 1 + len));
          pos = nl + 1 + len + 1;
        }
        for (const sha of shas) if (!blobs.has(sha)) throw new Error(`git cat-file: no content returned for ${sha}`);
      } catch (err) {
        return reject(err);
      }
      resolve(blobs);
    });
    proc.stdin.end(shas.join("\n") + "\n");
  });
}

async function main() {
  const allow = loadAllowlist();
  const allowed = (rule, path) => allow.some((a) => a.rule === rule && a.re.test(path));
  let entries, label = mode;
  if (mode === "--range") {
    const r = listRangeEntries(rangeArg);
    entries = r.entries;
    label = `--range ${rangeArg}, ${r.commitCount} commit(s)`;
  } else {
    entries = listIndexEntries();
  }
  const where = (e) => (e.commit ? `${e.commit.slice(0, 12)} ${e.path}` : e.path);
  const findings = new Set();

  for (const e of entries) {
    for (const r of PATH_RULES) {
      if (r.re.test(e.path) && !(r.allow && r.allow.test(e.path)) && !allowed(r.id, e.path)) {
        findings.add(`${where(e)}: [${r.id}] ${r.why}`);
      }
    }
  }

  // Content hits per blob, computed once; batches bound memory on long ranges.
  const hitsBySha = new Map();
  const shas = [...new Set(entries.map((e) => e.sha))];
  for (let i = 0; i < shas.length; i += 2000) {
    const batch = shas.slice(i, i + 2000);
    const blobs = await readBlobs(batch);
    for (const sha of batch) {
      const buf = blobs.get(sha);
      const kind = archiveMagic(buf);
      if (kind) { hitsBySha.set(sha, [{ id: "archive", why: `${kind} data, a ${ARCHIVE_WHY}` }]); continue; }
      const text = decodeText(buf);
      if (text === null) { hitsBySha.set(sha, []); continue; } // other binary (images, fonts)
      hitsBySha.set(sha, [...contentHits(text).values()]);
    }
  }
  for (const e of entries) {
    for (const r of hitsBySha.get(e.sha)) {
      if (!allowed(r.id, e.path)) findings.add(`${where(e)}: [${r.id}] ${r.why}`);
    }
  }

  if (findings.size) {
    console.error("check-secrets: blocked. These files look like secrets or personal data:");
    for (const f of findings) console.error(`  ${f}`);
    console.error("Unstage them. If one is a reviewed false positive, add `<rule-id> <path>` to .secrets-guard-allow.");
    if (mode === "--range") {
      console.error("A file in an earlier commit stays public after it is deleted: rewrite that history before pushing.");
    }
    process.exitCode = 1;
  } else {
    console.log(`check-secrets: ${entries.length} file(s) clean (${label}).`);
  }
}

const mode = process.argv[2] ?? "--staged";
const rangeArg = process.argv[3];
const extra = process.argv.slice(mode === "--range" ? 4 : 3);
if (!["--staged", "--all", "--range"].includes(mode) || extra.length
    || (mode === "--range" && (!rangeArg || rangeArg.startsWith("-")))) {
  console.error(`check-secrets: bad arguments ${process.argv.slice(2).join(" ")} (use --staged, --all, --range A..B or --range REV)`);
  process.exitCode = 2;
} else {
  main().catch((err) => {
    console.error(`check-secrets: failed: ${err.stack ?? err}`);
    process.exitCode = 2;
  });
}
