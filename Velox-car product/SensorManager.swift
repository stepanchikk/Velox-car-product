import Foundation
import CoreMotion
import CoreLocation
import Combine
import UIKit

// Стан сесії, який бачить користувач і який записується в колонку State.
// Тексти збігаються з попередніми версіями, щоб старі CSV аналізувались так само.
enum SessionState: Equatable {
    case idle
    case calibrating
    case recording
    case distracted

    var title: String {
        switch self {
        case .idle: return "Очікування"
        case .calibrating: return "Калібрування..."
        case .recording: return "Запис іде"
        case .distracted: return "Відволікання!"
        }
    }
}

/// Керуючий клас сесії запису. Отримує дані від сенсорів і системи, передає їх
/// спеціалізованим компонентам і публікує стан для інтерфейсу:
/// - OrientationCalibrator - калібрування орієнтації (OrientationCalibrator.swift);
/// - LowPassFilter, ManeuverDetector, DistractionPolicy, OrientationChangeDetector
///   - обробка сигналу і виявлення подій (EventDetectors.swift);
/// - SafetyScoreCalculator - модель штрафів (SafetyScore.swift);
/// - TripCSVWriter - запис поїздки у файл (TripCSVWriter.swift).
class SensorManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()

    // Поріг перевантаження (також використовується в TrackerView для підсвічування)
    static let maneuverThreshold: Double = 0.4
    // Коефіцієнт Low-Pass фільтра
    static let filterAlpha: Double = 0.2
    // Ручне перекалібрування дозволене лише "майже на стоянці" (безпека:
    // не заохочуємо водія натискати кнопки під час руху)
    private static let manualRecalibrationMaxSpeed: Double = 2.0  // м/с (~7 км/год)

    // isRecording = сесія активна (калібрування або запис)
    @Published var isRecording = false
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0.0
    @Published var calibrationInfo: String = ""
    @Published var lastKnownSpeed: Double = 0.0

    // Поздовжнє прискорення після калібрування (відфільтроване)
    @Published var currentGForceY: Double = 0.0

    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionCount: Int = 0
    @Published var phoneState: SessionState = .idle

    // Обчислюється з лічильників, тому завжди узгоджений з ними
    var safetyScore: Int {
        SafetyScoreCalculator.score(maneuvers: hardBrakingCount + hardAccelerationCount,
                                    distractions: distractionCount)
    }

    // Повідомлення для користувача (помилки та підтвердження)
    @Published var showAlert = false
    @Published var alertMessage = ""

    // Компоненти
    private let calibrator = OrientationCalibrator()
    private var calibration: CalibrationResult?
    private var filter = LowPassFilter(alpha: SensorManager.filterAlpha)
    private var maneuverDetector = ManeuverDetector(threshold: SensorManager.maneuverThreshold)
    private var distractionPolicy = DistractionPolicy()
    private var orientationDetector = OrientationChangeDetector()
    private let csvWriter = TripCSVWriter()

    private var forwardPhaseLogged = false
    private var locationAuthorized = false

    // Останні значення, які потрапляють у рядки CSV
    private var lastRawLongitudinal: Double = 0.0
    private var lastUserAcceleration: Vector3 = Vector3.zero

    // Єдиний годинник сесії: секунди від натискання «Старт».
    // CoreMotion рахує час від увімкнення пристрою (як systemUptime), а GPS дає
    // настінний час (Date), тому фіксуємо обидва моменти старту одночасно.
    private var startTime: Date = Date()
    private var startUptime: TimeInterval = 0

    override init() {
        super.init()

        // ЗАХИСТ: згортання додатка АБО відкриття шторки сповіщень
        NotificationCenter.default.addObserver(self, selector: #selector(appLostFocus), name: UIApplication.willResignActiveNotification, object: nil)

        // Повернення в додаток
        NotificationCenter.default.addObserver(self, selector: #selector(appGainedFocus), name: UIApplication.didBecomeActiveNotification, object: nil)

        // Застосунок пішов у фон: iOS може його вивантажити, тому скидаємо буфер у файл
        NotificationCenter.default.addObserver(self, selector: #selector(appEnteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationAuthorized = isLocationAuthorized(locationManager.authorizationStatus)
        // Запитуємо дозвіл заздалегідь, щоб на момент старту запису статус
        // уже був відомий і калібрування не чекало на системний діалог
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // Прибираємо спостерігачів і зупиняємо сенсори, коли об'єкт звільняється з пам'яті
    deinit {
        NotificationCenter.default.removeObserver(self)
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        // Якщо об'єкт знищується посеред запису, зберігаємо вже записане
        if isRecording {
            _ = csvWriter.finish()
        }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - CLLocationManagerDelegate

    private func isLocationAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorized = isLocationAuthorized(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, isRecording else { return }

        // Перше оновлення може бути старою закешованою позицією: пропускаємо її
        let time = sessionTime(of: location)
        guard time > -1.0 else { return }

        let speed = location.speed
        lastKnownSpeed = max(speed, 0)

        guard isCalibrating else { return }
        if let outcome = calibrator.feedLocation(speed: speed, speedAccuracy: location.speedAccuracy, time: time) {
            apply(outcome)
        }
    }

    // MARK: - Час сесії

    // Поточний момент (для подій без власної мітки часу: сповіщення, кнопки)
    private func sessionTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - startUptime
    }

    // Момент, коли сенсор фактично зробив вимір (а не коли ми його обробили)
    private func sessionTime(of motion: CMDeviceMotion) -> TimeInterval {
        motion.timestamp - startUptime
    }

    // Момент визначення координат GPS
    private func sessionTime(of location: CLLocation) -> TimeInterval {
        location.timestamp.timeIntervalSince(startTime)
    }

    // MARK: - Життєвий цикл додатка (Anti-Fraud)

    @objc private func appLostFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusLost()
        }
    }

    private func handleFocusLost() {
        // Під час калібрування штрафів немає
        guard isRecording, !isCalibrating else { return }
        let now = sessionTime()
        guard distractionPolicy.register(at: now) else { return }

        distractionCount += 1
        phoneState = .distracted

        // Пишемо подію в CSV одразу, а не чекаємо наступного виміру
        appendEventRow(event: "Distraction", time: now)
        triggerHapticFeedback(style: .error)
    }

    @objc private func appEnteredBackground() {
        guard isRecording else { return }
        if let error = csvWriter.flush() {
            stopRecording(reason: error)
        }
    }

    @objc private func appGainedFocus() {
        guard isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording, !self.isCalibrating else { return }
            self.phoneState = .recording
        }
    }

    // MARK: - Керування записом

    func startRecording() {
        guard !isRecording else { return }

        guard motionManager.isDeviceMotionAvailable else {
            showMessage("Акселерометр недоступний. Перевірте дозволи та запускайте застосунок на фізичному iPhone (у симуляторі сенсорів немає).")
            return
        }

        // Спершу очищаємо дані і створюємо файл, потім вмикаємо сесію
        resetData()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        if let error = csvWriter.open(fileName: "Velox_Data_\(formatter.string(from: Date())).csv") {
            showMessage(error)
            return
        }

        isRecording = true
        // Телефон у тримачі ніхто не торкається: без цього iOS погасить екран,
        // застосунок втратить активність (штраф) і перестане отримувати дані
        UIApplication.shared.isIdleTimerDisabled = true

        startTime = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        maneuverDetector.reset()
        distractionPolicy.reset()
        orientationDetector.reset()
        calibration = nil
        lastRawLongitudinal = 0.0
        lastUserAcceleration = Vector3.zero
        lastKnownSpeed = 0.0

        if locationAuthorized {
            locationManager.startUpdatingLocation()
        }

        // Кожен запис починається з калібрування
        beginCalibration(event: "CalibrationStart")

        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let self = self else { return }
            if let error = error {
                self.handleMotionError(error)
                return
            }
            guard let motion = motion else { return }
            self.processMotionData(motion)
        }
    }

    func stopRecording(reason: String? = nil) {
        guard isRecording else { return }
        isRecording = false
        isCalibrating = false
        calibration = nil
        calibrationProgress = 0.0
        calibrationInfo = ""
        phoneState = .idle
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false

        let summary: String
        if csvWriter.recordedSamples > 0 {
            let safetyClass = SafetyClass.classify(safetyScore)
            summary = "Safety Score: \(safetyScore) (\(safetyClass.label))\n"
                + "Маневри: \(hardBrakingCount + hardAccelerationCount), відволікання: \(distractionCount)"
        } else {
            summary = ""
        }

        let saveResult = csvWriter.finish()
        let fullMessage = [reason, summary.isEmpty ? nil : summary, saveResult]
            .compactMap { $0 }
            .joined(separator: "\n")
        showMessage(fullMessage)
    }

    // Ручне перекалібрування (кнопка в інтерфейсі). Дозволене лише коли авто
    // практично стоїть - див. canManuallyRecalibrate.
    func recalibrate() {
        guard isRecording, !isCalibrating, canManuallyRecalibrate else { return }
        triggerHapticFeedback(style: .warning)
        beginCalibration(event: "CalibrationStart")
    }

    // Кнопку варто вимикати під час руху: перекалібрування вимагає їхати
    // (фаза GPS), а взаємодія з телефоном на ходу суперечить самій меті
    // застосунку. Автоматичне перекалібрування працює без цього.
    var canManuallyRecalibrate: Bool {
        lastKnownSpeed < Self.manualRecalibrationMaxSpeed
    }

    // Скидання лічильників; файл поїздки під час запису не зачіпається
    func resetData() {
        hardBrakingCount = 0
        hardAccelerationCount = 0
        distractionCount = 0
        filter.reset()
        currentGForceY = 0.0

        if !isRecording {
            phoneState = .idle
        }
    }

    // MARK: - Калібрування

    private func beginCalibration(event: String) {
        calibrator.reset(locationAvailable: locationAuthorized)
        forwardPhaseLogged = false
        isCalibrating = true
        calibrationProgress = 0.0
        orientationDetector.resetTimer()
        phoneState = .calibrating
        calibrationInfo = "Тримайте телефон нерухомо"
        appendEventRow(event: event)
    }

    private func apply(_ outcome: CalibrationOutcome) {
        switch outcome {
        case .calibratingUp(let progress):
            calibrationProgress = progress
            calibrationInfo = "Тримайте телефон нерухомо"
        case .calibratingForward(let progress):
            calibrationProgress = progress
            calibrationInfo = "Проїдьте прямо, плавно прискорюючись і гальмуючи"
            if !forwardPhaseLogged {
                forwardPhaseLogged = true
                appendEventRow(event: "CalibrationForwardStart")
            }
        case .finished(let result):
            finishCalibration(result)
        case .failed(let message):
            isCalibrating = false
            stopRecording(reason: "Калібрування не вдалося: " + message)
        }
    }

    private func finishCalibration(_ result: CalibrationResult) {
        calibration = result
        isCalibrating = false
        calibrationProgress = 1.0
        // Осі змінились, тому фільтр починає з нуля
        filter.reset()
        currentGForceY = 0.0
        orientationDetector.reset()
        phoneState = .recording

        switch result.forwardSource {
        case .gps:
            let percent = Int((result.forwardQuality * 100).rounded())
            calibrationInfo = "Калібрування завершено (GPS), якість \(percent)%"
            appendEventRow(event: "CalibrationDone")
        case .fallbackFlatMount:
            calibrationInfo = "Калібрування без GPS: припущено, що телефон лежить екраном вгору, верхом вперед"
            appendEventRow(event: "CalibrationDoneFallback")
        }

        triggerHapticFeedback(style: .success)
    }

    // MARK: - Обробка даних

    private func handleMotionError(_ error: Error) {
        guard isRecording else { return }
        stopRecording(reason: "Втрачено зв'язок із сенсором: \(error.localizedDescription)")
    }

    private func vector(_ a: CMAcceleration) -> Vector3 {
        Vector3(x: a.x, y: a.y, z: a.z)
    }

    private func vector(_ r: CMRotationRate) -> Vector3 {
        Vector3(x: r.x, y: r.y, z: r.z)
    }

    private func processMotionData(_ motion: CMDeviceMotion) {
        // Захист від запізнілого виклику після зупинки запису
        guard isRecording else { return }

        let gravity = vector(motion.gravity)
        let userAcceleration = vector(motion.userAcceleration)
        let time = sessionTime(of: motion)

        if isCalibrating {
            let outcome = calibrator.feedMotion(gravity: gravity,
                                                userAcceleration: userAcceleration,
                                                rotationRate: vector(motion.rotationRate),
                                                time: time)
            apply(outcome)
            return
        }

        guard let calibration = calibration else { return }

        // Кардинальна зміна положення телефона: калібруємо заново
        if orientationDetector.update(gravity: gravity, calibratedUp: calibration.up, time: time) {
            triggerHapticFeedback(style: .warning)
            beginCalibration(event: "CalibrationStart_Auto")
            return
        }

        // Поздовжнє прискорення в осях автомобіля, далі Low-Pass фільтр
        let raw = calibration.longitudinal(userAcceleration)
        lastRawLongitudinal = raw
        lastUserAcceleration = userAcceleration
        currentGForceY = filter.process(raw)

        var event = ""
        if let maneuver = maneuverDetector.detect(filtered: currentGForceY, at: time) {
            switch maneuver {
            case .hardBraking: hardBrakingCount += 1
            case .hardAcceleration: hardAccelerationCount += 1
            }
            triggerHapticFeedback(style: .error)
            event = maneuver.eventCode
        }
        appendRow(event: event, time: time, isSample: true)
    }

    // MARK: - Рядки CSV

    // Рядок лише з подією (Distraction, Calibration...): повторює останні значення
    private func appendEventRow(event: String, time: TimeInterval? = nil) {
        appendRow(event: event, time: time ?? sessionTime(), isSample: false)
    }

    private func appendRow(event: String, time: TimeInterval, isSample: Bool) {
        let row = TelemetryRow(time: time,
                               filtered: currentGForceY,
                               state: phoneState.title,
                               event: event,
                               raw: lastRawLongitudinal,
                               userAcceleration: lastUserAcceleration,
                               tiltDegrees: orientationDetector.lastAngle,
                               score: safetyScore,
                               speed: lastKnownSpeed)
        if let error = csvWriter.append(row, isSample: isSample) {
            stopRecording(reason: error)
        }
    }

    // MARK: - Повідомлення

    private func triggerHapticFeedback(style: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(style)
    }

    private func showMessage(_ text: String) {
        alertMessage = text
        showAlert = true
    }
}
