# DeepSeek and billing status

Updated: 2026-10-28

The gateway can use the official DeepSeek `deepseek-flash` Chat Completions API
when `MODEL_PROVIDER=deepseek` and the server has an API key. The key is never
returned to the client. The provider currently disables thinking because the
agent relay does not preserve provider reasoning state across tool calls.
The model catalog exposes both `deepseek-flash` and `deepseek-v4-pro` as
separate selectable API endpoints. The official documentation says the Pro
endpoint currently routes to Flash; the UI discloses that routing with an
as-of date instead of claiming an independent Pro deployment. Selection is
validated server-side and the requested endpoint ID is saved in the ledger.

References: https://api-docs.deepseek.com/news/news260910/ and
https://api-docs.deepseek.com/quick_start/pricing. Provider costs and customer
credit prices are distinct. The operator must configure and publish customer
prices and verify provider usage and actual model availability.

The SQLite ledger uses integer credits, authenticated account binding, immutable
request IDs, purchase verification, reservations, and idempotent settlement.
A dispatched request without usage becomes `uncertain`: its hold remains and
the account cannot dispatch another paid request until the operator reconciles
it. The internal ledger can settle verified usage or void the hold with an
audit reason; no customer-facing reconciliation endpoint is exposed.

This is not a production payment system. Account credentials are currently
static operator configuration, not a complete registration, recovery, session
rotation, or device revocation system. Reconciliation is manual; upstream
outages, cancellations, and crashes can leave funds held. StoreKit production
credentials and products, server deployment, TLS termination, durable backup,
monitoring, abuse limits across hosts, and operational reconciliation are not
proven. SQLite startup recovery assumes a single gateway instance. Do not
accept customer funds or promise automatic refunds until these are implemented
and independently verified. Do not put provider keys in an iOS app or commit
them to the repository.
