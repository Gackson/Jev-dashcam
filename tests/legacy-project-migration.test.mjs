import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { planLegacyProjects, migrateLegacyProjects } from '../legacy-project-migration.mjs';

const time = seconds => new Date(Date.UTC(2026,0,1)+seconds*1000).toISOString();
const capture = (id, seconds, extra={}) => ({id, app:'Browser', title:'Page', frames:JSON.stringify([{time:time(seconds),image:id+'.jpg',text:'evidence '+id}]), created:time(seconds),kind:'capture',session_id:null,...extra});
test('historical inference requires exact app/title, bounded capture gap, and never overrides known sessions', () => {
  const rows=[capture('a',0),capture('other-app',10,{app:'Other'}),capture('b',60),capture('other-title',70,{title:'Another'}),capture('c',121),capture('d',122),capture('known',123,{session_id:'real-window'}),capture('manual',124,{kind:'manual'}),capture('invalid',125,{frames:'[]',created:'invalid'})];
  assert.deepEqual(planLegacyProjects(rows,60),[['a','b'],['c','d']]);
  assert.deepEqual(planLegacyProjects(rows,0),[]);
  assert.deepEqual(planLegacyProjects(rows,120),[['a','b','c','d']]);
});
test('historical backfill backs up first, changes only display membership, and is idempotent', () => {
  const dir=mkdtempSync(join(tmpdir(),'jev-legacy-project-'));
  const db=new DatabaseSync(join(dir,'jev.sqlite'));
  try {
    db.exec("CREATE TABLE records(id TEXT PRIMARY KEY, app TEXT,title TEXT,frames TEXT,created TEXT,kind TEXT,session_id TEXT,text TEXT,scores TEXT,status TEXT)");
    for(const row of [capture('a',0),capture('b',30),capture('c',180),capture('known',190,{session_id:'real-window'})]) db.prepare('INSERT INTO records VALUES(?,?,?,?,?,?,?,?,?,?)').run(row.id,row.app,row.title,row.frames,row.created,row.kind,row.session_id,'independent '+row.id,JSON.stringify({[row.id]:0.99}),'classified');
    const original=db.prepare('SELECT * FROM records ORDER BY id').all();
    const result=migrateLegacyProjects(db,dir,60);
    assert.equal(result.groups,1);assert.equal(result.captures,2);
    const backup=new DatabaseSync(join(result.backup,'jev.sqlite'),{readOnly:true});
    assert.deepEqual(backup.prepare('SELECT * FROM records ORDER BY id').all(),original);backup.close();
    const updated=db.prepare('SELECT * FROM records ORDER BY id').all();
    assert.equal(updated[0].session_id,updated[1].session_id);
    assert.match(updated[0].session_id,/^legacy-/);
    assert.equal(updated[2].session_id,null);assert.equal(updated[3].session_id,'real-window');
    for(let i=0;i<original.length;i++) assert.deepEqual({...updated[i],session_id:original[i].session_id},{...original[i]});
    assert.equal(migrateLegacyProjects(db,dir,120),null);
    assert.equal(readdirSync(join(dir,'backups')).length,1);
  } finally {db.close();rmSync(dir,{recursive:true,force:true});}
});
