// Outgoing mail. Nothing is sent unless a mailer is configured; the gateway then reports passwordReset/emailVerification as unavailable.
const SUBJECTS = { 'password-reset': 'iTalk 密码重置验证码', 'verify-email': 'iTalk 邮箱验证码' };
const BODY = {
  'password-reset': (code) => `你的 iTalk 密码重置验证码是 ${code}，30 分钟内有效。如果不是你本人操作，请忽略这封邮件。\n\nYour iTalk password reset code is ${code} (valid for 30 minutes). If you did not ask for it, ignore this message.`,
  'verify-email': (code) => `你的 iTalk 邮箱验证码是 ${code}，24 小时内有效。\n\nYour iTalk e-mail verification code is ${code} (valid for 24 hours).`,
};

/** POSTs JSON to a transactional-mail HTTP API (Resend, Postmark, SES-gateway, …): { from, to, subject, text } with a bearer key. */
export class HttpMailer {
  constructor({ url, key, from, fetcher = fetch }) { Object.assign(this, { url, key, from, fetcher }); }
  async send({ to, template, code }) {
    const response = await this.fetcher(this.url, { method: 'POST', headers: { authorization: `Bearer ${this.key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: this.from, to: [to], subject: SUBJECTS[template], text: BODY[template](code) }) });
    if (!response.ok) throw new Error(`mail_failed_${response.status}`);
  }
}

/** Development only: prints the code to the server log. Never enabled in production. */
export class ConsoleMailer {
  constructor(log = console.log) { this.log = log; }
  async send({ to, template, code }) { this.log(`[mail:${template}] to=${to} code=${code}`); }
}

export function createMailer(env) {
  if (env.MAIL_API_URL && env.MAIL_API_KEY && env.MAIL_FROM) return new HttpMailer({ url: env.MAIL_API_URL, key: env.MAIL_API_KEY, from: env.MAIL_FROM });
  if (env.MAIL_MODE === 'console' && env.NODE_ENV !== 'production') return new ConsoleMailer();
  return null;
}
