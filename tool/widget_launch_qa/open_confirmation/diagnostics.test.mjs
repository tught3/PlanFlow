import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {formatDiagnostic} from './helper.mjs';

const here=path.dirname(new URL(import.meta.url).pathname).replace(/^\/(.:)/,'$1');
const helper=path.join(here,'helper.mjs');
const driver=path.join(here,'driver.sh');
const transport=path.resolve(here,'..','run_transport.sh');
const bash=process.env.WIDGET_QA_BASH||(process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'/bin/bash');
function shellFunction(name){
 const source=fs.readFileSync(transport,'utf8'),lines=source.split(/\r?\n/),start=lines.indexOf(name+'() {');
 assert.ok(start>=0);let depth=1;
 for(let i=start+1;i<lines.length;i++){depth+=(lines[i].match(/{/g)||[]).length-(lines[i].match(/}/g)||[]).length;if(!depth)return lines.slice(start,i+1).join('\n');}
 throw Error('unclosed shell function');
}
function ownedLog(name,text){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),`widget-diag-${name}-`));
 const file=path.join(dir,'driver.log');fs.writeFileSync(file,text);const st=fs.statSync(file);
 fs.writeFileSync(file+'.owner',JSON.stringify({dev:String(st.dev),ino:String(st.ino)}));
 return {dir,file};
}

test('diagnostic formatter allowlists enums and bounded safe fields',()=>{
 const secret='SECRET_PATH_URI_TOKEN_exception-message_should-not-appear';
 const text=formatDiagnostic({source:'untrusted',reason:`${secret}`,firstFailure:`${secret}`,phase:'COLD',elapsedMs:999999,ackCount:-7,noAlertCount:1,URI:secret,path:secret,controlToken:secret,errorBody:secret});
 assert.ok(Buffer.byteLength(text,'utf8')<=768);
 assert.doesNotMatch(text,new RegExp(secret));
 const row=JSON.parse(text);
 assert.equal(row.kind,'WIDGET_QA_DIAG_V1');assert.equal(row.source,'helper');assert.equal(row.reason,'FORMAT_BOUNDED');assert.equal(row.firstFailure,'NONE');assert.equal(row.phase,'COLD');assert.equal(row.elapsedMs,60000);assert.equal(row.ackCount,0);assert.equal(row.noAlertCount,1);
 assert.deepEqual(Object.keys(row).sort(),['ackCount','elapsedMs','errorClass','firstFailure','kind','noAlertCount','phase','reason','source'].sort());
});

test('cold check keeps stdout protocol and reports exact marker counts only to stderr',()=>{
 const {dir,file}=ownedLog('cold','HOST_UI_READY\nHOST_UI_NO_ALERT\n');
 try{
  const r=spawnSync(process.execPath,[helper,'check',file,'cold'],{encoding:'utf8',windowsHide:true});
  assert.equal(r.status,1);assert.equal(r.stdout,'');
  const record=r.stderr.split(/\r?\n/).map(s=>{try{return JSON.parse(s);}catch{return null;}}).find(x=>x?.kind==='WIDGET_QA_DIAG_V1');
  assert.ok(record);assert.equal(record.reason,'COLD_ACK_PREDICATE');assert.equal(record.firstFailure,'COLD_ACK_PREDICATE');assert.equal(record.readyCount,1);assert.equal(record.ackCount,0);assert.equal(record.noAlertCount,1);
  assert.equal(record.path,undefined);assert.equal(record.URI,undefined);assert.equal(record.controlToken,undefined);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('driver diagnostic emitter uses fixed enums, bounded fields and stderr only',()=>{
 const quote=s=>"'"+s.replaceAll('\\','/')+"'";
 const script=['source '+quote(driver),'OPEN_DIAG_STARTED=$SECONDS','OPEN_DIAG_PHASE_STARTED=$SECONDS','OPEN_DIAG_PHASE=READY','OPEN_DIAG_READY_MS=1200','OPEN_DIAG_OWNER_PRESENT=1','OPEN_DIAG_PROXY_VALID=1','OPEN_DIAG_HELPER_LIVE=1','OPEN_DIAG_TERMINAL_PRESENT=0','OPEN_DIAG_FD_REGULAR=1','OPEN_DIAG_FD_IDENTITY=1','open_driver_diag_fail START_READY_TIMEOUT'].join('\n');
 const r=spawnSync(bash,['--noprofile','--norc','-c',script],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stdout+r.stderr);assert.equal(r.stdout,'');
 const row=JSON.parse(r.stderr.trim());assert.equal(row.kind,'WIDGET_QA_DIAG_V1');assert.equal(row.source,'driver');assert.equal(row.reason,'START_READY_TIMEOUT');assert.equal(row.firstFailure,'START_READY_TIMEOUT');assert.equal(row.phase,'READY');assert.equal(row.readyElapsedMs,1200);assert.equal(row.ownerPresent,true);assert.equal(row.proxyValid,true);assert.equal(row.helperLive,true);assert.equal(row.fdRegular,true);assert.equal(row.fdIdentityValid,true);assert.ok(Buffer.byteLength(r.stderr,'utf8')<768);assert.doesNotMatch(r.stderr,/token|https?:|file:|driver\\.sh/);
});

test('open_qa_url tolerates missing and failing diagnostic logger without changing launch status or observation',()=>{
 const uri='planflow://diagnostic-test?PRIVATE_URI_TOKEN';
 for(const status of [0,37])for(const logger of ['missing','failing']){
  const lines=['set -euo pipefail','UDID=OWNED; RUN_OUT=/unused; DIAGNOSTICS=stub; ACTIVE_CASE=""',`node() { return ${status}; }`,'observe_first_process() { printf "OBSERVED:%s/%s-first-process.txt\\n" "$RUN_OUT" "$ACTIVE_CASE"; return 0; }'];
  if(logger==='failing')lines.push('open_driver_diag_transport() { printf "%s\\n" "$*" >&2; return 19; }');
  lines.push(shellFunction('open_qa_url'),`open_qa_url applinks-cold '${uri}'`,'printf FINISHED');
  const r=spawnSync(bash,['--noprofile','--norc','-c',lines.join('\n')],{encoding:'utf8',timeout:5000,windowsHide:true});
  assert.equal(r.status,status,`status=${status} logger=${logger}: ${r.stdout}${r.stderr}`);assert.match(r.stdout,/OBSERVED:.*applinks-cold-first-process\.txt/);
  if(status===0)assert.match(r.stdout,/FINISHED/);else assert.doesNotMatch(r.stdout,/FINISHED/);
  assert.doesNotMatch(r.stdout+r.stderr,/PRIVATE_URI_TOKEN|planflow:\/\//);
  if(logger==='failing')assert.match(r.stderr,/OS_REQUEST_(ACCEPTED|FAILED)/);else assert.equal(r.stderr,'');
 }
});

test('successful check stdout remains exactly OK',()=>{
 const {dir,file}=ownedLog('success','HOST_UI_READY\nHOST_UI_ACK\n');
 try{
  const r=spawnSync(process.execPath,[helper,'check',file,'cold'],{encoding:'utf8',windowsHide:true});
  assert.equal(r.status,0);assert.equal(r.stdout,'OK\n');assert.equal(r.stderr,'');
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('driver diagnostic emitter survives closed stderr under errexit without aborting caller',()=>{
 const quote=s=>"'"+s.replaceAll('\\','/')+"'";
 const script=['set -euo pipefail','source '+quote(driver),'OPEN_DIAG_STARTED=$SECONDS','OPEN_DIAG_PHASE_STARTED=$SECONDS','OPEN_DIAG_PHASE=READY','OPEN_DIAG_READY_MS=1200','OPEN_DIAG_OWNER_PRESENT=1','OPEN_DIAG_PROXY_VALID=1','OPEN_DIAG_HELPER_LIVE=1','OPEN_DIAG_TERMINAL_PRESENT=0','OPEN_DIAG_FD_REGULAR=1','OPEN_DIAG_FD_IDENTITY=1','exec 2>&-','open_driver_diag_emit driver READY_ACCEPTED','printf AFTER\\n'].join('\n');
 const r=spawnSync(bash,['--noprofile','--norc','-c',script],{encoding:'utf8',windowsHide:true});
 assert.equal(r.status,0,r.stdout+r.stderr);
 assert.match(r.stdout,/AFTER/);
});