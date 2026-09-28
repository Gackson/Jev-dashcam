import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, readdirSync, symlinkSync, statSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { migrateStorage } from '../storage-migration.mjs';

function fixture(t, { wal = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'dashcam-storage-'));
  const source = join(root, '旧资料'), target = join(root, '新位置 Dashcam');
  mkdirSync(source); mkdirSync(join(source, 'screenshots'));
  const db = new DatabaseSync(join(source, 'jev.sqlite'));
  if (wal) db.exec('PRAGMA journal_mode=WAL');
  db.exec("CREATE TABLE records(id TEXT PRIMARY KEY, frames TEXT, text TEXT, status TEXT); CREATE TABLE topics(id TEXT, name TEXT); INSERT INTO topics VALUES ('t', 'Edited topic');");
  db.prepare('INSERT INTO records VALUES (?, ?, ?, ?)').run('r', JSON.stringify([{ image: 'abcd-1234.jpg' }]), 'original content', 'error');
  writeFileSync(join(source, 'screenshots', 'abcd-1234.jpg'), 'screenshot bytes');
  writeFileSync(join(source, 'settings.json'), '{"apiKey":"fixture-secret"}');
  writeFileSync(join(source, '.env'), 'TYPESAFE_MODEL=jev-latest\n');
  writeFileSync(join(source, 'window-exclusions.json'), '[{"app":"Excluded"}]');
  writeFileSync(join(source, 'capture-preferences.json'), '{"pendingRetentionHours":24}');
  mkdirSync(join(source, 'backups')); writeFileSync(join(source, 'backups', 'original.sqlite'), 'backup bytes');
  if (!wal) db.close();
  t.after(() => { if (wal) db.close(); rmSync(root, { recursive: true, force: true }); });
  return { root, source, target, db };
}

test('relocation preserves records, topic edits, screenshots, hidden configuration and backups without changing source', async t => {
  const { source, target } = fixture(t);
  const before = readFileSync(join(source, 'jev.sqlite'));
  mkdirSync(target);
  const result = await migrateStorage(source, target);
  assert.equal(result.directory, realpathSync(target));
  const db = new DatabaseSync(join(target, 'jev.sqlite'), { readOnly: true });
  try {
    assert.equal(db.prepare('SELECT text FROM records').get().text, 'original content');
    assert.equal(db.prepare('SELECT status FROM records').get().status, 'error');
    assert.equal(db.prepare('SELECT name FROM topics').get().name, 'Edited topic');
  } finally { db.close(); }
  for (const path of ['settings.json', '.env', 'window-exclusions.json', 'capture-preferences.json', 'screenshots/abcd-1234.jpg', 'backups/original.sqlite']) {
    assert.deepEqual(readFileSync(join(target, path)), readFileSync(join(source, path)));
    assert.equal(statSync(join(target, path)).mode & 0o777, 0o600);
  }
  assert.equal(statSync(target).mode & 0o777, 0o700);
  assert.deepEqual(readFileSync(join(source, 'jev.sqlite')), before);
  writeFileSync(join(target, 'new-record'), 'new data');
  assert.equal(existsSync(join(source, 'new-record')), false);
});

test('WAL data is included even when it has not checkpointed', async t => {
  const { source, target } = fixture(t, { wal: true });
  assert.ok(existsSync(join(source, 'jev.sqlite-wal')));
  await migrateStorage(source, target);
  const db = new DatabaseSync(join(target, 'jev.sqlite'), { readOnly: true });
  try { assert.equal(db.prepare('SELECT COUNT(*) n FROM records').get().n, 1); }
  finally { db.close(); }
});

test('nonempty, identical and nested destinations are rejected without overwriting anything', async t => {
  const { source, target, root } = fixture(t);
  mkdirSync(target); writeFileSync(join(target, 'keep.txt'), 'keep me');
  await assert.rejects(migrateStorage(source, target), /空文件夹/);
  assert.equal(readFileSync(join(target, 'keep.txt'), 'utf8'), 'keep me');
  for (const bad of [source, join(source, 'child'), root]) await assert.rejects(migrateStorage(source, bad), /父目录或子目录/);
  const alias = join(root, 'alias'); symlinkSync(source, alias);
  await assert.rejects(migrateStorage(source, join(alias, 'child')), /父目录或子目录/);
});

test('missing screenshot and corrupt database fail without publishing a partial library', async t => {
  const { source, target, root } = fixture(t);
  rmSync(join(source, 'screenshots', 'abcd-1234.jpg'));
  await assert.rejects(migrateStorage(source, target), /截图缺失/);
  assert.equal(existsSync(target), false);
  assert.equal(existsSync(join(source, 'settings.json')), true);
  writeFileSync(join(source, 'jev.sqlite'), 'corrupted');
  await assert.rejects(migrateStorage(source, target));
  assert.equal(existsSync(target), false);
  assert.equal(readdirSync(root).some(name => name.startsWith('.dashcam-migration-')), false);
});

test('links inside the library are rejected; missing source never creates an empty library', async t => {
  const { source, target, root } = fixture(t);
  symlinkSync(join(root, 'outside'), join(source, 'link'));
  await assert.rejects(migrateStorage(source, target), /链接或特殊文件/);
  assert.equal(existsSync(target), false);
  await assert.rejects(migrateStorage(join(root, 'missing'), target), /资料库不存在/);
});

test('CLI works through a symlinked path and reports failures to the native caller', async t => {
  const { source, target, root } = fixture(t);
  const { execFileSync } = await import('node:child_process');
  const { resolve } = await import('node:path');
  const alias = join(root, 'migration-link.mjs');
  symlinkSync(resolve('storage-migration.mjs'), alias);
  const result = JSON.parse(execFileSync(process.execPath, [alias, source, target], { encoding: 'utf8' }));
  assert.equal(result.directory, realpathSync(target));
  assert.ok(existsSync(join(target, 'jev.sqlite')));
  assert.throws(() => execFileSync(process.execPath, [alias, source, target, '--validate'], { stdio: 'pipe' }));
});
