import test from 'node:test';
import assert from 'node:assert/strict';
import { WindowSessions, capturePreferences, expiredPendingCaptures } from '../capture-policy.mjs';
import { DatabaseSync } from 'node:sqlite';

const schema = `CREATE TABLE records (id TEXT PRIMARY KEY, frames TEXT, kind TEXT, status TEXT, model TEXT, scores TEXT, manual TEXT, created TEXT)`;
test('window sessions follow focus, not screenshot frequency or title; return threshold is inclusive', () => {
  const sessions=new WindowSessions();
  const first=sessions.observe('window-A',0,60);
  for(let t=1000;t<=120000;t+=1000) assert.equal(sessions.observe('window-A',t,60),first);
  const other=sessions.observe('window-B',121000,60);
  assert.notEqual(other,first);
  assert.equal(sessions.observe('window-A',181000,60),first,'Exactly one minute away rejoins');
  sessions.observe('window-B',182000,60);
  assert.notEqual(sessions.observe('window-A',242001,60),first,'Over one minute starts a new group');
  const current=sessions.observe('window-A',243000,60);
  sessions.observe(null,244000,60);
  assert.equal(sessions.observe('window-A',245000,60),current,'Excluded / no-window focus also tracks departures');
  sessions.observe('window-B',246000,0);
  assert.notEqual(sessions.observe('window-A',247000,0),current,'Zero disables return joining');
  const zero=sessions.observe('window-A',248000,0);
  sessions.observe('window-B',248000,0);
  assert.notEqual(sessions.observe('window-A',248000,0),zero);
});
test('custom timeout and missing focus observations do not join unrelated browsing periods', () => {
  const sessions=new WindowSessions();
  const first=sessions.observe('A',0,120);
  sessions.observe('B',1000,120);
  assert.equal(sessions.observe('A',91000,120),first);
  assert.notEqual(sessions.observe('A',300000,120),first,'Sleep/unobserved gaps split sessions');
  const previous=sessions.observe('A',301000,120);
  sessions.reset();assert.notEqual(sessions.observe('A',302000,120),previous);
  assert.deepEqual(capturePreferences({}),{windowReturnSeconds:60});
  for(const value of [-1,3601,1.5,'60']) assert.throws(()=>capturePreferences({windowReturnSeconds:value}));
});
test('retention keeps at least one hour, protects paused capture and completed / active / manual records, and caps batches', () => {
  const db=new DatabaseSync(':memory:');db.exec(schema);
  const now=Date.now();
  function insert(id,age,status='pending',kind='capture',model=null,scores='{}',manual='{}') {
    db.prepare('INSERT INTO records VALUES (?,?,?,?,?,?,?,?)').run(id,'[]',kind,status,model,scores,manual,new Date(now-age).toISOString());
  }
  insert('expired',3600001);insert('boundary',3600000);insert('recent',3599999);
  insert('processing',7200000,'processing');insert('error',7200000,'error');
  insert('unmatched',7200000,'unmatched');insert('classified',7200000,'classified');
  insert('manual',7200000,'pending','manual');insert('reclassifying',7200000,'pending','capture','model');
  insert('corrected',7200000,'pending','capture',null,'{}','{"topic":true}');
  assert.deepEqual(expiredPendingCaptures(db,{recording:false,now}),[]);
  assert.deepEqual(expiredPendingCaptures(db,{recording:true,now}).map(r=>r.id),['expired']);
  assert.equal(expiredPendingCaptures(db,{recording:true,now:now+3600000,limit:2}).length,2);
  db.close();
});
