# YouTube upload

**Title:** Defence in depth for autonomous infrastructure agents (Kubernetes)

**Thumbnail:** `out/thumbnail.png`, the title frame at 1280x720 (the capstone card's design).

**Altered or synthetic content:** Yes. The narration is an AI voice; nothing shown is generated footage.

**Chapters:** the times below come from `out/timings.json`; update them if the script changes.

**Captions:** upload `out/captions.srt` (English) rather than relying on auto-captions.

## Description

How do you let an AI agent investigate and fix infrastructure without trusting it? This video follows one task through eight layers of a working Kubernetes implementation: for each, what it stops, how that's proven, and what it doesn't stop.

00:00 The problem
00:49 Three rules and one assumption
01:29 The architecture
01:59 Layers 1-4: identity, sandbox, gateways, typed actions
04:31 Layer 5: the approval gate, on the cluster
05:43 Layers 6-8: the record, the kill switch drill, evals
07:01 Does it hold? The red-team
07:32 Costs, limits and the short version

Code, tests and the ten known gaps (MIT): https://github.com/billykong/safe-ops-agent-k8s
The full write-up: https://billykong.github.io/2026/10/21/defence-in-depth-for-autonomous-infrastructure-agents.html

How this video was made: the script was drafted with AI (Claude) from the write-up, then checked and edited by me; the narration is an AI voice (Kokoro, running locally); the slides are generated from code. All terminal output is real, recorded from runs on the lab cluster, replayed at the narration's pace. The model in the demos is the project's mock model, which obeys every instruction it reads.
