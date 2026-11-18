#!/usr/bin/env python3
"""Which Mac app user flows a real integration test drives, computed from the tests.

A flow test declares its flow by its name, one way only:

    func test_<flow_id>()            e.g. test_rename_from_title     covers rename-from-title
    func test_<flow_id>__<variant>()  e.g. test_permission_allow__always

Flow ids are lowercase words joined by hyphens; in the test name the hyphens are underscores,
and a double underscore starts an optional variant. No other test name starts with `test_`
(the rest of FrogTests is camelCase `testSomething`), so the rule can't catch a test by
accident.

    coverage.py            report: flows driven by a test, flows with none, unknown names
    coverage.py --write    store each flow's `flow_tests` in the map (the map is computed)
    coverage.py --check    fail if a test names a flow that doesn't exist, or the stored
                           `flow_tests` differ from the tests (run --write and commit)

--map and --tests point it elsewhere (its own test does, with fixtures).
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MAPS = ["shell.json", "conversation.json", "platform.json"]
TEST_RE = re.compile(r"\bfunc\s+(test_\w+)\s*\(")
FLOW_RE = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")


def flow_of(test_name):
    """The flow id a `test_…` name declares, or None if the name breaks the rule."""
    body = test_name[len("test_"):].split("__", 1)[0]
    flow = body.replace("_", "-")
    return flow if FLOW_RE.fullmatch(flow) else None


def declared(tests_dir):
    """{flow id: ["Class.swift:test_name", …]} and the names that don't parse."""
    found, bad = {}, []
    for path in sorted(Path(tests_dir).rglob("*.swift")):
        for m in TEST_RE.finditer(path.read_text(encoding="utf-8")):
            name = m.group(1)
            ref = f"{path.relative_to(tests_dir)}:{name}"
            flow = flow_of(name)
            if flow is None:
                bad.append(ref)
            else:
                found.setdefault(flow, []).append(ref)
    return found, bad


def load(map_dir):
    return {name: json.loads((Path(map_dir) / name).read_text(encoding="utf-8")) for name in MAPS}


def flows(maps):
    for name, doc in maps.items():
        for feature in doc["features"]:
            for flow in feature["flows"]:
                yield name, feature, flow


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", default=HERE)
    ap.add_argument("--tests", default=REPO / "apps/macos/FrogTests")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    maps = load(args.map)
    tests, bad = declared(args.tests)
    problems = [f"test name breaks the flow rule (test_<flow_id>[__variant]): {b}" for b in bad]

    ids = {}
    for name, feature, flow in flows(maps):
        if flow["id"] in ids:
            problems.append(f"flow id {flow['id']} is in {ids[flow['id']]} and {name}: ids are keys, keep them unique")
        ids[flow["id"]] = name
    for flow_id, refs in sorted(tests.items()):
        if flow_id not in ids:
            problems.extend(f"{r} names flow {flow_id}, which isn't in the map" for r in refs)

    stale = []
    for name, feature, flow in flows(maps):
        want = sorted(tests.get(flow["id"], []))
        if flow.get("flow_tests", []) != want:
            stale.append(flow["id"])
            if args.write:
                if want:
                    flow["flow_tests"] = want
                else:
                    flow.pop("flow_tests", None)

    if args.write:
        for name, doc in maps.items():
            (Path(args.map) / name).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    elif args.check and stale:
        problems.append(f"flow_tests in the map are out of date for {', '.join(stale)}: run docs/testing/feature-map/coverage.py --write")

    every = list(flows(maps))
    auto = [f for _, _, f in every if f.get("automatable") == "yes"]
    driven = [f for _, _, f in every if f["id"] in tests]
    print(f"flows driven by a flow test: {len(driven)} of {len(every)}; "
          f"{sum(f['id'] in tests for f in auto)} of {len(auto)} marked automatable")
    if not (args.check or args.write):
        for name, feature, flow in every:
            mark = "x" if flow["id"] in tests else " "
            print(f"[{mark}] {flow['id']:48} {flow.get('automatable', '?'):5} {feature['id']}")
    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
