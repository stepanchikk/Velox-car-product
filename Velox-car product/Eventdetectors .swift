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

    init(threshold: Double, cooldown: TimeInterval = 3.0) {
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

    init(gracePeriod: TimeInterval = 3.0, cooldown: TimeInterval = 1.5) {
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

// MARK: - Зміна положення телефона

/// Виявляє кардинальну зміну нахилу телефона відносно калібрування
nonisolated struct OrientationChangeDetector {
    let angleThreshold: Double      // градуси
    let holdTime: TimeInterval      // скільки секунд зміна має тривати
    private var exceededSince: TimeInterval?
    // Останній виміряний кут (пишеться в колонку Tilt_deg)
    private(set) var lastAngle: Double = 0.0

    init(angleThreshold: Double = 30.0, holdTime: TimeInterval = 2.0) {
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
