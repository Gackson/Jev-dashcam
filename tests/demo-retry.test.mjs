import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

test('demo returns existing records visibly without reclassifying user content; retries target only requested failures', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jev-demo-retry-'));
  const child = spawn(process.execPath, ['server.mjs'], {
    env: { ...process.env, PORT: '0', JEV_DATA_DIR: directory, JEV_ENV_FILE: '/dev/null', TYPESAFE_API_KEY: '', JEV_DESKTOP_TOKEN: 'demo-test' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  let db;
  try {
    const port = await new Promise((resolve, reject) => {
      let data = '';
      const timer = setTimeout(() => reject(Error('startup timeout')), 5000);
      child.once('exit', () => { clearTimeout(timer); reject(Error('service exited')); });
      child.stdout.on('data', chunk => { data += chunk; if (data.includes('\n')) { clearTimeout(timer); resolve(JSON.parse(data.split('\n')[0]).port); } });
    });
    const request = async (path, body, expected = 200) => {
      const response = await fetch(`http://127.0.0.1:${port}/api/${path}`, {
        method: body ? 'POST' : 'GET', headers: { Authorization: 'Bearer demo-test', 'Content-Type': 'application/json' },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      assert.equal(response.status, expected); return response.json();
    };
    await request('topics', { name: 'Existing topic', description: 'Original description' });
    const original = await request('import', { text: 'Original user content must not be reclassified by demo.' });
    const before = (await request('state')).records.find(r => r.id === original.id);
    const first = await request('demo', {});
    assert.equal(first.added, 4); assert.equal(first.ids.length, 4);
    const repeated = await request('demo', {});
    assert.equal(repeated.added, 0); assert.deepEqual(repeated.ids, first.ids);
    const state = await request('state');
    assert.equal(state.records.length, 5);
    assert.deepEqual(state.records.find(r => r.id === original.id), before);
    db = new DatabaseSync(join(directory, 'jev.sqlite'));
    // Distinct sentinel failures reveal if a per-card retry touches other cards.
    db.prepare("UPDATE records SET error='leave this failure untouched' WHERE id=?").run(original.id);
    db.prepare("UPDATE records SET status='pending', error=NULL WHERE id=?").run(first.ids[1]);
    db.prepare("UPDATE records SET status='unmatched', error=NULL WHERE id=?").run(first.ids[2]);
    assert.equal((await request('retry', { ids: [first.ids[0], first.ids[0], first.ids[1], first.ids[2], 'missing'] })).count, 1);
    assert.equal(db.prepare('SELECT error FROM records WHERE id=?').get(original.id).error, 'leave this failure untouched');
    assert.equal(db.prepare('SELECT status FROM records WHERE id=?').get(first.ids[1]).status, 'pending');
    assert.equal((await request('retry', { ids: [] })).count, 0);
    assert.equal((await request('retry', {})).count, 3);
    await request('retry', { ids: 'bad' }, 400);
    await request('retry', { ids: [3] }, 400);
    const topicId = state.topics[0].id;
    const ids = first.ids.slice(0, 2);
    const snapshot = db.prepare('SELECT * FROM records WHERE id=?').get(ids[0]);
    await request('records/batch', { action: 'classify', ids: [ids[0], 'missing'], topicId, matched: true }, 404);
    assert.deepEqual(db.prepare('SELECT * FROM records WHERE id=?').get(ids[0]), snapshot, 'Invalid batches change nothing');
    assert.equal((await request('records/batch', { action: 'classify', ids: [...ids, ids[0]], topicId, matched: true })).count, 2);
    let classified = await request('state');
    for (const id of ids) assert.ok(classified.records.find(r => r.id === id).labels.includes(topicId));
    assert.equal(classified.records.find(r => r.id === original.id).labels.includes(topicId), false);
    await request('records/batch', { action: 'classify', ids, topicId, matched: false });
    classified = await request('state');
    for (const id of ids) assert.equal(classified.records.find(r => r.id === id).labels.includes(topicId), false);
    assert.equal(db.prepare('SELECT scores FROM records WHERE id=?').get(ids[0]).scores, snapshot.scores);
    await request('records/batch', { action: 'delete', ids: [] }, 400);
    await request('records/batch', { action: 'classify', ids, topicId: 'missing', matched: true }, 400);
    for (const [index, id] of first.ids.entries()) {
      const image = `abcd-${index}.jpg`;
      writeFileSync(join(directory, 'screenshots', image), 'synthetic test screenshot');
      db.prepare('UPDATE records SET frames=? WHERE id=?').run(JSON.stringify([{ image }]), id);
    }
    assert.equal((await request('records/batch', { action: 'delete', ids })).count, 2);
    assert.equal(db.prepare('SELECT count(*) n FROM records').get().n, 3);
    assert.equal(existsSync(join(directory, 'screenshots', 'abcd-0.jpg')), false);
    assert.equal(existsSync(join(directory, 'screenshots', 'abcd-1.jpg')), false);
    assert.equal(existsSync(join(directory, 'screenshots', 'abcd-2.jpg')), true);
    assert.equal((await request('demo', {})).added, 2, 'Deleting a group also clears deduplication references');
    child.stdin.end(); await exited;
  } finally {
    if (child.exitCode === null) { child.kill(); await exited; }
    db?.close(); rmSync(directory, { recursive: true, force: true });
  }
});
