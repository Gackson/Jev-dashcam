import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const navigation = '首页\n搜索\n收藏\n我的\n固定导航\n';
const schema = `
CREATE TABLE topics (id TEXT PRIMARY KEY, name TEXT, description TEXT, color TEXT, created TEXT);
CREATE TABLE records (id TEXT PRIMARY KEY, title TEXT, app TEXT, url TEXT, text TEXT, frames TEXT DEFAULT '[]', scores TEXT DEFAULT '{}', manual TEXT DEFAULT '{}', status TEXT DEFAULT 'pending', error TEXT, model TEXT, created TEXT, updated TEXT, kind TEXT DEFAULT 'capture');
CREATE TABLE seen (hash TEXT PRIMARY KEY, record_id TEXT);`;

test('old groups are backed up and split; same-app same-title captures classify and export independently across restarts', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jev-isolation-'));
  const shots = join(directory, 'screenshots'); mkdirSync(shots);
  const db = new DatabaseSync(join(directory, 'jev.sqlite')); db.exec(schema);
  for (const [id, name] of [['ai', 'AI'], ['coffee', 'Coffee']]) db.prepare('INSERT INTO topics VALUES (?,?,?,?,?)').run(id, name, name, 'sage', '2026-01-01');
  const frames = [
    { image: 'aa-11.jpg', text: navigation + 'AI_BODY old independent neural network source', time: '2026-01-01T01:00:00Z' },
    { image: 'aa-22.jpg', text: navigation + 'COFFEE_BODY old independent brewing source', time: '2026-01-01T01:00:01Z' },
  ];
  frames.forEach(frame => writeFileSync(join(shots, frame.image), 'synthetic image'));
  db.prepare('INSERT INTO records (id,title,app,url,text,frames,scores,manual,status,created,updated,kind) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)').run(
    'old-group', 'Same title', 'Same app', '', frames.map(f => f.text).join('\n'), JSON.stringify(frames), '{"ai":0.99,"coffee":0.99}', '{"ai":true}', 'classified', frames[0].time, frames[1].time, 'capture');
  db.close();
  const preload = join(directory, 'mock-model.mjs');
  writeFileSync(preload, `import {appendFileSync} from 'node:fs';
const original = globalThis.fetch;
globalThis.fetch = async (url, options) => {
 if (url !== 'https://api.typesafe.ai/v1/systemone') return original(url, options);
 const payload=JSON.parse(options.body), text=payload.state.document.text;
 appendFileSync(process.env.JEV_TEST_LOG,JSON.stringify(payload.state.document)+'\\n');
 if (text.includes('AI_BODY') === text.includes('COFFEE_BODY')) return new Response('{}',{status:400});
 const answers=Object.fromEntries(Object.entries(payload.questions).map(([id,q])=>[id,{type:'noul',noul: text.includes(q.instructions.topic==='AI'?'AI_BODY':'COFFEE_BODY')?0.99:0.01}]));
 return new Response(JSON.stringify({model:'mock',answers}));
};`);
  const helper = join(directory, 'capture-helper');
  const newFrames = [
    { image: 'aa-33.jpg', text: navigation + 'AI_BODY new neural network page' },
    { image: 'aa-44.jpg', text: navigation + 'COFFEE_BODY new brewing page' },
    { image: 'aa-55.jpg', text: navigation + 'COFFEE_BODY new brewing page' },
  ];
  writeFileSync(helper, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs'; import {join} from 'node:path';
console.log(JSON.stringify({type:'ready'}));
for (const f of ${JSON.stringify(newFrames)}) {
 writeFileSync(join(process.argv[2],f.image),'synthetic image');
 console.log(JSON.stringify({type:'capture',app:'Same app',title:'Same title',text:f.text,screenshot:f.image}));
}
setInterval(()=>{},1000);`, { mode: 0o700 });
  let child, exited;
  async function launch() {
    child = spawn(process.execPath, ['--import', preload, 'server.mjs'], { env: { ...process.env, PORT: '0', JEV_DATA_DIR: directory, JEV_ENV_FILE: '/dev/null', JEV_DESKTOP_TOKEN: 'test-isolation', TYPESAFE_API_KEY: 'test-only', JEV_CAPTURE_HELPER: helper, JEV_TEST_LOG: join(directory, 'calls.jsonl') }, stdio: ['pipe', 'pipe', 'pipe'] });
    exited = new Promise(resolve => child.once('exit', resolve));
    const port = await new Promise((resolve, reject) => {
      let buffer='', stderr=''; const timer=setTimeout(()=>reject(new Error('startup timeout '+stderr)),5000);
      child.stderr.on('data',chunk=>stderr+=chunk);
      child.once('exit',code=>{clearTimeout(timer);reject(new Error(`exit ${code}: ${stderr}`));});
      child.stdout.on('data',chunk=>{buffer+=chunk;if(buffer.includes('\n')){clearTimeout(timer);resolve(JSON.parse(buffer.split('\n')[0]).port);}});
    });
    return async (path, method='GET') => {
      const r=await fetch(`http://127.0.0.1:${port}${path}`,{method,headers:{Authorization:'Bearer test-isolation','Content-Type':'application/json'},...(method==='POST'?{body:'{}'}:{})});
      assert.equal(r.status,200);return r.json();
    };
  }
  async function settled(request, count) {
    for(let i=0;i<200;i++) {
      const state=await request('/api/state');
      if(state.records.length===count && state.status.queue===0) return state;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    const state = await request('/api/state');
    throw new Error('classification did not settle: ' + JSON.stringify({count:state.records.length,status:state.status,errors:state.records.map(r=>r.error)}));
  }
  try {
    let request = await launch();
    let state = await settled(request, 2);
    assert.ok(state.records.every(r => r.frames.length===1 && r.labels.length===1 && Object.keys(r.manual).length===0));
    assert.deepEqual(new Set(state.records.map(r=>r.labels[0])),new Set(['ai','coffee']));
    const backupFolder=join(directory,'backups',readdirSync(join(directory,'backups')).find(name=>name.startsWith('before-independent-capture-')));
    const backup=new DatabaseSync(join(backupFolder,'jev.sqlite'),{readOnly:true});
    assert.equal(JSON.parse(backup.prepare('SELECT frames FROM records').get().frames).length,2);backup.close();
    assert.ok(existsSync(join(backupFolder,'screenshots','aa-11.jpg')));
    await request('/api/capture/start','POST'); state=await settled(request,4);
    assert.ok(state.records.every(r=>r.frames.length===1 && r.labels.length===1 && r.status==='classified'));
    assert.equal(state.records.filter(r=>r.labels.includes('ai')).length,2);
    assert.equal(state.records.filter(r=>r.labels.includes('coffee')).length,2);
    assert.ok(state.records.filter(r=>r.labels.includes('ai')).every(r=>!r.text.includes('COFFEE_BODY')));
    const exported=await request('/api/export');
    assert.ok(exported.records.filter(r=>r.labels.includes('coffee')).every(r=>r.frames[0].text.includes('COFFEE_BODY')));
    await request('/api/capture/stop','POST');
    assert.equal(existsSync(join(shots,'aa-55.jpg')),false,'Only the exact duplicate screenshot is removed');
    child.stdin.end(); await exited;
    request=await launch();state=await settled(request,4);
    assert.equal(readdirSync(join(directory,'backups')).length,2,'Independent capture and historical display grouping each back up once; restarting is idempotent');
    assert.equal(readFileSync(join(directory,'calls.jsonl'),'utf8').trim().split('\n').length,4,'Each screenshot receives one independent request; restart does not rerun completed judgments');
    child.stdin.end();await exited;
  } finally {
    if(child?.exitCode===null) { child.kill();await exited; }
    rmSync(directory,{recursive:true,force:true});
  }
});
