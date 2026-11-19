import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, chmodSync, statSync, symlinkSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { openDb } from '../src/db.mjs';
import { PathPolicy } from '../src/policy.mjs';
import { MacTools } from '../src/tools.mjs';
import { FileCheckpoints } from '../src/agent/file-checkpoints.mjs';
import { Tasks } from '../src/tasks.mjs';
import { scratch } from './helpers.mjs';

test('file recovery is scoped, requires approval, and never replaces subsequent edits', async () => {
  const sc = scratch('italk-backup-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true });
  const file = path.join(cwd, 'draft.txt');
  writeFileSync(file, 'before');
  const db = openDb();
  db.exec('PRAGMA foreign_keys=OFF');
  const policy = new PathPolicy({ roots: [home], home });
  const options = { db, taskId: 'task', phoneId: 'phone', sessionId: 'session', policy };
  const checkpoints = new FileCheckpoints(options);
  const tools = new MacTools({ policy, mode: 'acceptEdits', cwd, checkpoints });
  try {
    const result = await tools.run('write_file', { path: 'draft.txt', content: 'agent edit' });
    assert.equal(result.ok, true);
    assert.equal(readFileSync(file, 'utf8'), 'agent edit');
    const [backup] = checkpoints.list();
    assert.ok(backup.id);
    assert.equal(tools.plan('checkpoint_recover', { id: backup.id }).access, 'ask');
    assert.equal(new FileCheckpoints({ ...options, phoneId: 'other' }).find(backup.id), undefined);
    assert.equal(new FileCheckpoints({ ...options, sessionId: 'other' }).find(backup.id), undefined);
    const restricted = new PathPolicy({ roots: [home], home, extraDeny: [file] });
    await assert.rejects(new FileCheckpoints({ ...options, policy: restricted }).recover(backup.id), /protected/);
    writeFileSync(file, 'user edit after the agent');
    const recovered = await checkpoints.recover(backup.id);
    assert.equal(readFileSync(recovered, 'utf8'), 'before');
    assert.equal(readFileSync(file, 'utf8'), 'user edit after the agent');
    await assert.rejects(checkpoints.recover(backup.id), /EEXIST/);
    assert.equal(readFileSync(recovered, 'utf8'), 'before');
  } finally { db.close(); sc.cleanup(); }
});

test('backup size limits fail closed before an existing file is overwritten', async () => {
  const sc = scratch('italk-backup-size-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true });
  const file = path.join(cwd, 'large.txt'), original = 'a'.repeat(1_000_001);
  writeFileSync(file, original);
  const db = openDb(); db.exec('PRAGMA foreign_keys=OFF');
  const policy = new PathPolicy({ roots: [home], home });
  const checkpoints = new FileCheckpoints({ db, taskId: 'task', phoneId: 'phone', sessionId: 'session', policy });
  const tools = new MacTools({ policy, mode: 'acceptEdits', cwd, checkpoints });
  try {
    await assert.rejects(tools.run('write_file', { path: 'large.txt', content: 'replacement' }), /Cannot safely back up/);
    assert.equal(readFileSync(file, 'utf8'), original);
    assert.equal(checkpoints.list().length, 0);
  } finally { db.close(); sc.cleanup(); }
});

test('a concurrent edit detected after backup is not overwritten and leaves no temporary file', async () => {
  const sc = scratch('italk-backup-race-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true });
  const file = path.join(cwd, 'draft.txt'); writeFileSync(file, 'original'); chmodSync(file, 0o600);
  const db = openDb(); db.exec('PRAGMA foreign_keys=OFF');
  const policy = new PathPolicy({ roots: [home], home });
  const store = new FileCheckpoints({ db, taskId: 'task', phoneId: 'phone', sessionId: 'session', policy });
  const capture = store.capture.bind(store);
  store.capture = async target => { const saved = await capture(target); writeFileSync(file, 'human edit'); return saved; };
  const tools = new MacTools({ policy, mode: 'acceptEdits', cwd, checkpoints: store });
  try {
    await assert.rejects(tools.run('write_file', { path: 'draft.txt', content: 'agent edit' }), /file changed after backup/);
    assert.equal(readFileSync(file, 'utf8'), 'human edit');
    assert.deepEqual(readdirSync(cwd), ['draft.txt']);
    assert.equal(statSync(file).mode & 0o777, 0o600);
  } finally { db.close(); sc.cleanup(); }
});

test('an approved path changed to a protected symlink is refused before any write', async () => {
  const sc = scratch('italk-backup-link-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true }); mkdirSync(path.join(home, '.ssh'));
  const safe = path.join(cwd, 'safe.txt'), secret = path.join(home, '.ssh', 'id_rsa'), link = path.join(cwd, 'link.txt');
  writeFileSync(safe, 'safe'); writeFileSync(secret, 'private'); symlinkSync(safe, link);
  const policy = new PathPolicy({ roots: [home], home });
  const tools = new MacTools({ policy, mode: 'ask', cwd });
  try {
    const args = { path: 'link.txt', content: 'changed' }, plan = tools.plan('write_file', args);
    assert.equal(plan.access, 'ask');
    unlinkSync(link); symlinkSync(secret, link);
    await assert.rejects(tools.run('write_file', args, { plan }), /location changed/);
    assert.equal(readFileSync(secret, 'utf8'), 'private');
    assert.equal(readFileSync(safe, 'utf8'), 'safe');
  } finally { sc.cleanup(); }
});

test('backups survive a service restart and are removed with their task record', async () => {
  const sc = scratch('italk-backup-restart-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true });
  const file = path.join(cwd, 'draft.txt'), dbPath = path.join(sc.dir, 'agent.sqlite');
  writeFileSync(file, 'before restart');
  const policy = new PathPolicy({ roots: [home], home });
  let db = openDb(dbPath);
  db.prepare('INSERT INTO phones(id,name,public_key,paired_at) VALUES(?,?,?,?)').run('phone', 'test', 'public', 0);
  db.prepare("INSERT INTO tasks(id,phone_id,idem_key,request_digest,backend,permission_mode,state,created_at) VALUES(?,?,?,?,?,?,?,?)")
    .run('task', 'phone', 'unique-key', 'digest', 'italk', 'ask', 'completed', 0);
  const opts = { taskId: 'task', phoneId: 'phone', sessionId: 'session', policy };
  try {
    const saved = await new FileCheckpoints({ db, ...opts }).capture(file);
    db.close(); db = openDb(dbPath);
    const store = new FileCheckpoints({ db, ...opts });
    assert.equal(readFileSync(await store.recover(saved.id), 'utf8'), 'before restart');
    db.prepare('DELETE FROM tasks WHERE id=?').run('task');
    assert.equal(store.find(saved.id), undefined);
  } finally { db.close(); sc.cleanup(); }
});

test('task retention purges file contents and execution state with the task events', async () => {
  const sc = scratch('italk-backup-retention-');
  const home = path.join(sc.dir, 'home'), cwd = path.join(home, 'project');
  mkdirSync(cwd, { recursive: true });
  const file = path.join(cwd, 'draft.txt'); writeFileSync(file, 'private data');
  const db = openDb();
  db.prepare('INSERT INTO phones(id,name,public_key,paired_at) VALUES(?,?,?,?)').run('phone', 'test', 'public', 0);
  db.prepare("INSERT INTO tasks(id,phone_id,idem_key,request_digest,backend,permission_mode,state,created_at,finished_at,request_json) VALUES(?,?,?,?,?,?,?,?,?,?)")
    .run('task', 'phone', 'unique-key', 'digest', 'italk', 'ask', 'completed', 0, 10, '{"prompt":"private"}');
  const policy = new PathPolicy({ roots: [home], home });
  const store = new FileCheckpoints({ db, taskId: 'task', phoneId: 'phone', sessionId: 'session', policy });
  try {
    await store.capture(file);
    db.prepare('INSERT INTO agent_state(task_id,state_json,updated_at) VALUES(?,?,?)').run('task', '{"text":"private"}', 0);
    const tasks = new Tasks({ db, backends: new Map(), policy, retentionMs: 100, now: () => 1000 });
    assert.equal(tasks.purge(), 1);
    assert.equal(store.list().length, 0);
    assert.equal(db.prepare('SELECT * FROM agent_state WHERE task_id=?').get('task'), undefined);
    assert.equal(db.prepare('SELECT request_json FROM tasks WHERE id=?').get('task').request_json, null);
  } finally { db.close(); sc.cleanup(); }
});
