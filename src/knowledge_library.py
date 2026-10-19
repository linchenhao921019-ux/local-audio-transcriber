"""Explicit, portable report publication. Never copies source audio or video."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timezone


def atomic_json(destination, value):
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=destination.parent, suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def projects(root):
    result = {}
    records = list((root / "元数据" / "LocalMind").glob("projects-*.json"))
    for file in records:
        if "sync-conflict" in file.name:
            continue
        record = json.loads(file.read_text(encoding="utf-8"))
        if record.get("schemaVersion") == 1 and record.get("value"):
            project = record["value"]
            result[project["id"]] = project
    if not records:
        state_file = root / ".derived" / "localmind" / "library.json"
        if state_file.exists():
            result = {p["id"]: p for p in json.loads(state_file.read_text())["projects"]}
    return list(result.values())


def publish(root, report, project_id):
    root = root.resolve(strict=True)
    if not any(p["id"] == project_id for p in projects(root)):
        raise ValueError("所选项目库不存在，请先打开本机知识库网站并等待同步完成。")
    report = report.resolve(strict=True)
    original_title = report.stem
    if report.suffix.lower() not in (".md", ".txt"):
        raise ValueError("请选择 Markdown 或 TXT 报告；Word 报告请使用同时生成的 Markdown 文件。")
    body = report.read_bytes()
    text = body.decode("utf-8-sig")
    if not text.strip() or len(body) > 20 * 1024 * 1024:
        raise ValueError("报告为空或超过 20MB。")
    content_hash = hashlib.sha256(body).hexdigest()
    publication_id = hashlib.sha256((project_id + "\0" + content_hash).encode()).hexdigest()
    receipt_path = root / "元数据" / "转录报告" / (publication_id + ".json")
    if receipt_path.exists():
        return {**json.loads(receipt_path.read_text()), "duplicate": True}
    content_root = (root / "内容").resolve()
    if not report.is_relative_to(content_root):
        target = content_root / "报告" / (content_hash + report.suffix.lower())
        target.parent.mkdir(parents=True, exist_ok=True)
        # Hash-named files are immutable; two publishers reuse the same bytes.
        if not target.exists():
            descriptor, temporary = tempfile.mkstemp(dir=target.parent, suffix=".tmp")
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(body)
            os.replace(temporary, target)
        report = target
    heading = next((line.lstrip("# ").strip() for line in text.splitlines() if line.startswith("# ")), "")
    receipt = {"schemaVersion": 1, "id": publication_id, "projectId": project_id,
               "title": heading or original_title, "reportPath": report.relative_to(root).as_posix(),
               "contentHash": content_hash, "status": "published", "producer": "local-audio-transcriber",
               "createdAt": datetime.now(timezone.utc).isoformat()}
    atomic_json(receipt_path, receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["projects", "publish"])
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--project-id")
    args = parser.parse_args()
    root = args.library.resolve(strict=True)
    marker = json.loads((root / ".knowledge-library.json").read_text())
    if marker.get("libraryID") != "my-knowledge-library-v1":
        raise ValueError("请选择正确的“我的知识库”同步文件夹。")
    if args.command == "projects":
        value = {"projects": projects(root)}
    else:
        if not args.report or not args.project_id:
            raise ValueError("需要选择报告和项目库。")
        value = publish(root, args.report, args.project_id)
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        sys.exit(1)
