#!/usr/bin/env python3
import site
import sysconfig
from pathlib import Path


def main() -> None:
    candidates = [Path(p) / "funasr_onnx" / "__init__.py" for p in site.getsitepackages()]
    purelib = sysconfig.get_paths().get("purelib")
    if purelib:
        candidates.append(Path(purelib) / "funasr_onnx" / "__init__.py")
    init_path = next((p for p in candidates if p.exists()), None)
    if init_path is None:
        raise FileNotFoundError("Could not find funasr_onnx/__init__.py")
    text = init_path.read_text(encoding="utf-8")
    target = "from .sensevoice_bin import SenseVoiceSmall"
    replacement = (
        "# SenseVoiceSmall imports torch. This local app uses Paraformer/VAD/Punc "
        "ONNX only, so keep startup lightweight.\\n"
        "# from .sensevoice_bin import SenseVoiceSmall"
    )
    if target in text:
        init_path.write_text(text.replace(target, replacement), encoding="utf-8")
        print(f"Patched {init_path}")
    else:
        print(f"No patch needed for {init_path}")


if __name__ == "__main__":
    main()
