#!/usr/bin/env node
/**
 * stale-revert-guard — refuses a commit that silently UNDOES a recent commit.
 *
 * THE FAILURE IT CATCHES. Several people or AI agents work on one repository. One of them builds
 * a commit from a STALE copy of a file (an editor buffer opened an hour ago, a file copied from
 * another worktree, an agent that rewrote the whole file from its own memory of it). The staged
 * file is byte-for-byte the old version plus their change, so it reverts whatever landed in that
 * file since — and nothing says so. Each commit looks fine on its own; the damage is only visible
 * against history.
 *
 * THE SIGNATURE (what keeps it near-zero false-positive). For every staged file, compare the lines
 * the staged diff REMOVES / ADDS against what each recent commit C (last WINDOW hours, on the base
 * commit's history, touching that file) ADDED / REMOVED in that file:
 *   - "reverted adds":    >= RATIO of C's added (non-trivial) lines in the file are removed here;
 *   - "restored removes": >= RATIO of C's removed lines in the file are added back here.
 * A normal refactor, a rewrite or an edit that reshapes a recent change fails the RATIO test — it
 * keeps or rewrites part of what C added. Only an inverse of C's whole hunks passes.
 *   STRONG hit — C both added AND removed lines in the file (>= MIN_LINES added), and the staged
 *                diff is the inverse of both sides. One such file blocks.
 *   WEAK hit   — C only ADDED lines in the file (>= MIN_LINES) and the staged diff removes them all.
 *                Alone that is also what a deliberate deletion looks like, so it blocks only when the
 *                SAME commit C is reverted this way in >= 2 staged files (a feature's code AND its
 *                test vanishing together is a stale base, not a cleanup).
 *   SMALL hit  — C only ADDED a few lines (< MIN_LINES), C landed in the last SMALL_WINDOW minutes,
 *                and the staged diff removes them all. Counts toward the same >= 2 files.
 * It never fires on: new files, additions only, edits to lines nobody added recently, a merge /
 * cherry-pick / revert in progress, or any internal error (it fails OPEN).
 *
 * OVERRIDE. ACK_REVERT="<sha or reason>" git commit …   (printed, then allowed)
 *
 * ENV (the pre-commit hook fills the tunables from .git-safety.conf):
 *   STALE_GUARD_WINDOW_HOURS        default 48
 *   STALE_GUARD_RATIO               default 0.9
 *   STALE_GUARD_MIN_LINES           default 5
 *   STALE_GUARD_SMALL_WINDOW_MIN    default 30
 *   STALE_GUARD_SKIP_PATHS          newline-separated regex sources of paths never examined
 *   STALE_GUARD_BASE                commit the index is compared against (default HEAD; replays)
 *   STALE_GUARD_NOW                 epoch seconds treated as "now" (default the real clock; replays)
 *
 *   node stale-revert-guard.mjs        exit 1 = blocked, 0 = ok / not applicable / internal error
 */
import { execFileSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const num = (v, d) => (v !== undefined && v !== '' && Number.isFinite(Number(v)) ? Number(v) : d);

export const DEFAULTS = Object.freeze({
  windowSeconds: 48 * 3600,
  ratio: 0.9,
  minLines: 5,
  smallWindowSeconds: 30 * 60,
});
const MAX_CANDIDATE_FILES = 200;
const MAX_LOG_COMMITS = 400;
const SKIP_PATH = /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|go\.sum|dist\/|build\/|node_modules\/|vendor\/)|\.(lock|snap|min\.js|min\.css|map|svg|png|jpe?g|gif|webp|pdf|woff2?)$/;

/** A line that carries no identity: braces, blanks, one-token punctuation. Never evidence. */
export function isTrivial(line) {
  const t = line.trim();
  if (t.length < 6) return true;
  return !/[\p{L}\p{N}]{3,}/u.test(t);
}

/**
 * Parse a `-U0 --no-renames` patch stream into [{commit, time, subject, files: Map(path → {added, removed})}].
 * `\x01C <sha> <epoch> <subject>` marker lines (from --format) start a new commit; a plain diff is one
 * anonymous block.
 */
export function parsePatchStream(text) {
  const blocks = [];
  let cur = null;
  let file = null;
  let inHeader = false;
  for (const raw of text.split('\n')) {
    if (raw.startsWith('\x01C ')) {
      const [, sha, ts, ...subject] = raw.slice(1).split(' ');
      cur = { commit: sha, time: Number(ts), subject: subject.join(' '), files: new Map() };
      blocks.push(cur);
      file = null;
      inHeader = false;
      continue;
    }
    if (!cur) {
      cur = { commit: null, time: 0, subject: '', files: new Map() };
      blocks.push(cur);
    }
    if (raw.startsWith('diff --git ')) {
      file = null;
      inHeader = true;
      continue;
    }
    if (inHeader) {
      if (raw.startsWith('--- ')) {
        const p = raw.slice(4);
        if (p !== '/dev/null') file = p.replace(/^a\//, '');
        continue;
      }
      if (raw.startsWith('+++ ')) {
        const p = raw.slice(4);
        if (p !== '/dev/null') file = p.replace(/^b\//, '');
        if (file && !cur.files.has(file)) cur.files.set(file, { added: [], removed: [] });
        continue;
      }
      if (raw.startsWith('@@')) inHeader = false;
      else continue;
    }
    if (!file) continue;
    const rec = cur.files.get(file) ?? cur.files.set(file, { added: [], removed: [] }).get(file);
    if (raw.startsWith('+')) rec.added.push(raw.slice(1));
    else if (raw.startsWith('-')) rec.removed.push(raw.slice(1));
  }
  return blocks;
}

function multiset(lines) {
  const m = new Map();
  for (const l of lines) {
    if (isTrivial(l)) continue;
    const k = l.trim();
    m.set(k, (m.get(k) ?? 0) + 1);
  }
  return m;
}
const size = (m) => [...m.values()].reduce((a, b) => a + b, 0);
function overlap(a, b) {
  let n = 0;
  for (const [k, c] of a) n += Math.min(c, b.get(k) ?? 0);
  return n;
}

/**
 * Pure decision. `staged`: Map(path → {added, removed}) of the staged diff vs the base;
 * `recent`: parsed log blocks (newest first) — each {commit, time, subject, files}.
 * `now`: epoch seconds, for the small-hit window. `opts`: overrides of DEFAULTS.
 * Returns [{commit, subject, strong: [...], weak: [...]}] for every commit the staged diff reverts.
 */
export function findReverts(staged, recent, now = Math.floor(Date.now() / 1000), opts = {}) {
  const { ratio, minLines, smallWindowSeconds } = { ...DEFAULTS, ...opts };
  const stagedSets = new Map();
  for (const [path, d] of staged) {
    stagedSets.set(path, { added: multiset(d.added), removed: multiset(d.removed) });
  }
  const verdicts = [];
  for (const c of recent) {
    const strong = [];
    const weak = [];
    for (const [path, d] of c.files) {
      const s = stagedSets.get(path);
      if (!s) continue;
      const addC = multiset(d.added);
      const remC = multiset(d.removed);
      const nAdd = size(addC);
      const nRem = size(remC);
      if (nAdd === 0) continue;
      const rev = overlap(addC, s.removed);
      if (rev < Math.ceil(ratio * nAdd)) continue;
      if (nRem > 0) {
        const rest = overlap(remC, s.added);
        if (nAdd >= minLines && rest >= Math.ceil(ratio * nRem)) strong.push({ path, nAdd, nRem, rev, rest });
      } else if (nAdd >= minLines || now - c.time <= smallWindowSeconds) {
        weak.push({ path, nAdd, rev });
      }
    }
    if (strong.length > 0 || strong.length + weak.length >= 2) {
      verdicts.push({ commit: c.commit, subject: c.subject, strong, weak });
    }
  }
  return verdicts;
}

function git(args, opts = {}) {
  return execFileSync('git', ['-c', 'core.quotepath=off', ...args], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
    ...opts,
  });
}

function main() {
  const ack = process.env.ACK_REVERT;
  if (ack && ack.trim()) {
    console.log(`⚠️  stale-revert guard skipped — ACK_REVERT="${ack}"`);
    return 0;
  }
  const opts = {
    windowSeconds: num(process.env.STALE_GUARD_WINDOW_HOURS, DEFAULTS.windowSeconds / 3600) * 3600,
    ratio: num(process.env.STALE_GUARD_RATIO, DEFAULTS.ratio),
    minLines: num(process.env.STALE_GUARD_MIN_LINES, DEFAULTS.minLines),
    smallWindowSeconds: num(process.env.STALE_GUARD_SMALL_WINDOW_MIN, DEFAULTS.smallWindowSeconds / 60) * 60,
  };
  const skipExtra = String(process.env.STALE_GUARD_SKIP_PATHS || '').split('\n').map((s) => s.trim()).filter(Boolean).map((s) => new RegExp(s));

  const gitPath = (p) => git(['rev-parse', '--git-path', p]).trim();
  // Only these markers: a leftover rebase-merge/ directory holding just `autostash` can linger
  // for good and would otherwise disable the guard permanently.
  for (const marker of ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD']) {
    if (existsSync(gitPath(marker))) return 0;
  }
  const base = process.env.STALE_GUARD_BASE || 'HEAD';
  try {
    git(['rev-parse', '--verify', '--quiet', `${base}^{commit}`]);
  } catch {
    return 0; // first commit: nothing to revert
  }
  const now = num(process.env.STALE_GUARD_NOW, 0) || Math.floor(Date.now() / 1000);

  const diffText = git(['diff', '--cached', '--no-color', '--no-ext-diff', '--no-renames', '-U0', '--diff-filter=MD', base]);
  if (!diffText) return 0;
  const staged = new Map();
  for (const [path, d] of parsePatchStream(diffText)[0]?.files ?? []) {
    if (SKIP_PATH.test(path) || skipExtra.some((rx) => rx.test(path))) continue;
    if (size(multiset(d.removed)) >= 1) staged.set(path, d);
  }
  if (staged.size === 0 || staged.size > MAX_CANDIDATE_FILES) return 0;

  const since = new Date((now - opts.windowSeconds) * 1000).toISOString();
  const logText = git([
    'log', base, `--since=${since}`, '--no-merges', '--no-color', '--no-ext-diff', '--no-renames', '-U0',
    `--max-count=${MAX_LOG_COMMITS}`, '--format=%x01C %H %ct %s', '--', ...staged.keys(),
  ]);
  const recent = parsePatchStream(logText).filter((b) => b.commit && b.time >= now - opts.windowSeconds);
  const verdicts = findReverts(staged, recent, now, opts);
  if (verdicts.length === 0) return 0;

  console.log('');
  console.log('✖ commit blocked: this commit looks like it UNDOES a recent commit (stale copy of a file?).');
  for (const v of verdicts) {
    console.log(`   ${v.commit.slice(0, 9)}  ${v.subject.slice(0, 100)}`);
    for (const f of v.strong) console.log(`     ${f.path}: its ${f.nAdd} added line(s) are removed and its ${f.nRem} removed line(s) are back`);
    for (const f of v.weak) console.log(`     ${f.path}: its ${f.nAdd} added line(s) are all removed`);
  }
  console.log('');
  console.log('   Cause: the staged file was built from an older copy of the file, so it silently drops what');
  console.log('   landed since. Fix: start from HEAD (`git show HEAD:<path>`), re-apply only YOUR hunks, restage.');
  console.log('   If removing that change IS the intent (a deliberate revert):');
  console.log('     ACK_REVERT="<sha it reverts, or the reason>" git commit …');
  return 1;
}

function isMain() {
  try { return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1] || ''); } catch { return false; }
}

if (isMain()) {
  let code = 0;
  try {
    code = main();
  } catch (e) {
    console.log(`⚠️  stale-revert guard errored and was skipped: ${String(e?.message ?? e).split('\n')[0]}`);
  }
  process.exit(code);
}
