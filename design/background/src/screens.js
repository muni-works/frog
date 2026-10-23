// ---------- inbox: one place for everything blocked on Cam ----------
const CARDS=[
  {id:"c-bench",band:"COSTING MONEY",tone:"x",who:"tang manager",sub:"dead 12m · held by chief",ago:"12m",glyph:"orph",
   what:"tang-h200-bench has no living owner",
   why:[["cause","tang manager's engine stopped at 14:21 (out of memory)"],["costs","<b>$10.58/hr</b> · $23.40 of its $50 cap · $2.12 since it died"],["also","j4 bench loop was lost · its 1 open approval is kept"],["advice","<b>restart the manager</b>: it takes the pod back and resumes run 3 of 5"]],
   acts:[["Restart manager","p","restarted · tang manager took the pod back"],["Stop pod","x","tang-h200-bench stopped · volume kept · $0/hr"],["Run to cap","","left running · stops itself at $50"]],sc:"⌘⏎"},
  {id:"c-push",band:"BLOCKING WORK",tone:"w",who:"frog cloud manager",sub:"paused on this",ago:"14m",glyph:"key",
   what:"wants to run <code>git push https://github.com/ecto/zest.git HEAD:cancel-safe</code>",
   why:[["why","ship the cancel-safe image branch for review"],["touches","ecto/zest · a new branch, not main"],["blocks","<b>frog cloud manager</b> and its next step (open the pr)"],["rule","pushes of branches are routine. Always would cover this kind."]],
   acts:[["Allow once","p","allowed once · frog cloud manager resumed"],["Always for branches","","always allowed: push to non-main branches of ecto/zest"],["Deny with note…","q","note"],["Deny","","denied · the manager was told why"]],sc:"⌘⏎"},
  {id:"c-xc",band:"BLOCKING WORK",tone:"w",who:"frog-ui worker",sub:"under frog manager",ago:"6m",glyph:"key",
   what:"wants to run outside the sandbox: <code>xcodebuild -scheme Frog build</code>",
   why:[["why","the sandbox blocks DerivedData in ~/Library"],["touches","~/Library/Developer/Xcode/DerivedData"],["blocks","1 worker · its manager is idle waiting on it"]],
   acts:[["Allow once","p","allowed once · the build is running as j33"],["Deny with note…","q","note"],["Deny","","denied · the worker will try /private/tmp"]],sc:"⌘⏎"},
  {id:"c-merge",band:"DECISIONS",tone:"i",who:"frog manager",sub:"asks",ago:"3m",glyph:"ask",
   what:"merge ecto/frog#81 (job ledger) when ci is green?",
   why:[["state","3 of 5 checks passed · ui-tests running · next check 0:40"],["note","this is the ledger the rest of this design sits on"]],
   acts:[["Merge when green","p","will merge #81 when all 5 checks pass"],["Wait for me","","held · you'll get a row when it's green"],["Close","","closed"]],sc:"⌘⏎"},
];
function renderCards(){
  let band="",h="";
  for(const c of CARDS){
    if(c.band!==band){band=c.band;const n=CARDS.filter(x=>x.band===band&&!x.answered).length;
      h+=`<div class="band">${band} <em>${n?n+" open":"all answered"}</em></div>`;}
    h+=`<div class="card ${c.tone==="x"?"x":c.tone==="i"?"i":""} ${c.answered?"answered":""} ${c.id==="c-bench"&&!c.answered?"focus":""}" data-card="${c.id}">
      <div class="body">
        <div class="hd">${g(c.glyph)}<span class="who">${c.who}</span><span class="sub">· ${c.sub}</span><span class="ago">waiting ${c.ago}</span></div>
        <div class="what">${c.what}</div>
        <dl class="why">${c.why.map(([k,v])=>`<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl>
        <div class="acts">${c.acts.map(([l,t,r],i)=>`${t==="q"?'<span class="spacer"></span>':""}<button class="btn ${t}" data-ans="${c.id}" data-i="${i}">${l}${i===0?` <kbd>${c.sc}</kbd>`:""}</button>`).join("")}</div>
        <div class="note"><input placeholder="tell ${c.who} why, so it can try another way"><button class="btn" data-ans="${c.id}" data-i="deny-note">Deny</button></div>
      </div>
      <div class="res">${g("done")}<span>${c.answered||""}</span><span class="spacer"></span><button class="btn q" data-undo="${c.id}">Undo</button></div>
    </div>`;
  }
  document.getElementById("cards").innerHTML=h;
  const open=CARDS.filter(c=>!c.answered).length;
  document.getElementById("ihSub").textContent=open?`${open} open · oldest 14m${CARDS[0].answered?"":" · $10.58/hr at stake"}`:"nothing needs you. frog will ask here first.";
  setCount(open);
  paintGlyphs(document.getElementById("cards"));
}
function setCount(n){
  document.querySelectorAll('[data-count="inbox"]').forEach(e=>{e.textContent=n;e.style.display=n?"":"none";});
  document.querySelectorAll('[data-count="inboxN"]').forEach(e=>e.textContent=n);
  const b=document.getElementById("dockBadge");if(b){b.textContent=n;b.style.display=n?"":"none";}
  const mf=document.getElementById("mbCount");if(mf) mf.textContent=n;
}

// ---------- transcript: inline rows ----------
function ir({lead,who,hl,tr,cls="",det,go}){
  return `<div class="ir ${cls}"${go?` data-go="${go}"`:""}>${lead}<span class="who">${who}</span><span class="hl">${hl}</span><span class="tr">${tr}<span class="chev">›</span></span></div>${det?`<div class="idet">${det}</div>`:""}`;
}
function renderTx(){
  const x=document.getElementById("txcol");
  x.innerHTML=`
  <div class="ubub">run the frog merge queue, and tell me when frog cloud is serving again</div>
  <p>starting the queue as a frog job, so it survives restarts and shows up in activity. i'll watch the status page instead of polling it.</p>
  ${ir({cls:"open",lead:g("shell"),who:"j31",hl:'<span class="mono">bin/merge-queue.sh frog 74 76</span> · step 2 of 3',tr:`<span class="tm">4m 12s</span>${stTag("run")}`,
    det:`<pre class="tail">#74 rebased on main · ci green · merged 6f2a1c0
#76 rebased on main
waiting for ci (4 of 7 checks)…</pre>
    <div class="acts" style="margin-top:8px"><span class="chip">cap 30m</span><span class="chip">wakes me on exit</span><span class="spacer"></span><button class="btn q" data-go="activity">In activity</button><button class="btn x" data-toast="j31 stopped · #76 left unmerged">Stop</button></div>`})}
  ${ir({lead:g("watch"),who:"m7",hl:'frog cloud health · until <span class="mono">“Serving now”</span> · every 30s',tr:`<span class="chip">44 checks</span><span class="tm">next 0:12</span>${stTag("run","watching")}`,
    det:`<dl class="kv"><dt>command</dt><dd class="m">curl -s https://api.frog.toys/status | grep -q "Serving now"</dd><dt>last</dt><dd class="m">14:33:08 · exit 1 · 503 pod booting</dd><dt>cap</dt><dd class="m">2h · then tells me it timed out</dd></dl>`})}
  <div class="foot">opus 5.5 · 38 tok/s · 6.1k in · $0.09</div>

  <div class="notice w">${g("live")}app restarted at 14:23 · 4 jobs picked up where they were · 1 lost</div>

  <div class="wake">woke on j29 · job done</div>
  ${ir({cls:"ended",lead:g("shell"),who:"j29",hl:'<span class="mono">cargo test -p frog-engine</span> · 412 passed',tr:`<span class="tm">3m 12s</span>${stTag("done","exit 0")}`})}
  <p>tests pass on main. the tang manager went quiet, so i checked on it.</p>
  ${ir({go:"dead",lead:`<span class="g">${face("gray",16,"sad")}</span>`,who:"tang manager",hl:"engine stopped 12m ago · its pod still bills $10.58/hr · i'm holding it",tr:`${stTag("dead")}`})}
  ${ir({lead:`<span class="g">${face("tree",16,"idle")}</span>`,who:"frog manager",hl:"idle · watching ecto/frog#81 · 1 worker running",tr:`${stTag("idle","idle · engine ok")}`})}
  ${ir({lead:`<span class="g">${face("tree",16,"waiting")}</span>`,go:"inbox",who:"frog cloud manager",hl:'wants to push <span class="mono">HEAD:cancel-safe</span> to zest',tr:`<span class="tm">14m</span>${stTag("wait")}`})}
  ${ir({lead:g("agent"),who:"t2",hl:"survey frog background code · read-only",tr:`<span class="chip">$0.04</span><span class="tm">1m 40s</span>${stTag("run")}`})}
  ${ir({lead:g("timer"),who:"m8",hl:"check tang bench · due 14:40 by the clock",tr:`<span class="tm">in 9m</span>${stTag("queue","set")}`})}
  ${ir({lead:g("shell"),cls:"open",who:"JobOutput j12",hl:"ended 6m ago, while the engine restarted",tr:`${stTag("done","exit 0 · kept")}`,
    det:`<div class="ba" style="margin:4px 0 6px"><div><div class="lbl old">TODAY</div><pre class="blk old">no background task, job or monitor j12</pre></div><div><div class="lbl new">WITH THE LEDGER</div><pre class="blk">j12 ended 14:27 (exit 0, 48s) while the
engine restarted. output is kept:
JobOutput j12 --tail 50</pre></div></div>`})}
  <div class="foot">opus 5.5 · 41 tok/s · 18.2k in · $0.31</div>`;
}

// ---------- dead manager legend ----------
function renderLegend(){
  const L=[
    ["idle","idle","idle","engine alive. nothing running, nothing queued, nothing asked.","heartbeat ok · 0 live · 0 cards"],
    ["hand","waiting on you","waiting","engine alive and paused on your answer.","heartbeat ok · 1 card open"],
    ["flat","dead","sad","engine gone without saying so. its jobs stay on disk.","no heartbeat for 30s · pid gone"],
    ["orph","orphaned","sad","a job still running whose owner is dead. it moves up to the parent.","owner dead · job alive"],
  ];
  document.getElementById("legend").innerHTML=L.map(([gl,t,m,p,c])=>`<div class="lg4"><div class="h">${g(gl)}${t}<span class="spacer"></span><span class="g" style="width:18px;height:18px">${face(m==="sad"?"gray":"tree",18,m)}</span></div><p>${p}</p><code>${c}</code></div>`).join("");
  document.getElementById("deadFace").innerHTML=face("gray",40,"sad");
}

// ---------- pod ----------
const POD={cost:23.40,cap:50,mins:133,capm:240,state:"orph"};
function renderPod(){
  const cf=POD.cost/POD.cap,tf=POD.mins/POD.capm;
  const tone=f=>f>=1?"x":f>=.8?"w":"";
  document.getElementById("podCost").innerHTML=`$${POD.cost.toFixed(2)}<small>of $${POD.cap} cap</small>`;
  const bar=document.getElementById("podCostBar");bar.style.width=Math.min(100,cf*100)+"%";bar.className=tone(cf);
  document.getElementById("podCostNote").textContent=`warns at $${Math.round(POD.cap*.8)} · stops at $${POD.cap}`;
  const h=Math.floor(POD.mins/60),m=POD.mins%60;
  document.getElementById("podTime").innerHTML=`${h}h ${String(m).padStart(2,"0")}m<small>of ${POD.capm/60}h cap</small>`;
  const tb=document.getElementById("podTimeBar");tb.style.width=Math.min(100,tf*100)+"%";tb.className=tone(tf);
  const end=12*60+8+POD.capm;document.getElementById("podEnds").textContent=POD.state==="stop"?"stopped 14:34":`stops itself at ${Math.floor(end/60)}:${String(end%60).padStart(2,"0")}`;
  document.getElementById("podState").innerHTML=POD.state==="stop"?stTag("stop","stopped · volume kept · $0/hr"):POD.state==="pause"?stTag("idle","paused · volume kept"):stTag("orph","orphaned · held by chief");
  // spark: flat burn with a step at the run boundaries
  const pts=[];for(let i=0;i<=60;i++){const v=i<8?3:i<14?30:i<52?30+Math.sin(i/2)*3:(POD.state==="stop"?0:31);pts.push(`${i*5},${40-v}`);}
  document.getElementById("podSpark").innerHTML=`<polyline points="${pts.join(" ")}" fill="none" stroke="var(--color-accent)" stroke-width="1.5" vector-effect="non-scaling-stroke"/><line x1="${52*5}" x2="${52*5}" y1="0" y2="40" stroke="var(--color-danger)" stroke-dasharray="2 2" vector-effect="non-scaling-stroke"/>`;
  // which cap hits first, at the current burn
  const rate=POD.state==="stop"?0:10.58,costAt=12*60+8+POD.mins+(rate?Math.round((POD.cap-POD.cost)/rate*60):9999),timeAt=12*60+8+POD.capm;
  const hm=m=>`${Math.floor(m/60)}:${String(m%60).padStart(2,"0")}`;
  const first=timeAt<=costAt?`the time cap hits first, at ${hm(timeAt)}, with about $${(POD.cost+rate*(POD.capm-POD.mins)/60).toFixed(2)} spent.`:`the cost cap hits first, at ${hm(costAt)}.`;
  document.getElementById("podFirst").textContent=POD.state==="stop"?"stopped. no cap will fire.":"at $10.58/hr, "+first;
  document.querySelectorAll("#podActs .btn").forEach(b=>b.disabled=POD.state==="stop");
  const R=JOBS.filter(j=>j.id==="p1"||j.id==="p2"||j.id==="r81");
  const b=JOBS.find(j=>j.id==="p1");b.costb=`$${POD.cost.toFixed(2)} of $${POD.cap}`;b.cap=`$${POD.cap}`;b.costfrac=cf;b.frac=tf;
  if(POD.state==="stop"){b.state="stop";b.wf="stopped by you · volume kept";b.cost="$0/hr";b.next="—";}
  const ci={id:"r82",owner:"frogm",kind:"ci",name:"ui-tests · ecto/frog#81",cmd:"gh run watch 18842211 -R ecto/frog",state:"run",wf:"job ui-tests · step 6 of 9",el:"5m",frac:.5,ticks:10,cost:"—",cap:"20m",next:"0:15"};
  document.getElementById("podRows").innerHTML=[...R,ci].map(j=>`<div class="jrow" style="margin:0 6px">${g(j.kind)}
    <span class="nm"><b>${j.name}<span class="idb">${j.id}</span></b><small>${j.cmd}</small></span>
    <span>${stTag(j.state,j.state==="orph"?"orphaned":null)}</span><span class="wf">${j.wf}</span>
    <span class="el"><span>${j.el}</span>${rail(j)}</span>
    <span class="cost r">${j.costb?`<b>${j.cost}</b>${j.costb}`:`<b>${j.cost}</b>${j.cap!=="—"?"cap "+j.cap:""}`}</span><span class="nx r">${j.next}</span></div>`).join("");
  paintGlyphs(document.querySelector('[data-screen="pod"]'));
}
