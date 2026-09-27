import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('capture continues above 12 queued jobs; periodic cleanup only runs while recording; settings and groups persist', async () => {
  const dir=mkdtempSync(join(tmpdir(),'jev-backlog-'));mkdirSync(join(dir,'screenshots'));
  const db=new DatabaseSync(join(dir,'jev.sqlite'));
  db.exec(`CREATE TABLE topics (id TEXT PRIMARY KEY, name TEXT, description TEXT, color TEXT, created TEXT);
    CREATE TABLE records (id TEXT PRIMARY KEY,title TEXT,app TEXT,url TEXT,text TEXT,frames TEXT DEFAULT '[]',scores TEXT DEFAULT '{}',manual TEXT DEFAULT '{}',status TEXT DEFAULT 'pending',error TEXT,model TEXT,created TEXT,updated TEXT,kind TEXT DEFAULT 'capture');
    CREATE TABLE seen (hash TEXT PRIMARY KEY,record_id TEXT);`);
  db.prepare('INSERT INTO topics VALUES (?,?,?,?,?)').run('topic','Topic','Test','sage',new Date().toISOString());
  const old=new Date(Date.now()-7200000).toISOString(), now=new Date().toISOString();
  for(const [id,status,date] of [['active','pending',now],['expired','pending',old],['failed','error',old],['done','unmatched',old]]) {
    const image=id==='expired'?'aa-11.jpg':null;
    db.prepare('INSERT INTO records(id,title,app,url,text,frames,status,created,updated,kind) VALUES(?,?,?,?,?,?,?,?,?,?)').run(id,id,'Test','','Synthetic evidence '+id,JSON.stringify(image?[{image,text:'synthetic',time:date}]:[]),status,date,date,'capture');
  }
  writeFileSync(join(dir,'screenshots','aa-11.jpg'),'synthetic');
  db.prepare('INSERT INTO seen VALUES (?,?)').run('expired-fingerprint','expired');db.close();
  const preload=join(dir,'mock.mjs');
  writeFileSync(preload,`const realInterval=globalThis.setInterval;globalThis.setInterval=(fn,ms,...args)=>realInterval(fn,ms===300000?50:ms,...args);
const original=globalThis.fetch;globalThis.fetch=(url,options)=>url==='https://api.typesafe.ai/v1/systemone'?new Promise(()=>{}):original(url,options);`);
  const helper=join(dir,'helper.mjs');
  writeFileSync(helper,`#!${process.execPath}\nconsole.log(JSON.stringify({type:'ready'}));
console.log(JSON.stringify({type:'focus',windowKey:'first-window'}));
for(let i=0;i<20;i++) console.log(JSON.stringify({type:'capture',windowKey:'first-window',app:'Browser',title:'Changing title '+i,text:'Synthetic independent capture number '+i}));
console.log(JSON.stringify({type:'focus',windowKey:'second-window'}));
console.log(JSON.stringify({type:'capture',windowKey:'second-window',app:'Browser',title:'Changing title 0',text:'Synthetic second window evidence'}));
console.log(JSON.stringify({type:'focus',windowKey:'first-window'}));
console.log(JSON.stringify({type:'capture',windowKey:'first-window',app:'Browser',title:'Return',text:'Synthetic returned window evidence'}));
setInterval(()=>{},1000);`,{mode:0o700});
  let child,exited;
  async function launch() {
    child=spawn(process.execPath,['--import',preload,'server.mjs'],{env:{...process.env,PORT:'0',JEV_DATA_DIR:dir,JEV_ENV_FILE:'/dev/null',JEV_DESKTOP_TOKEN:'backlog-test',JEV_CAPTURE_HELPER:helper,TYPESAFE_API_KEY:'test-only'},stdio:['pipe','pipe','pipe']});
    exited=new Promise(resolve=>child.once('exit',resolve));
    const port=await new Promise((resolve,reject)=>{
      let out='',err='';const timer=setTimeout(()=>reject(new Error('timeout '+err)),5000);
      child.stderr.on('data',chunk=>err+=chunk);child.once('exit',()=>{clearTimeout(timer);reject(new Error(err));});
      child.stdout.on('data',chunk=>{out+=chunk;if(out.includes('\n')){clearTimeout(timer);resolve(JSON.parse(out.split('\n')[0]).port);}});
    });
    return async(path,body)=>{const response=await fetch(`http://127.0.0.1:${port}/api/${path}`,{method:body?'POST':'GET',headers:{Authorization:'Bearer backlog-test','Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});assert.equal(response.status,200);return response.json();};
  }
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  try {
    let request=await launch();await wait(200);
    assert.ok((await request('state')).records.some(r=>r.id==='expired'),'Paused capture does not delete backlog');
    await request('capture-preferences',{windowReturnSeconds:120});
    await request('capture/start',{});
    let state;
    for(let i=0;i<100;i++) { state=await request('state');if(state.status.queue>12&&!state.records.some(r=>r.id==='expired'))break;await wait(50); }
    assert.equal(state.status.capture,'running');assert.ok(state.status.queue>12);
    assert.ok(!state.records.some(r=>r.id==='expired'));
    assert.ok(state.records.some(r=>r.id==='active'&&r.status==='processing'));
    assert.ok(state.records.some(r=>r.id==='failed'));assert.ok(state.records.some(r=>r.id==='done'));
    for(let i=0;i<100&&existsSync(join(dir,'screenshots','aa-11.jpg'));i++) await wait(20);
    assert.equal(existsSync(join(dir,'screenshots','aa-11.jpg')),false);
    const check=new DatabaseSync(join(dir,'jev.sqlite'));assert.equal(check.prepare("SELECT * FROM seen WHERE record_id='expired'").get(),undefined);
    const captures=state.records.filter(r=>r.app==='Browser');
    assert.equal(captures.length,22);assert.equal(new Set(captures.map(r=>r.session_id)).size,2);
    const returned=captures.find(r=>r.title==='Return');assert.equal(captures.filter(r=>r.session_id===returned.session_id).length,21);
    await request('capture/stop',{});
    check.prepare("INSERT INTO records(id,title,text,status,created,updated,kind) VALUES('paused-old','paused','test','pending',?,?,'capture')").run(old,old);check.close();
    await wait(200);assert.ok((await request('state')).records.some(r=>r.id==='paused-old'));
    child.stdin.end();await exited;
    request=await launch();state=await request('state');
    assert.equal(state.capturePreferences.windowReturnSeconds,120);
    assert.equal(state.records.find(r=>r.id===returned.id).session_id,returned.session_id);
    child.stdin.end();await exited;
  } finally {if(child?.exitCode===null){child.kill();await exited;}rmSync(dir,{recursive:true,force:true});}
});
