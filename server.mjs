import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync, renameSync } from 'node:fs';
import { fingerprint, classify, labelIds } from './core.mjs';
import { migrateLegacyProjects } from './legacy-project-migration.mjs';
import { migrateCaptureRecords } from './capture-migration.mjs';
import { WindowSessions, capturePreferences, expiredPendingCaptures, retentionSweepMs } from './capture-policy.mjs';
import { unlink } from 'node:fs/promises';
import { validateExclusions, isWindowExcluded } from './window-exclusions.mjs';

const root = dirname(fileURLToPath(import.meta.url));
try { process.loadEnvFile(process.env.JEV_ENV_FILE || join(root, '.env')); } catch {}
let port = Number(process.env.PORT ?? 4317);
const desktopToken = process.env.JEV_DESKTOP_TOKEN;
const dataDir = process.env.JEV_DATA_DIR || join(root, 'data');
const settingsFile = join(dataDir, 'settings.json');
if (desktopToken && existsSync(settingsFile)) {
  const settings = JSON.parse(readFileSync(settingsFile, 'utf8'));
  process.env.TYPESAFE_API_KEY = settings.apiKey || '';
  process.env.TYPESAFE_MODEL = settings.model || 'jev-latest';
}
const shots = join(dataDir, 'screenshots');
mkdirSync(shots, { recursive: true, mode: 0o700 });
const exclusionsFile = join(dataDir, 'window-exclusions.json');
if (!existsSync(exclusionsFile)) writeFileSync(exclusionsFile, '[]', { mode: 0o600 });
let windowExclusions = validateExclusions(JSON.parse(readFileSync(exclusionsFile, 'utf8')));
const capturePreferencesFile = join(dataDir, 'capture-preferences.json');
let captureOptions = capturePreferences(existsSync(capturePreferencesFile) ? JSON.parse(readFileSync(capturePreferencesFile, 'utf8')) : {});
const windowSessions = new WindowSessions();
const db = new DatabaseSync(join(dataDir, 'jev.sqlite'));
db.exec(`PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS topics (id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, color TEXT NOT NULL, created TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, title TEXT, app TEXT, url TEXT, text TEXT, frames TEXT DEFAULT '[]', scores TEXT DEFAULT '{}', manual TEXT DEFAULT '{}', status TEXT DEFAULT 'pending', error TEXT, model TEXT, created TEXT, updated TEXT, kind TEXT DEFAULT 'capture');
  CREATE TABLE IF NOT EXISTS seen (hash TEXT PRIMARY KEY, record_id TEXT);
`);
const migration = migrateCaptureRecords(db, dataDir);
if (!db.prepare('PRAGMA table_info(records)').all().some(column => column.name === 'session_id')) db.exec('ALTER TABLE records ADD COLUMN session_id TEXT');
if (!db.prepare('PRAGMA table_info(records)').all().some(column => column.name === 'topic_snapshot')) db.exec('ALTER TABLE records ADD COLUMN topic_snapshot TEXT');
const projectMigration = migrateLegacyProjects(db, dataDir, captureOptions.windowReturnSeconds);
db.exec("CREATE INDEX IF NOT EXISTS records_retention ON records(status, created) WHERE kind='capture'");
db.prepare("UPDATE records SET status='pending' WHERE status='processing'").run();
const run = promisify(execFile);
const helper = process.env.JEV_CAPTURE_HELPER || join(root, 'build', 'jev-capture');
const palette = ['sage', 'peach', 'blue', 'lavender', 'yellow'];
const queue = new Set();
let working = false;
let collector = null;
let shuttingDown = false;
const captureChildren = new Set();
const status = { capture: 'paused', message: '准备好后，开始收集你的灵感', app: '', samples: 0, duplicates: 0, lastCapture: null, error: null };
const events = [];
function event(message, type = 'info') { events.unshift({ id: randomUUID(), message, type, time: new Date().toISOString() }); events.splice(20); }
function topics() { return db.prepare('SELECT * FROM topics ORDER BY created').all(); }
function record(row) {
  if (!row) return null;
  const item = { ...row, frames: JSON.parse(row.frames), scores: JSON.parse(row.scores), manual: JSON.parse(row.manual) };
  delete item.topic_snapshot;
  return { ...item, labels: labelIds(item, topics()) };
}
function allRecords() { return db.prepare('SELECT * FROM records ORDER BY updated DESC').all().map(record); }
function removeShot(name) {
  if (name && basename(name) === name && /^[a-f0-9-]+\.jpg$/.test(name)) {
    try { unlinkSync(join(shots, name)); } catch {}
  }
}
function schedule(id, { preserveSnapshot = false } = {}) {
  const snapshot = JSON.stringify(topics());
  db.prepare(`UPDATE records SET status=CASE WHEN status='processing' THEN status ELSE 'pending' END, error=NULL,
    topic_snapshot=${preserveSnapshot ? 'COALESCE(topic_snapshot, ?)' : '?'} WHERE id=?`).run(snapshot, id);
  queue.add(id); void work();
}
async function work() {
  if (working || shuttingDown) return;
  working = true;
  try {
    while (queue.size && !shuttingDown) {
      const id = queue.values().next().value;
      queue.delete(id);
      const row = db.prepare('SELECT * FROM records WHERE id=?').get(id);
      const item = record(row);
      if (!item) continue;
      const selectedTopics = row.topic_snapshot ? JSON.parse(row.topic_snapshot) : topics();
      if (!selectedTopics.length) {
        db.prepare("UPDATE records SET status='unmatched', error=NULL WHERE id=?").run(id); continue;
      }
      db.prepare("UPDATE records SET status='processing', error=NULL WHERE id=?").run(id);
      try {
        const result = await classify(item, selectedTopics);
        if (shuttingDown) return;
        const latest = db.prepare('SELECT updated, topic_snapshot, manual FROM records WHERE id=?').get(id);
        if (!latest) continue;
        // Only explicitly scheduled work replaces the topic snapshot. Editing a topic
        // must not invalidate or rerun existing jobs.
        if (latest.updated !== item.updated || latest.topic_snapshot !== row.topic_snapshot) {
          queue.add(id); continue;
        }
        const matched = labelIds({ scores: result.scores, manual: JSON.parse(latest.manual) }, topics()).length;
        db.prepare('UPDATE records SET scores=?, status=?, model=?, error=NULL WHERE id=?').run(JSON.stringify(result.scores), matched ? 'classified' : 'unmatched', result.model || null, id);
        event(matched ? `「${item.title.slice(0, 30)}」已归入 ${matched} 个话题` : `已检查「${item.title.slice(0, 30)}」，暂未匹配话题`, matched ? 'match' : 'info');
      } catch (error) {
        if (shuttingDown) return;
        const message = error.name === 'TimeoutError' ? 'Jev 响应超时，资料已保存，可重试' : error.message === 'fetch failed' ? '无法连接 Jev，资料已保存，请检查网络后重试' : error.message;
        db.prepare("UPDATE records SET status='error', error=? WHERE id=?").run(message, id);
        event(message, 'error');
      }
    }
  } finally { working = false; }
}
function ingest(input) {
  if ((!input.kind || input.kind === 'capture') && isWindowExcluded(windowExclusions, input)) {
    removeShot(input.screenshot);
    return { skipped: true, reason: '此窗口已排除采集' };
  }
  const text = String(input.text || '').trim().slice(0, 100000);
  if (text.length < 10) { removeShot(input.screenshot); return { skipped: true, reason: '文字太少' }; }
  const hash = fingerprint(text);
  const seen = db.prepare('SELECT record_id FROM seen WHERE hash=?').get(hash);
  if (seen) { status.duplicates++; removeShot(input.screenshot); return { duplicate: true, id: seen.record_id }; }
  const now = new Date().toISOString();
  const title = String(input.title || text.split('\n')[0]).trim().slice(0, 180);
  const app = String(input.app || '手动录入').slice(0, 80);
  const frame = input.screenshot ? [{ image: input.screenshot, time: now, text }] : [];
  // Capture identity is its own OCR evidence, never its app, title, or shared navigation.
  const id = randomUUID();
  const sessionID = input.kind && input.kind !== 'capture' ? null : input.sessionID || null;
  const url = /^https?:\/\//.test(input.url || '') ? String(input.url).slice(0, 2000) : '';
  db.prepare('INSERT INTO records (id,title,app,url,text,frames,created,updated,kind,session_id) VALUES (?,?,?,?,?,?,?,?,?,?)').run(id, title, app, url, text, JSON.stringify(frame), now, now, input.kind || 'capture', sessionID);
  event(`收集到「${title.slice(0, 36)}」`);
  schedule(id);
  db.prepare('INSERT OR IGNORE INTO seen VALUES (?,?)').run(hash, id);
  status.lastCapture = now;
  return { id };
}
function startCapture() {
  if (collector) return;
  if (!existsSync(helper)) throw new Error('采集器尚未构建，请先运行 npm run build:native');
  status.capture = 'starting'; status.error = null; status.message = '正在连接 Mac 屏幕…';
  const child = spawn(helper, [shots, '--exclusions', exclusionsFile], { stdio: ['ignore', 'pipe', 'pipe'] });
  collector = child;
  captureChildren.add(child);
  child.once('close', () => captureChildren.delete(child));
  windowSessions.reset();
  let buffer = '';
  child.stdout.on('data', chunk => {
    buffer += chunk;
    const parts = buffer.split('\n'); buffer = parts.pop();
    for (const line of parts) {
      try {
        const item = JSON.parse(line);
        if (shuttingDown || collector !== child) { if (item.type === 'capture') removeShot(item.screenshot); continue; }
        if (item.type === 'focus') windowSessions.observe(item.windowKey || null, Date.now(), captureOptions.windowReturnSeconds);
        if (item.type === 'ready') { status.capture = 'running'; status.message = '正在留意新内容'; event('自动采集已开始'); }
        if (item.type === 'permission' && !item.granted) {
          status.capture = 'permission'; status.message = '需要屏幕录制权限';
          status.error = desktopToken ? '在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Dashcam，然后退出并重新打开 App。' : '在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中，允许启动服务的终端或 Codex。授权后重启服务，再开始采集。';
          event('等待屏幕录制授权', 'error');
        }
        if (item.type === 'tick') { status.samples = item.samples; status.app = item.app; status.message = '正在留意新内容'; status.error = null; }
        if (item.type === 'skipped') { status.app = item.app; status.message = item.reason === 'self' ? '查看资料中，已跳过 Dashcam 窗口' : item.reason === 'window-excluded' ? '此窗口已排除采集' : '此应用已排除采集'; }
        if (item.type === 'capture') {
          const sessionID = item.windowKey ? windowSessions.observe(item.windowKey, Date.now(), captureOptions.windowReturnSeconds) : null;
          ingest({ ...item, sessionID });
        }
        if (item.type === 'error') { status.error = item.message; status.message = '采集遇到问题，正在重试'; }
      } catch { status.error = '采集器返回了无法读取的数据'; }
    }
  });
  child.stderr.on('data', () => {});
  child.on('error', error => { status.error = error.message; status.capture = 'error'; });
  child.on('close', () => {
    if (collector === child) {
      collector = null;
      if (status.capture === 'running' || status.capture === 'starting') { status.capture = 'error'; status.message = '采集器已停止，请重新开始'; }
    }
  });
}
function stopCapture() {
  collector?.kill('SIGTERM'); collector = null;
  status.capture = 'paused'; status.message = '采集已暂停'; status.error = null;
  event('已暂停采集，已有资料继续归类');
}
let cleaning = false;
async function cleanPendingCaptures() {
  if (cleaning || shuttingDown) return;
  const expired = expiredPendingCaptures(db, { recording: collector !== null && status.capture === 'running', retentionHours: captureOptions.pendingRetentionHours });
  if (!expired.length) return;
  cleaning = true;
  try {
    db.exec('BEGIN IMMEDIATE');
    try {
      for (const item of expired) {
        db.prepare('DELETE FROM seen WHERE record_id=?').run(item.id);
        db.prepare('DELETE FROM records WHERE id=?').run(item.id);
        queue.delete(item.id);
      }
      db.exec('COMMIT');
    } catch (error) { db.exec('ROLLBACK'); throw error; }
    // One sweep, one database transaction. No per-frame timers or VACUUM.
    for (const item of expired) {
      for (const frame of JSON.parse(item.frames)) {
        if (/^[a-f0-9-]+\.jpg$/.test(frame.image)) {
          try { await unlink(join(shots, frame.image)); } catch (error) { if (error.code !== 'ENOENT') event('过期待归类截图文件清理失败', 'error'); }
        }
      }
    }
    event(`已清理 ${expired.length} 份超过保留时长的待归类截图`);
  } finally { cleaning = false; }
}
const cleanupTimer = setInterval(() => { void cleanPendingCaptures().catch(() => event('待归类内容清理失败，下次检查时重试', 'error')); }, retentionSweepMs);
cleanupTimer.unref();

const fixtures = [
  { title: '让知识库随着阅读自然生长', text: '个人知识库与 AI 笔记\n传统笔记工具要求用户主动复制、粘贴、整理。自动收集工具可以通过屏幕 OCR 和语义分类，将阅读时遇到的信息关联到正在关注的目标。\n设计重点包括来源可追溯、重复内容合并，以及用户随时纠正分类。AI 笔记产品的价值在于将碎片信息转化为可检索的个人资料库。', app: '示例文章' },
  { title: '好的交互，让等待变得可理解', text: '产品设计中的反馈与状态\n当用户触发一个耗时操作，界面应立即反馈已收到操作，然后展示正在进行的步骤。\n自动化产品尤其需要可见的运行状态、暂停入口和可撤销的结果。渐进展示能帮助用户理解系统正在做什么，降低等待过程中的不确定性。', app: '示例文章' },
  { title: '把 AI 分类变成一个可组合的函数', text: 'Building reliable AI agents with typed decisions\nA small model can judge whether a document is relevant to a user goal. Ask independent yes/no questions for each topic, then let ordinary code choose thresholds and store matching results.\nTyped model outputs support predictable routing, evaluation, and testing. Preserve original evidence so later reasoning agents can cite sources in their answers.', app: '示例文章' },
  { title: '周末的一杯手冲咖啡', text: '今天尝试了一支浅烘焙埃塞俄比亚咖啡豆。用 15 克咖啡粉，搭配 240 克热水，分三段注水。杯中有柑橘和白花的香气，放凉之后甜感更加明显。下次可以尝试稍微降低水温。', app: '示例随笔' },
];
function addTopic(name, description, { reclassifyExisting = true } = {}) {
  const existing = topics();
  if (existing.length >= 20) throw new Error('原型最多支持 20 个话题');
  if (!name?.trim()) throw new Error('请填写话题名称');
  if (existing.some(t => t.name === name.trim())) throw new Error('这个话题已经存在');
  const id = 't_' + randomUUID().replaceAll('-', '');
  db.prepare('INSERT INTO topics VALUES (?,?,?,?,?)').run(id, name.trim().slice(0, 60), String(description || '').slice(0, 1000), palette[existing.length % palette.length], new Date().toISOString());
  if (reclassifyExisting) for (const item of allRecords()) schedule(item.id);
  return id;
}
async function body(req) {
  if (!req.headers['content-type']?.startsWith('application/json')) throw new Error('需要 JSON 请求');
  let data = ''; for await (const chunk of req) { data += chunk; if (data.length > 150000) throw new Error('内容太长'); }
  return JSON.parse(data || '{}');
}
function send(res, value, code = 200) { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); }
const server = http.createServer(async (req, res) => {
  if (shuttingDown) return send(res, { error: '服务正在关闭' }, 503);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Security-Policy', "default-src 'self'; style-src 'self'; img-src 'self' data:; script-src 'self'; frame-ancestors 'none'; base-uri 'none'");
  // Local-only host and same-origin writes protect the local capture controls.
  if (![`localhost:${port}`, `127.0.0.1:${port}`].includes(req.headers.host)) return send(res, { error: 'Invalid host' }, 403);
  if (req.headers.origin && ![`http://localhost:${port}`, `http://127.0.0.1:${port}`].includes(req.headers.origin)) return send(res, { error: 'Invalid origin' }, 403);
  if (desktopToken && req.headers.authorization !== `Bearer ${desktopToken}`) return send(res, { error: 'Unauthorized' }, 401);
  try {
    const path = new URL(req.url, `http://127.0.0.1:${port}`).pathname;
    if (req.method === 'GET' && path === '/api/state') return send(res, { capturePreferences: captureOptions, windowExclusions, topics: topics(), records: allRecords(), status: { ...status, queue: queue.size + (working ? 1 : 0), modelConfigured: Boolean(process.env.TYPESAFE_API_KEY), model: process.env.TYPESAFE_MODEL || 'jev-latest', helperReady: existsSync(helper) }, events });
    if (req.method === 'POST' && path === '/api/capture-preferences') {
      const options = capturePreferences({ ...captureOptions, ...await body(req) });
      writeFileSync(capturePreferencesFile + '.tmp', JSON.stringify(options), { mode: 0o600 });
      renameSync(capturePreferencesFile + '.tmp', capturePreferencesFile);
      captureOptions = options;
      return send(res, { ok: true });
    }
    if (req.method === 'GET' && path === '/api/windows') {
      const { stdout } = await run(helper, ['--list-windows'], { timeout: 10000 });
      const result = JSON.parse(stdout);
      if (result.error) throw new Error(result.error);
      return send(res, result);
    }
    if (req.method === 'POST' && path === '/api/window-exclusions') {
      const b = await body(req);
      const rules = validateExclusions(b.rules);
      writeFileSync(exclusionsFile + '.tmp', JSON.stringify(rules), { mode: 0o600 });
      renameSync(exclusionsFile + '.tmp', exclusionsFile);
      windowExclusions = rules;
      return send(res, { ok: true });
    }
    if (desktopToken && req.method === 'POST' && path === '/api/settings') {
      const b = await body(req);
      const apiKey = b.apiKey === undefined ? (process.env.TYPESAFE_API_KEY || '') : String(b.apiKey).trim();
      const model = String(b.model || 'jev-latest').trim();
      if (apiKey.length > 1000 || !/^[a-zA-Z0-9._-]{1,100}$/.test(model)) throw new Error('无效的配置');
      writeFileSync(settingsFile + '.tmp', JSON.stringify({ apiKey, model }), { mode: 0o600 });
      renameSync(settingsFile + '.tmp', settingsFile);
      process.env.TYPESAFE_API_KEY = apiKey; process.env.TYPESAFE_MODEL = model;
      return send(res, { ok: true });
    }
    if (req.method === 'POST' && path === '/api/topics') { const b = await body(req); return send(res, { id: addTopic(b.name, b.description) }); }
    if (req.method === 'PATCH' && path.startsWith('/api/topics/')) {
      const id = path.split('/').pop(); const b = await body(req);
      if (!db.prepare('SELECT id FROM topics WHERE id=?').get(id)) return send(res, { error: '话题不存在' }, 404);
      if (typeof b.name !== 'string' || !b.name.trim() || b.name.trim().length > 60 || typeof b.description !== 'string' || b.description.length > 1000) throw new Error('标题需为 1–60 字，简介最多 1000 字');
      const name = b.name.trim();
      if (db.prepare('SELECT id FROM topics WHERE name=? AND id!=?').get(name, id)) throw new Error('这个话题名称已经存在');
      db.prepare('UPDATE topics SET name=?, description=? WHERE id=?').run(name, b.description.trim(), id);
      // Do not schedule records or modify their stored classification snapshots.
      return send(res, { ok: true });
    }
    if (req.method === 'POST' && path === '/api/capture/start') { await body(req); startCapture(); return send(res, { ok: true }); }
    if (req.method === 'POST' && path === '/api/capture/stop') { await body(req); stopCapture(); return send(res, { ok: true }); }
    if (req.method === 'POST' && path === '/api/import') { const b = await body(req); return send(res, ingest({ text: b.text, title: b.title, url: b.url, kind: 'manual', app: '手动录入' })); }
    if (req.method === 'POST' && path === '/api/demo') {
      await body(req);
      const seeds = [['AI 笔记', '自动收集信息、个人知识库、AI 笔记产品和相关竞品'], ['产品设计', '用户体验、界面设计、交互反馈与设计方法'], ['AI Agent', 'AI agents, typed model decisions, tools, orchestration and evaluation']];
      for (const [name, description] of seeds) {
        if (topics().length < 20 && !topics().some(t => t.name === name)) addTopic(name, description, { reclassifyExisting: false });
      }
      const results = fixtures.map(fixture => ingest({ ...fixture, kind: 'demo' }));
      return send(res, { ok: true, ids: results.map(result => result.id), added: results.filter(result => !result.duplicate).length });
    }
    if (req.method === 'POST' && path === '/api/retry') {
      const b = await body(req);
      if (b.ids !== undefined && (!Array.isArray(b.ids) || b.ids.length > 500 || b.ids.some(id => typeof id !== 'string'))) throw new Error('无效的资料列表');
      const requested = b.ids === undefined ? null : new Set(b.ids);
      const failed = allRecords().filter(item => item.status === 'error' && (!requested || requested.has(item.id)));
      for (const item of failed) schedule(item.id, { preserveSnapshot: true });
      return send(res, { ok: true, count: failed.length });
    }
    if (req.method === 'POST' && path === '/api/records/batch') {
      const b = await body(req);
      if (!['classify', 'delete'].includes(b.action) || !Array.isArray(b.ids) || !b.ids.length || b.ids.some(id => typeof id !== 'string')) throw new Error('无效的批量操作');
      const ids = [...new Set(b.ids)];
      const items = ids.map(id => record(db.prepare('SELECT * FROM records WHERE id=?').get(id)));
      if (items.some(item => !item)) return send(res, { error: '部分资料已不存在，请刷新后重试' }, 404);
      if (b.action === 'classify' && (!topics().some(t => t.id === b.topicId) || typeof b.matched !== 'boolean')) throw new Error('无效的话题');
      db.exec('BEGIN IMMEDIATE');
      try {
        for (const item of items) {
          if (b.action === 'classify') {
            item.manual[b.topicId] = b.matched;
            db.prepare('UPDATE records SET manual=? WHERE id=?').run(JSON.stringify(item.manual), item.id);
          } else {
            db.prepare('DELETE FROM seen WHERE record_id=?').run(item.id);
            db.prepare('DELETE FROM records WHERE id=?').run(item.id);
          }
        }
        db.exec('COMMIT');
      } catch (error) { db.exec('ROLLBACK'); throw error; }
      if (b.action === 'delete') for (const item of items) {
        queue.delete(item.id);
        for (const frame of item.frames) removeShot(frame.image);
      }
      return send(res, { ok: true, count: items.length });
    }
    if (req.method === 'PATCH' && path.startsWith('/api/records/')) {
      const id = path.split('/').pop(); const b = await body(req);
      const item = record(db.prepare('SELECT * FROM records WHERE id=?').get(id));
      if (!item) return send(res, { error: '资料不存在' }, 404);
      if (!topics().some(t => t.id === b.topicId) || typeof b.matched !== 'boolean') throw new Error('无效的话题');
      item.manual[b.topicId] = b.matched;
      db.prepare('UPDATE records SET manual=? WHERE id=?').run(JSON.stringify(item.manual), id);
      return send(res, { ok: true });
    }
    if (req.method === 'DELETE' && path.startsWith('/api/records/')) {
      await body(req); const id = path.split('/').pop();
      const item = record(db.prepare('SELECT * FROM records WHERE id=?').get(id));
      for (const frame of item?.frames || []) removeShot(frame.image);
      db.prepare('DELETE FROM seen WHERE record_id=?').run(id); db.prepare('DELETE FROM records WHERE id=?').run(id); queue.delete(id);
      return send(res, { ok: true });
    }
    if (req.method === 'DELETE' && path.startsWith('/api/topics/')) {
      await body(req); db.prepare('DELETE FROM topics WHERE id=?').run(path.split('/').pop()); return send(res, { ok: true });
    }
    if (req.method === 'GET' && path === '/api/export') {
      res.setHeader('Content-Disposition', 'attachment; filename="jev-dashcam.json"');
      return send(res, { version: 1, exported: new Date().toISOString(), topics: topics(), records: allRecords() });
    }
    if (req.method === 'GET' && path === '/api/permission') {
      if (!existsSync(helper)) return send(res, { granted: false, built: false });
      const { stdout } = await run(helper, ['--check'], { timeout: 5000 }); return send(res, JSON.parse(stdout));
    }
    if (req.method === 'GET' && path.startsWith('/screenshots/')) {
      const name = path.split('/').pop();
      if (!/^[a-f0-9-]+\.jpg$/.test(name)) return send(res, { error: 'Not found' }, 404);
      res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'no-store' }); return res.end(readFileSync(join(shots, name)));
    }
    const pages = { '/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'], '/style.css': ['style.css', 'text/css'], '/favicon.svg': ['favicon.svg', 'image/svg+xml'] };
    if (req.method === 'GET' && pages[path]) {
      const [file, type] = pages[path]; res.writeHead(200, { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-cache' }); return res.end(readFileSync(join(root, 'public', file)));
    }
    send(res, { error: 'Not found' }, 404);
  } catch (error) { if (!res.headersSent) send(res, { error: error.message }, 400); else res.end(); }
});
server.on('error', error => {
  console.error(error.code === 'EADDRINUSE' ? `端口 ${port} 已被占用，请关闭已有服务或更改 PORT。` : `无法启动本地服务：${error.message}`);
  process.exit(1);
});
server.listen(port, '127.0.0.1', () => {
  port = server.address().port;
  console.log(desktopToken ? JSON.stringify({ type: 'ready', port }) : `Dashcam is ready at http://localhost:${port}`);
  if (projectMigration?.groups) event(`已将 ${projectMigration.captures} 张历史截图补合并为 ${projectMigration.groups} 个项目；按来源、标题与时间推断，原资料库已备份`);
  if (migration?.groups) event(`已将 ${migration.groups} 组旧资料拆为 ${migration.captures} 张截图，正在逐张归类；原资料已备份`);
  for (const item of allRecords().filter(r => r.status === 'pending')) schedule(item.id, { preserveSnapshot: true });
});
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(cleanupTimer);
  server.close();
  await Promise.all([...captureChildren].map(child => new Promise(resolve => {
    const deadline = setTimeout(() => child.kill('SIGKILL'), 3000);
    child.once('close', () => { clearTimeout(deadline); resolve(); });
    child.kill('SIGTERM');
  })));
  while (cleaning) await new Promise(resolve => setTimeout(resolve, 10));
  // The process exits only after helpers have stopped writing screenshots.
  db.close();
  process.exit(0);
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, shutdown);
// The desktop owns this pipe. EOF also cleans up after an unexpected App exit.
if (desktopToken) { process.stdin.resume(); process.stdin.on('end', shutdown); }
