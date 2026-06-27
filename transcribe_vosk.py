#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import av
from vosk import KaldiRecognizer, Model, SetLogLevel


def fmt_time(seconds: float) -> str:
    total = int(round(seconds))
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def write_result(f, result: dict) -> None:
    text = result.get("text", "").strip()
    if not text:
        return
    words = result.get("result") or []
    if words:
        start = words[0].get("start", 0.0)
        end = words[-1].get("end", start)
    else:
        start = result.get("start", 0.0)
        end = result.get("end", start)
    line = f"[{fmt_time(start)} - {fmt_time(end)}] {text}"
    print(line, flush=True)
    f.write(line + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-seconds", type=float, default=None)
    args = parser.parse_args()

    SetLogLevel(-1)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    model = Model(args.model)
    recognizer = KaldiRecognizer(model, 16000)
    recognizer.SetWords(True)

    container = av.open(args.audio)
    stream = container.streams.audio[0]
    resampler = av.audio.resampler.AudioResampler(format="s16", layout="mono", rate=16000)

    with output.open("w", encoding="utf-8") as f:
        f.write("# Vosk transcription\n\n")
        for packet in container.demux(stream):
            for frame in packet.decode():
                if args.max_seconds is not None and frame.pts is not None:
                    if float(frame.pts * stream.time_base) > args.max_seconds:
                        write_result(f, json.loads(recognizer.FinalResult()))
                        return
                for out_frame in resampler.resample(frame):
                    audio_bytes = out_frame.to_ndarray().tobytes()
                    if recognizer.AcceptWaveform(audio_bytes):
                        write_result(f, json.loads(recognizer.Result()))
        write_result(f, json.loads(recognizer.FinalResult()))


if __name__ == "__main__":
    main()
