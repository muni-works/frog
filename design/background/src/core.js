// ---------- frog face (round-3 mark, FrogFace.swift:83-134) ----------
const WEIGHT={
  dart:{skin:"--color-model-dart",spot:"--model-dart-spot",body:"rotate(-6 512 802) translate(512 802) scale(.86 1.04) translate(-512 -802)",mouth:"o"},
  tree:{skin:"--color-model-tree",spot:"--model-tree-spot",body:"",mouth:"smile"},
  gray:{skin:"--color-faint",spot:"--color-line-strong",body:"",mouth:"smile"},
  bull:{skin:"--color-model-bull",spot:"--model-bull-spot",body:"translate(512 802) scale(1.12 .9) translate(-512 -802)",mouth:"smirk"}};
const HEAD='<path d="M216 568 A296 224 0 0 1 808 568 A296 234 0 0 1 216 568 Z"/><circle cx="360" cy="352" r="120"/><circle cx="664" cy="352" r="120"/>';
const SPOTS=[[290,469,18],[262,523,11],[742,463,16],[772,510,10],[323,541,30],[701,541,30]];
let uid=0;
function mouth(kind,sad){
  const s='stroke="var(--mark-ink)" stroke-width="30" stroke-linecap="round" fill="none"';
  if(kind==="o"&&!sad) return '<ellipse cx="512" cy="592" rx="30" ry="36" fill="var(--mark-ink)"/>';
  if(kind==="smirk"&&!sad) return `<path d="M430 590 L586 590 Q606 588 616 562" ${s}/>`;
  return `<path d="M420 572 Q512 636 604 572" ${s}${sad?' transform="matrix(1 0 0 -1 0 1194)"':''}/>`;
}
function face(w,size,mood,extra=""){
  const m=WEIGHT[w],id="h"+(uid++);
  const eyes=[360,664].map(x=>`<g class="pupil"><circle cx="${x}" cy="344" r="68" fill="var(--mark-ink)"/><circle cx="${x+22}" cy="322" r="22" fill="var(--mark-paper)"/><circle cx="${x-24}" cy="368" r="9" fill="var(--mark-paper)"/></g>`).join("");
  return `<svg class="ff ${mood} ${extra}" width="${size}" height="${size}" viewBox="160 200 704 704" overflow="visible" role="img" aria-label="frog, ${mood}" style="display:block">`+
   `<defs><clipPath id="${id}">${HEAD}</clipPath></defs><g transform="${m.body}"><g class="frog">`+
   `<g fill="var(${m.skin})">${HEAD}</g>`+
   `<g fill="var(${m.spot})" clip-path="url(#${id})">${SPOTS.map(([x,y,r])=>`<circle cx="${x}" cy="${y}" r="${r}"/>`).join("")}</g>`+
   `${eyes}${mouth(m.mouth,mood==="sad")}</g></g></svg>`;
}

// ---------- glyphs (16pt, one per state and kind) ----------
const sv=(b,cls="")=>`<svg viewBox="0 0 16 16" width="100%" height="100%" fill="none" stroke-linecap="round" stroke-linejoin="round" class="${cls}">${b}</svg>`;
const C={a:"var(--color-accent)",w:"var(--color-warning)",x:"var(--color-danger)",m:"var(--color-muted)",f:"var(--color-faint)",s:"var(--color-success)",l:"var(--color-line-strong)"};
const GLYPH={
  // states
  spin:()=>sv(`<circle cx="8" cy="8" r="5.5" stroke="${C.l}" stroke-width="2"/><path d="M8 2.5a5.5 5.5 0 0 1 5.5 5.5" stroke="${C.a}" stroke-width="2"/>`,"spin"),
  run:()=>GLYPH.spin(),
  idle:()=>sv(`<circle cx="8" cy="8" r="4.5" stroke="${C.f}" stroke-width="1.5"/>`),
  queue:()=>sv(`<circle cx="8" cy="8" r="5" stroke="${C.f}" stroke-width="1.5" stroke-dasharray="2 2.2"/>`),
  hand:()=>sv(`<circle cx="8" cy="8" r="6.2" stroke="${C.w}" stroke-width="1.2" opacity=".45" class="pulse"/><circle cx="8" cy="8" r="3.6" fill="${C.w}"/>`),
  wait:()=>GLYPH.hand(),
  flat:()=>sv(`<path d="M1 8.5h3l1.4-4 2 8 1.4-4H15" stroke="${C.x}" stroke-width="1.5"/><circle cx="15" cy="8.5" r=".1" stroke="${C.x}" stroke-width="2"/>`),
  dead:()=>GLYPH.flat(),
  orph:()=>sv(`<circle cx="8" cy="8" r="5.5" stroke="${C.x}" stroke-width="1.4" stroke-dasharray="2.4 2"/><circle cx="8" cy="8" r="2" fill="${C.x}"/>`),
  done:()=>sv(`<path d="M3.5 8.4l3 3 6-6.6" stroke="${C.s}" stroke-width="1.8"/>`),
  fail:()=>sv(`<path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="${C.x}" stroke-width="1.8"/>`),
  stop:()=>sv(`<rect x="4.5" y="4.5" width="7" height="7" rx="1.5" fill="${C.m}"/>`),
  live:()=>sv(`<path d="M1 8.5h3l1.4-4 2 8 1.4-4H11l1-2 1 2h2" stroke="${C.m}" stroke-width="1.4"/>`),
  coin:()=>sv(`<circle cx="8" cy="8" r="5.5" stroke="${C.m}" stroke-width="1.3"/><path d="M8 5v6M9.6 6.2c-.4-.5-1-.7-1.7-.7-.9 0-1.5.5-1.5 1.1 0 1.5 3.3.9 3.3 2.5 0 .7-.7 1.2-1.7 1.2-.7 0-1.4-.3-1.8-.8" stroke="${C.m}" stroke-width="1.1"/>`),
  // kinds
  shell:()=>sv(`<rect x="1.5" y="2.5" width="13" height="11" rx="2.5" stroke="${C.m}" stroke-width="1.3"/><path d="M4.5 6l2 2-2 2M8.5 10.5h3" stroke="${C.m}" stroke-width="1.3"/>`),
  watch:()=>sv(`<circle cx="8" cy="8" r="6" stroke="${C.m}" stroke-width="1.3"/><circle cx="8" cy="8" r="2.6" stroke="${C.m}" stroke-width="1.1"/><path d="M8 8l4.2-4.2" stroke="${C.m}" stroke-width="1.3"/>`),
  timer:()=>sv(`<circle cx="8" cy="9" r="5.5" stroke="${C.m}" stroke-width="1.3"/><path d="M8 6v3l2 1.4M6.5 1.8h3" stroke="${C.m}" stroke-width="1.3"/>`),
  agent:()=>sv(`<path d="M8 1.8l1.5 4.7 4.7 1.5-4.7 1.5L8 14.2l-1.5-4.7L1.8 8l4.7-1.5z" stroke="${C.m}" stroke-width="1.2"/>`),
  pod:()=>sv(`<rect x="3.5" y="3.5" width="9" height="9" rx="1.8" stroke="${C.m}" stroke-width="1.3"/><rect x="6" y="6" width="4" height="4" rx=".6" fill="${C.m}"/><path d="M6 1.5v2M10 1.5v2M6 12.5v2M10 12.5v2M1.5 6h2M1.5 10h2M12.5 6h2M12.5 10h2" stroke="${C.m}" stroke-width="1.1"/>`),
  pr:()=>sv(`<circle cx="4.5" cy="3.8" r="1.7" stroke="${C.m}" stroke-width="1.2"/><circle cx="4.5" cy="12.2" r="1.7" stroke="${C.m}" stroke-width="1.2"/><circle cx="11.5" cy="12.2" r="1.7" stroke="${C.m}" stroke-width="1.2"/><path d="M4.5 5.5v5M11.5 10.5V6.5c0-1.2-.8-2-2-2H7.5M8.8 3.2L7.4 4.5l1.4 1.3" stroke="${C.m}" stroke-width="1.2"/>`),
  ci:()=>sv(`<circle cx="8" cy="8" r="6" stroke="${C.m}" stroke-width="1.3"/><path d="M6.6 5.3v5.4L11 8z" fill="${C.m}"/>`),
  ask:()=>sv(`<path d="M3 3.5h10a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 1-1.5 1.5H8l-3 2.5v-2.5H3A1.5 1.5 0 0 1 1.5 10V5A1.5 1.5 0 0 1 3 3.5z" stroke="${C.m}" stroke-width="1.3"/>`),
  audit:()=>sv(`<path d="M2.5 2.5h11v11h-11z" stroke="${C.m}" stroke-width="1.3"/><path d="M5 5.5h6M5 8h6M5 10.5h3.5" stroke="${C.m}" stroke-width="1.1"/>`),
  key:()=>sv(`<circle cx="5.5" cy="10.5" r="3" stroke="${C.m}" stroke-width="1.3"/><path d="M7.6 8.4L14 2M11.5 4.5l1.6 1.6" stroke="${C.m}" stroke-width="1.3"/>`),
};
const g=(name,size)=>`<span class="g"${size?` style="width:${size}px;height:${size}px"`:""}>${GLYPH[name]()}</span>`;
function paintGlyphs(root=document){root.querySelectorAll("[data-glyph]").forEach(el=>{el.innerHTML=GLYPH[el.dataset.glyph]();});}

// ---------- folder tint (SessionRows.swift:66, skipping brown hues 15-50) ----------
function tint(h,a=1){h=(h>=15&&h<=50)?h+40:h;const s=.5,v=.72,f=n=>{const k=(n+h/60)%6;return v-v*s*Math.max(0,Math.min(k,4-k,1));};
  return `rgba(${Math.round(f(5)*255)},${Math.round(f(3)*255)},${Math.round(f(1)*255)},${a})`;}

// ---------- state vocabulary ----------
const STATE={
  queue:{label:"queued",cls:"queue",glyph:"queue"},
  run:{label:"running",cls:"run",glyph:"spin"},
  wait:{label:"needs you",cls:"wait",glyph:"hand"},
  idle:{label:"idle",cls:"idle",glyph:"idle"},
  done:{label:"done",cls:"done",glyph:"done"},
  fail:{label:"failed",cls:"fail",glyph:"fail"},
  stop:{label:"stopped",cls:"stop",glyph:"stop"},
  dead:{label:"dead",cls:"dead",glyph:"flat"},
  lost:{label:"lost",cls:"dead",glyph:"flat"},
  orph:{label:"orphaned",cls:"orph",glyph:"orph"},
};
const stTag=(s,label)=>`<span class="st ${STATE[s].cls}">${g(STATE[s].glyph)}${label||STATE[s].label}</span>`;

// ---------- data ----------
const SESSIONS=[
  {id:"chief",name:"chief of staff",ini:"c",hue:150,state:"run",detail:"running · 5 live · next wake 0:12",lvl:0},
  {id:"frogm",name:"frog manager",ini:"f",hue:205,state:"idle",detail:"idle · watching 1 pr",lvl:1},
  {id:"bgux",name:"background-work-ux",ini:"b",hue:205,state:"run",detail:"running 18m · $0.42 of $5",lvl:2},
  {id:"cloudm",name:"frog cloud manager",ini:"f",hue:265,state:"wait",detail:"needs you 14m · push to zest",lvl:1},
  {id:"tangm",name:"tang manager",ini:"t",hue:330,state:"dead",detail:"stopped 12m · pod billing $10.58/hr",lvl:1},
  {id:"zest",name:"zest",ini:"z",hue:95,state:"run",detail:"running 3h · frog-cloud-10",lvl:1},
  {id:"vcadm",name:"vcad manager",ini:"v",hue:290,state:"idle",detail:"idle 2h · nothing live",lvl:1},
];
const OWN={chief:"chief of staff",frogm:"frog manager",cloudm:"frog cloud manager",tangm:"tang manager",zest:"zest"};
// kind: shell | watch | timer | agent | session | pod | pr | ci | approval
const JOBS=[
  {id:"j31",owner:"chief",kind:"shell",name:"frog merge queue",cmd:"bin/merge-queue.sh frog 74 76",state:"run",wf:"exit · step 2 of 3 (#76)",el:"4m 12s",frac:.14,cost:"—",cap:"30m",next:"on exit",
   tail:"#74 rebased on main · ci green · merged 6f2a1c0\n#76 rebased on main\nwaiting for ci (4 of 7 checks)…",
   tl:[["14:29","a","started by <b>chief</b> as a frog job"],["14:31","a","#74 merged"],["now","o","wakes chief when it exits"]]},
  {id:"m7",owner:"chief",kind:"watch",name:"frog cloud health",cmd:"curl -s https://api.frog.toys/status | grep -q \"Serving now\"",state:"run",wf:"“Serving now” · every 30s",el:"22m 04s",frac:.18,ticks:44,cost:"—",cap:"2h",next:"0:12",
   tail:"14:33:08  exit 1  (pod booting · 503)\n14:32:38  exit 1\n14:32:08  exit 1",
   tl:[["14:11","a","started · every 30s until a match, 2h cap"],["14:23","w","app restarted · watch kept its schedule"],["now","o","check 45 in 0:12 · wakes chief on match"]]},
  {id:"m8",owner:"chief",kind:"timer",name:"check tang bench",cmd:"timer · due 14:40:00 (wall clock)",state:"run",wf:"14:40 · wall clock",el:"11m of 20m",frac:.55,cost:"—",cap:"—",next:"9m",
   tail:"set at 14:20:00 for 20m\ndue 14:40:00 · survives restarts\nnever fires before due",
   tl:[["14:20","a","set for 20m"],["14:40","o","wakes chief"]]},
  {id:"t2",owner:"chief",kind:"agent",name:"survey frog background code",cmd:"Task · read-only · sonnet",state:"run",wf:"its report",el:"1m 40s",frac:.1,cost:"$0.04",cap:"$1",next:"on report",
   tail:"read background.rs (412 lines)\nread engine.rs:2210-2380\nreading protocol.rs…",
   tl:[["14:31","a","started by chief, in the background"],["now","o","report comes back as a task-done wake"]]},
  {id:"s3",owner:"frogm",kind:"session",name:"background-work-ux",cmd:"worker · glm-5.3 · worktree frog/background-work-ux",state:"run",wf:"its report",el:"18m",frac:.08,cost:"$0.42",cap:"$5",next:"on idle",face:"tree",
   tail:"wrote design/background/spec.md\nscreenshotting index.html (dark)…",
   tl:[["14:15","a","started by <b>frog manager</b>"],["now","o","reports to frog manager when idle"]]},
  {id:"r81",owner:"frogm",kind:"pr",name:"ecto/frog#81 · job ledger",cmd:"gh pr checks 81 -R ecto/frog",state:"run",wf:"ci · 3 of 5 checks",el:"12m",frac:.4,ticks:12,cost:"—",cap:"1h",next:"0:40",
   tail:"build-macos   pass  6m\ntest-engine   pass  4m\nlint          pass  1m\nui-tests      running\nrelease-dry   queued",
   tl:[["14:21","a","pushed · frog manager tracks it"],["now","o","asks you to merge when green"]]},
  {id:"a9",owner:"cloudm",kind:"approval",name:"push branch to zest",cmd:"git push https://github.com/ecto/zest.git HEAD:cancel-safe",state:"wait",wf:"you · Allow once or Deny",el:"14m",frac:1,cost:"—",cap:"—",next:"—",
   tail:"frog cloud manager is paused on this.\nit touches: ecto/zest, a new branch only.",
   tl:[["14:19","w","asked you"],["now","o","manager stays paused until you answer"]]},
  {id:"p2",owner:"cloudm",kind:"pod",name:"frog-cloud-10",cmd:"runpod · 1× h200 · serves api.frog.toys",state:"run",wf:"stays up · approved always-on",el:"2d 4h",frac:0,cost:"$5.29/hr",costb:"$41.30 today",cap:"standing",next:"0:22",
   tail:"probe ok · 18 sessions · 74 tok/s\nqueue depth 0",
   tl:[["oct 21","a","started · Cam approved always-on at $5.29/hr"],["now","o","probed every 60s"]]},
  {id:"p1",owner:"tangm",kind:"pod",name:"tang-h200-bench",cmd:"runpod · 1× h200 sxm · bench coder-next 128k",state:"orph",wf:"bench run 3 of 5 · held by chief",el:"2h 13m of 4h",frac:.554,cost:"$10.58/hr",costb:"$23.40 of $50",cap:"$50",next:"0:40",costfrac:.468,
   tail:"probe ok · gpu 92% · 61 tok/s\nowner engine gone since 14:21",
   tl:[["12:08","a","started by <b>tang manager</b> · $50, 4h cap"],["14:21","x","tang manager stopped"],["14:22","w","moved up to chief · you got one alert"],["now","o","stops itself at $50 or 16:08"]]},
  {id:"j4",owner:"tangm",kind:"shell",name:"bench loop",cmd:"bench/loop.sh --runs 5",state:"lost",wf:"lost with its engine at 14:21",el:"1h 52m",frac:0,cost:"—",cap:"—",next:"—",
   tail:"[run 3/5] prefill 128k … 61.2 tok/s\n(no output after 14:21:02)\nexit code: never written",
   tl:[["12:29","a","started"],["14:21","x","engine died · the process went with it"],["now","o","output kept · rerun from the activity view"]]},
  {id:"j2",owner:"zest",kind:"shell",name:"gateway logs",cmd:"wrangler tail frog-gateway --format pretty",state:"run",wf:"nothing · a stream",el:"3h 02m",frac:0,cost:"—",cap:"8h",next:"stream",
   tail:"POST /v1/chat/completions 200 812ms\nPOST /v1/chat/completions 200 1.4s"},
  {id:"m3",owner:"zest",kind:"watch",name:"frog-cloud-10 queue depth",cmd:"curl -s localhost:9100/metrics | grep queue_depth",state:"run",wf:"depth over 8 · every 60s",el:"3h",frac:.37,ticks:180,cost:"—",cap:"8h",next:"0:31"},
  // ended today
  {id:"j29",owner:"chief",kind:"shell",name:"engine tests",cmd:"cargo test -p frog-engine",state:"done",wf:"exit 0 · 412 passed",el:"3m 12s",frac:1,cost:"—",cap:"—",next:"14:26",ended:true},
  {id:"j27",owner:"frogm",kind:"shell",name:"macos build",cmd:"xcodebuild -scheme Frog build",state:"fail",wf:"exit 65 · signing",el:"2m 40s",frac:1,cost:"—",cap:"—",next:"13:58",ended:true},
  {id:"t1",owner:"chief",kind:"agent",name:"audit open approvals",cmd:"Task · read-only",state:"done",wf:"report read",el:"2m",frac:1,cost:"$0.06",cap:"$1",next:"13:40",ended:true},
];
const HEADS={
  chief:{chain:"",os:stTag("run","running")},
  frogm:{chain:"under chief",os:stTag("idle","idle · engine ok")},
  cloudm:{chain:"under chief",os:stTag("wait","needs you · 14m")},
  tangm:{chain:"under chief · its work is held by chief",os:stTag("dead","engine stopped 12m")},
  zest:{chain:"under chief",os:stTag("run","running")},
};

// ---------- rail: elapsed against the cap, one tick per check, hollow mark for the next ----------
function rail(j){
  const W=100,f=Math.max(0,Math.min(1,j.frac||0));
  const tone=j.state==="orph"||j.state==="lost"||j.state==="fail"?C.x:j.state==="wait"?C.w:(j.state==="done"?C.s:C.a);
  let s=`<rect x="0" y="3" width="${W}" height="2" rx="1" fill="var(--color-line-strong)"/>`;
  if(j.kind==="shell"&&j.cap==="—"&&!j.ended&&j.state!=="lost") return `<svg class="rail" viewBox="0 0 ${W} 8" preserveAspectRatio="none">${s}<rect x="0" y="3" width="${W}" height="2" rx="1" fill="${C.a}" opacity=".35"/></svg>`;
  if(f>0) s+=`<rect x="0" y="2.5" width="${W*f}" height="3" rx="1.5" fill="${tone}"/>`;
  if(j.ticks){const n=Math.min(j.ticks,24);for(let i=1;i<=n;i++){const x=(W*f)*i/n;s+=`<rect x="${x-.35}" y="1" width=".7" height="6" fill="var(--color-bg)" opacity=".9"/>`;}}
  if(!j.ended&&j.state!=="lost"&&j.state!=="wait"&&j.cap!=="standing") s+=`<rect x="${Math.min(W-2,W*f+3)}" y="1" width="1.4" height="6" rx=".7" fill="none" stroke="${C.f}" stroke-width=".6" vector-effect="non-scaling-stroke"/>`;
  return `<svg class="rail" viewBox="0 0 ${W} 8" preserveAspectRatio="none">${s}</svg>`;
}

// ---------- sidebar ----------
function renderTree(sel){
  document.getElementById("tree").innerHTML=SESSIONS.map(s=>{
    const d=s.state==="wait"?"w":s.state==="dead"?"x":"";
    const lg=s.state==="idle"?"":`<span class="lg">${GLYPH[STATE[s.state].glyph]()}</span>`;
    return `<div class="srow c${s.lvl}${sel===s.id?" sel":""}" data-sess="${s.id}">
      <span class="av" style="background:${tint(s.hue,.18)};color:${tint(s.hue)}">${s.ini}${lg}</span>
      <span class="t${s.state==="idle"?" dim":""}">${s.name}</span><span></span>
      <span class="d ${d}">${s.detail}</span></div>`;}).join("");
}

// ---------- activity ----------
let FILTER="live",SEL="p1";
function visible(j){
  if(FILTER==="live") return !j.ended;
  if(FILTER==="you") return j.state==="wait"||j.state==="orph"||j.state==="lost";
  if(FILTER==="ended") return j.ended;
  return true;
}
function renderJobs(){
  const groups=Object.keys(OWN);let h="";
  for(const o of groups){
    const js=JOBS.filter(j=>j.owner===o&&visible(j));if(!js.length) continue;
    const s=SESSIONS.find(x=>x.id===o);
    h+=`<div class="owner"><span class="av" style="background:${tint(s.hue,.18)};color:${tint(s.hue)};width:18px;height:18px;font-size:10px">${s.ini}</span>${OWN[o]}<span class="chain">${HEADS[o].chain}</span><span class="os">${HEADS[o].os}</span></div>`;
    for(const j of js){
      const lead=j.kind==="session"?`<span class="g">${face(j.face||"tree",16,"working")}</span>`:g(j.kind==="approval"?"key":j.kind);
      const lab=j.state==="wait"?"needs you":j.state==="orph"?"orphaned":j.state==="lost"?"lost":null;
      h+=`<div class="jrow ${j.ended?"ended":""} ${j.state==="orph"?"orph":""} ${j.state==="lost"?"dead":""} ${SEL===j.id?"sel":""}" data-job="${j.id}">
        ${lead}
        <span class="nm"><b>${j.name}<span class="idb">${j.id}</span></b><small>${j.cmd}</small></span>
        <span>${stTag(j.state==="lost"?"lost":j.state,lab)}</span>
        <span class="wf" title="${j.wf}">${j.wf}</span>
        <span class="el"><span>${j.el}</span>${rail(j)}</span>
        <span class="cost r">${j.costb?`<b>${j.cost}</b>${j.costb}`:`<b>${j.cost}</b>${j.cap!=="—"?"cap "+j.cap:""}`}</span>
        <span class="nx r">${j.next}</span></div>`;
    }
  }
  document.getElementById("jobs").innerHTML=h||`<div style="padding:30px 28px;color:var(--color-muted)">nothing here. frog will show it the moment something starts.</div>`;
}
function renderInsp(){
  const j=JOBS.find(x=>x.id===SEL);if(!j) return;
  const lead=j.kind==="session"?`<span class="g" style="width:20px;height:20px">${face("tree",20,"working")}</span>`:g(j.kind==="approval"?"key":j.kind,18);
  const kinds={shell:"command",watch:"watch",timer:"timer",agent:"subagent",session:"child session",pod:"gpu pod",pr:"pull request",approval:"approval"};
  const pod=j.kind==="pod"&&j.costfrac;
  const live=!j.ended&&j.state!=="lost";
  document.getElementById("insp").innerHTML=`
    <div><h3>${lead}${j.name}</h3><div style="margin-top:6px;display:flex;gap:8px;align-items:center">${stTag(j.state==="lost"?"lost":j.state,j.state==="wait"?"needs you":null)}<span class="chip">${j.id}</span><span class="chip">${kinds[j.kind]}</span></div></div>
    <div class="cmd">${j.cmd}</div>
    <dl class="kv">
      <dt>owner</dt><dd>${OWN[j.owner]}${j.owner==="tangm"?' <span style="color:var(--color-danger)">· dead</span>, held by chief':""}</dd>
      <dt>waiting for</dt><dd>${j.wf}</dd>
      <dt>elapsed</dt><dd class="m">${j.el}</dd>
      <dt>cost</dt><dd class="m">${j.cost}${j.costb?" · "+j.costb:""}</dd>
      <dt>cap</dt><dd class="m">${j.cap}</dd>
      <dt>next</dt><dd class="m">${j.next}</dd>
    </dl>
    ${pod?`<div class="meter"><div class="ln"><span>cost</span><span>$23.40 / $50</span></div><div class="track"><i style="width:${j.costfrac*100}%"></i><u style="left:80%"></u></div>
      <div class="ln" style="margin-top:4px"><span>time</span><span>2h 13m / 4h</span></div><div class="track"><i style="width:${j.frac*100}%"></i><u style="left:80%"></u></div></div>`:""}
    ${j.tl?`<div class="sec">HISTORY</div><div class="tl">${j.tl.map(([t,c,s])=>`<div><time>${t}</time><i class="${c}"></i><span>${s}</span></div>`).join("")}</div>`:""}
    ${j.tail?`<div class="sec">LAST OUTPUT</div><pre class="tail">${j.tail}</pre>`:""}
    <div class="acts">${
      j.kind==="approval"?`<button class="btn p" data-go="inbox">Answer</button>`:
      j.state==="lost"?`<button class="btn p" data-toast="j4 started again as j32 · same command, same owner">Run again</button><button class="btn q">Full log</button>`:
      !live?`<button class="btn q">Full log</button>`:
      `${j.kind==="pod"?`<button class="btn" data-toast="cap raised to 5h · stops at 17:08">Extend 1h</button>`:`<button class="btn" data-toast="${j.id} cap extended 30m">Extend</button>`}
       ${j.kind==="watch"||j.kind==="timer"?`<button class="btn" data-toast="${j.id} paused · it keeps its place">Pause</button>`:""}
       <button class="btn q">Full log</button><span class="spacer"></span>
       <button class="btn x" data-stop="${j.id}">${j.kind==="pod"?"Stop pod":"Stop"}</button>`}
    </div>`;
  paintGlyphs(document.getElementById("insp"));
}
