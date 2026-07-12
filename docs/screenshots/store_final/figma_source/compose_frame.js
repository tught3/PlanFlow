const fs=require('fs');const path=require('path');
const FF="Pretendard,'Apple SD Gothic Neo','Malgun Gothic','Noto Sans KR',sans-serif";
const C={navyA:'#14294A',navyB:'#0F2440',light:'#EEF5FB',active:'#1A4FD6',brand:'#1E3A5F',
  wNavyHl:'#ffffff',wNavySc:'#c6d8f0',wNavyFoot:'#8fb0d8',wLightHl:'#12263f',wLightSc:'#40566f',wLightFoot:'#5b7690'};
const frames=[
 {n:1,g:'navy',hl:['말하면,','일정이 됩니다'],sc:["'내일 오후 3시 강남역에서 팀 미팅'","처럼 말하면 AI가 일정으로 정리해요"],badge:'음성 입력'},
 {n:2,g:'navy',hl:['나갈 시간까지','알려줘요'],sc:['장소가 있는 일정은 이동시간을 반영해','출발 알림을 제안해요'],badge:'출발 알림'},
 {n:3,g:'navy',hl:['편하게 대화하듯','말하세요'],sc:['조회부터 수정, 삭제까지','AI가 알아서 해줘요'],badge:'AI 일정 대화'},
 {n:4,g:'light',hl:['네이버·구글,','한 번에 연동'],sc:['쓰던 캘린더를 연결하면','자동으로 동기화돼요'],badge:'캘린더 연동'},
 {n:5,g:'light',hl:['홈 화면 위젯으로','한눈에'],sc:['달력 위젯과 마이크 위젯을','홈 화면에 바로 놓아요'],badge:'홈 위젯'},
 {n:6,g:'light',hl:['아침엔 오늘,','저녁엔 내일'],sc:['시간을 정하면 모닝·이브닝','브리핑을 알려드려요'],badge:'브리핑'},
 {n:7,g:'light',hl:['가족·팀과','함께'],sc:['초대·역할·댓글로','일정을 같이 관리해요'],badge:'그룹 일정'},
 {n:8,g:'navy',hl:['말로 시작하는','AI 캘린더'],sc:['적지 말고, 말하세요','— PlanFlow'],badge:'PlanFlow'}
];
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
const TOP_OFFSET=160;
function geom(f,W,H){
  const hlLines=f.hl.length;
  let scY=TOP_OFFSET+hlLines*104+26;
  const badgeY=scY+f.sc.length*50+40;
  const slotY=badgeY+120, slotH=H-slotY-120, slotX=180, slotW=W-slotX*2;
  return {scY,badgeY,slotX,slotY,slotW,slotH};
}
function bgSvg(f,W,H){
  const navy=f.g==='navy';
  const hlC=navy?C.wNavyHl:C.wLightHl,scC=navy?C.wNavySc:C.wLightSc,ftC=navy?C.wNavyFoot:C.wLightFoot;
  let bg=navy?`<defs><linearGradient id="bg${f.n}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${C.navyA}"/><stop offset="1" stop-color="${C.navyB}"/></linearGradient></defs><rect width="${W}" height="${H}" fill="url(#bg${f.n})"/>`:`<rect width="${W}" height="${H}" fill="${C.light}"/>`;
  let hl='';f.hl.forEach((l,i)=>{hl+=`<text x="84" y="${TOP_OFFSET+i*104}" font-family="${FF}" font-size="88" font-weight="800" fill="${hlC}" letter-spacing="-1">${esc(l)}</text>`;});
  const g=geom(f,W,H);
  let sc='';f.sc.forEach((l,i)=>{sc+=`<text x="86" y="${g.scY+i*50}" font-family="${FF}" font-size="38" fill="${scC}">${esc(l)}</text>`;});
  const bw=Math.max(150,f.badge.length*34+70);
  const badge=`<rect x="84" y="${g.badgeY}" width="${bw}" height="66" rx="33" fill="${navy?C.active:C.brand}"/><text x="${84+bw/2}" y="${g.badgeY+44}" font-family="${FF}" font-size="32" font-weight="700" fill="#fff" text-anchor="middle">${esc(f.badge)}</text>`;
  const foot=`<text x="84" y="${H-62}" font-family="${FF}" font-size="30" font-weight="700" fill="${ftC}">${f.n} / 8</text><text x="${W-84}" y="${H-62}" font-family="${FF}" font-size="30" font-weight="700" fill="${ftC}" text-anchor="end">PlanFlow</text>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${bg}${hl}${sc}${badge}${foot}</svg>`;
}
const n=parseInt(process.argv[2],10);
const capturePath=process.argv[3];
const OUT=process.argv[4]||'.';
const f=frames.find(x=>x.n===n);
if(!f){console.error('frame not found');process.exit(1);}
const W=1080,H=1920;
const g=geom(f,W,H);
const bg=bgSvg(f,W,H);
const bgB64=Buffer.from(bg).toString('base64');
const capB64=fs.readFileSync(capturePath).toString('base64');
const html=`<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;width:${W}px;height:${H}px;overflow:hidden;position:relative;font-family:${FF}}
.bg{position:absolute;left:0;top:0;width:${W}px;height:${H}px;}
.slot{position:absolute;left:${g.slotX}px;top:${g.slotY}px;width:${g.slotW}px;height:${g.slotH}px;border-radius:46px;overflow:hidden;box-shadow:0 18px 40px rgba(0,0,0,0.28);}
.slot img{width:100%;height:100%;object-fit:cover;object-position:top center;display:block;}
</style></head><body>
<img class="bg" src="data:image/svg+xml;base64,${bgB64}"/>
<div class="slot"><img src="data:image/png;base64,${capB64}"/></div>
</body></html>`;
fs.writeFileSync(path.join(OUT,`composite_${n}.html`),html,'utf8');
console.log('written composite_'+n+'.html geom='+JSON.stringify(g));
