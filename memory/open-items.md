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

- 01:2xZ update: frog-cloud-3 = 5972sc9ke6kh3d (US-GA-2) booting with keep-alive/health/metrics; mew targets.json seeded; old node deleted once published. zest#30 DEPLOYED and verified (pricing in /v1/models, request ids, /v1/generation).

- 01:3xZ: frog-cloud-3 live, the only node. Models: qwen3-coder-next 128k (245 tok/s), qwen3-8b 16k (117-194 tok/s), qwen3-vl-8b 16k (vision verified). Keep-alive, health and metrics live. Watch: KV for 8x128k is allocated on demand next to the 2 small models, so check for OOM under full load. Long agent runs are unblocked: start pond step 1.

- 2026-10-22 ~02:30Z: Cam turned RunPod off for the night. frog-cloud-3 (5972sc9ke6kh3d) is STOPPED (disk kept). frog cloud is down until restarted, and frog falls back to local. Morning: start the pod (or node-up.sh if no GPU), verify, then the FA2 swap (needs Cam go). frog#38 (CI git identity) is still unmerged; main CI is red.

- 2026-10-22 10:26Z: Claude credits nearly out, so work moves to frog. Created frog-cloud-4 (phd7liagvpatty, US-NC-1, $5.29/hr); the stopped frog-cloud-3 (5972sc9ke6kh3d) still needs deleting (ask Cam). bin/beat1-queue.sh runs frog workers once cloud is up: frog/public-scrub, frog/release-dryrun, zest/launch-surface. Logs are in logs/. Cam owns frog.toys DNS (does not resolve) and the Novita key. Beat 1 readiness: memory/beat1-readiness.md.

- 2026-10-22 ~13:00 ET: Cam chose frog cloud beta-cap option b + b0 with full deploy OK. b0 = move the agent tree's key to tier `api` (Cam does the KV writes). b = new `internal` tier (edge 64 streams/3000 rpm; router 64 streams, max_tokens 16384), branch zest/internal-tier @ a603e10. Steps: PR, merge, rebuild image, node replace, `wrangler deploy`, then Cam mints an internal key. Beta stays 2 streams/30 rpm/4096 max_tokens. Live node: frog-cloud-6 cpna1c5w9g1u1z (US-GA-2). cf-3 and cf-4 are already gone. The frog cloud manager is session 20261022-124854-02a0.
- 2026-10-22 ~14:20 ET: swap done. frog-cloud-7 (5uej5lixwna3o9, US-NC-1, image 0496e64) is the only node; cf-6 terminated (Cam OK'd it by id). Edge 37f8815e (rollback a0f3fc85). Our frog cloud key k_ecfe00bf53ac14b0 is now tier **internal** (64 streams/3000 rpm), verified via /me. Cam merged #35/#37/#31 himself. #31 launch surface deploy OK'd by Cam; with the frog cloud manager. #35/#37 go live at the next node rebuild. Disk incident: 3G → 16G after clearing idle build dirs.
