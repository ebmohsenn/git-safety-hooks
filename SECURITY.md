# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue: open the repository's
**Security** tab and choose **Report a vulnerability**
(<https://github.com/ebmohsenn/git-safety-hooks/security/advisories/new>).

Include what you found and the smallest repository or command that shows it. You will get an
acknowledgement within a few days, and credit in the changelog when the fix ships, if you want it.

Only the latest release receives fixes.

## What counts

- **A bypass of the secret scanner.** A commit that adds a secret in one of the formats the README
  lists, or a value from a configured env file, and is passed without a message. This includes
  bypasses that depend on git settings, attributes, file names or the size and shape of the diff.
  Please build the test secret at run time from random bytes; never send a real one.
- **Anything that lets a repository's content run code or write files through the hooks** beyond
  what the README says a committed `.git-safety.conf` can do. The file may switch checks on and
  off and supply patterns. It must not be able to name a command, and none of its values may
  reach `sed`, `eval` or a shell-built regex.
- A way to make a guard (push guard, ratchet, migrations, stale-revert) pass silently through
  configuration that looks valid.
- A value that the scanner prints, logs or writes anywhere.

Not a vulnerability: a secret in a format the scanner does not know (a feature request), and the
documented ways to skip a check (`--no-verify`, `SAFETY_SKIP`, the per-check overrides, a clone
that never set `core.hooksPath`).

## What these hooks are, and are not

They are a safety net on the developer's machine. They catch the common, accidental cases
before a commit exists. They are not a guarantee and not an enforcement point: hooks are
optional by design, they look only at the lines a commit adds, and a new key format or an
encoding the scanner does not read (UTF-16, for one) passes. Keep a server-side scanner in CI or
on the host (GitHub secret scanning with push protection, gitleaks, trufflehog), and rotate any
secret that was ever pushed, whatever a scanner said.
