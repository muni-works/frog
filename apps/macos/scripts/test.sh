#!/bin/zsh
# The Mac app's test suite, run locally the way CI runs it (job `macos-app` in
# .github/workflows/ci.yml): per-test timeouts on, so a hung test fails by name after 5 minutes
# and xcodebuild goes on to the next one, instead of the whole run sitting there for an hour.
#
#   apps/macos/scripts/test.sh                                   # the whole suite
#   apps/macos/scripts/test.sh -only-testing:FrogTests/SomeTests # extra xcodebuild arguments
#
# The full xcodebuild log goes to apps/macos/build/test.log (unfiltered, so a stall shows which
# test was running); the end of the run prints each failing test and the executed/failed counts.
#
# What it leaves out of CI's command, on purpose:
# - TEST_RUNNER_CI: that tells the tests they're on a shared VM, which skips the display-driven
#   ones and multiplies their wall-clock budgets by 4. A Mac runs them as written.
# - -retry-tests-on-failure / -test-iterations: a flaky test shows up as a failure here.
# - ad-hoc signing: local builds sign the usual way.
set -u
cd "${0:A:h}/.."
mkdir -p build
log=build/test.log

xcodegen generate --quiet || exit 1
echo "testing; full log: apps/macos/$log"
xcodebuild test \
    -project Frog.xcodeproj -scheme Frog -configuration Debug \
    -derivedDataPath build/test -destination 'platform=macOS,arch=arm64' \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
    "$@" > "$log" 2>&1
rc=$?

# Sidecars this run's build started (frog-apple, tang-llm) go with the test host; one still
# running a few seconds after the run, even one that was killed, is a leak: it would hold its
# port. Named and stopped, and the run fails. Only this build's own copies are looked at.
built="$PWD/build/test/"
sleep 5
leaked=$(ps -axo pid=,comm= | awk -v p="$built" 'index($2, p) == 1 && ($2 ~ /\/frog-apple$/ || $2 ~ /\/tang-llm$/) { print $1 " " $2 }')
if [[ -n "$leaked" ]]; then
    echo "test run left sidecars running (stopping them):"
    echo "$leaked"
    echo "$leaked" | awk '{ print $1 }' | xargs kill 2>/dev/null
    rc=1
fi

grep -aE "^Test Case .*(failed|exceeded execution time)" "$log"
grep -aE "^\s+Executed [0-9]+ tests?, with" "$log" | tail -1
grep -aE "^\*\* (TEST|BUILD) [A-Z ]+ \*\*" "$log" | tail -1
exit $rc
