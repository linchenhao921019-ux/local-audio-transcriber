#!/usr/bin/env python3
import json
import queue
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path
from tkinter import BooleanVar, PhotoImage, StringVar, Tk, filedialog, messagebox, scrolledtext
from tkinter import ttk


APP_DIR = Path(__file__).resolve().parent

BLUE = "#1d5fd1"
BLUE_DARK = "#154aa3"
BLUE_LIGHT = "#eaf2ff"
TEXT = "#1f2937"
MUTED = "#64748b"
BG = "#f5f8fc"
WHITE = "#ffffff"
BORDER = "#d9e2ef"


class TranscriberApp:
    def __init__(self, root: Tk):
        self.root = root
        self.root.title("本地音频转录")
        self.root.geometry("920x820")
        self.root.minsize(860, 760)
        self.root.configure(bg=BG)
        self._set_window_icon()

        self.audio_var = StringVar()
        self.output_var = StringVar(value=str(Path.home() / "Documents" / "音频转录输出"))
        self.title_var = StringVar()
        self.chunk_var = StringVar(value="180")
        self.doc_var = BooleanVar(value=True)
        self.ollama_var = BooleanVar(value=False)
        self.ollama_url_var = StringVar(value="http://127.0.0.1:11434")
        self.ollama_model_var = StringVar()
        self.ollama_models: list[str] = []
        self.running = False
        self.log_queue: queue.Queue[str] = queue.Queue()

        self._configure_style()
        self._build_ui()
        self._poll_log()
        self.check_ollama(silent=True)

    def _set_window_icon(self):
        icon_path = APP_DIR / "AppIcon.png"
        if icon_path.exists():
            try:
                self.icon_image = PhotoImage(file=str(icon_path))
                self.root.iconphoto(True, self.icon_image)
            except Exception:
                self.icon_image = None

    def _configure_style(self):
        self.style = ttk.Style()
        self.style.theme_use("clam")
        self.style.configure(".", font=("PingFang SC", 13), background=BG, foreground=TEXT)
        self.style.configure("Root.TFrame", background=BG)
        self.style.configure("Panel.TFrame", background=WHITE, borderwidth=0, relief="flat")
        self.style.configure("White.TFrame", background=WHITE)
        self.style.configure("Header.TFrame", background=BLUE)
        self.style.configure("HeaderTitle.TLabel", background=BLUE, foreground=WHITE, font=("PingFang SC", 22, "bold"))
        self.style.configure("HeaderSub.TLabel", background=BLUE, foreground="#dbeafe", font=("PingFang SC", 12))
        self.style.configure("Section.TLabel", background=WHITE, foreground=BLUE_DARK, font=("PingFang SC", 15, "bold"))
        self.style.configure("Hint.TLabel", background=WHITE, foreground=MUTED, font=("PingFang SC", 11))
        self.style.configure("Field.TLabel", background=WHITE, foreground=TEXT, font=("PingFang SC", 12))
        self.style.configure("TEntry", padding=(10, 8), fieldbackground=WHITE)
        self.style.configure("TCombobox", padding=(10, 8), fieldbackground=WHITE, background=WHITE, arrowcolor=BLUE_DARK)
        self.style.map("TCombobox", fieldbackground=[("readonly", WHITE)])
        self.style.configure("TCheckbutton", background=WHITE, foreground=TEXT, font=("PingFang SC", 12))
        self.style.configure("Primary.TButton", background=BLUE, foreground=WHITE, padding=(20, 10), font=("PingFang SC", 13, "bold"), borderwidth=0, relief="flat")
        self.style.map("Primary.TButton", background=[("active", BLUE_DARK), ("disabled", "#9ab7e6")], foreground=[("disabled", WHITE)])
        self.style.configure("Secondary.TButton", background=BLUE_LIGHT, foreground=BLUE_DARK, padding=(17, 10), font=("PingFang SC", 12), borderwidth=0, relief="flat")
        self.style.map("Secondary.TButton", background=[("active", "#dbeafe")])
        self.style.configure("Ghost.TButton", background=WHITE, foreground=BLUE_DARK, padding=(12, 8), font=("PingFang SC", 12), borderwidth=0, relief="flat")
        self.style.map("Ghost.TButton", background=[("active", BLUE_LIGHT)])

    def _build_ui(self):
        root = ttk.Frame(self.root, style="Root.TFrame", padding=(22, 22, 22, 18))
        root.grid(row=0, column=0, sticky="nsew")
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)

        header = ttk.Frame(root, style="Header.TFrame", padding=(24, 18))
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="本地音频转录", style="HeaderTitle.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(header, text="离线转写录音，并可调用本机 Ollama 生成重点大纲和会议纪要", style="HeaderSub.TLabel").grid(row=1, column=0, sticky="w", pady=(5, 0))

        main = ttk.Frame(root, style="Panel.TFrame", padding=(22, 18))
        main.grid(row=1, column=0, sticky="ew", pady=(16, 14))
        main.columnconfigure(1, weight=1)

        ttk.Label(main, text="录音与输出", style="Section.TLabel").grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 12))
        self._field(main, 1, "音视频文件", self.audio_var, "选择文件", self.choose_audio)
        self._field(main, 2, "输出目录", self.output_var, "选择目录", self.choose_output)
        self._field(main, 3, "文档标题", self.title_var, None, None, hint="留空则使用文件名")

        ttk.Label(main, text="分段秒数", style="Field.TLabel").grid(row=4, column=0, sticky="w", pady=(10, 0), padx=(0, 12))
        chunk_row = ttk.Frame(main, style="White.TFrame")
        chunk_row.grid(row=4, column=1, sticky="w", pady=(10, 0))
        ttk.Entry(chunk_row, textvariable=self.chunk_var, width=10).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(chunk_row, text="生成 Word 文档", variable=self.doc_var).grid(row=0, column=1, sticky="w", padx=(18, 0))

        ttk.Label(main, text="Ollama 纪要", style="Section.TLabel").grid(row=5, column=0, columnspan=3, sticky="w", pady=(22, 12))
        ttk.Checkbutton(main, text="用 Ollama 生成重点大纲和会议纪要", variable=self.ollama_var).grid(row=6, column=1, sticky="w")
        ttk.Button(main, text="刷新模型", command=self.check_ollama, style="Ghost.TButton").grid(row=6, column=2, sticky="ew", padx=(12, 0))

        ttk.Label(main, text="Ollama 地址", style="Field.TLabel").grid(row=7, column=0, sticky="w", pady=(10, 0), padx=(0, 12))
        ttk.Entry(main, textvariable=self.ollama_url_var).grid(row=7, column=1, sticky="ew", pady=(10, 0))
        ttk.Label(main, text="默认本机", style="Hint.TLabel").grid(row=7, column=2, sticky="w", pady=(10, 0), padx=(12, 0))

        ttk.Label(main, text="Ollama 模型", style="Field.TLabel").grid(row=8, column=0, sticky="w", pady=(10, 0), padx=(0, 12))
        self.model_combo = ttk.Combobox(main, textvariable=self.ollama_model_var, state="readonly", values=(), height=8)
        self.model_combo.grid(row=8, column=1, sticky="ew", pady=(10, 0))
        self.model_hint = ttk.Label(main, text="点击刷新模型后选择", style="Hint.TLabel")
        self.model_hint.grid(row=8, column=2, sticky="w", pady=(10, 0), padx=(12, 0))

        action_row = ttk.Frame(main, style="White.TFrame")
        action_row.grid(row=9, column=0, columnspan=3, sticky="ew", pady=(22, 0))
        action_row.columnconfigure(2, weight=1)
        self.start_button = ttk.Button(action_row, text="开始转录", command=self.start, style="Primary.TButton")
        self.start_button.grid(row=0, column=0, sticky="w")
        ttk.Button(action_row, text="打开输出目录", command=self.open_output, style="Secondary.TButton").grid(row=0, column=1, sticky="w", padx=(12, 0))
        self.status_label = ttk.Label(action_row, text="准备就绪", style="Hint.TLabel")
        self.status_label.grid(row=0, column=2, sticky="e")

        log_panel = ttk.Frame(root, style="Panel.TFrame", padding=(16, 14))
        log_panel.grid(row=2, column=0, sticky="nsew")
        log_panel.columnconfigure(0, weight=1)
        log_panel.rowconfigure(1, weight=1)
        ttk.Label(log_panel, text="运行日志", style="Section.TLabel").grid(row=0, column=0, sticky="w", pady=(0, 10))
        self.log = scrolledtext.ScrolledText(
            log_panel,
            height=14,
            bg="#fbfdff",
            fg=TEXT,
            insertbackground=BLUE_DARK,
            relief="flat",
            bd=0,
            highlightthickness=1,
            highlightbackground=BORDER,
            highlightcolor=BORDER,
            padx=12,
            pady=10,
            font=("Menlo", 12),
        )
        self.log.grid(row=1, column=0, sticky="nsew")

        self._append_log("本工具在本机离线运行，适合中文普通话录音。")
        self._append_log("如需重点大纲和会议纪要，请先启动本机 Ollama，然后点击“刷新模型”并选择模型。")

    def _field(self, parent, row, label, variable, button_text, button_command, hint=None):
        ttk.Label(parent, text=label, style="Field.TLabel").grid(row=row, column=0, sticky="w", pady=(10, 0), padx=(0, 12))
        ttk.Entry(parent, textvariable=variable).grid(row=row, column=1, sticky="ew", pady=(10, 0))
        if button_text and button_command:
            ttk.Button(parent, text=button_text, command=button_command, style="Ghost.TButton").grid(row=row, column=2, sticky="ew", pady=(10, 0), padx=(12, 0))
        elif hint:
            ttk.Label(parent, text=hint, style="Hint.TLabel").grid(row=row, column=2, sticky="w", pady=(10, 0), padx=(12, 0))

    def choose_audio(self):
        path = filedialog.askopenfilename(
            title="选择音频或视频文件",
            filetypes=[
                ("Audio files", "*.m4a *.mp3 *.wav *.aac *.flac *.mp4 *.mov"),
                ("All files", "*.*"),
            ],
        )
        if path:
            self.audio_var.set(path)
            if not self.title_var.get().strip():
                self.title_var.set(f"{Path(path).stem} 转录文档")

    def choose_output(self):
        path = filedialog.askdirectory(title="选择输出目录")
        if path:
            self.output_var.set(path)

    def open_output(self):
        out = Path(self.output_var.get()).expanduser()
        out.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", str(out)], check=False)

    def check_ollama(self, silent=False):
        if self.running:
            return
        url = self.ollama_url_var.get().strip().rstrip("/") or "http://127.0.0.1:11434"
        if not silent:
            self.model_hint.configure(text="正在刷新...")
            self._append_log("正在检测 Ollama 模型...")
        thread = threading.Thread(target=self._check_ollama_worker, args=(url, silent), daemon=True)
        thread.start()

    def _check_ollama_worker(self, url: str, silent: bool):
        try:
            req = urllib.request.Request(f"{url}/api/tags")
            with urllib.request.urlopen(req, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
            models = [model.get("name", "") for model in data.get("models", []) if model.get("name")]
            self.log_queue.put("MODELS::" + json.dumps({"models": models, "silent": silent}, ensure_ascii=False))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            self.log_queue.put("MODELS_ERROR::" + json.dumps({"error": str(exc), "silent": silent}, ensure_ascii=False))

    def _update_models(self, models: list[str], silent: bool):
        self.ollama_models = models
        self.model_combo.configure(values=models)
        current = self.ollama_model_var.get().strip()
        if models:
            if current not in models:
                self.ollama_model_var.set(models[0])
            self.model_hint.configure(text=f"{len(models)} 个模型")
            if not silent:
                self._append_log("Ollama 已连接。可用模型：" + "，".join(models))
        else:
            self.ollama_model_var.set("")
            self.model_hint.configure(text="未发现模型")
            if not silent:
                self._append_log("Ollama 已连接，但没有发现模型。请先在终端运行：ollama pull qwen2.5:7b")

    def start(self):
        if self.running:
            return
        audio = Path(self.audio_var.get()).expanduser()
        if not audio.exists():
            messagebox.showerror("缺少音频文件", "请选择一个存在的音频文件。")
            return
        try:
            chunk_seconds = float(self.chunk_var.get())
            if chunk_seconds <= 0:
                raise ValueError
        except ValueError:
            messagebox.showerror("分段秒数无效", "分段秒数请输入正数，例如 180。")
            return
        if self.ollama_var.get() and not self.ollama_model_var.get().strip():
            messagebox.showerror("缺少 Ollama 模型", "请先点击“刷新模型”，并从下拉框选择一个本地模型。")
            return

        output_root = Path(self.output_var.get()).expanduser()
        output_dir = output_root / audio.stem
        output_dir.mkdir(parents=True, exist_ok=True)

        self.running = True
        self.start_button.configure(state="disabled", text="转录中...")
        self.status_label.configure(text="正在处理")
        self._append_log("")
        self._append_log(f"音频：{audio}")
        self._append_log(f"输出：{output_dir}")

        title = self.title_var.get().strip()
        build_doc = self.doc_var.get()
        use_ollama = self.ollama_var.get()
        ollama_url = self.ollama_url_var.get().strip() or "http://127.0.0.1:11434"
        ollama_model = self.ollama_model_var.get().strip()
        thread = threading.Thread(
            target=self._run_job,
            args=(audio, output_dir, chunk_seconds, title, build_doc, use_ollama, ollama_url, ollama_model),
            daemon=True,
        )
        thread.start()

    def _run_job(
        self,
        audio: Path,
        output_dir: Path,
        chunk_seconds: float,
        title: str,
        build_doc: bool,
        use_ollama: bool,
        ollama_url: str,
        ollama_model: str,
    ):
        try:
            transcript = output_dir / f"{audio.stem}_transcript.txt"
            chunks = output_dir / "chunks"
            cmd = [
                sys.executable,
                str(APP_DIR / "transcribe_funasr_chunks.py"),
                str(audio),
                "--output",
                str(transcript),
                "--chunks-dir",
                str(chunks),
                "--chunk-seconds",
                str(chunk_seconds),
            ]
            self._stream_command(cmd)

            if build_doc:
                cmd = [
                    sys.executable,
                    str(APP_DIR / "build_transcript_doc.py"),
                    str(audio),
                    "--transcript",
                    str(transcript),
                    "--output-dir",
                    str(output_dir),
                ]
                if title:
                    cmd.extend(["--title", title])
                self._stream_command(cmd)

            if use_ollama:
                minutes_title = title or f"{audio.stem} 重点大纲与会议纪要"
                cmd = [
                    sys.executable,
                    str(APP_DIR / "ollama_meeting_minutes.py"),
                    "--transcript",
                    str(transcript),
                    "--output-dir",
                    str(output_dir),
                    "--title",
                    minutes_title,
                    "--ollama-url",
                    ollama_url,
                    "--model",
                    ollama_model,
                ]
                self._stream_command(cmd)

            self.log_queue.put(f"DONE::{output_dir}")
        except Exception as exc:
            self.log_queue.put(f"ERROR::{exc}")

    def _stream_command(self, cmd):
        self.log_queue.put("$ " + " ".join(str(x) for x in cmd))
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            self.log_queue.put(line.rstrip())
        code = proc.wait()
        if code != 0:
            raise RuntimeError(f"命令执行失败，退出码 {code}")

    def _append_log(self, text: str):
        self.log.insert("end", text + "\n")
        self.log.see("end")

    def _poll_log(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                if msg.startswith("MODELS::"):
                    payload = json.loads(msg.split("::", 1)[1])
                    self._update_models(payload["models"], payload["silent"])
                elif msg.startswith("MODELS_ERROR::"):
                    payload = json.loads(msg.split("::", 1)[1])
                    self.model_hint.configure(text="未连接")
                    if not payload["silent"]:
                        self._append_log(f"Ollama 检测失败：{payload['error']}")
                elif msg.startswith("DONE::"):
                    out = msg.split("::", 1)[1]
                    self._append_log("")
                    self._append_log(f"完成。输出目录：{out}")
                    self.running = False
                    self.start_button.configure(state="normal", text="开始转录")
                    self.status_label.configure(text="已完成")
                    messagebox.showinfo("转录完成", f"已生成到：\n{out}")
                elif msg.startswith("ERROR::"):
                    err = msg.split("::", 1)[1]
                    self._append_log("")
                    self._append_log(f"错误：{err}")
                    self.running = False
                    self.start_button.configure(state="normal", text="开始转录")
                    self.status_label.configure(text="处理失败")
                    messagebox.showerror("转录失败", err)
                else:
                    self._append_log(msg)
        except queue.Empty:
            pass
        self.root.after(150, self._poll_log)


def main():
    root = Tk()
    TranscriberApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
