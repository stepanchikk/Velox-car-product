import Foundation

/// Точка маршруту (широта і довгота в градусах)
nonisolated struct RoutePoint: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Один рядок CSV поїздки (порядок колонок відповідає TripCSVWriter.header)
nonisolated struct TelemetryRow {
    let time: TimeInterval          // секунди від «Старт»
    let filtered: Double            // Filtered_Y, G
    let state: String               // State
    let event: String               // Event (може бути порожнім)
    let raw: Double                 // Raw_Y, G
    let userAcceleration: Vector3   // Ax, Ay, Az, G
    let rotationRate: Vector3       // Gx, Gy, Gz, рад/с (гіроскоп в осях телефона)
    let tiltDegrees: Double         // Tilt_deg
    let score: Int                  // Score
    let speed: Double?              // Speed_mps (nil: GPS немає або дані застарілі)
    let coordinate: RoutePoint?     // Lat, Lon (nil: маршрут не зберігається або немає GPS)

    var csvLine: String {
        let safeState = state.replacingOccurrences(of: ",", with: "")
        let a = userAcceleration
        let g = rotationRate
        let speedText = speed.map { "\($0)" } ?? ""
        let lat = coordinate.map { "\($0.latitude)" } ?? ""
        let lon = coordinate.map { "\($0.longitude)" } ?? ""
        return "\(time),\(filtered),\(safeState),\(event),\(raw),\(a.x),\(a.y),\(a.z),\(g.x),\(g.y),\(g.z),\(tiltDegrees),\(score),\(speedText),\(lat),\(lon)"
    }
}

// MARK: - Параметри запису

/// Службові рядки на початку CSV у форматі "# ключ=значення": з якими
/// параметрами алгоритмів, на якій версії застосунку і на якому пристрої
/// записано поїздку. Завдяки ним analyzer.py перераховує події саме з тими
/// параметрами, з якими працював застосунок, навіть якщо VeloxConfig потім змінився.
/// pandas читає такий файл з параметром comment="#" або skiprows.
nonisolated struct TripMetadata: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        let key: String
        let value: String
    }

    static let linePrefix = "#"
    // Версія формату файлу: 2 - з рядками параметрів,
    // 3 - додано гіроскоп (Gx, Gy, Gz) і маршрут (Lat, Lon)
    static let formatVersion = "3"

    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    subscript(key: String) -> String? {
        entries.last { $0.key == key }?.value
    }

    func double(_ key: String) -> Double? {
        self[key].flatMap(Double.init)
    }

    /// Додає або замінює значення. Переноси рядків і коми прибираються,
    /// щоб службовий рядок лишався одним рядком і не плутав CSV-читачі.
    mutating func set(_ key: String, _ value: String) {
        let clean = value.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: ",", with: " ")
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, value: clean))
    }

    var lines: [String] {
        entries.map { "\(Self.linePrefix) \($0.key)=\($0.value)" }
    }

    /// Розбирає рядок "# ключ=значення"; nil для будь-якого іншого рядка
    static func parseLine<S: StringProtocol>(_ line: S) -> Entry? {
        guard line.hasPrefix(linePrefix) else { return nil }
        let body = line.dropFirst(linePrefix.count)
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = body[..<eq].trimmingCharacters(in: .whitespaces)
        let value = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return Entry(key: key, value: value)
    }

    // MARK: Поточні параметри

    /// Параметри алгоритмів з VeloxConfig; імена ключів збігаються з іменами
    /// констант, тому analyzer.py зіставляє їх без окремої таблиці
    static var configValues: [(key: String, value: Double)] {
        [
            ("sampleInterval", VeloxConfig.sampleInterval),
            ("filterAlpha", VeloxConfig.filterAlpha),
            ("maneuverThreshold", VeloxConfig.maneuverThreshold),
            ("maneuverCooldown", VeloxConfig.maneuverCooldown),
            ("distractionGracePeriod", VeloxConfig.distractionGracePeriod),
            ("distractionCooldown", VeloxConfig.distractionCooldown),
            ("distractionDurationStep", VeloxConfig.distractionDurationStep),
            ("distractionDurationPenalty", Double(VeloxConfig.distractionDurationPenalty)),
            ("distractionDurationPenaltyMax", Double(VeloxConfig.distractionDurationPenaltyMax)),
            ("maneuverPenalty", Double(VeloxConfig.maneuverPenalty)),
            ("distractionPenalty", Double(VeloxConfig.distractionPenalty)),
            ("safeScoreMin", Double(VeloxConfig.safeScoreMin)),
            ("mediumScoreMin", Double(VeloxConfig.mediumScoreMin)),
            ("recalibrationAngle", VeloxConfig.recalibrationAngle),
            ("recalibrationHold", VeloxConfig.recalibrationHold),
            ("recalibrationRetryDelay", VeloxConfig.recalibrationRetryDelay),
        ]
    }

    /// Набір параметрів для нової поїздки; route - чи пишуться координати
    static func recording(startedAt: Date, route: Bool = false) -> TripMetadata {
        var metadata = TripMetadata()
        metadata.set("format", formatVersion)
        metadata.set("route", route ? "on" : "off")
        metadata.set("app", appVersion)
        metadata.set("device", deviceModel)
        metadata.set("os", osVersion)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        metadata.set("started", formatter.string(from: startedAt))
        for item in configValues {
            metadata.set(item.key, format(item.value))
        }
        return metadata
    }

    /// Ключі параметрів, значення яких відрізняються від поточного VeloxConfig
    var changedParameters: [String] {
        Self.configValues.compactMap { item in
            guard let recorded = double(item.key) else { return nil }
            return abs(recorded - item.value) > 1e-9 ? item.key : nil
        }
    }

    /// 2.0 -> "2", 0.4 -> "0.4"
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(value)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // Модель на кшталт "iPhone15,2" (у симуляторі - архітектура комп'ютера)
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - Результат збереження

nonisolated enum TripSaveResult: Equatable {
    /// Файл збережено; warning - якщо частину рядків дописати не вдалося
    case saved(fileName: String, warning: String?)
    /// Жодного виміру (запис зупинено під час калібрування): файл видалено
    case empty
    /// Файл не було створено
    case notCreated

    var message: String {
        switch self {
        case .saved(let fileName, let warning):
            return warning ?? "Дані поїздки збережено: \(fileName)"
        case .empty:
            return "Даних для збереження немає, файл не створено."
        case .notCreated:
            return "Файл поїздки не було створено."
        }
    }
}

// MARK: - Запис файлу

/// Запис поїздки у CSV. Файл із параметрами і заголовком створюється на старті,
/// рядки накопичуються в буфері й дописуються частинами, тому при аварійному
/// завершенні застосунку втрачається не більше flushEveryRows останніх рядків.
nonisolated final class TripCSVWriter {
    static let header = "Timestamp,Filtered_Y,State,Event,Raw_Y,Ax,Ay,Az,Gx,Gy,Gz,Tilt_deg,Score,Speed_mps,Lat,Lon"

    let flushEveryRows: Int
    private var pendingRows: [String] = []
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private(set) var fileName: String = ""
    // Кількість рядків-вимірів (без службових рядків подій)
    private(set) var recordedSamples: Int = 0

    init(flushEveryRows: Int = 100) {   // ~10 с при 10 Гц
        self.flushEveryRows = flushEveryRows
    }

    /// Створює файл у каталозі Documents і відкриває його для дописування.
    /// metadata записується перед заголовком колонок. Повертає текст помилки або nil.
    func open(fileName: String, metadata: TripMetadata = TripMetadata()) -> String? {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Не вдалося знайти папку для збереження файлу."
        }
        let url = documentDirectory.appendingPathComponent(fileName)
        let head = (metadata.lines + [Self.header]).joined(separator: "\n") + "\n"
        do {
            try head.write(to: url, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: url)
            _ = try handle.seekToEnd()
            fileHandle = handle
            fileURL = url
            self.fileName = fileName
            pendingRows.removeAll()
            recordedSamples = 0
            return nil
        } catch {
            return "Не вдалося створити файл поїздки: \(error.localizedDescription)"
        }
    }

    /// Додає рядок; isSample = true для вимірів, false для службових подій.
    /// Повертає текст помилки, якщо не вдалося дописати буфер у файл.
    func append(_ row: TelemetryRow, isSample: Bool) -> String? {
        if isSample {
            recordedSamples += 1
        }
        pendingRows.append(row.csvLine)
        guard pendingRows.count >= flushEveryRows else { return nil }
        return flush()
    }

    /// Дописує накопичені рядки у файл. Повертає текст помилки або nil.
    @discardableResult
    func flush() -> String? {
        guard !pendingRows.isEmpty, let handle = fileHandle else { return nil }
        let chunk = pendingRows.joined(separator: "\n") + "\n"
        pendingRows.removeAll(keepingCapacity: true)
        do {
            try handle.write(contentsOf: Data(chunk.utf8))
            return nil
        } catch {
            return "Помилка запису файлу: \(error.localizedDescription)"
        }
    }

    /// Дописує залишок і закриває файл
    func finish() -> TripSaveResult {
        let flushError = flush()
        try? fileHandle?.close()
        fileHandle = nil

        guard let url = fileURL else {
            return .notCreated
        }
        fileURL = nil

        // Жодного виміру (запис зупинено під час калібрування): файл не потрібен
        if recordedSamples == 0 {
            try? FileManager.default.removeItem(at: url)
            return .empty
        }
        return .saved(fileName: fileName, warning: flushError)
    }
}
