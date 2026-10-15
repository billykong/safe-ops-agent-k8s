"""Narrates each beat of scenes.js with Kokoro, a local TTS model.

    python tts.py OUT_DIR MODEL_DIR [VOICE]

Writes OUT_DIR/narration.wav (all beats, with pauses), OUT_DIR/timings.json
(each beat's duration, pause included, for render.js) and OUT_DIR/captions.srt
(the script as written, for YouTube). MODEL_DIR holds kokoro-v1.0.onnx and
voices-v1.0.bin (github.com/thewh1teagle/kokoro-onnx, model-files-v1.0).
"""
import json
import os
import shutil
import subprocess
import sys

import numpy as np
import soundfile as sf
import espeakng_loader
from kokoro_onnx import Kokoro
from kokoro_onnx.config import EspeakConfig

HERE = os.path.dirname(os.path.abspath(__file__))
PAUSE_BEAT, PAUSE_SCENE = 0.35, 0.9
SPEED = 1.05

# How to say what the voice would otherwise misread. Captions keep the
# script's own spelling.
SAY = {
    "INC-1001": "incident ten oh one",
    "gVisor": "G-visor",
    "RBAC": "R-back",
    "OPA": "O-P-A",
    "PyPI": "pie P I",
    "MCP": "M-C-P",
    "LLM": "L-L-M",
    "API": "A-P-I",
    "ChangeRequest": "change request",
    "OpenTelemetry": "open telemetry",
    "syscall-heavy": "system-call heavy",
    "red-team": "red team",
    "CI ": "C-I ",
}


def spoken(text):
    for k, v in SAY.items():
        text = text.replace(k, v)
    return text.replace("’", "'").replace("“", '"').replace("”", '"')


def srt_time(t):
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def espeak_data():
    """libespeak-ng truncates its data path at 160 bytes, and a venv's path
    can be longer (it then reads the wrong directory, or its build machine's
    default). Copy the data somewhere short; phonemizer resolves symlinks,
    so a link won't do."""
    src = espeakng_loader.get_data_path()
    if len(src) < 150:
        return src
    dst = os.path.expanduser("~/.cache/safe-ops-video/espeak-ng-data")
    if not os.path.exists(os.path.join(dst, "phontab")):
        shutil.copytree(src, dst, dirs_exist_ok=True)
    return dst


def main(out, models, voice="am_michael"):
    scenes = json.loads(subprocess.check_output(
        ["node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1]).scenes))", os.path.join(HERE, "scenes.js")]))
    k = Kokoro(os.path.join(models, "kokoro-v1.0.onnx"), os.path.join(models, "voices-v1.0.bin"),
               espeak_config=EspeakConfig(data_path=espeak_data()))
    lang = "en-us" if voice.startswith("a") else "en-gb"
    os.makedirs(out, exist_ok=True)
    audio, timings, captions, t = [], {}, [], 0.0
    sr = 24000
    for sc in scenes:
        for i, b in enumerate(sc["beats"]):
            samples, sr = k.create(spoken(b["say"]), voice=voice, speed=SPEED, lang=lang)
            pause = PAUSE_SCENE if i == len(sc["beats"]) - 1 else PAUSE_BEAT
            audio += [samples, np.zeros(int(sr * pause), dtype=samples.dtype)]
            dur = len(samples) / sr
            captions.append((t, t + dur, b["say"]))
            timings[f"{sc['id']}-{i}"] = dur + pause
            t += dur + pause
            print(f"{sc['id']}-{i}: {dur:.1f}s", flush=True)
    sf.write(os.path.join(out, "narration.wav"), np.concatenate(audio), sr)
    with open(os.path.join(out, "timings.json"), "w") as f:
        json.dump(timings, f, indent=1)
    with open(os.path.join(out, "captions.srt"), "w") as f:
        for n, (a, z, s) in enumerate(captions, 1):
            f.write(f"{n}\n{srt_time(a)} --> {srt_time(z)}\n{s}\n\n")
    print(f"total {t / 60:.1f} min")


if __name__ == "__main__":
    main(*sys.argv[1:])
