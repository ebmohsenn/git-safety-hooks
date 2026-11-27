# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ebmohsenn/git-safety-hooks/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ebmohsenn/git-safety-hooks/releases/tag/v0.1.0
