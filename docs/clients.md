# Ballast Clients

Ballast is centered on a Rails server. Every client connects to that server and
uses the same accounts, users, authentication rules, and financial data. A
client can be a browser, an automation script, or an LLM agent using Ballast's MCP
endpoint. Ballast has no mobile or desktop app.

Use this guide to choose the right entry point for a person, device, or
integration.

## Client overview

| Client | Best for | Status | Entry point |
| --- | --- | --- | --- |
| Web app | Full everyday use, administration, and self-hosted access from any modern browser. | Primary client | Run the Rails app and visit the server URL. For local development, use `bin/dev` and open `http://localhost:3000`. |
| LLM agents and assistants | Claude Desktop, GPT agents, local agents, or custom tools that need structured access to Ballast data. | MCP endpoint for external AI clients | See [MCP Server for External AI Assistants](hosting/mcp.md). |
| Custom API clients | Scripts, services, importer experiments, dashboards, or other integrations. | HTTP API | See the OpenAPI spec at [docs/api/openapi.yaml](api/openapi.yaml) and endpoint guides such as [docs/api/transactions.md](api/transactions.md). |

## Web app

The web app is the complete Ballast experience. It is the right default when a
person wants to use Ballast directly, manage settings, connect providers, review
transactions, or work with features that the API and MCP do not cover.

For self-hosting, start with the [Docker hosting guide](hosting/docker.md). For
local development, run the Rails app and visit the local server URL:

```sh
bin/dev
```

```text
http://localhost:3000
```

## LLM agents and MCP clients

LLM agents are clients too. Ballast exposes a Model Context Protocol endpoint for
external assistants and agent runtimes that need structured access to financial
data.

Use MCP when a person wants an assistant such as Claude Desktop, a GPT agent, or
a custom local agent to query Ballast directly instead of copying data into a chat
window. MCP access is configured server-side with a bearer token and a specific
Ballast user email.

Because this gives the assistant read access to that user's family data, treat
the MCP token like a production secret and only connect assistants and providers
the user trusts.

See [docs/hosting/mcp.md](hosting/mcp.md) for setup and protocol details.

## Custom API clients

Custom clients can call Ballast's HTTP API directly. This is the right path for
scripts, services, import experiments, dashboards, and integrations that do not
need an MCP-compatible agent interface.

API requests authenticate with a user-generated `X-Api-Key` header.

Start with the OpenAPI spec at [docs/api/openapi.yaml](api/openapi.yaml) and
endpoint guides such as [docs/api/transactions.md](api/transactions.md).

## Choosing a client

- Start with the web app when a person needs the complete Ballast experience.
- Use MCP for LLM agents and assistant runtimes.
- Use the HTTP API for custom software integrations.

All clients should connect to a Ballast server the user controls or trusts. API and
MCP clients do not replace the server; they are different ways to access it.

## Cash flow reporting through the API

Read monthly server-calculated totals and the daily spending comparison using
[`GET /api/v1/cash_flow`](api/openapi.yaml). API clients should
use these values instead of rebuilding Ballast's reporting rules from transactions.

Structural node `name` values are fallback labels; clients should localize
`cash_flow`, `surplus`, `deficit`, and `invested` by `kind` at the presentation boundary.

`include` and `view` are mutually exclusive; combining them returns `422 invalid_view`.

Request `include=sankey` to append category nodes and links to the monthly
summary. For arbitrary date filters, request
`view=sankey&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD` to receive only the graph
and its currency, time zone, as-of date, and inclusive period. This avoids building
a daily series for long date ranges. The default monthly response is unchanged.

Graph values are decimal strings in family currency, with stable node IDs and
zero-based link indices. Refunds are netted within each category; parent direct
amounts exclude children before each direction is grouped. Graph income and
spending can therefore differ from the gross monthly figures, while net savings
agrees. Surplus and deficit nodes balance the central flow. Clients own layout,
formatting, and structural colors; all financial aggregation stays on Ballast.

The public endpoint uses the standard API-key authentication and does not
accept browser sessions. Responses are private and not HTTP-cacheable.

The Turbo dashboard fetches `/dashboard/cash_flow` through a normal web controller,
with session authentication, onboarding checks, and the current user's preview
gate. It honors the signed-in user's finance-account scope. Both
endpoints use `IncomeStatement::CashFlowGraph` and `IncomeStatement::Sankey`, sharing
the graph representation and aggregation without sharing authentication paths.

The web dashboard keeps its original Sankey unchanged and renders the new
server-calculated chart directly below it only for users with preview features
enabled.
