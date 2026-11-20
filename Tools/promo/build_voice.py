#!/usr/bin/env python3
"""Scratch narration for the promo video.

Records every line of script.json with macOS `say`, measures it, and lays the
lines out on one track with short pauses between them. Writes
<out>/timing.json (start/end of each line, in seconds) and <out>/narration.wav.
The renderer reads timing.json, so a new voice re-times the whole film.

Usage: build_voice.py <script.json> <out dir> [--voice NAME] [--rate WPM]
"""
import argparse
import json
import subprocess
from pathlib import Path

LEAD_IN = 0.8      # silence before the first line
GAP = 0.45         # pause between lines
TAIL = 2.5         # hold after the last line (end card)
RATE_HZ = 48000


def duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("out")
    ap.add_argument("--voice")
    ap.add_argument("--rate", type=int)
    args = ap.parse_args()

    script = json.loads(Path(args.script).read_text())
    voice = args.voice or script.get("voice", "Samantha")
    rate = args.rate or script.get("rate", 175)
    out = Path(args.out)
    lines_dir = out / "lines"
    lines_dir.mkdir(parents=True, exist_ok=True)

    timing, t, parts = [], LEAD_IN, []
    for i, line in enumerate(script["lines"]):
        aiff = lines_dir / f"{i:02d}-{line['id']}.aiff"
        wav = lines_dir / f"{i:02d}-{line['id']}.wav"
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(aiff), line["spoken"]], check=True)
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(aiff), "-ar", str(RATE_HZ), "-ac", "1", str(wav)],
                       check=True)
        d = duration(wav)
        timing.append({"id": line["id"], "start": round(t, 3), "end": round(t + d, 3)})
        parts.append((wav, t))
        t += d + GAP + float(line.get("hold", 0))   # hold: let a demo play out
    total = timing[-1]["end"] + TAIL

    # Place every line at its start time on one silent track.
    cmd = ["ffmpeg", "-y", "-v", "error"]
    for wav, _ in parts:
        cmd += ["-i", str(wav)]
    delays = "".join(f"[{i}]adelay={int(start * 1000)}[d{i}];" for i, (_, start) in enumerate(parts))
    mix = "".join(f"[d{i}]" for i in range(len(parts)))
    cmd += ["-filter_complex",
            f"{delays}{mix}amix=inputs={len(parts)}:normalize=0,apad=whole_dur={total}[a]",
            "-map", "[a]", "-ar", str(RATE_HZ), "-ac", "1", str(out / "narration.wav")]
    subprocess.run(cmd, check=True)

    (out / "timing.json").write_text(json.dumps({"total": round(total, 3), "lines": timing}, indent=2))
    print(f"{len(timing)} lines, {total:.1f} s, voice {voice} at {rate} wpm")
    for line in timing:
        print(f"  {line['start']:6.2f}-{line['end']:6.2f}  {line['id']}")


if __name__ == "__main__":
    main()
