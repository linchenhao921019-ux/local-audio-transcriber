import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("knowledge_library", Path(__file__).resolve().parents[1] / "src/knowledge_library.py")
library = importlib.util.module_from_spec(spec)
spec.loader.exec_module(library)


class KnowledgeLibraryTests(unittest.TestCase):
    def test_explicit_publication_and_deduplication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "我的知识库"
            metadata = root / "元数据/LocalMind"
            metadata.mkdir(parents=True)
            (metadata / "projects-test.json").write_text(json.dumps({"schemaVersion": 1, "value": {"id": "p1", "name": "测试"}}))
            content = root / "内容/转录"
            content.mkdir(parents=True)
            report = content / "report.md"
            report.write_text("# 完整报告\n证据、分析与结论。", encoding="utf-8")
            self.assertFalse((root / "元数据/转录报告").exists())
            first = library.publish(root, report, "p1")
            self.assertEqual(first["reportPath"], "内容/转录/report.md")
            self.assertTrue(library.publish(root, report, "p1")["duplicate"])
            self.assertEqual(len(list((root / "元数据/转录报告").glob("*.json"))), 1)
            self.assertEqual(list(content.iterdir()), [report])
            with self.assertRaises(ValueError):
                library.publish(root, report, "missing")
            external = Path(temporary) / "报告.txt"
            external.write_text("另一个详细报告。", encoding="utf-8")
            published = library.publish(root, external, "p1")
            self.assertEqual(published["title"], "报告")
            self.assertTrue(published["reportPath"].startswith("内容/报告/"))
            video = Path(temporary) / "source.mp4"
            video.write_bytes(b"not a report")
            with self.assertRaises(ValueError):
                library.publish(root, video, "p1")


if __name__ == "__main__":
    unittest.main()
