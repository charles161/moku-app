import AppKit
import MokuKit
import MokuSense

// moku-sense: prints Moku's live SenseEvents as JSON lines.

let usage = """
    usage: moku-sense [--duration <sec>] [--interval <sec>] [--no-ocr] [--full-text] [--out <file.jsonl>] [--request-permissions]

      --duration <sec>        stop after this many seconds (default: run until Ctrl-C)
      --interval <sec>        seconds between samples (default: 3)
      --no-ocr                never OCR the focused window
      --full-text             print sample text in full (default: first 200 characters)
      --out <file.jsonl>      also write every full ActivitySample, one per line, for the brain's `npm run replay`
      --request-permissions   show the system prompts for Accessibility and Screen Recording first
    """

struct Options {
    var duration: TimeInterval?
    var interval: TimeInterval = 3
    var ocr = true
    var fullText = false
    var outPath: String?
    var requestPermissions = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var rest = arguments[...]
        func value(for flag: String) -> String {
            guard let value = rest.popFirst() else { fail("\(flag) needs a value") }
            return value
        }
        func seconds(for flag: String) -> TimeInterval {
            guard let seconds = TimeInterval(value(for: flag)), seconds > 0 else { fail("\(flag) needs a positive number of seconds") }
            return seconds
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--duration": options.duration = seconds(for: flag)
            case "--interval": options.interval = seconds(for: flag)
            case "--no-ocr": options.ocr = false
            case "--full-text": options.fullText = true
            case "--out": options.outPath = value(for: flag)
            case "--request-permissions": options.requestPermissions = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default: fail("unknown argument \(flag)")
            }
        }
        return options
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("moku-sense: \(message)\n\(usage)\n".utf8))
        exit(2)
    }
}

/// One printed line per SenseEvent: `{"type": ..., ...}`.
struct EventLine: Encodable {
    let event: SenseEvent
    let fullText: Bool
    static let previewLength = 200

    enum Keys: String, CodingKey {
        case type, accessibility, screenRecording, sample, app, window, x, y, context
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch event {
        case .permissions(let status):
            try container.encode("permissions", forKey: .type)
            try container.encode(status.accessibility, forKey: .accessibility)
            try container.encode(status.screenRecording, forKey: .screenRecording)
        case .sample(var sample):
            if !fullText, let text = sample.text, text.count > Self.previewLength {
                sample.text = text.prefix(Self.previewLength) + "…"
            }
            try container.encode("sample", forKey: .type)
            try container.encode(sample, forKey: .sample)
        case .focusChanged(let app, let window):
            try container.encode("focusChanged", forKey: .type)
            try container.encode(app, forKey: .app)
            try container.encode(window, forKey: .window)
        case .attention(let point):
            try container.encode("attention", forKey: .type)
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        case .meeting(let context):
            try container.encode("meeting", forKey: .type)
            try container.encode(context, forKey: .context)
        }
    }

    var type: String {
        switch event {
        case .permissions: "permissions"
        case .sample: "sample"
        case .focusChanged: "focusChanged"
        case .attention: "attention"
        case .meeting: "meeting"
        }
    }
}

@MainActor
final class Runner {
    private let options: Options
    private let hub: SenseHub
    private let encoder = MokuJSON.encoder()
    private let sampleFile: FileHandle?
    private var counts: [String: Int] = [:]
    private var signalSource: DispatchSourceSignal?
    private let started = Date()

    init(options: Options) {
        self.options = options
        hub = SenseHub(sampleInterval: options.interval, ocrEnabled: options.ocr)
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        if let path = options.outPath {
            guard FileManager.default.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path) else {
                Options.fail("cannot write \(path)")
            }
            sampleFile = handle
        } else {
            sampleFile = nil
        }
    }

    func run() {
        let status = SenseHub.permissionStatus()
        if !status.accessibility {
            note("no Accessibility: no window titles from Accessibility, no browser URLs, no accessibility text; key and click counts come from system-wide counters")
        }
        if !status.screenRecording {
            note("no Screen Recording: no OCR, and other apps' window titles are hidden")
        }
        Task { [hub] in
            for await event in hub.events { self.handle(event) }
        }
        hub.start()

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.finishSoon() }
        }
        source.resume()
        signalSource = source

        if let duration = options.duration {
            Task {
                try? await Task.sleep(for: .seconds(duration))
                await self.finish()
            }
        }
    }

    private func handle(_ event: SenseEvent) {
        let line = EventLine(event: event, fullText: options.fullText)
        counts[line.type, default: 0] += 1
        write(line, to: .standardOutput)
        if case .sample(let sample) = event, let sampleFile {
            write(sample, to: sampleFile)
        }
    }

    private func write(_ value: some Encodable, to handle: FileHandle) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        handle.write(data)
    }

    private func finishSoon() {
        Task { await finish() }
    }

    private func finish() async {
        hub.stop()
        let diagnostics = await hub.diagnostics()
        try? sampleFile?.close()
        let seconds = Date().timeIntervalSince(started)
        let events = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let meanOCR = diagnostics.ocrRuns > 0 ? diagnostics.ocrMilliseconds / Double(diagnostics.ocrRuns) : 0
        note(String(format: "%.0f s: %@ | OCR runs=%d mean=%.0f ms | accessibility text reads=%d",
                    seconds, events, diagnostics.ocrRuns, meanOCR, diagnostics.accessibilityTextReads))
        exit(0)
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("moku-sense: \(message)\n".utf8))
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
if options.requestPermissions {
    SenseHub.requestPermissions()
}
let runner = Runner(options: options)
runner.run()
application.run()
