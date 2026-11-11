# Pitfalls

> Accumulated project-specific gotchas. Dated entries, newest at the bottom. If this file exceeds ~200 lines, split by area (`pitfalls-<area>.md`) and update the CLAUDE.md index.

- **2026-11-11 · Codespace dev server.** Sure's devcontainer has no sshd (`gh codespace ssh` fails), its `bin/dev` dies when detached (Tailwind watcher exits on closed stdin), and `CODESPACES=true` makes session cookies secure-only so sign-in over `http://localhost:3000` fails with `InvalidAuthenticityToken`. Use `.devcontainer/ballast/` + `scripts/codespace-dev.sh` (see `commands.md`). Cost 3 retries.
- **2026-11-11 · Line endings.** Sure commits 38 `config/locales/**/nb.yml` files with CRLF. A repo-wide `*.yml eol=lf` attribute makes them show as modified in every checkout; the firmware rule is scoped to `.github/` for that reason.
