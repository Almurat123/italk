// Development only: gives an account a subscription row without the App Store, so the cloud path can be tried end to end.
//   node tools/dev-grant.mjs <db path> <email> [days=30] [productId=com.italk.cloud.monthly]
// Refuses to run when NODE_ENV=production.
import { openDb } from '../src/v2/db.mjs';
if (process.env.NODE_ENV === 'production') { console.error('refused: production'); process.exit(1); }
const [path, email, days = '30', product = 'com.italk.cloud.monthly'] = process.argv.slice(2);
const db = openDb(path);
const account = db.prepare('SELECT id FROM accounts WHERE email_norm=?').get(String(email).trim().toLowerCase());
if (!account) { console.error('no such account'); process.exit(1); }
const now = Date.now();
db.prepare(`INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,updated_at) VALUES(?,?,?,?,?,?,?,?,?)
  ON CONFLICT(original_transaction_id) DO UPDATE SET status='active', expires_at=excluded.expires_at, period_start=excluded.period_start, updated_at=excluded.updated_at`)
  .run(`dev-${account.id}`, account.id, product, 'active', 'Development', now, now + Number(days) * 86_400_000, 1, now);
console.log(`granted ${product} to ${email} for ${days} days`);
