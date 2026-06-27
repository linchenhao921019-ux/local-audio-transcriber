#!/usr/bin/env python3
import argparse
import logging
import subprocess
import sys
import warnings
import wave
from pathlib import Path

import av

warnings.filterwarnings("ignore", message="pkg_resources is deprecated as an API.*")
logging.getLogger("jieba").setLevel(logging.WARNING)

from funasr_onnx import CT_Transformer, Paraformer

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL_DIR = SCRIPT_DIR / "modelscope_cache" / "iic" / "speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-onnx"
DEFAULT_PUNC_MODEL_DIR = SCRIPT_DIR / "modelscope_cache" / "damo" / "punc_ct-transformer_cn-en-common-vocab471067-large-onnx"
SENTENCE_ENDINGS = "。！？!?；;"


def first_audio_stream(container):
    streams = list(container.streams.audio)
    if not streams:
        raise RuntimeError("文件中没有可转录的音频轨道。请确认选择的是含音频的 wav、mp3、mp4、mov 或 m4a 文件。")
    return streams[0]


def fmt_time(seconds: float) -> str:
    total = int(round(seconds))
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def audio_duration(audio: str) -> float:
    with av.open(audio) as container:
        if container.duration is not None:
            return float(container.duration / av.time_base)

        stream = first_audio_stream(container)
        if stream.duration is not None:
            return float(stream.duration * stream.time_base)

    raise RuntimeError("Could not determine audio duration; pass --duration explicitly.")


def wav_duration(path: Path) -> float:
    try:
        with wave.open(str(path), "rb") as wav:
            if wav.getframerate() <= 0:
                return 0.0
            return wav.getnframes() / wav.getframerate()
    except Exception:
        return 0.0


def fallback_punctuate(text: str) -> str:
    text = text.strip()
    if not text:
        return text
    if text[-1] in "。！？!?":
        return text

    pieces = []
    start = 0
    soft_breaks = "然后但是所以因为如果就是那么这个那个同时另外而且不过以及并且"
    for idx, char in enumerate(text, start=1):
        if idx - start >= 28:
            pieces.append(text[start:idx])
            start = idx
        elif idx - start >= 14:
            tail = text[max(start, idx - 4):idx]
            if any(tail.endswith(word[-min(len(word), 4):]) for word in soft_breaks):
                pieces.append(text[start:idx])
                start = idx
    if start < len(text):
        pieces.append(text[start:])

    if len(pieces) == 1:
        return pieces[0] + "。"
    return "，".join(piece for piece in pieces if piece) + "。"


def load_punc_model(model_dir: Path):
    if not (model_dir / "model_quant.onnx").exists() and not (model_dir / "model.onnx").exists():
        print(f"未找到本地标点模型，使用基础标点规则：{model_dir}", flush=True)
        return None
    try:
        try:
            import jieba
            jieba.setLogLevel(logging.WARNING)
        except Exception:
            pass
        logging.getLogger("jieba").setLevel(logging.WARNING)
        print("正在加载中文标点模型...", flush=True)
        return CT_Transformer(str(model_dir), batch_size=1, quantize=(model_dir / "model_quant.onnx").exists())
    except Exception as exc:
        print(f"中文标点模型加载失败，使用基础标点规则：{exc}", flush=True)
        return None


def punctuate_text(text: str, punc_model) -> str:
    text = text.strip()
    if not text:
        return text
    if text[-1] in SENTENCE_ENDINGS and any(mark in text for mark in "，。！？"):
        return text
    if punc_model is None:
        return fallback_punctuate(text)
    try:
        punctuated, _ = punc_model(text)
        return punctuated.strip() or fallback_punctuate(text)
    except Exception as exc:
        print(f"标点恢复失败，使用基础标点规则：{exc}", flush=True)
        return fallback_punctuate(text)


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe a long Chinese recording with local FunASR ONNX.")
    parser.add_argument("audio")
    parser.add_argument("--model-dir", default=str(DEFAULT_MODEL_DIR))
    parser.add_argument("--punc-model-dir", default=str(DEFAULT_PUNC_MODEL_DIR))
    parser.add_argument("--no-punctuation", action="store_true")
    parser.add_argument("--output", default=None)
    parser.add_argument("--chunks-dir", default=None)
    parser.add_argument("--duration", type=float, default=None)
    parser.add_argument("--chunk-seconds", type=float, default=180)
    args = parser.parse_args()

    audio = Path(args.audio).expanduser().resolve()
    output = Path(args.output).expanduser() if args.output else SCRIPT_DIR / f"{audio.stem}_funasr_transcript.txt"
    chunks_dir = Path(args.chunks_dir).expanduser() if args.chunks_dir else SCRIPT_DIR / "chunks" / audio.stem
    model_dir = Path(args.model_dir).expanduser()
    punc_model_dir = Path(args.punc_model_dir).expanduser()
    duration = args.duration if args.duration is not None else audio_duration(str(audio))
    make_clip = SCRIPT_DIR / "make_clip.py"

    output.parent.mkdir(parents=True, exist_ok=True)
    chunks_dir.mkdir(parents=True, exist_ok=True)

    model = Paraformer(str(model_dir), batch_size=1, quantize=True)
    punc_model = None if args.no_punctuation else load_punc_model(punc_model_dir)

    with output.open("w", encoding="utf-8") as f:
        f.write("# FunASR Paraformer transcription with Chinese punctuation\n\n")
        start = 0.0
        idx = 0
        while start < duration:
            length = min(args.chunk_seconds, duration - start)
            if length < 0.5:
                break
            chunk_path = chunks_dir / f"chunk_{idx:03d}_{int(start):05d}.wav"
            if not chunk_path.exists():
                subprocess.run(
                    [
                        sys.executable,
                        str(make_clip),
                        str(audio),
                        "--start",
                        str(start),
                        "--duration",
                        str(length),
                        "--output",
                        str(chunk_path),
                    ],
                    check=True,
                )
            actual_length = wav_duration(chunk_path)
            if actual_length < 0.5:
                break
            result = model(str(chunk_path))
            text = ""
            if result and isinstance(result[0], dict):
                preds = result[0].get("preds", "")
                text = preds[0] if isinstance(preds, tuple) else str(preds)
            text = text.strip()
            text = punctuate_text(text, punc_model)
            line = f"[{fmt_time(start)} - {fmt_time(start + length)}] {text}"
            print(line, flush=True)
            f.write(line + "\n")
            start += args.chunk_seconds
            idx += 1

    print(f"\nSaved transcript to {output}", flush=True)


if __name__ == "__main__":
    main()
