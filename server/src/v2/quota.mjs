import { randomUUID } from 'node:crypto';
import { GatewayError, tx } from './db.mjs';
import { MICRO_PER_POINT } from './plans.mjs';

const WEEK = 7 * 86_400_000;
export const GRACE_STATUSES = new Set(['active', 'grace']);

/**
 * Entitlements and usage windows. Every number comes from the database; the phone never decides what it may spend.
 * A subscription has two windows: the billing period (total allowance) and a weekly allowance counted from the period start.
 */
export class Quota {
  constructor(db, pricing, { now = () => Date.now(), reservationTimeoutMs = 30 * 60_000 } = {}) {
    this.db = db; this.pricing = pricing; this.now = now; this.reservationTimeoutMs = reservationTimeoutMs;
  }

  /** The subscription that grants access right now, or null. */
  entitlement(accountId) {
    const t = this.now();
    const rows = this.db.prepare('SELECT * FROM subscriptions WHERE account_id=? ORDER BY expires_at DESC').all(accountId);
    const live = rows.find(r => GRACE_STATUSES.has(r.status) && r.expires_at > t);
    const row = live ?? rows[0] ?? null;
    if (!row) return { status: 'none', plan: null, subscription: null };
    const plan = this.pricing.plan(row.product_id);
    return { status: live ? row.status : (row.expires_at <= t && GRACE_STATUSES.has(row.status) ? 'expired' : row.status), plan, subscription: row, active: Boolean(live && plan) };
  }

  windows(accountId, ent = this.entitlement(accountId)) {
    if (!ent.active) return null;
    const t = this.now(), start = ent.subscription.period_start ?? ent.subscription.expires_at - 30 * 86_400_000, end = ent.subscription.expires_at;
    const week = Math.max(0, Math.floor((t - start) / WEEK));
    const weekStart = start + week * WEEK, weekEnd = Math.min(weekStart + WEEK, end);
    const sum = (from, to) => this.db.prepare("SELECT COALESCE(SUM(CASE WHEN state='reserved' THEN reserved_micro WHEN state='settled' THEN cost_micro ELSE 0 END),0) AS used FROM usage WHERE account_id=? AND created_at>=? AND created_at<?")
      .get(accountId, from, to).used;
    const periodUsed = sum(start, end), weekUsed = sum(weekStart, weekEnd);
    return {
      period: { limitMicro: ent.plan.periodPoints * MICRO_PER_POINT, usedMicro: periodUsed, startsAt: start, resetsAt: end },
      weekly: { limitMicro: ent.plan.weeklyPoints * MICRO_PER_POINT, usedMicro: weekUsed, startsAt: weekStart, resetsAt: weekEnd },
    };
  }

  /** What the client shows: points, not money or tokens. */
  summary(accountId) {
    const ent = this.entitlement(accountId), w = this.windows(accountId, ent);
    const view = (x) => ({ limit: x.limitMicro / MICRO_PER_POINT, used: Math.round(x.usedMicro / MICRO_PER_POINT * 10) / 10, remaining: Math.max(0, Math.round((x.limitMicro - x.usedMicro) / MICRO_PER_POINT * 10) / 10), startsAt: x.startsAt, resetsAt: x.resetsAt });
    return {
      status: ent.status, planId: ent.plan?.productId ?? null, tier: ent.plan?.tier ?? null, planName: ent.plan?.name ?? null,
      periodStart: ent.subscription?.period_start ?? null, periodEnd: ent.subscription?.expires_at ?? null, autoRenew: ent.subscription ? Boolean(ent.subscription.auto_renew) : null,
      concurrency: ent.plan?.concurrency ?? 0, models: ent.plan?.models ?? [], windows: w ? { weekly: view(w.weekly), period: view(w.period) } : null,
    };
  }

  /**
   * Atomically checks both windows, the concurrency limit and the model entitlement, then holds `maxCostMicro` for the request.
   * Nothing is dispatched to a provider before this succeeds.
   */
  reserve(accountId, { model, maxCostMicro, taskId }) {
    return tx(this.db, () => {
      const ent = this.entitlement(accountId);
      if (!ent.active) throw new GatewayError('subscription_required', 402, { status: ent.status });
      if (!ent.plan.models.includes(model)) throw new GatewayError('model_not_in_plan', 403);
      const running = this.db.prepare("SELECT COUNT(*) AS n FROM tasks WHERE account_id=? AND state IN ('queued','running')").get(accountId).n;
      if (running >= ent.plan.concurrency) throw new GatewayError('too_many_concurrent_requests', 429, { limit: ent.plan.concurrency });
      const w = this.windows(accountId, ent);
      for (const [name, x] of [['weekly', w.weekly], ['period', w.period]]) {
        if (x.usedMicro + maxCostMicro > x.limitMicro) {
          throw new GatewayError('quota_exceeded', 429, { window: name, resetsAt: x.resetsAt, remainingPoints: Math.max(0, (x.limitMicro - x.usedMicro) / MICRO_PER_POINT) });
        }
      }
      const id = randomUUID();
      this.db.prepare("INSERT INTO usage(id,account_id,task_id,model,state,reserved_micro,created_at) VALUES(?,?,?,?, 'reserved', ?, ?)").run(id, accountId, taskId ?? null, model, maxCostMicro, this.now());
      return id;
    });
  }

  /** Replaces the hold with the real cost. `estimated` marks usage the provider never reported (connection lost mid-stream). */
  settle(usageId, { input = 0, cachedInput = 0, output = 0, reasoning = 0, estimated = false }) {
    return tx(this.db, () => {
      const row = this.db.prepare('SELECT * FROM usage WHERE id=?').get(usageId);
      if (!row || row.state !== 'reserved') return row ? row.cost_micro : 0;     // idempotent: a second settle changes nothing
      const cost = this.pricing.costMicro(row.model, { input, cachedInput, output });
      this.db.prepare("UPDATE usage SET state='settled', cost_micro=?, input_tokens=?, cached_input_tokens=?, output_tokens=?, reasoning_tokens=?, estimated=?, settled_at=? WHERE id=?")
        .run(cost, input, cachedInput, output, reasoning, estimated ? 1 : 0, this.now(), usageId);
      return cost;
    });
  }

  /** The request never reached the provider (or produced nothing billable): the hold disappears. */
  release(usageId) {
    return this.db.prepare("UPDATE usage SET state='released', settled_at=? WHERE id=? AND state='reserved'").run(this.now(), usageId).changes > 0;
  }

  /** Holds whose task is gone (crash) are settled at what the task is known to have produced, or released if it produced nothing. */
  reconcile() {
    const cutoff = this.now() - this.reservationTimeoutMs;
    const stale = this.db.prepare("SELECT u.id, u.task_id FROM usage u WHERE u.state='reserved' AND u.created_at<? AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.id=u.task_id AND t.state IN ('queued','running'))").all(cutoff);
    for (const u of stale) {
      const produced = u.task_id ? this.db.prepare("SELECT COUNT(*) AS n FROM task_events WHERE task_id=? AND type IN ('delta','reasoning','tool_call')").get(u.task_id).n : 0;
      if (produced === 0) this.release(u.id); else this.settle(u.id, { input: 0, output: 0, estimated: true });
    }
    return stale.length;
  }
}
