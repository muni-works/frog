// Quiet and dead children (see `child_watch`): a Task subagent or an engine-owned child
// session that stops making progress becomes one question on the parent, or with nobody to
// ask is stopped by a fixed rule; a dead one is reported as dead. Every quiet case runs on a
// paused clock: the stalls are scripted (`Fail::Stall`) and the minutes are virtual.

use super::*;
use crate::child_watch::{KEEP, STOP, STOP_TURN};

/// A parent engine with these child limits, its provider's requests handed back.
fn parent(
    script: Vec<Response>,
    quiet: u64,
    stop: u64,
    can_ask: bool,
    store: Option<PathBuf>,
    cwd: PathBuf,
) -> (Handle, Arc<Mutex<Vec<String>>>) {
    let mut profile = Profile::new(ProviderKind::Ollama, "test");
    profile.tool_mode = ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            child_quiet_secs: quiet,
            child_quiet_stop_secs: stop,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd,
        mode: Mode::Default,
        can_ask,
        resume: None,
        store,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    let sent = client.sent.clone();
    (start(opts, Provider::Scripted(client)).unwrap(), sent)
}

/// A client that shows questions to a person (the Mac, the web).
fn shows_questions(h: &Handle) {
    h.ops
        .send(Op::SetClientCaps {
            irc: false,
            panes: false,
            ask: true,
            sessions: false,
        })
        .unwrap();
}

/// `drive` with room for virtual minutes: the paused clock jumps straight to the next timer,
/// so the bound only has to outlast the longest one under test.
async fn drive_long(h: &mut Handle, done: impl Fn(&Event) -> bool) -> Vec<Envelope> {
    let mut out = Vec::new();
    loop {
        let env = tokio::time::timeout(Duration::from_secs(4 * 3600), h.events.recv())
            .await
            .expect("timed out waiting for events")
            .expect("event stream closed");
        let stop = done(&env.event);
        out.push(env);
        if stop {
            return out;
        }
    }
}

/// Everything that arrives within `secs` of virtual time.
async fn quiet_for(h: &mut Handle, secs: u64) -> Vec<Envelope> {
    let mut out = Vec::new();
    let until = tokio::time::Instant::now() + Duration::from_secs(secs);
    while let Ok(Some(env)) = tokio::time::timeout_at(until, h.events.recv()).await {
        out.push(env);
    }
    out
}

fn questions(evs: &[Envelope]) -> Vec<(String, String, String)> {
    evs.iter()
        .filter_map(|e| match &e.event {
            Event::Question {
                id, item, question, ..
            } => Some((id.clone(), item.clone(), question.clone())),
            _ => None,
        })
        .collect()
}

fn answer(h: &Handle, id: &str, choice: &str) {
    h.ops
        .send(Op::Answer {
            id: id.into(),
            answer: Answer {
                choices: vec![choice.into()],
                other: None,
            },
        })
        .unwrap();
}

/// The Task call's result as the parent's model got it.
fn task_output(evs: &[Envelope]) -> (String, ToolOutcome) {
    evs.iter()
        .find_map(|e| match &e.event {
            Event::ItemCompleted {
                item:
                    Item::ToolCall {
                        name,
                        output,
                        outcome,
                        ..
                    },
                ..
            } if name == "Task" => Some((output.clone(), outcome.clone())),
            _ => None,
        })
        .expect("the Task call completed")
}

fn task(prompt: &str) -> Block {
    call(
        "t",
        "Task",
        json!({"description": "find the parser", "prompt": prompt}),
    )
}

fn after_task() -> Vec<Response> {
    vec![
        reply(vec![task("where is the parser?")], Stop::ToolUse),
        reply(vec![text("carried on")], Stop::End),
    ]
}

/// The bug this fixes: a subagent whose engine panicked left its stream open (the router and
/// background registry hold the journal), so the parent's turn waited forever. Now the stream
/// closes and the parent's model gets an error that names the death, with no question.
#[tokio::test]
async fn a_dead_subagent_is_reported_dead_not_waited_on() {
    let dir = tmp_store();
    script_child_failing(&dir, vec![scripted::Fail::Panic], vec![]);
    let (mut h, _) = parent(after_task(), 300, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find it");
    let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    let (out, outcome) = task_output(&evs);
    assert!(out.contains("engine stopped unexpectedly"), "{out}");
    assert_eq!(outcome, ToolOutcome::Error, "a death is an error result");
    assert!(questions(&evs).is_empty(), "a dead child isn't a question");
    shutdown(h).await;
}

/// The same for a child session the engine owns: it used to stay "running" forever, so a
/// headless run (which waits for its children) never ended. Now its parent gets a note that it
/// died and its state settles.
#[tokio::test]
async fn a_dead_child_session_tells_its_parent_and_settles() {
    let dir = tmp_store();
    let store = dir.join(".store");
    script_child_failing(&dir, vec![scripted::Fail::Panic], vec![]);
    let start = call(
        "s",
        "StartSession",
        json!({"title": "find parser", "prompt": "where is the parser?", "read_only": true}),
    );
    let script = vec![
        reply(vec![start], Stop::ToolUse),
        reply(vec![text("started it")], Stop::End),
        reply(vec![text("it died; noted")], Stop::End),
    ];
    let (mut h, _) = parent(script, 300, 1800, true, Some(store), dir);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find the parser in parallel");
    let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { turn: 2, .. })).await;
    let woke = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::TurnStarted { input, .. } if input.contains("<session-message") => {
                Some(input.clone())
            }
            _ => None,
        })
        .expect("the parent heard about the death");
    assert!(woke.contains("stopped unexpectedly"), "{woke}");
    let last = evs
        .iter()
        .rev()
        .find_map(|e| match &e.event {
            Event::ChildSession { state, .. } => Some(state.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(last, "idle", "settled, so a headless run can end");
    assert!(questions(&evs).is_empty());
    shutdown(h).await;
}

/// A subagent whose model call stalls raises exactly one question on the parent, naming it and
/// what it was asked; Stop interrupts it and the parent carries on, saying why.
#[tokio::test(start_paused = true)]
async fn a_quiet_subagent_asks_once_and_stop_carries_on() {
    let dir = tmp_store();
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let (mut h, sent) = parent(after_task(), 60, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let qs = questions(&evs);
    assert_eq!(qs.len(), 1);
    let (id, item, q) = &qs[0];
    assert_eq!(item, "t", "anchored on the Task call");
    assert!(
        q.contains("find the parser") && q.contains("where is the parser?"),
        "{q}"
    );
    assert!(q.contains("60 s"), "{q}");
    answer(&h, id, STOP);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(questions(&evs).is_empty(), "one question, not one per tick");
    assert!(evs.iter().any(
        |e| matches!(&e.event, Event::QuestionResolved { id: r, answer, .. } if r == id && !answer.dismissed())
    ));
    let (out, _) = task_output(&evs);
    assert!(
        out.contains("The user stopped this subagent after it had produced nothing for 60 s"),
        "{out}"
    );
    assert!(
        sent.lock()
            .unwrap()
            .last()
            .unwrap()
            .contains("The user stopped this subagent")
    );
    shutdown(h).await;
}

/// Keep waiting starts the quiet clock over: another full stretch, then one more question.
#[tokio::test(start_paused = true)]
async fn keep_waiting_asks_again_after_another_stretch() {
    let dir = tmp_store();
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let (mut h, _) = parent(after_task(), 60, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let first = questions(&evs)[0].0.clone();
    let asked = tokio::time::Instant::now();
    answer(&h, &first, KEEP);
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    assert!(
        asked.elapsed() >= Duration::from_secs(60),
        "a full stretch first"
    );
    assert!(
        evs.iter()
            .any(|e| matches!(&e.event, Event::QuestionResolved { id, .. } if *id == first))
    );
    let second = questions(&evs);
    assert_eq!(second.len(), 1);
    assert_ne!(second[0].0, first);
    answer(&h, &second[0].0, STOP);
    drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    shutdown(h).await;
}

/// A child whose provider is busy says so on every retry ("busy, retrying…"): it isn't quiet,
/// however long the storm, and no question opens.
#[tokio::test(start_paused = true)]
async fn a_busy_subagent_raises_no_question() {
    let dir = tmp_store();
    let busy = || scripted::Fail::Busy {
        status: 429,
        body: "busy".into(),
        retry_after: 60,
    };
    script_child_failing(
        &dir,
        (0..5).map(|_| busy()).collect(),
        vec![reply(vec![text("src/parse.rs:12")], Stop::End)],
    );
    let (mut h, _) = parent(after_task(), 90, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    let began = tokio::time::Instant::now();
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(
        began.elapsed() > Duration::from_secs(4 * 60),
        "the storm outlasted the quiet threshold several times over"
    );
    assert!(questions(&evs).is_empty());
    assert!(task_output(&evs).0.contains("src/parse.rs:12"));
    shutdown(h).await;
}

/// A write-mode child sitting on a permission card is waiting on the person, not quiet: the
/// card is on the parent (labelled with the child), and no question opens however long it
/// waits. Answering the card lets it finish.
#[tokio::test(start_paused = true)]
async fn a_subagent_on_a_card_raises_no_question_and_its_card_is_reachable() {
    let dir = tmp_store();
    let write = call(
        "w",
        "Write",
        json!({"file_path": "new.txt", "content": "hi\n"}),
    );
    script_child(
        &dir,
        vec![
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("wrote new.txt")], Stop::End),
        ],
    );
    let task = call(
        "t",
        "Task",
        json!({"description": "write file", "prompt": "create new.txt", "mode": "write"}),
    );
    let script = vec![
        reply(vec![task], Stop::ToolUse),
        reply(vec![text("done")], Stop::End),
    ];
    let (mut h, _) = parent(script, 60, 120, true, None, dir.clone());
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "have a subagent write it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::PermissionRequest { .. })).await;
    let card = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::PermissionRequest { id, subagent, .. } => Some((id.clone(), subagent.clone())),
            _ => None,
        })
        .unwrap();
    assert_eq!(
        card.1.as_deref(),
        Some("t"),
        "the child's card is on the parent"
    );
    // Five quiet thresholds, and past the headless cap, on the card (but inside the 10 min
    // `approval_timeout` that denies a card nobody answers).
    let waited = quiet_for(&mut h, 300).await;
    assert!(
        questions(&waited).is_empty(),
        "a child on a card isn't quiet"
    );
    h.ops
        .send(Op::Permission {
            id: card.0,
            decision: Decision::Allow,
            note: None,
            choice: None,
        })
        .unwrap();
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    let out = task_output(&evs).0;
    assert!(out.contains("wrote new.txt"), "{out}");
    assert_eq!(
        std::fs::read_to_string(dir.join("new.txt")).unwrap(),
        "hi\n"
    );
    shutdown(h).await;
}

/// Nobody to ask (headless, `frog bench`): no question ever; after `child_quiet_stop_secs` the
/// engine stops the child itself and the parent carries on, saying so.
#[tokio::test(start_paused = true)]
async fn headless_stops_a_quiet_subagent_at_the_cap_without_asking() {
    let dir = tmp_store();
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    // can_ask is true but no client said it shows questions: the same as headless.
    let (mut h, _) = parent(after_task(), 60, 120, true, None, dir);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    let began = tokio::time::Instant::now();
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(began.elapsed() >= Duration::from_secs(120));
    assert!(questions(&evs).is_empty(), "nobody to ask, so no question");
    let (out, _) = task_output(&evs);
    assert!(
        out.contains("frog stopped this subagent after it had produced nothing for 2 min (nobody was there to ask)"),
        "{out}"
    );
    shutdown(h).await;
}

/// A question is withdrawn the moment the child shows life: here its provider comes back
/// (a retry's "busy, retrying…") after the question opened, and the subagent finishes.
#[tokio::test(start_paused = true)]
async fn a_quiet_question_is_withdrawn_when_the_child_speaks() {
    let dir = tmp_store();
    script_child_failing(
        &dir,
        vec![scripted::Fail::Busy {
            status: 429,
            body: "busy".into(),
            retry_after: 60,
        }],
        vec![reply(vec![text("src/parse.rs:12")], Stop::End)],
    );
    let (mut h, _) = parent(after_task(), 30, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let id = questions(&evs)[0].0.clone();
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(evs.iter().any(
        |e| matches!(&e.event, Event::QuestionResolved { id: r, answer, .. } if *r == id && answer.dismissed())
    ), "withdrawn with no answer");
    assert!(task_output(&evs).0.contains("src/parse.rs:12"));
    shutdown(h).await;
}

fn start_child() -> Vec<Response> {
    let start = call(
        "s",
        "StartSession",
        json!({"title": "find parser", "prompt": "where is the parser?", "read_only": true}),
    );
    vec![
        reply(vec![start], Stop::ToolUse),
        reply(vec![text("started it")], Stop::End),
        reply(vec![text("carried on")], Stop::End),
    ]
}

/// A child session that goes quiet raises the question on its (idle) parent, anchored on the
/// child; Stop interrupts it, and the parent's note says who stopped it and why.
#[tokio::test(start_paused = true)]
async fn a_quiet_child_session_asks_and_stop_interrupts_it() {
    let dir = tmp_store();
    let store = dir.join(".store");
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let (mut h, _) = parent(start_child(), 60, 1800, true, Some(store), dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find the parser in parallel");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let child = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::ChildSession { id, .. } => Some(id.clone()),
            _ => None,
        })
        .unwrap();
    let qs = questions(&evs);
    assert_eq!(qs.len(), 1);
    assert_eq!(qs[0].1, child, "anchored on the child");
    assert!(
        qs[0].2.contains("child session “find parser”"),
        "{}",
        qs[0].2
    );
    answer(&h, &qs[0].0, STOP);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { turn: 2, .. })).await;
    let woke = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::TurnStarted { input, .. } if input.contains("<session-message") => {
                Some(input.clone())
            }
            _ => None,
        })
        .expect("the stop reached the parent as the child's turn end");
    assert!(woke.contains("stopped (cancelled)"), "{woke}");
    assert!(
        woke.contains("The user stopped it after it had produced nothing for 60 s"),
        "{woke}"
    );
    assert!(questions(&evs).is_empty());
    shutdown(h).await;
}

/// #117's shape: once a child has ended its turn (or its Task returned), nothing about it asks
/// or wakes anyone again, however long the clock runs. One note per ended turn, no more.
#[tokio::test(start_paused = true)]
async fn an_ended_child_never_asks_or_wakes_again() {
    let dir = tmp_store();
    let store = dir.join(".store");
    script_child(&dir, vec![reply(vec![text("src/parse.rs:12")], Stop::End)]);
    script_child(&dir, vec![reply(vec![text("src/parse.rs:12")], Stop::End)]);
    let mut script = start_child();
    script.push(reply(vec![task("where is the parser?")], Stop::ToolUse));
    script.push(reply(vec![text("done")], Stop::End));
    let (mut h, _) = parent(script, 60, 120, true, Some(store), dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find the parser in parallel");
    // The child's note wakes the parent once (turn 2).
    let mut evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { turn: 2, .. })).await;
    submit(&h, "and with a Task");
    evs.extend(drive_long(&mut h, |e| matches!(e, Event::TurnEnded { turn: 3, .. })).await);
    let later = quiet_for(&mut h, 20 * 60).await;
    assert!(questions(&evs).is_empty() && questions(&later).is_empty());
    assert!(
        !later
            .iter()
            .any(|e| matches!(e.event, Event::TurnStarted { .. })),
        "nothing woke the parent after the children ended"
    );
    shutdown(h).await;
}

/// A real stall: the stream hangs until the request times out, and the retry policy tries
/// again, five times. The retries' status lines aren't progress, so the quiet clock isn't
/// reset by them: one question, still open while the retries go on.
#[tokio::test(start_paused = true)]
async fn a_stream_that_times_out_and_retries_still_asks_once() {
    let dir = tmp_store();
    let hangs = (0..6).map(|_| scripted::Fail::Hang { secs: 600 }).collect();
    script_child_failing(&dir, hangs, vec![]);
    let (mut h, _) = parent(after_task(), 300, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let id = questions(&evs)[0].0.clone();
    // Through two more timed-out attempts.
    let later = quiet_for(&mut h, 1300).await;
    assert!(questions(&later).is_empty(), "still the one question");
    assert!(
        !later
            .iter()
            .any(|e| matches!(&e.event, Event::QuestionResolved { .. })),
        "a retry isn't the child coming back"
    );
    answer(&h, &id, STOP);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(
        task_output(&evs)
            .0
            .contains("The user stopped this subagent")
    );
    shutdown(h).await;
}

/// Headless, the same stall is stopped at the cap, not after an hour of retries.
#[tokio::test(start_paused = true)]
async fn headless_stops_a_timing_out_subagent_at_the_cap() {
    let dir = tmp_store();
    let hangs = (0..6).map(|_| scripted::Fail::Hang { secs: 600 }).collect();
    script_child_failing(&dir, hangs, vec![]);
    let (mut h, _) = parent(after_task(), 300, 1800, false, None, dir);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    let began = tokio::time::Instant::now();
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    let took = began.elapsed();
    assert!(
        took >= Duration::from_secs(1800) && took < Duration::from_secs(2400),
        "{took:?}"
    );
    assert!(questions(&evs).is_empty());
    assert!(task_output(&evs).0.contains("nobody was there to ask"));
    shutdown(h).await;
}

/// `frog -p`'s case: a child session goes quiet with nobody to ask. frog stops it at the
/// cap, the parent's note says so, and the child settles, so the run can end.
#[tokio::test(start_paused = true)]
async fn a_quiet_child_session_with_nobody_to_ask_is_stopped_and_settles() {
    let dir = tmp_store();
    let store = dir.join(".store");
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let (mut h, _) = parent(start_child(), 60, 120, false, Some(store), dir);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find the parser in parallel");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { turn: 2, .. })).await;
    assert!(questions(&evs).is_empty());
    let woke = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::TurnStarted { input, .. } if input.contains("<session-message") => {
                Some(input.clone())
            }
            _ => None,
        })
        .unwrap();
    assert!(
        woke.contains(
            "frog stopped it after it had produced nothing for 2 min (nobody was there to ask)"
        ),
        "{woke}"
    );
    let last = evs
        .iter()
        .rev()
        .find_map(|e| match &e.event {
            Event::ChildSession { state, .. } => Some(state.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(last, "idle");
    shutdown(h).await;
}

/// A child session's question is asked while its parent is idle, and clients put every
/// question away when a turn ends. So a parent turn in between (the person sends something)
/// leaves the question open in the engine and shows it again, same id, and it still works.
#[tokio::test(start_paused = true)]
async fn a_child_question_survives_a_parent_turn_and_is_shown_again() {
    let dir = tmp_store();
    let store = dir.join(".store");
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let mut script = start_child();
    script.insert(2, reply(vec![text("still waiting on it")], Stop::End));
    let (mut h, _) = parent(script, 60, 1800, true, Some(store), dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "find the parser in parallel");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    let id = questions(&evs)[0].0.clone();
    submit(&h, "how is it going?");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    assert!(
        !evs.iter()
            .any(|e| matches!(&e.event, Event::QuestionResolved { id: r, .. } if *r == id)),
        "the parent's turn didn't dismiss the child's question"
    );
    let ended = evs
        .iter()
        .position(|e| matches!(e.event, Event::TurnEnded { .. }))
        .expect("the parent's turn ended");
    let again = evs
        .iter()
        .position(|e| matches!(&e.event, Event::Question { id: q, .. } if *q == id))
        .unwrap();
    assert!(again > ended, "shown again after the turn ended");
    answer(&h, &id, STOP);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { turn: 3, .. })).await;
    assert!(evs.iter().any(|e| matches!(
        &e.event,
        Event::TurnStarted { input, .. } if input.contains("The user stopped it")
    )));
    shutdown(h).await;
}

// The turn's own model call going quiet (see `child_watch::Watch::call`): at
// `call_quiet_secs` of nothing streamed the person is asked to keep waiting or stop the turn.

/// An engine on a cloud model (the clock starts when a call is sent) or a local one (it starts
/// at the first token), its provider failing the first calls with `fails`.
fn quiet_call_engine(cloud: bool, fails: Vec<scripted::Fail>, script: Vec<Response>) -> Handle {
    let kind = if cloud {
        ProviderKind::Anthropic
    } else {
        ProviderKind::Ollama
    };
    let mut profile = Profile::new(kind, "test");
    profile.tool_mode = ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd: tmp_store(),
        mode: Mode::Default,
        can_ask: true,
        resume: None,
        store: None,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    *client.fails.lock().unwrap() = fails.into();
    start(opts, Provider::Scripted(client)).unwrap()
}

fn options(evs: &[Envelope]) -> Vec<String> {
    evs.iter()
        .rev()
        .find_map(|e| match &e.event {
            Event::Question { options, .. } => {
                Some(options.iter().map(|o| o.label.clone()).collect())
            }
            _ => None,
        })
        .unwrap_or_default()
}

fn ended(evs: &[Envelope]) -> EndReason {
    evs.iter()
        .find_map(|e| match &e.event {
            Event::TurnEnded { reason, .. } => Some(reason.clone()),
            _ => None,
        })
        .expect("the turn ended")
}

/// A cloud call that sends nothing asks at 30 s, and Stop is the Stop button: the turn ends
/// cancelled and the question closes with the answer.
#[tokio::test(start_paused = true)]
async fn a_quiet_call_asks_at_30s_and_stop_ends_the_turn() {
    let mut h = quiet_call_engine(true, vec![scripted::Fail::Stall], vec![]);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    let began = tokio::time::Instant::now();
    submit(&h, "go");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    assert_eq!(began.elapsed().as_secs(), 30, "asked at 30 s");
    let (id, _, question) = questions(&evs)[0].clone();
    assert_eq!(question, "The model has sent nothing for 30 s.");
    assert_eq!(options(&evs), [KEEP, STOP_TURN]);
    answer(&h, &id, STOP_TURN);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert!(
        evs.iter().any(|e| matches!(&e.event,
            Event::QuestionResolved { id: r, answer, .. } if *r == id && answer.choices == [STOP_TURN])),
        "the question closes with the answer"
    );
    assert_eq!(ended(&evs), EndReason::Cancelled);
    assert!(began.elapsed() < Duration::from_secs(31), "stopped at once");
    shutdown(h).await;
}

/// Keep waiting asks again after twice as long, so a slow provider isn't asked every 30 s.
#[tokio::test(start_paused = true)]
async fn keep_waiting_on_a_quiet_call_asks_again_after_twice_as_long() {
    let mut h = quiet_call_engine(true, vec![scripted::Fail::Stall], vec![]);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "go");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    answer(&h, &questions(&evs)[0].0, KEEP);
    let kept = tokio::time::Instant::now();
    let soon = quiet_for(&mut h, 59).await;
    assert!(questions(&soon).is_empty(), "not again within 60 s");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    assert_eq!(kept.elapsed().as_secs(), 60);
    let (id, _, question) = questions(&evs)[0].clone();
    assert_eq!(question, "The model has sent nothing for 60 s.");
    answer(&h, &id, STOP_TURN);
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert_eq!(ended(&evs), EndReason::Cancelled);
    shutdown(h).await;
}

/// A stream that stalls mid-reply asks, anchored on the message it's writing, and the question
/// is withdrawn the moment the stream comes back; the turn finishes as usual.
#[tokio::test(start_paused = true)]
async fn a_quiet_call_question_is_withdrawn_when_tokens_come_back() {
    let pause = scripted::Fail::Pause {
        text: "Working on it".into(),
        secs: 45,
    };
    let mut h = quiet_call_engine(
        true,
        vec![pause],
        vec![reply(vec![text(", done.")], Stop::End)],
    );
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "go");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    let asked = questions(&evs);
    assert_eq!(asked.len(), 1, "{asked:?}");
    let (id, item, _) = asked[0].clone();
    let message = evs
        .iter()
        .find_map(|e| match &e.event {
            Event::ItemStarted {
                id,
                kind: ItemKind::Message,
            } => Some(id.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(item, message, "anchored on the message being written");
    assert!(
        evs.iter().any(|e| matches!(&e.event,
            Event::QuestionResolved { id: r, answer, .. } if *r == id && answer.dismissed())),
        "withdrawn with no answer"
    );
    assert_eq!(ended(&evs), EndReason::Complete);
    shutdown(h).await;
}

/// A local model's prefill can rightly take minutes: its clock starts at the first token, so a
/// call that hasn't sent one yet never asks, and one that stalls after it does.
#[tokio::test(start_paused = true)]
async fn a_local_call_counts_from_its_first_token() {
    let mut h = quiet_call_engine(false, vec![scripted::Fail::Stall], vec![]);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "go");
    let evs = quiet_for(&mut h, 600).await;
    assert!(questions(&evs).is_empty(), "no first token yet: not quiet");
    h.ops.send(Op::Interrupt).unwrap();
    drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    shutdown(h).await;

    let pause = scripted::Fail::Pause {
        text: "Working on it".into(),
        secs: 45,
    };
    let mut h = quiet_call_engine(
        false,
        vec![pause],
        vec![reply(vec![text(", done.")], Stop::End)],
    );
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "go");
    let evs = drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    assert_eq!(
        questions(&evs).len(),
        1,
        "quiet after its first token: asked"
    );
    shutdown(h).await;
}

/// With nobody to ask, a quiet call raises nothing: the provider's own timeout governs.
#[tokio::test(start_paused = true)]
async fn a_quiet_call_with_nobody_to_ask_raises_no_question() {
    let mut h = quiet_call_engine(true, vec![scripted::Fail::Stall], vec![]);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    submit(&h, "go");
    let evs = quiet_for(&mut h, 600).await;
    assert!(questions(&evs).is_empty());
    h.ops.send(Op::Interrupt).unwrap();
    drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    shutdown(h).await;
}

/// A subagent's calls are its parent's `child_watch`'s to ask about, never its own: a stalled
/// subagent raises the child question at `child_quiet_secs`, and nothing before.
#[tokio::test(start_paused = true)]
async fn a_quiet_subagent_call_asks_only_through_its_parent() {
    let dir = tmp_store();
    script_child_failing(&dir, vec![scripted::Fail::Stall], vec![]);
    let (mut h, _) = parent(after_task(), 120, 1800, true, None, dir);
    shows_questions(&h);
    drive(&mut h, |e| matches!(e, Event::Idle)).await;
    let began = tokio::time::Instant::now();
    submit(&h, "find it");
    let evs = drive_long(&mut h, |e| matches!(e, Event::Question { .. })).await;
    assert_eq!(
        began.elapsed().as_secs(),
        120,
        "the child question, at child_quiet_secs"
    );
    let asked = questions(&evs);
    assert_eq!(asked.len(), 1);
    assert!(asked[0].2.starts_with("The subagent"), "{}", asked[0].2);
    answer(&h, &asked[0].0, STOP);
    drive_long(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
    shutdown(h).await;
}
