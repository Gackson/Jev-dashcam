// One-time copy of the web prototype's data. Never changes or removes the source.
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync, renameSync, rmSync, chmodSync } from 'node:fs';
import { dirname, join, resolve, basename } from 'node:path';
import { homedir } from 'node:os';
import { parseEnv } from 'node:util';
import { fileURLToPath } from 'node:url';

const project = dirname(dirname(fileURLToPath(import.meta.url)));
const source = resolve(process.env.JEV_MIGRATE_SOURCE || join(project, 'data'));
const target = resolve(process.env.JEV_APP_DATA_DIR || join(homedir(), 'Library', 'Application Support', 'Dashcam'));
if (existsSync(target)) throw new Error(`目标目录已存在，未覆盖任何数据：${target}`);
if (!existsSync(join(source, 'jev.sqlite'))) throw new Error('找不到旧版资料库');
mkdirSync(dirname(target), { recursive: true });
const staging = mkdtempSync(join(dirname(target), '.jev-import-'));
try {
  const original = new DatabaseSync(join(source, 'jev.sqlite'), { readOnly: true });
  try { original.exec(`VACUUM INTO '${join(staging, 'jev.sqlite').replaceAll("'", "''")}'`); }
  finally { original.close(); }
  chmodSync(join(staging, 'jev.sqlite'), 0o600);
  mkdirSync(join(staging, 'screenshots'), { mode: 0o700 });
  const snapshot = new DatabaseSync(join(staging, 'jev.sqlite'), { readOnly: true });
  let count = 0;
  try {
    const notes = snapshot.prepare('SELECT frames FROM records').all();
    count = notes.length;
    for (const note of notes) for (const frame of JSON.parse(note.frames)) {
      if (basename(frame.image) !== frame.image || !/^[a-f0-9-]+\.jpg$/.test(frame.image)) throw new Error('无效的截图路径');
      copyFileSync(join(source, 'screenshots', frame.image), join(staging, 'screenshots', frame.image));
      chmodSync(join(staging, 'screenshots', frame.image), 0o600);
    }
  } finally { snapshot.close(); }
  const envFile = process.env.JEV_MIGRATE_ENV || join(project, '.env');
  if (existsSync(envFile)) {
    const values = parseEnv(readFileSync(envFile, 'utf8'));
    writeFileSync(join(staging, 'settings.json'), JSON.stringify({ apiKey: values.TYPESAFE_API_KEY || '', model: values.TYPESAFE_MODEL || 'jev-latest' }), { mode: 0o600 });
  }
  // Rename only into an absent destination; callers should keep the App closed.
  if (existsSync(target)) throw new Error('目标目录已被创建，请关闭 App 后再迁移');
  renameSync(staging, target);
  console.log(`已复制 ${count} 份资料至 ${target}。旧版数据保持不变。`);
} catch (error) {
  rmSync(staging, { recursive: true, force: true });
  throw error;
}
