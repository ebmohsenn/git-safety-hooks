#!/usr/bin/env node
/**
 * secret-scan — refuses a commit whose STAGED additions carry a secret. It names the file:line and the
 * secret's NAME or kind, never the value.
 *
 * Once a secret is pushed, only rotation undoes it. This stops the paste before it becomes history.
 *
 * WHAT IT CHECKS (only the lines this commit ADDS: `git diff --cached -U0`, which honours GIT_INDEX_FILE):
 *   1. LIVE VALUES. Every secret-looking value in your local .env file(s) (>= 12 characters, not a plain word,
 *      number, path, e-mail or credential-free URL; plus the password inside each credentialed URL) is compared
 *      by SHA-256 against every token of every added line. The raw values are hashed once at start and never
 *      printed or written anywhere.
 *   2. KEY SHAPES. AWS access key, private-key PEM block, GitHub token, Anthropic / OpenRouter / OpenAI key,
 *      Google API key, Google OAuth client secret, Slack token, Telegram bot token, Stripe live key, a database
 *      URL with a password, a 64-hex (or long base64) value assigned to a secret-named key, plus any extra
 *      patterns you configure.
 *   3. FILE NAMES. `.env*` (but not `.env.example|sample|template`), `*.pem`, `*.p12`, `*.pfx`, `*.jks`,
 *      `*.keystore`, `id_rsa`/`id_ed25519`/`id_ecdsa`, `keystore.properties`, `google-service-account*.json`,
 *      `*credentials*.json`.
 * Placeholders (example, your-, xxxx, changeme, a run of one character …) are not secrets.
 *
 * ALLOW.
 *   - One line: put `secret-scan: allow <why>` on that line or the line above.
 *   - The whole commit: SECRET_SCAN_ALLOW="<why>" git commit …   (printed, then allowed)
 * It fails OPEN on its own internal errors, so a broken scanner never blocks work.
 *
 * ENV (the pre-commit hook fills these from .git-safety.conf):
 *   SECRET_SCAN_ENV_FILES      newline- or colon-separated .env paths whose values are guarded (default: .env)
 *   SECRET_SCAN_EXTRA_PATTERNS newline-separated JavaScript regex sources, each reported as "custom pattern"
 *   SECRET_SCAN_IGNORE_PATHS   newline-separated JavaScript regex sources; matching paths are not scanned
 *   SECRET_SCAN_DIFF_FILE      read the diff from this file instead of git (tests)
 *
 *   node secret-scan.mjs     exit 1 = blocked, 0 = clean / allowed / internal error
 */
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const sha = (s) => createHash('sha256').update(s).digest('hex')

const SECRET_NAME = /SECRET|PASSWORD|PASSWD|PASS$|_PASS_|TOKEN|KEY|PRIVATE|DSN|DATABASE_URL|REDIS_URL|WEBHOOK|CREDENTIAL|AUTH|SALT|SIGNING|COOKIE/i
/** Shipped to every browser or published on purpose: a public / site key, an id, a fingerprint. */
const PUBLIC_NAME = /^VITE_|^NEXT_PUBLIC_|^REACT_APP_|PUBLIC|SITE_?KEY|CLIENT_ID|_ID$|FINGERPRINT|MEASUREMENT|VERIFICATION|_KEY_ID$|_KEY_PATH$|_FILE$/i

/** Values from an .env text that are worth guarding, as Map(hash → NAME). Pure. */
export function liveValueHashes(envText) {
  const out = new Map()
  const add = (name, v) => {
    if (!v || v.length < 12) return
    if (/^[0-9.,:_-]+$/.test(v)) return                      // numbers, ports, dates
    if (/^(true|false|yes|no|on|off)$/i.test(v)) return
    if (/^[a-z][a-z_-]*$/i.test(v) && v.length < 24) return   // plain words: modes, model names
    if (/^https?:\/\//i.test(v) && !/@/.test(v)) return       // a URL with no credentials
    if (/^[./~]/.test(v)) return                             // paths
    if (/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(v)) return        // an e-mail address is not a secret
    if (!out.has(sha(v))) out.set(sha(v), name)
  }
  for (const raw of String(envText || '').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const name = line.slice(0, eq).trim().replace(/^export\s+/, '')
    let v = line.slice(eq + 1).trim()
    if (v.length >= 2 && (v[0] === '"' || v[0] === "'") && v[v.length - 1] === v[0]) v = v.slice(1, -1)
    const m = v.match(/^[a-z][a-z0-9+.-]*:\/\/[^:/@\s]*:([^@\s]+)@/i)
    if (!m && (!SECRET_NAME.test(name) || PUBLIC_NAME.test(name))) continue
    add(name, v)
    // the password inside a credentialed URL is a secret on its own
    if (m) { try { add(`${name} (password)`, decodeURIComponent(m[1])) } catch { add(`${name} (password)`, m[1]) } }
  }
  return out
}

const PLACEHOLDER = /example|your[-_]|<[a-z_ -]+>|x{4,}|\*{3,}|changeme|placeholder|dummy|fake|redacted|sample|not-a-(?:live-)?secret|harness|fixture|0123456789|deadbeef|\$\{|\$\(|process\.env|import\.meta\.env|getenv|environ\[/i
/** The random part (the longest alphanumeric run) uses fewer than 8 distinct characters — a fixture like
 *  'sk-ant-api03-0000…' or 'AKIA0000…', not a key. */
const lowVariety = (s) => {
  const runs = String(s).match(/[A-Za-z0-9]+/g) || ['']
  const longest = runs.reduce((a, b) => (b.length > a.length ? b : a), '')
  return new Set(longest).size < 8
}
/** A value assigned to a secret-named key looks generated: 64+ hex, or base64 with upper, lower AND digits (a path or
 *  a word list does not). */
const looksGenerated = (v) => /^[0-9a-fA-F]{64,}$/.test(v) || (/[A-Z]/.test(v) && /[a-z]/.test(v) && /\d/.test(v) && !/\/[a-z-]+\//.test(v))

export const SHAPES = [
  { kind: 'aws-access-key', rx: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { kind: 'private-key-block', rx: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY( BLOCK)?-----/ },
  { kind: 'github-token', rx: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{60,}/ },
  { kind: 'anthropic-key', rx: /\bsk-ant-(?:api|admin|oat)\d{2}-[A-Za-z0-9_-]{20,}/ },
  { kind: 'openrouter-key', rx: /\bsk-or-v1-[a-f0-9]{40,}/ },
  { kind: 'openai-key', rx: /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{30,}|\bsk-[A-Za-z0-9]{48}\b/ },
  { kind: 'google-api-key', rx: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  { kind: 'google-oauth-client-secret', rx: /\bGOCSPX-[A-Za-z0-9_-]{20,}/ },
  { kind: 'slack-token', rx: /\bxox[baprs]-[A-Za-z0-9-]{10,}/ },
  { kind: 'telegram-bot-token', rx: /\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b/ },
  { kind: 'stripe-live-key', rx: /\b(?:sk|rk)_live_[A-Za-z0-9]{20,}/ },
  { kind: 'db-url-with-password', rx: /\b(?:postgres(?:ql)?|mysql|rediss?|mongodb(?:\+srv)?|amqps?):\/\/[^:/@\s'"`]+:([^@\s'"`$<>{}]{6,})@/, value: 1 },
  { kind: 'secret-assigned-64hex-or-base64', rx: /\b[A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|ENC_KEY|SIGNING_KEY)[A-Z0-9_]*["']?\s*[:=]\s*["'`]?([0-9a-fA-F]{64,}|[A-Za-z0-9+/_-]{40,}={0,2})(?![A-Za-z0-9+/_-])/, value: 1 },
]

/** Each guardable token of a line: split on everything that cannot be inside a value; also the part after `=`/`:`. */
function tokens(line) {
  const out = new Set()
  for (const t of line.split(/[\s'"`,;(){}[\]<>|\\]+/)) {
    if (t.length < 12) continue
    out.add(t)
    const cut = t.replace(/[.:!?]+$/, '')
    if (cut.length >= 12) out.add(cut)
    for (const sep of ['=', ':']) {
      const i = t.indexOf(sep)
      if (i > 0 && t.length - i - 1 >= 12) out.add(t.slice(i + 1).replace(/[.:!?]+$/, ''))
    }
  }
  return out
}

const BAD_NAME = /(^|\/)\.env(\.[^/]*)?$|\.(pem|p12|pfx|jks|keystore)$|(^|\/)id_(rsa|ed25519|ecdsa)$|(^|\/)keystore\.properties$|google-service-account[^/]*\.json$|credentials[^/]*\.json$/i
const OK_NAME = /(^|\/)\.env\.(example|sample|template)$/i

/**
 * Pure: a unified diff (-U0) + live-value hashes → findings [{file, line, what}]. `what` is a NAME or a kind, never
 * the value. `opts.extra` = [RegExp] reported as custom patterns; `opts.ignore` = [RegExp] of paths to skip.
 */
export function scanDiff(diffText, hashes = new Map(), opts = {}) {
  const extra = opts.extra || []
  const ignore = opts.ignore || []
  const findings = []
  let file = null
  let lineNo = 0
  let prevAdded = ''
  for (const raw of String(diffText || '').split('\n')) {
    const head = raw.match(/^diff --git a\/.+ b\/(.+)$/)
    if (head) {
      // checked here, not at «+++»: a binary file (a keystore, a .p12) has no «+++» line
      file = null
      if (ignore.some((rx) => rx.test(head[1]))) continue
      if (BAD_NAME.test(head[1]) && !OK_NAME.test(head[1])) findings.push({ file: head[1], line: 0, what: 'a secrets file by its name' })
      continue
    }
    if (raw.startsWith('+++ ')) {
      file = raw.startsWith('+++ b/') ? raw.slice(6) : null
      if (file && ignore.some((rx) => rx.test(file))) file = null
      continue
    }
    const hunk = raw.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
    if (hunk) { lineNo = Number(hunk[1]); prevAdded = ''; continue }
    if (!file || !raw.startsWith('+') || raw.startsWith('+++')) continue
    const line = raw.slice(1)
    const here = lineNo++
    const allowed = /secret-scan:\s*allow/i.test(line) || /secret-scan:\s*allow/i.test(prevAdded)
    prevAdded = line
    if (allowed) continue
    // 1. live values, by hash
    let hit = false
    if (hashes.size) {
      for (const t of tokens(line)) {
        const name = hashes.get(sha(t))
        if (name) { findings.push({ file, line: here, what: `${name} (a value from your local env file)` }); hit = true; break }
      }
    }
    if (hit) continue
    // 2. key shapes
    for (const s of SHAPES) {
      const m = line.match(s.rx)
      if (!m) continue
      const frag = s.value ? m[s.value] : m[0]
      if (PLACEHOLDER.test(m[0]) || (s.kind !== 'private-key-block' && lowVariety(frag))) continue
      if (s.kind === 'secret-assigned-64hex-or-base64' && !looksGenerated(frag)) continue
      if (s.kind === 'db-url-with-password' && /^(pass(word)?|postgres|secret|test\w*|pw|\$\w+)$/i.test(frag)) continue
      findings.push({ file, line: here, what: `${s.kind} pattern` })
      hit = true
      break
    }
    if (hit) continue
    // 3. custom patterns
    for (const rx of extra) {
      if (rx.test(line)) { findings.push({ file, line: here, what: `custom pattern /${rx.source}/` }); break }
    }
  }
  return findings
}

const list = (v) => String(v || '').split(/[\n:]/).map((s) => s.trim()).filter(Boolean)
const lines = (v) => String(v || '').split('\n').map((s) => s.trim()).filter(Boolean)

function main() {
  if (process.env.SECRET_SCAN_ALLOW) {
    console.log(`⚠️  secret scan skipped — SECRET_SCAN_ALLOW="${process.env.SECRET_SCAN_ALLOW}"`)
    return 0
  }
  let diff
  if (process.env.SECRET_SCAN_DIFF_FILE) diff = fs.readFileSync(process.env.SECRET_SCAN_DIFF_FILE, 'utf8')
  else diff = execFileSync('git', ['diff', '--cached', '-U0', '--no-color', '--no-ext-diff', '--diff-filter=ACMR'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
  let root = process.cwd()
  try { root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() } catch { /* not a repo: cwd */ }
  const envFiles = process.env.SECRET_SCAN_ENV_FILES !== undefined ? list(process.env.SECRET_SCAN_ENV_FILES) : ['.env']
  const hashes = new Map()
  for (const f of envFiles) {
    try {
      for (const [h, n] of liveValueHashes(fs.readFileSync(path.resolve(root, f), 'utf8'))) if (!hashes.has(h)) hashes.set(h, n)
    } catch { /* not readable here: shapes only */ }
  }
  const extra = lines(process.env.SECRET_SCAN_EXTRA_PATTERNS).map((s) => new RegExp(s))
  const ignore = lines(process.env.SECRET_SCAN_IGNORE_PATHS).map((s) => new RegExp(s))
  const findings = scanDiff(diff, hashes, { extra, ignore })
  if (!findings.length) return 0
  console.log('✖ commit blocked: this commit adds what looks like a secret (the value is not shown):')
  for (const f of findings.slice(0, 30)) console.log(`     ${f.file}${f.line ? `:${f.line}` : ''}  ${f.what}`)
  if (findings.length > 30) console.log(`     … and ${findings.length - 30} more`)
  console.log('   A secret in a commit stays in history; only rotation undoes it. Read it from the environment instead.')
  console.log('   A fixture that must look real: add «secret-scan: allow <why>» on that line or the line above.')
  console.log('   Deliberate (e.g. a scanner\'s own tests): SECRET_SCAN_ALLOW="<why>" git commit …')
  return 1
}

/** True when this file is the script node was asked to run (robust to spaces and symlinks in the path). */
function isMain() {
  try { return fs.realpathSync(fileURLToPath(import.meta.url)) === fs.realpathSync(process.argv[1] || '') } catch { return false }
}

if (isMain()) {
  let code = 0
  try { code = main() } catch (err) { console.log(`⚠️  secret scan could not run (${String(err?.message || err).slice(0, 120)}) — not blocking`); code = 0 }
  process.exit(code)
}
