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

    /// Чи йшла розмова ще до втрати активності (аргумент callWasActive для cause).
    /// Розмова, що почалась менше ніж за grace секунд до цього, не рахується:
    /// її екран відкрила система. Так у польовій поїздці дзвінок через CarPlay
    /// почався за 0.2 с до втрати активності і помилково отримав штраф.
    static func callWasActive(callStartedAt: TimeInterval?, focusLostAt: TimeInterval,
                              grace: TimeInterval = VeloxConfig.callFocusLossGrace) -> Bool {
        guard let start = callStartedAt else { return false }
        return focusLostAt - start >= grace
    }
}

// MARK: - Запис із вимкненим екраном

/// Що зробити SensorManager за рішенням ScreenLockTracker
nonisolated enum ScreenAction: Equatable {
    case screenLocked(at: TimeInterval)       // записати ScreenLocked, стан «Екран вимкнено»
    case screenUnlocked(at: TimeInterval)     // записати ScreenUnlocked
    case beginDistraction(at: TimeInterval)   // відволікання з цього моменту
    case endDistraction(at: TimeInterval)     // закрити відволікання, якщо воно триває
}

/// Розрізняє блокування екрана і користування телефоном, коли запис іде у фоні.
///
/// Застосунок втрачає активність і тоді, коли водій блокує екран, і тоді, коли
/// відкриває інший застосунок. Відрізнити їх можна лише за сповіщенням iOS про
/// блокування (protectedDataWillBecomeUnavailable), яке приходить із затримкою
/// до ~10 с. Тому рішення відкладається на lockWaitTime:
/// - прийшло блокування - це не відволікання, запис триває у фоні;
/// - водій повернувся або час минув - відволікання з моменту втрати активності.
/// Розблокування, після якого Velox не повернувся на екран за unlockGrace, -
/// відволікання: телефон розблокували заради іншого застосунку.
///
/// Тип не залежить від UIKit: події передає SensorManager, тому всі сценарії
/// перевіряються юніт-тестами.
nonisolated struct ScreenLockTracker {
    let lockWaitTime: TimeInterval
    let unlockGrace: TimeInterval

    private(set) var isLocked = false
    private var appActive = true
    // Втрата активності, для якої ще чекаємо сповіщення про блокування
    private var pendingFocusLoss: TimeInterval?
    // Розблокування, після якого чекаємо повернення у Velox
    private var pendingUnlock: TimeInterval?

    init(lockWaitTime: TimeInterval = VeloxConfig.screenLockWaitTime,
         unlockGrace: TimeInterval = VeloxConfig.unlockReturnGrace) {
        self.lockWaitTime = lockWaitTime
        self.unlockGrace = unlockGrace
    }

    mutating func reset() {
        isLocked = false
        appActive = true
        pendingFocusLoss = nil
        pendingUnlock = nil
    }

    /// Застосунок втратив активність не через дзвінок
    mutating func focusLost(at time: TimeInterval) -> [ScreenAction] {
        appActive = false
        // Сповіщення про блокування вже прийшло: причина відома
        guard !isLocked, pendingFocusLoss == nil else { return [] }
        pendingFocusLoss = time
        return []
    }

    /// Velox знову на екрані
    mutating func focusGained(at time: TimeInterval) -> [ScreenAction] {
        appActive = true
        pendingUnlock = nil
        guard let lostAt = pendingFocusLoss else { return [] }
        // Повернувся раніше, ніж прийшло блокування: виходив в інший застосунок
        pendingFocusLoss = nil
        return [.beginDistraction(at: lostAt), .endDistraction(at: time)]
    }

    /// iOS повідомила, що телефон заблоковано
    mutating func deviceLocked(at time: TimeInterval) -> [ScreenAction] {
        isLocked = true
        pendingUnlock = nil
        if let lostAt = pendingFocusLoss {
            // Блокування пояснює втрату активності
            pendingFocusLoss = nil
            return [.screenLocked(at: lostAt)]
        }
        // Телефон відклали після користування іншим застосунком
        return [.screenLocked(at: time), .endDistraction(at: time)]
    }

    /// iOS повідомила, що телефон розблоковано
    mutating func deviceUnlocked(at time: TimeInterval) -> [ScreenAction] {
        isLocked = false
        if !appActive {
            pendingUnlock = time
        }
        return [.screenUnlocked(at: time)]
    }

    /// Викликається з кожним виміром: приймає відкладені рішення
    mutating func tick(at time: TimeInterval) -> [ScreenAction] {
        if let lostAt = pendingFocusLoss, time - lostAt >= lockWaitTime {
            pendingFocusLoss = nil
            return [.beginDistraction(at: lostAt)]
        }
        if let unlockedAt = pendingUnlock, time - unlockedAt >= unlockGrace {
            pendingUnlock = nil
            return [.beginDistraction(at: unlockedAt)]
        }
        return []
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
