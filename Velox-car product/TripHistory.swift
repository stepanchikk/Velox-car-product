import Foundation
import Combine

// Історія поїздок: розбір збережених CSV-файлів і список для інтерфейсу.
// TripCSVParser і TripLibrary не залежать від інтерфейсу, тому перевіряються
// юніт-тестами і працюють у фоновому потоці (див. TripStore.reload).

// MARK: - Показники однієї поїздки

nonisolated enum TripCalibrationKind: Hashable, Sendable {
    case unknown    // у файлі немає подій калібрування (старі версії)
    case gps        // CalibrationDone: напрям руху визначено за GPS
    case fallback   // CalibrationDoneFallback: спрощене калібрування без GPS
    case fallbackChecked    // без GPS, напрям перевірено або виправлено за поворотами
}

nonisolated struct TripStats: Hashable, Sendable {
    var duration: TimeInterval = 0
    // Кількість рядків-вимірів (без службових рядків подій)
    var samples = 0
    // nil: старий файл без колонки Event, події невідомі
    var hardBrakings: Int?
    var hardAccelerations: Int?
    var distractions: Int?
    // Сумарний час з телефоном у руках (від Distraction до DistractionEnd);
    // nil для файлів версій, які тривалість не записували
    var distractionSeconds: Double?
    // Останнє значення колонки Score; для файлів без неї - розрахунок за подіями
    var score: Int?
    // Відстань за швидкістю GPS; nil, якщо швидкості в файлі немає
    var distanceMeters: Double?
    var calibration: TripCalibrationKind = .unknown
    // Пропущені неповні рядки (наприклад, обірваний останній рядок після збою)
    var skippedLines = 0
    // Параметри запису з рядків "# ключ=значення"; nil для файлів старих версій
    var metadata: TripMetadata?
    // У файлі є координати (увімкнено «Зберігати маршрут»); сам маршрут
    // читається окремо, лише коли відкривають поїздку (TripRoute)
    var hasRoute = false

    var maneuvers: Int? {
        guard let b = hardBrakings, let a = hardAccelerations else { return nil }
        return b + a
    }
}

// MARK: - Розбір CSV

nonisolated enum TripCSVParser {
    // Інтервали між вимірами довші за цей (розрив GPS, фон) не враховуються у відстані
    private static let maxDistanceGap: TimeInterval = 3.0

    /// Підсумок поїздки за вмістом CSV або nil, якщо це не файл поїздки Velox.
    /// Колонки шукаються за назвою, тому підтримуються всі попередні формати.
    /// Рядки "# ключ=значення" перед заголовком - параметри запису (TripMetadata).
    static func parse(_ text: String) -> TripStats? {
        let lines = text.split(whereSeparator: \.isNewline)
        var metadata = TripMetadata()
        var headerIndex = lines.startIndex
        while headerIndex < lines.endIndex, lines[headerIndex].hasPrefix(TripMetadata.linePrefix) {
            if let entry = TripMetadata.parseLine(lines[headerIndex]) {
                metadata.set(entry.key, entry.value)
            }
            headerIndex += 1
        }
        guard headerIndex < lines.endIndex else { return nil }
        let header = lines[headerIndex].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let iTime = header.firstIndex(of: "Timestamp") else { return nil }
        let iEvent = header.firstIndex(of: "Event")
        let iScore = header.firstIndex(of: "Score")
        let iSpeed = header.firstIndex(of: "Speed_mps")
        let iLat = header.firstIndex(of: "Lat")

        var stats = TripStats()
        stats.metadata = metadata.isEmpty ? nil : metadata
        var brakings = 0, accelerations = 0, distractions = 0
        var distractionSeconds = 0.0
        var distractionOpenedAt: Double?
        var hasDurationEvents = metadata["distractionDurationStep"] != nil
        var lastScore: Int?
        var distance = 0.0
        var hasSpeed = false
        var previous: (time: Double, speed: Double)?

        for line in lines[(headerIndex + 1)...] {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == header.count, let time = Double(fields[iTime]) else {
                stats.skippedLines += 1
                continue
            }
            stats.duration = max(stats.duration, time)
            if !stats.hasRoute, let i = iLat, !fields[i].isEmpty {
                stats.hasRoute = true
            }
            if let i = iScore, let value = Int(fields[i]) {
                lastScore = value
            }

            let event = iEvent.map { String(fields[$0]) } ?? ""
            switch event {
            case "HardBraking": brakings += 1
            case "HardAcceleration": accelerations += 1
            case "Distraction", "DistractionResume":
                if event == "Distraction" { distractions += 1 }
                if distractionOpenedAt == nil { distractionOpenedAt = time }
            case "DistractionEnd":
                hasDurationEvents = true
                if let openedAt = distractionOpenedAt {
                    distractionSeconds += max(0, time - openedAt)
                    distractionOpenedAt = nil
                }
            case "CalibrationDone": stats.calibration = .gps
            case "CalibrationDoneFallback": stats.calibration = .fallback
            case "CalibrationDirectionFix", "CalibrationDirectionConfirmed":
                if stats.calibration == .fallback { stats.calibration = .fallbackChecked }
            default: break
            }

            // Службові рядки (відволікання, калібрування, дзвінки) повторюють
            // останні значення і вимірами не є
            if event.hasPrefix("Distraction") || event.hasPrefix("Calibration") || event.hasPrefix("Call") {
                continue
            }
            stats.samples += 1

            // Відстань: інтеграл швидкості за методом трапецій
            if let i = iSpeed, let speed = Double(fields[i]) {
                hasSpeed = true
                if let prev = previous {
                    let dt = time - prev.time
                    if dt > 0, dt <= maxDistanceGap {
                        distance += (speed + prev.speed) / 2 * dt
                    }
                }
                previous = (time, speed)
            } else {
                previous = nil
            }
        }

        if iEvent != nil {
            stats.hardBrakings = brakings
            stats.hardAccelerations = accelerations
            stats.distractions = distractions
        }
        stats.distractionSeconds = hasDurationEvents ? distractionSeconds : nil
        if let lastScore = lastScore {
            stats.score = lastScore
        } else if iEvent != nil {
            stats.score = SafetyScoreCalculator.score(maneuvers: brakings + accelerations,
                                                      distractions: distractions)
        }
        stats.distanceMeters = hasSpeed ? distance : nil
        return stats
    }
}

// MARK: - Маршрут

/// Маршрут поїздки і місця подій на ньому (колонки Lat, Lon)
nonisolated struct TripRoute: Equatable, Sendable {
    nonisolated enum EventKind: Hashable, Sendable {
        case hardBraking, hardAcceleration, distraction
    }

    nonisolated struct Event: Identifiable, Hashable, Sendable {
        let id: Int
        let kind: EventKind
        let point: RoutePoint
        let time: TimeInterval
    }

    // Більше точок карта малює повільно, а на екрані різниці не видно
    static let maxPoints = 1500

    let points: [RoutePoint]
    let events: [Event]

    /// Маршрут з тексту CSV або nil, якщо координат менше двох
    static func parse(_ text: String) -> TripRoute? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerIndex = lines.firstIndex(where: { !$0.hasPrefix(TripMetadata.linePrefix) }) else { return nil }
        let header = lines[headerIndex].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let iLat = header.firstIndex(of: "Lat"), let iLon = header.firstIndex(of: "Lon"),
              let iTime = header.firstIndex(of: "Timestamp") else { return nil }
        let iEvent = header.firstIndex(of: "Event")

        var points: [RoutePoint] = []
        var events: [Event] = []
        var last: RoutePoint?
        for line in lines[(headerIndex + 1)...] {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == header.count, let time = Double(fields[iTime]) else { continue }
            if let lat = Double(fields[iLat]), let lon = Double(fields[iLon]) {
                let point = RoutePoint(latitude: lat, longitude: lon)
                // Координати оновлюються раз на секунду, а рядки пишуться 10 разів:
                // однакові точки підряд не потрібні
                if point != last {
                    points.append(point)
                    last = point
                }
            }
            let kind: EventKind?
            switch iEvent.map({ String(fields[$0]) }) ?? "" {
            case "HardBraking": kind = .hardBraking
            case "HardAcceleration": kind = .hardAcceleration
            case "Distraction": kind = .distraction
            default: kind = nil
            }
            if let kind = kind, let point = last {
                events.append(Event(id: events.count, kind: kind, point: point, time: time))
            }
        }
        guard points.count >= 2 else { return nil }
        return TripRoute(points: thin(points), events: events)
    }

    static func load(from url: URL) -> TripRoute? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Рівномірне проріджування до maxPoints (перша і остання точки лишаються)
    static func thin(_ points: [RoutePoint]) -> [RoutePoint] {
        guard points.count > maxPoints else { return points }
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { points[Int((Double($0) * step).rounded())] }
    }
}

// MARK: - Поїздка у списку

nonisolated struct TripSummary: Identifiable, Hashable, Sendable {
    let fileName: String
    let url: URL
    let date: Date
    let fileSize: Int64?
    let stats: TripStats

    var id: String { fileName }
}

// MARK: - Файли поїздок

nonisolated enum TripLibrary {
    static let filePrefix = "Velox_Data_"

    nonisolated struct CachedTrip: Sendable {
        let modified: Date
        let summary: TripSummary
    }

    nonisolated struct LoadResult: Sendable {
        let trips: [TripSummary]
        let cache: [String: CachedTrip]
    }

    static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Дата старту з імені файлу Velox_Data_yyyy-MM-dd_HH-mm-ss.csv
    static func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(".csv") else { return nil }
        let stamp = name.dropFirst(filePrefix.count).dropLast(".csv".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: String(stamp))
    }

    /// Підсумки всіх поїздок, від нових до старих. Незмінені файли беруться
    /// з кешу, тому повторне відкриття списку не перечитує всі CSV.
    /// excluding - файл поточного запису (він ще не завершений).
    static func load(cache: [String: CachedTrip], excluding: String?) -> LoadResult {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let directory = directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else {
            return LoadResult(trips: [], cache: [:])
        }

        var trips: [TripSummary] = []
        var newCache: [String: CachedTrip] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(filePrefix), url.pathExtension.lowercased() == "csv", name != excluding else {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast

            if let cached = cache[name], cached.modified == modified {
                trips.append(cached.summary)
                newCache[name] = cached
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let stats = TripCSVParser.parse(text) else { continue }

            let summary = TripSummary(fileName: name,
                                      url: url,
                                      date: date(fromFileName: name) ?? values?.creationDate ?? modified,
                                      fileSize: values?.fileSize.map { Int64($0) },
                                      stats: stats)
            trips.append(summary)
            newCache[name] = CachedTrip(modified: modified, summary: summary)
        }
        trips.sort { $0.date > $1.date }
        return LoadResult(trips: trips, cache: newCache)
    }
}

// MARK: - Сховище для інтерфейсу

@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var trips: [TripSummary] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var cache: [String: TripLibrary.CachedTrip] = [:]

    /// Перечитує каталог у фоновому потоці (розбір довгої поїздки - це тисячі рядків)
    func reload(excluding currentFile: String?) async {
        isLoading = true
        let cached = cache
        let result = await Task.detached(priority: .userInitiated) {
            TripLibrary.load(cache: cached, excluding: currentFile)
        }.value
        cache = result.cache
        trips = result.trips
        isLoading = false
    }

    /// Видаляє всі файли зі списку (поточний запис у список не входить)
    func deleteAll() {
        var failed = 0
        for trip in trips {
            do {
                try FileManager.default.removeItem(at: trip.url)
            } catch {
                failed += 1
            }
        }
        trips.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        cache = cache.filter { name, _ in trips.contains { $0.fileName == name } }
        if failed > 0 {
            errorMessage = "Не вдалося видалити файлів: \(failed)"
        }
    }

    func delete(_ trip: TripSummary) {
        do {
            try FileManager.default.removeItem(at: trip.url)
            trips.removeAll { $0.id == trip.id }
            cache[trip.fileName] = nil
        } catch {
            errorMessage = "Не вдалося видалити файл: \(error.localizedDescription)"
        }
    }
}

// MARK: - Форматування

nonisolated enum TripFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours) год \(minutes) хв" }
        if minutes > 0 { return "\(minutes) хв \(secs) с" }
        return "\(secs) с"
    }

    static func distance(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) м" : String(format: "%.1f км", meters / 1000)
    }
}
