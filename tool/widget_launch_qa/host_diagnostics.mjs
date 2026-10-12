// Host observations only. Never callback/receipt evidence; no raw tool output persists.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
export function runTool(args, timeout, execute=spawnSync) {
  try {
    const r=execute('xcrun', args, {encoding:'utf8',timeout,killSignal:'SIGKILL',maxBuffer:65536});
    const executionFailed=Boolean(r.error||r.signal);
    const status=Number.isInteger(r.status)&&(!executionFailed||r.status!==0)?r.status:124;
    return {status, stdout:r.stdout?'output_suppressed':'empty', stderr:r.stderr?'output_suppressed':'empty', outcome:executionFailed?'tool_unavailable_or_timeout':status===0?'accepted':'rejected'};
  } catch { return {status:124,stdout:'unknown',stderr:'unknown',outcome:'tool_unavailable_or_timeout'}; }
}
function publish(file, value) {
  const temporary=file+'.new';
  fs.writeFileSync(temporary,JSON.stringify(value)+'\n',{flag:'wx'});
  fs.renameSync(temporary,file);
}
export function launch(udid, uri, output, execute=spawnSync) {
  const result=runTool(['simctl','openurl',udid,uri],15000,execute);
  try { publish(output,{hostObservation:true,callbackProof:false,utc:new Date().toISOString(),...result}); }
  catch { return result.status || 1; }
  return result.status;
}
export function receiptPathMetadata(file) {
  const result={expectedLocation:'expectedContainerTmp',canonical:'unknown',symlink:'unknown',exists:'unknown',sizeClass:'unknown'};
  try {
    const parent=path.dirname(file);
    result.canonical=fs.realpathSync(parent)===path.resolve(parent)?'canonical':'noncanonical';
    const s=fs.lstatSync(file);
    result.exists='present';result.symlink=s.isSymbolicLink()?'symlink':'not_symlink';
    result.sizeClass=s.size===0?'empty':s.size<=131072?'bounded':'oversize';
  } catch(e) { if(e.code==='ENOENT') result.exists='absent'; }
  return result;
}
export function failure(udid, screenshot, output, receipt, execute=spawnSync) {
  // One synchronous owned-UDID capture, 15 seconds; no watcher survives it.
  const result=runTool(['simctl','io',udid,'screenshot',screenshot],15000,execute);
  publish(output,{hostObservation:true,callbackProof:false,utc:new Date().toISOString(),screenshot:result,receiptPath:receiptPathMetadata(receipt)});
}
// Raw process listing goes only to the existing guarded snapshot publisher.
if(process.argv[2]==='process') {
  try {
    const args=process.argv.slice(3);
    if(args.length!==5 || args[0]!=='simctl' || args[1]!=='spawn' || args[3]!=='launchctl' || args[4]!=='list') throw Error('invalid_command');
    const r=spawnSync('xcrun',args,{encoding:'utf8',timeout:3000,killSignal:'SIGKILL',maxBuffer:131072});
    if(r.status===0 && !r.error && !r.signal) process.stdout.write(r.stdout);
    else process.exitCode=Number.isInteger(r.status)&&r.status!==0?r.status:124;
  } catch { process.exitCode=124; }
}
if(process.argv[2]==='launch') process.exitCode=launch(...process.argv.slice(3));
if(process.argv[2]==='failure') {
  try { failure(...process.argv.slice(3)); } catch { process.exitCode=1; }
}
