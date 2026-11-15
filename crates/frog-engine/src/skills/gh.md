Use the GitHub CLI (`gh`) for pull requests, issues, checks and the API.

- Ask for JSON and pick fields: `gh pr list --json number,title,headRefName,statusCheckRollup,reviewDecision`. Run `gh pr list --json` with no fields to see the valid names; guessed ones (there is no `ciStatus`) fail.
- CI for one PR: `gh pr checks <n>`, or `gh pr view <n> --json statusCheckRollup`. Failing run logs: `gh run view <id> --log-failed`.
- Filter with `--jq`, e.g. `gh pr list --json number,title --jq '.[] | "\(.number) \(.title)"'`.
- Anything else: `gh api repos/{owner}/{repo}/...` (`{owner}`/`{repo}` fill in from the current repo).
- If `gh` says you're not logged in inside the sandbox, the user can export `GH_TOKEN` and allow `~/.config/gh` (see `[sandbox]` in frog's docs); don't retry unsandboxed just to read.
