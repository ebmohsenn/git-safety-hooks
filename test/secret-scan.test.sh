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

# a fake local .env: one plain secret, one credentialed URL, one public value, one e-mail
LIVE="$(b64 48 40)"; DBPASS="$(b64 24 20)"
printf 'MY_SERVICE_SECRET=%s\nDATABASE_URL=postgresql://app_rt:%s@localhost:5432/db\nVITE_SITE_KEY=%s\nADMIN_EMAIL=someone@example.org\n' \
  "$LIVE" "$DBPASS" "$(b64 48 40)" > "$T/fake.env"
export SECRET_SCAN_ENV_FILES="$T/fake.env"

# case_ <name> <expect 0|1> <file> <content> [ENV=VAL…]
case_() {
  local name="$1" expect="$2" file="$3" content="$4"; shift 4
  git rm -rq --cached . >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$file")"; printf '%s\n' "$content" > "$file"; git add -f -- "$file"
  local out code
  out="$(env "$@" node "$SCAN" 2>&1)"; code=$?
  if [ "$code" = "$expect" ]; then ok "$name"; else bad "$name: exit $code, expected $expect — $out"; fi
  for v in "$LIVE" "$DBPASS"; do case "$out" in *"$v"*) bad "$name: printed a secret value";; esac; done
  rm -f "$file"; git rm -rq --cached . >/dev/null 2>&1 || true
}

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
mut "no shape list" 's/for (const s of SHAPES)/for (const s of [])/' z2.txt "token: gh""o_$(b64 60 36)"
mut "no file-name check" 's/if (BAD_NAME.test(head\[1\])/if (false \&\& BAD_NAME.test(head[1])/' server/.env "X=1"

finish "secret-scan"
