# Ballast

Ballast is a personal-finance app for a single household. It is a trimmed-down, locked-down copy of [Sure](https://github.com/we-promise/sure), meant to run on hardware the household controls rather than as a public service.

It tracks bank accounts through [SimpleFIN Bridge](https://www.simplefin.org/), which Sure already supports. Everything else Sure ships for other banks, brokers, hosted billing, mobile apps and telemetry is being removed or switched off, so the app has fewer parts that can break or send data elsewhere.

## Status

Early. The code is currently Sure v0.7.6, unmodified, merged in with its full history. Removal of the unused parts has not started yet.

## Where the code comes from

Ballast is built on [Sure](https://github.com/we-promise/sure), the community-maintained fork of [Maybe Finance](https://github.com/maybe-finance/maybe), which Maybe Finance Inc. open-sourced and later archived. Almost all of the application code is their work.

Ballast is **not affiliated with or endorsed by** Maybe Finance Inc. or the Sure project. "Maybe" is a trademark of Maybe Finance Inc. and is not used as Ballast's name or branding.

Sure is kept as the `upstream` git remote and its releases are merged in regularly. Fixes that would help every Sure user go back to Sure as pull requests.

## Running it

Setup commands are in [`.claude/reference/commands.md`](.claude/reference/commands.md). Sure's own hosting notes are in [`docs/hosting/`](docs/hosting/).

## Keeping secrets out of this repo

This repository is public and the app handles bank data. Real financial data, `.env` files, the SimpleFIN access URL (which can read every linked account), database dumps and screenshots of real accounts must never be committed.

`.gitignore` blocks the common cases, and [`scripts/check-secrets.mjs`](scripts/check-secrets.mjs) checks file names and contents before each commit and in CI. Turn the commit hook on once per clone:

```sh
git config core.hooksPath .githooks
```

## License

AGPL-3.0, the same license as Maybe Finance and Sure. See [LICENSE](LICENSE).
