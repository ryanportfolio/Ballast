# MCP Server for External AI Assistants

Ballast includes a Model Context Protocol (MCP) server endpoint that allows external AI assistants like Claude Desktop, GPT agents, or custom AI clients to query and act on your financial data.

## What is MCP?

[Model Context Protocol](https://modelcontextprotocol.io/) is a JSON-RPC 2.0 protocol that enables AI assistants to access structured data and tools from external applications. Instead of copying and pasting financial data into a chat window, your AI assistant can directly query Ballast's data through a secure API.

This is useful when:
- You want to use an external AI assistant (Claude, GPT, custom agents) to analyze your Ballast financial data
- You prefer to keep your LLM provider separate from Ballast
- You're building custom AI agents that need access to financial tools

## Authentication

MCP clients authenticate with one static bearer token, which pins the MCP server to a specific Ballast user. Ballast has no OAuth sign-in or dynamic client registration for MCP clients.

Set these environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `MCP_API_TOKEN` | Bearer token for authentication | `your-secret-token-here` |
| `MCP_USER_EMAIL` | Email of the Ballast user whose data the assistant can access | `user@example.com` |

Both variables are required; without them `/mcp` rejects every request.

### Generating a secure token

Generate a random token for `MCP_API_TOKEN`:

```bash
# macOS/Linux
openssl rand -base64 32

# Or use any secure password generator
```

### Choosing the user

The `MCP_USER_EMAIL` must match an existing Ballast user's email address. The AI assistant will have access to all financial data for that user's family.

> [!CAUTION]
> The AI assistant can call the MCP tools available to the specified user. This includes reading financial data and write-capable tools such as account statement uploads, category/tag changes, and transaction updates. Only set this for users you trust with your AI provider.

## Configuration

### Docker Compose

Add the environment variables to your `compose.yml`:

```yaml
x-rails-env: &rails_env
  MCP_API_TOKEN: your-secret-token-here
  MCP_USER_EMAIL: user@example.com
```

Both `web` and `worker` services inherit this configuration.

## Protocol Details

The MCP endpoint is available at:

```
POST /mcp
```

### Authentication

Every request sends the `MCP_API_TOKEN` value as a Bearer token:

```
Authorization: Bearer <token>
```

### Supported Methods

Ballast implements the following JSON-RPC 2.0 methods:

| Method | Description |
|--------|-------------|
| `initialize` | Protocol handshake, returns server info and capabilities |
| `tools/list` | Lists available financial tools with schemas |
| `tools/call` | Executes a tool with provided arguments |

### Available Tools

The MCP endpoint exposes the same tool registry used by Ballast's built-in assistant. Clients should treat `tools/list` as the source of truth.

At the time of writing, `tools/list` includes:

| Tool | Description |
|------|-------------|
| `get_transactions` | Search transactions with filters (exact names or ids), sorting by date or absolute amount, and pagination |
| `get_recurring_transactions` | Detected and manual recurring transactions (subscriptions, bills, salaries) with expected dates and per-currency totals |
| `get_accounts` | Accounts with ids and current balances; pass `include_balance_series: true` for a period-bounded history series |
| `get_holdings` | Query investment holdings |
| `get_balance_sheet` | Net worth, assets and liabilities with a configurable history period and interval |
| `get_income_statement` | Income and expenses for a period, with optional monthly series, prior-period comparison and account filtering |
| `get_merchants` | Merchants with the ids `update_transaction` accepts and the exact names `get_transactions` filters on |
| `get_tags` | Tags with pagination |
| `get_categories` | Categories with hierarchy and pagination |
| `set_opening_balance` | Set a manual account's opening balance and the date it applies from, reporting whether the current balance changes. Supports `dry_run` |
| `unmatch_transfer` | Unlink a confirmed or pending transfer (by either transaction's id) so a wrong match can be redone; rejects the pairing for auto-match by default. Supports `dry_run` |
| `update_transfer` | Switch a confirmed transfer into an investment or crypto account between an investment contribution (counted as spending) and a plain transfer, e.g. when a brokerage or crypto account only converts currency. Supports `dry_run` |
| `create_tag` / `update_tag` | Manage tags |
| `create_category` / `update_category` / `delete_category` | Manage categories: create, rename, recolor, move between parents, and delete (optionally moving transactions to a replacement) |
| `update_transaction` | Edit a transaction's metadata (name, notes, category, merchant, tags) |
| `get_transfer_match_candidates` | A transaction's current transfer (including a pending auto-match) or the transactions it could be matched with, as in the "Match transfer" dialog |
| `match_transfer` | Match a transaction as a transfer with an existing counterpart, or create the counterpart in a target account (e.g. a manual loan). Supports `dry_run` |
| `review_transfer` | Confirm or reject a pending auto-matched transfer |
| `get_rules` / `get_rule_options` | Transaction rules in readable form (ids resolved to names, latest run; paginated, with a text search), and the condition and action types a rule can use |
| `preview_rule` | Match count and a sample of matching transactions for a saved rule or an unsaved definition, without changing anything |
| `create_rule` / `update_rule` | Save a rule definition. Rules are always saved inactive, and changing an active rule's conditions or actions deactivates it. AI-backed actions are not available |
| `apply_rule` | Activate a rule and apply it. Requires the `preview_token` from `preview_rule`, `create_rule` or `update_rule` (never `get_rules`; it expires after 30 minutes) and refuses if the rule or its matches have changed; keeps hand-set values unless `override_locked: true` |

### Preview Tools

These additional tools appear only when the MCP user has opted into preview
features (Settings → Preferences). Until then they are absent from `tools/list`,
and calling one by name returns an "Unknown tool" error. The Statement Vault
tools additionally require the user to be an admin or member, matching the
permissions enforced in the web UI.

| Tool | Description |
|------|-------------|
| `upload_account_statement` | Store a statement document (PDF/CSV/XLSX) in the Statement Vault; deduplicates by SHA-256 |
| `list_account_statements` | List vault documents with their SHA-256, period, linked account and review status |
| `get_account_statement` | One statement's details and its reconciliation checks against the ledger — present only once someone has entered the statement's opening/closing balances in the web UI, since nothing extracts them from the document. Does not return the file: stored documents are served only to a signed-in browser session |
| `get_statement_coverage` | Month-by-month statement coverage for an account: `covered`, `missing`, `mismatched`, `ambiguous`, `duplicate`, `not_expected`, each with a reconciliation status |
| `record_valuation` | Record an account's value on a date, with a required source citation |
| `get_valuations` | List recorded valuations newest first, including the citation stored in each entry's notes; the read pair for `record_valuation` |
| `get_insights` | Read the proactive insights feed (spending anomalies, cash-flow warnings, subscription audits and more) without marking anything read |
| `get_bills` | List bills, subscriptions and other recurring obligations with each one's current payment state |
| `get_bill_details` | One bill's full configuration, open occurrences, payment history, price-change history and cost analytics |
| `get_paycheck_plan` | Income plan sliced into pay periods: what is due before the next payday, what stays reserved for later bills, what is safe to spend |
| `get_bill_audit` | Deterministic bills review: possible duplicates, price changes, trials about to convert, upcoming renewals, long-overdue bills and undeclared recurring patterns |
| `create_bill` | Create a bill, subscription, installment plan or income schedule |
| `update_bill` | Update one bill's configuration; amount changes apply from today forward |
| `record_bill_payment` | Record a partial payment against a bill's open occurrence, or settle it in full |

Because tool calls never pass through the Bills pages' controllers, the bills
tools re-check the family's recurring-transactions feature gate (Settings →
Recurring transactions) and the MCP user's per-account access on every call.
With the feature disabled they return an error result instead of data, bills
tied to accounts the user cannot see are never returned, and the write tools
refuse series on accounts shared with the user read-only.

They exist for agents that maintain a document-backed record of a family's
wealth over time. See
[Wealth history with an external agent harness](../llm-guides/wealth-agent-harness.md).

## Example Requests

### Initialize

Handshake to verify protocol version and capabilities:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize"
  }'
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {
      "name": "ballast",
      "version": "1.0"
    }
  }
}
```

### List Tools

Get available tools with their schemas:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

Response includes tool names, descriptions, and JSON schemas for parameters.

### Call a Tool

Execute a tool to get transactions:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "get_transactions",
      "arguments": {
        "start_date": "2024-01-01",
        "end_date": "2024-01-31"
      }
    }
  }'
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[{\"id\":\"...\",\"amount\":-45.99,\"date\":\"2024-01-15\",\"name\":\"Coffee Shop\"}]"
      }
    ]
  }
}
```

## Security Considerations

### Transient Session Isolation

The MCP controller creates a **transient session** for each request, so MCP calls never reuse or change a browser session.

Each MCP request:
1. Authenticates the token
2. Loads the authorized Ballast user
3. Creates a temporary session scoped to that user
4. Executes the tool call
5. Discards the session

This ensures the AI assistant can only access data for the intended user.

### Pipelock Security Scanning

For production deployments, we recommend using [Pipelock](https://github.com/luckyPipewrench/pipelock) to scan MCP traffic for security threats.

Pipelock provides:
- **DLP scanning**: Detects secrets being exfiltrated through tool calls
- **Prompt injection detection**: Identifies attempts to manipulate the AI
- **Tool poisoning detection**: Prevents malicious tool call sequences
- **Policy enforcement**: Block or warn on suspicious patterns
- **Signed receipts**: Produces verifiable evidence for mediated MCP decisions when the flight recorder is configured with storage and a signing key

See the [Pipelock documentation](pipelock.md) and the example configuration in `compose.example.ai.yml` for setup instructions.

### Network Security

The `/mcp` endpoint is exposed on the same port as the web UI (default 3000). For hardened deployments:

**Docker Compose:**
- The MCP endpoint is protected by the `MCP_API_TOKEN` but is reachable on port 3000
- For additional security, use Pipelock's MCP reverse proxy (port 8889) which adds scanning
- See `compose.example.ai.yml` for a Pipelock configuration

**Kubernetes:**
- Use NetworkPolicies to restrict access to the MCP endpoint
- Route external agents through Pipelock's MCP reverse proxy

## Production Deployment

For a production-ready setup with security scanning:

1. **Download the example configuration:**

   ```bash
   curl -o compose.ai.yml https://raw.githubusercontent.com/ryanportfolio/Ballast/main/compose.example.ai.yml
   curl -o pipelock.example.yaml https://raw.githubusercontent.com/ryanportfolio/Ballast/main/pipelock.example.yaml
   ```

2. **Set your MCP credentials in `.env`:**

   ```bash
   MCP_API_TOKEN=your-secret-token
   MCP_USER_EMAIL=user@example.com
   ```

3. **Start the stack:**

   ```bash
   docker compose -f compose.ai.yml up -d
   ```

4. **Connect your AI assistant to the Pipelock MCP proxy:**

   ```
   http://your-server:8889
   ```

The Pipelock proxy (port 8889) scans all MCP traffic before forwarding to Ballast's `/mcp` endpoint.

## Connecting AI Assistants

### MCP clients (Claude Desktop, Claude Code, Cursor, VS Code)

Use a client that can send a custom `Authorization: Bearer <MCP_API_TOKEN>` header. Clients that only connect through an OAuth sign-in (such as Claude.ai integrations) cannot connect to Ballast. Point the client at:

- `http://your-server:8889` when using Pipelock, or
- `http://your-server:3000/mcp` for direct access

### Custom Agents

Any AI agent that supports JSON-RPC 2.0 can connect to the MCP endpoint. The agent should:

1. Send a POST request to `/mcp`
2. Include the `Authorization: Bearer <token>` header
3. Use the JSON-RPC 2.0 format for requests
4. Handle the protocol methods: `initialize`, `tools/list`, `tools/call`

### Using MCP without the in-app chat

MCP does not depend on the in-app assistant. To use only your own agent, set the assistant type to **None in app (connect your own agent via MCP)** in **Settings -> Self-Hosting**, or set `ASSISTANT_TYPE=mcp_only` for the whole instance. The chat sidebar and its entry points disappear; `/mcp` and **Settings -> MCP** keep working.

## Troubleshooting

### "unauthorized" error

**Symptom:** Requests return HTTP 401 with "unauthorized"

**Fix:** Verify both are true:

- The bearer token matches `MCP_API_TOKEN`
- `MCP_USER_EMAIL` matches an existing Ballast user

### Static token works, but the user still gets rejected

**Symptom:** Requests return HTTP 401 even though the bearer token matches `MCP_API_TOKEN`

**Fix:** The `MCP_USER_EMAIL` probably does not match an existing user. Check that:
- The email is correct
- The user exists in the database
- There are no typos or extra spaces

### Pipelock connection refused

**Symptom:** AI assistant cannot connect to Pipelock's MCP proxy (port 8889)

**Fix:**
1. Verify Pipelock is running: `docker compose ps pipelock`
2. Check Pipelock health: `docker compose exec pipelock /pipelock healthcheck --addr 127.0.0.1:8888`
3. Verify the port is exposed in your `compose.yml`

## See Also

- [External AI Assistant Configuration](ai.md#external-ai-assistant) - Configure Ballast's chat to use an external agent
- [Pipelock Security Proxy](pipelock.md) - Set up security scanning for MCP traffic
- [Model Context Protocol Specification](https://modelcontextprotocol.io/) - Official MCP documentation
