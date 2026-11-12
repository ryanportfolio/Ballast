# Commands

> Build / dev / test commands. Dev runs in a GitHub Codespace (no Docker, WSL, Ruby or Postgres on the Windows PC). Sure's own command table: `docs/llm-guides/development.md`.

## Codespace (dev environment)

Config: `.devcontainer/ballast/devcontainer.json` (Sure's compose + sshd feature; no Selenium). Sure's `.devcontainer/devcontainer.json` has no SSH server → `gh codespace ssh` fails on it.

Needs `codespace` scope on gh once: `gh auth refresh -h github.com -s codespace`.

Create (2-core, 8 GB; build + `bundle install` ~10 min):

```bash
gh codespace create -R ryanportfolio/Ballast -b <branch> -m basicLinux32gb --devcontainer-path .devcontainer/ballast/devcontainer.json --idle-timeout 30m --retention-period 168h --display-name ballast-dev
```

Name: `gh codespace list`. First-time DB + fake demo data (demo login `user@example.com` / `Password1!`, from `config/demo.yml`):

```bash
gh codespace ssh -c <name> -- 'cd /workspace && cp -n .env.local.example .env.local && bin/rails db:prepare && SEED=42 bin/rails demo_data:default'
```

Start / restart app (Rails server, Sidekiq, Tailwind watcher, detached; logs `/tmp/ballast-{web,worker,css}.log`):

```bash
gh codespace ssh -c <name> -- bash /workspace/scripts/codespace-dev.sh
```

Open on this PC at `http://localhost:3000` (keep running):

```bash
gh codespace ports forward 3000:3000 -c <name>
```

Sync local commits into the Codespace: push branch, then `gh codespace ssh -c <name> -- 'cd /workspace && git pull'`. Views, CSS, Stimulus reload on browser refresh; Ruby in `app/` reloads per request; config/initializers/gems need the start script again.

Stop billing early: `gh codespace stop -c <name>` (auto-stops after 30 min idle).

## Why not Sure's `bin/dev` in the Codespace

- Detached, its Tailwind watcher exits when stdin closes → foreman SIGTERMs all processes. Script uses `tailwindcss:watch[always]`.
- `config/initializers/codespaces.rb` makes session cookies secure-only when `CODESPACES=true` → sign-in fails over the HTTP localhost forward (`InvalidAuthenticityToken`). Script unsets `CODESPACES`.
- `pkill -f puma` inside `gh codespace ssh -- '...'` kills the SSH shell itself (its command line contains "puma"). Use `pkill -f '[p]uma'`.

## Secrets guard

```bash
node scripts/check-secrets.mjs --all
```

Hook (once per clone): `git config core.hooksPath .githooks`.

## Upstream (Sure) merges

`git fetch upstream --tags`, merge a release tag (`git merge <tag>`). Keep ours for `CLAUDE.md`, `AGENTS.md`, `README.md`; refresh `.claude/reference/sure-conventions.md` from `MSYS_NO_PATHCONV=1 git show <tag>:AGENTS.md`. Never push upstream tags to origin (Sure's `ios-testflight.yml` and `llm-evals.yml` run on `v*` tags).
