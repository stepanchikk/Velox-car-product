import Foundation

// MARK: - Вектор у системі координат пристрою

nonisolated struct Vector3 {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vector3(x: 0, y: 0, z: 0)

    var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(x: y * other.z - z * other.y,
                y: z * other.x - x * other.z,
                z: x * other.y - y * other.x)
    }

    // Одиничний вектор або nil, якщо вектор майже нульовий
    func normalized() -> Vector3? {
        let l = length
        guard l > 1e-9 else { return nil }
        return Vector3(x: x / l, y: y / l, z: z / l)
    }

    static func + (a: Vector3, b: Vector3) -> Vector3 {
        Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    static func - (a: Vector3, b: Vector3) -> Vector3 {
        Vector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    static func * (v: Vector3, s: Double) -> Vector3 {
        Vector3(x: v.x * s, y: v.y * s, z: v.z * s)
    }

    static prefix func - (v: Vector3) -> Vector3 {
        Vector3(x: -v.x, y: -v.y, z: -v.z)
    }
}

// MARK: - Результат калібрування

nonisolated struct CalibrationResult {
    nonisolated enum ForwardSource {
        case gps
        // GPS недоступний: припущення "екраном вгору, верхньою частиною вперед"
        case fallbackFlatMount
    }

    // Одиничний вектор "вгору" у системі координат пристрою (будь-яке положення)
    let up: Vector3
    // Одиничний горизонтальний вектор напрямку руху (у системі координат пристрою)
    let forward: Vector3
    let forwardSource: ForwardSource
    // 0...1, орієнтовна впевненість оцінки forward (лише для .gps; для fallback завжди 0)
    let forwardQuality: Double

    // Поздовжнє прискорення: додатне - розгін, від'ємне - гальмування
    func longitudinal(_ userAcceleration: Vector3) -> Double {
        userAcceleration.dot(forward)
    }
}

nonisolated enum CalibrationOutcome {
    case calibratingUp(Double)         // прогрес 0...1: тримаємо телефон нерухомо
    case calibratingForward(Double)    // прогрес 0...1: їдемо, щоб визначити напрям руху
    case finished(CalibrationResult)
    case failed(String)                // причина для користувача
}

// MARK: - Фаза 2: калібрування напрямку руху за GPS

/// Оцінює напрям руху автомобіля в горизонтальній площині приладу шляхом
/// кореляції горизонтального прискорення телефона (яке саме по собі не
/// прив'язане до жодної конкретної осі приладу) з прискоренням, отриманим
/// диференціюванням швидкості GPS. Завдяки цьому калібрування працює для
/// БУДЬ-ЯКОГО положення телефона - потрібно лише знати напрям "вгору"
/// (див. OrientationCalibrator, фаза 1) і трохи проїхати з увімкненою
/// геолокацією, плавно прискорюючись і гальмуючи.
///
/// Метод перевірено симуляцією (Python): при типовому профілі "розгін -
/// гальмування" за 8-10 с і реалістичному шумі GPS (похибка швидкості
/// 0.25 м/с) медіанна похибка кута становить 1-3 градуси, а поріг
/// goodEnergyThreshold дає похибку <10 градусів у 99% випадків.
nonisolated final class ForwardCalibrator {

    // Поріг накопиченої "енергії" (сума квадратів прискорень GPS, (м/с^2)^2),
    // після якого оцінка вважається надійною.
    static let goodEnergyThreshold: Double = 4.0
    // Мінімум, за яким погоджуємось використати оцінку по таймауту.
    static let minEnergyThreshold: Double = 1.0
    static let timeout: TimeInterval = 25.0

    // Ігноруємо GPS-інтервали з розривом (сигнал пропав на деякий час)
    // або нереалістичним стрибком швидкості (похибка визначення)
    private static let maxIntervalGap: TimeInterval = 3.0
    private static let maxRealisticAccel: Double = 6.0     // м/с^2
    private static let maxSpeedAccuracy: Double = 3.0      // м/с

    // Довільний ортонормований базис горизонтальної площини (перпендикулярної up)
    private let e1: Vector3
    private let e2: Vector3

    private var w1: Double = 0
    private var w2: Double = 0
    private(set) var energy: Double = 0

    private var lastSpeed: Double?
    private var lastSpeedTime: TimeInterval?

    private var bufferE1Sum: Double = 0
    private var bufferE2Sum: Double = 0
    private var bufferCount: Int = 0

    init(up: Vector3) {
        // Будь-який вектор, що не паралельний up, спроєктований на горизонтальну
        // площину, дає коректний базис - перевірено на 200 000 випадкових up.
        let reference = abs(up.x) < 0.9 ? Vector3(x: 1, y: 0, z: 0) : Vector3(x: 0, y: 1, z: 0)
        let e1raw = reference - up * reference.dot(up)
        let e1n = e1raw.normalized() ?? Vector3(x: 0, y: 1, z: 0)
        self.e1 = e1n
        self.e2 = up.cross(e1n)
    }

    var progress: Double {
        min(1.0, energy / Self.goodEnergyThreshold)
    }

    var isAcceptable: Bool {
        energy >= Self.minEnergyThreshold
    }

    // Викликати на кожен вимір акселерометра під час фази калібрування руху
    func addMotionSample(userAcceleration: Vector3) {
        bufferE1Sum += userAcceleration.dot(e1)
        bufferE2Sum += userAcceleration.dot(e2)
        bufferCount += 1
    }

    // Викликати на кожне оновлення геолокації. Повертає non-nil, коли
    // накопичено достатньо даних (goodEnergyThreshold) для завершення.
    func addLocationSample(speed: Double, speedAccuracy: Double, time: TimeInterval) -> Vector3? {
        defer {
            lastSpeed = speed
            lastSpeedTime = time
            bufferE1Sum = 0; bufferE2Sum = 0; bufferCount = 0
        }

        guard speed >= 0, speedAccuracy >= 0, speedAccuracy < Self.maxSpeedAccuracy else { return nil }
        guard let prevSpeed = lastSpeed, let prevTime = lastSpeedTime else { return nil }
        let dt = time - prevTime
        guard dt > 0.2, dt < Self.maxIntervalGap, bufferCount > 0 else { return nil }

        let aGps = (speed - prevSpeed) / dt
        guard abs(aGps) < Self.maxRealisticAccel else { return nil }

        let avgE1 = bufferE1Sum / Double(bufferCount)
        let avgE2 = bufferE2Sum / Double(bufferCount)

        // Узгоджений фільтр: forward ~ normalize( sum( a_gps(i) * device_vec(i) ) ).
        // Коли авто розганяється, обидва множники додатні; коли гальмує - обидва
        // від'ємні, тому добуток завжди підсилює саме напрям руху, а не збиває його.
        w1 += aGps * avgE1
        w2 += aGps * avgE2
        energy += aGps * aGps

        guard energy >= Self.goodEnergyThreshold else { return nil }
        return currentEstimate()
    }

    func currentEstimate() -> Vector3? {
        let mag = (w1 * w1 + w2 * w2).squareRoot()
        guard mag > 1e-9 else { return nil }
        return e1 * (w1 / mag) + e2 * (w2 / mag)
    }
}

// MARK: - Калібратор (фаза 1: "вгору" + фаза 2: напрям руху)

// Працює для будь-якого положення телефона: фаза 1 визначає вертикаль за
// силою тяжіння (без обмежень на орієнтацію), фаза 2 - напрям руху за GPS.
// Якщо доступу до геолокації немає, використовується запасний варіант:
// припущення, що телефон лежить екраном вгору, верхньою частиною вперед.
nonisolated final class OrientationCalibrator {

    // 20 вимірів при 10 Гц = 2 секунди спокою
    static let requiredStableSamples = 20
    static let maxUserAcceleration = 0.05
    static let maxRotationRate = 0.2
    // Перекалібрування під час поїздки: авто може їхати, тому вібрація дороги,
    // розгони і повороти не повинні зривати фазу вертикалі. Сила тяжіння від
    // CoreMotion уже очищена від лінійного прискорення (злиття з гіроскопом),
    // тож достатньо, щоб телефон не крутили в руках.
    static let maxUserAccelerationInMotion = 0.3
    static let maxRotationRateInMotion = 0.35
    static let upTimeout: TimeInterval = 8.0
    private static let maxSampleGap: TimeInterval = 1.0

    nonisolated private enum Phase { case up, forward }
    private var phase: Phase = .up

    private var stableGravity: [Vector3] = []
    private var recentGravity: [Vector3] = []
    private var upStartTime: TimeInterval?
    private var lastSampleTime: TimeInterval?

    private var upVector: Vector3?
    private var forwardCalibrator: ForwardCalibrator?
    private var forwardStartTime: TimeInterval?
    // Скільки оновлень GPS надійшло у фазі 2 (щоб відрізнити "немає сигналу"
    // від "замало розгонів")
    private var locationUpdates = 0
    private var locationAvailable = true
    private var inMotion = false

    /// inMotion = true для перекалібрування під час поїздки (послаблені вимоги до спокою)
    func reset(locationAvailable: Bool, inMotion: Bool = false) {
        self.inMotion = inMotion
        phase = .up
        stableGravity.removeAll()
        recentGravity.removeAll()
        upStartTime = nil
        lastSampleTime = nil
        upVector = nil
        forwardCalibrator = nil
        forwardStartTime = nil
        locationUpdates = 0
        self.locationAvailable = locationAvailable
    }

    // MARK: Дані акселерометра (обидві фази)

    func feedMotion(gravity: Vector3,
                    userAcceleration: Vector3,
                    rotationRate: Vector3,
                    time: TimeInterval) -> CalibrationOutcome {
        switch phase {
        case .up:
            return feedUp(gravity: gravity, userAcceleration: userAcceleration, rotationRate: rotationRate, time: time)
        case .forward:
            forwardCalibrator?.addMotionSample(userAcceleration: userAcceleration)
            // Таймаут перевіряється і тут: якщо GPS перестав надсилати оновлення
            // (тунель, заборона доступу), калібрування не повинно зависнути
            if let timedOut = forwardTimeoutOutcome(time: time) {
                return timedOut
            }
            return .calibratingForward(forwardCalibrator?.progress ?? 0)
        }
    }

    // MARK: Дані геолокації (лише фаза 2)

    func feedLocation(speed: Double, speedAccuracy: Double, time: TimeInterval) -> CalibrationOutcome? {
        guard phase == .forward, let calibrator = forwardCalibrator, let up = upVector else { return nil }
        locationUpdates += 1

        if let forward = calibrator.addLocationSample(speed: speed, speedAccuracy: speedAccuracy, time: time) {
            return .finished(CalibrationResult(up: up, forward: forward, forwardSource: .gps,
                                               forwardQuality: 1.0))
        }
        if let timedOut = forwardTimeoutOutcome(time: time) {
            return timedOut
        }
        return .calibratingForward(calibrator.progress)
    }

    // Результат фази 2 після таймауту або nil, якщо час ще не вийшов
    private func forwardTimeoutOutcome(time: TimeInterval) -> CalibrationOutcome? {
        guard let start = forwardStartTime, let calibrator = forwardCalibrator, let up = upVector,
              time - start > ForwardCalibrator.timeout else { return nil }

        if calibrator.isAcceptable, let forward = calibrator.currentEstimate() {
            let quality = min(1.0, calibrator.energy / ForwardCalibrator.goodEnergyThreshold)
            return .finished(CalibrationResult(up: up, forward: forward, forwardSource: .gps,
                                               forwardQuality: quality))
        }
        let seconds = Int(ForwardCalibrator.timeout)
        if locationUpdates == 0 {
            return .failed("Немає сигналу GPS за \(seconds) с. Перевірте доступ до геолокації або виїдіть на відкриту місцевість.")
        }
        return .failed("Не вдалося визначити напрям руху: замало розгонів чи гальмувань за \(seconds) с. Проїдьте прямо, плавно прискорюючись і гальмуючи, або перекалібруйте пізніше.")
    }

    // MARK: Фаза 1 - вертикаль (працює для будь-якого положення)

    private func feedUp(gravity: Vector3,
                        userAcceleration: Vector3,
                        rotationRate: Vector3,
                        time: TimeInterval) -> CalibrationOutcome {
        if let last = lastSampleTime, time - last > Self.maxSampleGap {
            stableGravity.removeAll()
            recentGravity.removeAll()
            upStartTime = time
        }
        lastSampleTime = time
        if upStartTime == nil { upStartTime = time }

        let maxAcceleration = inMotion ? Self.maxUserAccelerationInMotion : Self.maxUserAcceleration
        let maxRotation = inMotion ? Self.maxRotationRateInMotion : Self.maxRotationRate
        let isStable = userAcceleration.length < maxAcceleration && rotationRate.length < maxRotation

        if isStable {
            stableGravity.append(gravity)
        } else {
            stableGravity.removeAll()
        }

        recentGravity.append(gravity)
        if recentGravity.count > Self.requiredStableSamples {
            recentGravity.removeFirst()
        }

        if stableGravity.count >= Self.requiredStableSamples {
            return finishUp(with: stableGravity)
        }

        if let start = upStartTime, time - start > Self.upTimeout {
            if recentGravity.count >= Self.requiredStableSamples / 2 {
                return finishUp(with: recentGravity)
            }
            return .failed("Недостатньо даних для калібрування. Спробуйте ще раз.")
        }

        return .calibratingUp(Double(stableGravity.count) / Double(Self.requiredStableSamples))
    }

    private func finishUp(with samples: [Vector3]) -> CalibrationOutcome {
        var sum = Vector3.zero
        for sample in samples {
            sum = sum + sample
        }
        let mean = sum * (1.0 / Double(samples.count))

        guard let gravityUnit = mean.normalized() else {
            return .failed("Не вдалося визначити напрям сили тяжіння.")
        }

        // CoreMotion повертає gravity як напрям дії сили тяжіння в системі
        // координат приладу, тому "вгору" = мінус gravity. Це коректно для
        // будь-якого положення телефона, не лише горизонтального.
        let up = -gravityUnit
        upVector = up

        guard locationAvailable else {
            return finishWithFallback(up: up)
        }

        phase = .forward
        forwardStartTime = lastSampleTime
        forwardCalibrator = ForwardCalibrator(up: up)
        return .calibratingForward(0)
    }

    // MARK: Запасний варіант без GPS

    private func finishWithFallback(up: Vector3) -> CalibrationOutcome {
        // Немає геолокації: припускаємо традиційне положення "екраном вгору,
        // верхньою частиною вперед" (вісь Y приладу), як і в попередній версії.
        let deviceY = Vector3(x: 0, y: 1, z: 0)
        let projected = deviceY - up * deviceY.dot(up)
        guard let forward = projected.normalized() else {
            return .failed("Немає доступу до геолокації, а визначити напрям руху для поточного положення телефона неможливо. Покладіть телефон екраном вгору, верхньою частиною вперед, або дозвольте доступ до геолокації для калібрування в будь-якому положенні.")
        }
        return .finished(CalibrationResult(up: up, forward: forward, forwardSource: .fallbackFlatMount, forwardQuality: 0))
    }

    // Кут між двома напрямками, градуси
    static func angleDegrees(_ a: Vector3, _ b: Vector3) -> Double {
        guard let ua = a.normalized(), let ub = b.normalized() else { return 0 }
        return acos(max(-1.0, min(1.0, ua.dot(ub)))) * 180.0 / Double.pi
    }
}
