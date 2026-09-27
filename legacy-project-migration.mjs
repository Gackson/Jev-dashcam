import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, chmodSync } from 'node:fs';
import { join } from 'node:path';

// Old captures have no OS window identity or focus history. Only join exact
// app/title matches with a bounded capture gap; never infer across long gaps.
export function planLegacyProjects(rows, returnSeconds = 60) {
  const recent = new Map(), groups = [];
  const ordered = rows.filter(row => row.kind === 'capture' && !row.session_id)
    .map(row => ({ row, time: Date.parse(JSON.parse(row.frames)[0]?.time || row.created) }))
    .filter(item => Number.isFinite(item.time) && item.row.app?.trim() && item.row.title?.trim())
    .sort((a, b) => a.time - b.time || a.row.id.localeCompare(b.row.id));
  for (const { row, time } of ordered) {
    const key = JSON.stringify([row.app, row.title]);
    let group = recent.get(key);
    if (!group || returnSeconds === 0 || time - group.lastTime > returnSeconds * 1000) {
      group = { ids: [], lastTime: time }; groups.push(group); recent.set(key, group);
    }
    group.ids.push(row.id); group.lastTime = time;
  }
  return groups.filter(group => group.ids.length > 1).map(group => group.ids);
}

export function migrateLegacyProjects(db, dataDir, returnSeconds = 60) {
  const name = 'legacy-project-display-v1';
  db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, completed TEXT NOT NULL)');
  if (db.prepare('SELECT name FROM schema_migrations WHERE name=?').get(name)) return null;
  const groups = planLegacyProjects(db.prepare('SELECT id, app, title, frames, created, kind, session_id FROM records').all(), returnSeconds);
  let backup = null;
  if (groups.length) {
    const folder = join(dataDir, 'backups'); mkdirSync(folder, { recursive: true, mode: 0o700 });
    backup = mkdtempSync(join(folder, 'before-project-grouping-'));
    db.exec(`VACUUM INTO '${join(backup, 'jev.sqlite').replaceAll("'", "''")}'`);
    chmodSync(join(backup, 'jev.sqlite'), 0o600);
  }
  db.exec('BEGIN IMMEDIATE');
  try {
    const update = db.prepare('UPDATE records SET session_id=? WHERE id=? AND session_id IS NULL');
    for (const ids of groups) {
      const project = 'legacy-' + randomUUID();
      for (const id of ids) update.run(project, id);
    }
    db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(name, new Date().toISOString());
    db.exec('COMMIT');
  } catch (error) { db.exec('ROLLBACK'); throw error; }
  return { groups: groups.length, captures: groups.reduce((count, ids) => count + ids.length, 0), backup };
}
