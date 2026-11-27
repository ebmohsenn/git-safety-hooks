#!/usr/bin/env node
/**
 * secret-scan — refuses a commit whose STAGED additions carry a secret. It names the file:line and the
 * secret's NAME or kind, never the value.
 *
 * Once a secret is pushed, only rotation undoes it. This stops the paste before it becomes history.
 *
 * WHAT IT CHECKS (only the lines this commit ADDS: `git diff --cached -U0`, which honours GIT_INDEX_FILE):
 *   1. LIVE VALUES. Every secret-looking value in your local .env file(s) (>= 12 characters, not a plain word,
 *      number, path or e-mail; a URL only when it carries credentials or is a webhook-style URL with a token in
 *      it; plus the password inside each credentialed URL) is compared by SHA-256 against every token of every
 *      added line. A value that contains quotes, brackets, commas or spaces can never be one token, so those
 *      are also looked for as plain substrings. Values are held in memory only and never printed or written.
 *   2. KEY SHAPES. AWS access key, private-key PEM block, GitHub / GitLab / npm / Hugging Face token,
 *      Anthropic / OpenRouter / OpenAI key, Google API key, Google OAuth client secret, Slack token, Telegram
 *      bot token, Stripe live key and webhook secret, SendGrid key, a database URL or an http(s) URL with a
 *      password, a generated-looking value assigned to a secret-named key, plus any patterns you configure.
 *   3. FILE NAMES. `.env`, `.env.<anything>`, `<anything>.env`, `.envrc`, `.netrc`, `*.pem`, `*.key`, `*.p12`,
 *      `*.pfx`, `*.jks`, `*.keystore`, `*.tfstate`, `id_rsa`/`id_dsa`/`id_ed25519`/`id_ecdsa`,
 *      `keystore.properties`, `google-service-account*.json`, `*credentials*.json` — but not templates
 *      (`.env.example|sample|template|dist|defaults`, `example.env`). `secretScan.allowName` exempts a path
 *      from this name check only; its contents are still scanned.
 * Placeholders (example, your-, xxxx, changeme, a run of one character …) are not secrets.
 *
 * HOW THE DIFF IS READ. Every file is diffed as text (`--text`), so a `-diff` / `binary` attribute cannot hide
 * a text file; prefixes and path quoting are pinned on the command line, so the user's `diff.noprefix`,
 * `diff.mnemonicPrefix` or `core.quotePath` cannot change what the parser sees; and the diff is streamed, so
 * its size is not a limit. A file whose added lines contain a NUL byte is treated as binary data: only its
 * first megabyte is scanned. UTF-16 text therefore counts as binary and its contents are NOT matched.
 *
 * ALLOW.
 *   - One line: put `secret-scan: allow <why>` on that line or the line above.
 *   - The whole commit: SECRET_SCAN_ALLOW="<why>" git commit …   (printed, then allowed)
 * It fails CLOSED: if the scan cannot run (git fails, an internal error), the commit is refused, because
 * "could not scan" must not look the same as "scanned and clean". SECRET_SCAN_ALLOW_ON_ERROR=1 is the way past
 * that one case. A configured pattern that is not a valid regex, or that runs away, is dropped with a
 * warning and the rest of the scan goes on.
 *
 * ENV (the pre-commit hook fills these from .git-safety.conf):
 *   SECRET_SCAN_ENV_FILES      newline- or colon-separated .env paths whose values are guarded (default: .env)
 *   SECRET_SCAN_EXTRA_PATTERNS newline-separated JavaScript regex sources, each reported as "custom pattern"
 *   SECRET_SCAN_IGNORE_PATHS   newline-separated JavaScript regex sources; matching paths are not scanned
 *   SECRET_SCAN_ALLOW_NAMES    newline-separated JavaScript regex sources; matching paths skip the name check
 *
 *   node secret-scan.mjs     exit 1 = blocked or could not run, 0 = clean / allowed
 */
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const sha = (s) => createHash('sha256').update(s).digest('hex')

const SECRET_NAME = /SECRET|PASSWORD|PASSWD|PASSPHRASE|PASS$|_PASS_|(?:^|_)PWD(?:_|$)|TOKEN|KEY|PRIVATE|DSN|DATABASE_URL|REDIS_URL|WEBHOOK|CREDENTIAL|AUTH|SALT|SIGNING|COOKIE/i
/** Shipped to every browser or published on purpose: a public / site key, an id, a fingerprint. A site
 *  verification code is public; a `*_VERIFICATION_SECRET` / `_TOKEN` / `_KEY` is not. */
const PUBLIC_NAME = /^VITE_|^NEXT_PUBLIC_|^REACT_APP_|PUBLIC|SITE_?KEY|CLIENT_ID|_ID$|FINGERPRINT|MEASUREMENT|SITE_VERIFICATION|VERIFICATION(?!_(?:SECRET|TOKEN|KEY|PASSWORD))|_KEY_ID$|_KEY_PATH$|_FILE$/i

const mixedCase = (v) => /[A-Z]/.test(v) && /[a-z]/.test(v) && /\d/.test(v)
const classes = (v) => [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((rx) => rx.test(v)).length
/** A URL path / query segment that looks like a token rather than a word (a webhook secret, not «services»). */
const tokenish = (s) => s.length >= 16 && [/[a-z]/, /[A-Z]/, /\d/].filter((rx) => rx.test(s)).length >= 2

/** A value that begins like a path IS a path unless it looks generated: a base64 secret starts with «/» one
 *  time in 64. Generated-looking is upper + lower + digit, with no plain lowercase word among its segments. */
function looksLikePath(v) {
  if (!/^[./~]/.test(v)) return false
  if (!mixedCase(v)) return true
  const parts = v.split('/')
  return parts.length - 1 >= 2 && parts.some((s) => /^[a-z]{3,}$/.test(s))
}

/** The value of one `NAME=value` line: quotes removed, an inline «# comment» dropped. Unquoted values are
 *  returned both with and without the comment tail, since «#» can also be part of a password. */
function envValues(rest) {
  const v = rest.trim()
  const quoted = v.match(/^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/) || v.match(/^'([^']*)'\s*(?:#.*)?$/)
  if (quoted) return [quoted[1]]
  const i = v.search(/\s#/)
  return i > 0 ? [v.slice(0, i).trim(), v] : [v]
}

/** Values from an .env text that are worth guarding, as [{name, value}] (first name wins per value). Pure. */
export function liveValues(envText) {
  const out = []
  const seen = new Set()
  const push = (name, value) => { if (!seen.has(value)) { seen.add(value); out.push({ name, value }) } }
  const add = (name, v) => {
    if (!v || v.length < 12) return
    if (/^[0-9.,:_-]+$/.test(v)) return                      // numbers, ports, dates
    if (/^(true|false|yes|no|on|off)$/i.test(v)) return
    if (/^[a-z][a-z_-]*$/i.test(v) && v.length < 24) return   // plain words: modes, model names
    if (/^https?:\/\//i.test(v) && !/@/.test(v)) {
      // A URL with no credentials is an address, not a secret — unless the secret is IN the URL, as in a
      // chat webhook: then the token-like segment is guarded, and so is the URL as a whole.
      if (!/WEBHOOK|HOOK|SECRET/i.test(name)) return
      const segs = v.replace(/^https?:\/\/[^/?#]*/i, '').split(/[/?#&=]/).filter(tokenish)
      if (!segs.length) return
      for (const s of segs) push(`${name} (the token in the URL)`, s)
      push(name, v)
      return
    }
    if (looksLikePath(v)) return                              // paths
    if (/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(v)) return        // an e-mail address is not a secret
    push(name, v)
  }
  for (const raw of String(envText || '').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const name = line.slice(0, eq).trim().replace(/^export\s+/, '')
    if (/^(?:OLD)?PWD$/i.test(name)) continue                  // the shell's working directory
    for (const v of envValues(line.slice(eq + 1))) {
      const m = v.match(/^[a-z][a-z0-9+.-]*:\/\/[^:/@\s]*:([^@\s]+)@/i)
      if (!m && (!SECRET_NAME.test(name) || PUBLIC_NAME.test(name))) continue
      add(name, v)
      // the password inside a credentialed URL is a secret on its own
      if (m) { try { add(`${name} (password)`, decodeURIComponent(m[1])) } catch { add(`${name} (password)`, m[1]) } }
    }
  }
  return out
}

/** The same values as Map(hash → NAME), for the token comparison. Pure. */
export function liveValueHashes(envText) {
  const out = new Map()
  for (const { name, value } of liveValues(envText)) if (!out.has(sha(value))) out.set(sha(value), name)
  return out
}

/** Characters `tokens()` splits on. A live value containing one can never equal a token, so it is searched
 *  for as a substring instead. */
const TOKEN_DELIMITER = /[\s'"`,;(){}[\]<>|\\]/

const PLACEHOLDER = /example|your[-_]|<[a-z_ -]+>|x{4,}|\*{3,}|changeme|placeholder|dummy|fake|redacted|sample|not-a-(?:live-)?secret|harness|fixture|0123456789|deadbeef|\$\{|\$\(|process\.env|import\.meta\.env|getenv|environ\[/i
/** The random part (the longest alphanumeric run) uses fewer than 8 distinct characters — a fixture like
 *  'sk-ant-api03-0000…' or 'AKIA0000…', not a key. */
const lowVariety = (s) => {
  const runs = String(s).match(/[A-Za-z0-9]+/g) || ['']
  const longest = runs.reduce((a, b) => (b.length > a.length ? b : a), '')
  return new Set(longest).size < 8
}
/** A value assigned to a secret-named key looks generated: 32+ hex; or upper, lower AND digits (a path or a
 *  word list does not); or a 16+ character run that mixes two of those — «a8f3k2j5…», which kebab-case words
 *  with a version number («my-api-key-header-v2») never have. */
const looksGenerated = (v) => {
  if (/^[0-9a-fA-F]{32,}$/.test(v)) return true
  if (/\/[a-z-]+\//.test(v)) return false
  if (mixedCase(v)) return true
  return v.split(/[-_/+=]/).some((seg) => seg.length >= 16 && classes(seg) >= 2)
}
/** Passwords that documentation and local setups use: the scheme's own name, «password», «secret», «test…». */
const WEAK_PASSWORD = /^(?:pass(?:word)?|pw|passw0rd|my-secret-pw|test\w*|(?:my|the|your|some|db|dev|local|test|root|admin|postgres|mysql|redis|mongo|rabbit|user|guest|demo|docker|super)?[-_]?(?:secret|pass(?:word|wd)?|pw|postgres|mysql|mariadb|redis|mongo(?:db)?|rabbit(?:mq)?|root|admin|user|guest|demo|docker)[-_]?(?:secret|pass(?:word)?|pw|user|db|dev|local|test)?\d{0,4}|\$\w+|%\w+%|:\w+)$/i
const LOCAL_HOST = /^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[?::1\]?|host\.docker\.internal)$/i
/** Names that end a lower/camel-case identifier which only MENTIONS a secret: `tokenCount`, `passwordHash`. */
const NOT_THE_SECRET = /hash|digest|checksum|fingerprint|public|sha\d*$|commit|rev(?:ision)?$|(?:^|_)id$|[a-z]Id$|name$|url$|uri$|path$|file$|type$|length$|count$|expir|ttl$|header$|prefix$|suffix$|field$|param$|placeholder|label$|regex|pattern|format$|version$|limit$|size$|budget|usage$|symbol$/i

/** Every quantifier is bounded, so no rule can go quadratic on a hostile or merely huge line. */
export const SHAPES = [
  { kind: 'aws-access-key', rx: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { kind: 'private-key-block', rx: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY( BLOCK)?-----/ },
  { kind: 'github-token', rx: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,255}\b|\bgithub_pat_[A-Za-z0-9_]{60,255}/ },
  { kind: 'gitlab-token', rx: /\bglpat-[A-Za-z0-9_-]{20,255}/ },
  { kind: 'anthropic-key', rx: /\bsk-ant-(?:api|admin|oat)\d{2}-[A-Za-z0-9_-]{20,400}/ },
  { kind: 'openrouter-key', rx: /\bsk-or-v1-[a-f0-9]{40,128}/ },
  { kind: 'openai-key', rx: /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{30,400}|\bsk-[A-Za-z0-9]{48}\b/ },
  { kind: 'google-api-key', rx: /\bAIza[0-9A-Za-z_-]{35}(?![\w-])/ },
  { kind: 'google-oauth-client-secret', rx: /\bGOCSPX-[A-Za-z0-9_-]{20,100}/ },
  { kind: 'slack-token', rx: /\bxox[baprs]-[A-Za-z0-9-]{10,255}|\bxapp-\d-[A-Za-z0-9-]{20,255}/ },
  { kind: 'telegram-bot-token', rx: /\b\d{8,10}:AA[A-Za-z0-9_-]{33}(?![\w-])/ },
  { kind: 'stripe-live-key', rx: /\b(?:sk|rk)_live_[A-Za-z0-9]{20,255}|\bwhsec_[A-Za-z0-9]{24,255}/ },
  { kind: 'sendgrid-key', rx: /\bSG\.[A-Za-z0-9_-]{16,32}\.[A-Za-z0-9_-]{16,64}/ },
  { kind: 'huggingface-token', rx: /\bhf_[A-Za-z0-9]{30,80}\b/ },
  { kind: 'npm-token', rx: /\bnpm_[A-Za-z0-9]{36}\b|:_(?:authToken|auth|password)\s{0,4}=\s{0,4}["']?(?!\$\{)[A-Za-z0-9+/=_-]{16,400}/ },
  { kind: 'db-url-with-password', rx: /\b(?:postgres(?:ql)?|mysql|mariadb|rediss?|mongodb(?:\+srv)?|amqps?)(?:\+[a-z0-9]{1,20})?:\/\/[^:/@\s'"`]{0,100}:([^@\s'"`$<>{}]{6,200})@([^\s/:'"`?#,;)]{0,255})/, value: 1, host: 2 },
  { kind: 'url-with-password', rx: /\bhttps?:\/\/[^\s:/@'"`]{1,100}:([^@\s'"`$<>{}/]{8,200})@([^\s/:'"`?#,;)]{1,255})/, value: 1, host: 2 },
  { kind: 'secret-assigned-hex-or-base64', rx: /\b([A-Za-z0-9_]{0,60}(?:secret|password|passwd|passphrase|token|api_?key|private_?key|enc(?:ryption)?_?key|signing_?key|access_?key|auth_?key)[A-Za-z0-9_]{0,60})["']?\s{0,8}[:=]\s{0,8}["'`]?([0-9a-fA-F]{32,4096}|[A-Za-z0-9+/_-]{40,4096}={0,2})(?![A-Za-z0-9+/_=-])/i, name: 1, value: 2 },
]

/** Is this shape match a real finding? (Placeholders, fixtures and documentation passwords are not.) */
function shapeHit(s, m) {
  const frag = s.value ? m[s.value] : m[0]
  if (PLACEHOLDER.test(m[0])) return false
  if (s.kind === 'db-url-with-password' || s.kind === 'url-with-password') {
    // judged on the WHOLE password: «Kx7-Qm2-Zt9» has no long run, and is still a password
    if (WEAK_PASSWORD.test(frag) || new Set(frag).size < 4) return false
    if (LOCAL_HOST.test(m[s.host] || '') && frag.length < 12) return false     // a throwaway local database
    if (s.kind === 'url-with-password' && (classes(frag) < 2 || new Set(frag).size < 6)) return false
    return true
  }
  if (s.kind !== 'private-key-block' && lowVariety(frag)) return false
  if (s.kind === 'secret-assigned-hex-or-base64') {
    if (!looksGenerated(frag)) return false
    const name = m[s.name]
    if (name !== name.toUpperCase() && NOT_THE_SECRET.test(name)) return false   // tokenCount, passwordHash …
  }
  return true
}

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

const BAD_NAME = /(^|\/)\.env(\.[^/]*)?$|(^|\/)[^/]+\.env$|(^|\/)\.envrc$|(^|\/)[._]netrc$|\.(pem|key|p12|pfx|jks|keystore)$|\.tfstate(\.backup)?$|(^|\/)id_(rsa|dsa|ed25519|ecdsa)$|(^|\/)keystore\.properties$|google-service-account[^/]*\.json$|credentials[^/]*\.json$/i
/** Templates: they hold names and placeholders, and their contents are scanned like any other file. */
const OK_NAME = /(^|\/)\.env(\.[^/]*)?\.(example|sample|template|tmpl|dist|defaults)$|(^|\/)(example|sample|template)\.env$/i

/** Undo git's C-style quoting of a path («"a\tb"», «"caf\303\251"»). An unquoted path is returned as is. */
export function unquotePath(s) {
  if (s.length < 2 || s[0] !== '"' || s[s.length - 1] !== '"') return s
  const body = s.slice(1, -1)
  const ESC = { a: 7, b: 8, f: 12, n: 10, r: 13, t: 9, v: 11 }
  const parts = []
  let i = 0
  let start = 0
  while (i < body.length) {
    if (body[i] !== '\\') { i++; continue }
    if (i > start) parts.push(Buffer.from(body.slice(start, i)))
    const oct = body.slice(i + 1, i + 4)
    if (/^[0-7]{3}$/.test(oct)) { parts.push(Buffer.from([parseInt(oct, 8)])); i += 4 }
    else { const c = body[i + 1] ?? ''; parts.push(c in ESC ? Buffer.from([ESC[c]]) : Buffer.from(c)); i += 2 }
    start = i
  }
  if (start < body.length) parts.push(Buffer.from(body.slice(start)))
  return Buffer.concat(parts).toString('utf8')
}

/** The path in «diff --git a/<p> b/<p>» (the text after «diff --git »). Both sides are the same path unless
 *  the file was renamed or copied — then «rename to» / «+++» supply the name, and this is only a fallback. */
function headPath(rest) {
  if (rest.endsWith('"')) {
    const i = rest.lastIndexOf(' "b/')
    if (i >= 0) return unquotePath(rest.slice(i + 1)).slice(2)
  }
  const len = (rest.length - 5) / 2
  if (Number.isInteger(len) && len > 0 && rest.startsWith('a/') && rest.slice(2 + len, 5 + len) === ' b/' && rest.slice(2, 2 + len) === rest.slice(5 + len)) return rest.slice(5 + len)
  const i = rest.lastIndexOf(' b/')
  return i >= 0 ? rest.slice(i + 3) : null
}

/** Run a configured regex over many strings with a time limit: a pattern such as `(a+)+$` would otherwise hang
 *  every commit. Returns the indexes that match; throws when the limit is hit. */
const RX_LOOP = new vm.Script('(() => { const hit = []; for (let i = 0; i < texts.length; i++) { rx.lastIndex = 0; if (rx.test(texts[i])) hit.push(i) } return hit })()')
const RX_CONTEXT = vm.createContext({ rx: null, texts: [] })
function guardedMatches(rx, texts, ms) {
  RX_CONTEXT.rx = rx
  RX_CONTEXT.texts = texts
  try { return Array.from(RX_LOOP.runInContext(RX_CONTEXT, { timeout: ms })) } finally { RX_CONTEXT.texts = [] }
}

const BINARY_CAP = 1024 * 1024      // bytes scanned of a file whose added lines contain NUL
const CUSTOM_BATCH = 2000           // added lines handed to the custom patterns at a time
const PATTERN_TIME_MS = 1500        // per pattern, per batch

/**
 * A streaming scanner for a unified diff (-U0, prefixes a/ and b/). Feed it the diff one line at a time with
 * `line(raw)`, then call `end()` for the findings [{file, line, what}]. `what` is a NAME or a kind, never the
 * value. opts: `extra` [RegExp] reported as custom patterns · `ignore` [RegExp] of paths not scanned ·
 * `allowName` [RegExp] of paths exempt from the file-name check · `raw` [{name, value}] live values searched
 * as substrings · `warn(msg)`.
 */
export function createScanner(hashes = new Map(), opts = {}) {
  const extra = [...(opts.extra || [])]
  const ignore = [...(opts.ignore || [])]
  const allowName = opts.allowName || []
  const rawValues = opts.raw || []
  const warn = opts.warn || (() => {})
  const stats = { files: 0, ignored: 0, binary: 0 }
  const findings = []
  let pending = []                  // added lines no built-in layer flagged, waiting for the custom patterns
  let seq = 0
  let st = null                     // the file being read
  let inHeader = false
  let lineNo = 0
  let prevAdded = ''
  let lastWasAdded = false

  const matchesAny = (list, name) => {
    for (let i = list.length - 1; i >= 0; i--) {
      try { if (guardedMatches(list[i], [name], PATTERN_TIME_MS).length) return true } catch {
        warn(`pattern /${list[i].source}/ took too long on a path and was dropped for this run`)
        list.splice(i, 1)
      }
    }
    return false
  }

  /** Decide, once per file and before any of its lines, what the file is called and whether it is scanned. */
  const settle = () => {
    if (!st || st.settled) return
    st.settled = true
    stats.files++
    const name = st.renameTo ?? st.plus ?? st.head
    // An unparsable name is no reason to skip the contents: scan, and say where as well as we can.
    st.name = name || '(a path the scanner could not read)'
    if (st.deleted) { st.skip = true; return }
    if (name && matchesAny(ignore, name)) { st.skip = true; stats.ignored++; return }
    // checked here, not on a content line: an empty file, a pure rename or a mode change has none
    if (name && BAD_NAME.test(name) && !OK_NAME.test(name) && !matchesAny(allowName, name)) findings.push({ seq: seq++, file: name, line: 0, what: 'a secrets file by its name' })
  }

  const flushCustom = () => {
    const batch = pending
    pending = []
    if (!batch.length || !extra.length) return
    const texts = batch.map((b) => b.text)
    const claimed = new Set()
    for (let i = 0; i < extra.length; i++) {
      const rx = extra[i]
      let hits
      try { hits = guardedMatches(rx, texts, PATTERN_TIME_MS) } catch {
        warn(`custom pattern /${rx.source}/ took too long and was dropped for this run — fix or remove it`)
        extra.splice(i--, 1)
        continue
      }
      for (const h of hits) {
        if (claimed.has(h)) continue
        claimed.add(h)
        findings.push({ seq: batch[h].seq, file: batch[h].file, line: batch[h].line, what: `custom pattern /${rx.source}/` })
      }
    }
  }

  const scanAdded = (line, here) => {
    const file = st.name
    const allowed = /secret-scan:\s*allow/i.test(line) || /secret-scan:\s*allow/i.test(prevAdded)
    prevAdded = line
    if (allowed) return
    if (!st.binary && line.includes('\0')) { st.binary = true; stats.binary++ }
    if (st.binary && st.bytes > BINARY_CAP) return
    st.bytes += line.length
    // 1. live values: by hash, token by token …
    if (hashes.size) {
      for (const t of tokens(line)) {
        const name = hashes.get(sha(t))
        if (name) { findings.push({ seq: seq++, file, line: here, what: `${name} (a value from your local env file)` }); return }
      }
    }
    // … and, for a value no token can equal (it contains a quote, a bracket, a comma, a space), as a substring
    for (const r of rawValues) {
      if (line.includes(r.value)) { findings.push({ seq: seq++, file, line: here, what: `${r.name} (a value from your local env file)` }); return }
    }
    // 2. key shapes
    for (const s of SHAPES) {
      const m = line.match(s.rx)
      if (!m || !shapeHit(s, m)) continue
      findings.push({ seq: seq++, file, line: here, what: `${s.kind} pattern` })
      return
    }
    // 3. custom patterns: batched, so each one runs under a time limit
    if (extra.length) {
      pending.push({ seq: seq++, file, line: here, text: line })
      if (pending.length >= CUSTOM_BATCH) flushCustom()
    }
  }

  /** `continued` = this is a later window of an overlong line (see streamLines), not a new diff line. */
  const line = (raw, continued = false) => {
    if (continued) {
      if (lastWasAdded && st && !st.skip) scanAdded(raw, Math.max(lineNo - 1, 0))
      return
    }
    lastWasAdded = false
    if (raw.startsWith('diff --git ')) {
      settle()
      st = { head: headPath(raw.slice(11)), bytes: 0 }
      inHeader = true
      return
    }
    if (!st) return
    if (inHeader) {
      // Only here can «--- » and «+++ » be file headers. After the first hunk they are content: an ADDED
      // line whose own text starts with «++ » must not be mistaken for the next file.
      if (!raw.startsWith('@@ ')) {
        if (raw.startsWith('rename to ')) st.renameTo = unquotePath(raw.slice(10))
        else if (raw.startsWith('copy to ')) st.renameTo = unquotePath(raw.slice(8))
        else if (raw.startsWith('+++ ')) {
          const p = unquotePath(raw.slice(4).replace(/\t$/, ''))   // git adds a TAB after a name with spaces
          if (p === '/dev/null') st.deleted = true
          else st.plus = p.startsWith('b/') ? p.slice(2) : p
        }
        return
      }
      settle()
      inHeader = false
    }
    if (raw.startsWith('@@ ')) {
      const hunk = raw.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
      if (hunk) { lineNo = Number(hunk[1]); prevAdded = '' }
      return
    }
    if (st.skip || raw[0] !== '+') return
    lastWasAdded = true
    scanAdded(raw.slice(1), lineNo++)
  }

  const end = () => {
    settle()
    flushCustom()
    const seen = new Set()
    return findings
      .sort((a, b) => a.seq - b.seq)
      .filter((f) => { const k = `${f.file}\0${f.line}\0${f.what}`; if (seen.has(k)) return false; seen.add(k); return true })
      .map(({ file, line: l, what }) => ({ file, line: l, what }))
  }

  return { line, end, stats }
}

/** Pure: a whole diff as text → findings. See createScanner for `opts`. */
export function scanDiff(diffText, hashes = new Map(), opts = {}) {
  const scanner = createScanner(hashes, opts)
  for (const raw of String(diffText || '').split('\n')) scanner.line(raw)
  return scanner.end()
}

const MAX_LINE = 1024 * 1024        // a longer line is scanned in windows of this size …
const OVERLAP = 4096                // … that overlap by this much, so a secret on a boundary is seen whole

/** Run git and hand its output to `onLine(text, continued)` line by line, in bounded memory. */
async function streamLines(args, onLine) {
  const child = spawn('git', args, { stdio: ['ignore', 'pipe', 'pipe'] })
  let stderr = ''
  child.stderr.on('data', (d) => { if (stderr.length < 4000) stderr += d })
  const closed = new Promise((resolve, reject) => {
    child.on('error', reject)
    child.on('close', (code, signal) => resolve({ code, signal }))
  })
  closed.catch(() => {})            // awaited below; this only keeps an early failure from being "unhandled"
  let parts = []                    // the unfinished line, as chunks
  let size = 0
  let continued = false
  const emit = (buf) => { onLine(buf.toString('utf8'), continued) }
  try {
    for await (const chunk of child.stdout) {
      let from = 0
      for (;;) {
        const nl = chunk.indexOf(10, from)
        if (nl === -1) break
        const piece = chunk.subarray(from, nl)
        if (size) { parts.push(piece); emit(Buffer.concat(parts)); parts = []; size = 0 } else emit(piece)
        continued = false
        from = nl + 1
      }
      if (from < chunk.length) { parts.push(chunk.subarray(from)); size += chunk.length - from }
      while (size > MAX_LINE) {
        const all = Buffer.concat(parts)
        emit(all.subarray(0, MAX_LINE))
        continued = true
        const rest = all.subarray(MAX_LINE - OVERLAP)
        parts = [rest]
        size = rest.length
      }
    }
    if (size) emit(Buffer.concat(parts))
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill()
  }
  const { code, signal } = await closed
  if (code !== 0) throw new Error(`git ${args.find((a) => !a.startsWith('-') && !a.includes('=')) || ''} failed (${signal || `exit ${code}`}): ${stderr.trim().split('\n')[0] || 'no message'}`)
}

const list = (v) => String(v || '').split(/[\n:]/).map((s) => s.trim()).filter(Boolean)
const lines = (v) => String(v || '').split('\n').map((s) => s.trim()).filter(Boolean)
/** Paths no sane ignore pattern matches all of: one that does has switched the scan off. */
const PROBE_PATHS = ['a', 'README.md', 'src/index.ts', '.env', 'config/settings.json', 'Makefile']

async function main() {
  if (process.env.SECRET_SCAN_ALLOW) {
    console.log(`⚠️  secret scan skipped — SECRET_SCAN_ALLOW="${process.env.SECRET_SCAN_ALLOW}"`)
    return 0
  }
  const warn = (msg) => console.log(`⚠️  secret scan: ${msg}`)
  let root = process.cwd()
  try { root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() } catch { /* not a repo: cwd */ }
  const envFiles = process.env.SECRET_SCAN_ENV_FILES !== undefined ? list(process.env.SECRET_SCAN_ENV_FILES) : ['.env']
  const hashes = new Map()
  const raw = []
  for (const f of envFiles) {
    let text
    try { text = fs.readFileSync(path.resolve(root, f), 'utf8') } catch { continue /* not readable here: shapes only */ }
    for (const v of liveValues(text)) {
      if (!hashes.has(sha(v.value))) hashes.set(sha(v.value), v.name)
      if (TOKEN_DELIMITER.test(v.value) && !raw.some((r) => r.value === v.value)) raw.push(v)
    }
  }
  // One bad pattern must not switch the whole scan off: drop it, say so, and scan with the rest.
  const compile = (key, env) => lines(process.env[env]).map((src) => {
    if (src.includes('\b')) warn(`${key} /${src.replace(/\x08/g, '\\b')}/ contains a backspace character — in .git-safety.conf write \\\\b, not \\b`)
    try { return new RegExp(src) } catch (err) {
      warn(`ignoring ${key} /${src}/ — not a valid regex (${String(err?.message || err).slice(0, 80)})`)
      return null
    }
  }).filter(Boolean)
  const extra = compile('secretScan.pattern', 'SECRET_SCAN_EXTRA_PATTERNS')
  const ignore = compile('secretScan.ignorePath', 'SECRET_SCAN_IGNORE_PATHS')
  const allowName = compile('secretScan.allowName', 'SECRET_SCAN_ALLOW_NAMES')
  for (const rx of ignore) {
    let all = false
    try { all = guardedMatches(rx, PROBE_PATHS, PATTERN_TIME_MS).length === PROBE_PATHS.length } catch { /* reported when used */ }
    if (all) warn(`secretScan.ignorePath /${rx.source}/ matches every path — nothing in this commit is being scanned`)
  }

  const scanner = createScanner(hashes, { extra, ignore, allowName, raw, warn })
  // Pinned on the command line so the user's git config cannot change what is parsed:
  //   core.quotepath=off  a non-ASCII path arrives as itself, not as "caf\303\251.ts"
  //   --src/--dst-prefix  diff.noprefix / diff.mnemonicPrefix would rename or drop «a/» and «b/»
  //   --text              a `-diff` or `binary` attribute would otherwise hide the file's added lines
  //   --no-textconv       scan the bytes being committed, and run no conversion program
  //   ACMRT               T = a type change (a symlink replaced by a regular file)
  await streamLines(['-c', 'core.quotepath=off', 'diff', '--cached', '-U0', '--no-color', '--no-ext-diff', '--no-textconv', '--text',
    '--src-prefix=a/', '--dst-prefix=b/', '--diff-filter=ACMRT'], scanner.line)
  const findings = scanner.end()
  if (scanner.stats.ignored) console.log(`ℹ️  secret scan: ${scanner.stats.ignored} staged file(s) not scanned (secretScan.ignorePath)`)
  if (!findings.length) return 0
  console.log('✖ commit blocked: this commit adds what looks like a secret (the value is not shown):')
  for (const f of findings.slice(0, 30)) console.log(`     ${f.file}${f.line ? `:${f.line}` : ''}  ${f.what}`)
  if (findings.length > 30) console.log(`     … and ${findings.length - 30} more`)
  console.log('   A secret in a commit stays in history; only rotation undoes it. Read it from the environment instead.')
  console.log('   A fixture that must look real: add «secret-scan: allow <why>» on that line or the line above.')
  if (findings.some((f) => !f.line)) console.log('   A file refused by its name that is safe to commit: secretScan.allowName = <regex of its path>.')
  console.log('   Deliberate (e.g. a scanner\'s own tests): SECRET_SCAN_ALLOW="<why>" git commit …')
  return 1
}

/** True when this file is the script node was asked to run (robust to spaces and symlinks in the path). */
function isMain() {
  try { return fs.realpathSync(fileURLToPath(import.meta.url)) === fs.realpathSync(process.argv[1] || '') } catch { return false }
}

if (isMain()) {
  main().then((code) => { process.exitCode = code }, (err) => {
    const why = String(err?.message || err).split('\n')[0].slice(0, 200)
    if (process.env.SECRET_SCAN_ALLOW_ON_ERROR === '1') {
      console.log(`⚠️  secret scan could not run (${why}) — NOT scanned, allowed by SECRET_SCAN_ALLOW_ON_ERROR=1`)
      process.exitCode = 0
      return
    }
    console.log(`✖ commit blocked: the secret scan could not run (${why}).`)
    console.log('   Nothing was scanned, so the commit is refused rather than passed unchecked.')
    console.log('   To commit without the scan this once: SECRET_SCAN_ALLOW_ON_ERROR=1 git commit …')
    process.exitCode = 1
  })
}
