# Strip log

> What Ballast removed or switched off from Sure, and how each area resolves on an upstream merge. Upstream edits to a removed path → modify/delete conflict → `git rm <path>` keeps it gone. Switched-off areas stay in the tree and merge normally.

| Area | How | Paths / switch | On upstream merge |
|---|---|---|---|
| Release, mobile, chart, desktop, LLM-eval, sync and docs workflows; Dependabot; issue/discussion templates; Copilot instructions | Deleted | `.github/workflows/{publish,mobile-*,flutter-build,ios-testflight,google-play-upload,desktop-release,chart-*,helm-publish,llm-evals,sync-maybe-sure,update-docs}.yml`, `.github/dependabot.yml`, `.github/{ISSUE_TEMPLATE,DISCUSSION_TEMPLATE}/`, `.github/copilot-instructions.md` | `git rm` any re-added or modified copy; new upstream workflows → review before keeping |

Kept workflows: `pr.yml` → `ci.yml` (tests, lint, Brakeman), `pipelock.yml`, our `secrets-guard.yml`. Pipelock scans the PR diff, so it flags Sure's `.env*.example` placeholders whenever a PR carries a large upstream merge.
