// Plans, model prices and the arithmetic that keeps subscriptions profitable. Everything here is configuration with defaults;
// nothing is a promise to customers until the product ids and prices exist in App Store Connect.
//
// UNITS. Money is integer micro-CNY (1e-6 ¥) because the provider bills in CNY. The user-facing "point" is ¥0.001 (1,000 micro-CNY):
// a typical chat turn costs 1–5 points. Plan allowances are provider-cost budgets in points, never token counts.

export const MICRO_PER_POINT = 1000;

/**
 * Provider prices, CNY per million tokens. DeepSeek flash was calibrated against the account balance on 2026-10-30
 * (≈¥0.23 spent over a mix of ~127k cache-miss input, ~346k cache-hit input and ~23.5k output tokens); the figures below sit ~20%
 * above the fit on purpose. Re-run server/tools/calibrate-pricing.py after any provider price change and when invoices differ.
 */
export const DEFAULT_PRICING = {
  verified: false,
  note: 'calibrated against account balance 2026-10-30 (±25%), set 20% above the fit; confirm with the provider invoice',
  models: {
    'deepseek-flash': { name: 'DeepSeek V4.1 Flash', developer: 'DeepSeek', inputMiss: 1.2, inputHit: 0.12, output: 2.4, contextTokens: 128000, tools: true, reasoning: true, images: false },
  },
};

/**
 * Allowances are provider-cost budgets in points (¥0.001). The numbers follow from net revenue:
 *   net per period = price ÷ (1 + VAT) × (1 − App Store commission)     [conservative: 30% commission, 6% VAT]
 *   period budget  = net × maxCostShare                                  [≤ 40% of net revenue, so a fully used plan still earns]
 * ¥19/month → net ≈ ¥12.5 → budget ≈ ¥5.0 (5,000 points). Annual at ¥168 → net ≈ ¥111 → budget ≈ ¥44 (44,000 points).
 * The weekly allowance stops one heavy week from spending the whole period.
 */
export const DEFAULT_PLANS = [
  { productId: 'com.italk.cloud.monthly', tier: 'plus', period: 'monthly', name: 'iTalk 云端 · 月度', priceCNY: 19, periodPoints: 5000, weeklyPoints: 1800, concurrency: 2, models: ['deepseek-flash'] },
  { productId: 'com.italk.cloud.annual', tier: 'plus', period: 'annual', name: 'iTalk 云端 · 年度', priceCNY: 168, periodPoints: 44000, weeklyPoints: 1800, concurrency: 2, models: ['deepseek-flash'] },
];

export const ECONOMICS = { vat: 0.06, commission: 0.30, maxCostShare: 0.40, cnyPerUsd: 7.2 };

export function netRevenueCNY(priceCNY, e = ECONOMICS) { return priceCNY / (1 + e.vat) * (1 - e.commission); }

/** Worst-case margin of a plan: revenue minus the provider cost if every allowance point is spent. */
export function planMargin(plan, e = ECONOMICS) {
  const net = netRevenueCNY(plan.priceCNY, e);
  const worstCost = plan.periodPoints * MICRO_PER_POINT / 1e6;
  return { netCNY: +net.toFixed(2), worstCaseCostCNY: +worstCost.toFixed(2), worstCaseMarginCNY: +(net - worstCost).toFixed(2), costShare: +(worstCost / net).toFixed(3) };
}

export class Pricing {
  constructor(pricing = DEFAULT_PRICING, plans = DEFAULT_PLANS) {
    this.pricing = pricing; this.plans = plans;
    for (const plan of plans) {
      const m = planMargin(plan);
      if (m.costShare > ECONOMICS.maxCostShare + 1e-9) throw new Error(`plan ${plan.productId} can spend ${(m.costShare * 100).toFixed(0)}% of its net revenue on provider cost (limit ${ECONOMICS.maxCostShare * 100}%)`);
    }
  }
  model(id) { return this.pricing.models[id] ?? null; }
  plan(productId) { return this.plans.find(p => p.productId === productId) ?? null; }

  /** Actual provider cost in micro-CNY, rounded up. `cachedInput` is the cache-hit part of `input`. */
  costMicro(modelId, { input = 0, cachedInput = 0, output = 0 }) {
    const m = this.model(modelId);
    if (!m) throw new Error(`unknown model ${modelId}`);
    const miss = Math.max(0, input - cachedInput);
    return Math.ceil(miss * m.inputMiss + cachedInput * m.inputHit + output * m.output);
  }
  /** Worst case for a request: every input token a cache miss, the full output allowance used. */
  maxCostMicro(modelId, { inputTokens, maxOutput }) { return this.costMicro(modelId, { input: inputTokens, cachedInput: 0, output: maxOutput }); }

  /** Cost of a model relative to the cheapest baseline ("用量权重"): average of input-miss and output price ratios. */
  usageWeight(modelId) {
    const base = this.model('deepseek-flash') ?? Object.values(this.pricing.models)[0], m = this.model(modelId);
    return +(((m.inputMiss + m.output) / (base.inputMiss + base.output))).toFixed(2);
  }
}

/** Rough token estimate for budgeting a request before it is sent (never used for billing): CJK ≈ 1 token/char, other text ≈ 4 chars/token. */
export function estimateTokens(text) {
  let cjk = 0, other = 0;
  for (const ch of String(text)) { const c = ch.codePointAt(0); if ((c >= 0x3400 && c <= 0x9fff) || (c >= 0x3040 && c <= 0x30ff) || (c >= 0xac00 && c <= 0xd7af)) cjk++; else other++; }
  return Math.ceil(cjk * 1.1 + other / 3.6);
}
