import Foundation

// Гейміфікація: загальна статистика водія і досягнення.
// Усе обчислюється з історії поїздок (TripSummary), окремо нічого не зберігається,
// тому видалення поїздки чесно прибирає і пов'язані з нею досягнення.

// MARK: - Статистика

nonisolated struct DrivingStats: Equatable, Sendable {
    // Скільки останніх поїздок враховує середня оцінка
    static let recentWindow = 10

    let tripCount: Int
    let totalDistanceMeters: Double
    let totalDuration: TimeInterval
    // Середній Safety Score останніх recentWindow поїздок з оцінкою
    let averageRecentScore: Int?
    let recentScoreCount: Int
    // Оцінки останніх поїздок від старої до нової (для графіка)
    let recentScores: [Int]
    // Оцінка водія: штрафи тих самих поїздок, перераховані на
    // VeloxConfig.ratingDistanceKm кілометрів (див. rating)
    let driverRating: Int?

    init(trips: [TripSummary]) {
        let newestFirst = trips.sorted { $0.date > $1.date }
        tripCount = trips.count
        totalDistanceMeters = trips.compactMap { $0.stats.distanceMeters }.reduce(0, +)
        totalDuration = trips.map { $0.stats.duration }.reduce(0, +)
        let recent = Array(newestFirst.filter { $0.stats.score != nil }.prefix(Self.recentWindow))
        let scores = recent.compactMap { $0.stats.score }
        recentScoreCount = scores.count
        averageRecentScore = scores.isEmpty ? nil
            : Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
        recentScores = Array(scores.reversed())
        driverRating = Self.rating(recent)
    }

    /// Пробіг поїздки для нормування, км: за GPS, а без нього - за тривалістю
    static func exposureKm(_ trip: TripSummary) -> Double {
        if let meters = trip.stats.distanceMeters, meters > 0 {
            return meters / 1000
        }
        return trip.stats.duration / 3600 * VeloxConfig.ratingFallbackSpeedKmh
    }

    /// Оцінка водія = 100 - (сума штрафів / пробіг) * 10 км.
    /// Штраф поїздки - це 100 мінус її Safety Score. Пробіг береться не менше
    /// 10 км, тож поодинокий короткий заїзд оцінюється як звичайна поїздка
    /// і одна помилка на 2 км не обвалює оцінку до нуля.
    static func rating(_ trips: [TripSummary]) -> Int? {
        let scored = trips.filter { $0.stats.score != nil }
        guard !scored.isEmpty else { return nil }
        let penalties = scored.map { Double(100 - ($0.stats.score ?? 100)) }.reduce(0, +)
        let exposure = max(scored.map(exposureKm).reduce(0, +), VeloxConfig.ratingDistanceKm)
        let value = 100 - penalties / exposure * VeloxConfig.ratingDistanceKm
        return Int(max(0, value).rounded())
    }
}

// MARK: - Досягнення

nonisolated struct Achievement: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    // 0...1; 1 - отримано
    let progress: Double
    let progressText: String

    var isUnlocked: Bool { progress >= 1 }
}

nonisolated enum AchievementCatalog {
    // Короткі заїзди (перевірка в дворі) не повинні давати "ідеальних" досягнень
    static let minPerfectTripDuration: TimeInterval = 5 * 60
    static let minFocusedTripDuration: TimeInterval = 10 * 60

    static func evaluate(_ trips: [TripSummary]) -> [Achievement] {
        let count = trips.count
        let distanceKm = trips.compactMap { $0.stats.distanceMeters }.reduce(0, +) / 1000
        let smoothTrips = trips.filter { ($0.stats.score ?? 0) >= VeloxConfig.safeScoreMin }.count
        let perfect = trips.contains {
            $0.stats.score == 100 && $0.stats.duration >= minPerfectTripDuration
        }
        let focused = trips.contains {
            $0.stats.distractions == 0 && $0.stats.duration >= minFocusedTripDuration
        }

        return [
            counter(id: "first", title: "Перша поїздка", detail: "Запишіть свою першу поїздку",
                    image: "flag.checkered", value: count, goal: 1),
            flag(id: "perfect", title: "Ідеальна поїздка",
                 detail: "Safety Score 100 у поїздці від 5 хвилин",
                 image: "star.fill", done: perfect),
            flag(id: "focused", title: "Телефон відкладено",
                 detail: "Поїздка від 10 хвилин без жодного відволікання",
                 image: "iphone.slash", done: focused),
            counter(id: "smooth", title: "Плавний хід",
                    detail: "5 поїздок з оцінкою від \(VeloxConfig.safeScoreMin)",
                    image: "road.lanes", value: smoothTrips, goal: 5),
            counter(id: "ten", title: "Десять поїздок", detail: "Запишіть 10 поїздок",
                    image: "car.2.fill", value: count, goal: 10),
            distance(id: "hundred", title: "Перша сотня", detail: "Проїдьте 100 км із Velox",
                     image: "speedometer", km: distanceKm, goal: 100),
        ]
    }

    private static func counter(id: String, title: String, detail: String, image: String,
                                value: Int, goal: Int) -> Achievement {
        Achievement(id: id, title: title, detail: detail, systemImage: image,
                    progress: min(1, Double(value) / Double(goal)),
                    progressText: "\(min(value, goal)) з \(goal)")
    }

    private static func flag(id: String, title: String, detail: String, image: String,
                             done: Bool) -> Achievement {
        Achievement(id: id, title: title, detail: detail, systemImage: image,
                    progress: done ? 1 : 0, progressText: done ? "Отримано" : "Ще ні")
    }

    private static func distance(id: String, title: String, detail: String, image: String,
                                 km: Double, goal: Double) -> Achievement {
        Achievement(id: id, title: title, detail: detail, systemImage: image,
                    progress: min(1, km / goal),
                    progressText: "\(Int(min(km, goal).rounded(.down))) з \(Int(goal)) км")
    }
}

// MARK: - Порада дня

nonisolated enum DrivingTips {
    static let all = [
        "Тримайте дистанцію щонайменше 2 секунди до авто попереду, у дощ - 3-4 секунди.",
        "Плавно відпускайте педаль гальма перед зупинкою: авто зупиниться м'якше, а пасажирів не хитне.",
        "Дивіться далеко вперед: що раніше помічаєте ситуацію, то рідше доводиться різко гальмувати.",
        "Налаштуйте маршрут і музику до того, як рушите. Під час руху телефон має лежати.",
        "Розганяйтеся рівно: різкий старт майже не скорочує час у місті, але збільшує витрату пального.",
        "На мокрій дорозі гальмівний шлях зростає, тож починайте гальмувати раніше.",
        "Якщо треба відповісти на повідомлення, зупиніться в безпечному місці.",
    ]

    /// Одна порада на день: та сама протягом доби
    static func tip(for date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return all[day % all.count]
    }
}
