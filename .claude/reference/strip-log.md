# Strip log

> What Ballast removed or switched off from Sure, and how each area resolves on an upstream merge. Upstream edits to a removed path → modify/delete conflict → `git rm <path>` keeps it gone. Switched-off areas stay in the tree and merge normally.

| Area | How | Paths / switch | On upstream merge |
|---|---|---|---|
| Release, mobile, chart, desktop, LLM-eval, sync and docs workflows; Dependabot; issue/discussion templates; Copilot instructions | Deleted | `.github/workflows/{publish,mobile-*,flutter-build,ios-testflight,google-play-upload,desktop-release,chart-*,helm-publish,llm-evals,sync-maybe-sure,update-docs}.yml`, `.github/dependabot.yml`, `.github/{ISSUE_TEMPLATE,DISCUSSION_TEMPLATE}/`, `.github/copilot-instructions.md` | `git rm` any re-added or modified copy; new upstream workflows → review before keeping |
| Flutter mobile app, macOS desktop app, Helm chart, other agents' config | Deleted | `mobile/`, `desktop/`, `charts/`, `.cursor/`, `.gemini/`, `.junie/` | `git rm -r` |
| Pipelock workflow (renders `charts/sure`, so it can't run without the chart) | Deleted; `pr.yml` loses its `charts/**` paths-ignore | `.github/workflows/pipelock.yml` | `git rm`; keep our `pr.yml` |

Kept workflows: `pr.yml` → `ci.yml` (tests, lint, Brakeman) and our `secrets-guard.yml`. Kept `.sure-version`: read by `config/initializers/version.rb`. Mobile/desktop SSO routes and API stay until the SSO step.
