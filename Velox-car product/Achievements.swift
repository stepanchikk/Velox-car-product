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
        let penalties = scored.map { Double($0.stats.totalPenalty ?? (100 - ($0.stats.score ?? 100))) }.reduce(0, +)
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
        let eligible = trips.filter { Gamification.isEligible($0) }
        let smoothTrips = eligible.filter { ($0.stats.score ?? 0) >= VeloxConfig.safeScoreMin }.count
        let perfect = eligible.contains {
            $0.stats.score == 100 && $0.stats.hasCompleteScoring && $0.stats.duration >= minPerfectTripDuration
        }
        let focused = eligible.contains {
            $0.stats.distractions == 0 && $0.stats.unknownMovementSamples == 0 && $0.stats.duration >= minFocusedTripDuration
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


// MARK: - Досвід і тижневі завдання

nonisolated struct WeeklyChallenge: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let value: Int
    let goal: Int
    var isComplete: Bool { value >= goal }
    var progress: Double { min(1, Double(value) / Double(goal)) }
    static let bonus = 40
}

nonisolated struct DriverJourney: Equatable, Sendable {
    let xp: Int
    let weekly: [WeeklyChallenge]
    let weekEnd: Date
    var level: Int {
        var result = 1
        while xp >= Self.threshold(result + 1) { result += 1 }
        return result
    }
    static func threshold(_ level: Int) -> Int { 50 * (level - 1) * level }
    var levelStart: Int { Self.threshold(level) }
    var nextLevelXP: Int { Self.threshold(level + 1) }
    var progress: Double { Double(xp - levelStart) / Double(nextLevelXP - levelStart) }
    var rank: String {
        switch level {
        case 1...2: "Початок шляху"
        case 3...4: "Уважний водій"
        case 5...7: "Плавний стиль"
        default: "Досвід Velox"
        }
    }
}

nonisolated enum Gamification {
    /// Один календар для всіх екранів: локальний тиждень із понеділка.
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        result.firstWeekday = 2
        result.minimumDaysInFirstWeek = 4
        return result
    }

    /// Не винагороджуємо стоянку, короткі, обірвані та старі неперевірні записи.
    /// 95% покриття допускає короткі паузи GPS/калібрування.
    static func isEligible(_ trip: TripSummary) -> Bool {
        let s = trip.stats
        guard s.duration.isFinite, s.duration >= 300, s.endedNormally, s.hasScoringCoverage,
              s.metadata?["format"] == "4", Double(s.samples) >= s.duration * 2,
              s.skippedLines == 0, let score = s.score, (0...100).contains(score),
              let distance = s.distanceMeters, distance.isFinite, distance >= 500,
              s.distractions != nil, s.maneuvers != nil else { return false }
        return Double(max(s.unscoredManeuverSamples, s.unknownMovementSamples)) / Double(s.samples) <= 0.05
    }

    static func baseXP(_ trip: TripSummary) -> Int {
        guard isEligible(trip) else { return 0 }
        return 20 + ((trip.stats.score ?? 0) >= 90 ? 20 : 0)
            + (trip.stats.distractions == 0 && trip.stats.unknownMovementSamples == 0 ? 20 : 0)
    }

    static func challenges(_ trips: [TripSummary], calendar: Calendar) -> [WeeklyChallenge] {
        let safe = trips.filter { ($0.stats.score ?? 0) >= 90 }
        let focused = trips.filter { $0.stats.distractions == 0 && $0.stats.unknownMovementSamples == 0 }
        let days = Set(safe.map { calendar.startOfDay(for: $0.date) }).count
        return [
            WeeklyChallenge(id: "smooth", title: "Плавність", detail: "3 поїздки з оцінкою від 90", value: safe.count, goal: 3),
            WeeklyChallenge(id: "focus", title: "Увага на дорозі", detail: "2 поїздки без відволікань і невідомого руху", value: focused.count, goal: 2),
            WeeklyChallenge(id: "habit", title: "Корисна звичка", detail: "Оцінка від 90 у 3 різні дні", value: days, goal: 3)
        ]
    }

    static func evaluate(_ trips: [TripSummary], now: Date = Date(), calendar: Calendar = Gamification.calendar) -> DriverJourney {
        // Ідентичний файл не приносить досвід двічі; сортування визначає денну межу.
        var seen = Set<String>()
        let valid = trips.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            .filter { $0.date <= now && seen.insert($0.id).inserted && isEligible($0) }
        var daily = [Date: Int]()
        var weeks = [Date: [TripSummary]]()
        var xp = 0
        for trip in valid {
            let day = calendar.startOfDay(for: trip.date)
            let earned = min(baseXP(trip), max(0, 120 - daily[day, default: 0]))
            daily[day, default: 0] += earned
            xp += earned
            if let week = calendar.dateInterval(of: .weekOfYear, for: trip.date)?.start {
                weeks[week, default: []].append(trip)
            }
        }
        for trips in weeks.values {
            xp += challenges(trips, calendar: calendar).filter(\.isComplete).count * WeeklyChallenge.bonus
        }
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        return DriverJourney(xp: xp, weekly: challenges(weeks[interval.start] ?? [], calendar: calendar), weekEnd: interval.end)
    }
}
