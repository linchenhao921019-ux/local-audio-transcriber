import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))
from hermes_client import HermesClient, check_hermes, hermes_environment, resolve_hermes
from hermes_meeting_minutes import split_text
from docx import Document


class HermesIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Hermes integration ")
        self.root = Path(self.temp.name)
        self.command = self.root / "hermes test"

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, body):
        self.command.write_text(f"#!{sys.executable}\n" +
                                "import json, os, sys, time\nfrom pathlib import Path\n" + body,
                                encoding="utf-8")
        self.command.chmod(0o755)
        return str(self.command)

    def test_resolve_and_check(self):
        command = self.fake('print("--query-file --format stream-json --source")\n')
        self.assertEqual(check_hermes(command), command)
        with self.assertRaises(RuntimeError):
            resolve_hermes(str(self.root / "missing"))

    def test_bundled_python_environment_is_removed(self):
        with patch.dict(os.environ, {"PYTHONHOME": "/bundle", "PYTHONPATH": "/bundle/site", "VIRTUAL_ENV": "/bundle"}):
            env = hermes_environment()
        self.assertNotIn("PYTHONHOME", env)
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("VIRTUAL_ENV", env)
        self.assertIn("/.local/bin", env["PATH"])

    def test_reads_only_terminal_result_and_preserves_literal_prompt(self):
        prompt = '录音包含 $(touch /tmp/not-run) 和 `echo hello`，不要解释为命令。'
        command = self.fake(
            'query = Path(sys.argv[sys.argv.index("--query-file") + 1]).read_text()\n'
            'assert "--source" in sys.argv and "context_engine" in sys.argv\n'
            'print("startup diagnostic", flush=True)\n'
            'print(json.dumps({"type":"system", "model":"test-model"}), flush=True)\n'
            'print(json.dumps({"type":"text", "text":"not the final result"}), flush=True)\n'
            'print(json.dumps({"type":"result", "exit_code":0, "text":query}), flush=True)\n')
        client = HermesClient(command, timeout=5)
        self.assertEqual(client.generate(prompt), prompt)
        self.assertEqual(client.model, "test-model")

    def test_failure_and_empty_output_are_not_success(self):
        for result in ({"exit_code": 1, "error": "login required"},
                       {"exit_code": 0, "text": ""},
                       {"text": "missing exit status"}):
            with self.subTest(result=result):
                command = self.fake(f'print(json.dumps({dict(type="result", **result)!r}), flush=True)\n')
                with self.assertRaises(RuntimeError):
                    HermesClient(command, timeout=5).generate("test")

    def test_missing_result_is_not_success(self):
        with self.assertRaisesRegex(RuntimeError, "未返回完整结果"):
            HermesClient(self.fake('print("no result")\n'), timeout=5).generate("test")

    def test_timeout_reaps_child(self):
        pid_file = self.root / "pid"
        command = self.fake(f'Path({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n')
        with self.assertRaisesRegex(RuntimeError, "超时"):
            HermesClient(command, timeout=0.5).generate("test")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    def test_cancel_script_terminates_hermes(self):
        pid_file = self.root / "pid"
        command = self.fake(
            'if "--help" in sys.argv:\n    print("--query-file stream-json --source")\n    sys.exit(0)\n'
            f'Path({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n')
        transcript = self.root / "transcript.txt"
        transcript.write_text("[00:00:00 - 00:00:10] 今天讨论上线计划。", encoding="utf-8")
        process = subprocess.Popen([sys.executable, str(SRC / "hermes_meeting_minutes.py"),
                                    "--transcript", str(transcript), "--output-dir", str(self.root),
                                    "--hermes-command", command], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid_file.exists())
            process.terminate()
            process.wait(timeout=5)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_long_line_is_split(self):
        chunks = split_text("测" * 120, 50)
        self.assertEqual("".join(chunks), "测" * 120)
        self.assertTrue(all(len(c) <= 50 for c in chunks))

    def test_chunked_pipeline_writes_markdown_and_word(self):
        counter = self.root / "calls"
        command = self.fake(
            'if "--help" in sys.argv:\n    print("--query-file stream-json --source")\n    sys.exit(0)\n'
            f'counter = Path({str(counter)!r})\n'
            'counter.write_text(str(int(counter.read_text()) + 1) if counter.exists() else "1")\n'
            'print(json.dumps({"type":"system", "model":"test-model"}), flush=True)\n'
            'print(json.dumps({"type":"result", "exit_code":0, "text":"# 测试纪要\\n\\n## 核心摘要\\n- 周五完成上线。"}), flush=True)\n')
        transcript = self.root / "transcript.txt"
        transcript.write_text("[00:00:00 - 00:00:10] 周五完成上线。\n" * 4, encoding="utf-8")
        result = subprocess.run([sys.executable, str(SRC / "hermes_meeting_minutes.py"),
                                 "--transcript", str(transcript), "--output-dir", str(self.root),
                                 "--hermes-command", command, "--chunk-chars", "65"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(int(counter.read_text()), 1)
        markdown = next(self.root.glob("*.md")).read_text(encoding="utf-8")
        self.assertIn("周五完成上线", markdown)
        document = Document(next(self.root.glob("*.docx")))
        text = "\n".join(p.text for p in document.paragraphs)
        self.assertIn("Hermes 模型：test-model", text)
        self.assertNotIn("Ollama", text)


if __name__ == "__main__":
    unittest.main()
