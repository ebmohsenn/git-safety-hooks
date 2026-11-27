# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-27

A security release. A review found ways for a commit that contains a secret to pass the scanner
without a message, and one way for a committed settings file to run a program. All of them are
closed here, each with a regression test. If you vendor the hooks, re-run
`install.sh --vendor` and commit the result.

### Security
- **A committed `.git-safety.conf` could run a command.** `typecheck.command` was read from the
  committed file and executed on the next commit. It is now read from `git config` and the
  environment only. `migrations.dir` was spliced into a `sed` program and a regex; it is now only
  ever used as a literal name.
- **The secret scan saw nothing** when:
  - `diff.mnemonicPrefix` or `diff.noprefix` was set in the user's git config;
  - a file name contained non-ASCII characters, a double quote or a backslash (also for the
    migration-number check);
  - a file was marked `-diff` or `binary` in `.gitattributes`, or contained a NUL byte;
  - an earlier added line in the same file started with `++`;
  - a symlink was replaced by a regular file (a type change);
  - the staged diff was larger than 256 MB;
  - `secretScan.pattern` or `secretScan.ignorePath` held an invalid regex.
- **Key formats that were missed** are now matched: secret-named keys in lower or camel case
  (`jwtSecret`, `"client_secret":`, `api_key:`), 32 to 63 hex characters and tokens without
  capitals after a secret name, `redis://:password@`, `postgresql+driver://`, database passwords
  made of short groups or shorter than eight characters, Google API keys ending in `-`, GitHub
  tokens longer than 36 characters, GitLab, npm, Slack app, Stripe webhook, SendGrid and Hugging
  Face tokens, `.npmrc` `_authToken=` lines, and `https://user:password@host` URLs.
- **Live `.env` values that were missed** are now guarded: values containing quotes, brackets,
  commas or spaces, values followed by an inline comment, webhook URLs, base64 values that start
  with `/`, and `*_PASSPHRASE`, `*_PWD` and `*_VERIFICATION_SECRET` names.
- **More secrets files are refused by name:** `.envrc`, `<name>.env`, `.netrc`, `*.key`,
  `*.tfstate`, `id_dsa`.
- A `.git-safety.conf` that git cannot parse used to switch off every guard configured in it,
  silently. It is now an error.
- With many staged files, the migrations and typecheck checks could be skipped (a pipe under
  `pipefail`).
- `pushGuard.remote` was bypassed by pushing to the remote's URL instead of its name.
- fix-perms could `chmod` the target of a staged symlink, a file outside the repository (macOS).
- A file name containing an escape character reached the terminal raw in ratchet, migrations
  and typecheck messages.
- A custom pattern such as `(a+)+$` hung every commit, and one built-in rule was quadratic on a
  hostile line. Custom patterns now run under a time limit and every built-in rule is bounded.
- `trailer.key` could inject extra trailer lines; with `git commit -v` the trailer was lost.

### Changed
- **The secret scan fails closed.** If it cannot run, the commit is refused;
  `SECRET_SCAN_ALLOW_ON_ERROR=1` is the way past. Before, it printed "not blocking" and let the
  commit through.
- **`typecheck.command` in `.git-safety.conf` is ignored**, with a warning. Move it to
  `git config safety.typecheck.command`. If the compiler cannot run at all, the message now says
  so instead of "NOT CHECKED BY ANYTHING".
- **An invalid `.git-safety.conf` stops the hooks** with git's error message.
- Typecheck coverage needs the staged file's exact path in the compiler's file list, and an
  error counts against a staged file only when the error line starts with its path. Before, both
  were substring matches.
- `.env.dist`, `.env.defaults`, `.env.<x>.example` and `example.env` are treated as templates
  and no longer refused by name. Their contents are scanned.
- Connection strings with documentation passwords (`mysecretpassword`, `devpassword`,
  `admin123` and similar) or a short password on `localhost` are no longer reported.
- `SAFETY_SKIP`, `SKIP_TYPECHECK` and `PUSH_GUARD_OVERRIDE` print a line when they take effect.
  The secret scan says so when the committed file switches it off, and counts the files skipped
  by `secretScan.ignorePath`.
- `install.sh --uninstall` leaves a `core.hooksPath` that is not ours alone (use `--force`), and
  `--vendor` keeps a foreign file in `.githooks/lib/` as `<name>.orig`.
- CI actions are pinned by commit, and the pre-commit manifest declares pre-commit 3.2.0 as its
  minimum.

### Added
- `secretScan.allowName`: paths that may be committed although their name looks like a secrets
  file. Their contents are still scanned.
- `typecheck.enabled`: set it to `false` in `git config` to keep a committed
  `typecheck.project` from running a compiler.
- `SECURITY.md`.

### Removed
- `SECRET_SCAN_DIFF_FILE`, an undocumented switch that made the scanner read a file instead of
  the staged diff.

### Known limits (documented in the README)
- UTF-16 text is not scanned.
- Under the pre-commit framework the push guard sees one ref per push and no deletions.

## [0.1.0] - 2026-11-10

First public release. The hooks were extracted from a private production repository where many
developers and AI agents commit concurrently, then generalized.

### Added
- `pre-commit` dispatcher with these checks:
  - **secret-scan**: live `.env` values compared by SHA-256, known key formats and secrets file
    names, all on staged additions only. The value is never printed.
  - **stale-revert guard**: blocks a commit that is the near-exact inverse of a recent commit
    (a stale copy of a file).
  - **shrink-only ratchet** for files you configure.
  - **migration-number collision** check (index-based, ignores settled duplicates).
  - **staged-only typecheck** with a `--listFiles` coverage guard (opt-in).
  - **fix-perms** for shared machines (opt-in).
- `commit-msg`: an optional `Agent:` trailer that records which tool made the commit.
- `pre-push`: an optional push guard (allow-list of remote refs, no remote deletions).
- `.git-safety.conf` configuration (git-config syntax, never sourced) and `git config safety.*`
  overrides.
- `install.sh` with link, `--vendor` and `--uninstall` modes. It also chains existing
  `.git/hooks/*`.
- Integration with the pre-commit framework (`.pre-commit-hooks.yaml`) and notes for husky.
- A test suite with mutation tests (`make test`) and CI on Ubuntu and macOS.

### Changed (compared with the internal version)
- The scripts now detect their entry point in a way that works when the path contains spaces or
  symlinks. Before, a hook installed under such a path silently did nothing.
- Permission detection works on macOS (BSD `stat`) as well as Linux.
- The trailer stamper was ported from Python to Node, so the only runtime needed is Node.
- The stale-revert replay test, which used real commits, was replaced by synthetic scenarios that
  run with a fixed clock.

[Unreleased]: https://github.com/Ebmohsennn/git-safety-hooks/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Ebmohsennn/git-safety-hooks/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Ebmohsennn/git-safety-hooks/releases/tag/v0.1.0
