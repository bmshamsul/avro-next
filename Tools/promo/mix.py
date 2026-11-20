#!/usr/bin/env python3
"""Soundtrack and final mux for the promo film.

Synthesises a soft key click for every key press in cues.json (no samples, so
nothing to license), mixes it under the narration, normalises loudness to
-16 LUFS (social video standard), muxes it into the picture, and writes an SRT
from the captions.

Usage: mix.py <script.json> <media dir>
"""
import json
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 48000


def click(rng: np.random.Generator) -> np.ndarray:
    """A short, soft keyboard tick: filtered noise burst plus a low thump."""
    n = int(0.035 * RATE)
    t = np.arange(n) / RATE
    noise = rng.standard_normal(n)
    # One-pole low-pass to take the hiss off.
    lp = np.empty(n)
    acc = 0.0
    for i, x in enumerate(noise):
        acc += 0.35 * (x - acc)
        lp[i] = acc
    env = np.exp(-t / 0.006)
    thump = np.sin(2 * np.pi * 180 * t) * np.exp(-t / 0.010)
    return (0.55 * lp * env + 0.45 * thump) * 0.9


def srt_time(s: float) -> str:
    ms = int(round(s * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def main() -> None:
    script = json.loads(Path(sys.argv[1]).read_text())
    media = Path(sys.argv[2])
    timing = json.loads((media / "timing.json").read_text())
    cues = json.loads((media / "cues.json").read_text())["keys"]

    total = int(timing["total"] * RATE) + RATE
    track = np.zeros(total)
    rng = np.random.default_rng(7)
    for t in cues:
        c = click(rng) * rng.uniform(0.75, 1.0)
        i = int(t * RATE)
        track[i:i + len(c)] += c[: max(0, total - i)]
    track *= 0.18   # well under the voice
    with wave.open(str(media / "clicks.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(track, -1, 1) * 32767).astype("<i2").tobytes())

    out = media / "avro-next-promo.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-v", "error",
        "-i", str(media / "video.mp4"), "-i", str(media / "narration.wav"), "-i", str(media / "clicks.wav"),
        "-filter_complex",
        "[1]aformat=channel_layouts=stereo[v];[2]aformat=channel_layouts=stereo[c];"
        "[v][c]amix=inputs=2:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[a]",
        "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
        "-shortest", "-movflags", "+faststart", str(out)], check=True)

    with open(media / "avro-next-promo.srt", "w") as f:
        for n, (line, t) in enumerate(zip(script["lines"], timing["lines"]), 1):
            f.write(f"{n}\n{srt_time(t['start'])} --> {srt_time(t['end'] + 0.3)}\n{line['caption']}\n\n")
    print(f"wrote {out} and {media / 'avro-next-promo.srt'} ({len(cues)} key clicks)")


if __name__ == "__main__":
    main()
