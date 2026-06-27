#!/usr/bin/env python3
import argparse
from pathlib import Path

from faster_whisper import WhisperModel


def fmt_time(seconds: float) -> str:
    total = int(round(seconds))
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--model", default="small")
    parser.add_argument("--output", required=True)
    parser.add_argument("--clip", default=None, help="Example: 0,180")
    parser.add_argument("--beam-size", type=int, default=5)
    parser.add_argument("--compute-type", default="int8")
    args = parser.parse_args()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    model = WhisperModel(args.model, device="cpu", compute_type=args.compute_type)
    segments, info = model.transcribe(
        args.audio,
        language="zh",
        task="transcribe",
        beam_size=args.beam_size,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 700},
        clip_timestamps=args.clip or "0",
        initial_prompt="中文会议、访谈或沟通录音，请尽量保留人名、时间、地点、事项和结论。",
        log_progress=True,
      )

    with output.open("w", encoding="utf-8") as f:
        f.write(f"# Transcription\n")
        f.write(f"language={info.language} probability={info.language_probability:.3f}\n\n")
        for segment in segments:
            text = segment.text.strip()
            if not text:
                continue
            line = f"[{fmt_time(segment.start)} - {fmt_time(segment.end)}] {text}"
            print(line, flush=True)
            f.write(line + "\n")


if __name__ == "__main__":
    main()
