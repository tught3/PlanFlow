import fs from 'node:fs';
import path from 'node:path';
import {createHash, randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
export const MAX_BYTES=131072, MAX_ROWS=128;
export const mask = nonce => createHash('sha256').update(nonce,'utf8').digest('hex');
const sources=['applinks_initial','applinks_warm','homewidget_initial','homewidget_warm'];
function requireThat(ok){if(!ok) throw Error('invalid_evidence');}
export function parse(text){
  requireThat(Buffer.byteLength(text)<=MAX_BYTES && (!text || text.endsWith('\n')));
  const lines=text ? text.slice(0,-1).split('\n') : [];
  requireThat(lines.length<=MAX_ROWS);
  return lines.map(line=>{
    const r=JSON.parse(line); requireThat(r && typeof r==='object' && !Array.isArray(r));
    requireThat(['BOOT','READY','RECEIVED','NULL','ERROR'].includes(r.kind));
    const keys=['kind','bootId','pid', ...(['RECEIVED','NULL','ERROR'].includes(r.kind)?['source']:[]), ...(r.kind==='RECEIVED'?['nonceHash','target']:[]), ...(r.kind==='ERROR'?['reason']:[])];
    requireThat(Object.keys(r).length===keys.length && keys.every(k=>Object.hasOwn(r,k)));
    requireThat(typeof r.bootId==='string' && /^[a-f0-9]{32}$/.test(r.bootId) && Number.isSafeInteger(r.pid) && r.pid>0);
    if(['RECEIVED','NULL','ERROR'].includes(r.kind)) requireThat(typeof r.source==='string' && sources.includes(r.source));
    if(r.kind==='RECEIVED') requireThat(typeof r.nonceHash==='string' && /^[a-f0-9]{64}$/.test(r.nonceHash) && ['calendar','voice'].includes(r.target));
    if(r.kind==='ERROR') requireThat(['timeout','plugin','stream'].includes(r.reason));
    return r;
  });
}
const samePath=(a,b)=>process.platform==='win32'?path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase():a===b;
export function prepareRead(file){
  const originalParent=path.dirname(path.resolve(file));
  const parent=fs.realpathSync(originalParent);
  const p=fs.statSync(parent); const s=fs.lstatSync(file);
  requireThat(s.isFile() && !s.isSymbolicLink() && s.size<=MAX_BYTES);
  return {file:path.resolve(file),originalParent,parent,parentDev:p.dev,parentIno:p.ino,dev:s.dev,ino:s.ino};
}
export function read(file, prepared=prepareRead(file)){
  requireThat(path.resolve(file)===prepared.file);
  const validateParent=()=>{requireThat(samePath(fs.realpathSync(prepared.originalParent),prepared.parent)); const p=fs.statSync(prepared.parent); requireThat(p.dev===prepared.parentDev && p.ino===prepared.parentIno);};
  validateParent(); const before=fs.lstatSync(file);
  requireThat(before.isFile() && !before.isSymbolicLink() && before.dev===prepared.dev && before.ino===prepared.ino && before.size<=MAX_BYTES);
  // Windows lacks O_NOFOLLOW: lstat/FD identity and canonical parent checks are mandatory, never a zero-flag security assumption.
  requireThat(process.platform==='win32' || Number.isInteger(fs.constants.O_NOFOLLOW));
  const fd=fs.openSync(file,fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try { const s=fs.fstatSync(fd); const after=fs.lstatSync(file); validateParent();
    requireThat(s.isFile() && s.size<=MAX_BYTES && s.dev===before.dev && s.ino===before.ino && !after.isSymbolicLink() && after.dev===s.dev && after.ino===s.ino);
    const b=Buffer.alloc(s.size+1); const n=fs.readSync(fd,b,0,b.length,0); requireThat(n===s.size);
    validateParent(); const final=fs.lstatSync(file); requireThat(!final.isSymbolicLink() && final.dev===s.dev && final.ino===s.ino && fs.fstatSync(fd).size<=MAX_BYTES);
    return parse(new TextDecoder('utf-8',{fatal:true}).decode(b.subarray(0,n)));
  } finally{fs.closeSync(fd);}
}
export function listing(text,bundle,status=0){
  requireThat(status===0 && typeof text==='string' && Buffer.byteLength(text)<=MAX_BYTES && text.endsWith('\n') && /^[a-zA-Z0-9.-]+$/.test(bundle));
  const lines=text.slice(0,-1).split('\n'); requireThat(/^PID\s+Status\s+Label$/.test(lines[0]) && lines.length>=3);
  const processes=lines.slice(1).map(line=>{const m=/^(-|[1-9][0-9]*)\s+(-?[0-9]+)\s+(\S+)$/.exec(line);requireThat(m); return {pid:m[1]==='-'?null:Number(m[1]),label:m[3]};});
  requireThat(processes.filter(r=>/^(com\.apple\.|UIKitApplication:)/.test(r.label)).length>=2);
  for(const r of processes.filter(r=>r.label.startsWith('UIKitApplication:'+bundle+'['))) requireThat(/^UIKitApplication:[a-zA-Z0-9.-]+\[[^\]\s]+\]$/.test(r.label));
  const own=processes.filter(r=>r.label.startsWith('UIKitApplication:'+bundle+'[') && /^UIKitApplication:[a-zA-Z0-9.-]+\[[^\]\s]+\]$/.test(r.label));
  requireThat(own.length<=1); return own.length?own[0].pid:null;
}
const fingerprint = rows=>mask(JSON.stringify(rows));
export function boundary(rows){return {count:rows.length,digest:fingerprint(rows),boots:rows.filter(r=>r.kind==='BOOT').map(r=>({bootId:r.bootId,pid:r.pid}))};}
export function verify(rows,b,plugin,nonce,phase,cold,observedPid){
  requireThat(['cold','warm'].includes(phase));
  requireThat(['applinks','homewidget'].includes(plugin) && /^[a-z0-9_]{1,96}$/.test(nonce));
  requireThat(Number.isInteger(b.count) && b.count>=0 && rows.length>=b.count && fingerprint(rows.slice(0,b.count))===b.digest && Array.isArray(b.boots));
  let boot; let ready=false;
  const after=rows.slice(b.count);
  for(const r of after){
    if(r.kind==='BOOT'){
      requireThat(!boot && !b.boots.some(x=>x.bootId===r.bootId || x.pid===r.pid)); boot=r;
    } else {requireThat(boot && r.bootId===boot.bootId && r.pid===boot.pid); if(r.kind==='READY')ready=true; if(r.kind==='RECEIVED')requireThat(ready);}
  }
  requireThat(boot && ready);
  if(observedPid!==undefined) requireThat(Number.isSafeInteger(observedPid) && observedPid>0 && boot.pid===observedPid);
  if(phase==='warm') requireThat(cold && boot.bootId===cold.bootId && boot.pid===cold.pid);
  const src=plugin+'_'+(phase==='cold'?'initial':'warm');
  requireThat(!after.some(r=>r.kind==='ERROR' && (r.source===src || (phase==='warm' && r.source===plugin+'_initial'))));
  if(phase==='warm') requireThat(after.some(r=>r.kind==='RECEIVED' && r.source===plugin+'_initial' && r.nonceHash===cold.nonceHash && r.target==='calendar'));
  for(const r of after.filter(r=>r.kind==='RECEIVED' && r.source===src && r.nonceHash===mask(nonce))) requireThat(r.target===(phase==='cold'?'calendar':'voice'));
  if(phase==='warm') for(const r of after.filter(r=>r.kind==='RECEIVED' && r.source===plugin+'_initial' && r.nonceHash===cold.nonceHash)) requireThat(r.target==='calendar');
  const found=after.filter(r=>r.kind==='RECEIVED' && r.source===src && r.nonceHash===mask(nonce) && r.target===(phase==='cold'?'calendar':'voice'));
  requireThat(found.length===1);
  if(phase==='warm') requireThat(after.indexOf(found[0])>after.findIndex(r=>r.kind==='RECEIVED' && r.source===plugin+'_initial' && r.nonceHash===cold.nonceHash));
  return found[0];
}
export function containerPath(container,udid){
  requireThat(/^[a-f0-9-]{36}$/i.test(udid));
  const real=fs.realpathSync(container);
  requireThat(real.includes('/CoreSimulator/Devices/'+udid+'/data/Containers/Data/Application/'));
  const tmp=fs.realpathSync(path.join(real,'tmp'));
  requireThat(tmp===path.join(real,'tmp'));
  const file=path.join(tmp,'widget-transport-receipts.jsonl');
  if(fs.existsSync(file)) requireThat(fs.realpathSync(file)===file);
  return file;
}
function readListing(file){const s=fs.lstatSync(file); requireThat(s.isFile() && !s.isSymbolicLink() && s.size<=MAX_BYTES); return fs.readFileSync(file,'utf8');}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{
    const [cmd,...a]=process.argv.slice(2);
    if(cmd==='nonce')console.log('n_'+Date.now().toString(36)+'_'+randomBytes(16).toString('hex'));
    else if(cmd==='container')console.log(containerPath(a[0],a[1]));
    else if(cmd==='snapshot'){fs.writeFileSync(a[1],JSON.stringify(read(a[0])));}
    else if(cmd==='boundary'){const rows=fs.existsSync(a[0])?read(a[0]):[]; fs.writeFileSync(a[1],JSON.stringify(boundary(rows)));}
    else if(cmd==='verify'){const [file,bfile,plugin,nonce,phase,out,coldfile,observedFile,bundle,udid,container]=a; requireThat(containerPath(container,udid)===file); const observedPid=listing(readListing(observedFile),bundle); const receipt=verify(read(file),JSON.parse(fs.readFileSync(bfile,'utf8')),plugin,nonce,phase,coldfile?JSON.parse(fs.readFileSync(coldfile,'utf8')):null,observedPid); fs.writeFileSync(out,JSON.stringify(receipt));}
    else if(cmd==='absent'){
      const [file,bundle]=a; requireThat(listing(readListing(file),bundle)===null);
    }else throw Error('invalid_command');
  }catch{console.error('BLOCKED_TRANSPORT_RECEIPTS');process.exitCode=1;}
}
