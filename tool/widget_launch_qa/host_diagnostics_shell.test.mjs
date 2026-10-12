// Pure stubs only: no simulator, SDK, or real xcrun execution.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {launch,failure} from './host_diagnostics.mjs';
const shell=fs.readFileSync(new URL('./run_transport.sh',import.meta.url),'utf8');
const bash=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'/bin/bash';
function body(name) {
  const lines=shell.split(/\r?\n/);const start=lines.indexOf(name+'() {');
  assert.ok(start>=0);let depth=1;
  for(let i=start+1;i<lines.length;i++) {
    depth+=(lines[i].match(/\{/g)||[]).length-(lines[i].match(/\}/g)||[]).length;
    if(!depth) return lines.slice(start,i+1).join('\n');
  }
  throw Error('unclosed function');
}
function temp(fn) {const dir=fs.mkdtempSync(path.join(os.tmpdir(),'host-qa-'));try{fn(dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}
for(const status of [0,37]) test('launch status '+status+' is recorded without URI/output',()=>temp(dir=>{
  const output=path.join(dir,'launch.json');const uri='planflow://day?qaNonce=PRIVATE_TEST_NONCE';let calls=0;
  const actual=launch('OWNED-FAKE',uri,output,(tool,args,options)=>{
    calls++;assert.equal(tool,'xcrun');assert.deepEqual(args,['simctl','openurl','OWNED-FAKE',uri]);
    assert.equal(options.timeout,15000);assert.equal(options.killSignal,'SIGKILL');
    return {status,stdout:uri,stderr:'body header token '+uri};
  });
  assert.equal(actual,status);assert.equal(calls,1);
  const text=fs.readFileSync(output,'utf8');assert.doesNotMatch(text,/planflow|qaNonce|PRIVATE_TEST_NONCE|body|token/);
  const value=JSON.parse(text);assert.equal(value.status,status);assert.equal(value.callbackProof,false);assert.equal(value.stdout,'output_suppressed');assert.equal(value.stderr,'output_suppressed');assert.match(value.utc,/Z$/);
}));
test('execution errors or signals never publish or return launch success',()=>{
  for(const status of [0,37]) for(const kind of ['error','signal']) temp(dir=>{
    const output=path.join(dir,'launch.json');
    const result={status,stdout:'planflow://private',stderr:'private token',
      ...(kind==='error'?{error:Error('private')}:{signal:'SIGKILL'})};
    const actual=launch('OWNED','planflow://private',output,()=>result);
    assert.equal(actual,status===0?124:status);assert.notEqual(actual,0);
    const text=fs.readFileSync(output,'utf8');
    assert.doesNotMatch(text,/private|planflow|token|SIGKILL/);
    const value=JSON.parse(text);assert.equal(value.status,actual);
    assert.equal(value.outcome,'tool_unavailable_or_timeout');
  });
});
test('failed metadata publication cannot mask launch failure',()=>temp(dir=>{
  assert.equal(launch('OWNED','planflow://test',path.join(dir,'missing','out'),()=>({status:37})),37);
}));
test('failure screenshot is one owned-only bounded command even when tool fails',()=>temp(dir=>{
  let calls=0;const png=path.join(dir,'cold-failure.png');const out=path.join(dir,'failure.json');
  failure('OWNED-FAKE',png,out,path.join(dir,'absent-receipt'),(tool,args,options)=>{
    calls++;assert.equal(tool,'xcrun');assert.deepEqual(args,['simctl','io','OWNED-FAKE','screenshot',png]);
    assert.equal(options.timeout,15000);return {status:null,error:Error('private path/token'),stderr:'planflow://private'};
  });
  assert.equal(calls,1);const text=fs.readFileSync(out,'utf8');assert.doesNotMatch(text,/private|token|OWNED-FAKE/);
  assert.equal(JSON.parse(text).screenshot.status,124);assert.equal(JSON.parse(text).receiptPath.exists,'absent');
}));
for(const status of [0,37]) test('extracted launch wrapper retains original status '+status,()=>{
  const code=['set -euo pipefail','UDID=OWNED; RUN_OUT=/unused; DIAGNOSTICS=stub; ACTIVE_CASE=""',
    'node() { return '+status+'; }','observe_first_process() { echo "OBSERVED:$RUN_OUT/$ACTIVE_CASE-first-process.txt"; }',body('open_qa_url'),
    'open_qa_url applinks-cold "planflow://test?qaNonce=private"','echo FINISHED'].join('\n');
  const r=spawnSync(bash,['--noprofile','--norc','-c',code],{encoding:'utf8',timeout:5000});
  assert.equal(r.status,status);assert.match(r.stdout,/applinks-cold-first-process.txt/);if(status!==0) assert.doesNotMatch(r.stdout,/FINISHED/);
});
test('extracted EXIT cleanup preserves failure despite diagnostic failure and captures once',()=>{
  const code=['set -euo pipefail','UDID=OWNED; RUN_OUT=/unused; DIAGNOSTICS=stub; RECEIPTS=/unused/receipt; ACTIVE_CASE=applinks-cold; FAILURE_CAPTURED=0; LOGGER=999999',
    'node() { echo "$*" >> "$TRACE"; return 19; }','kill() { return 1; }',body('finish_transport'),
    'trap \'finish_transport "$?"\' EXIT','exit 37'].join('\n');
  temp(dir=>{const trace=path.join(dir,'trace');const r=spawnSync(bash,['--noprofile','--norc','-c',code],{env:{...process.env,TRACE:trace},encoding:'utf8',timeout:5000});
    assert.equal(r.status,37);const text=fs.readFileSync(trace,'utf8');assert.equal(text.trim().split('\n').length,1);assert.match(text,/failure OWNED \/unused\/applinks-cold-failure.png/);
  });
});
test('unchanged receipt verifier and fresh lifecycle guard remain separate from bounded milestones',()=>{
  assert.match(shell,/observe_process "\$RUN_OUT\/lifecycle-running.txt"/);
  assert.match(shell,/node "\$CHECKER" verify/);
  assert.match(shell,/\$poll" == 1 \|\| "\$poll" == 15/);
  assert.match(shell,/BLOCKED_TRANSPORT_RECEIPTS_BOOT_FILE_CHECK/);
  assert.match(shell,/cold-absence.txt/);
  assert.doesNotMatch(shell,/simctl launch|debugger/);
});
