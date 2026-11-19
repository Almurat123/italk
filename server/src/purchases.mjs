import { readFileSync } from 'node:fs';
import { GatewayError } from './ledger.mjs';

export class PurchaseVerifier {
  constructor(env) { this.env = env; }
  async verifier() {
    if (this.instance) return this.instance;
    const { Environment, SignedDataVerifier } = await import('@apple/app-store-server-library');
    if (!['Sandbox', 'Production'].includes(this.env.APPLE_ENVIRONMENT)) throw new GatewayError('store_not_configured', 503);
    const paths = (this.env.APPLE_ROOT_CERTIFICATES ?? '').split(',').filter(Boolean);
    if (!paths.length || !this.env.APPLE_BUNDLE_ID) throw new GatewayError('store_not_configured', 503);
    const environment = this.env.APPLE_ENVIRONMENT === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
    this.instance = new SignedDataVerifier(paths.map(p => readFileSync(p)), true, environment, this.env.APPLE_BUNDLE_ID,
      this.env.APPLE_ENVIRONMENT === 'Production' ? Number(this.env.APPLE_APP_ID) || undefined : undefined);
    return this.instance;
  }
  async transaction(jws) {
    const verifier = await this.verifier();
    let tx;
    try { tx = await verifier.verifyAndDecodeTransaction(jws); }
    catch { throw new GatewayError('purchase_verification_failed', 403); }
    if (tx.type !== 'Consumable' || !tx.transactionId || !tx.appAccountToken || tx.revocationDate) throw new GatewayError('invalid_purchase', 403);
    const products = JSON.parse(this.env.STORE_PRODUCTS_JSON ?? '{}');
    const quantity = tx.quantity ?? 1;
    const credits = products[tx.productId] * quantity;
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10 || !Number.isSafeInteger(credits) || credits <= 0) throw new GatewayError('unknown_product', 403);
    return { tx, credits };
  }
  async notification(jws) {
    const verifier = await this.verifier();
    try {
      const notice = await verifier.verifyAndDecodeNotification(jws);
      const tx = notice.data?.signedTransactionInfo ? await verifier.verifyAndDecodeTransaction(notice.data.signedTransactionInfo) : null;
      return { notice, tx };
    } catch { throw new GatewayError('notification_verification_failed', 403); }
  }
}
