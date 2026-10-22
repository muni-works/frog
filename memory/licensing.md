---
name: licensing
description: "Cam's licensing decisions (2026-10-20) — MIT OR Apache-2.0 for open code, zest/tang-pro proprietary, CERN-OHL-W for hardware, DCO; open items punted"
metadata:
  node_type: memory
  type: project
  originSessionId: 8c3dcc85-ad81-4ab4-9e67-2dd50bec4698
  modified: 2026-10-21T00:46:58.950Z
---

Decided by Cam 2026-10-20 (clicked in chief-of-staff):
- Open code (tang + crates, frog, vcad, phyz, kosm, loon, muni software): **MIT OR Apache-2.0**. Contributions: **DCO sign-off**, no CLA.
- zest and tang-pro: **fully proprietary**.
- rose hardware designs (when public): **CERN-OHL-W**.
- Deferred: loon/kosm/muni are public with NO license file, and muni has 10 crates marked "Proprietary" — "leave until after launch". "No weapons" enforcement venue: punted. Trademarks: not now.

**Why:** principle 7 (open by default); the moat is zest, hardware and execution. The plan already accepts that open licenses can't restrict use.
**How to apply:** new public repos get dual-license files. Raise the loon/kosm/muni fix after the Oct 30 launch. Related: [[product-direction]], [[manager-structure]].

**GitHub org (Cam, 2026-10-21):** open-source repos go under the existing org **muni-works** (Cam is admin); frog goes public there as muni-works/frog (private repo created 2026-10-21) on Oct 29, as a fresh single-commit repo. A signed/notarized tang-llm Apple Silicon binary must be ready by Oct 26 for frog's quickstart, Apple: Cam enrolling Municipal Robotics as an ORG (D-U-N-S + verification); builds ship unsigned with bypass instructions until it clears.
