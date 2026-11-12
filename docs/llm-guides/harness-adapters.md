# Instruction adapters and maintenance

[AGENTS.md](../../AGENTS.md) contains the shared repository requirements and links
to detailed guides. Harness entry points load or direct readers to that guidance.
The [preservation map](instruction-preservation-map.md) records the sources,
history and intentional policy decisions behind this structure.

## Supported entry points

| Harness | Repository entry point | Loading behavior |
| --- | --- | --- |
| AGENTS-compatible tools | [AGENTS.md](../../AGENTS.md) | Read the root instructions and applicable linked guides. |
| Claude Code | [CLAUDE.md](../../CLAUDE.md) | Loaded at session start. |

Ballast deleted Sure's Cursor (`.cursor/`), GitHub Copilot
(`.github/copilot-instructions.md`), Junie (`.junie/`) and Gemini (`.gemini/`)
adapters; see `.claude/reference/strip-log.md`.

## Maintaining guidance

- Put common requirements in AGENTS and detailed explanations, examples and
  procedures in the appropriate shared guide. Keep adapters limited to loading
  and routing guidance.
- Update guidance when code, a workflow or a reviewed requirement changes.
  Verify examples against current files; keep links accurate and remove resolved
  temporary advice with an explanation in the change description.
- Review parallel entry points before changing a rule. Record intentional changes
  to mandatory checks, permission requirements or harness applicability explicitly.
- Change existing shared guidance before adding a new document or rule. Repeated
  code alone is not a trigger to generate more harness-specific policy files.
- When editing an adapter, verify its target and applicable loading syntax. The
  existing [API checker](../../test/support/verify_api_endpoint_consistency.rb)
  protects the API guide.

## Skills considered

[Adding a securities provider](adding-a-securities-provider.md) and
[gating a preview feature](gating-a-preview-feature.md) are bounded, repeatable
workflows and therefore plausible skill candidates. Skills have real ecosystem
support: both Copilot and Junie document the open format and shared
`.agents/skills/` locations.
[Copilot customization reference](https://docs.github.com/en/copilot/reference/customization-cheat-sheet),
[Junie agent skills](https://junie.jetbrains.com/docs/agent-skills.html)

No skill wrapper is introduced. The shared guides already make these procedures
available across harnesses; the repository also has
[Rails provider generators](../../lib/generators/provider/). A wrapper would add
another discovery and maintenance layer without a demonstrated invocation,
template-packaging or execution benefit. The wealth guides describe product
integration and operation, not a repository coding skill.

## Legacy helpers

[bin/codex-env](../../bin/codex-env) is a legacy Linux environment bootstrap,
not the standard setup procedure or a skill. It installs system packages,
changes PostgreSQL authentication, and can comment out the Ruby requirement
and mark Gemfiles assume-unchanged when versions differ. It remains unchanged;
use the maintained [development guide](development.md) for repository setup and
checks.
