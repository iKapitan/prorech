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
    /// Копии готовых текстов и их список: история живёт отдельно от записей,
    /// поэтому переживает перенос и удаление текста рядом с записью.
    static var historyDir: URL { home.appendingPathComponent("history") }
    static var historyIndex: URL { historyDir.appendingPathComponent("history.json") }

    /// Модель распознавания, имя папки то же в engine/prorech.py и setup-engine.sh.
    /// У кого стоит версия 1.0 с GigaAM v2, движок считается неготовым,
    /// и установщик докачивает только новую модель.
    static let gigaam = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"

    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// На диске модель версии 1.0: значит это обновление, докачать нужно только модель.
    static var isUpgrade: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(
            "models/sherpa-onnx-nemo-transducer-giga-am-v2-russian-2025-04-19").path)
    }

    static var engineReady: Bool {
        let fm = FileManager.default
        let models = home.appendingPathComponent("models")
        return hasPython
            && fm.fileExists(atPath: models.appendingPathComponent("titanet.onnx").path)
            && fm.fileExists(atPath: models.appendingPathComponent(
                "sherpa-onnx-pyannote-segmentation-3-0/model.onnx").path)
            && fm.fileExists(atPath: models.appendingPathComponent("\(gigaam)/tokens.txt").path)
    }
}

// MARK: - История расшифровок

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: String
    let date: Date
    let title: String       // имя записи без расширения
    let source: String      // путь к записи, как он был в момент расшифровки
    let seconds: Double?    // длина записи, если движок её сообщил
    let speakers: Int

    /// Своя папка на каждую расшифровку, файл назван по записи: при отправке
    /// получатель видит «встреча.txt», а не служебный номер.
    var folder: URL { Paths.historyDir.appendingPathComponent(id) }
    var textURL: URL { folder.appendingPathComponent("\(title).txt") }

    /// Дата и длина: для строки списка, она узкая.
    var short: String {
        var parts = [HistoryItem.dateFormat.string(from: date)]
        if let s = seconds, s > 0 { parts.append("\(max(1, Int((s / 60).rounded()))) мин") }
        return parts.joined(separator: " · ")
    }

    /// Полная подпись над текстом: ещё и сколько говорящих.
    var meta: String {
        speakers > 0 ? short + " · " + HistoryItem.speakersText(speakers) : short
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    static func speakersText(_ n: Int) -> String {
        // «1 говорящий», «21 говорящий», в остальных случаях «говорящих».
        let word = n % 10 == 1 && n % 100 != 11 ? "говорящий" : "говорящих"
        return "\(n) \(word)"
    }

    /// Говорящие считаются по разметке строк «[мм:сс] Говорящий X:».
    static func countSpeakers(_ text: String) -> Int {
        let re = try! NSRegularExpression(pattern: #"^\[[0-9:]+\] Говорящий ([A-Z]):"#,
                                          options: .anchorsMatchLines)
        let ns = text as NSString
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        return Set(found).count
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
    @Published var history: [HistoryItem] = Model.loadHistory()
    @Published var showHistory = false
    @Published var selectedID: String?

    private var process: Process?
    private var queue: [URL] = []
    private var resultURL: URL?
    private var resultSeconds: Double?
    private var lastError = ""
    private var cancelled = false
    private var textCache: [String: String] = [:]
    private let io = DispatchQueue(label: "prorech.io")

    // Очередь: можно бросить несколько записей, они пойдут по одной.
    func open(_ urls: [URL]) {
        dlog("open \(urls.map(\.path)) phase=\(phase)")
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        showHistory = false
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
        resultSeconds = nil
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
        case "длина":
            resultSeconds = Double(value)
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
            addHistory(text: resultText, source: source)
            if queue.isEmpty {
                showHistory = false
                phase = .done
                NSApp.requestUserAttention(.informationalRequest)
            } else {
                next()
            }
        } else {
            let msg = lastError.isEmpty ? "Расшифровка не удалась." : lastError
            showHistory = false
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

    // MARK: история

    /// Запись списка читается сама по себе: одна битая не обнуляет остальные.
    private struct Lenient: Decodable {
        let item: HistoryItem?
        init(from decoder: Decoder) throws {
            item = try? decoder.singleValueContainer().decode(HistoryItem.self)
        }
    }

    static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: Paths.historyIndex) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let rows = try? dec.decode([Lenient].self, from: data)
        if rows == nil || rows!.contains(where: { $0.item == nil }) {
            // Испорченный список не затирается следующим сохранением: копия рядом.
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.copyItem(
                at: Paths.historyIndex,
                to: Paths.historyDir.appendingPathComponent("history-\(stamp).bad.json"))
        }
        let items = (rows ?? []).compactMap(\.item)
        // Запись без файла текста в списке не держим: показать её нечем.
        return items.filter { FileManager.default.fileExists(atPath: $0.textURL.path) }
            .sorted { $0.date > $1.date }
    }

    private func saveHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(history) else { return }
        try? data.write(to: Paths.historyIndex, options: .atomic)
    }

    private func addHistory(text: String, source: URL) {
        let item = HistoryItem(id: UUID().uuidString, date: Date(),
                               title: source.deletingPathExtension().lastPathComponent,
                               source: source.path, seconds: resultSeconds,
                               speakers: HistoryItem.countSpeakers(text))
        do {
            try FileManager.default.createDirectory(at: item.folder,
                                                    withIntermediateDirectories: true)
            try text.write(to: item.textURL, atomically: true, encoding: .utf8)
        } catch {
            dlog("история: не записан текст: \(error)")
            return
        }
        textCache[item.id] = text
        history.insert(item, at: 0)
        saveHistory()
    }

    /// Только для снимков экранов: история из образцов, без записи на диск.
    func seedForSnapshot(_ items: [HistoryItem], texts: [String: String]) {
        textCache = texts
        history = items
        selectedID = items.first?.id
    }

    func text(of item: HistoryItem) -> String {
        if let t = textCache[item.id] { return t }
        let t = (try? String(contentsOf: item.textURL, encoding: .utf8)) ?? ""
        textCache[item.id] = t
        return t
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: item.folder)
        textCache[item.id] = nil
        history.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = history.first?.id }
        saveHistory()
    }

    func openHistory() {
        if selectedID == nil || !history.contains(where: { $0.id == selectedID }) {
            selectedID = history.first?.id
        }
        showHistory = true
    }

    /// «Сохранить как…» из меню: то, что сейчас на экране.
    func saveAs() {
        if showHistory {
            if let item = history.first(where: { $0.id == selectedID }) {
                Export.save(text: text(of: item), title: item.title, date: item.date)
            }
        } else if phase == .done, !resultText.isEmpty {
            let title = doneURLs.last?.deletingPathExtension().lastPathComponent ?? "Расшифровка"
            Export.save(text: resultText, title: title, date: Date())
        }
    }

    var inSetup: Bool { phase == .needsSetup || phase == .settingUp }

    var canSave: Bool {
        showHistory ? selectedID != nil : (phase == .done && !resultText.isEmpty)
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

// MARK: - Сохранить как: документ Word или простой текст

enum Export {
    enum Format: Int { case docx = 0, txt = 1 }

    static let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    private static let formatKey = "exportFormat"

    static func save(text: String, title: String, date: Date) {
        let panel = NSSavePanel()
        panel.title = "Сохранить расшифровку"
        panel.prompt = "Сохранить"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = title
        let picker = FormatPicker(panel: panel)
        // Последний выбранный формат запоминается, в первый раз предлагается Word.
        picker.apply(Format(rawValue: UserDefaults.standard.integer(forKey: formatKey)) ?? .docx)
        panel.accessoryView = picker.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(picker.format.rawValue, forKey: formatKey)
        do {
            switch picker.format {
            case .txt: try text.write(to: url, atomically: true, encoding: .utf8)
            case .docx: try docx(text: text, title: title, date: date).write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Документ Word средствами macOS: заголовок, дата, затем реплики, время
    /// приглушено, говорящий жирным. Шрифт Arial есть и у Word, и на маке.
    static func docx(text: String, title: String, date: Date) throws -> Data {
        let font = NSFont(name: "Arial", size: 11) ?? .systemFont(ofSize: 11)
        let bold = NSFont(name: "Arial-BoldMT", size: 11) ?? .boldSystemFont(ofSize: 11)
        let head = NSFont(name: "Arial-BoldMT", size: 16) ?? .boldSystemFont(ofSize: 16)
        let grey = NSColor(srgbRed: 0.38, green: 0.38, blue: 0.37, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        let out = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: head, .foregroundColor: NSColor.black, .paragraphStyle: para])
        out.append(NSAttributedString(
            string: "Расшифровано в ПРОРЕЧЬ \(f.string(from: date))\n\n",
            attributes: [.font: font, .foregroundColor: grey, .paragraphStyle: para]))
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: para])
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"^(\[[0-9:]+\]) (Говорящий [A-Z]:)"#,
                                          options: .anchorsMatchLines)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            body.addAttribute(.foregroundColor, value: grey, range: m.range(at: 1))
            body.addAttribute(.font, value: bold, range: m.range(at: 2))
        }
        out.append(body)
        return try out.data(from: NSRange(location: 0, length: out.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}

/// Выбор формата внизу окна сохранения. Смена формата меняет и расширение в имени.
final class FormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let view: NSView
    private(set) var format: Export.Format = .docx

    init(panel: NSSavePanel) {
        self.panel = panel
        popup.addItems(withTitles: ["Документ Word (.docx)", "Текст (.txt)"])
        let label = NSTextField(labelWithString: "Формат:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.setFrameSize(stack.fittingSize)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        apply(Export.Format(rawValue: popup.indexOfSelectedItem) ?? .docx)
    }

    func apply(_ f: Export.Format) {
        format = f
        popup.selectItem(at: f.rawValue)
        guard let panel else { return }
        let type: UTType = f == .docx ? Export.docxType : .plainText
        panel.allowedContentTypes = [type]
        let name = panel.nameFieldStringValue as NSString
        let base = ["docx", "txt"].contains(name.pathExtension.lowercased())
            ? name.deletingPathExtension : name as String
        panel.nameFieldStringValue = base + "." + (f == .docx ? "docx" : "txt")
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
                if m.showHistory || !m.inSetup {
                    HistoryButton(m: m)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)

            Group {
                if m.showHistory {
                    HistoryView(m: m)
                } else {
                    switch m.phase {
                    case .needsSetup: SetupView(m: m, running: false)
                    case .settingUp: SetupView(m: m, running: true)
                    case .idle: IdleView(m: m)
                    case .working: WorkingView(m: m)
                    case .done: DoneView(m: m)
                    case .failed(let msg): FailedView(m: m, message: msg)
                    }
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
        .frame(minWidth: 640, minHeight: 540)
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
            Text("На маке с чипом M расшифровка обычно занимает около десятой части длины записи. Окно можно свернуть: когда текст будет готов, значок в Dock подпрыгнет.")
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
                .buttonStyle(.borderedProminent).tint(.kpAcid)
                Button("Сохранить как…") { m.saveAs() }
                Button(copied ? "Скопировано" : "Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.resultText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(m.doneURLs)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Показать в Finder")
                Spacer()
                Button("Новая запись") { m.reset() }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - История: список слева, текст справа

/// Кнопка в шапке. Цвета как у переключателя «Сколько человек говорит»:
/// системная подсветка синяя, а синего в бренде нет.
struct HistoryButton: View {
    @ObservedObject var m: Model

    var body: some View {
        let on = m.showHistory
        Button {
            if on { m.showHistory = false } else { m.openHistory() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text(on ? "Закрыть историю" : "История")
                if !on && !m.history.isEmpty {
                    Text("\(m.history.count)").foregroundColor(.kpStone)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? Color.kpInk : Color.kpCard)
            .foregroundColor(on ? Color.kpBg : Color.kpInk)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.clear : Color.kpHair))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HistoryView: View {
    @ObservedObject var m: Model
    @State private var query = ""
    @State private var confirmDelete = false
    @State private var copied = false

    private var found: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return m.history }
        return m.history.filter {
            $0.title.lowercased().contains(q) || m.text(of: $0).lowercased().contains(q)
        }
    }

    private var selected: HistoryItem? { m.history.first { $0.id == m.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.phase == .working {
                // Расшифровка идёт дальше, пока открыта история.
                HStack(spacing: 10) {
                    ProgressView(value: m.progress).tint(.kpAcid).frame(width: 90)
                    Text("Расшифровываю \(m.fileName)")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Показать") { m.showHistory = false }
                        .buttonStyle(.link).font(.system(size: 12.5, weight: .medium))
                }
            }
            if m.history.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: 14) {
                    list.frame(width: 220)
                    if let item = selected {
                        detail(item)
                    } else {
                        Text("Выберите расшифровку слева")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .medium))
            Text("Здесь будут все расшифровки").font(.system(size: 18, weight: .semibold))
            Text("Каждый готовый текст сохраняется в истории и остаётся здесь, даже если файл рядом с записью перенести или удалить.")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.kpStone)
                TextField("Поиск по истории", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.kpCard)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kpHair))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(found) { item in row(item) }
                    if found.isEmpty {
                        Text("Ничего не нашлось")
                            .font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
                            .padding(.top, 16)
                    }
                }
                .padding(4)
            }
            .background(Color.kpCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kpHair))
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        let on = item.id == m.selectedID
        return Button { m.selectedID = item.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.short).font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(on ? Color.kpBg.opacity(0.7) : .kpStone)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Color.kpInk : Color.clear)
            .foregroundColor(on ? Color.kpBg : Color.kpInk)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actions(_ item: HistoryItem, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button("Сохранить как…") {
                Export.save(text: m.text(of: item), title: item.title, date: item.date)
            }
            .buttonStyle(.borderedProminent).tint(.kpAcid)
            .fixedSize()
            ShareLink(item: item.textURL) {
                if compact {
                    Image(systemName: "square.and.arrow.up")
                } else {
                    Label("Отправить", systemImage: "square.and.arrow.up")
                }
            }
            .help("Отправить")
            .fixedSize()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.text(of: item), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                if compact {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                } else {
                    Text(copied ? "Скопировано" : "Скопировать")
                }
            }
            .help("Скопировать текст")
            .fixedSize()
            Spacer(minLength: 8)
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Удалить из истории")
                .fixedSize()
        }
    }

    private func detail(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 16, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.meta).font(.system(size: 12.5, weight: .medium)).foregroundColor(.kpStone)
            }
            TextPreview(text: m.text(of: item))
                .background(Color.kpCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kpHair))
            // В узком окне подписи «Отправить» и «Скопировать» уходят в значки,
            // чтобы «Сохранить как…» не обрезалось.
            ViewThatFits(in: .horizontal) {
                actions(item, compact: false)
                actions(item, compact: true)
            }
        }
        .confirmationDialog("Удалить расшифровку из истории?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                // Дальше открывается соседняя запись из найденных, а не первая из всей истории.
                let list = found
                let i = list.firstIndex(of: item) ?? 0
                let rest = list.filter { $0.id != item.id }
                m.delete(item)
                m.selectedID = rest.isEmpty ? m.history.first?.id : rest[min(i, rest.count - 1)].id
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текст рядом с записью, если он там есть, останется.")
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
            // На диске модель 1.0, значит это обновление: нужна только новая модель.
            Text(running ? m.setupStep
                 : Paths.isUpgrade ? "Осталось докачать новую модель распознавания"
                 : "Осталось докачать движок и модели")
                .font(.system(size: 18, weight: .semibold))
            Text(Paths.isUpgrade
                 ? "Один раз, около 170 МБ. Новая модель быстрее, ставит знаки препинания и пишет латиницу и цифры. Записи по-прежнему никуда не уходят."
                 : "Один раз, около 400 МБ, обычно 5-10 минут. Дальше расшифровка работает без интернета, записи никуда не уходят.")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.kpStone)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if running {
                if m.setupProgress > 0 {
                    ProgressView(value: m.setupProgress).tint(.kpAcid).frame(width: 320)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button(Paths.isUpgrade ? "Докачать" : "Установить") { m.setup() }
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
            [00:00] Говорящий A: Добрый день. Давайте начнём с плана на неделю, у нас три задачи.
            [00:05] Говорящий B: Да, согласен. Первая задача: сроки поставки оборудования, их нужно подтвердить до пятницы.
            [00:12] Говорящий A: Хорошо, записываю. Кто возьмёт вторую задачу?
            [00:17] Говорящий B: Вторую возьму я, а третью обсудим завтра в 10 утра в Zoom.

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
            ("5-istoriya", {
                let now = Date()
                let items = [
                    HistoryItem(id: "s1", date: now, title: "встреча", source: txt.path,
                                seconds: 1260, speakers: 2),
                    HistoryItem(id: "s2", date: now.addingTimeInterval(-86400 * 2 - 5400),
                                title: "созвон с подрядчиком", source: "", seconds: 2280, speakers: 3),
                    HistoryItem(id: "s3", date: now.addingTimeInterval(-86400 * 6 - 9000),
                                title: "интервью, часть 1", source: "", seconds: 3540, speakers: 2)]
                m.seedForSnapshot(items, texts: ["s1": sample, "s2": sample, "s3": sample])
                m.phase = .idle; m.showHistory = true }),
            ("6-istoriya-pusto", { m.seedForSnapshot([], texts: [:]) }),
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
        .defaultSize(width: 720, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Выбрать запись…") { model.pickFile() }
                    .keyboardShortcut("o")
                Button("История") { model.openHistory() }
                    .keyboardShortcut("y")
                    .disabled(model.inSetup)
                // Не в группе .saveItem: её замена убирает и «Закрыть» (Cmd + W).
                Divider()
                Button("Сохранить как…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSave)
            }
        }
    }
}
