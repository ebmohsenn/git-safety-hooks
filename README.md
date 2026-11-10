# git-safety-hooks

Fast git hooks that stop the mistakes that are cheap to prevent and expensive to undo: a secret
pasted into a commit, a commit built from a stale copy of a file that silently reverts someone
else's work, a god-file that keeps growing, two migrations with the same number.

They were written for a repository where many people **and AI coding agents** commit to the same
tree concurrently, which is where these failures happen most often. They are just as useful on
an ordinary team.

- **Fast.** The default checks finish well under a second on a normal commit. A slow hook gets
  bypassed with `--no-verify`, and then it protects nothing.
- **Diff-only.** Checks look only at what *this* commit stages, so you never need a baseline
  file and never get blocked by existing debt.
- **Honest about bypasses.** Every block names a one-off override, and the override is printed.
- **Fail open on their own bugs.** An internal error in a check is reported and does not block
  the commit.
- **Small dependency footprint:** `git`, `bash` (3.2+, so the macOS default works) and Node.js >= 18.
  Linux and macOS.

## What each hook catches

| Check | Hook | Default | Catches |
|---|---|---|---|
| [secret-scan](#secret-scan) | pre-commit | **on** | Secrets in the lines a commit adds: values from your local `.env`, known key formats, secrets files by name |
| [stale-revert](#stale-revert-guard) | pre-commit | **on** | A commit that silently undoes a recent commit because it was built from an old copy of a file |
| [ratchet](#shrink-only-ratchet) | pre-commit | when configured | Growth of files you have declared shrink-only |
| [migrations](#migration-number-collisions) | pre-commit | when configured | Two migration files with the same numeric prefix |
| [typecheck](#staged-only-typecheck-optional) | pre-commit | opt-in | Type errors in staged TypeScript files, and staged files the compiler **never opened** |
| [fix-perms](#fix-perms-optional) | pre-commit | opt-in | Staged files that other users on a shared machine can't read (it fixes them) |
| [push-guard](#push-guard-optional) | pre-push | when configured | Pushing branches that are not on the allow-list; deleting remote refs |
| [trailer](#agent-trailer-optional) | commit-msg | opt-in | Nothing. It records *which tool* made the commit (`Agent: claude-code`) |

### secret-scan

Scans only the **added** lines of the staged diff (`git diff --cached -U0`). It reports
`file:line` and the *name or kind* of the secret, and never prints the value.

1. **Live values.** Every secret-looking value in your local, uncommitted env file(s) (default
   `.env`) is hashed with SHA-256 once at start. Every token of every added line is hashed and
   compared against those hashes. This catches *your actual* database password even when it
   doesn't match any known format. Values that are clearly not secrets are skipped: short values,
   numbers, booleans, plain words, paths, e-mail addresses, URLs without credentials, and names
   like `*_ID`, `PUBLIC*`, `VITE_*`, `NEXT_PUBLIC_*`.
2. **Key formats.** AWS access key, PEM private-key block, GitHub token, Anthropic / OpenAI /
   OpenRouter key, Google API key and OAuth client secret, Slack token, Telegram bot token,
   Stripe live key, a database URL with a real password, a 64-hex or long base64 value assigned
   to a `*SECRET*`/`*TOKEN*`/`*PASSWORD*`/`*API_KEY*` name, plus any patterns you add.
3. **File names.** `.env*` (except `.env.example|sample|template`), `*.pem`, `*.p12`, `*.pfx`,
   `*.jks`, `*.keystore`, `id_rsa`/`id_ed25519`/`id_ecdsa`, `keystore.properties`,
   `google-service-account*.json`, `*credentials*.json`. This also covers binary files.

Placeholders are ignored: `example`, `your-…`, `xxxx`, `changeme`, `<token>`, `${VAR}`,
`process.env…`, and low-variety fixtures like `sk-ant-api03-000…`.

```text
✖ commit blocked: this commit adds what looks like a secret (the value is not shown):
     scripts/deploy.sh:14  DATABASE_URL (password) (a value from your local env file)
     src/client.ts:3  github-token pattern
```

Allow a single line by putting `secret-scan: allow <why>` on it or on the line above. Allow a
whole commit with `SECRET_SCAN_ALLOW="<why>" git commit …`.

### stale-revert guard

**The failure:** someone, often an AI agent, writes a whole file from an old copy. That copy might
be an editor buffer opened an hour ago, a file copied from another worktree, or the agent's memory
of the file. The commit contains their change *and* silently reverts everything that landed in that
file since. Viewed alone, the commit looks fine.

**The signature:** for each staged file, the guard compares what the staged diff removes and adds
with what each recent commit (default: last 48 h, on `HEAD`'s history) added and removed in that
file. It fires only when the staged diff is close to the **exact inverse** of that commit:

- **strong:** the commit both added and removed lines (at least 5 added), and at least 90 % of its
  additions are removed again and at least 90 % of its removals are back. One file is enough.
- **weak:** the commit only added lines (at least 5) and they are all removed. On its own this
  looks like a deliberate deletion, so it fires only when the same commit is reverted this way in
  **two or more files**, for example a feature and its test vanishing together.
- **small:** the same as weak, but for very small commits. They count only if they landed in the
  last 30 minutes, because stale copies race on a scale of minutes.

A refactor, a rewrite, or a partial removal of recent lines doesn't meet the 90 % test. The guard
never fires on new files, pure additions, trivial lines (braces, blanks), or during a merge,
cherry-pick or revert. A deliberate revert passes with
`ACK_REVERT="<sha or reason>" git commit …`.

```text
✖ commit blocked: this commit looks like it UNDOES a recent commit (stale copy of a file?).
   3f9a1c2d4  feat: retry failed webhooks
     src/webhooks.ts: its 18 added line(s) are removed and its 4 removed line(s) are back
   Fix: start from HEAD (`git show HEAD:<path>`), re-apply only YOUR hunks, restage.
```

### shrink-only ratchet

List the files that attract endless "just one more branch" growth, such as a 10k-line route
handler or a god class. A commit whose staged version of any listed file has more lines than
`HEAD`'s is refused. Each file is judged on its **net** line count, separately. `HEAD` is the
baseline, so the limit only ever moves down and there is no baseline file to conflict on. Use
`ratchet.hint` to tell people where new code should go instead. Override with
`RATCHET_OVERRIDE="<why>"`.

### migration-number collisions

Two people each pick "the next number" from the same starting point: `0042_add_users.sql` and
`0042_add_orders.sql`. The check reads the **index**, takes each file's leading digits (leading
zeros ignored), and refuses a duplicate when at least one of the files is **new in this commit**.
Old duplicates that are already in `HEAD` are treated as settled history, so they never block
future commits.

### staged-only typecheck (optional)

This check is slow, because it runs `tsc`, so it is off until you configure a project. It adds two
things that a plain `tsc` hook lacks:

- **Coverage before "no errors".** "tsc printed no error about your file" and "tsc never opened
  your file" produce identical output. The check asks the same run for `--listFiles` and fails
  loudly on a staged `.ts` file under the project's directory that isn't in the program, unless
  `typecheck.exclude` covers it.
- **Only your files block.** Type errors in files you are *not* committing are shown as a warning,
  so a teammate's half-finished file never blocks your commit.

`SKIP_TYPECHECK=1 git commit …` skips the typecheck for one commit, and the fast checks still run.

### fix-perms (optional)

git records only the executable bit, so a staged file at mode `0600` is a local detail that git
never sees. On a shared machine, though, it hides the file from every other user, such as a CI
runner, a cron job, or a deploy user, which then fail with `EACCES`. A common cause is the
"atomic write" pattern: `mkstemp()` creates files at `0600`, and the rename carries that mode onto
the target. This check doesn't block. It runs `chmod g+r,o+r` and tells you.

### push guard (optional)

For trunk-based repos, and for agents that keep local scratch branches that must never reach the
remote. Only remote refs that match `pushGuard.allow` (shell globs) can be pushed, and remote refs
can't be deleted unless `pushGuard.allowDeletes = true`. Override one push with
`PUSH_GUARD_OVERRIDE=1 git push …`.

### Agent trailer (optional)

When several humans and AI agents commit under one git identity, the log can't tell you which tool
made a commit. With `trailer.enabled = true`, every commit gets a trailer:

```text
Agent: claude-code        # or cursor, codex, human, unknown — or whatever you set
```

Detection order: `$GIT_AGENT`, then `git config safety.agent`, then `CLAUDECODE=1`, then
`CURSOR_AGENT` / `CURSOR_TRACE_ID`, then `CODEX_SANDBOX` / `CODEX_THREAD_ID` / `CODEX_CI`, then a
TTY (`human`), and finally `unknown`. The Cursor and Codex variable names are best-effort. If your
tool sets something else, export `GIT_AGENT`. The hook is idempotent (amend and rebase never add
a second trailer), skips merge commits, puts the trailer in its own paragraph rather than gluing it
to a one-line subject, and never blocks a commit.

## Install

```sh
git clone https://github.com/mohsenebrahimizadeh-ai/git-safety-hooks ~/src/git-safety-hooks
cd your-repo

# Option A — point this repo at the clone (one machine; update with `git pull` in the clone)
~/src/git-safety-hooks/install.sh

# Option B — vendor the hooks into the repo so the whole team runs the same version
~/src/git-safety-hooks/install.sh --vendor --config
git add .githooks .git-safety.conf && git commit -m "Add git-safety-hooks"
# every other clone then runs once:
git config core.hooksPath .githooks
```

`install.sh --uninstall` unsets `core.hooksPath`. The installer won't replace a `core.hooksPath`
that another tool owns, such as husky, unless you pass `--force`.

Setting `core.hooksPath` makes git ignore `.git/hooks/`. To make sure nothing is silently lost, any
executable `.git/hooks/<same-name>` still runs **after** these hooks. To turn that off, set
`safety.chainLocalHooks = false`.

### Using with husky

Keep husky in charge and call the vendored hooks from it:

```sh
# .husky/pre-commit
.githooks/pre-commit

# .husky/commit-msg
.githooks/commit-msg "$1"

# .husky/pre-push
.githooks/pre-push "$@"
```

To get the files there, copy them in with `cp -R ~/src/git-safety-hooks/hooks .githooks`. Don't
run `install.sh` here, because it would take `core.hooksPath` away from husky.

### Using with the pre-commit framework

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/mohsenebrahimizadeh-ai/git-safety-hooks
    rev: v0.1.0
    hooks:
      - id: git-safety-pre-commit
      - id: git-safety-commit-msg     # only if trailer.enabled
      - id: git-safety-pre-push       # only if pushGuard.allow is set
```

```sh
pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
```

The pre-commit framework stashes unstaged changes and leaves the index alone, so these checks see
exactly what will be committed. Node must be on `PATH`.

## Configuration

Settings are read, first match wins, from:

1. `git config safety.<key>`: per machine or per clone, never committed.
2. `.git-safety.conf` in the repo root: git-config syntax, committed. Its path can be overridden
   with `$GIT_SAFETY_CONFIG`. The file is read with `git config -f`, **never sourced**, so it can't
   execute code.

See [`examples/git-safety.conf`](examples/git-safety.conf) for a fully commented file.

| Key | Default | Meaning |
|---|---|---|
| `secretScan.enabled` | `true` | |
| `secretScan.envFile` (multi) | `.env` | Local env files whose values are guarded |
| `secretScan.pattern` (multi) | none | Extra JavaScript regex sources |
| `secretScan.ignorePath` (multi) | none | JavaScript regex sources of paths that are never scanned |
| `staleRevert.enabled` | `true` | |
| `staleRevert.windowHours` | `48` | How far back "recent" commits go |
| `staleRevert.ratio` | `0.9` | Share of a commit's lines that must be inverted |
| `staleRevert.minLines` | `5` | Lines a commit must have added for a strong or weak hit |
| `staleRevert.smallWindowMinutes` | `30` | Window for small hits |
| `staleRevert.skipPath` (multi) | none | Regex sources of paths that are never examined (lockfiles, `dist/`, images… are always skipped) |
| `ratchet.file` (multi) | none | Shrink-only files (git pathspecs) |
| `ratchet.hint` | none | Line printed when the ratchet blocks |
| `migrations.dir` (multi) | none | Migration directories |
| `typecheck.project` (multi) | none | tsconfig paths. Setting one turns the typecheck on |
| `typecheck.exclude` (multi) | none | Shell globs of staged paths that need no coverage |
| `typecheck.command` | `npx --no-install tsc` | Compiler command |
| `fixPerms.enabled` | `false` | |
| `pushGuard.allow` (multi) | none | Remote-ref globs. Setting one turns the guard on |
| `pushGuard.remote` (multi) | all | Only guard these remotes |
| `pushGuard.allowDeletes` | `false` | |
| `trailer.enabled` | `false` | |
| `trailer.key` | `Agent` | Trailer name |
| `chainLocalHooks` | `true` | Also run executable `.git/hooks/<name>` |

**One-off environment overrides** (all printed when used):

| Variable | Effect |
|---|---|
| `SAFETY_SKIP=secret-scan,stale-revert,…` | Skip the named checks (`all` skips everything) |
| `SECRET_SCAN_ALLOW="<why>"` | Allow this commit past the secret scan |
| `ACK_REVERT="<sha or why>"` | Allow a deliberate revert |
| `RATCHET_OVERRIDE="<why>"` | Allow a ratchet file to grow |
| `SKIP_TYPECHECK=1` | Skip the typecheck |
| `PUSH_GUARD_OVERRIDE=1` | Allow this push |
| `GIT_AGENT=<name>` | Value of the agent trailer |

If you commit through a private index (`GIT_INDEX_FILE=… git commit`), every check reads that
index and not the default one.

## Limitations

- **The secret scan is a seatbelt, not a vault.** It looks only at *added lines of this commit*.
  It doesn't scan history, and it can't recognise a secret that has no known format and isn't in
  your env file. Pair it with a server-side scanner (for example GitHub secret scanning, gitleaks
  or trufflehog in CI) and rotate anything that was ever pushed.
- **Hooks are client-side and optional by design.** `--no-verify` skips all of them, and so does a
  clone that never set `core.hooksPath`. Run the same checks in CI if they must be enforced.
- **The stale-revert guard is a heuristic.** It is tuned for near-zero false positives, so it will
  miss partial stale copies, for example a file that drops only *some* of a recent commit's lines.
  It looks only at commits reachable from `HEAD` within the window, and ignores merge commits
  themselves.
- **Ratchet** counts lines, not complexity. It can be gamed by joining lines.
- **Migrations** reads only the top level of each configured directory, and the numeric prefix
  only.
- **Typecheck** matches tsc's output by path suffix. Projects that map files through unusual
  `rootDirs` or symlinks may need `typecheck.exclude`.
- **Agent detection** depends on environment variables that each tool sets, and those can change.
- If `node` is missing, the secret scan and the stale-revert guard print a warning and are
  **skipped**, not enforced.
- Windows is untested (Git for Windows' bash will probably work, but this is not verified).

## Development

```sh
make test     # every suite in test/, against throwaway repos in $TMPDIR
make lint     # shellcheck + node --check
```

The suites include **mutation tests**. The secret scanner, the stale-revert guard and the coverage
check are each re-run with a detection layer switched off, and the suite must notice. A test suite
that still passes against a broken guard proves nothing. Test fixtures that look like secrets are
assembled at run time from random bytes and split literals, so the repository itself contains no
secret-shaped strings.

## License

MIT. See [LICENSE](LICENSE).
