import Foundation
import CoreMotion
import CoreLocation
import Combine
import UIKit
import CallKit
import AVFoundation

// Стан сесії, який бачить користувач і який записується в колонку State.
// Тексти збігаються з попередніми версіями, щоб старі CSV аналізувались так само.
enum SessionState: Equatable {
    case idle
    case calibrating
    case recording
    case distracted
    case onCall

    var title: String {
        switch self {
        case .idle: return "Очікування"
        case .calibrating: return "Калібрування..."
        case .recording: return "Запис іде"
        case .distracted: return "Відволікання!"
        case .onCall: return "Дзвінок"
        }
    }
}

// Щойно збережена поїздка: інтерфейс відкриває її підсумок
struct FinishedTrip: Equatable {
    let fileName: String
    // Причина зупинки або попередження про запис (nil - звичайна зупинка)
    let notice: String?
}

// Доступ до геолокації з погляду калібрування напряму руху
enum LocationAccess: Equatable {
    case notDetermined      // ще не запитували
    case authorized         // дозволено, точне місцезнаходження
    case reducedAccuracy    // дозволено, але лише приблизне: швидкості немає
    case denied             // заборонено або обмежено

    var hint: String {
        switch self {
        case .notDetermined: return "Геолокація: буде запитана при старті"
        case .authorized: return "Геолокація: дозволено"
        case .reducedAccuracy: return "Геолокація: лише приблизна, калібрування спрощене"
        case .denied: return "Геолокація: заборонено, калібрування спрощене"
        }
    }
}

/// Керуючий клас сесії запису. Отримує дані від сенсорів і системи, передає їх
/// спеціалізованим компонентам і публікує стан для інтерфейсу:
/// - OrientationCalibrator - калібрування орієнтації (OrientationCalibrator.swift);
/// - LowPassFilter, ManeuverDetector, DistractionTracker (з DistractionPolicy),
///   CallPolicy, OrientationChangeDetector
///   - обробка сигналу і виявлення подій (EventDetectors.swift);
/// - SafetyScoreCalculator - модель штрафів (SafetyScore.swift);
/// - TripCSVWriter - запис поїздки у файл (TripCSVWriter.swift).
class SensorManager: NSObject, ObservableObject, CLLocationManagerDelegate, CXCallObserverDelegate {
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    // Телефонні дзвінки: вхідний дзвінок і розмова без рук не є відволіканням
    private let callObserver = CXCallObserver()

    // Поріг перевантаження (також використовується в TrackerView для підсвічування)
    static let maneuverThreshold: Double = VeloxConfig.maneuverThreshold
    // Коефіцієнт Low-Pass фільтра
    static let filterAlpha: Double = VeloxConfig.filterAlpha
    // Ручне перекалібрування дозволене лише "майже на стоянці" (безпека:
    // не заохочуємо водія натискати кнопки під час руху)
    private static let manualRecalibrationMaxSpeed: Double = VeloxConfig.manualRecalibrationMaxSpeed
    // Швидкість GPS старша за цей час вважається невідомою (тунель, паркінг)
    private static let speedMaxAge: TimeInterval = 3.0

    // isRecording = сесія активна (калібрування або запис)
    @Published var isRecording = false
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0.0
    @Published var calibrationInfo: String = ""
    @Published var lastKnownSpeed: Double = 0.0
    // Момент останнього коректного оновлення швидкості (секунди сесії)
    private var lastSpeedTime: TimeInterval = -.infinity

    // Поздовжнє прискорення після калібрування (відфільтроване)
    @Published var currentGForceY: Double = 0.0

    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionCount: Int = 0
    // Сумарний час з телефоном у руках і штраф за тривалість (оновлюються,
    // коли водій повертається до застосунку)
    @Published private(set) var distractionSeconds: TimeInterval = 0
    @Published private(set) var distractionDurationPenalty: Int = 0
    @Published var phoneState: SessionState = .idle

    // Обчислюється з лічильників, тому завжди узгоджений з ними
    var safetyScore: Int {
        SafetyScoreCalculator.score(maneuvers: hardBrakingCount + hardAccelerationCount,
                                    distractions: distractionCount,
                                    durationPenalty: distractionDurationPenalty)
    }

    // Повідомлення для користувача (помилки та підтвердження)
    @Published var showAlert = false
    @Published var alertMessage = ""

    // Заповнюється після збереження поїздки; MainTabView показує підсумок і очищає
    @Published var finishedTrip: FinishedTrip?

    // Геолокація: стан доступу і діалоги перед стартом
    @Published var locationStatus: LocationAccess = .notDetermined
    @Published var showLocationPrompt = false        // пояснення перед системним запитом
    @Published var showLocationDeniedPrompt = false  // доступу немає: Налаштування або без GPS

    // Компоненти
    private let calibrator = OrientationCalibrator()
    private var calibration: CalibrationResult?
    private var filter = LowPassFilter(alpha: SensorManager.filterAlpha)
    private var maneuverDetector = ManeuverDetector(threshold: SensorManager.maneuverThreshold,
                                                    cooldown: VeloxConfig.maneuverCooldown)
    private var distractionTracker = DistractionTracker()
    private var orientationDetector = OrientationChangeDetector()
    private let csvWriter = TripCSVWriter()

    // Втрата активності, яку ще не класифіковано (див. handleFocusLost)
    private var pendingFocusLoss: (time: TimeInterval, callWasActive: Bool)?
    // Дзвінок триває (записано CallIncoming або CallStart, ще немає CallEnd)
    private var callInProgress = false
    // Відволікання почалось через розмову з телефоном біля вуха
    private var handheldCallEpisode = false

    // Калібрування в цій поїздці вже вдавалось: далі йдуть перекалібрування в русі
    private var hasCalibrated = false
    // Час сесії, коли повторити невдале перекалібрування
    private var retryCalibrationAt: TimeInterval?

    private var forwardPhaseLogged = false
    // Після системного діалогу дозволу запис стартує автоматично
    private var startAfterAuthorization = false
    // Користувач уже погодився записувати без GPS у цьому запуску застосунку
    private var userAcceptedFallback = false

    private var locationAuthorized: Bool {
        locationStatus == .authorized
    }

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

        // Дзвінки і зміна аудіовиходу (динамік біля вуха, гучний звʼязок, Bluetooth, CarPlay)
        callObserver.setDelegate(self, queue: DispatchQueue.main)
        // Це сповіщення надходить у фоновому потоці, тому обробник ставиться
        // в головну чергу. Посилання на self слабке: після звільнення об'єкта
        // обробник нічого не робить (SensorManager живе весь час роботи застосунку)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCallState()
            }
        }

        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        // Інакше на довгій зупинці iOS може призупинити оновлення і сама їх
        // не відновить: решта поїздки залишилась би без швидкості GPS
        locationManager.pausesLocationUpdatesAutomatically = false
        setLocationPrecision(forCalibration: true)
        // Дозвіл не запитуємо одразу: лише при першому «Старт», з поясненням навіщо
        locationStatus = currentLocationAccess()
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

    private func currentLocationAccess() -> LocationAccess {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways:
            // Приблизне місцезнаходження не дає швидкості, потрібної калібруванню
            return locationManager.accuracyAuthorization == .fullAccuracy ? .authorized : .reducedAccuracy
        default:
            return .denied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = currentLocationAccess()
        // Користувач відповів на системний запит: стартуємо (з GPS або без)
        if startAfterAuthorization, locationStatus != .notDetermined {
            startAfterAuthorization = false
            startRecording()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, isRecording else { return }

        // Перше оновлення може бути старою закешованою позицією: пропускаємо її
        let time = sessionTime(of: location)
        guard time > -1.0 else { return }

        let speed = location.speed
        // speed < 0 означає, що iOS не змогла визначити швидкість
        if speed >= 0 {
            lastKnownSpeed = speed
            lastSpeedTime = time
        }

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

    // Штрафів немає лише під час першого калібрування поїздки (водій щойно
    // натиснув «Старт»). Перекалібрування в русі не звільняє від штрафу.
    private var distractionsPaused: Bool {
        isCalibrating && !hasCalibrated
    }

    private func handleFocusLost() {
        guard isRecording, !distractionsPaused, pendingFocusLoss == nil else { return }
        // Екран вхідного дзвінка відкривається трохи раніше, ніж CallKit повідомляє
        // про дзвінок, тому причину визначаємо з невеликою затримкою, а час
        // відволікання беремо з моменту втрати активності
        pendingFocusLoss = (sessionTime(), callInProgress)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resolvePendingFocusLoss()
        }
    }

    // Викликається таймером або поверненням у застосунок, залежно від того, що раніше
    private func resolvePendingFocusLoss() {
        guard let pending = pendingFocusLoss else { return }
        pendingFocusLoss = nil
        guard isRecording else { return }

        switch CallPolicy.cause(for: currentCallState, callWasActive: pending.callWasActive) {
        case .incomingCall:
            appendEventRow(event: "CallIncoming", time: pending.time)
            // Дзвінок відкрито: CallEnd запишеться, коли дзвінків не залишиться
            // (навіть якщо iOS призупинила застосунок на час розмови)
            callInProgress = true
            phoneState = .onCall
        case .handsFreeCall:
            updateCallState()
        case .distraction:
            beginDistraction(at: pending.time)
        }
    }

    private func beginDistraction(at time: TimeInterval) {
        switch distractionTracker.begin(at: time) {
        case .counted:
            distractionCount += 1
            phoneState = .distracted
            // Пишемо подію в CSV одразу, а не чекаємо наступного виміру
            appendEventRow(event: "Distraction", time: time)
            triggerHapticFeedback(style: .error)
        case .resumed:
            phoneState = .distracted
            appendEventRow(event: "DistractionResume", time: time)
        case .ignored, .alreadyActive:
            break
        }
    }

    // Водій повернувся: фіксуємо тривалість і штраф за неї (у рядку
    // DistractionEnd колонка Score вже враховує цей штраф)
    private func endDistraction(at time: TimeInterval, stopOnError: Bool = true) {
        guard distractionTracker.end(at: time) != nil else { return }
        handheldCallEpisode = false
        distractionSeconds = distractionTracker.totalDuration
        distractionDurationPenalty = distractionTracker.durationPenalty
        appendRow(event: "DistractionEnd", time: time, isSample: false, stopOnError: stopOnError)
    }

    @objc private func appEnteredBackground() {
        guard isRecording else { return }
        if let error = csvWriter.flush() {
            stopRecording(reason: error)
        }
    }

    @objc private func appGainedFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusGained()
        }
    }

    private func handleFocusGained() {
        guard isRecording else { return }
        resolvePendingFocusLoss()
        // Відволікання через розмову біля вуха закінчується разом із розмовою
        if !handheldCallEpisode {
            endDistraction(at: sessionTime())
        }
        updateCallState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording, !self.distractionTracker.isActive else { return }
            if self.isCalibrating || self.calibration == nil {
                self.phoneState = .calibrating
            } else {
                self.phoneState = self.callInProgress ? .onCall : .recording
            }
        }
    }

    // MARK: - Дзвінки (CallKit)

    // Звук розмови йде в динамік біля вуха: телефон у руці
    private var isReceiverRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }

    private var currentCallState: CallState {
        let calls = callObserver.calls.filter { !$0.hasEnded }
        guard !calls.isEmpty else { return .none }
        if calls.contains(where: { $0.hasConnected || $0.isOutgoing }) {
            return .active(handheld: isReceiverRoute)
        }
        return .incomingRinging
    }

    // Делегат викликається в головній черзі (див. init)
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        updateCallState()
    }

    // Звіряє стан дзвінка із записаним: початок і кінець розмови, телефон біля вуха
    private func updateCallState() {
        guard isRecording else {
            callInProgress = false
            return
        }
        let now = sessionTime()
        switch currentCallState {
        case .none, .incomingRinging:
            guard callInProgress else { return }
            callInProgress = false
            if handheldCallEpisode {
                endDistraction(at: now)
            }
            appendEventRow(event: "CallEnd", time: now)
            if phoneState == .onCall {
                phoneState = .recording
            }
        case .active(let handheld):
            if !callInProgress {
                callInProgress = true
                appendEventRow(event: handheld ? "CallStart_Handheld" : "CallStart", time: now)
                if phoneState != .distracted, !isCalibrating {
                    phoneState = .onCall
                }
            }
            // Розмова з телефоном біля вуха - відволікання (поки звук не перемкнули
            // на гучний звʼязок чи гарнітуру)
            if handheld, !distractionTracker.isActive, !distractionsPaused {
                beginDistraction(at: now)
                handheldCallEpisode = distractionTracker.isActive
            } else if !handheld, handheldCallEpisode {
                endDistraction(at: now)
                if phoneState == .distracted {
                    phoneState = .onCall
                }
            }
        }
    }

    // MARK: - Керування записом

    // Кнопка «Старт»: спершу з'ясовуємо доступ до геолокації
    func requestStart() {
        guard !isRecording else { return }
        // Без сенсорів руху питати про геолокацію немає сенсу: startRecording покаже помилку
        guard motionManager.isDeviceMotionAvailable else {
            startRecording()
            return
        }
        locationStatus = currentLocationAccess()
        switch locationStatus {
        case .authorized:
            startRecording()
        case .notDetermined:
            showLocationPrompt = true
        case .denied, .reducedAccuracy:
            if userAcceptedFallback {
                startRecording()
            } else {
                showLocationDeniedPrompt = true
            }
        }
    }

    // «Дозволити» в поясненні: системний запит, після відповіді запис стартує сам
    func allowLocationAndStart() {
        startAfterAuthorization = true
        locationManager.requestWhenInUseAuthorization()
    }

    // «Без геолокації»: спрощене калібрування (телефон екраном вгору, верхом вперед)
    func startWithoutLocation() {
        userAcceptedFallback = true
        startRecording()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var locationDeniedMessage: String {
        if locationStatus == .reducedAccuracy {
            return "Увімкнено лише приблизне місцезнаходження, а калібруванню потрібна точна швидкість. Увімкніть: Налаштування → Velox → Геолокація → «Точне місцезнаходження». Без цього телефон треба класти екраном вгору, верхньою частиною вперед."
        }
        return "Доступ до геолокації заборонено. Без неї калібрування спрощене: телефон треба класти екраном вгору, верхньою частиною вперед. Дозволити доступ можна в Налаштуваннях."
    }

    func startRecording() {
        guard !isRecording else { return }

        guard motionManager.isDeviceMotionAvailable else {
            showMessage("Акселерометр недоступний. Перевірте дозволи та запускайте застосунок на фізичному iPhone (у симуляторі сенсорів немає).")
            return
        }

        // Спершу очищаємо дані і створюємо файл, потім вмикаємо сесію
        resetData()

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        // На початку файлу - параметри алгоритмів, версія застосунку і пристрій
        if let error = csvWriter.open(fileName: "Velox_Data_\(formatter.string(from: now)).csv",
                                      metadata: TripMetadata.recording(startedAt: now)) {
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
        orientationDetector.reset()
        calibration = nil
        hasCalibrated = false
        retryCalibrationAt = nil
        pendingFocusLoss = nil
        callInProgress = false
        lastRawLongitudinal = 0.0
        lastUserAcceleration = Vector3.zero
        lastKnownSpeed = 0.0
        lastSpeedTime = -.infinity

        if locationAuthorized {
            locationManager.startUpdatingLocation()
        }

        // Кожен запис починається з калібрування
        beginCalibration(event: "CalibrationStart")

        motionManager.deviceMotionUpdateInterval = VeloxConfig.sampleInterval
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
        // Відволікання, що ще триває, закривається моментом зупинки
        let stopTime = sessionTime()
        pendingFocusLoss = nil
        endDistraction(at: stopTime, stopOnError: false)
        if callInProgress {
            appendRow(event: "CallEnd", time: stopTime, isSample: false, stopOnError: false)
            callInProgress = false
        }
        retryCalibrationAt = nil
        isRecording = false
        isCalibrating = false
        calibration = nil
        calibrationProgress = 0.0
        calibrationInfo = ""
        phoneState = .idle
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false

        let result = csvWriter.finish()
        switch result {
        case .saved(let fileName, let warning):
            // Підсумок (оцінка, події, файл) показує екран поїздки, тож окреме
            // повідомлення потрібне лише для причини зупинки чи помилки запису
            let notice = [reason, warning].compactMap { $0 }.joined(separator: "\n")
            finishedTrip = FinishedTrip(fileName: fileName, notice: notice.isEmpty ? nil : notice)
        case .empty, .notCreated:
            showMessage([reason, result.message].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    /// Запасний варіант, якщо збережений файл не вдалося відкрити в історії
    func showSavedTripMessage(_ trip: FinishedTrip) {
        let summary = "Safety Score: \(safetyScore) (\(SafetyClass.classify(safetyScore).label))\n"
            + "Маневри: \(hardBrakingCount + hardAccelerationCount), відволікання: \(distractionCount)"
        showMessage([trip.notice, summary, "Дані поїздки збережено: \(trip.fileName)"]
            .compactMap { $0 }
            .joined(separator: "\n"))
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
    // Файл поточного запису: історія поїздок його не показує, бо він ще не завершений
    var currentTripFileName: String? {
        isRecording ? csvWriter.fileName : nil
    }

    var canManuallyRecalibrate: Bool {
        lastKnownSpeed < Self.manualRecalibrationMaxSpeed
    }

    // Скидання лічильників; файл поїздки під час запису не зачіпається
    func resetData() {
        hardBrakingCount = 0
        hardAccelerationCount = 0
        distractionCount = 0
        distractionTracker.reset()
        handheldCallEpisode = false
        distractionSeconds = 0
        distractionDurationPenalty = 0
        filter.reset()
        currentGForceY = 0.0

        if !isRecording {
            phoneState = .idle
        }
    }

    // MARK: - Калібрування

    // MARK: - Енергоспоживання GPS

    // Режим BestForNavigation (максимальна точність і злиття з іншими сенсорами)
    // потрібен лише для калібрування напряму руху. Під час запису швидкість
    // потрібна для колонки Speed_mps і блокування ручного перекалібрування в русі;
    // для цього вистачає NearestTenMeters, що витрачає помітно менше енергії.
    private func setLocationPrecision(forCalibration: Bool) {
        locationManager.desiredAccuracy = forCalibration
            ? kCLLocationAccuracyBestForNavigation
            : kCLLocationAccuracyNearestTenMeters
    }

    // Швидкість для CSV: nil, якщо GPS давно мовчить (порожнє значення в колонці
    // краще за застаріле: analyzer.py пропускає порожні значення)
    private var freshSpeed: Double? {
        sessionTime() - lastSpeedTime <= Self.speedMaxAge ? lastKnownSpeed : nil
    }

    private func beginCalibration(event: String) {
        setLocationPrecision(forCalibration: true)
        // Перекалібрування під час поїздки: авто може їхати, вимоги до спокою мʼякші
        calibrator.reset(locationAvailable: locationAuthorized, inMotion: hasCalibrated)
        retryCalibrationAt = nil
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
            guard hasCalibrated else {
                // На старті водій поруч із телефоном і може виправити причину сам
                stopRecording(reason: "Калібрування не вдалося: " + message)
                return
            }
            // Перекалібрування в русі: поїздку не зупиняємо, а пробуємо ще раз.
            // Поки калібрування немає, виміри не пишуться, але відволікання рахуються.
            calibration = nil
            calibrationProgress = 0.0
            let delay = Int(VeloxConfig.recalibrationRetryDelay)
            calibrationInfo = "Повторне калібрування через \(delay) с. \(message)"
            phoneState = .calibrating
            appendEventRow(event: "CalibrationFailed")
            retryCalibrationAt = sessionTime() + VeloxConfig.recalibrationRetryDelay
        }
    }

    private func finishCalibration(_ result: CalibrationResult) {
        setLocationPrecision(forCalibration: false)
        calibration = result
        hasCalibrated = true
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

        guard let calibration = calibration else {
            // Невдале перекалібрування: чекаємо паузу і пробуємо знову
            if let retryAt = retryCalibrationAt, time >= retryAt {
                beginCalibration(event: "CalibrationStart_Retry")
            }
            return
        }

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

    /// stopOnError = false - під час зупинки: помилку запису покаже finish()
    private func appendRow(event: String, time: TimeInterval, isSample: Bool, stopOnError: Bool = true) {
        let row = TelemetryRow(time: time,
                               filtered: currentGForceY,
                               state: phoneState.title,
                               event: event,
                               raw: lastRawLongitudinal,
                               userAcceleration: lastUserAcceleration,
                               tiltDegrees: orientationDetector.lastAngle,
                               score: safetyScore,
                               speed: freshSpeed)
        if let error = csvWriter.append(row, isSample: isSample), stopOnError {
            stopRecording(reason: error)
        }
    }

    // MARK: - Повідомлення

    private func triggerHapticFeedback(style: UINotificationFeedbackGenerator.FeedbackType) {
        // Вібрацію можна вимкнути в Налаштуваннях
        guard AppSettings.hapticsEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(style)
    }

    private func showMessage(_ text: String) {
        alertMessage = text
        showAlert = true
    }
}
