import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb, tx, GatewayError } from '../../src/v2/db.mjs';
import { Accounts, hashPassword, verifyPassword } from '../../src/v2/auth.mjs';
import { Pricing, DEFAULT_PRICING, DEFAULT_PLANS, planMargin, ECONOMICS, MICRO_PER_POINT } from '../../src/v2/plans.mjs';
import { Quota } from '../../src/v2/quota.mjs';

const fast = { N: 1 << 10, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
function setup(now = () => 1_800_000_000_000) {
  const db = openDb(':memory:');
  const accounts = new Accounts(db, { now, scryptParams: fast });
  const pricing = new Pricing();
  const quota = new Quota(db, pricing, { now });
  return { db, accounts, pricing, quota, now };
}
const rejects = async (promise, code) => assert.rejects(promise, e => e instanceof GatewayError && e.code === code, `expected ${code}`);
function subscribe(db, accountId, { productId = 'com.italk.cloud.monthly', start, end, status = 'active', original = 'orig-' + Math.random() }) {
  db.prepare('INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,updated_at) VALUES(?,?,?,?,?,?,?,?,?)')
    .run(original, accountId, productId, status, 'Sandbox', start, end, 1, start);
}

test('passwords are salted scrypt hashes and verify only the right password', async () => {
  const a = await hashPassword('correct horse', fast), b = await hashPassword('correct horse', fast);
  assert.notEqual(a, b);
  assert.ok(await verifyPassword('correct horse', a));
  assert.ok(!(await verifyPassword('wrong horse', a)));
});

test('register, login, sessions, profile, avatar, password change and deletion', async () => {
  const { accounts, db } = setup();
  const reg = await accounts.register({ email: ' Ada@Example.com ', password: 'a-long-password', displayName: '艾达', device: { name: 'iPhone', platform: 'ios' }, ip: '1.1.1.1' });
  assert.equal(reg.account.email, 'Ada@Example.com'); assert.equal(reg.account.displayName, '艾达');
  assert.ok(accounts.authenticate(reg.session.token));
  await rejects(accounts.register({ email: 'ada@example.com', password: 'another-password', ip: '1.1.1.2' }), 'email_taken');
  await rejects(accounts.register({ email: 'bad', password: 'another-password', ip: '1.1.1.3' }), 'invalid_email');
  await rejects(accounts.register({ email: 'b@example.com', password: 'short', ip: '1.1.1.4' }), 'weak_password');
  const login = await accounts.login({ email: 'ADA@example.com', password: 'a-long-password', ip: '2.2.2.2' });
  assert.equal(login.account.id, reg.account.id);
  await rejects(accounts.login({ email: 'ada@example.com', password: 'nope-nope-nope', ip: '2.2.2.2' }), 'invalid_credentials');
  assert.equal(accounts.sessions(reg.account.id).length, 2);
  assert.equal(accounts.authenticate('x'.repeat(40)), null);

  assert.equal(accounts.updateProfile(reg.account.id, { displayName: '新名字' }).displayName, '新名字');
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(100)]);
  assert.ok(accounts.setAvatar(reg.account.id, png).hasAvatar);
  assert.equal(accounts.avatar(reg.account.id).type, 'image/png');
  assert.throws(() => accounts.setAvatar(reg.account.id, Buffer.from('not an image at all')), e => e.code === 'unsupported_image');
  assert.throws(() => accounts.setAvatar(reg.account.id, Buffer.concat([png, Buffer.alloc(600 * 1024)])), e => e.code === 'image_too_large');

  await accounts.changePassword(reg.account.id, { current: 'a-long-password', next: 'a-new-password' }, login.session.token ? accounts.authenticate(login.session.token).sessionId : undefined);
  assert.equal(accounts.authenticate(reg.session.token), null, 'other sessions end when the password changes');
  assert.ok(accounts.authenticate(login.session.token));

  await rejects(accounts.deleteAccount(reg.account.id, { password: 'wrong-password' }), 'invalid_credentials');
  await accounts.deleteAccount(reg.account.id, { password: 'a-new-password' });
  assert.equal(accounts.authenticate(login.session.token), null);
  await rejects(accounts.login({ email: 'ada@example.com', password: 'a-new-password', ip: '3.3.3.3' }), 'invalid_credentials');
  const row = db.prepare('SELECT email, display_name, avatar FROM accounts WHERE id=?').get(reg.account.id);
  assert.equal(row.display_name, ''); assert.equal(row.avatar, null); assert.ok(row.email.startsWith('deleted-'));
  // the email can be registered again after deletion
  await accounts.register({ email: 'ada@example.com', password: 'fresh-password', ip: '4.4.4.4' });
});

test('failed logins are rate limited per email and per address', async () => {
  const { accounts } = setup();
  await accounts.register({ email: 'a@example.com', password: 'a-long-password', ip: '9.9.9.9' });
  for (let i = 0; i < 8; i++) await rejects(accounts.login({ email: 'a@example.com', password: 'bad-password-' + i, ip: '5.5.5.5' }), 'invalid_credentials');
  await rejects(accounts.login({ email: 'a@example.com', password: 'a-long-password', ip: '6.6.6.6' }), 'too_many_attempts');
});

test('sessions expire and slide', async () => {
  let t = 1_800_000_000_000;
  const { accounts } = setup(() => t);
  const { session } = await accounts.register({ email: 'a@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  t += 2 * 86_400_000; assert.ok(accounts.authenticate(session.token));
  t += 91 * 86_400_000; assert.equal(accounts.authenticate(session.token), null);
});

test('plans can never spend more than the allowed share of their net revenue', () => {
  for (const plan of DEFAULT_PLANS) {
    const m = planMargin(plan);
    assert.ok(m.costShare <= ECONOMICS.maxCostShare + 1e-9, `${plan.productId} ${JSON.stringify(m)}`);
    assert.ok(m.worstCaseMarginCNY > 0);
  }
  assert.throws(() => new Pricing(DEFAULT_PRICING, [{ ...DEFAULT_PLANS[0], periodPoints: 9000 }]), /can spend/);
});

test('cost uses cache-hit, cache-miss and output prices and rounds up', () => {
  const p = new Pricing();
  const cost = p.costMicro('deepseek-flash', { input: 10_000, cachedInput: 8_000, output: 500 });
  assert.equal(cost, Math.ceil(2000 * 1.2 + 8000 * 0.12 + 500 * 2.4));
  assert.equal(p.usageWeight('deepseek-flash'), 1);
});

test('reservation → settle charges the real cost and frees the unused hold', async () => {
  const { db, accounts, quota, pricing, now } = setup();
  const { account } = await accounts.register({ email: 'q@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  await rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 1000 })), 'subscription_required');
  subscribe(db, account.id, { start: now() - 86_400_000, end: now() + 29 * 86_400_000 });
  const hold = pricing.maxCostMicro('deepseek-flash', { inputTokens: 3000, maxOutput: 800 });
  const id = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: hold });
  const during = quota.summary(account.id);
  assert.equal(during.windows.weekly.used, Math.round(hold / MICRO_PER_POINT * 10) / 10);
  const cost = quota.settle(id, { input: 3000, cachedInput: 2000, output: 200 });
  assert.ok(cost < hold);
  assert.equal(quota.settle(id, { input: 99999, output: 99999 }), cost, 'settling twice changes nothing');
  const after = quota.summary(account.id);
  assert.equal(after.windows.weekly.used, Math.round(cost / MICRO_PER_POINT * 10) / 10);
  const id2 = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: hold });
  assert.ok(quota.release(id2));
  assert.equal(quota.summary(account.id).windows.weekly.used, after.windows.weekly.used, 'a released hold costs nothing');
});

test('weekly and period allowances are both enforced, with the right reset time', async () => {
  let t = 1_800_000_000_000;
  const { db, accounts, quota } = setup(() => t);
  const { account } = await accounts.register({ email: 'w@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  const start = t, end = t + 30 * 86_400_000;
  subscribe(db, account.id, { start, end });
  const weekly = DEFAULT_PLANS[0].weeklyPoints * MICRO_PER_POINT;
  const first = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: weekly - 10 });
  quota.settle(first, { input: 0, output: 0 }); // spend nothing real so only the reservation matters below
  const big = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: weekly - 10 });
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 20 })),
    e => e.code === 'quota_exceeded' && e.detail.window === 'weekly' && e.detail.resetsAt === start + 7 * 86_400_000);
  quota.release(big);
  // next week the weekly window resets
  t += 7 * 86_400_000 + 1000;
  assert.ok(quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: weekly - 10 }));
});

test('period allowance binds even when each week is within its own limit', async () => {
  let t = 1_800_000_000_000;
  const { db, accounts, quota } = setup(() => t);
  const { account } = await accounts.register({ email: 'p@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  subscribe(db, account.id, { start: t, end: t + 30 * 86_400_000 });
  const weekly = DEFAULT_PLANS[0].weeklyPoints * MICRO_PER_POINT, period = DEFAULT_PLANS[0].periodPoints * MICRO_PER_POINT;
  let spent = 0, weeks = 0;
  while (spent + weekly <= period) {
    const id = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: weekly });
    db.prepare("UPDATE usage SET state='settled', cost_micro=reserved_micro WHERE id=?").run(id);
    spent += weekly; weeks++; t += 7 * 86_400_000;
  }
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: weekly })), e => e.code === 'quota_exceeded' && e.detail.window === 'period');
  assert.ok(weeks >= 2);
});

test('concurrency limit counts queued and running tasks only', async () => {
  const { db, accounts, quota, now } = setup();
  const { account } = await accounts.register({ email: 'c@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  subscribe(db, account.id, { start: now(), end: now() + 30 * 86_400_000 });
  for (let i = 0; i < 2; i++) db.prepare("INSERT INTO tasks(id,account_id,idem_key,request_digest,state,model,created_at) VALUES(?,?,?,?,?,?,?)").run('t' + i, account.id, 'k' + i, 'd', 'running', 'deepseek-flash', now());
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 100 })), e => e.code === 'too_many_concurrent_requests');
  db.prepare("UPDATE tasks SET state='completed' WHERE id='t0'").run();
  assert.ok(quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 100 }));
});

test('expired, revoked and out-of-plan access is refused', async () => {
  const { db, accounts, quota, now } = setup();
  const { account } = await accounts.register({ email: 'e@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  subscribe(db, account.id, { start: now() - 40 * 86_400_000, end: now() - 10 * 86_400_000, original: 'o1' });
  assert.equal(quota.entitlement(account.id).status, 'expired');
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 1 })), e => e.code === 'subscription_required');
  subscribe(db, account.id, { start: now(), end: now() + 10 * 86_400_000, status: 'revoked', original: 'o2' });
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 1 })), e => e.code === 'subscription_required');
  db.prepare("UPDATE subscriptions SET status='active' WHERE original_transaction_id='o2'").run();
  await assert.rejects(Promise.resolve().then(() => quota.reserve(account.id, { model: 'some-other-model', maxCostMicro: 1 })), e => e.code === 'model_not_in_plan');
});

test('reconcile releases abandoned holds and settles ones that produced output', async () => {
  let t = 1_800_000_000_000;
  const { db, accounts, quota } = setup(() => t);
  const { account } = await accounts.register({ email: 'r@example.com', password: 'a-long-password', ip: '1.1.1.1' });
  subscribe(db, account.id, { start: t, end: t + 30 * 86_400_000 });
  for (const id of ['gone', 'partial']) db.prepare("INSERT INTO tasks(id,account_id,idem_key,request_digest,state,model,created_at) VALUES(?,?,?,?,?,?,?)").run(id, account.id, id, 'd', 'failed', 'deepseek-flash', t);
  db.prepare("INSERT INTO task_events(task_id,seq,type,payload,created_at) VALUES('partial',1,'delta','{}',?)").run(t);
  const a = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 500, taskId: 'gone' });
  const b = quota.reserve(account.id, { model: 'deepseek-flash', maxCostMicro: 500, taskId: 'partial' });
  t += 31 * 60_000;
  assert.equal(quota.reconcile(), 2);
  const states = Object.fromEntries(db.prepare('SELECT id, state, estimated FROM usage').all().map(r => [r.id, r]));
  assert.equal(states[a].state, 'released'); assert.equal(states[b].state, 'settled'); assert.equal(states[b].estimated, 1);
});
