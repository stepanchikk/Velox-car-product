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
///
/// Код класу розкладено по файлах за відповідальністю:
/// - SensorManager.swift - стан, ініціалізація, годинник сесії, повідомлення;
/// - SensorManager+Session.swift - старт, зупинка, скидання, доступ до геолокації;
/// - SensorManager+Motion.swift - обробка вимірів CoreMotion і рядки CSV;
/// - SensorManager+Calibration.swift - калібрування і перевірка напряму за поворотами;
/// - SensorManager+AntiFraud.swift - втрата активності, відволікання, дзвінки;
/// - SensorManager+Location.swift - геолокація, свіжість швидкості і координат.
///
/// Swift не дозволяє бачити private-члени з інших файлів, тому стан, яким
/// користуються кілька розширень, оголошено без private. Змінювати його
/// мають лише методи SensorManager; інтерфейс лише читає опубліковані значення.
class SensorManager: NSObject, ObservableObject, CLLocationManagerDelegate, CXCallObserverDelegate {
    let motionManager = CMMotionManager()
    let locationManager = CLLocationManager()
    // Телефонні дзвінки: вхідний дзвінок і розмова без рук не є відволіканням
    let callObserver = CXCallObserver()

    // Поріг перевантаження (також використовується в TrackerView для підсвічування)
    static let maneuverThreshold: Double = VeloxConfig.maneuverThreshold
    // Коефіцієнт Low-Pass фільтра
    static let filterAlpha: Double = VeloxConfig.filterAlpha
    // Ручне перекалібрування дозволене лише "майже на стоянці" (безпека:
    // не заохочуємо водія натискати кнопки під час руху)
    static let manualRecalibrationMaxSpeed: Double = VeloxConfig.manualRecalibrationMaxSpeed
    // Швидкість GPS старша за цей час вважається невідомою (тунель, паркінг)
    static let speedMaxAge: TimeInterval = 3.0
    // Розбіжність напряму за поворотами з поточним, після якої калібрування виправляється
    static let yawCorrectionAngle: Double = 20.0

    // isRecording = сесія активна (калібрування або запис)
    @Published var isRecording = false
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0.0
    @Published var calibrationInfo: String = ""
    @Published var lastKnownSpeed: Double = 0.0
    // Момент останнього коректного оновлення швидкості (секунди сесії)
    var lastSpeedTime: TimeInterval = -.infinity

    // Маршрут і мітки подій для живої карти на екрані поїздки. Тримаються лише
    // в памʼяті, тому ведуться за будь-якого значення «Зберігати маршрут».
    @Published var liveRoute = LiveRoute()

    /// Швидкість для екрана, км/год; nil, якщо GPS давно мовчить
    var currentSpeedKmh: Double? {
        freshSpeed.map { $0 * 3.6 }
    }

    /// Жива карта має сенс лише під час запису з доступом до геолокації
    var isLiveMapAvailable: Bool {
        isRecording && locationAuthorized
    }

    // Поздовжнє прискорення після калібрування (відфільтроване)
    @Published var currentGForceY: Double = 0.0

    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionCount: Int = 0
    // Сумарний час з телефоном у руках і штраф за тривалість (оновлюються,
    // коли водій повертається до застосунку)
    @Published var distractionSeconds: TimeInterval = 0
    @Published var distractionDurationPenalty: Int = 0
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
    let calibrator = OrientationCalibrator()
    var calibration: CalibrationResult?
    var filter = LowPassFilter(alpha: SensorManager.filterAlpha)
    var maneuverDetector = ManeuverDetector(threshold: SensorManager.maneuverThreshold,
                                                    cooldown: VeloxConfig.maneuverCooldown)
    var distractionTracker = DistractionTracker()
    var orientationDetector = OrientationChangeDetector()
    let csvWriter = TripCSVWriter()

    // Втрата активності, яку ще не класифіковано (див. handleFocusLost)
    var pendingFocusLoss: (time: TimeInterval, callWasActive: Bool)?
    // Дзвінок триває (записано CallIncoming або CallStart, ще немає CallEnd)
    var callInProgress = false
    // Коли почався дзвінок (секунди сесії), щоб відрізнити екран розмови,
    // відкритий системою, від виходу водія із застосунку під час розмови
    var callStartedAt: TimeInterval?
    // Відволікання почалось через розмову з телефоном біля вуха
    var handheldCallEpisode = false

    // Калібрування в цій поїздці вже вдавалось: далі йдуть перекалібрування в русі
    var hasCalibrated = false
    // Без GPS напрям руху перевіряється за поворотами (див. checkYawEstimate)
    var yawEstimator: YawForwardEstimator?
    // Наступна перевірка - коли накопичиться стільки "енергії" поворотів
    var nextYawCheckEnergy: Double = YawForwardEstimator.requiredEnergy
    var yawDirectionChecked = false
    // Час сесії, коли повторити невдале перекалібрування
    var retryCalibrationAt: TimeInterval?

    var forwardPhaseLogged = false
    // Після системного діалогу дозволу запис стартує автоматично
    var startAfterAuthorization = false
    // Користувач уже погодився записувати без GPS у цьому запуску застосунку
    var userAcceptedFallback = false

    var locationAuthorized: Bool {
        locationStatus == .authorized
    }

    // Останні значення, які потрапляють у рядки CSV
    var lastRawLongitudinal: Double = 0.0
    var lastUserAcceleration: Vector3 = Vector3.zero
    var lastRotationRate: Vector3 = Vector3.zero

    // Маршрут: пишеться лише з увімкненим «Зберігати маршрут» і доступом до геолокації.
    // Налаштування фіксується на старті, щоб файл не змінював формат посеред поїздки.
    var recordRoute = false
    var lastCoordinate: RoutePoint?
    var lastCoordinateTime: TimeInterval = -.infinity

    // Єдиний годинник сесії: секунди від натискання «Старт».
    // CoreMotion рахує час від увімкнення пристрою (як systemUptime), а GPS дає
    // настінний час (Date), тому фіксуємо обидва моменти старту одночасно.
    var startTime: Date = Date()
    var startUptime: TimeInterval = 0

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

    // MARK: - Час сесії

    // Поточний момент (для подій без власної мітки часу: сповіщення, кнопки)
    func sessionTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - startUptime
    }

    // MARK: - Повідомлення

    func triggerHapticFeedback(style: UINotificationFeedbackGenerator.FeedbackType) {
        // Вібрацію можна вимкнути в Налаштуваннях
        guard AppSettings.hapticsEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(style)
    }

    func showMessage(_ text: String) {
        alertMessage = text
        showAlert = true
    }
}
