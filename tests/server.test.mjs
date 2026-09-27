import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('local API persists records, deduplicates, preserves failed classification, corrects labels, and exports', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'jev-test-'));
  const port = 14317;
  const child = spawn(process.execPath, ['server.mjs'], { env: { ...process.env, PORT: String(port), JEV_DATA_DIR: dir, TYPESAFE_API_KEY: '' }, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => { child.kill(); rmSync(dir, { recursive: true, force: true }); });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('test server timeout')), 5000);
    child.stdout.once('data', () => { clearTimeout(timer); resolve(); });
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`test server exited ${code}`)); });
  });
  const request = async (path, method = 'GET', data) => {
    const res = await fetch(`http://127.0.0.1:${port}${path}`, { method, headers: { 'Content-Type': 'application/json' }, ...(data === undefined ? {} : { body: JSON.stringify(data) }) });
    assert.equal(res.status, 200);
    return res.json();
  };
  const initial = await request('/api/state');
  assert.equal(initial.status.modelConfigured, false);
  const topic = await request('/api/topics', 'POST', { name: '测试话题', description: '个人知识库' });
  const entry = { title: '测试资料', text: '个人知识库能让阅读资料变得可搜索。', url: 'javascript:alert(1)' };
  const first = await request('/api/import', 'POST', entry);
  const second = await request('/api/import', 'POST', entry);
  assert.equal(second.duplicate, true);
  assert.equal(second.id, first.id);
  const state = await request('/api/state');
  assert.equal(state.records.length, 1);
  assert.equal(state.records[0].status, 'error');
  assert.equal(state.records[0].text, entry.text);
  assert.equal(state.records[0].url, '');
  await request(`/api/records/${first.id}`, 'PATCH', { topicId: topic.id, matched: true });
  const exported = await request('/api/export');
  assert.deepEqual(exported.records[0].labels, [topic.id]);
  const denied = await fetch(`http://127.0.0.1:${port}/api/capture/start`, { method: 'POST', headers: { Origin: 'https://untrusted.example', 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(denied.status, 403);
  const noJson = await fetch(`http://127.0.0.1:${port}/api/capture/start`, { method: 'POST' });
  assert.equal(noJson.status, 400);
  await request(`/api/topics/${topic.id}`, 'DELETE', {});
  assert.equal((await request('/api/state')).records.length, 1);
  await request(`/api/records/${first.id}`, 'DELETE', {});
  assert.equal((await request('/api/state')).records.length, 0);
});
