import { randomUUID, createHash } from 'node:crypto';
import { open, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: File edits need a recoverable preimage without overwriting subsequent user changes.
// Debug Goal: Preserve bounded, owner-scoped file versions and recover only to a new, exclusive path.
// Search Tags: remote agent file checkpoint recovery copy concurrent user edits
// Invariants:
// - Only regular files up to 1 MB are saved; failure to save blocks an overwriting edit.
// - Restore never changes or removes the original file, and requires a separate approval.
// - Checkpoints are visible only to the phone and agent session that created them.
// Failure Modes:
// - Overwriting a current file during rollback can destroy later user edits.
// - A nonexclusive recovery write can overwrite a user's existing recovery file.
export class FileCheckpoints {
  constructor({ db, taskId, phoneId, sessionId, policy }) { Object.assign(this, { db, taskId, phoneId, sessionId, policy }); }

  async capture(file) {
    let handle;
    try { handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    try {
      const before = await handle.stat();
      if (!before.isFile() || before.size > 1_000_000) throw new Error('Cannot safely back up this file: only regular files up to 1 MB are supported.');
      const content = await handle.readFile();
      const after = await handle.stat();
      const current = await stat(file);
      if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || current.ino !== before.ino || current.dev !== before.dev) {
        throw new Error('The file changed during backup. No edit was made.');
      }
      const used = this.db.prepare('SELECT COALESCE(SUM(length(content)), 0) AS bytes FROM file_checkpoints WHERE phone_id=?').get(this.phoneId).bytes;
      if (used + content.length > 25_000_000) throw new Error('Backup storage is full. No edit was made. Delete old completed task records to free space.');
      const id = randomUUID(), digest = createHash('sha256').update(content).digest('hex');
      this.db.prepare('INSERT INTO file_checkpoints(id,task_id,phone_id,session_id,path,content,mode,digest,created_at) VALUES(?,?,?,?,?,?,?,?,?)')
        .run(id, this.taskId, this.phoneId, this.sessionId, file, content, before.mode & 0o777, digest, Date.now());
      return { id, digest, mode: before.mode & 0o777 };
    } finally { await handle.close(); }
  }

  list() {
    return this.db.prepare('SELECT id,path,created_at AS createdAt,length(content) AS bytes FROM file_checkpoints WHERE phone_id=? AND session_id=? ORDER BY created_at DESC LIMIT 100')
      .all(this.phoneId, this.sessionId);
  }

  find(id) {
    return this.db.prepare('SELECT * FROM file_checkpoints WHERE id=? AND phone_id=? AND session_id=?').get(id, this.phoneId, this.sessionId);
  }

  async recover(id) {
    const saved = this.find(id);
    if (!saved) throw new Error('Checkpoint not found in this conversation.');
    const checked = this.policy.check(saved.path);
    if (checked.verdict === 'deny' || checked.path !== saved.path) throw new Error('The original location is protected or has changed.');
    const content = Buffer.from(saved.content);
    if (createHash('sha256').update(content).digest('hex') !== saved.digest) throw new Error('Backup integrity check failed.');
    const target = path.join(path.dirname(saved.path), `${path.basename(saved.path)}.italk-recovered-${id.slice(0, 8)}`);
    const destination = this.policy.check(target);
    if (destination.verdict === 'deny' || destination.path !== target) throw new Error('The recovery location is not allowed.');
    const handle = await open(target, 'wx', saved.mode & 0o666);
    try { await handle.writeFile(content); } finally { await handle.close(); }
    return target;
  }
}
