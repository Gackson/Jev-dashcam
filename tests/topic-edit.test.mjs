import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('topic edits preserve existing work and classifications, new captures use edited metadata, retention settings persist independently', async () => {
  const dir=mkdtempSync(join(tmpdir(),'jev-topic-edit-')), log=join(dir,'calls.jsonl'), release=join(dir,'release');
  const preload=join(dir,'mock.mjs');
  writeFileSync(preload,`import {appendFileSync,existsSync} from 'node:fs';
const original=globalThis.fetch;
globalThis.fetch=async(url,options)=>{
 if(url!=='https://api.typesafe.ai/v1/systemone')return original(url,options);
 const payload=JSON.parse(options.body);appendFileSync(${JSON.stringify(log)},JSON.stringify(payload)+'\\n');
 if(payload.state.document.text.includes('SLOW'))while(!existsSync(${JSON.stringify(release)}))await new Promise(r=>setTimeout(r,20));
 return new Response(JSON.stringify({model:'mock',answers:Object.fromEntries(Object.entries(payload.questions).map(([id,q])=>[id,{type:'noul',noul:q.instructions.topic==='Old title'?0.99:0.01}]))}));
};`);
  let child,exited;
  async function launch(){
    child=spawn(process.execPath,['--import',preload,'server.mjs'],{env:{...process.env,PORT:'0',JEV_DATA_DIR:dir,JEV_ENV_FILE:'/dev/null',JEV_DESKTOP_TOKEN:'topic-edit-test',TYPESAFE_API_KEY:'test-only'},stdio:['pipe','pipe','pipe']});
    exited=new Promise(resolve=>child.once('exit',resolve));
    const port=await new Promise((resolve,reject)=>{let out='',err='';const timer=setTimeout(()=>reject(Error('timeout '+err)),5000);child.stderr.on('data',chunk=>err+=chunk);child.once('exit',()=>{clearTimeout(timer);reject(Error(err));});child.stdout.on('data',chunk=>{out+=chunk;if(out.includes('\n')){clearTimeout(timer);resolve(JSON.parse(out.split('\n')[0]).port);}});});
    return async(path,body,method=body?'POST':'GET',expected=200)=>{const r=await fetch(`http://127.0.0.1:${port}/api/${path}`,{method,headers:{Authorization:'Bearer topic-edit-test','Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});assert.equal(r.status,expected);return r.json();};
  }
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  async function until(request,predicate){for(let i=0;i<150;i++){const s=await request('state');if(predicate(s))return s;await wait(30);}throw Error('did not settle');}
  const calls=()=>existsSync(log)?readFileSync(log,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
  try{
    let request=await launch();
    const topic=await request('topics',{name:'Old title',description:'Old description'});
    await request('topics',{name:'Other topic',description:''});
    const completed=await request('import',{text:'COMPLETED original independent evidence'});
    let state=await until(request,s=>s.status.queue===0);
    const before=state.records.find(r=>r.id===completed.id);
    await request('import',{text:'SLOW in-flight independent evidence'});
    await until(request,s=>s.records.some(r=>r.text.startsWith('SLOW')&&r.status==='processing'));
    await request('import',{text:'QUEUED original independent evidence'});
    await request('topics/'+topic.id,{name:' New title ',description:'New description'},'PATCH');
    state=await request('state');
    assert.deepEqual(state.records.find(r=>r.id===completed.id),before,'Existing records are not rewritten or requeued');
    assert.equal(state.topics.find(t=>t.id===topic.id).name,'New title');
    await request('topics/'+topic.id,{name:'Other topic',description:''},'PATCH',400);
    await request('topics/'+topic.id,{name:' ',description:''},'PATCH',400);
    await request('topics/missing',{name:'Missing',description:''},'PATCH',404);
    const newItem=await request('import',{text:'NEW independent evidence after topic edit'});
    writeFileSync(release,'go');
    state=await until(request,s=>s.status.queue===0);
    const requests=calls();assert.equal(requests.length,4,'No extra classification calls caused by editing');
    for(const call of requests){const expected=call.state.document.text.startsWith('NEW')?'New':'Old';assert.equal(call.questions[topic.id].instructions.topic,expected+' title');assert.equal(call.questions[topic.id].instructions.goal,expected+' description');}
    assert.deepEqual(state.records.find(r=>r.id===completed.id),before);
    assert.deepEqual(state.records.find(r=>r.id===newItem.id).labels,[]);
    await request('capture-preferences',{pendingRetentionHours:6});
    await request('capture-preferences',{windowReturnSeconds:90});
    assert.deepEqual((await request('state')).capturePreferences,{windowReturnSeconds:90,pendingRetentionHours:6});
    for(const hours of [-1,721,1.5,'2'])await request('capture-preferences',{pendingRetentionHours:hours},'POST',400);
    child.stdin.end();await exited;request=await launch();state=await request('state');
    assert.equal(state.topics.find(t=>t.id===topic.id).description,'New description');
    assert.deepEqual(state.capturePreferences,{windowReturnSeconds:90,pendingRetentionHours:6});
    assert.equal(calls().length,4,'Restart does not reclassify completed records');
    await request('capture-preferences',{pendingRetentionHours:0});
    assert.equal((await request('state')).capturePreferences.pendingRetentionHours,0);
    child.stdin.end();await exited;
  }finally{if(child?.exitCode===null){child.kill();await exited;}rmSync(dir,{recursive:true,force:true});}
});
