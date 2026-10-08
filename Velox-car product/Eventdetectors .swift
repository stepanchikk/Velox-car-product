import Foundation

// Чиста логіка обробки сигналу і виявлення подій, винесена з SensorManager.
// Жодних залежностей від CoreMotion, UIKit чи часу пристрою: усе отримується
// через параметри, тому ці типи можна перевіряти юніт-тестами на синтетичних даних.
// Позначка nonisolated: проєкт за замовчуванням прив'язує всі типи до головного
// потоку (Default Actor Isolation = MainActor), а чистій логіці це не потрібно.
// Без неї тести отримують попередження про ізольовану відповідність Equatable.

// MARK: - Low-Pass фільтр

/// Експоненційний фільтр низьких частот: y[n] = alpha * x[n] + (1 - alpha) * y[n-1]
nonisolated struct LowPassFilter {
    let alpha: Double
    private(set) var value: Double = 0.0

    init(alpha: Double) {
        self.alpha = alpha
    }

    mutating func process(_ x: Double) -> Double {
        value = alpha * x + (1.0 - alpha) * value
        return value
    }

    // Після зміни осей (калібрування) або скидання фільтр починає з нуля
    mutating func reset() {
        value = 0.0
    }
}

// MARK: - Небезпечні маневри

nonisolated enum Maneuver {
    case hardBraking
    case hardAcceleration

    // Код події в колонці Event у CSV
    var eventCode: String {
        switch self {
        case .hardBraking: return "HardBraking"
        case .hardAcceleration: return "HardAcceleration"
        }
    }
}

/// Поріг перевантаження + окрема пауза для кожного типу маневру, щоб
/// гальмування одразу після розгону (чи навпаки) не губилось
nonisolated struct ManeuverDetector {
    let threshold: Double
    let cooldown: TimeInterval
    private var lastBrakingTime: TimeInterval = -.infinity
    private var lastAccelerationTime: TimeInterval = -.infinity

    init(threshold: Double = VeloxConfig.maneuverThreshold,
         cooldown: TimeInterval = VeloxConfig.maneuverCooldown) {
        self.threshold = threshold
        self.cooldown = cooldown
    }

    /// filtered - відфільтроване поздовжнє прискорення (G), time - секунди сесії
    mutating func detect(filtered: Double, at time: TimeInterval) -> Maneuver? {
        if filtered < -threshold, time - lastBrakingTime >= cooldown {
            lastBrakingTime = time
            return .hardBraking
        }
        if filtered > threshold, time - lastAccelerationTime >= cooldown {
            lastAccelerationTime = time
            return .hardAcceleration
        }
        return nil
    }

    mutating func reset() {
        lastBrakingTime = -.infinity
        lastAccelerationTime = -.infinity
    }
}

// MARK: - Anti-Fraud

/// Правила, коли втрату активності застосунку зараховувати як відволікання
nonisolated struct DistractionPolicy {
    // Скільки секунд після старту ігноруємо (системні вікна, натискання «Старт»)
    let gracePeriod: TimeInterval
    // Мінімальний інтервал між двома штрафами (шторка, Центр керування)
    let cooldown: TimeInterval
    private var lastDistractionTime: TimeInterval = -.infinity

    init(gracePeriod: TimeInterval = VeloxConfig.distractionGracePeriod,
         cooldown: TimeInterval = VeloxConfig.distractionCooldown) {
        self.gracePeriod = gracePeriod
        self.cooldown = cooldown
    }

    /// true, якщо подію в момент time (секунди сесії) треба зарахувати
    mutating func register(at time: TimeInterval) -> Bool {
        guard time > gracePeriod, time - lastDistractionTime > cooldown else { return false }
        lastDistractionTime = time
        return true
    }

    mutating func reset() {
        lastDistractionTime = -.infinity
    }
}

/// Відволікання з тривалістю. begin - водій почав користуватися телефоном
/// (застосунок втратив активність або телефон біля вуха під час дзвінка),
/// end - повернувся. Кожне відволікання штрафується одразу (DistractionPolicy),
/// а після завершення додається штраф за тривалість. Повторна втрата активності
/// одразу після попередньої (у межах паузи DistractionPolicy) вважається
/// продовженням того самого відволікання, тому штраф за тривалість рахується
/// за сумарний час, а не окремо за кожен шматок.
nonisolated struct DistractionTracker {
    nonisolated enum Start: Equatable {
        case counted        // нове відволікання, штраф
        case resumed        // продовження попереднього, без нового штрафу
        case ignored        // перші секунди після старту
        case alreadyActive  // уже триває
    }

    nonisolated struct End: Equatable {
        let duration: TimeInterval   // тривалість цього шматка
        let addedPenalty: Int        // доданий штраф за тривалість
    }

    private var policy: DistractionPolicy
    private(set) var activeSince: TimeInterval?
    private var hasEpisode = false
    private var episodeDuration: TimeInterval = 0
    private var episodePenalty = 0
    // Сумарний час з телефоном у руках і сумарний штраф за тривалість
    private(set) var totalDuration: TimeInterval = 0
    private(set) var durationPenalty = 0

    init(policy: DistractionPolicy = DistractionPolicy()) {
        self.policy = policy
    }

    var isActive: Bool { activeSince != nil }

    mutating func begin(at time: TimeInterval) -> Start {
        guard activeSince == nil else { return .alreadyActive }
        if policy.register(at: time) {
            activeSince = time
            hasEpisode = true
            episodeDuration = 0
            episodePenalty = 0
            return .counted
        }
        // Не зараховано лише через паузу після попереднього: це те саме відволікання
        if hasEpisode, time > policy.gracePeriod {
            activeSince = time
            return .resumed
        }
        return .ignored
    }

    mutating func end(at time: TimeInterval) -> End? {
        guard let since = activeSince else { return nil }
        activeSince = nil
        let duration = max(0, time - since)
        episodeDuration += duration
        totalDuration += duration
        let target = SafetyScoreCalculator.durationPenalty(for: episodeDuration)
        let added = max(0, target - episodePenalty)
        episodePenalty = target
        durationPenalty += added
        return End(duration: duration, addedPenalty: added)
    }

    mutating func reset() {
        policy.reset()
        activeSince = nil
        hasEpisode = false
        episodeDuration = 0
        episodePenalty = 0
        totalDuration = 0
        durationPenalty = 0
    }
}

// MARK: - Дзвінки

/// Стан телефонного дзвінка з погляду Anti-Fraud (джерело - CXCallObserver)
nonisolated enum CallState: Equatable {
    case none
    // Вхідний дзвінок ще не прийнято: екран дзвінка відкрила система, а не водій
    case incomingRinging
    // Розмова (або вихідний набір); handheld - звук іде в динамік біля вуха
    case active(handheld: Bool)
}

nonisolated enum FocusLossCause: Equatable {
    case distraction     // водій сам відкрив інший застосунок
    case incomingCall    // систему перекрив екран вхідного дзвінка
    case handsFreeCall   // розмова через гучний звʼязок, гарнітуру чи CarPlay
}

/// Чи вважати втрату активності застосунку відволіканням з огляду на дзвінок.
/// callWasActive - розмова вже йшла, коли застосунок був активним: тоді вихід
/// з Velox - це дія водія (наприклад, відкрив повідомлення під час розмови
/// через гучний звʼязок), і дзвінок його не виправдовує.
nonisolated enum CallPolicy {
    static func cause(for call: CallState, callWasActive: Bool) -> FocusLossCause {
        switch call {
        case .none:
            return .distraction
        case .incomingRinging:
            return .incomingCall
        case .active(let handheld):
            return handheld || callWasActive ? .distraction : .handsFreeCall
        }
    }
}

// MARK: - Зміна положення телефона

/// Виявляє кардинальну зміну нахилу телефона відносно калібрування
nonisolated struct OrientationChangeDetector {
    let angleThreshold: Double      // градуси
    let holdTime: TimeInterval      // скільки секунд зміна має тривати
    private var exceededSince: TimeInterval?
    // Останній виміряний кут (пишеться в колонку Tilt_deg)
    private(set) var lastAngle: Double = 0.0

    init(angleThreshold: Double = VeloxConfig.recalibrationAngle,
         holdTime: TimeInterval = VeloxConfig.recalibrationHold) {
        self.angleThreshold = angleThreshold
        self.holdTime = holdTime
    }

    /// true, якщо кут між поточною і каліброваною вертикаллю більший за поріг
    /// і тримається щонайменше holdTime
    mutating func update(gravity: Vector3, calibratedUp: Vector3, time: TimeInterval) -> Bool {
        let angle = OrientationCalibrator.angleDegrees(-gravity, calibratedUp)
        lastAngle = angle

        guard angle > angleThreshold else {
            exceededSince = nil
            return false
        }
        if let since = exceededSince {
            return time - since >= holdTime
        }
        exceededSince = time
        return false
    }

    // Скидає лише таймер (кут лишається, щоб у рядку калібрування було видно, чому воно почалось)
    mutating func resetTimer() {
        exceededSince = nil
    }

    mutating func reset() {
        exceededSince = nil
        lastAngle = 0.0
    }
}
