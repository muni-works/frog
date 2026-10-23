// ---------- agent context: what the model sees ----------
function renderAgent(){
  const esc=s=>s.replace(/&/g,"&amp;").replace(/</g,"&lt;");
  const block=`<span class="c">&lt;background owner="chief" as-of="14:33:20" new="2"&gt;</span>
live 5 · needs cam 1 · held for a dead child 1 · burn <span class="w">$10.58/hr</span>

<span class="a">j31</span> shell  running 4m12s   bin/merge-queue.sh frog 74 76
           <span class="m">waits for exit · step 2 of 3 · cap 30m · wakes you</span>
<span class="a">m7</span>  watch  running 22m     frog cloud health
           <span class="m">until "Serving now" · every 30s · 44 checks · next 0:12</span>
<span class="a">m8</span>  timer  due 14:40:00     check tang bench <span class="m">(in 9m, wall clock)</span>
<span class="a">t2</span>  agent  running 1m40s   survey frog background code <span class="m">· $0.04</span>

children
  frog manager        idle, engine ok · 1 worker running · pr #81 ci 3/5
  frog cloud manager  <span class="w">needs cam 14m</span> · git push zest HEAD:cancel-safe
  tang manager        <span class="x">DEAD since 14:21</span> (oom) · you hold its work:
    <span class="a">p1</span> pod tang-h200-bench  <span class="w">$10.58/hr</span> · $23.40 of $50 · 2h13m of 4h
    <span class="x">j4</span> lost · bench/loop.sh · output kept

since your last turn
  j29 done · exit 0 · 3m12s · cargo test -p frog-engine <span class="m">(you saw it)</span>
  engine restarted 14:23 · 4 reattached · j12 ended during it

<span class="m">ids are stable across restarts. don't poll: every live item wakes you.
Jobs for the full list · JobOutput &lt;id&gt; for output.</span>
<span class="c">&lt;/background&gt;</span>`;
  const jobs=`<span class="c">› Jobs {"filter":"live","children":true}</span>
id   kind   state      owner        waiting for        elapsed  cost
j31  shell  running    chief        exit · step 2/3    4m12s    —
m7   watch  running    chief        "Serving now"      22m      —
m8   timer  set        chief        14:40:00           11m      —
t2   agent  running    chief        report             1m40s    $0.04
p1   pod    <span class="x">orphaned</span>   tang→you     run 3/5 · cap $50  2h13m    $23.40
j4   shell  <span class="x">lost</span>       tang         —                  1h52m    —
a9   appr   <span class="w">needs cam</span>  cloud mgr    Allow once / Deny  14m      —
<span class="m">7 items · 2 need attention · burn $10.58/hr</span>`;
const pairs=[
    ["a handle that outlived its job","no background task, job or monitor j12",
     `j12 ended 14:27 (exit 0, 48s) while the engine
restarted. output is kept: JobOutput j12`],
    ["a job lost with its engine","(nothing. the job is gone from every list.)",
     `j4 was lost at 14:21: its engine (tang manager)
died and the process went with it. no exit code.
last output 14:21:02. rerun: Jobs rerun j4`],
    ["a timer that woke early",`&lt;wakeup id=mon-2&gt; 12s elapsed`,
     `m8 is due at 14:40:00 (wall clock, 20m from 14:20).
it fires once, at or after that. it never wakes early;
a restart in between doesn't reset it.`],
    ["a second watch on the same thing",`Timer mon-9 set (a duplicate of mon-7)`,
     `already watching this as m7 (same command and
pattern, next check 0:12). returned m7.`],
    ["polling a running job",`(the agent calls JobOutput j31 nine times)`,
     `j31 is still running, 4m12s in, step 2 of 3.
nothing new since your last read 40s ago. you'll
get a wake when it exits; no need to check.`],
    ["a background process frog can't see",`nohup bin/merge-queue.sh … & disown   (invisible)`,
     `this command detaches with nohup/disown, so frog
couldn't track it. ran it as job j31 instead (it
survives restarts the same way). opt out: --detach`],
  ];
  const wake=`<span class="c">&lt;wake id="w-188" for="j31" kind="job-done" at="14:38:51"&gt;</span>
j31 finished · exit 0 · 9m43s (started 14:29:08)
bin/merge-queue.sh frog 74 76 · owner chief
last lines:
  #76 rebased on main · ci green · merged 91be0d4
  queue empty
still live: m7, m8, t2 · p1 held for tang manager
<span class="c">&lt;/wake&gt;</span>`;
  const child=`<span class="c">› ListSessions {"under":"self","fields":["liveness","jobs"]}</span>
frog manager        engine ok · idle 3m      jobs 1 · needs cam 0
  background-work-ux  engine ok · running 18m  $0.42 of $5
frog cloud manager  engine ok · <span class="w">waiting on cam 14m</span> (a9)
tang manager        <span class="x">dead 12m</span> · last beat 14:21:08 · oom
                      holds p1 ($10.58/hr) → <span class="w">moved to you</span>
zest                engine ok · running 3h   jobs 2
vcad manager        engine ok · idle 2h      jobs 0`;
  document.getElementById("agent").innerHTML=`
  <div class="aggrid">
    <div><h4>the background block<small>appended to every turn, after compaction and after a restart</small></h4><pre class="blk">${block}</pre>
      <p class="cap">≤ 30 lines. ended items drop out once the agent has seen them. children show one line each; only what needs the parent expands.</p></div>
    <div><h4>Jobs<small>one list for everything, durable ids</small></h4><pre class="blk">${jobs}</pre>
      <p class="cap">kinds share one id space per session: j shell, m watch or timer, t subagent, s child session, p pod, r pr or ci, a approval.</p>
      <h4 style="margin-top:14px">a wake says what happened, with real timing</h4><pre class="blk">${wake}</pre>
      <h4 style="margin-top:14px">a parent sees its children</h4><pre class="blk">${child}</pre></div>
  </div>
  <h4 style="margin:22px 0 10px;font:600 12px var(--font-ui)">errors that say what happened<small style="font-weight:400;color:var(--color-muted);margin-left:6px">today on the left, with the ledger on the right</small></h4>
  ${pairs.map(([t,a,b])=>`<div class="ba"><div><div class="lbl old">${t.toUpperCase()} · TODAY</div><pre class="blk old">${a}</pre></div><div><div class="lbl new">WITH THE LEDGER</div><pre class="blk">${b}</pre></div></div>`).join("")}`;
}

// ---------- menu bar, dock and notifications ----------
function renderMb(){
  document.getElementById("mb").innerHTML=`
  <div class="menubar"><span class="dim">wi-fi</span><span class="dim">100%</span>
    <span class="fi"><span class="g" style="width:14px;height:14px">${face("tree",14,"waiting")}</span><span id="mbCount">4</span></span>
    <span class="dim">thu 14:33</span></div>
  <div class="pop">
    <div class="ph"><span class="g" style="width:20px;height:20px">${face("tree",20,"waiting")}</span><b>frog</b><span>5 sessions · 11 live</span></div>
    <div class="pl">NEEDS YOU</div>
    <div class="pi">${g("orph")}<span>tang-h200-bench has no owner<small>tang manager died 12m ago</small></span><span class="r">$10.58/hr</span></div>
    <div class="pi">${g("key")}<span>frog cloud manager · git push<small>paused 14m</small></span><span class="r">⌘1</span></div>
    <div class="pi">${g("key")}<span>frog-ui worker · xcodebuild<small>paused 6m</small></span><span class="r">⌘2</span></div>
    <div class="pi">${g("ask")}<span>merge #81 when green?<small>frog manager</small></span><span class="r">⌘3</span></div>
    <hr>
    <div class="pl">RUNNING</div>
    <div class="pi">${g("spin")}<span>chief of staff<small>merge queue step 2 of 3 · 2 watches</small></span><span class="r">4</span></div>
    <div class="pi">${g("spin")}<span>zest<small>gateway logs · queue depth</small></span><span class="r">2</span></div>
    <div class="pi">${g("coin")}<span>spend<small>today $46.10 of $120</small></span><span class="r">$15.87/hr</span></div>
    <hr>
    <div class="pi"><span></span><span>Open activity</span><span class="r">⌘0</span></div>
    <div class="pi"><span></span><span>Pause alerts for 1 hour</span><span class="r"></span></div>
  </div>
  <div class="notifs">
    <div class="ntcap">ALERTS FROG SENDS</div>
    <div class="nt"><span class="ic">${face("gray",24,"sad")}</span><div><b>tang manager stopped</b><span>it still owns a pod at $10.58/hr. chief is holding it.</span></div><time>14:22</time>
      <div class="acts"><button class="btn p">Restart</button><button class="btn x">Stop pod</button></div></div>
    <div class="nt"><span class="ic">${face("tree",24,"waiting")}</span><div><b>frog cloud manager needs you</b><span>wants to push a branch to zest. paused 2m.</span></div><time>14:21</time>
      <div class="acts"><button class="btn p">Allow once</button><button class="btn">Open</button></div></div>
    <div class="nt"><span class="ic">${face("tree",24,"idle")}</span><div><b>tang-h200-bench is at 80% of its cap</b><span>$40 of $50. it stops itself at $50, in about 57m.</span></div><time>15:31</time>
      <div class="acts"><button class="btn">Extend 1h</button><button class="btn q">Let it stop</button></div></div>
  </div>
  <div class="rules">
    <div class="pane"><h4>ALERT WHEN</h4><ul>
      <li><b>something waits on you</b> for 60s and you're not looking at it</li>
      <li><b>an engine dies</b> while it owns live work or money</li>
      <li><b>a cap</b> hits 80%, and again when it acts</li>
      <li><b>you asked</b> to hear about this one (“tell me when”)</li></ul></div>
    <div class="pane"><h4>STAY QUIET WHEN</h4><ul>
      <li>a job ends normally. its owner hears, you don't.</li>
      <li>a watch checks, or a child reports to its parent</li>
      <li>you're already looking at the row</li>
      <li>the same cause alerted in the last 10m. more than 3 at once become one.</li></ul></div>
    <div class="dockwrap"><div class="dockicon">${face("tree",44,"waiting")}<span class="bd" id="dockBadge">4</span></div><div class="dockcap">dock badge = things waiting on you. nothing else.</div></div>
  </div>`;
  paintGlyphs(document.getElementById("mb"));
}
