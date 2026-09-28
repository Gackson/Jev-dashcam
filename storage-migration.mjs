// Called only after the desktop service (and capture helper) have stopped.
// Keep the source as a recovery copy; never merge two libraries.
import { createReadStream, existsSync } from 'node:fs';
import { lstat, realpath, readdir, mkdir, mkdtemp, copyFile, chmod, rename, rmdir, rm } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

async function canonical(path) {
  path = resolve(path);
  if (existsSync(path)) return realpath(path);
  return join(await canonical(dirname(path)), basename(path));
}
function inside(parent, child) {
  const path = relative(parent, child);
  return !path || (path !== '..' && !path.startsWith(`..${sep}`) && !path.startsWith(sep));
}
async function inventory(root, prefix = '') {
  const files = [];
  for (const name of (await readdir(join(root, prefix))).sort()) {
    const path = join(prefix, name);
    // SQLite recreates its shared-memory index. The database and WAL hold data.
    if (path === 'jev.sqlite-shm') continue;
    const info = await lstat(join(root, path));
    if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) {
      throw new Error('资料目录中存在链接或特殊文件，未迁移。请先将其移出资料目录。');
    }
    files.push({ path, directory: info.isDirectory() });
    if (info.isDirectory()) files.push(...await inventory(root, path));
  }
  return files;
}
async function digest(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
export async function validateDestination(source, destination) {
  const from = await canonical(source), to = await canonical(destination);
  if (inside(from, to) || inside(to, from)) throw new Error('请选择当前资料目录以外的位置，不能使用其父目录或子目录。');
  if (existsSync(to) && (!(await lstat(to)).isDirectory() || (await readdir(to)).length)) {
    throw new Error('目标文件夹不是空文件夹。请选择或新建一个空文件夹，避免覆盖已有数据。');
  }
  return { from, to };
}
export async function migrateStorage(source, destination) {
  const { from, to } = await validateDestination(source, destination);
  if (!existsSync(join(from, 'jev.sqlite'))) throw new Error('原位置的资料库不存在，未修改存储位置。');
  const entries = await inventory(from);
  await mkdir(dirname(to), { recursive: true });
  const stage = await mkdtemp(join(dirname(to), '.dashcam-migration-'));
  try {
    await chmod(stage, 0o700);
    for (const entry of entries) {
      const target = join(stage, entry.path);
      if (entry.directory) await mkdir(target, { mode: 0o700 });
      else {
        await copyFile(join(from, entry.path), target);
        await chmod(target, 0o600);
        if (await digest(join(from, entry.path)) !== await digest(target)) throw new Error('文件校验失败，原资料保持不变。');
      }
    }
    if (JSON.stringify(entries) !== JSON.stringify(await inventory(from))) throw new Error('迁移期间原目录发生变化，请关闭其他实例后重试。');
    const db = new DatabaseSync(join(stage, 'jev.sqlite'), { readOnly: true });
    try {
      if (db.prepare('PRAGMA quick_check').all().some(row => Object.values(row)[0] !== 'ok')) throw new Error('资料库完整性校验失败。');
      for (const row of db.prepare('SELECT frames FROM records').all()) {
        for (const frame of JSON.parse(row.frames)) {
          if (basename(frame.image) !== frame.image || !existsSync(join(stage, 'screenshots', frame.image))) throw new Error('资料库引用的截图缺失，原资料保持不变。');
        }
      }
    } finally { db.close(); }
    // Recheck immediately before publishing, and never replace a populated folder.
    await validateDestination(from, to);
    if (existsSync(to)) await rmdir(to); // fails if anything was added to it
    await rename(stage, to);
    return { directory: to, files: entries.filter(entry => !entry.directory).length };
  } catch (error) {
    await rm(stage, { recursive: true, force: true });
    throw error;
  }
}

if (process.argv[1] && await canonical(process.argv[1]) === await canonical(fileURLToPath(import.meta.url))) {
  try {
    const [source, destination, mode] = process.argv.slice(2);
    if (!source || !destination) throw new Error('缺少资料路径。');
    const result = mode === '--validate' ? await validateDestination(source, destination) : await migrateStorage(source, destination);
    console.log(JSON.stringify(result));
  } catch (error) {
    // Messages contain filesystem diagnostics, never file contents or credentials.
    console.log(JSON.stringify({ error: error.message }));
    process.exitCode = 1;
  }
}
