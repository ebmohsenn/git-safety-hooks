#!/usr/bin/env bash
# Proof for hooks/lib/secret-scan.mjs, both directions, in a throwaway repo — plus mutation tests
# showing that each detection layer is actually exercised by a case here.
# Every secret-shaped string below is ASSEMBLED AT RUN TIME from random bytes or split literals,
# so this file itself contains no secret-shaped string (and no real key, ever).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SCAN="$HOOKS/lib/secret-scan.mjs"
new_repo

rnd() { openssl rand -hex "$1"; }                       # lowercase hex
b64() { openssl rand -base64 "$1" | tr -d '\n=+/' | head -c "$2"; }

# a fake local .env: one plain secret, one credentialed URL, one public value, one e-mail — and the
# shapes a naive reader of .env files gets wrong (see "live values" below)
LIVE="$(b64 48 40)"; DBPASS="$(b64 24 19)7"
DELIM="pA5;w0rd,with(Sym)$(b64 12 8)"                 # contains ; , ( ) — never a single token
COMMENTED="$(b64 30 23)9"                             # followed by an inline comment in the file
HOOKTOKEN="$(b64 30 20)Zq7x"                          # the secret part of a webhook URL
HOOKURL="https://hooks.slack.com/services/T$(rnd 5)/B$(rnd 5)/$HOOKTOKEN"
SLASHED="/$(b64 36 26)Zq7x"                           # a base64 value that happens to start with «/»
PASSPHRASE="$(b64 30 20)a1B2"; PWD_VALUE="$(b64 24 16)c3D4"; VERIFY="$(b64 30 20)e5F6"
{
  printf 'MY_SERVICE_SECRET=%s\nDATABASE_URL=postgresql://app_rt:%s@localhost:5432/db\n' "$LIVE" "$DBPASS"
  printf 'VITE_SITE_KEY=%s\nADMIN_EMAIL=someone@example.org\n' "$(b64 48 40)"
  printf 'DB_PASSWORD="%s"\nAPI_SECRET=%s # the production key\nSLACK_WEBHOOK_URL=%s\n' "$DELIM" "$COMMENTED" "$HOOKURL"
  printf 'JWT_SECRET=%s\nSSH_PASSPHRASE=%s\nDB_PWD=%s\nEMAIL_VERIFICATION_SECRET=%s\n' "$SLASHED" "$PASSPHRASE" "$PWD_VALUE" "$VERIFY"
  printf 'AUTH_URL=https://login.internal.test/oauth2/authorize\nSSL_KEY=/etc/ssl/private/server.key\n'
} > "$T/fake.env"
export SECRET_SCAN_ENV_FILES="$T/fake.env"
SECRETS=("$LIVE" "$DBPASS" "$DELIM" "$COMMENTED" "$HOOKTOKEN" "$SLASHED" "$PASSPHRASE" "$PWD_VALUE" "$VERIFY")

# case_ <name> <expect 0|1> <file> <content> [ENV=VAL…] — leaves the scanner's output in $LAST
LAST=""
case_() {
  local name="$1" expect="$2" file="$3" content="$4"; shift 4
  git rm -rq --cached . >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$file")"; printf '%s\n' "$content" > "$file"; git add -f -- "$file"
  local out code v
  out="$(env "$@" node "$SCAN" 2>&1)"; code=$?
  if [ "$code" = "$expect" ]; then ok "$name"; else bad "$name: exit $code, expected $expect — $out"; fi
  for v in "${SECRETS[@]}"; do case "$out" in *"$v"*) bad "$name: printed a secret value";; esac; done
  LAST="$out"
  rm -f "$file"; git rm -rq --cached . >/dev/null 2>&1 || true
}
said()   { if grep -qF -- "$1" <<<"$LAST"; then ok "  says: $1"; else bad "  output lacks: $1 — $LAST"; fi; }
# with_cfg <git-config-key> <value> <case_ args…> — the same case under a git config setting
with_cfg() { local k="$1" v="$2"; shift 2; git config "$k" "$v"; case_ "$@"; git config --unset "$k"; }

case_ "clean code" 0 src/a.ts "export const x = process.env.MY_SERVICE_SECRET ?? ''"
case_ "live value pasted" 1 src/b.ts "const k = '$LIVE'"
case_ "live value after =" 1 scripts/c.sh "MY_SERVICE_SECRET=$LIVE"
case_ "the password inside the live DB URL, alone" 1 docs/d.md "the db password is $DBPASS now"
case_ "a public value is not a secret" 0 src/e.ts "const site = 'harmless'"
case_ "aws key" 1 f.txt "AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')"
case_ "aws documented example" 0 f2.txt "AKIA""IOSFODNN7EXAMPLE"
case_ "github token" 1 g.txt "token: gh""o_$(b64 60 36)"
case_ "anthropic key" 1 h.txt "sk-ant-""api03-$(b64 90 60)"
case_ "anthropic fixture of zeros" 0 h2.txt "sk-ant-""api03-$(printf '%060d' 0)"
case_ "google oauth secret" 1 i.txt "secret = 'GOC""SPX-$(b64 40 28)'"
case_ "google api key" 1 i2.txt "AI""za$(b64 60 35)"
case_ "pem private key" 1 j.pem.txt "-----BEGIN ""PRIVATE KEY-----"
case_ "db url with a real-looking password" 1 k.md "postgres://app_user:$(b64 24 18)@db.internal:5432/x"
case_ "db url with a placeholder password" 0 k2.md "postgres://user:password@localhost:5432/x"
case_ "64-hex next to a secret name" 1 l.mjs "const JWT_SECRET = '$(rnd 32)'"
case_ "a path assigned to a TOKEN-named const" 0 l2.ts "const TOKEN_LEDGER = 'test/helpers/pins/stream-ledger.json'"
case_ "allow marker on the line" 0 m.ts "const JWT_SECRET = '$(rnd 32)' // secret-scan: allow fixture for this proof"
case_ "allow marker on the line above" 0 m2.ts "// secret-scan: allow fixture for this proof
const JWT_SECRET = '$(rnd 32)'"
case_ "commit-wide allow" 0 n.ts "const k = '$LIVE'" SECRET_SCAN_ALLOW="proof"
case_ ".env by its name" 1 server/.env "X=1"
case_ ".env.example is fine" 0 .env.example "API_KEY=your-key-here"
case_ "keystore.properties by its name" 1 android/keystore.properties "storeFile=x"
case_ "custom pattern configured" 1 o.txt "id = acme_live_$(rnd 16)" SECRET_SCAN_EXTRA_PATTERNS='\bacme_live_[0-9a-f]{32}\b'
case_ "custom pattern not matching" 0 o2.txt "id = acme_test_$(rnd 16)" SECRET_SCAN_EXTRA_PATTERNS='\bacme_live_[0-9a-f]{32}\b'
case_ "ignored path is not scanned" 0 fixtures/p.txt "AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')" SECRET_SCAN_IGNORE_PATHS='^fixtures/'
case_ "no env file configured: shapes still work" 1 q.txt "token: gh""p_$(b64 60 36)" SECRET_SCAN_ENV_FILES=
case_ "no env file configured: live value is not known" 0 q2.ts "const k = '$LIVE'" SECRET_SCAN_ENV_FILES=

echo "— what the diff looks like must not matter —"
GH() { printf 'gh''p_%s' "$(b64 60 36)"; }
# git config that changes diff headers: the token used to pass with exit 0 and no output
with_cfg diff.mnemonicPrefix true "diff.mnemonicPrefix: token still found" 1 mp.ts "const t = '$(GH)'"
with_cfg diff.noprefix true "diff.noprefix: token still found" 1 np.ts "const t = '$(GH)'"
with_cfg diff.noprefix true "diff.noprefix: .env still refused by name" 1 np/.env "X=1"
said "np/.env"
# paths git would quote
case_ "non-ASCII file name: contents scanned" 1 'café.ts' "const t = '$(GH)'"
said "café.ts:1"
case_ "non-ASCII directory: .env refused by name" 1 'configuración/.env' "X=1"
case_ "a file name containing a double quote: contents scanned" 1 'a"b.ts' "const t = '$(GH)'"
case_ "a file name containing a space: contents scanned" 1 'my notes.md' "token $(GH)"
said "my notes.md:1"
with_cfg core.quotePath true "core.quotePath=true (explicit): non-ASCII name still scanned" 1 'naïve.ts' "const t = '$(GH)'"
# attributes that make git print «Binary files differ» instead of the added lines
printf '*.json -diff\n*.lock binary\n' > .gitattributes
case_ "a text file marked -diff in .gitattributes" 1 conf.json "{\"t\": \"$(GH)\"}"
case_ "a text file marked binary in .gitattributes" 1 deps.lock "token $(GH)"
rm -f .gitattributes
# a NUL byte makes git call the file binary; the first megabyte is scanned all the same
git rm -rq --cached . >/dev/null 2>&1 || true
{ printf 'const t = "%s"\n' "$(GH)"; printf '\0\n'; } > nul.ts; git add -f nul.ts
if node "$SCAN" >/dev/null 2>&1; then bad "a token in a file containing a NUL byte went through"; else ok "a file containing a NUL byte: start still scanned"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f nul.ts
# an added line that itself starts with «++ » is content, not the next file's header
case_ "a token on the line after an added «++ » line" 1 notes.md "++ heading
const t = '$(GH)'"
case_ "a token on a line that starts with «++»" 1 notes2.md "++$(GH)"
# one enormous line (a minified bundle): scanned in windows, the token is 2.5 MB in
git rm -rq --cached . >/dev/null 2>&1 || true
{ head -c 2500000 /dev/zero | tr '\0' 'a'; printf ' %s\n' "$(GH)"; } > bundle.min.js; git add -f bundle.min.js
if node "$SCAN" >/dev/null 2>&1; then bad "a token 2.5 MB into a single line went through"; else ok "a token 2.5 MB into a single line is found"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f bundle.min.js

echo "— key shapes —"
case_ "camelCase secret name, 64 hex" 1 s1.js "const jwtSecret = \"$(rnd 32)\""
case_ "JSON client_secret, base64" 1 s2.json "{ \"client_secret\": \"$(b64 60 40)Zq7x\" }"
case_ "YAML api_key, base64" 1 s3.yml "api_key: $(b64 60 40)Zq7x"
case_ "UPPERCASE name, 48 lowercase hex" 1 s4.sh "SESSION_SECRET=$(rnd 24)"
case_ "UPPERCASE name, lower+digit token without capitals" 1 s5.sh "DEPLOY_TOKEN=$(rnd 24 | tr 'a-f' 'g-l')$(rnd 12)"
case_ "redis URL with an empty username" 1 d1.sh "REDIS=redis://:$(b64 30 23)7@cache.internal:6379/0"
case_ "SQLAlchemy-style scheme" 1 d2.py "url = \"postgresql+psycopg2://app:$(b64 30 23)7@db.internal/prod\""
case_ "db password made of short dashed groups" 1 d3.py "url = \"postgres://app:$(b64 6 3)-$(b64 6 3)-$(b64 6 3)-$(b64 6 3)-$(b64 6 3)@db.internal/prod\""
case_ "db password of 7 characters, remote host" 1 d4.py "url = \"postgres://app:$(b64 12 5)q7@db.internal/prod\""
case_ "http(s) URL with a password" 1 d5.sh "git clone https://deploy:$(b64 30 20)Zq7x@git.internal/repo.git"
case_ "google api key ending in a dash" 1 g1.js "const k = \"AI""za$(b64 60 34)-\""
case_ "gitlab personal access token" 1 t1.txt "token = gl""pat-$(b64 30 20)"
case_ "npm token" 1 t2.txt "token = np""m_$(b64 60 36)"
case_ ".npmrc auth line (by content, not by name)" 1 .npmrc "//registry.internal.test/:_authToken=$(b64 60 40)"
case_ "slack app token" 1 t3.txt "xa""pp-1-A0$(rnd 4 | tr 'a-f' 'A-F')-$(rnd 6 | tr -d 'a-f')12345-$(rnd 32)"
case_ "stripe webhook secret" 1 t4.txt "wh""sec_$(b64 60 32)"
case_ "sendgrid key" 1 t5.txt "S""G.$(b64 30 22).$(b64 60 43)"
case_ "hugging face token" 1 t6.txt "h""f_$(b64 60 34)"
case_ "github token longer than 36 characters" 1 t7.txt "gh""p_$(b64 60 44)"
echo "— … and what must stay quiet —"
case_ "camelCase name that only mentions a secret (passwordHash)" 0 q1.js "const passwordHash = \"$(rnd 32)\""
case_ "a commit sha assigned to tokenSha" 0 q2.js "const tokenSha = \"$(rnd 20)\""
case_ "kebab-case words with a version number" 0 q3.js "const apiKeyHeader = \"x-my-company-custom-header-name-for-api-v2\""
case_ "lock-file integrity hash" 0 q4.json "\"integrity\": \"sha512-$(openssl rand -base64 64 | tr -d '\n')\""
case_ "a registry URL with a hash fragment" 0 q5.lock "resolved \"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz#$(rnd 20)\""
case_ "URL with the word password" 0 q6.md "curl https://user:password@host.internal/path"
case_ "URL whose password is a variable" 0 q7.sh "git clone https://deploy:\${DEPLOY_TOKEN}@git.internal/repo.git"
case_ "a throwaway local redis password" 0 q8.yml "url: redis://:devpass@localhost:6379/0"
case_ "the postgres image's documented password" 0 q9.yml "url: postgres://postgres:mysecretpassword@db:5432/app"
case_ "an ordinary .npmrc" 0 .npmrc "save-exact=true
registry=https://registry.internal.test/"
case_ ".npmrc reading its token from the environment" 0 .npmrc "//registry.internal.test/:_authToken=\${NPM_TOKEN}"
case_ "a secret-named key set to a placeholder" 0 q10.sh "API_TOKEN=your-api-token-goes-here-xxxxxxxxxxxxxxxxxxxxxxxx"

echo "— live values —"
case_ "a value containing ; , ( ) pasted into code" 1 v1.js "const p = \"$DELIM\""
said "DB_PASSWORD"
case_ "a value followed by an inline comment in .env" 1 v2.js "const p = '$COMMENTED'"
said "API_SECRET"
case_ "a webhook URL from .env" 1 v3.js "fetch('$HOOKURL')"
case_ "the token of that webhook URL, alone" 1 v4.js "const t = '$HOOKTOKEN'"
case_ "a base64 value that starts with a slash" 1 v5.js "const k = '$SLASHED'"
case_ "a *_PASSPHRASE value" 1 v6.js "const k = '$PASSPHRASE'"
case_ "a *_PWD value" 1 v7.js "const k = '$PWD_VALUE'"
case_ "a *_VERIFICATION_SECRET value" 1 v8.js "const k = '$VERIFY'"
case_ "a credential-free URL under an AUTH name is an address" 0 v9.js "const u = 'https://login.internal.test/oauth2/authorize'"
case_ "a real path under a KEY name is a path" 0 v10.js "const f = '/etc/ssl/private/server.key'"

echo "— file names —"
for n in .envrc prod.env config/.netrc tls/server.key terraform.tfstate keys/id_dsa; do
  case_ "$n refused by its name" 1 "$n" "x = 1"
done
for n in .env.dist .env.defaults .env.production.example example.env; do
  case_ "$n is a template" 0 "$n" "API_KEY=your-key-here"
done
case_ "a template is still scanned for real values" 1 .env.dist "API_TOKEN=$(b64 60 40)Zq7x"
case_ "secretScan.allowName lets a named file through" 0 .envrc "use flake" SECRET_SCAN_ALLOW_NAMES='(^|/)\.envrc$'
case_ "… but its contents are still scanned" 1 .envrc "export TOKEN=$(GH)" SECRET_SCAN_ALLOW_NAMES='(^|/)\.envrc$'
# a type change (a symlink in HEAD replaced by a regular file) is an addition like any other
git rm -rq --cached . >/dev/null 2>&1 || true
echo hi > target.txt; ln -s target.txt link.ts; git add -f target.txt link.ts; git commit -q --no-verify -m "a link"
rm link.ts; printf 'const t = "%s"\n' "$(GH)" > link.ts; git add -f link.ts
if node "$SCAN" >/dev/null 2>&1; then bad "a token in a symlink-turned-file went through"; else ok "a symlink replaced by a regular file is scanned"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f link.ts target.txt

echo "— settings that are wrong must not switch the scan off —"
AWSK="AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')"
case_ "an invalid regex in secretScan.pattern: the rest still scans" 1 e1.txt "k = $AWSK" SECRET_SCAN_EXTRA_PATTERNS='foo('
said "not a valid regex"
case_ "an invalid regex in secretScan.ignorePath: the rest still scans" 1 e2.txt "k = $AWSK" SECRET_SCAN_IGNORE_PATHS='src/['
case_ "a pattern whose \\b was eaten by git-config (a backspace) is called out" 0 e2b.txt "k = harmless" SECRET_SCAN_EXTRA_PATTERNS="$(printf '\bacme_[0-9a-f]{8}\b')"
said "backspace"
case_ "an ignorePath that matches everything is called out" 0 e3.txt "k = $AWSK" SECRET_SCAN_IGNORE_PATHS='.'
said "matches every path"
case_ "ignored files are counted in the output" 0 fixtures/e4.txt "k = $AWSK" SECRET_SCAN_IGNORE_PATHS='^fixtures/'
said "1 staged file(s) not scanned"
case_ "a runaway custom pattern is dropped, and the rest still scans" 1 e5.txt "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!
k = $AWSK" SECRET_SCAN_EXTRA_PATTERNS='(a+)+$'
said "took too long"
# the scan cannot run at all (git fails): refuse, never "not blocking"
out="$(GIT_DIR="$T/no-such-dir" node "$SCAN" 2>&1)"; code=$?
if [ "$code" = 1 ] && grep -q "could not run" <<<"$out"; then ok "scan cannot run → the commit is refused"; else bad "scan cannot run: exit $code — $out"; fi
out="$(GIT_DIR="$T/no-such-dir" SECRET_SCAN_ALLOW_ON_ERROR=1 node "$SCAN" 2>&1)"; code=$?
if [ "$code" = 0 ] && grep -q "SECRET_SCAN_ALLOW_ON_ERROR=1" <<<"$out"; then ok "SECRET_SCAN_ALLOW_ON_ERROR=1 → allowed, and said so"; else bad "allow-on-error: exit $code — $out"; fi
# a line built to make a careless regex quadratic (it took 28 s) is linear now
git rm -rq --cached . >/dev/null 2>&1 || true
node -e "process.stdout.write('postgres://a:'.repeat(40000) + '\n')" > hostile.txt; git add -f hostile.txt
start=$(now_ms); node "$SCAN" >/dev/null 2>&1; ms=$(( $(now_ms) - start ))
if [ "$ms" -lt 3000 ]; then ok "a 520 KB adversarial line scanned in ${ms} ms (< 3000)"; else bad "adversarial line took ${ms} ms (budget 3000)"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f hostile.txt
# opt-in (slow, ~300 MB of disk): a staged diff larger than the old 256 MB buffer used to be passed unscanned
if [ -n "${GSH_TEST_HUGE:-}" ]; then
  git rm -rq --cached . >/dev/null 2>&1 || true
  printf 'k = "%s"\n' "$AWSK" > key.txt
  yes "an ordinary line of text that is not a secret at all, just filler for the diff" | head -c 270000000 > big.txt
  git add -f key.txt big.txt
  if node "$SCAN" >/dev/null 2>&1; then bad "a key next to a 270 MB staged file went through"; else ok "a 270 MB staged diff is streamed and scanned"; fi
  git rm -rq --cached . >/dev/null 2>&1; rm -f big.txt key.txt
fi

# a binary secrets file has no «+++» line — still refused by its name
git rm -rq --cached . >/dev/null 2>&1 || true
head -c 64 /dev/urandom > "$T/release.p12"; git add -f release.p12
if node "$SCAN" >/dev/null 2>&1; then bad "binary .p12 not refused"; else ok "binary .p12 refused by name"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f release.p12

# a path with a space: the scanner must still run as main (a naive import.meta.url check would
# silently do nothing and let everything through)
mkdir -p "$T/with space"; cp "$SCAN" "$T/with space/scan.mjs"
printf '%s\n' "token: gh""o_$(b64 60 36)" > s.txt; git add -f s.txt
if node "$T/with space/scan.mjs" >/dev/null 2>&1; then bad "scanner under a path with a space did not run"; else ok "scanner runs from a path with a space"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f s.txt

# speed: a normal commit (40 files, 2,000 added lines) well under a second
git rm -rq --cached . >/dev/null 2>&1 || true
for i in $(seq 1 40); do for j in $(seq 1 50); do echo "export const value_${i}_${j} = computeSomething('item-$j', $i) // ordinary code line"; done > "f$i.ts"; done
git add -- f*.ts
start=$(now_ms); node "$SCAN" >/dev/null 2>&1; code=$?; ms=$(( $(now_ms) - start ))
if [ "$code" = 0 ]; then ok "ordinary 2,000-line commit passes"; else bad "ordinary 2,000-line commit refused"; fi
if [ "$ms" -lt 1000 ]; then ok "ordinary commit scanned in ${ms} ms (< 1000)"; else bad "ordinary commit took ${ms} ms (budget 1000)"; fi
git rm -rq --cached . >/dev/null 2>&1; rm -f f*.ts

# mutations: a scanner with a detection layer switched off must let the matching case through.
# If a mutant still blocks, the cases above do not actually test that layer.
mut() {
  local name="$1" sed_expr="$2" file="$3" content="$4"
  local M="$T/mut.mjs"; sed "$sed_expr" "$SCAN" > "$M"
  if cmp -s "$M" "$SCAN"; then bad "mutant '$name' did not change the scanner (sed no longer matches)"; return; fi
  git rm -rq --cached . >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$file")"; printf '%s\n' "$content" > "$file"; git add -f -- "$file"
  if node "$M" >/dev/null 2>&1; then ok "mutant '$name' is caught by the suite"; else bad "mutant '$name' still blocked — the proof does not test it"; fi
  rm -f "$file"; git rm -rq --cached . >/dev/null 2>&1 || true
}
mut "no live-value check" 's/const name = hashes.get(sha(t))/const name = null/' z.ts "const k = '$LIVE'"
mut "no substring check" 's/if (line.includes(r.value))/if (false)/' z1.ts "const p = \"$DELIM\""
mut "no shape list" 's/for (const s of SHAPES)/for (const s of [])/' z2.txt "token: gh""o_$(b64 60 36)"
mut "no file-name check" 's/if (name \&\& BAD_NAME.test(name)/if (false \&\& BAD_NAME.test(name)/' server/.env "X=1"

finish "secret-scan"
