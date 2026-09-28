import Foundation
import CoreMotion
import Combine
import UIKit

class SensorManager: ObservableObject {
    private let motionManager = CMMotionManager()

    // Єдина константа порогу перевантаження
    static let maneuverThreshold: Double = 0.4

    // Пауза між двома зафіксованими маневрами
    private static let maneuverCooldown: TimeInterval = 3.0
    // БАГФІКС 2: скільки секунд після старту ігноруємо втрату фокусу
    // (натискання кнопки, системні вікна, що з'являються одразу після старту)
    private static let distractionGracePeriod: TimeInterval = 3.0
    // БАГФІКС 2: мінімальний інтервал між двома штрафами за відволікання
    // (захист від "дребезгу" при відкритті шторки чи Центру керування)
    private static let distractionCooldown: TimeInterval = 1.5
    private static let distractionPenalty: Int = 5

    @Published var isRecording = false
    @Published var currentGForceY: Double = 0.0

    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionScore: Int = 0
    @Published var phoneState: String = "Очікування"

    // БАГФІКС 3 і 4: повідомлення для користувача (помилки та підтвердження)
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var lastEventTime: Date = Date.distantPast
    private var lastDistractionTime: Date = Date.distantPast

    // Змінні для запису CSV
    private var csvData: [String] = []
    private var fileName: String = ""
    private var startTime: Date = Date()

    init() {
        // ЗАХИСТ: згортання додатка АБО відкриття шторки сповіщень
        NotificationCenter.default.addObserver(self, selector: #selector(appLostFocus), name: UIApplication.willResignActiveNotification, object: nil)

        // Повернення в додаток
        NotificationCenter.default.addObserver(self, selector: #selector(appGainedFocus), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // Прибираємо спостерігачів і зупиняємо сенсор, коли об'єкт звільняється з пам'яті
    deinit {
        NotificationCenter.default.removeObserver(self)
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - Життєвий цикл додатка (Anti-Fraud)

    @objc private func appLostFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusLost()
        }
    }

    private func handleFocusLost() {
        guard isRecording else { return }
        let now = Date()

        // БАГФІКС 2: не штрафуємо одразу після старту та не дублюємо штраф
        guard now.timeIntervalSince(startTime) > Self.distractionGracePeriod,
              now.timeIntervalSince(lastDistractionTime) > Self.distractionCooldown else { return }
        lastDistractionTime = now

        distractionScore += Self.distractionPenalty
        phoneState = "Відволікання!"

        // БАГФІКС 6: пишемо подію в CSV одразу, а не чекаємо наступного
        // виміру акселерометра (у фоні вимірювання можуть не надходити)
        appendCSVRow(event: "Distraction")
        triggerHapticFeedback(style: .error)
    }

    @objc private func appGainedFocus() {
        guard isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.phoneState = "Запис іде"
        }
    }

    // MARK: - Керування записом

    func startRecording() {
        guard !isRecording else { return }

        // БАГФІКС 3: користувач бачить причину, чому запис не почався
        guard motionManager.isDeviceMotionAvailable else {
            showMessage("Акселерометр недоступний. Перевірте дозволи та запускайте застосунок на фізичному iPhone (у симуляторі сенсорів немає).")
            return
        }

        // Спершу очищаємо дані, потім вмикаємо запис
        resetData()
        isRecording = true
        phoneState = "Запис іде"

        // Ініціалізація CSV
        startTime = Date()
        lastEventTime = Date.distantPast
        lastDistractionTime = Date.distantPast
        csvData = ["Timestamp,Filtered_Y,State,Event"]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileName = "Velox_Data_\(formatter.string(from: Date())).csv"

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
        phoneState = "Очікування"
        motionManager.stopDeviceMotionUpdates()

        // БАГФІКС 4: повідомляємо результат збереження
        let saveResult = saveCSV()
        if let reason = reason {
            showMessage(reason + "\n" + saveResult)
        } else {
            showMessage(saveResult)
        }
    }

    // БАГФІКС 1: скидання не руйнує CSV, поки триває запис
    func resetData() {
        hardBrakingCount = 0
        hardAccelerationCount = 0
        distractionScore = 0
        currentGForceY = 0.0

        if !isRecording {
            phoneState = "Очікування"
            csvData.removeAll()
        }
    }

    // MARK: - Обробка даних

    private func handleMotionError(_ error: Error) {
        guard isRecording else { return }
        stopRecording(reason: "Втрачено зв'язок із сенсором: \(error.localizedDescription)")
    }

    private func processMotionData(_ motion: CMDeviceMotion) {
        // Захист від запізнілого виклику після зупинки запису
        guard isRecording else { return }

        // Low-Pass фільтр (колбек уже приходить у головній черзі)
        currentGForceY = (0.2 * motion.userAcceleration.y) + (0.8 * currentGForceY)
        let event = detectManeuvers(currentY: currentGForceY)

        // Запис у CSV
        appendCSVRow(event: event)
    }

    private func detectManeuvers(currentY: Double) -> String {
        let now = Date()
        guard now.timeIntervalSince(lastEventTime) >= Self.maneuverCooldown else { return "" }

        if currentY < -Self.maneuverThreshold {
            hardBrakingCount += 1
            triggerHapticFeedback(style: .error)
            lastEventTime = now
            return "HardBraking"
        } else if currentY > Self.maneuverThreshold {
            hardAccelerationCount += 1
            triggerHapticFeedback(style: .error)
            lastEventTime = now
            return "HardAcceleration"
        }
        return ""
    }

    private func appendCSVRow(event: String) {
        let timestamp = Date().timeIntervalSince(startTime)
        let safeState = phoneState.replacingOccurrences(of: ",", with: "")
        csvData.append("\(timestamp),\(currentGForceY),\(safeState),\(event)")
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

    // Повертає текст результату для показу користувачу
    private func saveCSV() -> String {
        // БАГФІКС 4: якщо є лише заголовок, файл не створюємо
        guard csvData.count > 1 else {
            return "Даних для збереження немає, файл не створено."
        }

        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Не вдалося знайти папку для збереження файлу."
        }

        let fileURL = documentDirectory.appendingPathComponent(fileName)
        let csvString = csvData.joined(separator: "\n")
        do {
            try csvString.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Дані поїздки збережено: \(fileName)"
        } catch {
            return "Помилка збереження файлу: \(error.localizedDescription)"
        }
    }
}
