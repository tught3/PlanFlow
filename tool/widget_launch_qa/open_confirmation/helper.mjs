import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {read,boundary} from '../verify_transport_receipts.mjs';
const need=x=>{if(!x)throw Error('HOST_UI_BLOCKED');};
const staticFail=()=>{throw Error('HOST_UI_BLOCKED');};
export function prepare(j,products){
 need(j&&typeof j==='object');const version=j.__xctestrun_metadata__?.FormatVersion??1;need(version===1||version===2);let targets;
 if(version===2){need(j.TestConfigurations?.length===1);targets=j.TestConfigurations[0].TestTargets;}else targets=Object.entries(j).filter(([k])=>k!=='__xctestrun_metadata__').map(([k,v])=>({...v,BlueprintName:v.BlueprintName??k}));
 need(Array.isArray(targets)&&targets.length===1);const t=targets[0];need(t.BlueprintName==='OpenConfirmation'&&t.IsUITestBundle===true);
 function scan(o){for(const [k,v] of Object.entries(o)){need(!/UITargetApp|TargetApplication|TestTargetName|TargetTestID|TEST_HOST|TEST_TARGET_NAME/i.test(k));if(/dependenc/i.test(k))need(Array.isArray(v)&&v.length===0);if(typeof v==='string')need(!/(^|[/\\])Runner(?:\.app|\.xctest|$)|com\.fluxstudio\.planflow/i.test(v));if(v&&typeof v==='object')scan(v);}}scan(j);
 for(const k of ['TestHostPath','TestBundlePath']){need(typeof t[k]==='string');const p=path.resolve(t[k].replaceAll('__TESTROOT__',products).replaceAll('__TESTHOST__',t.TestHostPath.replaceAll('__TESTROOT__',products)));need(p.startsWith(path.resolve(products)+path.sep)&&/OpenConfirmation/.test(p));need(process.platform==='win32'?fs.realpathSync(p).toLowerCase()===p.toLowerCase():fs.realpathSync(p)===p);}
 need(t.TestHostBundleIdentifier==='com.fluxstudio.qa.openconfirmation.xctrunner');t.EnvironmentVariables={...(t.EnvironmentVariables??{}),QA_OPEN_CONFIRMATION_GATE:'ci-owned-exact-open-v1'};if(version===1)j.OpenConfirmation=t;return j;
}
export function unchanged(file,bfile){const b=JSON.parse(fs.readFileSync(bfile,'utf8'));need(JSON.stringify(boundary(fs.existsSync(file)?read(file):[]))===JSON.stringify(b));}
export function markers(text,phase){need(!text.includes('HOST_UI_FAIL')&&!text.includes('HOST_UI_BLOCKED'));const count=m=>(text.match(new RegExp('^'+m+'\\r?$','gm'))??[]).length;need(count('HOST_UI_READY')===1);if(phase==='ready')return;need((count('HOST_UI_ACK')===1&&count('HOST_UI_NO_ALERT')===0)||(phase==='warm'&&count('HOST_UI_ACK')===0&&count('HOST_UI_NO_ALERT')===1));}
export function helperAlive(pid){try{process.kill(pid,0);return true;}catch{return false;}}
export function terminalExit(dir){try{const s=fs.lstatSync(path.join(dir,'exit'));return s.isFile()&&!s.isSymbolicLink();}catch{return false;}}
export function writeOwnership(dir,record){
 const p=path.join(dir,'ownership.json');fs.writeFileSync(p,JSON.stringify(record),{flag:'wx'});return p;
}
export function readOwnership(dir){
 const p=path.join(dir,'ownership.json');const s=fs.lstatSync(p);need(s.isFile()&&!s.isSymbolicLink()&&s.size>0&&s.size<4096);return JSON.parse(fs.readFileSync(p,'utf8'));
}
export function clearOwnership(dir){
 try{fs.unlinkSync(path.join(dir,'ownership.json'));return true;}catch{return false;}
}
export function readOwnedLog(file,ownedFd,minSize=0){
 let fd=ownedFd,opened=false;
 try{
  const owned=JSON.parse(fs.readFileSync(file+'.owner','utf8'));
  if(ownedFd===undefined){fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW??0));opened=true;}
  const before=fs.fstatSync(fd);
  const lst=fs.lstatSync(file);
  need(before.isFile()&&lst.isFile()&&!lst.isSymbolicLink()&&before.dev===lst.dev&&before.ino===lst.ino&&String(before.dev)===owned.dev&&String(before.ino)===owned.ino&&before.size>=minSize&&before.size<4*1024*1024);
  const b=Buffer.alloc(before.size);
  let n=0;
  while(n<b.length){
   let r=0;
   try{r=fs.readSync(fd,b,n,b.length-n,n);}catch{staticFail();}
   need(r>0);n+=r;
  }
  let after;
  try{after=fs.fstatSync(fd);}catch{staticFail();}
  need(after.size>=before.size&&after.size<4*1024*1024&&after.dev===before.dev&&after.ino===before.ino);
  const lst2=fs.lstatSync(file);
  need(!lst2.isSymbolicLink()&&lst2.dev===after.dev&&lst2.ino===after.ino);
  return b.toString('utf8');
 }catch{throw Error('HOST_UI_BLOCKED');}
 finally{if(opened&&fd!==undefined)try{fs.closeSync(fd);}catch{}}
}
export function checkLog(file,phase,ownedFd){markers(readOwnedLog(file,ownedFd,1),phase);return true;}
// No implicit numeric-PID signalling backend. Used only with explicitly injected test primitives.
export function defaultHooks(kill){
 need(typeof kill==='function');
 return {alive:pid=>{try{kill(-pid,0);return true;}catch(e){return e.code==='EPERM';}},signal:(pid,sig)=>{try{kill(-pid,sig);}catch(e){if(e.code!=='ESRCH')throw e;}}};
}
export function cleanupGroup({dir,group,hooks,termMs=1000,reapMs=20000,now=Date.now,sleep=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms),recordTombstone}){
 // This API accepts only an explicitly injected backend. Disk records confer no signal authority.
 need(hooks&&Number.isSafeInteger(group)&&group>1);
 const owned=readOwnership(dir);need(owned.pid===group);
 const h=hooks;
 const startedAt=now();
 let phase='TERM';
 try{
  if(h.alive(group)){try{h.signal(group,'SIGTERM');}catch{}}
  const termEnd=startedAt+termMs;
  while(now()<termEnd){if(!h.alive(group)){phase='REAPED';break;}sleep(50);}
  if(phase!=='REAPED'){
   phase='KILL';
   try{h.signal(group,'SIGKILL');}catch{}
  }
  const reapEnd=now()+reapMs;
  while(now()<reapEnd){
   if(!h.alive(group)){phase='REAPED';break;}
   sleep(50);
  }
  if(phase==='REAPED'){
   const cleared=clearOwnership(dir);
   if(recordTombstone)recordTombstone({phase,cleared,at:now()});
   return {released:cleared,phase,cleared};
  }
  if(recordTombstone)recordTombstone({phase:'STILLOWNED',at:now()});
  return {released:false,phase};
 }catch{return {released:false,phase:'ERROR'};}
}

export const DEADLINES=Object.freeze({startupMs:20000,warmObservationMs:20000,terminalMs:20000,totalMs:60000});
export function deadlineSchedule(now=()=>Number(process.hrtime.bigint())/1e6,scale=1,startupMs=DEADLINES.startupMs){
 const started=now(),startup=started+Math.min(startupMs,DEADLINES.startupMs)*scale,total=started+DEADLINES.totalMs*scale;
 let readyAt=null;
 return {started,advance(authenticated){if(!authenticated||readyAt!==null||now()>startup)return false;readyAt=now();return true;},get readyAt(){return readyAt;},get deadline(){return readyAt===null?startup:Math.min(total,readyAt+(DEADLINES.warmObservationMs+DEADLINES.terminalMs)*scale);},get warmDeadline(){return readyAt===null?null:Math.min(total,readyAt+DEADLINES.warmObservationMs*scale);},get total(){return total;},expired(){return now()>this.deadline;}};
}
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const groupPresent=pid=>{try{process.kill(-pid,0);return true;}catch(e){return e.code!=='ESRCH';}};
// Only this still-live group leader signals its own group. Its PID cannot be reused while it lives.
export async function ownedController(args,token,options={}){
 const channel=options.channel??process,launch=options.launch??spawn;
 const signal=options.signal??(sig=>process.kill(-process.pid,sig));
 need(process.env.GITHUB_ACTIONS==='true'&&typeof channel.send==='function'&&/^[a-f0-9]{48}$/.test(token));
 if(!options.launch){
  need(Array.isArray(args)&&args.length===14);
  need(args[0]==='test-without-building'&&args[1]==='-xctestrun'&&args[3]==='-destination');
  need(/^platform=iOS Simulator,id=[a-f0-9-]{36}$/i.test(args[4]));
  need(fs.realpathSync(args[2]).startsWith(fs.realpathSync(process.env.QA_OPEN_PRODUCTS)+path.sep));
  need(JSON.stringify(args.slice(5,13))===JSON.stringify(['-only-testing:OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-resultBundlePath']));
  need(path.basename(args[13])==='driver.xcresult');
 }
 let started=false,closing=false,target,killTimer,lease,resolveDone;
 const schedule=deadlineSchedule(options.now??(()=>Number(process.hrtime.bigint())/1e6),options.deadlineScale??1,options.leaseMs??DEADLINES.startupMs);
 const done=new Promise(resolve=>{resolveDone=resolve;});
 const armLease=()=>{clearTimeout(lease);lease=setTimeout(stop,Math.max(1,schedule.deadline-(options.now??(()=>Number(process.hrtime.bigint())/1e6))()));};
 const dispose=()=>{clearTimeout(lease);clearTimeout(killTimer);channel.removeListener('SIGTERM',stop);channel.removeListener('SIGINT',stop);channel.removeListener('disconnect',stop);channel.removeListener('message',messageHandler);};
 const stop=()=>{
  if(closing)return;closing=true;
  try{signal('SIGTERM');}catch{}
  killTimer=setTimeout(()=>{try{signal('SIGKILL');}catch{}finally{dispose();resolveDone(1);}},Math.min(options.termMs??1000,1000));
 };
 const messageHandler=message=>{
  if(message?.token!==token)return;
  if(message.command==='stop'){stop();return;}
  if(message.command==='phase-ready'){if(!started||closing||!schedule.advance(true))return;armLease();return;}
  if(message.command!=='start'||started||closing)return;started=true;
  try{
   target=launch('xcodebuild',args,{detached:false,stdio:['ignore',1,2]});
   target.on('error',()=>{try{channel.send({event:'target-error'});}catch{}stop();});
   target.on('exit',code=>{try{channel.send({event:'target-exit',code});}catch{}/* retain group leader until cleanup */});
   if(!Number.isSafeInteger(target.pid)){try{channel.send({event:'target-error'});}catch{}stop();}
  }catch{try{channel.send({event:'target-error'});}catch{}stop();}
 };
 channel.on('SIGTERM',stop);channel.on('SIGINT',stop);channel.on('disconnect',stop);channel.on('message',messageHandler);
 // No target inherits IPC; EOF or a bounded lease contains the group after supervisor loss.
 armLease();
 return await done;
}
export async function requestCleanup(dir,{timeoutMs=20000,pollMs=50}={}){
 try{
  const record=readOwnership(dir);need(/^[a-f0-9]{48}$/.test(record.controlToken));
  const request=path.join(dir,'cleanup.request');
  try{fs.writeFileSync(request,record.controlToken,{flag:'wx'});}catch(e){if(e.code!=='EEXIST')throw e;const stat=fs.lstatSync(request);need(stat.isFile()&&!stat.isSymbolicLink()&&stat.size===48);need(fs.readFileSync(request,'utf8')===record.controlToken);}
  const end=Date.now()+Math.min(timeoutMs,20000);
  while(Date.now()<end){
   if(terminalExit(dir)&&!fs.existsSync(path.join(dir,'ownership.json'))&&!fs.existsSync(path.join(dir,'emergency.json')))return true;
   await pause(pollMs);
  }
 }catch{}
 return false;
}
export async function run(udid,meta,dir,options={}){
 need(process.env.GITHUB_ACTIONS==='true'&&/^[a-f0-9-]{36}$/i.test(udid));need(fs.realpathSync(meta).startsWith(fs.realpathSync(process.env.QA_OPEN_PRODUCTS)+path.sep));
 const log=path.join(dir,'driver.log'),token=randomBytes(24).toString('hex');
 let fd,child,group,reader,ready=false,phaseSent=false,closing=false,failed=false,lastSize=0,publication=false;
 const now=options.now??(()=>Number(process.hrtime.bigint())/1e6);
 const schedule=deadlineSchedule(now,options.deadlineScale??1,options.deadlineMs??DEADLINES.startupMs);
 let resolveDone;
 const done=new Promise(resolve=>{resolveDone=resolve;});
 const injected=typeof options.launch==='function';
 let exited=false,closeSeen=false;
 const inspect=()=>{
  const text=readOwnedLog(log,fd,lastSize);lastSize=Buffer.byteLength(text);
  need(!text.includes('HOST_UI_FAIL')&&!text.includes('HOST_UI_BLOCKED'));
  if(/^HOST_UI_READY\r?$/m.test(text)){markers(text,'ready');ready=true;if(!phaseSent){need(schedule.advance(true));phaseSent=true;if(!injected)child.send({command:'phase-ready',token});}}
  if(ready)markers(text,'ready');
 };
 const contain=async()=>{
  if(!child)return true;
  if(injected){
   // Test adapter owns this exact ChildProcess; optional cleanup injection never reaches real CLI.
   if(options.contain)return await options.contain(child);
   if(Number.isSafeInteger(group)&&group>1&&options.hooks){
    const cleanup=options.cleanup??cleanupGroup;
    const remaining=Math.max(0,schedule.total-now());
    const invoke=()=>cleanup({dir,group,hooks:options.hooks,termMs:Math.min(options.termMs??1000,remaining),reapMs:Math.min(options.reapMs??19000,remaining)});
    try{if(!publication)writeOwnership(dir,{pid:group,controlToken:token,diagnosticOnly:true});return invoke().released;}
    catch{
     // Cleanup/publication exceptions cannot turn the primary failure into success.
     failed=true;
     try{const remaining=Math.max(0,schedule.total-now());const direct=cleanupGroup({dir,group,hooks:options.hooks,termMs:Math.min(options.termMs??1000,remaining),reapMs:Math.min(options.reapMs??19000,remaining)});return direct.released;}catch{}
    }
   }
   // ChildProcess.kill targets the creation handle, never a PID loaded from disk.
   if(!exited&&!closeSeen)try{child.kill('SIGTERM');}catch{}
   const end=Math.min(schedule.total,now()+Math.min(options.reapMs??19000,19000));
   while(!exited&&!closeSeen&&now()<end)await pause(10);
   return exited||closeSeen;
  }
  // The controller holds the PGID until self-group TERM/KILL. Disconnect also triggers its lease cleanup.
  if(!exited&&!closeSeen){
   try{child.send({command:'stop',token});}catch{try{child.kill('SIGTERM');}catch{}}
  }
  const end=Math.min(schedule.total,now()+19000);
  while(now()<end){
   if((exited||closeSeen)&&(!Number.isSafeInteger(group)||!groupPresent(group)))return true;
   await pause(50);
  }
  return false;
 };
 const finish=async code=>{
  if(closing)return done;closing=true;clearInterval(reader);
  let released=false;
  try{released=await contain();}catch{failed=true;}
  process.removeListener('SIGTERM',interrupted);process.removeListener('SIGINT',interrupted);
  if(released&&publication&&(!injected||fs.existsSync(path.join(dir,'ownership.json')))&&!clearOwnership(dir)){failed=true;released=false;}
  if(!released){
   failed=true;
   // Actionable diagnostic state only: it cannot authorize any external group/PID signal.
   try{fs.writeFileSync(path.join(dir,'emergency.json'),JSON.stringify({diagnosticOnly:true,controllerPid:group??null,controllerExited:exited,reason:'OWNED_CONTAINMENT_UNVERIFIED'}),{flag:'wx'});}catch{}
  }
  if(fd!==undefined)try{fs.closeSync(fd);}catch{failed=true;}
  const status=failed||code!==0||!released?1:0;
  try{fs.writeFileSync(path.join(dir,'exit'),String(status),{flag:'wx'});}catch{resolveDone(1);return done;}
  resolveDone(status);return done;
 };
 const interrupted=()=>{failed=true;void finish(1);};
 process.on('SIGTERM',interrupted);process.on('SIGINT',interrupted);
 try{
  fd=fs.openSync(log,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR);
  const st=fs.fstatSync(fd);fs.writeFileSync(log+'.owner',JSON.stringify({dev:String(st.dev),ino:String(st.ino)}),{flag:'wx'});
  const args=['test-without-building','-xctestrun',meta,'-destination','platform=iOS Simulator,id='+udid,'-only-testing:OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-resultBundlePath',path.join(dir,'driver.xcresult')];
  child=injected?options.launch('xcodebuild',args,{detached:true,stdio:['ignore',fd,fd],windowsHide:true}):spawn(process.execPath,[fileURLToPath(import.meta.url),'owned-controller',JSON.stringify(args),token],{detached:true,stdio:['ignore',fd,fd,'ipc'],windowsHide:true});
  // Install lifecycle handlers immediately, before any fallible disk publication.
  child.on('error',()=>{failed=true;void finish(1);});
  child.on('close',()=>{closeSeen=true;});
  child.on('exit',code=>{exited=true;if(closing)return;if(injected){try{inspect();need(ready);need(!schedule.expired());}catch{failed=true;}void finish(code??1);}else{failed=true;void finish(1);}});
  if(!injected)child.on('message',message=>{if(message?.event==='target-error'){failed=true;void finish(1);}else if(message?.event==='target-exit'){try{inspect();need(ready);need(!schedule.expired());}catch{failed=true;}void finish(message.code??1);}});
  group=child.pid;
  if(child.exitCode!==null&&child.exitCode!==undefined)exited=true;
  if(child.signalCode!==null&&child.signalCode!==undefined)exited=true;
  need(Number.isSafeInteger(group)&&group>1);
  need(child.exitCode===null||child.exitCode===undefined);need(child.signalCode===null||child.signalCode===undefined);
  (options.publishOwnership??writeOwnership)(dir,{pid:group,helperPid:process.pid,controlToken:token,diagnosticOnly:true,logDev:String(st.dev),logIno:String(st.ino)});publication=true;
  // Production target launch happens only after publication and handlers are installed.
  if(!injected)child.send({command:'start',token});
  reader=setInterval(()=>{
   try{
    const request=path.join(dir,'cleanup.request');
    if(fs.existsSync(request)){
     const stat=fs.lstatSync(request);need(stat.isFile()&&!stat.isSymbolicLink()&&stat.size===48);
     need(fs.readFileSync(request,'utf8')===token);failed=true;void finish(1);return;
    }
    inspect();need(!schedule.expired());
   }catch{failed=true;void finish(1);}
  },options.pollMs??100);
 }catch{failed=true;void finish(1);}
 return await done;
}
export async function cli(args,options={}){
 try{
  const [cmd,...a]=args;
  if(cmd==='metadata'){const j=prepare(JSON.parse(fs.readFileSync(a[0],'utf8')),a[1]);fs.writeFileSync(a[2],JSON.stringify(j),{flag:'wx'});}
  else if(cmd==='unchanged')unchanged(...a);
  else if(cmd==='check'){checkLog(a[0],a[1]);console.log('OK');}
  else if(cmd==='alive')need(Number.isSafeInteger(Number(a[0]))&&Number(a[0])>1&&helperAlive(Number(a[0]))&&!terminalExit(a[1]));
  else if(cmd==='proxy'){const o=readOwnership(a[0]);need(Number.isSafeInteger(o.helperPid)&&o.helperPid>1);process.stdout.write(String(o.helperPid)+'\n');}
  else if(cmd==='ownership'){const o=readOwnership(a[0]);need(Number.isSafeInteger(o.pid)&&o.pid>1);process.stdout.write(String(o.pid)+'\n');}
  else if(cmd==='cleanup')return await requestCleanup(a[0],options)?0:1;
  else if(cmd==='owned-controller')return await ownedController(JSON.parse(a[0]),a[1]);
  else if(cmd==='run')return await run(...a,options);
  else throw Error('HOST_UI_BLOCKED');
  return 0;
 }catch{console.error('HOST_UI_BLOCKED');return 1;}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=await cli(process.argv.slice(2));
