import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, statSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

async function startDesktop(t, directory) {
  const child = spawn(process.execPath, ['server.mjs'], {
    env: { ...process.env, PORT: '0', JEV_DATA_DIR: directory, JEV_ENV_FILE: '/dev/null', TYPESAFE_API_KEY: '', JEV_DESKTOP_TOKEN: 'desktop-test-token' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  t.after(async () => { if (child.exitCode === null) { child.kill(); await exited; } });
  const port = await new Promise((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error('Desktop service startup timed out')), 5000);
    let lines = '', errors = '';
    child.stderr.on('data', chunk => { errors += chunk; });
    child.once('exit', code => { clearTimeout(deadline); reject(new Error(`Exited ${code}: ${errors}`)); });
    child.stdout.on('data', chunk => {
      lines += chunk;
      if (!lines.includes('\n')) return;
      const ready = JSON.parse(lines.split('\n')[0]);
      assert.equal(ready.type, 'ready'); clearTimeout(deadline); resolve(ready.port);
    });
  });
  const request = (path, options = {}) => fetch(`http://127.0.0.1:${port}${path}`, {
    ...options,
    headers: { Authorization: 'Bearer desktop-test-token', 'Content-Type': 'application/json', ...options.headers },
  });
  return { child, port, request, exited };
}

test('desktop service uses a private random port, rejects unauthenticated clients, persists settings, and exits with its parent pipe', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'jev-desktop-test-'));
  // Cleanup is registered last so service termination runs before directory removal below.
  try {
    const app = await startDesktop(t, directory);
    assert.ok(app.port > 0);
    assert.equal((await app.request('/api/state', { headers: { Authorization: '' } })).status, 401);
    assert.equal((await app.request('/api/state', { headers: { Origin: 'https://untrusted.example' } })).status, 403);
    assert.equal((await app.request('/api/capture/start', { method: 'POST', body: '{}', headers: { Authorization: '' } })).status, 401);
    const saved = await app.request('/api/settings', { method: 'POST', body: JSON.stringify({ apiKey: 'test-secret', model: 'jev-latest' }) });
    assert.equal(saved.status, 200);
    assert.equal(statSync(join(directory, 'settings.json')).mode & 0o777, 0o600);
    const response = await app.request('/api/state');
    const raw = await response.text();
    assert.equal(JSON.parse(raw).status.modelConfigured, true);
    assert.equal(raw.includes('test-secret'), false);
    assert.equal((await app.request('/api/settings', { method: 'POST', body: JSON.stringify({ model: '../bad' }) })).status, 400);
    await app.request('/api/settings', { method: 'POST', body: JSON.stringify({ model: 'jev-latest' }) });
    assert.equal(JSON.parse(readFileSync(join(directory, 'settings.json'))).apiKey, 'test-secret');
    app.child.stdin.end();
    assert.equal(await app.exited, 0);
    const second = await startDesktop(t, directory);
    assert.equal((await (await second.request('/api/state')).json()).status.modelConfigured, true);
    second.child.stdin.end();
    assert.equal(await second.exited, 0);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('migration snapshots a live WAL database, copies only referenced screenshots and credentials, and refuses overwrite', () => {
  const root = mkdtempSync(join(tmpdir(), 'jev-migration-test-'));
  const source = join(root, 'source'), target = join(root, 'target');
  mkdirSync(join(source, 'screenshots'), { recursive: true });
  const db = new DatabaseSync(join(source, 'jev.sqlite'));
  db.exec("PRAGMA journal_mode=WAL; CREATE TABLE records (id TEXT, frames TEXT); CREATE TABLE topics (id TEXT);");
  db.prepare('INSERT INTO records VALUES (?, ?)').run('one', JSON.stringify([{ image: 'abcd-1234.jpg' }]));
  writeFileSync(join(source, 'screenshots', 'abcd-1234.jpg'), 'synthetic image');
  writeFileSync(join(source, 'screenshots', 'orphan.jpg'), 'not referenced');
  const envFile = join(root, 'source.env');
  writeFileSync(envFile, 'TYPESAFE_API_KEY="migration-test-secret"\nTYPESAFE_MODEL=jev-latest\nUNRELATED=omit-me\n');
  const env = { ...process.env, JEV_MIGRATE_SOURCE: source, JEV_APP_DATA_DIR: target, JEV_MIGRATE_ENV: envFile };
  try {
    execFileSync(process.execPath, ['scripts/migrate-mac.mjs'], { env, stdio: 'pipe' });
    assert.equal(existsSync(join(target, 'screenshots', 'abcd-1234.jpg')), true);
    assert.equal(existsSync(join(target, 'screenshots', 'orphan.jpg')), false);
    const migrated = new DatabaseSync(join(target, 'jev.sqlite'), { readOnly: true });
    assert.equal(migrated.prepare('SELECT COUNT(*) AS n FROM records').get().n, 1); migrated.close();
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM records').get().n, 1);
    assert.deepEqual(JSON.parse(readFileSync(join(target, 'settings.json'))), { apiKey: 'migration-test-secret', model: 'jev-latest' });
    assert.equal(statSync(join(target, 'settings.json')).mode & 0o777, 0o600);
    assert.throws(() => execFileSync(process.execPath, ['scripts/migrate-mac.mjs'], { env, stdio: 'pipe' }));
  } finally { db.close(); rmSync(root, { recursive: true, force: true }); }
});
