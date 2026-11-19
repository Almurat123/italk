#!/usr/bin/env node
// Prints the worst-case and expected economics of the subscription plans under different assumptions.
//   node tools/economics.mjs            human-readable tables
//   node tools/economics.mjs --json     the same numbers as JSON (for review / spreadsheets)
// Nothing here is billing logic: the gateway enforces allowances in v2/quota.mjs; this tool explains why those numbers are safe.
import { DEFAULT_PLANS, DEFAULT_PRICING, ECONOMICS, MICRO_PER_POINT, Pricing, netRevenueCNY } from '../src/v2/plans.mjs';

const pricing = new Pricing(DEFAULT_PRICING, DEFAULT_PLANS);
const scenarios = {
  'App Store standard (30%)': { ...ECONOMICS },
  'Small Business Program (15%)': { ...ECONOMICS, commission: 0.15 },
  'Subscription after year 1 (15%)': { ...ECONOMICS, commission: 0.15 },
};
// What a "typical" agent turn costs: 3,000 input tokens (70% served from the provider cache), 400 output tokens.
const typical = { input: 3000, cachedInput: 2100, output: 400 };
const turnMicro = pricing.costMicro('deepseek-flash', typical);

const rows = [];
for (const plan of DEFAULT_PLANS) {
  for (const [label, e] of Object.entries(scenarios)) {
    for (const priceFactor of [1, 1.5, 2, 3]) {
      const net = netRevenueCNY(plan.priceCNY, e);
      const worst = plan.periodPoints * MICRO_PER_POINT / 1e6 * priceFactor;        // provider raises its price after the allowance was set
      const days = plan.period === 'annual' ? 365 : 30;
      const turnsAllowed = Math.floor(plan.periodPoints * MICRO_PER_POINT / turnMicro);
      rows.push({ plan: plan.productId, scenario: label, providerPriceFactor: priceFactor, priceCNY: plan.priceCNY, netCNY: +net.toFixed(2), worstCaseCostCNY: +worst.toFixed(2),
                  worstCaseMarginCNY: +(net - worst).toFixed(2), costShare: +(worst / net).toFixed(2), turnsPerPeriod: turnsAllowed, turnsPerDay: +(turnsAllowed / days).toFixed(1) });
    }
  }
}
const usage = [0.1, 0.25, 0.5, 1].map(fraction => ({ fractionOfAllowanceUsed: fraction, ...Object.fromEntries(DEFAULT_PLANS.map(p => [p.productId, +(netRevenueCNY(p.priceCNY) - p.periodPoints * MICRO_PER_POINT / 1e6 * fraction).toFixed(2)])) }));

if (process.argv.includes('--json')) { console.log(JSON.stringify({ typicalTurn: { ...typical, costMicroCNY: turnMicro, points: +(turnMicro / MICRO_PER_POINT).toFixed(2) }, rows, marginByUsage: usage }, null, 2)); process.exit(0); }
console.log(`Typical agent turn (3,000 in / 70% cached, 400 out) costs ${(turnMicro / MICRO_PER_POINT).toFixed(2)} points (¥${(turnMicro / 1e6).toFixed(4)}).\n`);
const pad = (s, n) => String(s).padEnd(n);
console.log(pad('plan', 26) + pad('commission scenario', 34) + pad('provider ×', 11) + pad('net ¥', 8) + pad('worst ¥', 9) + pad('margin ¥', 10) + pad('cost share', 11) + 'turns/day');
for (const r of rows) console.log(pad(r.plan, 26) + pad(r.scenario, 34) + pad(r.providerPriceFactor, 11) + pad(r.netCNY, 8) + pad(r.worstCaseCostCNY, 9) + pad(r.worstCaseMarginCNY, 10) + pad(r.costShare, 11) + r.turnsPerDay);
console.log('\nMargin (¥ per subscriber per period) if the person uses only a fraction of the allowance:');
for (const u of usage) console.log(`  ${pad(u.fractionOfAllowanceUsed * 100 + '%', 6)} ` + DEFAULT_PLANS.map(p => `${p.productId}: ¥${u[p.productId]}`).join('   '));
