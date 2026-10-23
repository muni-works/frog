// ---------- wiring ----------
const $=s=>document.querySelector(s);
function toast(t){const e=$("#toast");e.textContent=t;e.classList.add("on");clearTimeout(e._t);e._t=setTimeout(()=>e.classList.remove("on"),4000);}
function show(s){
  document.querySelectorAll(".screen").forEach(x=>x.classList.toggle("on",x.dataset.screen===s));
  document.querySelectorAll("#tabs button").forEach(b=>b.classList.toggle("on",b.dataset.s===s));
  document.querySelectorAll(".nav a").forEach(a=>a.classList.toggle("sel",a.dataset.go===s));
  renderTree(s==="dead"?"tangm":s==="transcript"?"chief":s==="pod"?"tangm":null);
  history.replaceState(null,"","#"+s+","+(document.body.classList.contains("light")?"light":"dark"));
}
function setTheme(t){document.body.classList.remove("light","dark");document.body.classList.add(t);document.querySelectorAll("#theme button").forEach(b=>b.classList.toggle("on",b.dataset.t===t));}
function render(){renderGrants();renderAudit();renderJobs();renderInsp();renderCards();renderTx();renderLegend();renderPod();renderAgent();renderMb();setCount(CARDS.filter(c=>!c.answered).length);paintGlyphs();}

document.addEventListener("click",e=>{
  const t=e.target.closest("[data-s],[data-go],[data-t],[data-job],[data-f],[data-ans],[data-undo],[data-stop],[data-toast],[data-pod],[data-dead],[data-gr],[data-un],[data-sess],.ir");
  if(!t) return;
  if(t.dataset.t) return setTheme(t.dataset.t);
  if(t.dataset.s) return show(t.dataset.s);
  if(t.dataset.go) return show(t.dataset.go);
  if(t.dataset.sess){const m={tangm:"dead",chief:"transcript",cloudm:"inbox"};return show(m[t.dataset.sess]||"activity");}
  if(t.dataset.f){FILTER=t.dataset.f;document.querySelectorAll("#afilter button").forEach(b=>b.classList.toggle("on",b===t));renderJobs();paintGlyphs($("#jobs"));return;}
  if(t.dataset.job){SEL=t.dataset.job;renderJobs();renderInsp();return;}
  if(t.dataset.stop){const j=JOBS.find(x=>x.id===t.dataset.stop);j.state="stop";j.ended=true;j.wf="stopped by you";j.next="—";j.frac=1;
    if(j.kind==="pod"){POD.state="stop";renderPod();}renderJobs();renderInsp();toast(`${j.id} stopped · its output is kept`);return;}
  if(t.dataset.toast) return toast(t.dataset.toast);
  if(t.dataset.ans){const c=CARDS.find(x=>x.id===t.dataset.ans);
    if(t.dataset.i==="deny-note"){c.answered="denied with a note · "+c.who+" will try another way";}
    else{const a=c.acts[+t.dataset.i];if(a[2]==="note"){t.closest(".card").classList.add("noting");t.closest(".card").querySelector("input").focus();return;}c.answered=a[2];
      if(c.id==="c-bench"&&a[0]==="Stop pod"){POD.state="stop";renderPod();}}
    renderCards();return;}
  if(t.dataset.undo){CARDS.find(x=>x.id===t.dataset.undo).answered=null;renderCards();return;}
  if(t.dataset.pod){const a=t.dataset.pod;
    if(a==="ext"){POD.capm+=60;toast("time cap now 5h · stops itself at 17:08");}
    if(a==="cap"){POD.cap=75;toast("cost cap now $75 · warns at $60");}
    if(a==="pause"){POD.state="pause";toast("paused · gpu released · volume kept · resume any time");}
    if(a==="stop"){POD.state="stop";toast("tang-h200-bench stopped · volume kept · $0/hr");}
    renderPod();return;}
  if(t.dataset.dead){const a=t.dataset.dead,b=$("#deadBanner");
    if(a==="restart"){b.classList.add("ok");$("#deadFace").innerHTML=face("tree",40,"working");
      $("#deadBody").innerHTML=`<h3>tang manager is back</h3><p>engine restarted at 14:34. it read its ledger, took the pod back from the chief and resumed bench run 3 of 5. j4 was lost, so it started j5 with the same command.</p><div class="facts"><span class="chip"><span class="dot"></span>heartbeat ok</span><span class="chip"><span class="dot"></span>p1 owned again</span><span class="chip">j5 running · replaces j4</span></div>`;
      $("#deadGlyph").innerHTML=GLYPH.spin();$("#deadSub").textContent="~/Developer/tang · running";
      const s=SESSIONS.find(x=>x.id==="tangm");s.state="run";s.detail="running · resumed 14:34";renderTree("tangm");}
    if(a==="stoppod"){POD.state="stop";renderPod();toast("tang-h200-bench stopped · volume kept · $0/hr");}
    if(a==="hand"){toast("chief now owns tang manager's work · pod p1, rerun of j4");}
    return;}
  if(t.dataset.f&&t.closest("#dfilter")){DF=t.dataset.f;document.querySelectorAll("#dfilter button").forEach(b=>b.classList.toggle("on",b===t));renderAudit();return;}
  if(t.dataset.gr){const gr=GRANTS.find(x=>x.id===t.dataset.id);
    if(t.dataset.gr==="rev"){gr.state="revoked";toast(`${gr.id} revoked · ${gr.name}. anything running under it pauses.`);}
    if(t.dataset.gr==="re"){gr.state="active";toast(`${gr.id} granted again`);}
    if(t.dataset.gr==="narrow"){toast("edit what this grant covers · narrowing never needs an ask");}
    if(t.dataset.gr==="time"){toast(`${gr.id} renewed 4w`);}
    renderGrants();return;}
  if(t.dataset.un){const a=AUDIT.find(x=>x.t===t.dataset.un);toast(`undo queued: ${a.who}'s "${a.did}" reverses now`);return;}
  if(t.classList.contains("ir")&&t.nextElementSibling&&t.nextElementSibling.classList.contains("idet")) t.classList.toggle("open");
});
document.addEventListener("keydown",e=>{
  if(e.target.tagName==="INPUT") return;
  if((e.metaKey||e.ctrlKey)&&e.key==="0"){e.preventDefault();show(e.shiftKey?"inbox":"activity");}
  const on=$(".screen.on").dataset.screen;
  if(on==="activity"&&(e.key==="j"||e.key==="k")){const ids=JOBS.filter(visible).map(j=>j.id);let i=ids.indexOf(SEL);i=Math.max(0,Math.min(ids.length-1,i+(e.key==="j"?1:-1)));SEL=ids[i];renderJobs();renderInsp();}
});

$("#hface").innerHTML=`<span style="display:inline-block;width:26px;height:26px">${face("tree",26,"working")}</span>`;
// hash: #screen,theme,still  e.g. #inbox,light
const [h0,h1,h2]=(window.BOOT||location.hash.slice(1)||"activity").split(",");
setTheme(h1||"dark");
if(h2==="still") document.body.classList.add("still");
render();
show(h0||"activity");
