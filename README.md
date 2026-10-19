# Audio Transcription Tool

Local Chinese recording transcription and document generation for the Mac mini workstation.

## 目录结构

- `audio_to_doc`：日常使用的“音频转文档”入口。
- `transcribe`：仅进行音频转录的入口。
- `app/`：macOS 原生应用界面源码。
- `src/`：转录、文档生成和会议纪要逻辑。
- `scripts/`：构建、安装、打包和发布工具。
- `assets/`：图标和界面预览图。
- `models/`：当前使用的离线 FunASR/ONNX 模型。
- `legacy/`：保留的旧版备用转录方案和 Vosk 模型。
- `dist.noindex/`：按需生成的安装包，不进入 Spotlight 搜索。

## Mac App

### 报告存入个人知识库

- 生成完成后可选择“暂不入库”或“选择项目库并存入”。不确认不会自动发布。
- 已有 Markdown/TXT 报告可在“结果”区域点“选择已有报告…”，再点“存入知识库…”。
- 发布保留完整报告正文，不再交给模型缩写。库内报告只建立引用，库外报告按内容哈希存一份；不会复制原始音视频。
- `我的知识库/元数据/转录报告` 存放项目归属，使用相对路径，随 Syncthing 同步。
- 每台 Mac 的“在网站查看”都打开本机 `http://localhost:3000/workspace`。另一台也需要更新并启动本机网站。
- Air 的同步目录不在默认位置时，首次发布可手动选择“我的知识库”根目录，路径仅保存在本机配置。

已有安装版可退出应用后执行 `bash scripts/update-native-app.sh`，更新界面和入库接口，保留已有离线模型和 Python 运行环境。

普通用户可直接从 GitHub Release 下载 DMG：

- 版本号按上传备份日期生成，例如 `v2026.06.07`。
- 同一天多次上传时自动递增为 `v2026.06.07.01`、`v2026.06.07.02`，以此类推。
- 下载页：https://github.com/linchenhao921019-ux/local-audio-transcriber/releases

已生成并安装本地应用：

- 构建产物：`dist.noindex/本地音频转录.app`（不进入 Spotlight 搜索）
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
- 可调用本机 Hermes，沿用 Hermes 当前配置的模型生成重点内容大纲和会议纪要。
- 分段秒数由系统自动选择，无需手动设置。
- 使用原生 macOS AppKit 界面；任务运行中可点击“取消”终止当前转录或纪要生成。
- 在 macOS 26/27 使用原生 Liquid Glass 材质，并为旧版 macOS 自动降级到系统视觉材质。
- 已针对 macOS 27 beta 的 Touch Bar 退出崩溃问题做规避处理。

说明：

- 语音转录不需要联网；语音识别模型和中文标点模型已经打包在 app 内。Hermes 纪要是否联网取决于 Hermes 的模型配置。
- Google Drive 中只需要保留软件安装包；录音资料和生成内容建议保存在本机资料包，避免云盘反复同步大文件和隐私资料。
- app 启动时会强制以 arm64 运行；构建脚本也只允许在 Apple Silicon Mac 上执行。
- 纪要需要先在本机安装 Hermes，并完成模型和登录配置。应用自动检测 `~/.local/bin/hermes`，也可在“Hermes 程序”中选择其他安装位置，再点击“检测 Hermes”。无需启动 Hermes 桌面窗口。
- 纪要通过 Hermes 的单次调用接口生成，输出 Markdown 和 Word；支持分段归纳、超时提示和取消任务。原始转录保留在输出目录中。
- DMG 体积约 1.6GB，主要来自本地语音模型、中文标点模型和离线运行库。
- 自动转写可能有错字、漏字、说话人混淆；正式使用时关键事实仍需结合原录音复核。

重新构建 app：

```bash
./scripts/build_mac_app.sh
```

重新安装到 `/Applications`：

```bash
./scripts/install_app_to_applications.sh
```

生成可分发 DMG：

```bash
./scripts/create_dmg.sh
```

打包并同步到 GitHub Release：

```bash
./scripts/sync_to_github.sh
```

默认版本号按上传备份当天生成：`vYYYY.MM.DD`。如果当天已有备份，会自动使用 `.01`、`.02` 等两位序号。
同步脚本生成的 DMG 也会使用同一个版本号命名，例如 `dist.noindex/v2026.06.07.dmg`。

## Install

```bash
./scripts/install_mac_mini.sh
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
./audio_to_doc /path/to/recording.m4a --minutes
```

已有转录文本也可单独交给 Hermes 生成纪要：

```bash
~/.codex/venvs/audio-transcriber/bin/python src/hermes_meeting_minutes.py \
  --transcript /path/to/recording_transcript.txt --output-dir /path/to/output
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
