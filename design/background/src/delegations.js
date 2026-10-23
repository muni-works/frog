// ---------- delegated approvals ----------
const GRANTS=[
  {id:"dg1",name:"read-only remote calls",owner:"chief of staff",state:"active",
   sc:["runpod list-pods · gh pr view · gh run list · gh api reads · curl on api.frog.toys/status"],
   scNote:"only commands whose parsed arguments read. any subcommand outside the list asks normally.",
   time:"4w left",spent:"n/a",n:"1,208 uses · 0 near-misses",
   budget:"no budget · reads cost tokens only",near:0},
  {id:"dg2",name:"writes in a session's own scratch",owner:"chief of staff → its workers",state:"active",
   sc:["<repo>/.frog/worktrees/<name>/ · /private/tmp/task/ · anything the session's own worktree owns"],
   scNote:"paths are parsed before the check. a heredoc that hides a write outside these paths does not pass.",
   time:"4w left",spent:"8.4 GB disk · cap 20 GB",n:"342 uses · 2 blocked by scope",near:0},
  {id:"dg3",name:"ssh to mew inside a named scratch dir",owner:"chief of staff → workers on request",state:"active",
   sc:['ssh mew with a command line that touches only ~/scratch/<session>/'],
   scNote:"host:path parses host and path. a second path inside the command is checked the same way.",
   time:"6d left",spent:"n/a",n:"57 uses · 0 near-misses",near:0},
  {id:"dg4",name:"bench pods under a $ budget with a time cap",owner:"zest, on the chief's word",state:"near",
   sc:["runpod create/stop on the muni account · any gpu up to h200 · image must be a pinned public one"],
   scNote:"no public endpoints, no account changes. start is one call; spend is what the budget watches.",
   time:"4w left",spent:"$31.20 this week · cap $40",n:"9 pods · 0 overruns",near:.78},
  {id:"dg5",name:"push branches (never main) with green ci",owner:"frog manager",state:"active",
   sc:["git push to ecto/* refs/heads/* except main, master, release/* · branch must have a pr"],
   scNote:"the refspec is parsed, not string-matched. a push that resolves to main does not pass.",
   time:"12d left",spent:"n/a",n:"31 pushes · 0 forced",near:0},
  {id:"dg6",name:"merge prs with green ci, no release branches",owner:"frog manager, on Cam's standing line",state:"active",
   sc:["gh pr merge --squash on ecto/* when every check is green · never release/* or main of the app repo"],
   scNote:"counts as a merge Cam pre-approved on 2026-10-21. each one still lands in the audit.",
   time:"4w left",spent:"n/a",n:"12 merges",near:0},
  {id:"dg7",name:"restart a crashed engine",owner:"chief of staff → managers",state:"revoked",
   sc:["frog restart <session> · once per session per hour"],
   scNote:"revoked 2026-10-23 after the mew ssh mistake: restarts may re-run commands that were only approved once.",
   time:"—",spent:"n/a",n:"3 uses before revoke",near:0},
];
const NEVER=["force-push or history rewrite","deletes outside a scratch dir","production deploys","purchases and account changes","posts, emails or messages","credentials and api keys"];
const AUDIT=[
  {t:"14:31",who:"frog manager",did:"merged ecto/frog#74",grant:"dg6",v:"ok",l:"green ci · squash · 6f2a1c0",how:"auto"},
  {t:"14:29",who:"chief of staff",did:"started j31 merge queue",grant:"dg2",v:"ok",l:"scoped to ~/Developer/chief/.frog/worktrees/",how:"auto"},
  {t:"14:26",who:"frog-ui worker",did:"stopped bench pod frog-bench-3",grant:"dg4",v:"ok",l:"under its $40 weekly budget",how:"auto"},
  {t:"14:22",who:"chief of staff",did:"restarted tang manager",grant:"dg7",v:"no",l:"asked instead · delegation was already revoked",how:"cam"},
  {t:"14:19",who:"frog cloud manager",did:"git push zest HEAD:cancel-safe",grant:"—",v:"no",l:"no delegation covers new-branch pushes to zest. it asked.",how:"cam"},
  {t:"14:11",who:"chief of staff",did:"granted dg3 to workers",grant:"dg3",v:"gr",l:"ssh to mew · scratch dirs only · 6d",how:"cam"},
  {t:"13:58",who:"frog-ui worker",did:"xcodebuild outside its sandbox",grant:"dg2",v:"no",l:"path parsed from the heredoc: ~/Library/DerivedData · outside the grant",how:"cam"},
  {t:"13:40",who:"zest",did:"ran bench pods 4 times",grant:"dg4",v:"ok",l:"$12.40 this week of $40",how:"auto"},
  {t:"12:02",who:"chief of staff",did:"replaced dg1 with a tighter list",grant:"dg1",v:"gr",l:"previous version allowed any gh subcommand",how:"cam"},
  {t:"11:47",who:"frog manager",did:"pushed frog/review-jobs to ecto/frog",grant:"dg5",v:"ok",l:"branch push · pr opened with it",how:"auto"},
];
let DF="all";
function renderGrants(){
  const open=GRANTS.filter(g=>g.state!=="revoked").length;
  document.getElementById("dgSub").textContent=`${open} active · ${GRANTS.filter(g=>g.near).length} near a limit · all revocable in one click`;
  document.getElementById("grants").innerHTML=GRANTS.map(g=>{
    const st=g.state==="revoked"?stTag("stop","revoked"):g.state==="near"?stTag("wait","near its cap"):stTag("run","active");
    const tone=g.near>=1?"x":g.near>=.7?"w":"";
    return `<div class="grant ${g.state==="revoked"?"revoked":""} ${g.state==="near"?"near":""}" data-grant="${g.id}">
      <div class="gh"><span class="g" style="width:20px;height:20px">${face("tree",20,"working")}</span><span class="nm">${g.name}</span><span class="id">${g.id}</span><span class="st">${st}</span></div>
      <div class="gsc">${g.sc.map(x=>`<div>${x}</div>`).join("")}<div style="color:var(--color-faint);margin-top:3px">${g.scNote}</div></div>
      <div class="gm"><span class="chip">${g.owner}</span><span class="chip">${g.time}</span><span class="chip${tone?" "+tone:""}">${g.spent}</span><span class="chip">${g.n}</span></div>
      ${g.near?`<div class="meter"><div class="track"><i class="${tone}" style="width:${g.near*100}%"></i></div></div>`:""}
      <div class="gacts">${g.state==="revoked"
        ?`<button class="btn" data-gr="re" data-id="${g.id}">Re-grant</button><span style="font-size:11px;color:var(--color-muted)">revoked from the audit, below</span>`
        :`<button class="btn" data-gr="narrow" data-id="${g.id}">Narrow</button><button class="btn" data-gr="time" data-id="${g.id}">Renew</button><span class="spacer"></span><button class="btn x" data-gr="rev" data-id="${g.id}">Revoke</button>`}</div>
    </div>`;}).join("")+`
    <div class="never"><h4>NEVER DELEGABLE</h4><ul>${NEVER.map(x=>`<li>${x}</li>`).join("")}</ul>
    <p>no grant can cover these, at any level, for any reason. the agent asking for one is itself the signal: <b>the ask goes straight to Cam</b>, with what it touches and why the agent thinks it needs it.</p></div>`;
}
function renderAudit(){
  const A=AUDIT.filter(a=>DF==="all"||a.how===DF||DF==="rev"&&a.v==="no");
  document.getElementById("audit").innerHTML=A.map(a=>`<div class="aud">
    <time>${a.t}</time>
    <div><div class="aa"><span class="who">${a.who}</span> ${a.did} <code>${a.grant!=="—"?"· "+a.grant:""}</code></div>
    <div class="am"><span class="v ${a.v==="ok"?"ok":a.v==="no"?"no":"gr"}">${a.v==="ok"?"allowed":a.v==="no"?"asked cam":"by cam"}</span><span class="why">${a.l}</span>
    ${a.v==="ok"?`<button class="btn" data-un="${a.t}">Undo</button>`:""}</div></div></div>`).join("")
    ||`<div style="padding:20px 2px;color:var(--color-muted)">nothing in this filter today.</div>`;
  paintGlyphs(document.querySelector('[data-screen="delegations"]'));
}
