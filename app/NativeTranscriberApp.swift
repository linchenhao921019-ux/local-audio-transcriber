import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private enum SharedKnowledgeLibraryLocator {
    static var root: URL? {
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/My Knowledge Library/location.json")
        let data = try? Data(contentsOf: config)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let relative = object["relativePath"] as? String ?? "我的知识库"
        let libraryID = object["libraryID"] as? String ?? "my-knowledge-library-v1"
        let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        var candidates = [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/" + relative)]
        if let explicit = object["rootPath"] as? String { candidates.insert(URL(fileURLWithPath: explicit), at: 0) }
        candidates += volumes.map { $0.appendingPathComponent(relative, isDirectory: true) }
        for candidate in candidates {
            let marker = candidate.appendingPathComponent(".knowledge-library.json")
            guard let markerData = try? Data(contentsOf: marker),
                  let markerObject = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
                  markerObject["libraryID"] as? String == libraryID else { continue }
            return candidate
        }
        return nil
    }
}

private extension NSView {
    var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

final class CardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        if usesDarkAppearance {
            layer?.backgroundColor = NSColor(calibratedRed: 0.105, green: 0.110, blue: 0.120, alpha: 0.96).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.055).cgColor
            layer?.shadowOpacity = 0.18
        } else {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            layer?.borderColor = NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.92, alpha: 0.45).cgColor
            layer?.shadowOpacity = 0.06
        }
    }
}

final class HeaderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.06, green: 0.32, blue: 0.76, alpha: 1),
            NSColor(calibratedRed: 0.11, green: 0.48, blue: 0.92, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class LogContainerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        if usesDarkAppearance {
            layer?.backgroundColor = NSColor(calibratedRed: 0.070, green: 0.076, blue: 0.086, alpha: 1).cgColor
            layer?.borderColor = NSColor(calibratedRed: 0.22, green: 0.34, blue: 0.50, alpha: 0.75).cgColor
        } else {
            layer?.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.980, blue: 1.0, alpha: 1).cgColor
            layer?.borderColor = NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.92, alpha: 1).cgColor
        }
    }
}

final class MediaDropView: NSVisualEffectView {
    var supportedExtensions: [String] = []
    var onFileDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstSupportedURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstSupportedURL(from: sender.draggingPasteboard) else {
            return false
        }
        onFileDrop?(url)
        return true
    }

    private func firstSupportedURL(from pasteboard: NSPasteboard) -> URL? {
        guard let items = pasteboard.pasteboardItems else {
            return nil
        }
        let supported = Set(supportedExtensions.map { $0.lowercased() })
        for item in items {
            guard
                let value = item.string(forType: .fileURL),
                let url = URL(string: value)
            else {
                continue
            }
            if supported.contains(url.pathExtension.lowercased()) {
                return url
            }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private enum PreferenceKey {
        static let outputDirectory = "outputDirectory"
    }

    private struct JobConfig {
        let audioURL: URL
        let outputDir: URL
        let chunkSeconds: Double
        let buildWord: Bool
        let useHermes: Bool
        let title: String
        let hermesCommand: String
    }

    private let appDir: URL
    private let pythonURL: URL
    private var currentProcess: Process?
    private var cancelled = false
    private var running = false
    private var exiting = false
    private var recentLogLines: [String] = []
    private var logFileURL: URL?
    private weak var mainWindow: NSWindow?

    private let audioField = NSTextField()
    private let outputField = NSTextField()
    private let titleField = NSTextField()
    private let wordCheck = NSButton(checkboxWithTitle: "生成 Word 文档", target: nil, action: nil)
    private let hermesCheck = NSButton(checkboxWithTitle: "用 Hermes 生成重点大纲和会议纪要", target: nil, action: nil)
    private let hermesPathField = NSTextField()
    private let modelSummary = NSTextField(labelWithString: "沿用 Hermes 当前配置")
    private let modelStatus = NSTextField(labelWithString: "待检测")
    private let startButton = NSButton(title: "开始转录", target: nil, action: nil)
    private let openButton = NSButton(title: "打开输出目录", target: nil, action: nil)
    private let refreshButton = NSButton(title: "检测 Hermes", target: nil, action: nil)
    private let openPreviewButton = NSButton(title: "打开预览文件", target: nil, action: nil)
    private let publishReportButton = NSButton(title: "存入知识库…", target: nil, action: nil)
    private let resultSegment = NSSegmentedControl(labels: ["转录预览", "运行日志"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "准备就绪")
    private let logView = NSTextView()
    private let previewView = NSTextView()
    private let previewScroll = NSScrollView()
    private let logScroll = NSScrollView()
    private let supportedMediaExtensions = ["wav", "mp3", "mp4", "mov", "m4a"]
    private var previewFileURL: URL?

    private struct CommandError: LocalizedError {
        let command: String
        let exitCode: Int32
        let recentOutput: [String]

        var errorDescription: String? {
            let tail = recentOutput.suffix(8).joined(separator: "\n")
            if tail.isEmpty {
                return "命令执行失败，退出码 \(exitCode)\n\n\(command)"
            }
            return "命令执行失败，退出码 \(exitCode)\n\n最近日志：\n\(tail)"
        }
    }

    override init() {
        let bundleURL = Bundle.main.bundleURL
        self.appDir = bundleURL.appendingPathComponent("Contents/Resources/app")
        self.pythonURL = bundleURL.appendingPathComponent("Contents/Resources/runtime/bin/python")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        checkHermes(silent: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestCleanExit()
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestCleanExit()
        return false
    }

    private func buildWindow() {
        let initialFrame = defaultWindowFrame()
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "本地音频转录"
        window.delegate = self
        mainWindow = window
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 680)

        let visual = MediaDropView()
        visual.material = .contentBackground
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.supportedExtensions = supportedMediaExtensions
        visual.onFileDrop = { [weak self] url in
            DispatchQueue.main.async {
                self?.setSelectedMedia(url)
            }
        }
        visual.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = visual

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(contentContainer)

        let header = makeHeader()
        let mainCard = makeMainCard()
        let resultCard = makeResultCard()
        [header, mainCard, resultCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: visual.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            contentContainer.centerXAnchor.constraint(equalTo: visual.centerXAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 28),
            contentContainer.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -28),

            header.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 28),

            mainCard.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            mainCard.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            mainCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),

            resultCard.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            resultCard.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            resultCard.topAnchor.constraint(equalTo: mainCard.bottomAnchor, constant: 16),
            resultCard.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -28),
            resultCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])

        restoreOutputDirectory()
        outputField.delegate = self
        titleField.placeholderString = "留空则使用文件名"
        audioField.placeholderString = "选择或拖入 wav、mp3、mp4、mov、m4a"
        wordCheck.state = .on
        hermesPathField.stringValue = UserDefaults.standard.string(forKey: "hermesCommand") ?? defaultHermesCommand()
        hermesPathField.cell?.lineBreakMode = .byTruncatingMiddle

        startButton.target = self
        startButton.action = #selector(startOrCancel)
        openButton.target = self
        openButton.action = #selector(openOutputDirectory)
        refreshButton.target = self
        refreshButton.action = #selector(checkHermesButton)
        openPreviewButton.target = self
        openPreviewButton.action = #selector(openPreviewFile)
        openPreviewButton.isEnabled = false
        publishReportButton.target = self
        publishReportButton.action = #selector(publishReport)
        publishReportButton.isEnabled = false

        appendLog("语音转录在本机离线运行，支持 wav、mp3、mp4、mov、m4a。录音资料和转录结果默认保存到本机资料包。纪要由本机 Hermes 生成，使用 Hermes 当前的模型与登录配置。")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func defaultWindowFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        let width = min(960, max(820, visible.width - 64))
        let height = min(860, max(680, visible.height - 72))
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func makeHeader() -> NSView {
        let header = HeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let title = NSTextField(labelWithString: "本地音频转录")
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "离线转写音频或视频音轨，并调用本机 Hermes 生成重点大纲和会议纪要")
        subtitle.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.82)
        subtitle.alignment = .center

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func makeMainCard() -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])

        stack.addArrangedSubview(sectionTitle("录音与输出"))
        stack.addArrangedSubview(row(label: "音视频文件", field: audioField, buttonTitle: "选择文件", action: #selector(chooseAudio)))
        stack.addArrangedSubview(row(label: "输出目录", field: outputField, buttonTitle: "选择目录", action: #selector(chooseOutput)))
        stack.addArrangedSubview(row(label: "文档标题", field: titleField, helper: "留空则使用文件名"))
        stack.addArrangedSubview(optionsRow())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Hermes 纪要"))
        stack.addArrangedSubview(checkRow())
        stack.addArrangedSubview(row(label: "Hermes 程序", field: hermesPathField, buttonTitle: "选择程序", action: #selector(chooseHermes)))
        stack.addArrangedSubview(modelRow())
        stack.addArrangedSubview(actionRow())
        return card
    }

    private func makeResultCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "结果")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NSColor.controlAccentColor

        resultSegment.controlSize = .large
        resultSegment.selectedSegment = 0
        resultSegment.target = self
        resultSegment.action = #selector(switchResultView)
        resultSegment.widthAnchor.constraint(equalToConstant: 210).isActive = true

        styleButton(openPreviewButton)
        openPreviewButton.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [title, resultSegment, spacer, openPreviewButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        titleRow.spacing = 14

        let resultContainer = LogContainerView()
        resultContainer.translatesAutoresizingMaskIntoConstraints = false

        configureResultScroll(previewScroll, textView: previewView, font: NSFont.systemFont(ofSize: 13))
        configureResultScroll(logScroll, textView: logView, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        previewView.string = "等待转录结果。"
        logScroll.isHidden = true

        [previewScroll, logScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            resultContainer.addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 6),
                $0.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -6),
                $0.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 6),
                $0.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor, constant: -6)
            ])
        }

        styleButton(publishReportButton)
        publishReportButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        publishReportButton.imagePosition = .imageLeading
        publishReportButton.toolTip = "选择项目库后存入完整报告"
        let existing = NSButton(title: "选择已有报告…", target: self, action: #selector(chooseExistingReport))
        styleButton(existing)
        existing.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        existing.imagePosition = .imageLeading
        existing.toolTip = "打开已有 Markdown 或 TXT 报告"
        let actionSpacer = NSView()
        let reportActions = NSStackView(views: [existing, actionSpacer, publishReportButton])
        reportActions.orientation = .horizontal
        reportActions.distribution = .fill
        let stack = NSStackView(views: [titleRow, reportActions, resultContainer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            resultContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 190)
        ])
        return card
    }

    private func configureResultScroll(_ scroll: NSScrollView, textView: NSTextView, font: NSFont) {
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        textView.isEditable = false
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        scroll.documentView = textView
    }

    private func makeLogCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let title = sectionTitle("运行日志")
        let logContainer = LogContainerView()
        logContainer.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.scrollerStyle = .overlay
        logContainer.addSubview(scroll)

        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textColor = NSColor.labelColor
        logView.backgroundColor = .clear
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 14, height: 12)
        scroll.documentView = logView

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: logContainer.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor, constant: -6)
        ])

        let stack = NSStackView(views: [title, logContainer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            logContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        return card
    }

    private func makePreviewCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = sectionTitle("转录预览")
        styleButton(openPreviewButton)
        openPreviewButton.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let titleRow = NSStackView(views: [title, openPreviewButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let previewContainer = LogContainerView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.scrollerStyle = .overlay
        previewContainer.addSubview(scroll)

        previewView.isEditable = false
        previewView.font = NSFont.systemFont(ofSize: 13)
        previewView.textColor = NSColor.labelColor
        previewView.backgroundColor = .clear
        previewView.drawsBackground = false
        previewView.textContainerInset = NSSize(width: 14, height: 12)
        previewView.string = "等待转录结果。"
        scroll.documentView = previewView

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6)
        ])

        let stack = NSStackView(views: [titleRow, previewContainer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        return card
    }

    private func sectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        label.textColor = NSColor.controlAccentColor
        label.alignment = .left
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func styleButton(_ button: NSButton, prominent: Bool = false) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 13, weight: prominent ? .semibold : .regular)
        if prominent {
            button.bezelColor = NSColor.controlAccentColor
            button.contentTintColor = .white
        }
    }

    private func row(label: String, field: NSTextField, buttonTitle: String? = nil, action: Selector? = nil, helper: String? = nil) -> NSView {
        field.controlSize = .large
        field.font = NSFont.systemFont(ofSize: 14)

        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if let buttonTitle, let action {
            let button = NSButton(title: buttonTitle, target: self, action: action)
            styleButton(button)
            button.widthAnchor.constraint(equalToConstant: 118).isActive = true
            row.addArrangedSubview(button)
        } else if let helper {
            let helperLabel = NSTextField(labelWithString: helper)
            helperLabel.font = NSFont.systemFont(ofSize: 12)
            helperLabel.textColor = .tertiaryLabelColor
            helperLabel.widthAnchor.constraint(equalToConstant: 118).isActive = true
            row.addArrangedSubview(helperLabel)
        }
        return row
    }

    private func optionsRow() -> NSView {
        wordCheck.controlSize = .large

        let label = NSTextField(labelWithString: "输出选项")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let helper = NSTextField(labelWithString: "系统自动选择转录分段")
        helper.font = NSFont.systemFont(ofSize: 12)
        helper.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, wordCheck, helper, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func checkRow() -> NSView {
        hermesCheck.controlSize = .large
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        styleButton(refreshButton)
        refreshButton.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let labelSpacer = NSView()
        labelSpacer.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let row = NSStackView(views: [labelSpacer, hermesCheck, spacer, refreshButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func modelRow() -> NSView {
        modelSummary.font = NSFont.systemFont(ofSize: 14)
        modelSummary.textColor = .secondaryLabelColor
        modelSummary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelStatus.font = NSFont.systemFont(ofSize: 12)
        modelStatus.textColor = .tertiaryLabelColor
        modelStatus.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let label = NSTextField(labelWithString: "纪要模型")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, modelSummary, modelStatus, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func actionRow() -> NSView {
        styleButton(startButton, prominent: true)
        styleButton(openButton)
        startButton.widthAnchor.constraint(equalToConstant: 142).isActive = true
        openButton.widthAnchor.constraint(equalToConstant: 142).isActive = true
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [startButton, openButton, spacer, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "选择音频或视频文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedMediaExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            setSelectedMedia(url)
        }
    }

    private func setSelectedMedia(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard supportedMediaExtensions.contains(ext), FileManager.default.fileExists(atPath: url.path) else {
            showAlert(title: "文件格式不支持", message: "请选择 wav、mp3、mp4、mov 或 m4a 文件。")
            return
        }
        audioField.stringValue = url.path
        if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titleField.stringValue = "\(url.deletingPathExtension().lastPathComponent) 转录文档"
        }
        appendLog("已选择文件：\(url.path)")
    }

    private var defaultOutputDirectoryPath: String {
        if let root = SharedKnowledgeLibraryLocator.root {
            return root.appendingPathComponent("内容/转录", isDirectory: true).path
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("本地音频转录/待处理", isDirectory: true).path
    }

    private func restoreOutputDirectory() {
        let savedPath = UserDefaults.standard.string(forKey: PreferenceKey.outputDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedPath, !savedPath.isEmpty, !savedPath.contains("本地录音转录文件包") {
            outputField.stringValue = savedPath
        } else {
            outputField.stringValue = defaultOutputDirectoryPath
        }
    }

    private func persistOutputDirectory() {
        let enteredPath = outputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = enteredPath.isEmpty ? defaultOutputDirectoryPath : enteredPath.expandingTildeInPath
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        outputField.stringValue = standardizedPath
        UserDefaults.standard.set(standardizedPath, forKey: PreferenceKey.outputDirectory)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === outputField else {
            return
        }
        persistOutputDirectory()
    }

    @objc private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "选择输出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outputField.stringValue = url.path
            persistOutputDirectory()
        }
    }

    @objc private func openOutputDirectory() {
        persistOutputDirectory()
        let url = URL(fileURLWithPath: outputField.stringValue.expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func openPreviewFile() {
        guard let previewFileURL else {
            return
        }
        NSWorkspace.shared.open(previewFileURL)
    }

    @objc private func switchResultView() {
        showResultPane(resultSegment.selectedSegment)
    }

    private func showResultPane(_ index: Int) {
        let showLog = index == 1
        resultSegment.selectedSegment = showLog ? 1 : 0
        previewScroll.isHidden = showLog
        logScroll.isHidden = !showLog
    }

    private func requestCleanExit() {
        guard !exiting else {
            return
        }
        exiting = true
        persistOutputDirectory()
        UserDefaults.standard.synchronize()
        cancelled = true
        currentProcess?.terminate()
        currentProcess = nil
        mainWindow?.orderOut(nil)
        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Darwin.exit(0)
        }
    }

    private func defaultHermesCommand() -> String {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/hermes",
            NSHomeDirectory() + "/.hermes/hermes-agent/.hermes/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    @objc private func chooseHermes() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "选择 Hermes 程序"
        panel.directoryURL = URL(fileURLWithPath: hermesPathField.stringValue.expandingTildeInPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            hermesPathField.stringValue = url.path
            checkHermes(silent: false)
        }
    }

    @objc private func checkHermesButton() {
        checkHermes(silent: false)
    }

    private func checkHermes(silent: Bool) {
        let path = hermesPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath
        modelStatus.stringValue = "正在检测..."
        refreshButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.probeHermes(path: path)
            DispatchQueue.main.async {
                self.refreshButton.isEnabled = true
                guard self.hermesPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath == path else { return }
                switch result {
                case .success:
                    self.modelStatus.stringValue = "Hermes 已就绪"
                    UserDefaults.standard.set(path, forKey: "hermesCommand")
                    if !silent { self.appendLog("Hermes 程序检测通过，纪要使用 Hermes 当前配置的模型。") }
                case .failure(let error):
                    self.modelStatus.stringValue = "检测失败"
                    if !silent { self.appendLog(error.localizedDescription) }
                }
            }
        }
    }

    private func probeHermes(path: String) -> Result<Void, Error> {
        do {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw NSError(domain: "LocalTranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 Hermes，请选择本机可执行的 Hermes 程序。"])
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["chat", "--help"]
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONNOUSERSITE", "VIRTUAL_ENV"] {
                environment.removeValue(forKey: key)
            }
            environment["HOME"] = NSHomeDirectory()
            environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let deadline = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let help = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0, help.contains("--query-file"), help.contains("stream-json") else {
                throw NSError(domain: "LocalTranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Hermes 启动失败或版本过旧，请先在终端修复或升级 Hermes。"])
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @objc private func startOrCancel() {
        if running {
            cancelled = true
            currentProcess?.terminate()
            appendLog("正在取消当前任务...")
            startButton.isEnabled = false
            statusLabel.stringValue = "正在取消"
            return
        }
        startJob()
    }

    private func startJob() {
        let audioPath = audioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !audioPath.isEmpty, FileManager.default.fileExists(atPath: audioPath) else {
            showAlert(title: "缺少音视频文件", message: "请选择一个存在的音频或视频文件。支持格式：wav、mp3、mp4、mov、m4a。")
            return
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        guard supportedMediaExtensions.contains(audioURL.pathExtension.lowercased()) else {
            showAlert(title: "文件格式不支持", message: "请选择 wav、mp3、mp4、mov 或 m4a 文件。")
            return
        }
        persistOutputDirectory()
        let chunkSeconds = automaticChunkSeconds(for: audioURL)
        if hermesCheck.state == .on && !FileManager.default.isExecutableFile(atPath: hermesPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath) {
            showAlert(title: "缺少 Hermes 程序", message: "请先选择本机 Hermes 程序并点击“检测 Hermes”。")
            return
        }

        running = true
        cancelled = false
        startButton.title = "取消"
        startButton.isEnabled = true
        startButton.bezelColor = NSColor.systemRed
        statusLabel.stringValue = "正在处理"
        previewFileURL = nil
        openPreviewButton.isEnabled = false
        previewView.string = "正在转录，完成后会在这里显示预览。"
        showResultPane(1)

        let outputRoot = URL(fileURLWithPath: outputField.stringValue.expandingTildeInPath)
        let outputDir = outputRoot.appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        logFileURL = outputDir.appendingPathComponent("运行日志.txt")
        try? "".write(to: logFileURL!, atomically: true, encoding: .utf8)
        recentLogLines.removeAll()
        let config = JobConfig(
            audioURL: audioURL,
            outputDir: outputDir,
            chunkSeconds: chunkSeconds,
            buildWord: wordCheck.state == .on,
            useHermes: hermesCheck.state == .on,
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            hermesCommand: hermesPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath
        )

        appendLog("")
        appendLog("音频：\(audioURL.path)")
        appendLog("输出：\(outputDir.path)")
        appendLog("自动分段：\(Int(chunkSeconds)) 秒")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let previewURL = try self.runPipeline(config)
                DispatchQueue.main.async {
                    self.finish(success: true, outputDir: outputDir, previewURL: previewURL)
                }
            } catch {
                DispatchQueue.main.async {
                    if self.cancelled {
                        self.finishCancelled()
                    } else {
                        self.finish(error: error)
                    }
                }
            }
        }
    }

    private func automaticChunkSeconds(for url: URL) -> Double {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values?.fileSize ?? 0
        if fileSize > 1_000_000_000 {
            return 120
        }
        if fileSize > 300_000_000 {
            return 150
        }
        return 180
    }

    private func runPipeline(_ config: JobConfig) throws -> URL {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("MyJarvisTranscription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let localMediaURL = config.audioURL
        let transcript = workDir.appendingPathComponent("\(localMediaURL.deletingPathExtension().lastPathComponent)_transcript.txt")
        let chunks = workDir.appendingPathComponent("chunks")

        try runPython([
            script("transcribe_funasr_chunks.py"),
            localMediaURL.path,
            "--output", transcript.path,
            "--chunks-dir", chunks.path,
            "--chunk-seconds", String(config.chunkSeconds)
        ])

        if cancelled { throw CancellationError() }

        if config.buildWord {
            var args = [
                script("build_transcript_doc.py"),
                localMediaURL.path,
                "--transcript", transcript.path,
                "--output-dir", workDir.path
            ]
            if !config.title.isEmpty {
                args += ["--title", config.title]
            }
            try runPython(args)
        }

        if cancelled { throw CancellationError() }

        // Preserve completed transcription even if Hermes is unavailable or cancelled.
        try FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)
        for source in try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            guard ["txt", "md", "docx"].contains(source.pathExtension.lowercased()) else { continue }
            let destination = config.outputDir.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let savedTranscript = config.outputDir.appendingPathComponent(transcript.lastPathComponent)
        var selectedPreview: URL?
        if config.useHermes {
            let minutesTitle = config.title.isEmpty ? "\(localMediaURL.deletingPathExtension().lastPathComponent) 重点大纲与会议纪要" : config.title
            try runPython([
                script("hermes_meeting_minutes.py"),
                "--transcript", savedTranscript.path,
                "--output-dir", config.outputDir.path,
                "--title", minutesTitle,
                "--hermes-command", config.hermesCommand
            ])
            let minutesMarkdown = config.outputDir.appendingPathComponent("\(transcript.deletingPathExtension().lastPathComponent)_重点大纲与会议纪要.md")
            if FileManager.default.fileExists(atPath: minutesMarkdown.path) {
                selectedPreview = minutesMarkdown
            }
        }
        if selectedPreview == nil {
            let transcriptMarkdown = config.outputDir.appendingPathComponent("\(localMediaURL.deletingPathExtension().lastPathComponent)_转录文档.md")
            if config.buildWord, FileManager.default.fileExists(atPath: transcriptMarkdown.path) {
                selectedPreview = transcriptMarkdown
            }
        }
        return selectedPreview ?? savedTranscript
    }

    private func copyOriginalMedia(_ sourceURL: URL, to outputDir: URL) throws -> URL {
        return sourceURL
    }

    private func script(_ name: String) -> String {
        appDir.appendingPathComponent(name).path
    }

    private func runPython(_ arguments: [String]) throws {
        if cancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = arguments
        process.currentDirectoryURL = appDir
        let resourcesURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let pythonHome = resourcesURL.appendingPathComponent("Python.framework/Versions/3.11").path
        let sitePackages = resourcesURL.appendingPathComponent("runtime/lib/python3.11/site-packages").path
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONHOME"] = pythonHome
        environment["PYTHONPATH"] = sitePackages
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = NSHomeDirectory()
        if let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let appCache = cacheBase.appendingPathComponent("本地录音转录", isDirectory: true)
            try? FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
            environment["NUMBA_CACHE_DIR"] = appCache.appendingPathComponent("numba", isDirectory: true).path
            environment["XDG_CACHE_HOME"] = appCache.path
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        DispatchQueue.main.async {
            self.currentProcess = process
            self.appendLog("$ \(self.pythonURL.path) \(arguments.joined(separator: " "))")
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                text.split(separator: "\n", omittingEmptySubsequences: false).forEach { line in
                    if !line.isEmpty { self.appendLog(String(line)) }
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
            if self.currentProcess === process {
                self.currentProcess = nil
            }
        }
        if cancelled { throw CancellationError() }
        if process.terminationStatus != 0 {
            throw CommandError(command: "\(pythonURL.path) \(arguments.joined(separator: " "))", exitCode: process.terminationStatus, recentOutput: recentLogLines)
        }
    }

    private func finish(success: Bool, outputDir: URL, previewURL: URL) {
        running = false
        cancelled = false
        currentProcess = nil
        logFileURL = nil
        startButton.title = "开始转录"
        startButton.isEnabled = true
        startButton.bezelColor = NSColor.controlAccentColor
        statusLabel.stringValue = success ? "已完成" : "准备就绪"
        appendLog("")
        appendLog("完成。输出目录：\(outputDir.path)")
        loadPreview(from: previewURL)
        let alert = NSAlert()
        alert.messageText = "转录完成"
        alert.informativeText = "已生成到：\n\(outputDir.path)"
        alert.addButton(withTitle: "暂不入库")
        alert.addButton(withTitle: "选择项目库并存入…")
        if alert.runModal() == .alertSecondButtonReturn { publishReport() }
    }

    private func finishCancelled() {
        running = false
        cancelled = false
        currentProcess = nil
        logFileURL = nil
        startButton.title = "开始转录"
        startButton.isEnabled = true
        startButton.bezelColor = NSColor.controlAccentColor
        statusLabel.stringValue = "已取消"
        appendLog("任务已取消。")
    }

    private func finish(error: Error) {
        running = false
        cancelled = false
        currentProcess = nil
        startButton.title = "开始转录"
        startButton.isEnabled = true
        startButton.bezelColor = NSColor.controlAccentColor
        statusLabel.stringValue = "处理失败"
        appendLog("")
        appendLog("错误：\(error.localizedDescription)")
        appendLog("完整日志：\(logFileURL?.path ?? "无")")
        showResultPane(1)
        showAlert(title: "转录失败", message: error.localizedDescription)
        logFileURL = nil
    }

    private func loadPreview(from url: URL) {
        previewFileURL = url
        openPreviewButton.isEnabled = true
        publishReportButton.isEnabled = true
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            previewView.string = readablePreview(from: text, fileURL: url)
            previewView.scrollToBeginningOfDocument(nil)
            showResultPane(0)
            appendLog("预览文件：\(url.path)")
        } catch {
            previewView.string = "预览加载失败：\(error.localizedDescription)\n\n文件位置：\(url.path)"
            showResultPane(0)
            appendLog("预览加载失败：\(error.localizedDescription)")
        }
    }

    @objc private func chooseExistingReport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { loadPreview(from: url) }
    }

    @objc private func publishReport() {
        guard let report = previewFileURL else { return }
        var root = SharedKnowledgeLibraryLocator.root
        if root == nil {
            let panel = NSOpenPanel()
            panel.message = "选择 Syncthing 同步的“我的知识库”文件夹"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            guard panel.runModal() == .OK, let selected = panel.url,
                  let marker = try? Data(contentsOf: selected.appendingPathComponent(".knowledge-library.json")),
                  let object = try? JSONSerialization.jsonObject(with: marker) as? [String: Any],
                  object["libraryID"] as? String == "my-knowledge-library-v1" else { return }
            let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/My Knowledge Library/location.json")
            do {
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                let value: [String: Any] = ["schemaVersion": 1, "libraryID": "my-knowledge-library-v1", "relativePath": "我的知识库", "rootPath": selected.path]
                try JSONSerialization.data(withJSONObject: value).write(to: config, options: .atomic)
                root = selected
            } catch { showAlert(title: "保存位置失败", message: error.localizedDescription); return }
        }
        guard let root else { return }
        let metadata = root.appendingPathComponent("元数据/LocalMind")
        var projects: [[String: Any]] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)) ?? [] {
            guard file.lastPathComponent.hasPrefix("projects-"), !file.lastPathComponent.contains("sync-conflict"),
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = record["value"] as? [String: Any] else { continue }
            projects.append(value)
        }
        guard !projects.isEmpty else {
            showAlert(title: "暂未读取到项目库", message: "请先打开更新后的知识库网站，并等待 Syncthing 完成元数据同步。")
            return
        }
        projects.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        picker.addItems(withTitles: projects.map { $0["name"] as? String ?? "未命名项目库" })
        let alert = NSAlert()
        alert.messageText = "存入哪个项目库？"
        alert.informativeText = report.lastPathComponent
        alert.accessoryView = picker
        alert.addButton(withTitle: "存入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              let projectID = projects[picker.indexOfSelectedItem]["id"] as? String else { return }
        publishReportButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                process.executableURL = self.pythonURL
                process.arguments = [self.script("knowledge_library.py"), "publish", "--library", root.path, "--report", report.path, "--project-id", projectID]
                var env = ProcessInfo.processInfo.environment
                let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
                env["PYTHONHOME"] = resources.appendingPathComponent("Python.framework/Versions/3.11").path
                env["PYTHONPATH"] = resources.appendingPathComponent("runtime/lib/python3.11/site-packages").path
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                env["PYTHONNOUSERSITE"] = "1"
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let response = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
                guard process.terminationStatus == 0, let id = response["id"] as? String else {
                    throw NSError(domain: "KnowledgeLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? String(data: bytes, encoding: .utf8) ?? "发布失败"])
                }
                DispatchQueue.main.async {
                    self.publishReportButton.isEnabled = true
                    let done = NSAlert()
                    done.messageText = response["duplicate"] as? Bool == true ? "该报告已在项目库中" : "已存入知识库"
                    done.informativeText = "报告和项目归属会通过 Syncthing 同步到另一台电脑。"
                    done.addButton(withTitle: "在网站查看")
                    done.addButton(withTitle: "完成")
                    if done.runModal() == .alertFirstButtonReturn {
                        var url = URLComponents(string: "http://localhost:3000/workspace")!
                        url.queryItems = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "reportId", value: id)]
                        NSWorkspace.shared.open(url.url!)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.publishReportButton.isEnabled = true
                    self.showAlert(title: "存入失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func readablePreview(from text: String, fileURL: URL) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "预览文件为空：\(fileURL.path)"
        }
        if trimmed.count <= 15000 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 15000)
        return String(trimmed[..<endIndex]) + "\n\n……预览已截取前 15000 个字符，完整内容请打开文件查看。"
    }

    private func appendLog(_ text: String) {
        recentLogLines.append(text)
        if recentLogLines.count > 80 {
            recentLogLines.removeFirst(recentLogLines.count - 80)
        }
        if let logFileURL, let data = (text + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        let attr = NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        logView.textStorage?.append(attr)
        logView.scrollToEndOfDocument(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

let app = NSApplication.shared
app.isAutomaticCustomizeTouchBarMenuItemEnabled = false
NSTouchBar.isAutomaticCustomizeTouchBarMenuItemEnabled = false
let delegate = AppDelegate()
app.delegate = delegate
app.run()
