# The capstone video

A narrated video of the capstone, [Defence in depth for autonomous infrastructure agents](https://billykong.github.io/2026/10/15/defence-in-depth-for-autonomous-infrastructure-agents.html): one task traced through the eight layers, with real output from the cluster. Published at https://youtu.be/pDVeg_Gb_i8. About 8 and a half minutes, 1920x1080, in the style of the post's thumbnail.

```bash
video/build.sh            # writes video/out/capstone.mp4, captions.srt and thumbnail.png
```

The first run installs its tools under `video/out/tools` (resvg-js and ffmpeg-static from npm, [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) in a uv venv, and Kokoro's model files, about 350 MB). Nothing needs a GPU or a network service after that. `VOICE=bm_george video/build.sh` picks another Kokoro voice.

| File | What it is |
| --- | --- |
| `scenes.js` | The script: each beat's narration and what's on screen |
| `captures/` | Real output from the cluster, trimmed to fit the screen |
| `tts.py` | Narrates each beat; writes the timings and YouTube captions |
| `render.js` | Draws each frame (SVG, rendered with resvg) and times them to the narration |
| `build.sh` | Runs the three and muxes the MP4 with ffmpeg |
| `description.md` | The YouTube title, description and disclosure |

## Editing

Change the words in `scenes.js` and rebuild: each beat is narrated on its own, so the screen always changes when the voice moves on. Keep the script saying what the post says, and check any new claim against the repo. `tts.py` has a table of spellings for words the voice misreads (gVisor, RBAC, OPA, PyPI); the captions keep the script's own spelling.

## The captures

Recorded on 2026-10-14 from the lab cluster, at commit `1e3a4b3`:

- `approval.txt`: `scripts/agent-task.sh` with incident INC-1001 (the mock model), `approvalctl show` and `approvalctl approve` as a certificate-authenticated approver. The `show` output was printed again after the approval, with its `decision` line removed so it reads as it did before.
- `kill-switch.txt`: `scripts/eval-kill-switch.sh`, the drill CI runs; the eval-gate table in the middle is left out.
- `red-team.txt`: `scripts/red-team.sh`, one result line per attack.

Lines are trimmed, never edited. A capture is replayed line by line at the narration's pace, not in real time. `#@ name` lines mark where a beat's reveal stops.
