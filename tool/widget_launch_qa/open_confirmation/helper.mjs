import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {read,boundary} from '../verify_transport_receipts.mjs';
const need=x=>{if(!x)throw Error('HOST_UI_BLOCKED');};
const staticFail=()=>{throw Error('HOST_UI_BLOCKED');};
const DIAG_SOURCES=new Set(['helper','controller','driver','transport']);
const DIAG_REASONS=new Set(['NONE','START_PRECONDITION','START_DIRECTORY','START_OWNER_PUBLISH','START_TERMINAL','START_PROXY_READ','START_PROXY_LIVE','START_READY_TIMEOUT','START_READY_LOG_GUARD','POST_READY_PID_EMPTY','POST_READY_LIVE_GUARD','POST_READY_LOG_GUARD','COLD_ACK_PREDICATE','MARKER_PREDICATE','LOG_GUARD_BLOCKED','STARTUP_DEADLINE','READY_ACCEPTED','READY_REJECTED','TARGET_START_ERROR','TARGET_EXIT_NONZERO','CONTROL_DISCONNECT','CONTROL_SIGNAL','CONTROL_STOP','LEASE_EXPIRED','CLEANUP_REQUEST','CONTAINMENT_UNVERIFIED','OS_REQUEST_FAILED','OS_REQUEST_ACCEPTED','PRE_URL_GUARD_PASSED','FINISH_TIMEOUT','FINISH_EXIT','FINISH_OWNERSHIP','FINISH_STATUS','COLD_FINISH_BLOCKED','WARM_FINISH_BLOCKED','COLD_FINISH','WARM_FINISH','FORMAT_BOUNDED']);
const DIAG_PHASES=new Set(['UNKNOWN','STARTUP','READY','COLD','WARM','CONTAINMENT','TERMINAL']);
const DIAG_ERRORS=new Set(['NONE','BLOCKED','EIO','ENOENT','EACCES','OTHER']);
const DIAG_NUMBERS=['elapsedMs','readyElapsedMs','phaseElapsedMs','readyCount','ackCount','noAlertCount','failCount','targetExitCode'];
const DIAG_FLAGS=['ownerPresent','proxyValid','helperLive','terminalPresent','fdRegular','fdIdentityValid','readyAccepted','targetExited','released','deadlineExpired'];
export function formatDiagnostic(value){
 const input=value&&typeof value==='object'&&!Array.isArray(value)?value:{};
 const row={kind:'WIDGET_QA_DIAG_V1',source:DIAG_SOURCES.has(input.source)?input.source:'helper',reason:DIAG_REASONS.has(input.reason)?input.reason:'FORMAT_BOUNDED',firstFailure:DIAG_REASONS.has(input.firstFailure)?input.firstFailure:'NONE',phase:DIAG_PHASES.has(input.phase)?input.phase:'UNKNOWN'};
 for(const key of DIAG_NUMBERS){const n=input[key];if(Number.isFinite(n)){const lo=key.endsWith('Count')?0:-1;row[key]=Math.max(lo,Math.min(60000,Math.trunc(n)));}}
 for(const key of DIAG_FLAGS){if(typeof input[key]==='boolean')row[key]=input[key];}
 row.errorClass=DIAG_ERRORS.has(input.errorClass)?input.errorClass:'NONE';
 const text=JSON.stringify(row);return Buffer.byteLength(text,'utf8')<=768?text:'{"kind":"WIDGET_QA_DIAG_V1","source":"helper","reason":"FORMAT_BOUNDED","firstFailure":"NONE","phase":"UNKNOWN","errorClass":"NONE"}';
}
function emitDiagnostic(value){try{process.stderr.write(formatDiagnostic(value)+'\n');}catch{}}

// Exact 4 no-AUT target-level keys allowlisted for the no-AUT captured metadata shape.
// Each is shape+value+location validated; nested or top-level additions fail closed.
const NO_AUT_KEYS=Object.freeze(['UseUITargetAppProvidedByTests','UITargetAppCommandLineArguments','UITargetAppEnvironmentVariables','UITargetAppMainThreadCheckerEnabled']);
const noAutKeySet=new Set(NO_AUT_KEYS);
const CAPTURED_TARGET_KEYS=Object.freeze(['IsXCTRunnerHostedTestBundle','BundleIdentifiersForCrashReportEmphasis','IsUITestBundle','TestBundlePath','TestHostBundleIdentifier','BlueprintProviderRelativePath','UseUITargetAppProvidedByTests','ToolchainsSettingValue','ProductModuleName','TestLanguage','UITargetAppCommandLineArguments','DefaultTestExecutionTimeAllowance','BlueprintProviderName','UITargetAppEnvironmentVariables','UserAttachmentLifetime','DiagnosticCollectionPolicy','UITargetAppMainThreadCheckerEnabled','TestHostPath','RunOrder','EnvironmentVariables','CommandLineArguments','SystemAttachmentLifetime','TestingEnvironmentVariables','BlueprintName','TestRegion','PreferredScreenCaptureFormat','TestTimeoutsEnabled','DependentProductPaths']);
const NO_AUT_ENV=Object.freeze({
 DYLD_LIBRARY_PATH:'__TESTROOT__/Debug-iphonesimulator',
 DYLD_FRAMEWORK_PATH:'__TESTROOT__/Debug-iphonesimulator',
 XCODE_SCHEME_NAME:'OpenConfirmation',
 __XPC_DYLD_LIBRARY_PATH:'__TESTROOT__/Debug-iphonesimulator',
 APP_DISTRIBUTOR_ID_OVERRIDE:'com.apple.AppStore',
 __XCODE_BUILT_PRODUCTS_DIR_PATHS:'__TESTROOT__/Debug-iphonesimulator',
 __XPC_DYLD_FRAMEWORK_PATH:'__TESTROOT__/Debug-iphonesimulator',
});
const TARGET_ENV=Object.freeze({OS_ACTIVITY_DT_MODE:'YES',APP_DISTRIBUTOR_ID_OVERRIDE:'com.apple.AppStore',TERM:'dumb',SQLITE_ENABLE_THREAD_ASSERTIONS:'1'});
const TESTING_ENV=Object.freeze({
 DYLD_LIBRARY_PATH:'__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib',
 DYLD_FRAMEWORK_PATH:'__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks',
 XCODE_SCHEME_NAME:'OpenConfirmation',
 DYLD_INSERT_LIBRARIES:'__SIMRUNTIMEROOT__/usr/lib/libMainThreadChecker.dylib',
 __XPC_DYLD_LIBRARY_PATH:'__TESTROOT__/Debug-iphonesimulator',
 __XCODE_BUILT_PRODUCTS_DIR_PATHS:'__TESTROOT__/Debug-iphonesimulator',
 MTC_CRASH_ON_REPORT:'1',
 __XPC_DYLD_FRAMEWORK_PATH:'__TESTROOT__/Debug-iphonesimulator',
});
const exactMap=(actual,expected)=>!!actual&&typeof actual==='object'&&!Array.isArray(actual)&&Object.keys(actual).length===Object.keys(expected).length&&Object.keys(expected).every(k=>Object.hasOwn(actual,k)&&actual[k]===expected[k]);
const NO_AUT_KEY_VALIDATORS=Object.freeze({
 UseUITargetAppProvidedByTests:(v)=>v===true,
 UITargetAppCommandLineArguments:(v)=>Array.isArray(v)&&v.length===0,
 UITargetAppEnvironmentVariables:(v)=>{
  return exactMap(v,NO_AUT_ENV);
 },
 UITargetAppMainThreadCheckerEnabled:(v)=>v===true,
});

// Default plist reader: macOS built-in plutil. The conversion is bounded to local own
// files; the parser is not part of the validation surface so no general bplist parser
// is built. Other platforms fail closed without any external architecture.
function defaultReadPlist(file){
 if(process.platform!=='darwin')staticFail();
 try{
  const st=fs.lstatSync(file);need(st.isFile()&&!st.isSymbolicLink()&&st.size>0&&st.size<=256*1024);
  const canonical=fs.realpathSync(file);need(canonical===file);
  const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW??0));
  let bytes;
  try{const current=fs.fstatSync(fd);need(current.isFile()&&current.dev===st.dev&&current.ino===st.ino&&current.size===st.size);bytes=Buffer.alloc(current.size);let n=0;while(n<bytes.length){const got=fs.readSync(fd,bytes,n,bytes.length-n,n);need(got>0);n+=got;}const after=fs.fstatSync(fd);need(after.dev===current.dev&&after.ino===current.ino&&after.size===current.size);const pathAfter=fs.lstatSync(file);need(pathAfter.isFile()&&!pathAfter.isSymbolicLink()&&pathAfter.dev===after.dev&&pathAfter.ino===after.ino&&pathAfter.size===after.size);need(fs.realpathSync(file)===canonical);}finally{fs.closeSync(fd);}
  const r=spawnSync('/usr/bin/plutil',['-convert','json','-o','-','--','-'],{input:bytes,encoding:'utf8',windowsHide:true,timeout:2000,maxBuffer:256*1024});
  if(r.error||r.status!==0||typeof r.stdout!=='string'||r.stdout.length>256*1024)staticFail();
  return JSON.parse(r.stdout);
 }catch{staticFail();}
}

// Small portable test seam: tests may inject a readPlist function for local XML plists.
// Validation still runs in full; only the byte->object conversion is replaced.
function readPlistWith(file,plistRead){
 if(typeof plistRead==='function')return plistRead(file);
 return defaultReadPlist(file);
}
function validateHostInfoPlist(plist){
 need(plist&&typeof plist==='object'&&!Array.isArray(plist));
 need(typeof plist.CFBundleIdentifier==='string'&&plist.CFBundleIdentifier==='com.fluxstudio.qa.openconfirmation.xctrunner');
 need(typeof plist.CFBundleExecutable==='string'&&plist.CFBundleExecutable==='OpenConfirmation-Runner');
 need(typeof plist.CFBundlePackageType==='string'&&plist.CFBundlePackageType==='APPL');
}
function validateTestInfoPlist(plist){
 need(plist&&typeof plist==='object'&&!Array.isArray(plist));
 need(typeof plist.CFBundleIdentifier==='string'&&plist.CFBundleIdentifier==='com.fluxstudio.qa.openconfirmation');
 need(typeof plist.CFBundleExecutable==='string'&&plist.CFBundleExecutable==='OpenConfirmation');
 need(typeof plist.CFBundlePackageType==='string'&&plist.CFBundlePackageType==='BNDL');
 need(plist.XCTContainsUITests===true);
}
export function prepare(j,products,options={}){
 need(j&&typeof j==='object');const version=j.__xctestrun_metadata__?.FormatVersion??1;need(version===1||version===2);let targets;
 if(version===2){need(j.TestConfigurations?.length===1);targets=j.TestConfigurations[0].TestTargets;}else targets=Object.entries(j).filter(([k])=>k!=='__xctestrun_metadata__').map(([k,v])=>({...v,BlueprintName:v.BlueprintName??k}));
 need(Array.isArray(targets)&&targets.length===1);const t=targets[0];need(Object.keys(t).length===CAPTURED_TARGET_KEYS.length&&CAPTURED_TARGET_KEYS.every(k=>Object.hasOwn(t,k)));need(t.BlueprintName==='OpenConfirmation'&&t.IsUITestBundle===true&&t.IsXCTRunnerHostedTestBundle===true);
 need(Array.isArray(t.CommandLineArguments)&&t.CommandLineArguments.length===0&&exactMap(t.EnvironmentVariables,TARGET_ENV)&&exactMap(t.TestingEnvironmentVariables,TESTING_ENV));
 // No-AUT allowlist: exactly 4 target-level keys with shape/value validation.
 for(const key of NO_AUT_KEYS){need(Object.hasOwn(t,key));need(NO_AUT_KEY_VALIDATORS[key](t[key]));}
 // Reject any other UITargetApp* keys at target level (e.g. UITargetAppPath, UITargetAppBundleIdentifier).
 for(const k of Object.keys(t)){if(k.startsWith('UITargetApp')&&!noAutKeySet.has(k))staticFail();}
 // DependentProductPaths: exactly own host and own test bundle, no foreign/missing/duplicate/extra.
 const deps=t.DependentProductPaths;need(Array.isArray(deps)&&deps.length===2);
 const hostRel='__TESTROOT__/Debug-iphonesimulator/OpenConfirmation-Runner.app';
 const bundleRel='__TESTHOST__/PlugIns/OpenConfirmation.xctest';
 need(t.TestHostPath===hostRel&&t.TestBundlePath===bundleRel);
 need(deps[0]===hostRel&&deps[1]==='__TESTROOT__/Debug-iphonesimulator/OpenConfirmation-Runner.app/PlugIns/OpenConfirmation.xctest');
 const root=fs.realpathSync(products);need(root===path.resolve(products));
 const resolvedHost=path.join(root,'Debug-iphonesimulator','OpenConfirmation-Runner.app');
 const resolvedBundle=path.join(resolvedHost,'PlugIns','OpenConfirmation.xctest');
 need(path.resolve(t.TestHostPath.replace('__TESTROOT__',root))===resolvedHost);
 need(path.resolve(t.TestBundlePath.replace('__TESTHOST__',resolvedHost))===resolvedBundle);
 // Scan rest of j, skipping the target's no-AUT keys (already validated) and DependentProductPaths (already validated).
 // Deep-copy keeps the original `j` untouched and removes only the allowlisted target-level keys
 // so the blanket forbidden-key scan still rejects nested occurrences and arbitrary additional keys.
 const scanJ=JSON.parse(JSON.stringify(j));
 if(version===2){const target=scanJ.TestConfigurations[0].TestTargets[0];for(const key of NO_AUT_KEYS)delete target[key];delete target.DependentProductPaths;}
 else{for(const k of Object.keys(scanJ)){if(k==='__xctestrun_metadata__')continue;const target=scanJ[k];for(const key of NO_AUT_KEYS)delete target[key];delete target.DependentProductPaths;break;}}
 function scan(o){for(const [k,v] of Object.entries(o)){need(!/UITargetApp|TargetApplication|TestTargetName|TargetTestID|TEST_HOST|TEST_TARGET_NAME/i.test(k));if(/dependenc/i.test(k))staticFail();if(typeof v==='string')need(!/(^|[/\\])Runner(?:\.app|\.xctest|$)|com\.fluxstudio\.planflow/i.test(v));if(v&&typeof v==='object')scan(v);}}scan(scanJ);
 need(fs.realpathSync(resolvedHost)===resolvedHost&&fs.realpathSync(resolvedBundle)===resolvedBundle);
 for(const p of [resolvedHost,resolvedBundle]){const st=fs.lstatSync(p);need(st.isDirectory()&&!st.isSymbolicLink());}
 need(t.TestHostBundleIdentifier==='com.fluxstudio.qa.openconfirmation.xctrunner');
 // Info.plists must be regular, canonical, bounded files inside the exact owned products.
 const hostInfo=path.join(resolvedHost,'Info.plist'),testInfo=path.join(resolvedBundle,'Info.plist');
 for(const [f,base] of [[hostInfo,resolvedHost],[testInfo,resolvedBundle]]){const st=fs.lstatSync(f);need(st.isFile()&&!st.isSymbolicLink()&&st.size>0&&st.size<=256*1024);const canonical=fs.realpathSync(f);need(canonical===f&&canonical.startsWith(base+path.sep));}
 validateHostInfoPlist(readPlistWith(hostInfo,options.plistRead));
 validateTestInfoPlist(readPlistWith(testInfo,options.plistRead));
 t.EnvironmentVariables={...(t.EnvironmentVariables??{}),QA_OPEN_CONFIRMATION_GATE:'ci-owned-exact-open-v1'};if(version===1)j.OpenConfirmation=t;return j;
}
export function unchanged(file,bfile){const b=JSON.parse(fs.readFileSync(bfile,'utf8'));need(JSON.stringify(boundary(fs.existsSync(file)?read(file):[]))===JSON.stringify(b));}
export function markers(text,phase){need(!text.includes('HOST_UI_FAIL')&&!text.includes('HOST_UI_BLOCKED'));const count=m=>(text.match(new RegExp('^'+m+'\\r?$','gm'))??[]).length;need(count('HOST_UI_READY')===1);if(phase==='ready')return;need((count('HOST_UI_ACK')===1&&count('HOST_UI_NO_ALERT')===0)||(phase==='warm'&&count('HOST_UI_ACK')===0&&count('HOST_UI_NO_ALERT')===1));}
const markerFacts=text=>{const count=m=>(text.match(new RegExp('^'+m+'\\r?$','gm'))??[]).length;return {readyCount:count('HOST_UI_READY'),ackCount:count('HOST_UI_ACK'),noAlertCount:count('HOST_UI_NO_ALERT'),failCount:count('HOST_UI_FAIL')};};
const safeErrorClass=e=>DIAG_ERRORS.has(e?.code)?e.code:(e?.code?'OTHER':'BLOCKED');
const safePhase=phase=>phase==='ready'?'READY':phase==='cold'?'COLD':phase==='warm'?'WARM':'UNKNOWN';
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
export function readOwnedLog(file,ownedFd,minSize=0,diagnostic){
 let fd=ownedFd,opened=false;
 try{
  const owned=JSON.parse(fs.readFileSync(file+'.owner','utf8'));
  if(ownedFd===undefined){fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW??0));opened=true;}
  const before=fs.fstatSync(fd);
  const lst=fs.lstatSync(file);
  if(diagnostic){diagnostic.fdRegular=before.isFile()&&lst.isFile()&&!lst.isSymbolicLink();diagnostic.fdIdentityValid=before.dev===lst.dev&&before.ino===lst.ino&&String(before.dev)===owned.dev&&String(before.ino)===owned.ino;}
  need(before.isFile()&&lst.isFile()&&!lst.isSymbolicLink()&&before.dev===lst.dev&&before.ino===lst.ino&&String(before.dev)===owned.dev&&String(before.ino)===owned.ino&&before.size>=minSize&&before.size<4*1024*1024);
  const b=Buffer.alloc(before.size);
  let n=0;
  while(n<b.length){
   let r=0;
   try{r=fs.readSync(fd,b,n,b.length-n,n);}catch(e){if(diagnostic)diagnostic.errorClass=safeErrorClass(e);staticFail();}
   need(r>0);n+=r;
  }
  let after;
  try{after=fs.fstatSync(fd);}catch{staticFail();}
  need(after.size>=before.size&&after.size<4*1024*1024&&after.dev===before.dev&&after.ino===before.ino);
  const lst2=fs.lstatSync(file);
  need(!lst2.isSymbolicLink()&&lst2.dev===after.dev&&lst2.ino===after.ino);
  return b.toString('utf8');
 }catch(e){if(diagnostic&&!diagnostic.errorClass)diagnostic.errorClass=safeErrorClass(e);throw Error('HOST_UI_BLOCKED');}
 finally{if(opened&&fd!==undefined)try{fs.closeSync(fd);}catch{}}
}
export function checkLog(file,phase,ownedFd,diagnostic){
 const text=readOwnedLog(file,ownedFd,1,diagnostic);if(diagnostic)Object.assign(diagnostic,markerFacts(text));markers(text,phase);return true;
}
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
 const controllerNow=options.now??(()=>Number(process.hrtime.bigint())/1e6);
 const schedule=deadlineSchedule(controllerNow,options.deadlineScale??1,options.leaseMs??DEADLINES.startupMs);
 let firstFailure='NONE',readyAccepted=false,diagnosticEmitted=false;
 const markControllerFailure=code=>{if(firstFailure==='NONE')firstFailure=code;};
 const done=new Promise(resolve=>{resolveDone=resolve;});
 const armLease=()=>{clearTimeout(lease);lease=setTimeout(()=>stop('LEASE_EXPIRED'),Math.max(1,schedule.deadline-controllerNow()));};
 const dispose=()=>{clearTimeout(lease);clearTimeout(killTimer);channel.removeListener('SIGTERM',onTerm);channel.removeListener('SIGINT',onInt);channel.removeListener('disconnect',stop);channel.removeListener('message',messageHandler);};
 const stop=(reason='CONTROL_DISCONNECT')=>{
  if(closing)return;closing=true;if(reason!=='CONTROL_STOP')markControllerFailure(reason);
  if(!diagnosticEmitted){diagnosticEmitted=true;const elapsed=Math.max(0,Math.round(controllerNow()-schedule.started));emitDiagnostic({source:'controller',reason:firstFailure,firstFailure,phase:readyAccepted?'READY':'STARTUP',elapsedMs:elapsed,readyElapsedMs:schedule.readyAt===null?-1:Math.max(0,Math.round(schedule.readyAt-schedule.started)),phaseElapsedMs:elapsed,targetExited:!!target&&(target.exitCode!==null&&target.exitCode!==undefined),targetExitCode:Number.isInteger(target?.exitCode)?target.exitCode:-1,readyAccepted,helperLive:true});}
  try{signal('SIGTERM');}catch{}
  killTimer=setTimeout(()=>{try{signal('SIGKILL');}catch{}finally{dispose();resolveDone(1);}},Math.min(options.termMs??1000,1000));
 };
 const onTerm=()=>stop('CONTROL_SIGNAL'),onInt=()=>stop('CONTROL_SIGNAL');
 const messageHandler=message=>{
  if(message?.token!==token)return;
  if(message.command==='phase-ready'){
   if(!started||closing)return;
   if(!schedule.advance(true)){markControllerFailure('READY_REJECTED');if(!diagnosticEmitted){diagnosticEmitted=true;const elapsed=Math.max(0,Math.round(controllerNow()-schedule.started));emitDiagnostic({source:'controller',reason:firstFailure,firstFailure,phase:'STARTUP',elapsedMs:elapsed,readyElapsedMs:-1,phaseElapsedMs:elapsed,readyAccepted:false,deadlineExpired:schedule.expired(),helperLive:true});}return;}
   readyAccepted=true;const elapsed=Math.max(0,Math.round(controllerNow()-schedule.started));emitDiagnostic({source:'controller',reason:'READY_ACCEPTED',firstFailure,phase:'READY',elapsedMs:elapsed,readyElapsedMs:Math.max(0,Math.round(schedule.readyAt-schedule.started)),phaseElapsedMs:0,readyAccepted:true,helperLive:true});armLease();return;
  }
  if(message.command==='stop'){stop('CONTROL_STOP');return;}
  if(message.command!=='start'||started||closing)return;started=true;
  try{
   target=launch('xcodebuild',args,{detached:false,stdio:['ignore',1,2]});
   target.on('error',()=>{try{channel.send({event:'target-error'});}catch{}stop('TARGET_START_ERROR');});
   target.on('exit',code=>{try{channel.send({event:'target-exit',code});}catch{}/* retain group leader until cleanup */});
   if(!Number.isSafeInteger(target.pid)){try{channel.send({event:'target-error'});}catch{}stop('TARGET_START_ERROR');}
  }catch{try{channel.send({event:'target-error'});}catch{}stop('TARGET_START_ERROR');}
 };
 channel.on('SIGTERM',onTerm);channel.on('SIGINT',onInt);channel.on('disconnect',stop);channel.on('message',messageHandler);
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
 let fd,child,group,reader,ready=false,phaseSent=false,closing=false,failed=false,lastSize=0,publication=false,targetExitCode=null;
 const now=options.now??(()=>Number(process.hrtime.bigint())/1e6);
 const schedule=deadlineSchedule(now,options.deadlineScale??1,options.deadlineMs??DEADLINES.startupMs);
 const diag={source:'helper',phase:'STARTUP',reason:'NONE',firstFailure:'NONE'};
 const markFailure=code=>{if(diag.firstFailure==='NONE')diag.firstFailure=code;diag.reason=diag.firstFailure;};
 let resolveDone;
 const done=new Promise(resolve=>{resolveDone=resolve;});
 const injected=typeof options.launch==='function';
 let exited=false,closeSeen=false;
 const inspect=()=>{
  const text=readOwnedLog(log,fd,lastSize,diag);lastSize=Buffer.byteLength(text);Object.assign(diag,markerFacts(text));
  need(!text.includes('HOST_UI_FAIL')&&!text.includes('HOST_UI_BLOCKED'));
  if(/^HOST_UI_READY\r?$/m.test(text)){markers(text,'ready');ready=true;if(!phaseSent){need(schedule.advance(true));phaseSent=true;if(!injected)child.send({command:'phase-ready',token});}}
  if(ready)markers(text,'ready');
 };
 const observeFailure=()=>schedule.expired()?'STARTUP_DEADLINE':ready&&!phaseSent?'READY_REJECTED':diag.errorClass&&diag.errorClass!=='NONE'?'LOG_GUARD_BLOCKED':'MARKER_PREDICATE';
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
  try{released=await contain();}catch{failed=true;markFailure('CONTAINMENT_UNVERIFIED');}
  process.removeListener('SIGTERM',interrupted);process.removeListener('SIGINT',interrupted);
  if(released&&publication&&(!injected||fs.existsSync(path.join(dir,'ownership.json')))&&!clearOwnership(dir)){failed=true;released=false;}
  if(!released){
   failed=true;markFailure('CONTAINMENT_UNVERIFIED');
   // Actionable diagnostic state only: it cannot authorize any external group/PID signal.
   try{fs.writeFileSync(path.join(dir,'emergency.json'),JSON.stringify({diagnosticOnly:true,controllerPid:group??null,controllerExited:exited,reason:'OWNED_CONTAINMENT_UNVERIFIED'}),{flag:'wx'});}catch{}
  }
  if(fd!==undefined)try{fs.closeSync(fd);}catch{failed=true;}
  const status=failed||code!==0||!released?1:0;
  if(code!==0&&diag.firstFailure==='NONE')markFailure('TARGET_EXIT_NONZERO');
  try{fs.writeFileSync(path.join(dir,'exit'),String(status),{flag:'wx'});}catch{failed=true;markFailure('FINISH_STATUS');resolveDone(1);return done;}
  const elapsed=Math.max(0,Math.round(now()-schedule.started));diag.phase=ready?'TERMINAL':'STARTUP';diag.elapsedMs=elapsed;diag.readyElapsedMs=schedule.readyAt===null?-1:Math.max(0,Math.round(schedule.readyAt-schedule.started));diag.phaseElapsedMs=diag.readyElapsedMs<0?elapsed:Math.max(0,elapsed-diag.readyElapsedMs);diag.ownerPresent=publication&&!released;diag.proxyValid=publication&&Number.isSafeInteger(group);diag.helperLive=true;diag.terminalPresent=true;diag.released=released;diag.targetExited=exited;diag.targetExitCode=Number.isInteger(targetExitCode)?targetExitCode:(Number.isInteger(code)?code:-1);emitDiagnostic(diag);
  resolveDone(status);return done;
 };
 const interrupted=()=>{failed=true;markFailure('CONTROL_SIGNAL');void finish(1);};
 process.on('SIGTERM',interrupted);process.on('SIGINT',interrupted);
 try{
  fd=fs.openSync(log,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR);
  const st=fs.fstatSync(fd);fs.writeFileSync(log+'.owner',JSON.stringify({dev:String(st.dev),ino:String(st.ino)}),{flag:'wx'});
  const args=['test-without-building','-xctestrun',meta,'-destination','platform=iOS Simulator,id='+udid,'-only-testing:OpenConfirmation/OpenConfirmation/testExactPlanFlowOpen','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-resultBundlePath',path.join(dir,'driver.xcresult')];
  child=injected?options.launch('xcodebuild',args,{detached:true,stdio:['ignore',fd,fd],windowsHide:true}):spawn(process.execPath,[fileURLToPath(import.meta.url),'owned-controller',JSON.stringify(args),token],{detached:true,stdio:['ignore',fd,fd,'ipc'],windowsHide:true});
  // Install lifecycle handlers immediately, before any fallible disk publication.
  child.on('error',()=>{failed=true;markFailure('TARGET_START_ERROR');void finish(1);});
  child.on('close',()=>{closeSeen=true;});
  child.on('exit',code=>{exited=true;targetExitCode=code??1;if(closing)return;if(injected){try{inspect();need(ready);need(!schedule.expired());}catch{failed=true;markFailure(observeFailure());}void finish(code??1);}else{failed=true;markFailure('TARGET_EXIT_NONZERO');void finish(1);}});
  if(!injected)child.on('message',message=>{if(message?.event==='target-error'){failed=true;markFailure('TARGET_START_ERROR');void finish(1);}else if(message?.event==='target-exit'){targetExitCode=message.code??1;try{inspect();need(ready);need(!schedule.expired());}catch{failed=true;markFailure(observeFailure());}void finish(message.code??1);}});
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
     need(fs.readFileSync(request,'utf8')===token);failed=true;markFailure('CLEANUP_REQUEST');void finish(1);return;
    }
    inspect();if(schedule.expired()){failed=true;markFailure('STARTUP_DEADLINE');need(false);}
   }catch{failed=true;if(diag.firstFailure==='NONE')markFailure(diag.errorClass&&diag.errorClass!=='NONE'?'LOG_GUARD_BLOCKED':'MARKER_PREDICATE');void finish(1);}
  },options.pollMs??100);
 }catch{failed=true;if(diag.firstFailure==='NONE')markFailure(fd===undefined?'START_DIRECTORY':publication?'TARGET_START_ERROR':'START_OWNER_PUBLISH');void finish(1);}
 return await done;
}
export async function cli(args,options={}){
 try{
  const [cmd,...a]=args;
  if(cmd==='metadata'){need(a.length===3);const st=fs.lstatSync(a[0]);need(st.isFile()&&!st.isSymbolicLink()&&st.size>0&&st.size<=1024*1024);const fd=fs.openSync(a[0],fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW??0));let text;try{const s=fs.fstatSync(fd);need(s.isFile()&&s.size===st.size);const b=Buffer.alloc(s.size);let n=0;while(n<b.length){const got=fs.readSync(fd,b,n,b.length-n,n);need(got>0);n+=got;}need(fs.fstatSync(fd).size===s.size);text=b.toString('utf8');}finally{fs.closeSync(fd);}const j=prepare(JSON.parse(text),a[1]);fs.writeFileSync(a[2],JSON.stringify(j),{flag:'wx'});}
  else if(cmd==='unchanged')unchanged(...a);
  else if(cmd==='check'){
   const d={source:'helper',phase:safePhase(a[1]),reason:'NONE',firstFailure:'NONE'};
   try{checkLog(a[0],a[1],undefined,d);console.log('OK');}
   catch(e){const coldMiss=d.phase==='COLD'&&d.readyCount===1&&d.ackCount===0&&d.noAlertCount===1;d.reason=coldMiss?'COLD_ACK_PREDICATE':d.errorClass&&d.errorClass!=='NONE'?'LOG_GUARD_BLOCKED':'MARKER_PREDICATE';d.firstFailure=d.reason;if(a[2]!=='wait')emitDiagnostic(d);throw e;}
  }
  else if(cmd==='alive'){const valid=Number.isSafeInteger(Number(a[0]))&&Number(a[0])>1;let live=false,terminal=false;if(valid){live=helperAlive(Number(a[0]));if(live)terminal=terminalExit(a[1]);}if(!valid||!live||terminal)emitDiagnostic({source:'helper',reason:'POST_READY_LIVE_GUARD',firstFailure:'POST_READY_LIVE_GUARD',phase:'READY',helperLive:!!live,terminalPresent:valid&&live?!!terminal:undefined});need(valid&&live&&!terminal);}
  else if(cmd==='proxy'){try{const o=readOwnership(a[0]);need(Number.isSafeInteger(o.helperPid)&&o.helperPid>1);process.stdout.write(String(o.helperPid)+'\n');}catch(e){emitDiagnostic({source:'helper',reason:'START_PROXY_READ',firstFailure:'START_PROXY_READ',phase:'STARTUP',errorClass:safeErrorClass(e)});throw e;}}
  else if(cmd==='ownership'){const o=readOwnership(a[0]);need(Number.isSafeInteger(o.pid)&&o.pid>1);process.stdout.write(String(o.pid)+'\n');}
  else if(cmd==='cleanup')return await requestCleanup(a[0],options)?0:1;
  else if(cmd==='owned-controller')return await ownedController(JSON.parse(a[0]),a[1]);
  else if(cmd==='run')return await run(...a,options);
  else throw Error('HOST_UI_BLOCKED');
  return 0;
 }catch{console.error('HOST_UI_BLOCKED');return 1;}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))process.exitCode=await cli(process.argv.slice(2));
