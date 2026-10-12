import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {prepare,markers,unchanged,checkLog,checkLog as _checkLog,writeOwnership,readOwnership,clearOwnership,cleanupGroup,helperAlive,terminalExit,run,cli,defaultHooks,ownedController,deadlineSchedule,DEADLINES} from './helper.mjs';
import {boundary} from '../verify_transport_receipts.mjs';
const here=path.dirname(new URL(import.meta.url).pathname).replace(/^\/(.:)/,'$1');
const temp=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'open-fixture-')));
const host=path.join(temp,'OpenConfirmation-Runner.app');fs.mkdirSync(host);const bundle=path.join(host,'OpenConfirmation.xctest');fs.mkdirSync(bundle);
const target=()=>({BlueprintName:'OpenConfirmation',IsUITestBundle:true,TestHostPath:host,TestBundlePath:bundle,TestHostBundleIdentifier:'com.fluxstudio.qa.openconfirmation.xctrunner'});
for(const version of [1,2])test('metadata accepted v'+version,()=>{
 const j=version===1?{OpenConfirmation:target()}:{__xctestrun_metadata__:{FormatVersion:2},TestConfigurations:[{TestTargets:[target()]}]};
 assert.ok(prepare(j,temp));
});
for(const field of ['UITargetAppPath','UITargetAppBundleIdentifier','TargetApplication','TEST_HOST','TargetTestID'])test('reject AUT '+field,()=>{const t=target();t[field]='Runner';assert.throws(()=>prepare({OpenConfirmation:t},temp));});
test('reject dependency and extra target',()=>{const t=target();t.DependentProductPaths=['Runner.app'];assert.throws(()=>prepare({OpenConfirmation:t},temp));assert.throws(()=>prepare({OpenConfirmation:target(),Other:target()},temp));});
for(const text of ['', 'HOST_UI_READY\nHOST_UI_READY\n','HOST_UI_READY\nHOST_UI_FAIL_TITLE\n','HOST_UI_READY\nHOST_UI_NO_ALERT\n'])test('cold rejects '+JSON.stringify(text),()=>assert.throws(()=>markers(text,'cold')));
test('ACK is diagnostic only and warm absent allowed',()=>{markers('HOST_UI_READY\nHOST_UI_ACK\n','cold');markers('HOST_UI_READY\nHOST_UI_NO_ALERT\n','warm');});
test('BOOT prior detected',()=>{const f=path.join(temp,'receipts');const b=path.join(temp,'boundary');fs.writeFileSync(b,JSON.stringify(boundary([])));unchanged(f,b);fs.writeFileSync(f,JSON.stringify({kind:'BOOT',bootId:'a'.repeat(32),pid:1})+'\n');assert.throws(()=>unchanged(f,b));});
test('Swift exact one alert/button and no launch or default AUT',()=>{const s=fs.readFileSync(path.join(here,'OpenConfirmation.swift'),'utf8');assert.match(s,/alerts.count == 1/);assert.match(s,/Open in .PlanFlow./);assert.match(s,/buttons.count == 1/);assert.match(s,/isHittable/);assert.equal((s.match(/\.tap\(/g)||[]).length,1);assert.doesNotMatch(s,/\.launch\(|\.activate\(|XCUIApplication\(\)|addUIInterruptionMonitor|coordinate/);});
test('host boundaries preserve source checker and no synthesis',()=>{const s=fs.readFileSync(path.join(here,'../run_transport.sh'),'utf8');assert.ok(s.indexOf('open_driver_start || exit 1')<s.indexOf('  open_qa_url "${plugin}-cold"'));assert.match(s,/prove_absent \|\| exit 1/);assert.match(s,/unchanged "\$RECEIPTS" "\$BOUNDARY"/);assert.match(s,/open_driver_guard_pre_url/);assert.doesNotMatch(fs.readFileSync(path.join(here,'helper.mjs'),'utf8'),/simctl|writeFileSync\(file/);});
test('CI guard blocks runtime locally without tools',()=>{const r=spawnSync(process.execPath,[path.join(here,'helper.mjs'),'run','11111111-2222-3333-4444-555555555555','unused',temp],{env:{...process.env,GITHUB_ACTIONS:'false'},encoding:'utf8'});assert.equal(r.status,1);assert.match(r.stderr,/HOST_UI_BLOCKED/);});

test('pinned log rejects replacement, symlink, truncation and oversize',()=>{
 const f=path.join(temp,'pinned.log');fs.writeFileSync(f,'HOST_UI_READY\nHOST_UI_ACK\n');const st=fs.statSync(f);fs.writeFileSync(f+'.owner',JSON.stringify({dev:String(st.dev),ino:String(st.ino)}));const fd=fs.openSync(f,fs.constants.O_RDONLY);const replacement=path.join(temp,'replacement');fs.writeFileSync(replacement,'HOST_UI_READY\nHOST_UI_ACK\n');fs.unlinkSync(f);fs.renameSync(replacement,f);assert.throws(()=>checkLog(f,'cold',fd),/HOST_UI_BLOCKED/);fs.closeSync(fd);assert.throws(()=>checkLog(f,'cold'),/HOST_UI_BLOCKED/);
 fs.rmSync(f);try{fs.symlinkSync(host,f);}catch(e){if(e.code!=='EPERM')throw e;}assert.throws(()=>checkLog(f,'cold'),/HOST_UI_BLOCKED/);
 fs.unlinkSync(f);fs.writeFileSync(f,'HOST_UI_READY\nHOST_UI_ACK\n');const st2=fs.statSync(f);fs.writeFileSync(f+'.owner',JSON.stringify({dev:String(st2.dev),ino:String(st2.ino)}));const short=fs.openSync(f,fs.constants.O_RDONLY);fs.truncateSync(f,1);assert.throws(()=>checkLog(f,'cold',short),/HOST_UI_BLOCKED/);fs.closeSync(short);
 fs.unlinkSync(f);fs.writeFileSync(f,'HOST_UI_READY\nHOST_UI_ACK\n');const st3=fs.statSync(f);fs.writeFileSync(f+'.owner',JSON.stringify({dev:String(st3.dev),ino:String(st3.ino)}));fs.writeFileSync(f,Buffer.alloc(4*1024*1024+1,65));assert.throws(()=>checkLog(f,'cold'),/HOST_UI_BLOCKED/);
});
test('ready guard rejects terminal helper and missing helper',()=>{
 const h=fs.readFileSync(path.join(here,'driver.sh'),'utf8');assert.match(h,/open_driver_guard/);assert.match(h,/open_driver_guard_pre_url/);assert.match(h,/alive/);assert.match(fs.readFileSync(path.join(here,'helper.mjs'),'utf8'),/terminalExit/);
});
// === New tests for required behavior ===

// Fixture: regular file with owner record and log content.
function makeOwnedLog(name,content){
 const dir=path.join(temp,name);fs.mkdirSync(dir);
 const log=path.join(dir,'driver.log');fs.writeFileSync(log,content);
 const st=fs.statSync(log);
 fs.writeFileSync(log+'.owner',JSON.stringify({dev:String(st.dev),ino:String(st.ino)}));
 return {dir,log,dev:String(st.dev),ino:String(st.ino)};
}

test('pinned log separate CLI rejects dev/ino mismatch on opened FD',()=>{
 const {dir,log,dev,ino}=makeOwnedLog('cli-mismatch','HOST_UI_READY\nHOST_UI_ACK\n');
 // Simulate a separate CLI: replace the file with a different inode, then open its own FD.
 const replacement=path.join(dir,'replacement.log');fs.writeFileSync(replacement,'HOST_UI_READY\nHOST_UI_ACK\n');
 fs.unlinkSync(log);fs.renameSync(replacement,log);
 // The recorded dev/ino is stale. The freshly opened FD's fstat will not match the recorded identity.
 assert.throws(()=>checkLog(log,'cold'),/HOST_UI_BLOCKED/);
});
test('pinned log read error yields static FAIL not pass or crash',()=>{
 // The owner record path is part of the bounded check. A missing owner record must surface
 // as a static FAIL (HOST_UI_BLOCKED) rather than a crash or accidental pass.
 const f=path.join(temp,'cli-no-owner.log');fs.writeFileSync(f,'HOST_UI_READY\nHOST_UI_ACK\n');
 assert.throws(()=>checkLog(f,'cold'),/HOST_UI_BLOCKED/);
 // Same for a closed FD: opening the check path on a non-existent file must reject.
 const missing=path.join(temp,'cli-missing.log');
 assert.throws(()=>checkLog(missing,'cold'),/HOST_UI_BLOCKED/);
});
test('pinned log accepts freshly opened FD when identity matches',()=>{
 const {log}=makeOwnedLog('cli-match','HOST_UI_READY\nHOST_UI_ACK\n');
 // Open a fresh FD (no shared FD with supervisor). fstat should match recorded identity.
 const fd=fs.openSync(log,fs.constants.O_RDONLY);
 try{assert.doesNotThrow(()=>checkLog(log,'cold',fd));}finally{fs.closeSync(fd);}
});
test('ownership record tracks group PID and log identity at creation',()=>{
 const d=path.join(temp,'own-write');fs.mkdirSync(d);
 const p=writeOwnership(d,{pid:4242,startedAt:1,logDev:'X',logIno:'Y'});
 const o=readOwnership(d);assert.equal(o.pid,4242);assert.equal(o.logDev,'X');assert.equal(o.logIno,'Y');
 assert.equal(p,path.join(d,'ownership.json'));
 assert.ok(fs.existsSync(p));
 clearOwnership(d);
 assert.equal(fs.existsSync(p),false);
});
test('cleanupGroup rejects when ownership record is missing',()=>{
 const d=path.join(temp,'own-missing');fs.mkdirSync(d);
 assert.throws(()=>cleanupGroup({dir:d,group:1,hooks:{alive:()=>true,signal:()=>{}},now:()=>0,sleep:()=>{}}));
});
test('cleanupGroup leader-gone descendants-alive still-owned preserves ownership',()=>{
 const d=path.join(temp,'own-leader-gone');fs.mkdirSync(d);
 writeOwnership(d,{pid:111,startedAt:1,logDev:'a',logIno:'b'});
 const signals=[];
 const t0=1000;let t=t0;
 const hooks={alive:()=>true,signal:(g,s)=>signals.push({g,s})};
 const result=cleanupGroup({dir:d,group:111,hooks,termMs:50,reapMs:100,now:()=>t,sleep:ms=>{t+=ms;}});
 assert.equal(result.released,false);
 assert.equal(result.phase,'KILL');
 assert.deepEqual(signals.map(s=>s.s),['SIGTERM','SIGKILL']);
 assert.ok(fs.existsSync(path.join(d,'ownership.json')));
});
test('cleanupGroup deadline still-owned preserves ownership and does not clear PID',()=>{
 const d=path.join(temp,'own-deadline');fs.mkdirSync(d);
 writeOwnership(d,{pid:222,startedAt:1,logDev:'c',logIno:'d'});
 const t0=5000;let t=t0;
 const result=cleanupGroup({dir:d,group:222,hooks:{alive:()=>true,signal:()=>{}},termMs:20,reapMs:50,now:()=>t,sleep:ms=>{t+=ms;}});
 assert.equal(result.released,false);
 const o=readOwnership(d);assert.equal(o.pid,222);
});
test('cleanupGroup successful reap clears ownership and returns REAPED',()=>{
 const d=path.join(temp,'own-reaped');fs.mkdirSync(d);
 writeOwnership(d,{pid:333,startedAt:1,logDev:'e',logIno:'f'});
 let calls=0;const t0=10000;let t=t0;
 const result=cleanupGroup({dir:d,group:333,hooks:{alive:()=>{calls++;return calls<3;},signal:()=>{}},termMs:30,reapMs:200,now:()=>t,sleep:ms=>{t+=ms;}});
 assert.equal(result.released,true);
 assert.equal(result.phase,'REAPED');
 assert.equal(fs.existsSync(path.join(d,'ownership.json')),false);
});
test('cleanupGroup tombstones record when recordTombstone is provided',()=>{
 const d=path.join(temp,'own-tomb');fs.mkdirSync(d);
 writeOwnership(d,{pid:444,startedAt:1,logDev:'g',logIno:'h'});
 const tomb=[];const t0=1000;let t=t0;
 cleanupGroup({dir:d,group:444,hooks:{alive:()=>true,signal:()=>{}},termMs:20,reapMs:50,now:()=>t,sleep:ms=>{t+=ms;},recordTombstone:e=>tomb.push(e)});
 assert.equal(tomb.length,1);assert.equal(tomb[0].phase,'STILLOWNED');
});


// Actual helper entry points, no shell reimplementation of alive/check semantics.
test('actual alive CLI uses directory and blocks terminal result with a live proxy',()=>{
 const d=fs.mkdtempSync(path.join(temp,'alive-'));
 const call=()=>spawnSync(process.execPath,[path.join(here,'helper.mjs'),'alive',String(process.pid),d],{encoding:'utf8',windowsHide:true});
 assert.equal(call().status,0);fs.writeFileSync(path.join(d,'exit'),'0');assert.equal(call().status,1);
});
test('actual default signal adapter sends negative group and two arguments',()=>{
 const calls=[];const h=defaultHooks((...args)=>calls.push(args));
 h.alive(4567);h.signal(4567,'SIGTERM');h.signal(4567,'SIGKILL');
 assert.deepEqual(calls,[[-4567,0],[-4567,'SIGTERM'],[-4567,'SIGKILL']]);
});
for(const mode of ['normal','replace','truncate','oversize','readerror','timeout','leader-descendants','deadline'])test('actual supervisor owned stub '+mode,async()=>{
 const d=fs.mkdtempSync(path.join(temp,'supervisor-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'OpenConfirmation.xctestrun');fs.writeFileSync(meta,'{}');
 const oldCI=process.env.GITHUB_ACTIONS,oldProducts=process.env.QA_OPEN_PRODUCTS;process.env.GITHUB_ACTIONS='true';process.env.QA_OPEN_PRODUCTS=products;
 let child,descendants=mode==='leader-descendants'||mode==='deadline',dead=false;const signals=[];let timer;
 try{
  const result=await run('11111111-2222-3333-4444-555555555555',meta,d,{
   pollMs:5,deadlineMs:mode==='timeout'?10:1500,termMs:10,reapMs:20,
   launch:(command,args,opts)=>{
    assert.equal(command,'xcodebuild');assert.equal(args[2],meta);assert.equal(opts.detached,true);
    child=spawn(process.execPath,['-e',mode==='timeout'?'setTimeout(()=>{},100)':"console.log('HOST_UI_READY');setTimeout(()=>{console.log('HOST_UI_ACK')},70);setTimeout(()=>{},100)"],{stdio:opts.stdio,windowsHide:true});
    child.on('exit',()=>{dead=true;});
    if(['replace','truncate','oversize','readerror'].includes(mode)){
     const mutate=()=>{
      const log=path.join(d,'driver.log');if(!fs.existsSync(log)||fs.statSync(log).size===0){timer=setTimeout(mutate,5);return;}
      timer=setTimeout(()=>{if(mode==='replace'){fs.renameSync(log,log+'.old');fs.writeFileSync(log,'HOST_UI_READY\nHOST_UI_ACK\n');}if(mode==='truncate')fs.truncateSync(log,0);if(mode==='oversize')fs.truncateSync(log,4*1024*1024);if(mode==='readerror')fs.unlinkSync(log+'.owner');},20);
     };timer=setTimeout(mutate,5);
    }
    return child;
   },
   hooks:{alive:g=>{assert.equal(g,child.pid);return !dead||descendants;},signal:(g,s)=>{assert.equal(g,child.pid);signals.push([g,s]);if(mode!=='deadline'){dead=true;if(s==='SIGKILL')descendants=false;}}}
  });
  assert.equal(result,mode==='normal'||mode==='leader-descendants'?0:1);
  assert.equal(fs.readFileSync(path.join(d,'exit'),'utf8'),String(result));
  assert.equal(fs.existsSync(path.join(d,'ownership.json')),mode==='deadline');
  if(mode==='leader-descendants'||mode==='deadline')assert.deepEqual(signals.map(x=>x[1]),['SIGTERM','SIGKILL']);
  if(mode==='normal')assert.doesNotThrow(()=>checkLog(path.join(d,'driver.log'),'cold'));
 }finally{clearTimeout(timer);if(child&&child.exitCode===null)await new Promise(r=>child.once('exit',r));if(oldCI===undefined)delete process.env.GITHUB_ACTIONS;else process.env.GITHUB_ACTIONS=oldCI;if(oldProducts===undefined)delete process.env.QA_OPEN_PRODUCTS;else process.env.QA_OPEN_PRODUCTS=oldProducts;}
});
test('stale reused numeric record cannot authorize external signals even with supplied backend',async()=>{
 const d=fs.mkdtempSync(path.join(temp,'stale-'));writeOwnership(d,{pid:6543,controlToken:'a'.repeat(48),diagnosticOnly:true});
 const calls=[];
 assert.equal(await cli(['cleanup',d,'6543'],{timeoutMs:30,pollMs:5,hooks:{alive:()=>true,signal:(...a)=>calls.push(a)}}),1);
 assert.deepEqual(calls,[]);assert.ok(fs.existsSync(path.join(d,'ownership.json')));
 fs.writeFileSync(path.join(d,'exit'),'1');fs.unlinkSync(path.join(d,'ownership.json'));fs.writeFileSync(path.join(d,'emergency.json'),'{"diagnosticOnly":true}');
 assert.equal(await cli(['cleanup',d],{timeoutMs:10,pollMs:2}),1);
 assert.throws(()=>defaultHooks());
 assert.throws(()=>cleanupGroup({dir:d,group:6543}));
});
for(const fault of ['publication','missing-pid','sync-spawn','early-exit','early-error','cleanup-throw'])test('acquisition/finish fault '+fault+' uses actual supervisor and retains failure',async()=>{
 const d=fs.mkdtempSync(path.join(temp,'acquisition-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'meta');fs.writeFileSync(meta,'{}');
 const ci=process.env.GITHUB_ACTIONS,prod=process.env.QA_OPEN_PRODUCTS;process.env.GITHUB_ACTIONS='true';process.env.QA_OPEN_PRODUCTS=products;
 let child,ownedFd,dead=false;const signals=[];let closed=false;
 const opts={pollMs:5,deadlineMs:1000,termMs:1,reapMs:30,
  launch:(cmd,args,config)=>{
   ownedFd=config.stdio[1];
   if(fault==='sync-spawn')throw Error('STUB_SPAWN_ERROR');
   child=spawn(process.execPath,['-e',"console.log('HOST_UI_READY');console.log('HOST_UI_ACK');setTimeout(()=>{},150)"],{stdio:config.stdio,windowsHide:true});
   child.on('exit',()=>{dead=true;});child.on('close',()=>{closed=true;});
   if(fault==='missing-pid')Object.defineProperty(child,'pid',{value:undefined});
   if(fault==='early-exit')queueMicrotask(()=>{child.emit('exit',5);});
   if(fault==='early-error')queueMicrotask(()=>{child.emit('error',Error('STUB_ERROR'));});
   return child;
  },hooks:{alive:()=>!dead,signal:(g,s)=>{signals.push([g,s]);dead=true;}},
 };
 if(fault==='publication')opts.publishOwnership=()=>{throw Error('STUB_PUBLICATION');};
 if(fault==='cleanup-throw')opts.cleanup=()=>{throw Error('STUB_CLEANUP');};
 try{
  assert.equal(await run('11111111-2222-3333-4444-555555555555',meta,d,opts),1);
  assert.equal(fs.readFileSync(path.join(d,'exit'),'utf8'),'1');
  assert.throws(()=>fs.fstatSync(ownedFd),e=>e.code==='EBADF');
  assert.equal(fs.existsSync(path.join(d,'ownership.json')),false);
  if(fault==='publication')assert.ok(signals.length>0);
 }finally{
  if(child&&!closed)await new Promise(r=>child.once('close',r));
  if(ci===undefined)delete process.env.GITHUB_ACTIONS;else process.env.GITHUB_ACTIONS=ci;if(prod===undefined)delete process.env.QA_OPEN_PRODUCTS;else process.env.QA_OPEN_PRODUCTS=prod;
 }
});
test('publication failure plus cleanup failure leaves passive actionable emergency and terminal failure',async()=>{
 const d=fs.mkdtempSync(path.join(temp,'emergency-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'meta');fs.writeFileSync(meta,'{}');
 const ci=process.env.GITHUB_ACTIONS,prod=process.env.QA_OPEN_PRODUCTS;process.env.GITHUB_ACTIONS='true';process.env.QA_OPEN_PRODUCTS=products;
 let child;
 try{
  const result=await run('11111111-2222-3333-4444-555555555555',meta,d,{launch:(cmd,args,cfg)=>{child=spawn(process.execPath,['-e','setTimeout(()=>{},50)'],{stdio:cfg.stdio,windowsHide:true});return child;},publishOwnership:()=>{throw Error('stub');},contain:async()=>false});
  assert.equal(result,1);assert.equal(JSON.parse(fs.readFileSync(path.join(d,'emergency.json'),'utf8')).diagnosticOnly,true);
  assert.equal(fs.readFileSync(path.join(d,'exit'),'utf8'),'1');
 }finally{if(child&&child.exitCode===null)await new Promise(r=>child.once('close',r));if(ci===undefined)delete process.env.GITHUB_ACTIONS;else process.env.GITHUB_ACTIONS=ci;if(prod===undefined)delete process.env.QA_OPEN_PRODUCTS;else process.env.QA_OPEN_PRODUCTS=prod;}
});
test('actual sourced driver complete start/finish and start/cleanup through actual run CLI fixture',()=>{
 const bash=process.env.WIDGET_QA_BASH||(process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'/bin/bash');
 const d=fs.mkdtempSync(path.join(temp,'driver-cli-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'meta');fs.writeFileSync(meta,'{}');
 const adapter=path.join(d,'adapter.mjs');
 const code="import {cli} from "+JSON.stringify(new URL('./helper.mjs',import.meta.url).href)+";import {spawn} from 'node:child_process';let child,dead=false;process.exitCode=await cli(process.argv.slice(3),{publishOwnership:process.env.FAIL_PUBLISH==='true'?()=>{throw Error('STUB_PUBLICATION');}:undefined,timeoutMs:1500,pollMs:5,termMs:1,reapMs:10,launch:(cmd,args,cfg)=>{child=spawn(process.execPath,['-e',\"console.log('HOST_UI_READY');setTimeout(()=>{console.log('HOST_UI_ACK')},1000);setTimeout(()=>{},2000)\"],{stdio:cfg.stdio,windowsHide:true});child.on('exit',()=>dead=true);return child;},hooks:{alive:()=>!dead,signal:(g,s)=>{if(g!==child.pid)throw Error('not owned');dead=true;child.kill(s);}}});";
 fs.writeFileSync(adapter,code);
 const q=s=>"'"+s.replaceAll('\\','/')+"'";
 const script=['set -eu','source '+q(path.join(here,'driver.sh')),
 'node() { command node '+q(adapter)+' "$@"; }','export GITHUB_ACTIONS=true','export QA_OPEN_PRODUCTS='+q(products),
 'export QA_OPEN_XCTESTRUN='+q(meta),'RUN_OUT='+q(d),'UDID=11111111-2222-3333-4444-555555555555','ACTIVE_CASE=finish',
 'open_driver_start || exit 10','open_driver_guard_pre_url || exit 11','open_driver_finish cold || exit 12','[[ -z "$OPEN_PID" ]] || exit 13',
 'ACTIVE_CASE=cleanup','open_driver_start || exit 14','open_driver_guard_pre_url || exit 15','open_driver_cleanup || exit 16','[[ -z "$OPEN_PID" && ! -e "$OPEN_DIR/ownership.json" ]] || exit 17',
 '[[ $(cat "$OPEN_DIR/exit") != 0 ]] || exit 18','export FAIL_PUBLISH=true','ACTIVE_CASE=publication','if open_driver_start; then exit 19; fi','open_driver_cleanup || exit 20','[[ -z "$OPEN_PID" && ! -e "$OPEN_DIR/ownership.json" && $(cat "$OPEN_DIR/exit") != 0 ]] || exit 21'].join('\n');
 const result=spawnSync(bash,['--noprofile','--norc','-c',script],{encoding:'utf8',windowsHide:true,timeout:10000});assert.equal(result.status,0,result.stdout+result.stderr);
});
for(const cause of ['disconnect','lease','stop','leader-exit-descendants'])test('actual owned controller containment '+cause+' uses self-only injected signals',async()=>{
 const channel=new EventEmitter();const messages=[];channel.send=m=>messages.push(m);const token='a'.repeat(48);let child,dead=false;const signals=[];
 const ci=process.env.GITHUB_ACTIONS;process.env.GITHUB_ACTIONS='true';
 try{
  const done=ownedController(['stub'],token,{channel,leaseMs:40,termMs:5,
   launch:(cmd,args,opts)=>{assert.equal(opts.detached,false);child=new EventEmitter();child.pid=5432;return child;},
   signal:s=>{signals.push(s);if(s==='SIGKILL')dead=true;}});
  channel.emit('message',{command:'start',token:'b'.repeat(48)});assert.equal(child,undefined);
  channel.emit('message',{command:'start',token});assert.ok(child);
  if(cause==='disconnect')channel.emit('disconnect');
  if(cause==='stop')channel.emit('message',{command:'stop',token});
  if(cause==='leader-exit-descendants'){child.emit('exit',0);assert.equal(dead,false);}
  assert.equal(await done,1);assert.deepEqual(signals,['SIGTERM','SIGKILL']);assert.equal(dead,true);
  assert.equal(channel.listenerCount('disconnect'),0);assert.equal(channel.listenerCount('message'),0);
 }finally{if(ci===undefined)delete process.env.GITHUB_ACTIONS;else process.env.GITHUB_ACTIONS=ci;}
});
test('shared monotonic deadline permits delayed READY plus warm observation and bounded terminal within total cap',()=>{
 let t=0;const s=deadlineSchedule(()=>t);assert.equal(DEADLINES.startupMs,20000);assert.equal(DEADLINES.warmObservationMs,20000);assert.equal(DEADLINES.totalMs,60000);
 t=19000;assert.equal(s.advance(false),false);assert.equal(s.advance(true),true);const initial=s.deadline;
 t=39000;assert.equal(s.expired(),false);assert.equal(s.advance(true),false);assert.equal(s.deadline,initial);
 t=59000;assert.equal(s.expired(),false);t=60001;assert.equal(s.expired(),true);
});
test('shared deadline rejects missing or late READY and cannot renew warm cap',()=>{
 let t=0;const s=deadlineSchedule(()=>t);t=20001;assert.equal(s.advance(true),false);assert.equal(s.readyAt,null);assert.equal(s.expired(),true);
 let x=0;const w=deadlineSchedule(()=>x);assert.equal(w.advance(true),true);x=20001;assert.equal(w.expired(),false);x=40001;assert.equal(w.expired(),true);assert.equal(w.advance(true),false);
});
test('persisted cleanup never signals and production lease is self-group-only',()=>{
 const source=fs.readFileSync(path.join(here,'helper.mjs'),'utf8');
 const request=source.slice(source.indexOf('export async function requestCleanup'),source.indexOf('export async function run'));
 assert.equal(request.includes('process.kill'),false);assert.equal(request.includes('.signal('),false);
 assert.ok(source.includes('sig=>process.kill(-process.pid,sig)'));
 assert.ok(source.includes("channel.on('disconnect',stop)"));assert.ok(source.includes('options.leaseMs??DEADLINES.startupMs'));
 assert.ok(source.indexOf('(options.publishOwnership??writeOwnership)')<source.indexOf("child.send({command:'start',token})"));
});

// === Regression: controller strict validator must match producer's actual 14-vector ===
// Build the exact production vector that helper.mjs line ~221 emits so the real
// validator (no options.launch shortcut) is exercised, not a copy of the parser.
function producerArgs(meta,udid,dir,override){
 const base=['test-without-building','-xctestrun',meta,'-destination','platform=iOS Simulator,id='+udid,'-only-testing:OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-resultBundlePath',path.join(dir,'driver.xcresult')];
 return override?override(base,meta,udid,dir):base;
}
function controllerEnv(products){
 const oldCI=process.env.GITHUB_ACTIONS,oldProd=process.env.QA_OPEN_PRODUCTS;
 process.env.GITHUB_ACTIONS='true';process.env.QA_OPEN_PRODUCTS=products;
 return ()=>{if(oldCI===undefined)delete process.env.GITHUB_ACTIONS;else process.env.GITHUB_ACTIONS=oldCI;if(oldProd===undefined)delete process.env.QA_OPEN_PRODUCTS;else process.env.QA_OPEN_PRODUCTS=oldProd;};
}
function quietChannel(){const c=new EventEmitter();c.send=()=>{};return c;}

test('controller validator accepts actual producer 14-vector with owned result path',async()=>{
 const d=fs.mkdtempSync(path.join(temp,'val-ok-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'OpenConfirmation.xctestrun');fs.writeFileSync(meta,'{}');
 const restore=controllerEnv(products);const token='a'.repeat(48);const sig=[];
 try{
  const args=producerArgs(meta,'11111111-2222-3333-4444-555555555555',d);
  assert.equal(args.length,14);
  assert.equal(args[5],'-only-testing:OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen');
  assert.equal(path.basename(args[13]),'driver.xcresult');
  const done=ownedController(args,token,{channel:quietChannel(),leaseMs:40,termMs:5,signal:s=>sig.push(s),deadlineScale:0.001,now:()=>0});
  assert.equal(await done,1);
  assert.deepEqual(sig,['SIGTERM','SIGKILL']);
  assert.equal(args[0],'test-without-building');assert.equal(args[1],'-xctestrun');assert.equal(args[3],'-destination');
 }finally{restore();}
});
for(const variant of ['stale-15-split','wrong-target','escaped-result','wrong-destination','wrong-flag'])test('controller validator rejects '+variant,async()=>{
 const d=fs.mkdtempSync(path.join(temp,'val-'+variant+'-'));const products=path.join(d,'products');fs.mkdirSync(products);const meta=path.join(products,'OpenConfirmation.xctestrun');fs.writeFileSync(meta,'{}');
 const restore=controllerEnv(products);const token='a'.repeat(48);
 const udid='11111111-2222-3333-4444-555555555555';
 try{
  let override;
  if(variant==='stale-15-split'){
   // Old pre-fix form: -only-testing and target as separate args, result at index 14.
   override=()=>['test-without-building','-xctestrun',meta,'-destination','platform=iOS Simulator,id='+udid,'-only-testing','OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-resultBundlePath',path.join(d,'driver.xcresult')];
  }else if(variant==='wrong-target'){
   override=base=>{base[5]='-only-testing:WrongTarget/WrongTarget/testWrongOpen';return base;};
  }else if(variant==='escaped-result'){
   override=base=>{base[13]=path.join(d,'escaped.xcresult');return base;};
  }else if(variant==='wrong-destination'){
   override=base=>{base[4]='platform=iOS Simulator,name=iPhone 17';return base;};
  }else if(variant==='wrong-flag'){
   override=base=>{base[6]='-parallel-testing-enabled';base[7]='YES';return base;};
  }
  const args=producerArgs(meta,udid,d,override);
  await assert.rejects(()=>ownedController(args,token,{channel:quietChannel(),signal:()=>{}}),/HOST_UI_BLOCKED/);
 }finally{restore();}
});
process.on('exit',()=>{try{fs.rmSync(temp,{recursive:true,force:true});}catch{}});
