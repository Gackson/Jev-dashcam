import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateExclusions, isWindowExcluded } from '../window-exclusions.mjs';

const rule = { id: 'one', app: 'Browser', bundleID: 'test.browser', title: 'Private', match: 'exact' };
test('exclusions match a specific app and title, validate input and support explicit keywords', () => {
  const rules = validateExclusions([rule]);
  assert.equal(isWindowExcluded(rules, { app: 'Browser', bundleID: 'test.browser', title: 'Private' }), true);
  assert.equal(isWindowExcluded(rules, { app: 'Browser', bundleID: 'test.browser', title: 'Public' }), false);
  assert.equal(isWindowExcluded(rules, { app: 'Browser', bundleID: 'another.browser', title: 'Private' }), false);
  assert.equal(isWindowExcluded(rules, { bundleID: 'test.browser', title: 'Private 2' }), false);
  assert.equal(isWindowExcluded([{ ...rule, match: 'contains' }], { bundleID: 'test.browser', title: 'Private 2' }), true);
  assert.equal(isWindowExcluded([{ ...rule, bundleID: '' }], { app: 'Browser', title: 'Private' }), true);
  for (const bad of [[{ ...rule, title: ' ' }], [{ ...rule, app: '' }], [{ ...rule, match: 'anything' }], [rule, rule]]) assert.throws(() => validateExclusions(bad));
});

test('rules persist and take effect during capture; excluded frames never enter the library', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jev-exclusions-'));
  const helper = join(directory, 'helper.mjs');
  writeFileSync(helper, `#!${process.execPath}\nimport {writeFileSync,existsSync} from 'node:fs';import {join} from 'node:path';
console.log(JSON.stringify({type:'ready'}));
let n=0;setInterval(()=>{n++;const blocked=n%2===1;const screenshot=(blocked?'aa-':'bb-')+n.toString(16)+'.jpg';writeFileSync(join(process.argv[2],screenshot),'synthetic');console.log(JSON.stringify({type:'capture',app:'Browser',bundleID:'test.browser',title:blocked?'Private':'Public',text:'Synthetic '+(blocked?'private':'public')+' capture number '+n,screenshot}));},80);`, { mode: 0o700 });
  let child, exit;
  async function launch() {
    child = spawn(process.execPath, ['server.mjs'], { env: { ...process.env, PORT: '0', JEV_DATA_DIR: directory, JEV_ENV_FILE: '/dev/null', JEV_DESKTOP_TOKEN: 'exclusions-test', JEV_CAPTURE_HELPER: helper }, stdio: ['pipe','pipe','pipe'] });
    exit = new Promise(resolve => child.once('exit', resolve));
    const port = await new Promise((resolve,reject) => {
      let output='', stderr='';const timer=setTimeout(()=>reject(new Error('startup timeout '+stderr)),5000);
      child.stderr.on('data',chunk=>stderr+=chunk);
      child.once('exit',()=>{clearTimeout(timer);reject(new Error(stderr));});
      child.stdout.on('data',chunk=>{output+=chunk;if(output.includes('\n')){clearTimeout(timer);resolve(JSON.parse(output.split('\n')[0]).port);}});
    });
    return async (path, body) => {
      const response = await fetch(`http://127.0.0.1:${port}/api/${path}`, { method:body?'POST':'GET',headers:{Authorization:'Bearer exclusions-test','Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}) });
      assert.equal(response.status,200);return response.json();
    };
  }
  const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
  async function until(request, predicate) {
    for (let i=0;i<100;i++) {
      const state=await request('state');
      if(predicate(state)) return state;
      await wait(100);
    }
    throw new Error('Capture did not settle: '+JSON.stringify((await request('state')).status));
  }
  try {
    let request=await launch();
    await request('window-exclusions',{rules:[rule]});
    await request('capture/start',{});
    let state=await until(request, state=>state.records.length>=2);
    assert.ok(state.records.length>0, JSON.stringify(state.status));
    assert.ok(state.records.every(item=>item.title==='Public'));
    assert.equal(existsSync(join(directory,'screenshots','aa-1.jpg')),false);
    await request('window-exclusions',{rules:[]});
    state=await until(request, state=>state.records.some(item=>item.title==='Private'));assert.ok(state.records.some(item=>item.title==='Private'));
    await request('window-exclusions',{rules:[rule]});
    await request('capture/stop',{});
    child.stdin.end();await exit;
    request=await launch();
    assert.deepEqual((await request('state')).windowExclusions,[rule]);
    child.stdin.end();await exit;
  } finally {
    if(child?.exitCode===null){child.kill();await exit;}
    rmSync(directory,{recursive:true,force:true});
  }
});
