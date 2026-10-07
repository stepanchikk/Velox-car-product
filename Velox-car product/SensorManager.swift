import Foundation
import CoreMotion
import CoreLocation
import Combine
import UIKit

class SensorManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()

    // Єдина константа порогу перевантаження
    static let maneuverThreshold: Double = 0.4
    // Коефіцієнт Low-Pass фільтра
    static let filterAlpha: Double = 0.2

    // Пауза між двома зафіксованими маневрами (окремо для гальмування і
    // розгону, щоб один не "з'їдав" паузу для іншого - якщо гальмування і
    // розгін трапляються з різницею менше cooldown, обидва мають зарахуватись)
    private static let maneuverCooldown: TimeInterval = 3.0
    // Скільки секунд після старту ігноруємо втрату фокусу
    private static let distractionGracePeriod: TimeInterval = 3.0
    // Мінімальний інтервал між двома штрафами за відволікання
    private static let distractionCooldown: TimeInterval = 1.5
    private static let distractionPenalty: Int = 5

    // Safety Score: 100 балів базово, штраф за кожен маневр і кожен факт
    // відволікання (README: -2 за маневр, -5 за відволікання)
    private static let maneuverPenalty: Int = 2

    // Автоматичне перекалібрування: на скільки градусів має змінитись нахил
    // телефона і як довго (секунд) ця зміна має тривати
    private static let recalibrationAngle: Double = 30.0
    private static let recalibrationHold: TimeInterval = 2.0
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
    @Published var distractionScore: Int = 0
    @Published var phoneState: String = "Очікування"

    // Обчислюється з лічильників вище, тому завжди узгоджений з ними і
    // автоматично скидається разом з resetData(). distractionScore уже
    // містить накопичений штраф (5 за подію), тому додається як є.
    var safetyScore: Int {
        let maneuvers = hardBrakingCount + hardAccelerationCount
        let penalty = Self.maneuverPenalty * maneuvers + distractionScore
        return max(0, 100 - penalty)
    }

    // Повідомлення для користувача (помилки та підтвердження)
    @Published var showAlert = false
    @Published var alertMessage = ""

    private let calibrator = OrientationCalibrator()
    private var calibration: CalibrationResult?
    private var orientationChangedSince: TimeInterval?
    private var forwardPhaseLogged = false
    private var locationAuthorized = false

    // Моменти останніх подій у секундах сесії (див. sessionTime)
    private var lastBrakingTime: TimeInterval = -.infinity
    private var lastAccelerationTime: TimeInterval = -.infinity
    private var lastDistractionTime: TimeInterval = -.infinity

    // Останні значення, які потрапляють у рядки CSV
    private var lastRawLongitudinal: Double = 0.0
    private var lastUserAcceleration: Vector3 = Vector3.zero
    private var lastTiltDegrees: Double = 0.0

    // Запис CSV: рядки накопичуються в буфері і дописуються у файл частинами,
    // тому при аварійному завершенні втрачається не більше ~10 с поїздки
    private static let csvHeader = "Timestamp,Filtered_Y,State,Event,Raw_Y,Ax,Ay,Az,Tilt_deg,Score,Speed_mps"
    private static let flushEveryRows = 100   // ~10 с при 10 Гц
    private var pendingRows: [String] = []
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var recordedSamples: Int = 0
    private var fileName: String = ""
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
            _ = finishCSV()
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

        guard now > Self.distractionGracePeriod,
              now - lastDistractionTime > Self.distractionCooldown else { return }
        lastDistractionTime = now

        distractionScore += Self.distractionPenalty
        phoneState = "Відволікання!"

        // Пишемо подію в CSV одразу, а не чекаємо наступного виміру
        appendEventRow(event: "Distraction", time: now)
        triggerHapticFeedback(style: .error)
    }

    @objc private func appEnteredBackground() {
        guard isRecording else { return }
        if let error = flushCSV() {
            stopRecording(reason: error)
        }
    }

    @objc private func appGainedFocus() {
        guard isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording, !self.isCalibrating else { return }
            self.phoneState = "Запис іде"
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
        fileName = "Velox_Data_\(formatter.string(from: Date())).csv"
        if let error = openCSV() {
            showMessage(error)
            return
        }

        isRecording = true
        // Телефон у тримачі ніхто не торкається: без цього iOS погасить екран,
        // застосунок втратить активність (штраф) і перестане отримувати дані
        UIApplication.shared.isIdleTimerDisabled = true

        startTime = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        lastBrakingTime = -.infinity
        lastAccelerationTime = -.infinity
        lastDistractionTime = -.infinity
        calibration = nil
        recordedSamples = 0
        lastRawLongitudinal = 0.0
        lastUserAcceleration = Vector3.zero
        lastTiltDegrees = 0.0
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
        phoneState = "Очікування"
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false

        let summary: String
        if recordedSamples > 0 {
            let safetyClass = SafetyClass.classify(safetyScore)
            summary = "Safety Score: \(safetyScore) (\(safetyClass.label))\n"
                + "Маневри: \(hardBrakingCount + hardAccelerationCount), відволікання: \(distractionScore / Self.distractionPenalty)"
        } else {
            summary = ""
        }

        let saveResult = finishCSV()
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
    // застосунку. Автоматичне перекалібрування (нижче) працює без цього.
    var canManuallyRecalibrate: Bool {
        lastKnownSpeed < Self.manualRecalibrationMaxSpeed
    }

    // Скидання не руйнує CSV, поки триває запис
    func resetData() {
        hardBrakingCount = 0
        hardAccelerationCount = 0
        distractionScore = 0
        currentGForceY = 0.0

        if !isRecording {
            phoneState = "Очікування"
            pendingRows.removeAll()
        }
    }

    // MARK: - Калібрування

    private func beginCalibration(event: String) {
        calibrator.reset(locationAvailable: locationAuthorized)
        forwardPhaseLogged = false
        isCalibrating = true
        calibrationProgress = 0.0
        orientationChangedSince = nil
        phoneState = "Калібрування..."
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
        currentGForceY = 0.0
        lastTiltDegrees = 0.0
        orientationChangedSince = nil
        phoneState = "Запис іде"

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

    // true, якщо нахил телефона суттєво змінився і це триває достатньо довго
    private func orientationChanged(gravity: Vector3,
                                    time: TimeInterval,
                                    calibration: CalibrationResult) -> Bool {
        let angle = OrientationCalibrator.angleDegrees(-gravity, calibration.up)
        lastTiltDegrees = angle

        guard angle > Self.recalibrationAngle else {
            orientationChangedSince = nil
            return false
        }

        if let since = orientationChangedSince {
            return time - since >= Self.recalibrationHold
        }
        orientationChangedSince = time
        return false
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
        if orientationChanged(gravity: gravity, time: time, calibration: calibration) {
            triggerHapticFeedback(style: .warning)
            beginCalibration(event: "CalibrationStart_Auto")
            return
        }

        // Поздовжнє прискорення в осях автомобіля, далі Low-Pass фільтр
        let raw = calibration.longitudinal(userAcceleration)
        lastRawLongitudinal = raw
        lastUserAcceleration = userAcceleration
        currentGForceY = Self.filterAlpha * raw + (1.0 - Self.filterAlpha) * currentGForceY

        let event = detectManeuvers(currentY: currentGForceY, time: time)
        appendMotionRow(event: event, time: time)
    }

    private func detectManeuvers(currentY: Double, time now: TimeInterval) -> String {

        if currentY < -Self.maneuverThreshold,
           now - lastBrakingTime >= Self.maneuverCooldown {
            hardBrakingCount += 1
            triggerHapticFeedback(style: .error)
            lastBrakingTime = now
            return "HardBraking"
        } else if currentY > Self.maneuverThreshold,
                  now - lastAccelerationTime >= Self.maneuverCooldown {
            hardAccelerationCount += 1
            triggerHapticFeedback(style: .error)
            lastAccelerationTime = now
            return "HardAcceleration"
        }
        return ""
    }

    // Рядок із виміром (враховується при збереженні)
    private func appendMotionRow(event: String, time: TimeInterval) {
        recordedSamples += 1
        writeRow(event: event, time: time)
    }

    // Рядок лише з подією (Distraction, Calibration...): повторює останні значення
    private func appendEventRow(event: String, time: TimeInterval? = nil) {
        writeRow(event: event, time: time ?? sessionTime())
    }

    private func writeRow(event: String, time timestamp: TimeInterval) {
        let safeState = phoneState.replacingOccurrences(of: ",", with: "")
        let a = lastUserAcceleration
        pendingRows.append("\(timestamp),\(currentGForceY),\(safeState),\(event),\(lastRawLongitudinal),\(a.x),\(a.y),\(a.z),\(lastTiltDegrees),\(safetyScore),\(lastKnownSpeed)")

        if pendingRows.count >= Self.flushEveryRows, let error = flushCSV() {
            stopRecording(reason: error)
        }
    }

    private func triggerHapticFeedback(style: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(style)
    }

    // MARK: - Збереження

    private func showMessage(_ text: String) {
        alertMessage = text
        showAlert = true
    }

    // Створює файл із заголовком і відкриває його для дописування.
    // Повертає текст помилки або nil.
    private func openCSV() -> String? {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Не вдалося знайти папку для збереження файлу."
        }
        let url = documentDirectory.appendingPathComponent(fileName)
        do {
            try (Self.csvHeader + "\n").write(to: url, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: url)
            _ = try handle.seekToEnd()
            fileHandle = handle
            fileURL = url
            pendingRows.removeAll()
            return nil
        } catch {
            return "Не вдалося створити файл поїздки: \(error.localizedDescription)"
        }
    }

    // Дописує накопичені рядки у файл. Повертає текст помилки або nil.
    @discardableResult
    private func flushCSV() -> String? {
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

    // Дописує залишок, закриває файл і повертає текст результату для користувача
    private func finishCSV() -> String {
        let flushError = flushCSV()
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
