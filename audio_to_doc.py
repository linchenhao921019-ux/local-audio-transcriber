#!/usr/bin/env python3
import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description="Transcribe an audio file and build Markdown/DOCX documents.")
    parser.add_argument("audio")
    parser.add_argument("--title", default=None)
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--chunk-seconds", type=float, default=60)
    parser.add_argument("--duration", type=float, default=None, help="Optional test limit in seconds.")
    parser.add_argument("--skip-transcribe", action="store_true", help="Use an existing transcript in the output directory.")
    args = parser.parse_args()

    audio = Path(args.audio).expanduser().resolve()
    if not audio.exists():
        raise FileNotFoundError(audio)

    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else SCRIPT_DIR / "outputs" / audio.stem
    chunks_dir = output_dir / "chunks"
    transcript = output_dir / f"{audio.stem}_transcript.txt"
    output_dir.mkdir(parents=True, exist_ok=True)

    if not args.skip_transcribe:
        cmd = [
            sys.executable,
            str(SCRIPT_DIR / "transcribe_funasr_chunks.py"),
            str(audio),
            "--output",
            str(transcript),
            "--chunks-dir",
            str(chunks_dir),
            "--chunk-seconds",
            str(args.chunk_seconds),
        ]
        if args.duration is not None:
            cmd.extend(["--duration", str(args.duration)])
        subprocess.run(cmd, check=True)
    elif not transcript.exists():
        raise FileNotFoundError(f"Missing transcript for --skip-transcribe: {transcript}")

    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "build_transcript_doc.py"),
        str(audio),
        "--transcript",
        str(transcript),
        "--output-dir",
        str(output_dir),
    ]
    if args.title:
        cmd.extend(["--title", args.title])
    subprocess.run(cmd, check=True)

    print("\nDone.")
    print(f"Output directory: {output_dir}")
    print(f"Transcript: {transcript}")
    print(f"Markdown: {output_dir / (audio.stem + '_转录文档.md')}")
    print(f"Word document: {output_dir / (audio.stem + '_转录文档.docx')}")


if __name__ == "__main__":
    main()
