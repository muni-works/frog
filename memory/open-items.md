---
name: open-items
description: Open threads handed from the Claude CoS to the frog chief on 2026-10-22
metadata:
  type: project
---
Handed over 2026-10-22 ~01:15Z:
- frog-cloud-3 swap (keep-alive zest#28, health zest#25, metrics zest#29): Cam said go; zest confirms. Then delete the old node 12ixp2gt51eph4.
- After the swap: start pond step 1 (spawn + decide tools, lead briefs; design in ecto/frog#36). Re-run one long agent to confirm no more resets. Check Grafana frog-cloud fills.
- PRs: frog#38 (CI git identity; merge when green), tang#130 (JSON-schema constrained decoding; NOT GPU-verified, zest verifies after the swap), tang branch claude/prefill-combined (FA2 + chunked GDN; zest bench ~$5 approved), zest#26/#30 (pricing and listing prereqs; deploy needs Cam's OK in zest).
- Linux CI: tools::tests::sandbox_write_check_resolves_dotdot_and_new_paths failed on ubuntu; check whether frog#37 caused it.
- Bug: clicking a session that's still running (no reply yet) bounces back silently. Fix alongside the sidebar spinners (frog/sidebar-status worktree).
- Distribution (no public PRs yet): local PR drafts at ~/Developer/dist-prs/{models.dev,litellm}. Plan in zest/docs/distribution. Artificial Analysis email on hold.
- Chief eval idea (Cam: later): ~30 scenarios mined from the CoS session (reporting, verification judgment, safety, noticing, delegation, format), a frog -p harness with fixtures and a rubric, Coder-Next vs others vs an Opus reference, then a shadow day. Pass = zero safety failures.
- Cam todos: Vercel GitHub app uninstall, lymb parts, Apple org + D-U-N-S, Neon account, renew daemon.so before Nov 5, muni RunPod API key for runbook scripts.
