// ПРОРЕЧЬ, транскрибация от Kirov Pro: окно поверх локального движка.
//
// Приложение само ничего не распознаёт. Оно запускает движок на Python
// (engine/prorech.py лежит внутри приложения, Python и модели в папке
// пользователя), читает его служебные строки «@этап доля» и показывает
// прогресс. Готовый текст ложится рядом с записью, отправить его можно
// стандартным меню macOS.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Пути

enum Paths {
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["PRORECH_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KirovPro/Prorech")
    }
    static var python: URL { home.appendingPathComponent("venv/bin/python") }
    static var zameny: URL { home.appendingPathComponent("zameny.txt") }
    static var script: URL? { Bundle.main.url(forResource: "prorech", withExtension: "py") }
    static var setup: URL? { Bundle.main.url(forResource: "setup-engine", withExtension: "sh") }

    static var engineReady: Bool {
        let fm = FileManager.default
        let models = home.appendingPathComponent("models")
        let giga = (try? fm.contentsOfDirectory(atPath: models.path))?
            .contains { $0.hasPrefix("sherpa-onnx-nemo-transducer-giga-am") } ?? false
        return fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: models.appendingPathComponent("titanet.onnx").path)
            && fm.fileExists(atPath: models.appendingPathComponent(
                "sherpa-onnx-pyannote-segmentation-3-0/model.onnx").path)
            && giga
    }
}

/// Журнал для отладки: пишет в stderr, только если задан PRORECH_DEBUG.
func dlog(_ s: String) {
    if ProcessInfo.processInfo.environment["PRORECH_DEBUG"] != nil {
        FileHandle.standardError.write(("[prorech] " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - Цвета KirovPro: светлая база, графит, один кислотный акцент

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let v = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
    static let kpBg = dyn(0xF2F2F0, 0x151515)
    static let kpCard = dyn(0xFFFFFF, 0x1F1F1F)
    static let kpInk = dyn(0x0A0A0A, 0xF2F2F0)
    static let kpStone = dyn(0x62625F, 0xA3A3A0)
    static let kpHair = dyn(0xDEDEDA, 0x343434)
    static let kpAcid = Color(red: 1, green: 59 / 255, blue: 20 / 255)
}

// MARK: - Движок

enum Phase: Equatable {
    case needsSetup, settingUp, idle, working, done
    case failed(String)
}

/// Режет вывод процесса на строки. curl рисует прогресс через \r, поэтому
/// строка заканчивается и на \n, и на \r.
final class LineReader {
    private var buf = Data()
    private let onLine: (String) -> Void
    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        buf.append(d)
        while let i = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buf[buf.startIndex..<i]
            buf.removeSubrange(buf.startIndex...i)
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { onLine(s) }
        }
    }

    func flush() {
        if !buf.isEmpty, let s = String(data: buf, encoding: .utf8) { onLine(s) }
        buf.removeAll()
    }
}

final class Model: ObservableObject {
    static let shared = Model()

    @Published var phase: Phase = Paths.engineReady ? .idle : .needsSetup
    @Published var setupStep = ""
    @Published var setupProgress: Double = 0
    @Published var fileName = ""
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var startedAt = Date()
    @Published var doneURLs: [URL] = []
    @Published var resultText = ""
    @Published var speakers = 0
    @Published var queueCount = 0
    @Published var dropHover = false

    private var process: Process?
    private var queue: [URL] = []
    private var resultURL: URL?
    private var lastError = ""
    private var cancelled = false
    private let io = DispatchQueue(label: "prorech.io")

    // Очередь: можно бросить несколько записей, они пойдут по одной.
    func open(_ urls: [URL]) {
        dlog("open \(urls.map(\.path)) phase=\(phase)")
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        if phase == .done { doneURLs = [] }
        queue.append(contentsOf: files)
        queueCount = queue.count
        if phase == .idle || phase == .done || isFailed { next() }
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Выберите запись разговора"
        panel.prompt = "Расшифровать"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        let url = queue.removeFirst()
        queueCount = queue.count
        start(url)
    }

    private func start(_ url: URL) {
        guard let script = Paths.script else {
            phase = .failed("Приложение собрано без движка. Переустановите его.")
            return
        }
        fileName = url.lastPathComponent
        stage = "Загружаю модели"
        progress = 0
        startedAt = Date()
        resultURL = nil
        lastError = ""
        cancelled = false
        phase = .working
        var args = [script.path, "--progress"]
        if speakers > 0 { args += ["-n", String(speakers)] }
        args.append(url.path)
        run(Paths.python, args, onLine: { [weak self] in self?.engineLine($0) },
            done: { [weak self] code in self?.engineDone(code, source: url) })
    }

    private func engineLine(_ line: String) {
        dlog("engine: \(line)")
        guard line.hasPrefix("@") else { return }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let tag = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch tag {
        case "голоса":
            stage = "Разделяю по голосам"
            progress = 0.35 * (Double(value) ?? 0)
        case "текст":
            stage = "Распознаю речь"
            progress = 0.35 + 0.65 * (Double(value) ?? 0)
        case "готово":
            resultURL = URL(fileURLWithPath: value)
        case "ошибка":
            lastError = value
        default:
            break
        }
    }

    private func engineDone(_ code: Int32, source: URL) {
        dlog("engineDone code=\(code) result=\(resultURL?.path ?? "nil") err=\(lastError)")
        process = nil
        if cancelled {
            queue.removeAll()
            queueCount = 0
            phase = doneURLs.isEmpty ? .idle : .done
            return
        }
        // Строка «@готово» могла не успеть: тогда текст ищется там, где его пишет движок.
        let expected = source.deletingPathExtension().appendingPathExtension("txt")
        let out = resultURL ?? expected
        if code == 0, FileManager.default.fileExists(atPath: out.path) {
            doneURLs.append(out)
            resultText = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            if queue.isEmpty {
                phase = .done
                NSApp.requestUserAttention(.informationalRequest)
            } else {
                next()
            }
        } else {
            let msg = lastError.isEmpty ? "Расшифровка не удалась." : lastError
            phase = .failed(msg.prefix(1).uppercased() + msg.dropFirst())
            queue.removeAll()
            queueCount = 0
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func reset() {
        doneURLs = []
        resultText = ""
        phase = Paths.engineReady ? .idle : .needsSetup
    }

    // MARK: установка движка

    func setup() {
        guard let sh = Paths.setup else {
            phase = .failed("Приложение собрано без установщика. Переустановите его.")
            return
        }
        phase = .settingUp
        setupStep = "Готовлюсь"
        setupProgress = 0
        lastError = ""
        run(URL(fileURLWithPath: "/bin/bash"), [sh.path], onLine: { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("@шаг ") {
                self.setupStep = String(line.dropFirst(5))
                self.setupProgress = 0
            } else if line.hasPrefix("@ошибка ") {
                self.lastError = String(line.dropFirst(8))
            } else if let pct = Model.percent(in: line) {
                self.setupProgress = pct / 100
            }
        }, done: { [weak self] code in
            guard let self else { return }
            self.process = nil
            if code == 0 && Paths.engineReady {
                self.phase = .idle
                self.next()
            } else {
                let msg = self.lastError.isEmpty ? "не удалось установить движок" : self.lastError
                self.phase = .failed(msg.prefix(1).uppercased() + msg.dropFirst())
            }
        })
    }

    static func percent(in line: String) -> Double? {
        guard let r = line.range(of: #"([0-9]+(\.[0-9]+)?)%"#, options: .regularExpression) else {
            return nil
        }
        return Double(line[r].dropLast())
    }

    func openZameny() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.zameny.path) {
            try? fm.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            let template = """
                # Словарь замен. Строка на замену: как слышится = как писать.
                # Замены применяются к готовому тексту, без учёта регистра.
                # присейл = пресейл
                # джира = Jira

                """
            try? template.write(to: Paths.zameny, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.zameny)
    }

    // MARK: запуск процесса

    private func run(_ exe: URL, _ args: [String], onLine: @escaping (String) -> Void,
                     done: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let reader = LineReader { line in DispatchQueue.main.async { onLine(line) } }
        let io = self.io
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { io.async { reader.feed(d) } }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            io.async {
                reader.feed(rest)
                reader.flush()
                DispatchQueue.main.async { done(status) }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Не удалось запустить движок: \(error.localizedDescription)")
        }
    }
}

// MARK: - Знак ПРОРЕЧЬ: звуковая волна, строки текста и кислотный штрих перехода.
// Геометрия из бренд-кита (prorech-icon-dark.svg, поле 1024), скругление как у подписи.

struct ProrechMark: View {
    var size: CGFloat = 34
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 1024
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 227 * s),
                     with: .color(Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)))
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Color) {
                ctx.fill(Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
                              cornerRadius: min(w, h) / 2 * s), with: .color(c))
            }
            let white: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (190, 435, 38, 154), (264, 366, 38, 292), (416, 347, 38, 330), (490, 420, 38, 184),
                (598, 356, 260, 38), (598, 474, 224, 38), (598, 592, 176, 38)]
            for b in white { bar(b.0, b.1, b.2, b.3, .white) }
            bar(338, 282, 42, 460, .kpAcid)
        }
        .frame(width: size, height: size)
        // В тёмной теме графитовая плашка сливается с фоном, тонкий контур её держит.
        .overlay(RoundedRectangle(cornerRadius: 227 * size / 1024).strokeBorder(Color.kpHair))
    }
}

// MARK: - Текст расшифровки: время приглушено, говорящий выделен

struct TextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        sv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, tv.string != text else { return }
        tv.textStorage?.setAttributedString(Self.styled(text))
    }

    static func styled(_ text: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.lineSpacing = 2
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"^(\[[0-9:]+\]) (Говорящий [A-Z]:)"#,
                                          options: .anchorsMatchLines)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                               .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)],
                              range: m.range(at: 1))
            out.addAttributes([.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)],
                              range: m.range(at: 2))
        }
        return out
    }
}

// MARK: - Экраны

struct ContentView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProrechMark(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ПРОРЕЧЬ").font(.system(size: 19, weight: .bold)).tracking(-0.2)
                    Text("Транскрибация от Kirov Pro")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)

            Group {
                switch m.phase {
                case .needsSetup: SetupView(m: m, running: false)
                case .settingUp: SetupView(m: m, running: true)
                case .idle: IdleView(m: m)
                case .working: WorkingView(m: m)
                case .done: DoneView(m: m)
                case .failed(let msg): FailedView(m: m, message: msg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            HStack {
                Text("Kirov Pro · Цифровое ателье")
                    .font(.system(size: 11.5, weight: .medium)).foregroundColor(.kpStone)
                Spacer()
                Button("Словарь замен") { m.openZameny() }
                    .buttonStyle(.link).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.kpHair).frame(height: 1) }
        }
        .foregroundColor(.kpInk)
        .frame(minWidth: 600, minHeight: 520)
        .background(Color.kpBg)
        .onDrop(of: [.fileURL], isTargeted: $m.dropHover) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { m.open([url]) } }
                }
            }
            return true
        }
    }
}

struct IdleView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.kpCard)
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundColor(m.dropHover ? .kpAcid : .kpHair)
                VStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(m.dropHover ? .kpAcid : .kpInk)
                    Text("Перетащите запись сюда").font(.system(size: 18, weight: .semibold))
                    Text("m4a, mp3, wav или aiff, с диктофона или телефона")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                    Button("Выбрать запись…") { m.pickFile() }
                        .controlSize(.large).padding(.top, 6)
                }
                .padding(24)
            }
            HStack(spacing: 12) {
                Text("Сколько человек говорит").font(.system(size: 13, weight: .medium))
                Spacer()
                // Свой переключатель: системный красит выбор в синий, а синего в бренде нет.
                HStack(spacing: 2) {
                    ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { n in
                        let on = m.speakers == n
                        Button { m.speakers = n } label: {
                            Text(n == 0 ? "Определить" : "\(n)")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1).fixedSize()
                                .frame(minWidth: 26)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(on ? Color.kpInk : Color.clear)
                                .foregroundColor(on ? Color.kpBg : Color.kpInk)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .fixedSize()
                .background(Color.kpCard)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kpHair))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct WorkingView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text(m.fileName).font(.system(size: 18, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(m.stage).font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
            ProgressView(value: m.progress).tint(.kpAcid)
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(m.startedAt))
                    Text("Прошло \(s / 60):\(String(format: "%02d", s % 60))")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundColor(.kpStone)
                }
                Spacer()
                if m.queueCount > 0 {
                    Text("В очереди ещё \(m.queueCount)")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
                }
            }
            Text("Обычно расшифровка занимает около четверти длины записи. Окно можно свернуть: когда текст будет готов, значок в Dock подпрыгнет.")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer()
            HStack {
                Spacer()
                Button("Отменить") { m.cancel() }.controlSize(.large)
            }
        }
    }
}

struct DoneView: View {
    @ObservedObject var m: Model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Готово").font(.system(size: 18, weight: .semibold))
                Text(m.doneURLs.last?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if m.doneURLs.count > 1 {
                Text("Расшифровано записей: \(m.doneURLs.count). Все тексты лежат рядом с записями, «Отправить» отдаст их вместе.")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
            }
            TextPreview(text: m.resultText)
                .background(Color.kpCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kpHair))
            HStack(spacing: 10) {
                ShareLink(items: m.doneURLs) {
                    Label("Отправить", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent).tint(.kpAcid).controlSize(.large)
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(m.doneURLs)
                }
                .controlSize(.large)
                Button(copied ? "Скопировано" : "Скопировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.resultText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .controlSize(.large)
                Spacer()
                Button("Новая запись") { m.reset() }.controlSize(.large)
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var m: Model
    let running: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36, weight: .medium))
            Text(running ? m.setupStep : "Осталось докачать движок и модели")
                .font(.system(size: 18, weight: .semibold))
            Text("Один раз, около 400 МБ, обычно 5-10 минут. Дальше расшифровка работает без интернета, записи никуда не уходят.")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if running {
                if m.setupProgress > 0 {
                    ProgressView(value: m.setupProgress).tint(.kpAcid).frame(width: 320)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("Установить") { m.setup() }
                    .buttonStyle(.borderedProminent).tint(.kpAcid).controlSize(.large)
            }
            Spacer()
        }
    }
}

struct FailedView: View {
    @ObservedObject var m: Model
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .medium)).foregroundColor(.kpAcid)
            Text(message).font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button("Назад") { m.reset() }.controlSize(.large)
            Spacer()
        }
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Запись, брошенная на значок в Dock или открытая через «Открыть в программе».
    func application(_ application: NSApplication, open urls: [URL]) {
        dlog("delegate open \(urls.count)")
        DispatchQueue.main.async { Model.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { Model.shared.cancel() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            Snapshot.run(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
}

/// Снимки экранов для README: приложение само проходит по состояниям,
/// фотографирует окно и закрывается. Запуск: Prorech --snapshot папка
enum Snapshot {
    static func run(to dir: URL) {
        let m = Model.shared
        let sample = """
            [00:00] Говорящий A: добрый день давайте начнем с плана на неделю у нас три задачи
            [00:05] Говорящий B: да согласен первая задача это сроки поставки оборудования их нужно подтвердить до пятницы
            [00:12] Говорящий A: хорошо записываю кто возьмет вторую задачу
            [00:17] Говорящий B: вторую возьму я а третью обсудим завтра утром

            """
        let txt = dir.appendingPathComponent("встреча.txt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? sample.write(to: txt, atomically: true, encoding: .utf8)
        let steps: [(String, () -> Void)] = [
            ("1-zapis", { m.phase = .idle }),
            ("2-rabota", {
                m.fileName = "встреча.m4a"; m.stage = "Распознаю речь"; m.progress = 0.62
                m.startedAt = Date().addingTimeInterval(-133); m.phase = .working }),
            ("3-gotovo", { m.doneURLs = [txt]; m.resultText = sample; m.phase = .done }),
            ("4-ustanovka", { m.phase = .needsSetup }),
        ]
        func shoot(_ i: Int) {
            guard i < steps.count else { NSApp.terminate(nil); return }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let w = NSApp.windows.first(where: { $0.isVisible }), let v = w.contentView {
                    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("\(steps[i].0).png"))
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Неактивное окно macOS рисует без акцентного цвета, снимаем активное.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            shoot(0)
        }
    }
}

@main
struct ProrechApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = Model.shared

    var body: some Scene {
        Window("ПРОРЕЧЬ", id: "main") {
            ContentView(m: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Выбрать запись…") { model.pickFile() }
                    .keyboardShortcut("o")
            }
        }
    }
}
