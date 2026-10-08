import Quickshell
import Quickshell.Io
import QtQuick

// One conversation: a `frog --serve` child speaking frog_engine::protocol
// (Op JSON lines in, Event JSON lines out), folded into a ListModel the
// transcript draws. Same protocol the Mac app speaks.
//   kind  user | message | reasoning | tool | note
Item {
    id: eng
    readonly property string bin: Quickshell.env("FROG_BIN") || "frog"
    // preview mode: play a recorded session instead of talking to a model
    readonly property string replay: Quickshell.env("FROG_APP_REPLAY") || ""

    property string cwd: Quickshell.env("FROG_APP_CWD") || Quickshell.env("HOME") || "/"
    property string resume: ""          // session id to continue
    property string modelSpec: ""       // -m, empty = config default
    property string session: ""
    property string title: ""
    property string model: ""
    property string mode: "default"
    property var status: ({})
    property bool busy: false
    property bool alive: false
    property string progress: ""
    property string failure: ""
    property var permission: null       // the open permission_request
    property var question: null         // the open question
    property alias items: list
    property var index: ({})             // item id -> row

    signal changed()

    ListModel { id: list }
    property var proc: null

    function start(opts) {
        list.clear();
        index = {};
        session = ""; title = ""; permission = null; question = null;
        busy = false; progress = ""; failure = "";
        resume = opts && opts.resume ? opts.resume : "";
        if (opts && opts.cwd) cwd = opts.cwd;
        if (opts && opts.model !== undefined) modelSpec = opts.model;
        let args;
        if (replay) args = [bin, "--replay", replay, "--replay-ask", "--speed", Quickshell.env("FROG_APP_SPEED") || "4"];
        else {
            args = [bin, "--serve"];
            if (resume) args.push("-r", resume);
            if (modelSpec) args.push("-m", modelSpec);
        }
        if (proc) { proc.dead = true; proc.running = false; proc.destroy(2000); }
        proc = procComp.createObject(eng, {command: args, workingDirectory: cwd, running: true});
    }
    function stop() { if (proc && proc.running) { send({op: "shutdown"}); proc.dead = true; proc.running = false; } }
    function send(op) { if (proc && proc.running && !proc.dead) proc.write(JSON.stringify(op) + "\n"); }
    function submit(text) {
        const t = text.trim();
        if (!t) return;
        if (t.startsWith("!")) send({op: "shell", command: t.slice(1)});
        else send({op: "submit", text: t});
    }
    function interrupt() { send({op: "interrupt"}); }
    function allow(always) {
        if (!permission) return;
        send({op: "permission", id: permission.id, decision: always ? "allow_always" : "allow"});
    }
    function deny() { if (permission) send({op: "permission", id: permission.id, decision: "deny"}); }
    function answer(choices, other) {
        if (!question) return;
        const op = {op: "answer", id: question.id, choices: choices || []};
        if (other) op.other = other;
        send(op);
    }
    function setModel(spec) { send({op: "set_model", spec: spec}); }
    function setMode(m) { send({op: "set_mode", mode: m}); }

    function push(o) {
        const row = {kind: "", id: "", text: "", name: "", arg: "", outcome: "", output: "", diff: "", level: ""};
        for (const k in o) row[k] = o[k];
        list.append(row);
        if (row.id) index[row.id] = list.count - 1;
        changed();
    }
    function rowOf(id) { const r = index[id]; return r === undefined ? -1 : r; }

    function handle(ev) {
        if (ev.session && !session) session = ev.session;
        switch (ev.event) {
        case "turn_started":
            push({kind: "user", text: ev.input || ""});
            busy = true;
            break;
        case "item_started": {
            const k = ev.kind || {};
            if (k.type === "message") push({kind: "message", id: ev.id});
            else if (k.type === "reasoning") push({kind: "reasoning", id: ev.id});
            else push({kind: "tool", id: ev.id, name: k.name || "", arg: k.arg || "", outcome: "running"});
            break;
        }
        case "item_delta": {
            const r = rowOf(ev.id), d = ev.delta || {};
            if (r < 0) break;
            if (d.type === "text" || d.type === "reasoning")
                list.setProperty(r, "text", list.get(r).text + d.text);
            else if (d.type === "output")
                list.setProperty(r, "output", list.get(r).output + Style.plain(d.text));
            changed();
            break;
        }
        case "item_completed": {
            const it = ev.item || {};
            let r = rowOf(ev.id);
            if (r < 0) {
                push({kind: it.type === "tool_call" ? "tool" : it.type, id: ev.id, name: it.name || "", arg: it.arg || ""});
                r = list.count - 1;
            }
            if (it.type === "tool_call") {
                list.setProperty(r, "outcome", it.outcome || "ok");
                list.setProperty(r, "output", Style.plain(it.display || it.output || ""));
                list.setProperty(r, "diff", it.diff ? JSON.stringify(it.diff) : "");
            } else {
                list.setProperty(r, "text", it.text || "");
            }
            changed();
            break;
        }
        case "permission_request":
            permission = ev;
            break;
        case "permission_resolved":
            if (permission && permission.id === ev.id) permission = null;
            break;
        case "question":
            question = ev;
            break;
        case "question_resolved":
            if (question && question.id === ev.id) question = null;
            break;
        case "auto_approved":
            break;
        case "turn_ended": {
            const why = ev.reason || {};
            const words = {max_tokens: "stopped at the output limit", denied: "stopped: you denied a tool call",
                           looping: "stopped: the model kept repeating itself", step_limit: "stopped at the step limit",
                           cancelled: "interrupted"};
            if (why.type === "error") push({kind: "note", level: "fault", text: errorText(why.error)});
            else if (words[why.type]) push({kind: "note", level: why.type === "cancelled" ? "" : "warn", text: words[why.type]});
            busy = false; progress = "";
            permission = null; question = null;
            break;
        }
        case "compacted":
            push({kind: "note", text: "compacted " + ev.tokens_before + " → " + ev.tokens_after + " tokens"});
            break;
        case "model_changed": model = ev.model; break;
        case "mode_changed": mode = ev.mode; break;
        case "titled": title = ev.title; break;
        case "folder_changed": cwd = ev.cwd; break;
        case "progress": progress = ev.label || ""; break;
        case "notice": push({kind: "note", level: ev.level === "warn" ? "warn" : ev.level === "error" ? "fault" : "", text: ev.message}); break;
        case "error": push({kind: "note", level: "fault", text: errorText(ev.error)}); break;
        case "status":
            status = ev;
            model = ev.model || model;
            mode = ev.mode || mode;
            if (ev.cwd) cwd = ev.cwd;
            break;
        case "idle": busy = false; progress = ""; break;
        }
    }
    function errorText(e) {
        if (!e) return "error";
        switch (e.type) {
        case "provider": return "provider error (" + e.status + "): " + e.message;
        case "connection": return "couldn't reach the model: " + e.message;
        case "incomplete_stream": return "the response stream ended early";
        default: return e.message || e.type;
        }
    }

    // one child per conversation; a replaced one is marked dead so its
    // last lines and its exit never reach the new conversation
    Component {
        id: procComp
        Process {
            id: p
            property bool dead: false
            stdinEnabled: true
            onRunningChanged: if (!dead) eng.alive = running
            onStarted: {
                if (eng.replay) return;
                eng.send({op: "set_client_caps", panes: false, ask: true});
                if (eng.resume) eng.send({op: "subscribe", after: 0});
            }
            stdout: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    if (p.dead || !line || line[0] !== "{") return;
                    try { eng.handle(JSON.parse(line)); } catch (e) { console.warn("frog: bad line", e); }
                }
            }
            stderr: SplitParser {
                onRead: line => { if (!p.dead && line.trim()) { console.log("frog:", line); eng.failure = line.trim(); } }
            }
            onExited: (code, st) => {
                if (p.dead) return;
                if (code !== 0) eng.push({kind: "note", level: "fault", text: "frog exited (" + code + ")" + (eng.failure ? ": " + eng.failure : "")});
                eng.busy = false;
            }
        }
    }
}
