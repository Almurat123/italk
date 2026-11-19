# Cloud subscription economics (gateway v2)

Status: arithmetic implemented and enforced in `server/src/v2/plans.mjs` + `quota.mjs`; explained by `server/tools/economics.mjs` (`node tools/economics.mjs [--json]`).
**Not yet true in the real world:** the products do not exist in App Store Connect, no customer has paid, provider prices were fitted to one account balance (±25%), and the commission tier depends on enrolment in Apple's Small Business Program. Treat every ¥ figure as a model, not a result.

## Rules the server enforces
1. **Units.** Money is integer micro-CNY; the user-facing *point* is ¥0.001 of provider cost. Allowances are provider-cost budgets, never token counts, so a model that costs more uses points faster ("用量权重").
2. **Two windows per plan.** A period allowance (month/year) and a weekly allowance counted from the period start. The weekly one stops a single heavy week from spending the whole period; both are checked before a request is sent.
3. **Reserve → settle / release.** Before anything goes to the provider the worst case of the request (every input token a cache miss, the full output allowance, +2,048 reasoning tokens when thinking is on) is reserved. When the provider reports usage the reservation is settled to the actual cost (cache-hit tokens at the cache price); nothing delivered → released; a gateway restart settles what was produced.
4. **Concurrency.** 2 model steps per account at once; per-address/per-email rate limits on sign-in.
5. **Start-up guard.** `Pricing` refuses to start if any plan could spend more than **40 %** of its *net* revenue on provider cost when its whole allowance is used (`maxCostShare`). Raising a provider price in configuration without lowering allowances therefore fails loudly instead of silently losing money.
6. **No free cloud tier.** Local features need no account; cloud models need an active, server-verified subscription (Apple transactions are verified against Apple's chain, bundle id, environment and the buyer's `appAccountToken`). Expired/refunded/revoked ⇒ the app falls back to local models with all local history intact.

## Numbers (defaults in `plans.mjs`, DeepSeek Flash prices ¥1.2 miss / ¥0.12 hit / ¥2.4 out per million tokens)
- A typical agent turn (3,000 input tokens, 70 % cached, 400 output tokens) costs **≈ 2.3 points (¥0.0023)**.
- Net revenue per period = price ÷ 1.06 (VAT) × (1 − commission). Monthly ¥19 → **¥12.55** at 30 % commission, ¥15.24 at 15 %. Annual ¥168 → ¥110.94 / ¥134.72.
- Allowances: monthly 5,000 points (¥5), annual 44,000 points (¥44), weekly 1,800 points (¥1.8) → about **73 typical turns a day** on the monthly plan (53 on the annual plan).

| Case (monthly plan) | Provider cost if the whole allowance is used | Margin per subscriber |
| --- | --- | --- |
| Model prices as fitted, 30 % commission | ¥5.00 (40 % of net) | **¥7.55** |
| Provider doubles its prices, allowances unchanged | ¥10.00 (80 %) | ¥2.55 |
| Provider triples its prices, allowances unchanged | ¥15.00 (120 %) | **−¥2.45** → allowances must be cut (the start-up guard forces this) |
| Same, 15 % commission | ¥5.00 / ¥10.00 / ¥15.00 | ¥10.24 / ¥5.24 / ¥0.24 |
| Subscriber uses 25 % of the allowance (typical) | ¥1.25 | ¥11.30 |

The annual plan has the same shape (¥66.94 worst-case margin at 30 %). It is cheaper per month for the customer but its whole year of allowance is spendable from day one, so the weekly window (¥1.8) is what bounds early burn: the worst first-month cost is 4.3 weeks × ¥1.8 ≈ ¥7.7 against ¥110.94 net.

## What is deliberately not modelled
- App Store refunds (the plan state becomes `refunded`/`revoked`; usage already served stays a cost), chargebacks, grace-period usage, taxes other than the 6 % VAT assumption, currency moves (the provider bills in CNY; the price list for other storefronts is whatever StoreKit shows).
- Infrastructure cost: one small VM/tunnel, SQLite on disk, outbound traffic. Order of ¥100–300/month, shared across all subscribers; break-even is roughly 20–40 paying monthly subscribers at 25 % average use. This is an estimate, not a quote.
- Image/vision input: the default model has none (`images:false`); enabling a vision model needs its own prices and weights.

## Calibration and operations
- Prices were fitted on 2026-10-30 against an account balance change (≈ ¥0.23 for ~127 k cache-miss input, ~346 k cache-hit input and ~23.5 k output tokens) and set ~20 % above the fit. After the first real invoice run `server/tools/calibrate-pricing.py`-style fitting again and update `DEFAULT_PRICING` (or the deployment's pricing file), `verified:true` only once an invoice agrees.
- If a provider raises prices: lower `periodPoints`/`weeklyPoints` (server-side, no app update; the app reads allowances from `/v2/plans` and shows remaining points from `/v2/account`), or change the model weights. Existing subscribers keep their paid period; the new allowance applies from the next window start.
- Watch: share of subscribers above 80 % of their weekly window, average cache-hit ratio (the fit assumes ~70 %), reasoning-token share, 429 `quota_exceeded` per active account, refunds.
- Prices shown to customers come from StoreKit, never from the gateway.
