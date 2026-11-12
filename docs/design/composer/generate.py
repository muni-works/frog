#!/usr/bin/env python3
# Writes cases.json (the composer reducer's shared vectors) and ../parity/composer-states.json.
# Edit here, run `python3 docs/design/composer/generate.py`, then both test suites.
import json, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
LOCAL={"id":"local/qwen3-coder-next","name":"Qwen3 Coder Next","place":"local","node":"mew"}
CLOUD={"id":"cloud/glm-5.3-flash","name":"GLM-5.3 Flash","place":"cloud","node":None}
MAC={"id":"local/qwen3-8b","name":"Qwen3 8B","place":"local","node":None}
base={
 "draft":{"text":"","attachments":[],"caret":0},
 "lastSent":"",
 "mode":"auto","yoloConfirmed":False,
 "model":LOCAL,
 "defaults":{"local":LOCAL,"cloud":CLOUD},
 "signedIn":True,
 "where":{"kind":"folder","folder":"/Users/cam/frog","branch":"main","worktree":True,"git":True,"dirty":False},
 "busy":"idle","pending":None,"queued":0,"error":None,"notice":None,"confirm":None,"stackOpen":False,
 "memory":{"modelByPlace":{},"worktreeByRepo":{},"branchByRepo":{}}
}
def pr(n,state,repo="muni-works/frog",title=None,ok=3,total=3):
    return {"repo":repo,"number":n,"title":title or f"PR {n}","state":state,"checks":{"ok":ok,"total":total}}
def sess(**kw):
    w={"kind":"session","repo":"muni-works/frog","branch":"claude/tray","worktree":True,"worktreePath":"/Users/cam/frog/.claude/worktrees/tray","diff":{"add":0,"del":0,"files":0},"dirty":False,"ahead":0,"prs":[]}
    w.update(kw); return w
TEXT={"draft":{"text":"add a test","attachments":[],"caret":10}}
cases=[]
def c(name,row,given,intent,expect=None,effects=None):
    cases.append({"name":name,"row":row,"given":given,"intent":intent,"expect":expect or {},"effects":effects or []})

# --- Rail: action button
c("empty composer offers dictation","Rail · Action, empty",{},{"type":"action"},{"derived":{"action":"dictate","sendDisabled":True}},[{"type":"start_dictation"}])
c("typing turns the action into send","Rail · Action, text",{},{"type":"type","text":"add a test"},{"draft":{"text":"add a test","caret":10},"derived":{"action":"send","sendDisabled":False}})
c("whitespace alone sends nothing","Send · 1",{"draft":{"text":"   \n"}},{"type":"send"},{"busy":"idle","draft":{"text":"   \n"}},[])
c("send in a session submits and keeps the draft until ack","Send · 2",{**TEXT,"where":sess()},{"type":"send"},{"busy":"sending","pending":"draft","draft":{"text":"add a test"},"derived":{"sendDisabled":True}},[{"type":"submit","text":"add a test","attachments":[]}])
c("send trims the text","Send · 1",{"draft":{"text":"  fix it \n","attachments":[],"caret":3},"where":sess()},{"type":"send"},{"busy":"sending"},[{"type":"submit","text":"fix it"}])
c("acknowledgement clears the draft and attachments","Send · 3",{"draft":{"text":"add a test","attachments":[{"name":"a.png","size":10,"type":"image/png"}],"caret":10},"busy":"sending","pending":"draft","where":sess()},{"type":"ack"},{"busy":"working","pending":None,"draft":{"text":"","attachments":[]},"lastSent":"add a test","derived":{"action":"stop"}})
c("a second send while sending is ignored","Send · 2",{**TEXT,"busy":"sending","pending":"draft","where":sess()},{"type":"send"},{"busy":"sending"},[])
c("attachments alone can be sent","Send · 1",{"draft":{"text":"","attachments":[{"name":"shot.png","size":2000,"type":"image/png"}],"caret":0},"where":sess()},{"type":"send"},{"busy":"sending"},[{"type":"submit","text":"","attachments":[{"name":"shot.png"}]}])
c("working with an empty draft shows stop","Rail · Action, working",{"busy":"working","where":sess()},{"type":"action"},{"derived":{"action":"stop"}},[{"type":"interrupt"}])
c("text typed while working turns return into queue","Rail · Action, working",{"busy":"working","where":sess()},{"type":"type","text":"also lint"},{"derived":{"action":"queue"}})
c("queue sends a follow-up and counts it","Rail · Action, working",{"busy":"working","draft":{"text":"also lint","attachments":[],"caret":9},"where":sess()},{"type":"send"},{"busy":"working","queued":1,"draft":{"text":""},"lastSent":"also lint"},[{"type":"queue","text":"also lint","attachments":[]}])
c("turn done clears the queued count","Rail · Action, working",{"busy":"working","queued":2,"where":sess()},{"type":"turn_done"},{"busy":"idle","queued":0,"derived":{"action":"dictate"}})
c("esc stops a turn","Keyboard · Esc",{"busy":"working","where":sess()},{"type":"esc"},{"busy":"working"},[{"type":"interrupt"}])
c("esc clears an error when nothing runs","Keyboard · Esc",{"error":{"code":"cloud_busy","message":"Frog Cloud is busy","actions":["retry"],"control":None,"detail":None,"retryIn":4}},{"type":"esc"},{"error":None})
c("up in an empty composer recalls the last message","Keyboard · ↑",{"lastSent":"run the tests"},{"type":"recall"},{"draft":{"text":"run the tests","caret":13}})
c("up with text typed does nothing","Keyboard · ↑",{"lastSent":"run the tests",**TEXT},{"type":"recall"},{"draft":{"text":"add a test"}})
c("model loading: send waits","Send · Model loading",{**TEXT,"busy":"loading_model","where":sess()},{"type":"send"},{"busy":"loading_model","pending":"draft","derived":{"action":"stop"}},[])
c("model ready sends what waited","Send · Model loading",{**TEXT,"busy":"loading_model","pending":"draft","where":sess()},{"type":"model_ready"},{"busy":"sending","pending":"draft"},[{"type":"submit","text":"add a test"}])
c("stop cancels a model load and keeps the draft","Send · Model loading",{**TEXT,"busy":"loading_model","pending":"draft","where":sess()},{"type":"stop"},{"busy":"idle","pending":None,"draft":{"text":"add a test"}},[{"type":"cancel_load"}])
# --- Send failures
c("engine stopped keeps the draft","Send · Engine not running",{**TEXT,"busy":"sending","pending":"draft","where":sess()},{"type":"send_failed","code":"engine_stopped"},{"busy":"idle","draft":{"text":"add a test"},"error":{"code":"engine_stopped","message":"Frog's engine stopped","actions":["restart_engine"],"control":None}})
c("restart engine clears the error, draft kept","Send · Engine not running",{**TEXT,"error":{"code":"engine_stopped","message":"Frog's engine stopped","actions":["restart_engine"],"control":None,"detail":None,"retryIn":None}},{"type":"error_action","action":"restart_engine"},{"error":None,"draft":{"text":"add a test"}},[{"type":"restart_engine"}])
c("signed out of Frog Cloud","Send · Gateway 401",{**TEXT,"busy":"sending","pending":"draft","model":CLOUD},{"type":"send_failed","code":"signed_out"},{"busy":"idle","draft":{"text":"add a test"},"error":{"code":"signed_out","message":"Signed out of Frog Cloud","actions":["sign_in"]}})
c("sign in from the error opens login","Send · Gateway 401",{**TEXT,"error":{"code":"signed_out","message":"Signed out of Frog Cloud","actions":["sign_in"],"control":None,"detail":None,"retryIn":None}},{"type":"error_action","action":"sign_in"},{"error":None,"draft":{"text":"add a test"}},[{"type":"open_login"}])
c("out of credit offers the local model","Send · 402",{**TEXT,"busy":"sending","pending":"draft","model":CLOUD},{"type":"send_failed","code":"no_credit"},{"error":{"code":"no_credit","message":"Out of credit","actions":["add_credit","use_local"]}})
c("out of credit with no local model offers only credit","Send · 402",{**TEXT,"busy":"sending","pending":"draft","model":CLOUD,"defaults":{"local":None,"cloud":CLOUD}},{"type":"send_failed","code":"no_credit"},{"error":{"code":"no_credit","actions":["add_credit"]}})
c("use local switches the model and clears the error","Send · 402",{**TEXT,"model":CLOUD,"error":{"code":"no_credit","message":"Out of credit","actions":["add_credit","use_local"],"control":None,"detail":None,"retryIn":None}},{"type":"error_action","action":"use_local"},{"error":None,"model":LOCAL},[{"type":"set_model","model":LOCAL}])
c("add credit opens billing","Send · 402",{"error":{"code":"no_credit","message":"Out of credit","actions":["add_credit"],"control":None,"detail":None,"retryIn":None}},{"type":"error_action","action":"add_credit"},{"error":None},[{"type":"open_billing"}])
c("cloud busy shows the backoff","Send · 429 / 5xx",{**TEXT,"busy":"sending","pending":"draft","where":sess()},{"type":"send_failed","code":"cloud_busy","retryIn":8},{"error":{"code":"cloud_busy","message":"Frog Cloud is busy","actions":["retry"],"retryIn":8}})
c("retry sends the kept draft again","Send · 429 / 5xx",{**TEXT,"where":sess(),"error":{"code":"cloud_busy","message":"Frog Cloud is busy","actions":["retry"],"control":None,"detail":None,"retryIn":8}},{"type":"error_action","action":"retry"},{"error":None,"busy":"sending"},[{"type":"submit","text":"add a test"}])
c("dismiss clears the error slot","Error display · ×",{"error":{"code":"pr_not_found","message":"Couldn't find that PR","actions":[],"control":None,"detail":None,"retryIn":None}},{"type":"dismiss_error"},{"error":None})
# --- Plus / attachments
c("attaching an image adds it","Rail · ＋",{},{"type":"attach","files":[{"name":"a.png","size":1200,"type":"image/png"}]},{"draft":{"attachments":[{"name":"a.png"}]},"error":None})
c("too-large and wrong-type files are refused, the rest attach","Rail · ＋",{},{"type":"attach","files":[{"name":"ok.txt","size":10,"type":"text/plain"},{"name":"huge.png","size":30000000,"type":"image/png"},{"name":"app.zip","size":100,"type":"application/zip"}]},{"draft":{"attachments":[{"name":"ok.txt"}]},"error":{"code":"attach_refused","message":"Couldn't attach huge.png (over 20 MB), app.zip (not a supported type)","actions":[]}})
c("removing an attachment","Rail · ＋",{"draft":{"text":"","attachments":[{"name":"a.png","size":1,"type":"image/png"},{"name":"b.png","size":1,"type":"image/png"}],"caret":0}},{"type":"remove_attachment","index":0},{"draft":{"attachments":[{"name":"b.png"}]}})
c("mic denied outlines the action button","Rail · Action, empty",{},{"type":"mic_denied"},{"error":{"code":"mic_denied","message":"Allow microphone in System Settings","actions":["open_settings"],"control":"action"}})
c("open settings from the mic error","Rail · Action, empty",{"error":{"code":"mic_denied","message":"Allow microphone in System Settings","actions":["open_settings"],"control":"action","detail":None,"retryIn":None}},{"type":"error_action","action":"open_settings"},{"error":None},[{"type":"open_mic_settings"}])
# --- Mode
c("mode defaults to auto","Rail · Mode",{},{"type":"type","text":""},{"mode":"auto"})
c("picking a mode applies it","Rail · Mode",{},{"type":"set_mode","mode":"accept_edits"},{"mode":"accept_edits"},[{"type":"set_mode","mode":"accept_edits"}])
c("picking yolo asks once","Rail · Mode",{},{"type":"set_mode","mode":"yolo"},{"mode":"auto","confirm":"yolo"},[])
c("confirming yolo applies it and remembers","Rail · Mode",{"confirm":"yolo"},{"type":"confirm"},{"mode":"yolo","yoloConfirmed":True,"confirm":None},[{"type":"set_mode","mode":"yolo"}])
c("yolo after confirming once doesn't ask again","Rail · Mode",{"yoloConfirmed":True,"mode":"default"},{"type":"set_mode","mode":"yolo"},{"mode":"yolo","confirm":None},[{"type":"set_mode","mode":"yolo"}])
c("cancelling the yolo confirmation keeps the mode","Rail · Mode",{"confirm":"yolo"},{"type":"cancel_confirm"},{"mode":"auto","confirm":None})
c("cmd-period cycles auto to ask","Keyboard · ⌘.",{},{"type":"cycle_mode"},{"mode":"default"},[{"type":"set_mode","mode":"default"}])
c("cmd-period from accept edits asks for yolo","Keyboard · ⌘.",{"mode":"accept_edits"},{"type":"cycle_mode"},{"mode":"accept_edits","confirm":"yolo"})
c("changing mode mid-turn applies to the next permission","Rail · Mode",{"busy":"working","where":sess()},{"type":"set_mode","mode":"default"},{"mode":"default","busy":"working"},[{"type":"set_mode","mode":"default"}])
# --- Model
c("picking a model sets it and remembers it for the folder","Rail · Model",{},{"type":"pick_model","model":MAC},{"model":MAC,"memory":{"modelByPlace":{"/Users/cam/frog":MAC}}},[{"type":"set_model","model":MAC}])
c("a cloud model while signed out opens login and keeps the draft","Rail · Model",{**TEXT,"signedIn":False},{"type":"pick_model","model":CLOUD},{"model":LOCAL,"draft":{"text":"add a test"}},[{"type":"open_login"}])
c("swapping a node's model mid-turn swaps after the turn","Rail · Model",{"busy":"working","where":sess(),"model":MAC},{"type":"pick_model","model":LOCAL},{"model":LOCAL,"notice":"Swaps after this turn"},[{"type":"set_model","model":LOCAL}])
# --- New session top line
c("changing the folder keeps draft, attachments and mode","New · folder",{"draft":{"text":"add a test","attachments":[{"name":"a.png","size":1,"type":"image/png"}],"caret":10},"mode":"accept_edits"},{"type":"choose_folder","folder":"/Users/cam/zest","branch":"dev","git":True,"dirty":False},{"draft":{"text":"add a test","attachments":[{"name":"a.png"}]},"mode":"accept_edits","where":{"kind":"folder","folder":"/Users/cam/zest","branch":"dev","worktree":True}},[])
c("changing the folder takes its remembered model","New · folder",{"memory":{"modelByPlace":{"/Users/cam/zest":MAC},"worktreeByRepo":{},"branchByRepo":{}}},{"type":"choose_folder","folder":"/Users/cam/zest","branch":"main","git":True,"dirty":False},{"model":MAC},[{"type":"set_model","model":MAC}])
c("changing the folder takes its remembered worktree switch","New · folder",{"memory":{"modelByPlace":{},"worktreeByRepo":{"/Users/cam/zest":False},"branchByRepo":{}}},{"type":"choose_folder","folder":"/Users/cam/zest","branch":"main","git":True,"dirty":False},{"where":{"worktree":False}})
c("a folder outside git has no worktree","New · New worktree",{},{"type":"choose_folder","folder":"/Users/cam/notes","branch":"","git":False,"dirty":False},{"where":{"kind":"folder","git":False,"worktree":False}})
c("switching to cloud keeps the draft and says the model changed","New · cloud",{**TEXT},{"type":"choose_cloud","repo":"muni-works/frog","branch":"main"},{"draft":{"text":"add a test"},"where":{"kind":"cloud","repo":"muni-works/frog","branch":"main"},"model":CLOUD,"notice":"Switched to GLM-5.3 Flash for Frog Cloud"},[{"type":"set_model","model":CLOUD}])
c("switching from cloud back to a folder takes a local model","New · folder",{**TEXT,"model":CLOUD,"where":{"kind":"cloud","repo":"muni-works/frog","branch":"main"}},{"type":"choose_folder","folder":"/Users/cam/frog","branch":"main","git":True,"dirty":False},{"draft":{"text":"add a test"},"model":LOCAL,"notice":"Switched to Qwen3 Coder Next on this Mac"},[{"type":"set_model","model":LOCAL}])
c("just chat keeps the draft and drops the top line's repo","New · folder",{**TEXT},{"type":"just_chat"},{"where":{"kind":"chat"},"draft":{"text":"add a test"}})
c("a branch choice is kept when you switch away and back","New · branch",{"memory":{"modelByPlace":{},"worktreeByRepo":{},"branchByRepo":{"/Users/cam/zest":"feature"}}},{"type":"choose_folder","folder":"/Users/cam/zest","branch":"main","git":True,"dirty":False},{"where":{"branch":"feature"}})
c("picking a branch remembers it for the repo","New · branch",{},{"type":"pick_branch","branch":"dev"},{"where":{"branch":"dev"},"memory":{"branchByRepo":{"/Users/cam/frog":"dev"}}})
c("worktree off on a dirty tree notes the checkout","New · New worktree",{"where":{"dirty":True}},{"type":"toggle_worktree"},{"where":{"worktree":False},"notice":"Frog will work in your checkout","memory":{"worktreeByRepo":{"/Users/cam/frog":False}}})
c("worktree on clears the note","New · New worktree",{"where":{"dirty":True,"worktree":False},"notice":"Frog will work in your checkout"},{"type":"toggle_worktree"},{"where":{"worktree":True},"notice":None})
c("send on a new session creates it with the where","New · Send",{**TEXT},{"type":"send"},{"busy":"sending","draft":{"text":"add a test"}},[{"type":"start_session","where":{"kind":"folder","folder":"/Users/cam/frog","worktree":True},"text":"add a test","attachments":[]}])
c("worktree creation fails: draft kept, offer the checkout","New · Send",{**TEXT,"busy":"sending","pending":"draft"},{"type":"failed","code":"worktree_failed","detail":"branch main is checked out elsewhere"},{"busy":"idle","draft":{"text":"add a test"},"error":{"code":"worktree_failed","message":"Couldn't make a worktree","actions":["use_checkout"],"control":"worktree","detail":"branch main is checked out elsewhere"}})
c("use checkout turns the worktree off and sends","New · Send",{**TEXT,"error":{"code":"worktree_failed","message":"Couldn't make a worktree","actions":["use_checkout"],"control":"worktree","detail":None,"retryIn":None}},{"type":"error_action","action":"use_checkout"},{"error":None,"where":{"worktree":False},"busy":"sending"},[{"type":"start_session","where":{"worktree":False},"text":"add a test"}])
c("clone fails: draft kept","New · Send",{**TEXT,"busy":"sending","pending":"draft","where":{"kind":"cloud","repo":"o/r","branch":"main"}},{"type":"failed","code":"clone_failed"},{"busy":"idle","draft":{"text":"add a test"},"error":{"code":"clone_failed","message":"Couldn't clone the repo","control":"where"}})
c("a suggestion fills the draft without sending","New · suggestions",{},{"type":"suggestion","text":"Explain this repo"},{"draft":{"text":"Explain this repo"},"busy":"idle"},[])
c("suggestions don't replace typed text","New · suggestions",{**TEXT},{"type":"suggestion","text":"Explain this repo"},{"draft":{"text":"add a test"}})
# --- Session top line: git action by state
c("no changes, nothing ahead: no action","Top line · Action",{"where":sess()},{"type":"type","text":""},{"derived":{"gitAction":None,"prSummary":None}})
c("dirty with no PR: commit","Top line · Commit",{"where":sess(dirty=True,diff={"add":12,"del":3,"files":2})},{"type":"git_action"},{"derived":{"gitAction":"commit","canSwitchBranch":False}},[{"type":"draft_commit"}])
c("commit hook failure keeps the message and shows output","Top line · Commit",{"where":sess(dirty=True)},{"type":"failed","code":"hook_failed","detail":"lint: 2 errors"},{"error":{"code":"hook_failed","message":"A commit hook failed","actions":["show_output"],"control":"git_action","detail":"lint: 2 errors"}})
c("show output from the hook error","Top line · Commit",{"where":sess(dirty=True),"error":{"code":"hook_failed","message":"A commit hook failed","actions":["show_output"],"control":"git_action","detail":"lint: 2 errors","retryIn":None}},{"type":"error_action","action":"show_output"},{"error":{"code":"hook_failed"}},[{"type":"show_output","detail":"lint: 2 errors"}])
c("committed with no PR: open PR","Top line · Open PR",{"where":sess(ahead=2)},{"type":"git_action"},{"derived":{"gitAction":"open_pr"}},[{"type":"open_pr"}])
c("open PR without gh auth: connect GitHub","Top line · Open PR",{"where":sess(ahead=2)},{"type":"failed","code":"gh_auth"},{"error":{"code":"gh_auth","message":"Connect GitHub to open a PR","actions":["connect_github"],"control":"git_action"}})
c("connect GitHub runs gh auth login","Top line · Open PR",{"where":sess(ahead=2),"error":{"code":"gh_auth","message":"Connect GitHub to open a PR","actions":["connect_github"],"control":"git_action","detail":None,"retryIn":None}},{"type":"error_action","action":"connect_github"},{"error":None},[{"type":"gh_auth_login"}])
c("ahead of the PR: push","Top line · Push",{"where":sess(ahead=1,prs=[pr(297,"checks",ok=1,total=3)])},{"type":"git_action"},{"derived":{"gitAction":"push","prSummary":{"count":1,"worst":"checks","label":"#297"}}},[{"type":"push"}])
c("push rejected: branch moved on GitHub","Top line · Push",{"where":sess(ahead=1,prs=[pr(297,"checks")])},{"type":"failed","code":"push_rejected"},{"error":{"code":"push_rejected","message":"Branch moved on GitHub","actions":["pull_retry"],"control":"git_action"}})
c("pull and retry never force-pushes","Top line · Push",{"where":sess(ahead=1,prs=[pr(297,"checks")]),"error":{"code":"push_rejected","message":"Branch moved on GitHub","actions":["pull_retry"],"control":"git_action","detail":None,"retryIn":None}},{"type":"error_action","action":"pull_retry"},{"error":None},[{"type":"pull_push"}])
c("checks failing: fix sends a turn and keeps the draft","Top line · Fix",{**TEXT,"where":sess(prs=[pr(297,"failing",ok=2,total=3)])},{"type":"git_action"},{"busy":"sending","pending":"aside","draft":{"text":"add a test"},"derived":{"gitAction":"fix"}},[{"type":"submit","text":"Fix the failing checks on #297","attachments":[]}])
c("acknowledging a fix leaves the draft alone","Top line · Fix",{**TEXT,"busy":"sending","pending":"aside","where":sess(prs=[pr(297,"failing")])},{"type":"ack"},{"busy":"working","draft":{"text":"add a test"}})
c("approved: merge asks first","Top line · Merge",{"where":sess(prs=[pr(297,"approved")])},{"type":"git_action"},{"confirm":"merge","derived":{"gitAction":"merge"}},[])
c("confirming the merge merges that PR","Top line · Merge",{"confirm":"merge","where":sess(prs=[pr(297,"approved")])},{"type":"confirm"},{"confirm":None},[{"type":"merge","repo":"muni-works/frog","number":297}])
c("merge conflicts: resolve is a turn","Top line · Merge",{"where":sess(prs=[pr(297,"approved")]),"error":{"code":"merge_conflict","message":"This PR has conflicts","actions":["resolve_conflicts"],"control":"git_action","detail":None,"retryIn":None}},{"type":"error_action","action":"resolve_conflicts"},{"error":None,"busy":"sending","pending":"aside"},[{"type":"submit","text":"Resolve the merge conflicts on #297"}])
c("branch protection shows its reason","Top line · Merge",{"where":sess(prs=[pr(297,"approved")])},{"type":"failed","code":"branch_protected","detail":"2 approving reviews are required"},{"error":{"code":"branch_protected","message":"2 approving reviews are required","actions":[]}})
c("merged: archive","Top line · Archive",{"where":sess(prs=[pr(297,"merged")])},{"type":"git_action"},{"derived":{"gitAction":"archive","prSummary":{"label":"#297","worst":"merged"}}},[{"type":"archive","discard":False}])
c("merged with a dirty worktree asks before deleting","Top line · Archive",{"where":sess(dirty=True,prs=[pr(297,"merged")])},{"type":"git_action"},{"confirm":"archive","derived":{"gitAction":"archive"}},[])
c("closed: reopen","Top line · Reopen",{"where":sess(prs=[pr(297,"closed")])},{"type":"git_action"},{"derived":{"gitAction":"reopen"}},[{"type":"reopen","repo":"muni-works/frog","number":297}])
c("draft PR, up to date: no action","Top line · Action",{"where":sess(prs=[pr(297,"draft")])},{"type":"git_action"},{"derived":{"gitAction":None,"prSummary":{"worst":"draft"}}},[])
# --- PR pill & stack
c("PR pill opens the PR","Top line · PR pill",{"where":sess(prs=[pr(297,"checks")])},{"type":"pr_click","index":0},{},[{"type":"open_url","url":"https://github.com/muni-works/frog/pull/297"}])
c("option-click copies the URL","Top line · PR pill",{"where":sess(prs=[pr(297,"checks")])},{"type":"pr_click","index":0,"alt":True},{},[{"type":"copy","text":"https://github.com/muni-works/frog/pull/297"}])
c("stack pill names the worst state","Top line · Stack pill",{"where":sess(prs=[pr(297,"approved"),pr(41,"failing",repo="muni-works/zest"),pr(298,"checks")])},{"type":"open_stack"},{"stackOpen":True,"derived":{"gitAction":"fix","prSummary":{"count":3,"worst":"failing","label":"3 PRs, 1 failing"}}})
c("all merged stack","Top line · Stack pill",{"where":sess(prs=[pr(297,"merged"),pr(298,"merged")])},{"type":"type","text":""},{"derived":{"gitAction":"archive","prSummary":{"label":"2 PRs, all merged"}}})
c("the stack opens only with two or more","Top line · Stack pill",{"where":sess(prs=[pr(297,"checks")])},{"type":"open_stack"},{"stackOpen":False})
c("esc closes the stack","Top line · Stack pill",{"stackOpen":True,"where":sess(prs=[pr(1,"checks"),pr(2,"draft")])},{"type":"esc"},{"stackOpen":False})
c("bind a PR by URL or number","Top line · Bind a PR…",{"where":sess()},{"type":"bind_pr","ref":" #41 "},{},[{"type":"bind_pr","ref":"#41"}])
c("a PR that can't be found is inline","Top line · Bind a PR…",{"where":sess()},{"type":"failed","code":"pr_not_found"},{"error":{"code":"pr_not_found","message":"Couldn't find that PR"}})
c("bound PR state arrives from the feed","Top line · PR state source",{"where":sess()},{"type":"prs","prs":[pr(297,"checks",ok=1,total=3)]},{"where":{"prs":[{"number":297,"state":"checks"}]},"derived":{"prSummary":{"label":"#297"}}})
c("a PR you can't access stays bound","Top line · Stack pill",{"where":sess()},{"type":"prs","prs":[{**pr(9,"draft",repo="acme/secret"),"access":False},pr(297,"checks")]},{"where":{"prs":[{"repo":"acme/secret","access":False},{"number":297}]},"derived":{"prSummary":{"count":2}}})
c("switching branch on a dirty tree does nothing","Top line · branch",{"where":sess(dirty=True)},{"type":"switch_branch","branch":"main"},{"derived":{"canSwitchBranch":False}},[])
c("switching branch on a clean tree","Top line · branch",{"where":sess()},{"type":"switch_branch","branch":"main"},{},[{"type":"switch_branch","branch":"main"}])

doc={"about":"Shared test vectors for the composer reducer (docs/plans/2026-11-12-composer-tray.md). Each case deep-merges `given` onto `base` (objects merge, arrays and scalars replace), applies `intent`, and checks `expect` against the new state plus `derived` (a partial match: objects match the keys listed, arrays match length and each element partially) and `effects` (same length, each partial). Run by apps/web/test/composer.test.ts and FrogTests/ComposerReducerTests.swift. A behaviour change is a new case here; both fail until they agree.","base":base,"cases":cases}
open("cases.json","w").write(json.dumps(doc,indent=1,ensure_ascii=False)+"\n")
print(len(cases))

# --- parity fixture: the states the screenshots show (docs/design/parity/composer.html)
three=[pr(297,"approved",title="Composer: the tray"),pr(41,"failing",repo="muni-works/zest",title="PR state endpoint",ok=4,total=6),pr(298,"checks",title="Tokens for pr.*",ok=1,total=3)]
states=[
 ("idle","In a session, nothing typed",{"where":sess()}),
 ("typing","Typing: the action is Send",{"where":sess(),"draft":{"text":"add a test for the stack pill","attachments":[],"caret":29}}),
 ("working","Working, a follow-up queued",{"where":sess(),"busy":"working","queued":1,"draft":{"text":"also run the linter","attachments":[],"caret":19}}),
 ("no-repo","A folder outside git",{"where":{"kind":"folder","folder":"/Users/cam/notes","branch":"","worktree":False,"git":False,"dirty":False}}),
 ("worktree","A worktree with changes: Commit",{"where":sess(dirty=True,diff={"add":48,"del":12,"files":3})}),
 ("pr-draft","PR: draft",{"where":sess(prs=[pr(297,"draft",title="Composer: the tray")])}),
 ("pr-checks","PR: checks running, ahead: Push",{"where":sess(ahead=1,prs=[pr(297,"checks",title="Composer: the tray",ok=1,total=3)])}),
 ("pr-failing","PR: failing: Fix",{"where":sess(prs=[pr(297,"failing",title="Composer: the tray",ok=2,total=3)])}),
 ("pr-approved","PR: approved: Merge",{"where":sess(prs=[pr(297,"approved",title="Composer: the tray")])}),
 ("pr-merged","PR: merged: Archive",{"where":sess(prs=[pr(297,"merged",title="Composer: the tray")])}),
 ("pr-closed","PR: closed: Reopen",{"where":sess(prs=[pr(297,"closed",title="Composer: the tray")])}),
 ("stack","Three PRs, the stack open",{"where":sess(prs=three),"stackOpen":True}),
 ("new-folder","New session: a folder",{}),
 ("new-cloud","New session: Frog Cloud",{"where":{"kind":"cloud","repo":"muni-works/frog","branch":"main"},"model":CLOUD}),
 ("new-chat","New session: just chat",{"where":{"kind":"chat"}}),
 ("error","An error slot: out of credit",{"where":sess(),"model":CLOUD,"draft":{"text":"add a test","attachments":[],"caret":10},"error":{"code":"no_credit","message":"Out of credit","actions":["add_credit","use_local"],"control":None,"detail":None,"retryIn":None}}),
]
open("../parity/composer-states.json","w").write(json.dumps({"about":"The composer states the parity shots draw (docs/design/parity/composer.html), each merged onto cases.json's base like a case's `given`.","states":[{"name":n,"caption":c,"given":g} for n,c,g in states]},indent=1,ensure_ascii=False)+"\n")
