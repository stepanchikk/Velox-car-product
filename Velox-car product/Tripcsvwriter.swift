import Foundation

/// Один рядок CSV поїздки (порядок колонок відповідає TripCSVWriter.header)
nonisolated struct TelemetryRow {
    let time: TimeInterval          // секунди від «Старт»
    let filtered: Double            // Filtered_Y, G
    let state: String               // State
    let event: String               // Event (може бути порожнім)
    let raw: Double                 // Raw_Y, G
    let userAcceleration: Vector3   // Ax, Ay, Az, G
    let tiltDegrees: Double         // Tilt_deg
    let score: Int                  // Score
    let speed: Double?              // Speed_mps (nil: GPS немає або дані застарілі)

    var csvLine: String {
        let safeState = state.replacingOccurrences(of: ",", with: "")
        let a = userAcceleration
        let speedText = speed.map { "\($0)" } ?? ""
        return "\(time),\(filtered),\(safeState),\(event),\(raw),\(a.x),\(a.y),\(a.z),\(tiltDegrees),\(score),\(speedText)"
    }
}

/// Запис поїздки у CSV. Файл із заголовком створюється на старті, рядки
/// накопичуються в буфері й дописуються частинами, тому при аварійному
/// завершенні застосунку втрачається не більше flushEveryRows останніх рядків.
nonisolated final class TripCSVWriter {
    static let header = "Timestamp,Filtered_Y,State,Event,Raw_Y,Ax,Ay,Az,Tilt_deg,Score,Speed_mps"

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
    /// Повертає текст помилки або nil.
    func open(fileName: String) -> String? {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Не вдалося знайти папку для збереження файлу."
        }
        let url = documentDirectory.appendingPathComponent(fileName)
        do {
            try (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
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

    /// Дописує залишок, закриває файл і повертає текст результату для користувача
    func finish() -> String {
        let flushError = flush()
        try? fileHandle?.close()
        fileHandle = nil

        guard let url = fileURL else {
            return "Файл поїздки не було створено."
        }
        fileURL = nil

        // Жодного виміру (запис зупинено під час калібрування): файл не потрібен
        if recordedSamples == 0 {
            try? FileManager.default.removeItem(at: url)
            return "Даних для збереження немає, файл не створено."
        }
        if let flushError = flushError {
            return flushError
        }
        return "Дані поїздки збережено: \(fileName)"
    }
}
