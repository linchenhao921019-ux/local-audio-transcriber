#!/usr/bin/env python3
import argparse
import wave
from pathlib import Path

import av


def first_audio_stream(container):
    streams = list(container.streams.audio)
    if not streams:
        raise RuntimeError("文件中没有可转录的音频轨道。请确认选择的是含音频的 wav、mp3、mp4、mov 或 m4a 文件。")
    return streams[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    container = av.open(args.audio)
    stream = first_audio_stream(container)
    container.seek(int(args.start / stream.time_base), any_frame=False, backward=True, stream=stream)

    resampler = av.audio.resampler.AudioResampler(format="s16", layout="mono", rate=16000)
    start = args.start
    end = args.start + args.duration
    wrote_frames = 0

    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)

        for packet in container.demux(stream):
            try:
                decoded_frames = packet.decode()
            except av.error.FFmpegError:
                if wrote_frames > 0:
                    continue
                raise

            for frame in decoded_frames:
                if frame.pts is None:
                    continue
                frame_start = float(frame.pts * stream.time_base)
                frame_end = frame_start + float(frame.samples / frame.sample_rate)
                if frame_end < start:
                    continue
                if frame_start > end:
                    print(f"Wrote {wrote_frames / 16000:.1f}s to {output}")
                    return

                for out_frame in resampler.resample(frame):
                    wav.writeframes(out_frame.to_ndarray().tobytes())
                    wrote_frames += out_frame.samples

    print(f"Wrote {wrote_frames / 16000:.1f}s to {output}")


if __name__ == "__main__":
    main()
