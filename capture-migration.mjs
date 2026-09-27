import { mkdirSync, mkdtempSync, cpSync, existsSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fingerprint } from './core.mjs';

// Run before classification starts. The transaction and marker make this restart-safe.
export function migrateCaptureRecords(db, dataDir) {
  db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, completed TEXT NOT NULL)');
  const name = 'independent-capture-v1';
  if (db.prepare('SELECT name FROM schema_migrations WHERE name=?').get(name)) return null;
  const groups = db.prepare("SELECT * FROM records WHERE kind='capture'").all()
    .map(row => ({ row, frames: JSON.parse(row.frames) })).filter(item => item.frames.length > 1);
  for (const { frames } of groups) for (const frame of frames) {
    if (typeof frame.text !== 'string' || !/^[a-f0-9-]+\.jpg$/.test(frame.image)) {
      throw new Error('旧截图资料不完整，已停止升级；原资料保持不变。');
    }
  }
  let backup = null;
  if (groups.length) {
    const backups = join(dataDir, 'backups');
    mkdirSync(backups, { recursive: true, mode: 0o700 });
    backup = mkdtempSync(join(backups, 'before-independent-capture-'));
    db.exec(`VACUUM INTO '${join(backup, 'jev.sqlite').replaceAll("'", "''")}'`);
    chmodSync(join(backup, 'jev.sqlite'), 0o600);
    if (existsSync(join(dataDir, 'screenshots'))) cpSync(join(dataDir, 'screenshots'), join(backup, 'screenshots'), { recursive: true });
  }
  let count = 0;
  db.exec('BEGIN IMMEDIATE');
  try {
    db.exec('CREATE TABLE IF NOT EXISTS legacy_capture_groups (id TEXT PRIMARY KEY, original TEXT NOT NULL)');
    const insert = db.prepare('INSERT INTO records (id,title,app,url,text,frames,scores,manual,status,error,model,created,updated,kind) VALUES (?,?,?,?,?,?,\'{}\',\'{}\',\'pending\',NULL,NULL,?,?,\'capture\')');
    for (const { row, frames } of groups) {
      db.prepare('INSERT INTO legacy_capture_groups VALUES (?,?)').run(row.id, JSON.stringify(row));
      db.prepare('DELETE FROM seen WHERE record_id=?').run(row.id);
      db.prepare('DELETE FROM records WHERE id=?').run(row.id);
      frames.forEach((frame, index) => {
        const id = index === 0 ? row.id : randomUUID();
        const time = Number.isFinite(Date.parse(frame.time)) ? frame.time : row.created;
        insert.run(id, row.title, row.app, row.url, frame.text, JSON.stringify([frame]), time, time);
        db.prepare('INSERT OR IGNORE INTO seen VALUES (?,?)').run(fingerprint(frame.text), id);
        count++;
      });
    }
    db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(name, new Date().toISOString());
    db.exec('COMMIT');
  } catch (error) { db.exec('ROLLBACK'); throw error; }
  return { groups: groups.length, captures: count, backup };
}
