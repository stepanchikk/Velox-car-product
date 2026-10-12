import Foundation
import CoreMotion
import CoreLocation
import UIKit

// Керування сесією: старт, зупинка, скидання, діалоги доступу до геолокації
extension SensorManager {

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
        liveRoute = LiveRoute()

        let now = Date()
        recordRoute = AppSettings.saveRouteEnabled && locationAuthorized
        lastCoordinate = nil
        lastCoordinateTime = -.infinity
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        // На початку файлу - параметри алгоритмів, версія застосунку і пристрій
        if let error = csvWriter.open(fileName: "Velox_Data_\(formatter.string(from: now)).csv",
                                      metadata: TripMetadata.recording(startedAt: now, route: recordRoute)) {
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
        yawEstimator = nil
        retryCalibrationAt = nil
        pendingFocusLoss = nil
        callInProgress = false
        callStartedAt = nil
        lastRawLongitudinal = 0.0
        lastUserAcceleration = Vector3.zero
        lastRotationRate = Vector3.zero
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
            callStartedAt = nil
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
        liveRoute.clearEvents()
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
}
