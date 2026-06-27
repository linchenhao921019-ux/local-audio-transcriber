# Audio Transcription Tool

Local Chinese recording transcription and document generation for the Mac mini workstation.

## Mac App

普通用户可直接从 GitHub Release 下载 DMG：

- 当前版本：`v2026.06.14.1`
- 下载页：https://github.com/linchenhao921019-ux/local-audio-transcriber/releases/tag/v2026.06.14.1
- DMG 文件：https://github.com/linchenhao921019-ux/local-audio-transcriber/releases/download/v2026.06.14.1/default.dmg

已生成并安装本地应用：

- 构建产物：`dist/本地音频转录.app`
- 已安装位置：`/Applications/本地音频转录.app`
- 芯片支持：仅支持 Apple M 系列芯片（arm64），不支持 Intel Mac。

打开方式：

```bash
open "/Applications/本地音频转录.app"
```

应用功能：

- 选择本地音频或视频文件，支持 `wav`、`mp3`、`mp4`、`mov`、`m4a`。
- 可直接把音频或视频文件拖入应用窗口。
- 默认输出到本机资料包：`~/本地录音转录文件包/转录资料`。
- 每次转录会按文件名生成独立目录，并保存原始录音资料、转录文本、Word 文档和会议纪要。
- 本地离线转写中文普通话录音，视频文件会读取其中的音频轨道。
- 生成带时间戳的转写文本，并自动恢复中文标点。
- 转录完成后在应用内显示预览。
- 可同时生成 Markdown 和 Word 文档。
- 可连接本机 Ollama，用本地大模型生成重点内容大纲和会议纪要。
- 分段秒数由系统自动选择，无需手动设置。
- 使用原生 macOS AppKit 界面；任务运行中可点击“取消”终止当前转录或纪要生成。
- 在 macOS 26/27 使用原生 Liquid Glass 材质，并为旧版 macOS 自动降级到系统视觉材质。
- 已针对 macOS 27 beta 的 Touch Bar 退出崩溃问题做规避处理。

说明：

- 使用时不需要联网；语音识别模型和中文标点模型已经打包在 app 内。
- Google Drive 中只需要保留软件安装包；录音资料和生成内容建议保存在本机资料包，避免云盘反复同步大文件和隐私资料。
- app 启动时会强制以 arm64 运行；构建脚本也只允许在 Apple Silicon Mac 上执行。
- Ollama 增强功能同样走本机 `http://127.0.0.1:11434`，需要你先启动 Ollama 并下载本地模型，例如 `ollama pull qwen2.5:7b`。
- DMG 体积约 1.6GB，主要来自本地语音模型、中文标点模型和离线运行库。
- 自动转写可能有错字、漏字、说话人混淆；正式使用时关键事实仍需结合原录音复核。

重新构建 app：

```bash
./build_mac_app.sh
```

重新安装到 `/Applications`：

```bash
./install_app_to_applications.sh
```

生成可分发 DMG：

```bash
./create_dmg.sh
```

打包并同步到 GitHub Release：

```bash
./sync_to_github.sh
```

## Install

```bash
./install_mac_mini.sh
```

The virtual environment is installed at `~/.codex/venvs/audio-transcriber` by default so dependency files do not sync through Google Drive.

## Create A Document

Use this as the normal entry point:

```bash
./audio_to_doc /path/to/recording.m4a
```

Outputs are written to `outputs/<recording-name>/`:

- `<recording-name>_transcript.txt`
- `<recording-name>_转录文档.md`
- `<recording-name>_转录文档.docx`

Useful options:

```bash
./audio_to_doc /path/to/recording.m4a --title "会议录音转录文档"
./audio_to_doc /path/to/recording.m4a --output-dir ./outputs/my-recording
./audio_to_doc /path/to/recording.m4a --chunk-seconds 90
```

## Transcribe Only

```bash
./transcribe /path/to/recording.m4a
```

The default output is written next to this tool as `<recording-name>_funasr_transcript.txt`. Audio is split into reusable chunks under `chunks/<recording-name>/`.

Useful options:

```bash
./transcribe /path/to/recording.m4a --output ./my_transcript.txt
./transcribe /path/to/recording.m4a --chunk-seconds 120
```
