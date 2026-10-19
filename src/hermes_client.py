#!/usr/bin/env python3
"""Invoke the installed Hermes CLI without inheriting the bundled Python runtime."""
from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def resolve_hermes(command: str | None = None) -> str:
    override = command or os.environ.get("HERMES_COMMAND")
    candidates = [override] if override else [
        str(Path.home() / ".local/bin/hermes"),
        str(Path.home() / ".hermes/hermes-agent/.hermes/bin/hermes"),
        shutil.which("hermes"),
        "/opt/homebrew/bin/hermes",
        "/usr/local/bin/hermes",
    ]
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate).expanduser()
        if not path.is_absolute():
            found = shutil.which(str(path))
            if not found:
                continue
            path = Path(found)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise RuntimeError("未找到可执行的 Hermes。请安装本机 Hermes，或选择正确的 Hermes 程序路径。")


def hermes_environment() -> dict[str, str]:
    env = os.environ.copy()
    for name in ("PYTHONHOME", "PYTHONPATH", "PYTHONNOUSERSITE", "VIRTUAL_ENV"):
        env.pop(name, None)
    paths = [str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
             "/usr/bin", "/bin", "/usr/sbin", "/sbin", env.get("PATH", "")]
    env["PATH"] = os.pathsep.join(paths)
    env["PYTHONUTF8"] = "1"
    env["NO_COLOR"] = "1"
    return env


def check_hermes(command: str | None = None) -> str:
    executable = resolve_hermes(command)
    try:
        result = subprocess.run([executable, "chat", "--help"], env=hermes_environment(),
                                capture_output=True, text=True, encoding="utf-8", timeout=25)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Hermes 启动检测失败：{exc}") from exc
    if result.returncode or not all(flag in result.stdout for flag in ("--query-file", "stream-json", "--source")):
        raise RuntimeError("Hermes 未正常启动或版本过旧，请先在终端修复或升级 Hermes。")
    return executable


class HermesClient:
    def __init__(self, command: str | None = None, timeout: float = 900):
        self.command = resolve_hermes(command)
        self.timeout = timeout
        self.model = "Hermes 当前配置"
        self.process: subprocess.Popen | None = None

    def cancel(self) -> None:
        process = self.process
        if process is None:
            return
        if process.poll() is not None:
            self.process = None
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            if process.poll() is None:
                process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        self.process = None

    def generate(self, prompt: str) -> str:
        # Keep source recordings out of argv and avoid shell interpretation of their contents.
        with tempfile.TemporaryDirectory(prefix="transcriber-hermes-") as temp:
            prompt_path = Path(temp) / "query.txt"
            prompt_path.touch(mode=0o600)
            prompt_path.write_text(prompt, encoding="utf-8")
            with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as errors:
                command = [self.command, "--ignore-rules", "chat", "--query-file", str(prompt_path),
                           "--format", "stream-json", "--toolsets", "context_engine",
                           "--source", "tool", "--max-turns", "1", "--run-budget", str(self.timeout)]
                events: queue.Queue[str | None] = queue.Queue()
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=errors, text=True, encoding="utf-8", errors="replace",
                                           env=hermes_environment(), cwd=temp, start_new_session=True)
                self.process = process

                def read_events():
                    try:
                        for line in process.stdout:
                            events.put(line)
                    finally:
                        events.put(None)

                reader = threading.Thread(target=read_events, daemon=True)
                reader.start()
                deadline = time.monotonic() + self.timeout
                result = None
                generated_chars = 0
                reported_chars = 0
                try:
                    while result is None:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise RuntimeError(f"Hermes 纪要生成超时（{self.timeout:g} 秒），转录文本已保留，可稍后重试。")
                        try:
                            line = events.get(timeout=min(remaining, 1))
                        except queue.Empty:
                            continue
                        if line is None:
                            break
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(event, dict):
                            continue
                        if event.get("type") == "system" and event.get("model"):
                            self.model = str(event["model"])
                            print(f"Hermes 模型：{self.model}", flush=True)
                        if event.get("type") == "text" and isinstance(event.get("text"), str):
                            generated_chars += len(event["text"])
                            if generated_chars - reported_chars >= 500:
                                print(f"Hermes 已生成 {generated_chars} 字...", flush=True)
                                reported_chars = generated_chars
                        if event.get("type") == "result":
                            result = event
                    if result is None:
                        errors.seek(0)
                        detail = errors.read()[-1800:].strip()
                        raise RuntimeError(f"Hermes 未返回完整结果。请检查 Hermes 的模型与登录配置。\n{detail}")
                    if result.get("exit_code") != 0 or result.get("error"):
                        raise RuntimeError(f"Hermes 生成失败：{result.get('error') or result.get('text') or result.get('exit_code')}")
                    response = result.get("text")
                    if not isinstance(response, str) or not response.strip():
                        raise RuntimeError("Hermes 返回了空内容，未生成纪要。")
                    # Hermes may linger on exit; the terminal result is the completion contract.
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
                    if process.poll() not in (None, 0):
                        raise RuntimeError(f"Hermes 异常退出，退出码 {process.returncode}。")
                    return response.strip()
                finally:
                    self.cancel()
                    reader.join(timeout=2)
                    process.stdout.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Check the installed Hermes integration.")
    parser.add_argument("--check", action="store_true", required=True)
    parser.add_argument("--hermes-command")
    args = parser.parse_args()
    try:
        path = check_hermes(args.hermes_command)
    except RuntimeError as exc:
        parser.exit(1, f"{exc}\n")
    print(json.dumps({"command": path, "status": "ready"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
