# Provider integration guidance

Read [architecture](architecture.md) for provider concepts, runtime registry
selection and `Provided` concerns. For a new securities price provider, follow
[the complete workflow](adding-a-securities-provider.md), including response
types, MIC mapping, currency handling, settings encryption, UI, locales and tests.

## Provider logos

A provider's logo comes from [`ProviderLogo`](../../app/components/provider_logo.rb): the
Brandfetch icon for the `domain` in its
[`Provider::Metadata::REGISTRY`](../../app/models/provider/metadata.rb) entry, falling back
to `logo_icon`, then `logo_text` initials on `logo_color`. Anything identifying a provider
renders `render ProviderLogo.new(provider_key: :<x>)` — the `_<x>_item` card on Accounts,
the Bank Sync cards and connection rows, and the connection rows in
`settings/providers/_<x>_panel` — rather than a hand-built badge or the first letter of a
connection name. A panel's setup form and instructions carry no logo.

Give each new provider a registry entry with a brand domain. Only a provider with no single
brand behind it omits the domain and sets `logo_icon` instead.
Institution logos are a separate concept and belong on accounts through
`Account#logo_url`, never on a provider.

## Support diagnostics

When a provider sync/import path encounters a recoverable error, suspicious partial
response or other support-relevant incident, prefer
[`DebugLogEntry.capture`](../../app/models/debug_log_entry.rb) over `Rails.logger.*`
so operators can inspect it in the super-admin `/settings/debug` UI.

- Include `category`, `level`, `message`, `source`, `provider_key` and useful
  structured `metadata`.
- Attach `family` and `account_provider` whenever available so support can filter
  and trace the affected connection. Account/user associations can add context.
- Reserve raw Rails logging for low-value local noise; incidents operators need
  to investigate belong in the debug log.

## Pending transactions and FX metadata

Store provider metadata on `Transaction#extra` under the provider namespace.
[`import_transaction`](../../app/models/account/provider_import_adapter.rb) deep-merges
that hash, so a key the provider stops sending keeps its previous value. A provider
that owns its namespace outright passes `replace_extra_namespaces: ["<key>"]`. When the
incoming payload includes that namespace, the existing namespace is replaced, so omitted
nested fields are removed. Send the provider's current namespace snapshot on every sync.
[`Transaction#pending?` and pending scopes](../../app/models/transaction.rb) share
`PENDING_PROVIDERS`; that constant is the current list of supported namespaces
(only `simplefin` in Ballast). The UI shows a Pending
badge when `transaction.pending?` is true. A provider that supplies no pending
metadata produces no badge; manual/CSV imports have no pending concept.

| Provider | Detection and storage |
| --- | --- |
| SimpleFIN | [`SimplefinEntry::Processor.pending?`](../../app/models/simplefin_entry/processor.rb) accepts an explicitly truthy `pending` flag, or `posted` equal to numeric `0` or string `"0"` with a present, positive `transacted_at` timestamp. A blank/missing `posted` value does **not** imply pending. Writes `extra["simplefin"]["pending"]` as true or false so a posted update clears stale pending metadata. |

SimpleFIN additionally stores `extra["simplefin"]["fx_from"]` when transaction and
account currencies differ, and `fx_date` from the transacted date with posted-date
fallback. Preserve these namespaced fields and the existing conversion behavior.

Pending inclusion is provider- and layer-specific:

- **SimpleFIN:** the [initializer](../../config/initializers/simplefin.rb) defaults
  `config.x.simplefin.include_pending` to true. The
  [importer](../../app/models/simplefin_item/importer.rb) resolves an explicit
  `pending:` argument first, then a present `SIMPLEFIN_INCLUDE_PENDING` environment
  value, then `Setting.syncs_include_pending`. The entry processor also checks the
  environment/Setting choice before importing cached pending payloads.
  `SIMPLEFIN_INCLUDE_PENDING=0` disables the environment-controlled path.
  The [low-level provider](../../app/models/provider/simplefin.rb) does not resolve
  these settings: it adds `pending=1` only for a truthy argument, and otherwise
  omits the parameter. Do not send `pending=0`; bridges can interpret its presence
  as inclusion.
- **Shared setting:** [`Setting.syncs_include_pending`](../../app/models/setting.rb)
  defaults true when `SIMPLEFIN_INCLUDE_PENDING` is absent. Its initial default is
  computed from that environment value; a persisted runtime setting can differ. Do
  not infer effective importer behavior from an initializer alone.

## Exchange rate providers

Exchange rate providers include
[`Provider::ExchangeRateConcept`](../../app/models/provider/exchange_rate_concept.rb),
which validates their responses: a rate that `ExchangeRate.valid_rate?` rejects
(zero, negative, NaN, infinite or missing) turns a single lookup into a failed
response and is dropped from a series, with a `DebugLogEntry` in the
`exchange_rates` category. Providers do not need their own check. A database
constraint on `exchange_rates.rate` rejects anything that still gets through.

## Transaction naming

Where a provider supplies both a cleaned merchant name and the bank's own
description, combine them rather than choosing one:
[`SimplefinEntry::Processor`](../../app/models/simplefin_entry/processor.rb) emits
`"#{payee} - #{description}"` when both are present and differ.

The merchant name alone collapses distinct transactions into one name, and
[rules](../../app/models/rule/condition.rb) match on `transaction_name`, so the
collapse removes the only signal that could separate them. Merchant records are
built from the cleaned name on a separate path, so grouping is unaffected.

SimpleFIN has always emitted the combined form, so its rules were written against
it. If another provider starts combining names after its rules were written, an
`=` or `!=` rule on the merchant name would silently stop or start matching:
`transaction_name` is a text filter
([`condition_filter.rb`](../../app/models/rule/condition_filter.rb)) with no
substring tolerance on those two operators. Gate such a change to that provider's
rows rather than widening the rule engine generally.

## Raw payload debugging

Raw debugging is default-off. `SIMPLEFIN_DEBUG_RAW=1` enables the importer's raw
response logging through `Rails.configuration.x.simplefin.debug_raw`. It has no
local-only environment gate, and the dump contains PII.
