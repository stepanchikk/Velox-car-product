import Foundation
import CoreMotion
import Combine
import UIKit

class SensorManager: ObservableObject {
    private let motionManager = CMMotionManager()

    // ФІКС 1: єдина константа порогу замість захардкоджених 0.4 у різних місцях
    static let maneuverThreshold: Double = 0.4

    @Published var isRecording = false
    @Published var currentGForceY: Double = 0.0

    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionScore: Int = 0
    @Published var phoneState: String = "Очікування"

    private var lastEventTime: Date = Date.distantPast

    // ФІКС 3: подія, що чекає запису в найближчий рядок CSV
    private var pendingEvent: String = ""

    // Змінні для запису CSV
    private var csvData: [String] = []
    private var fileName: String = ""
    private var startTime: Date = Date()

    init() {
        // ЗАХИСТ: Згортання додатка АБО відкриття шторки сповіщень
        NotificationCenter.default.addObserver(self, selector: #selector(appLostFocus), name: UIApplication.willResignActiveNotification, object: nil)

        // Повернення в додаток
        NotificationCenter.default.addObserver(self, selector: #selector(appGainedFocus), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // ФІКС 2: прибираємо спостерігачів, коли об'єкт звільняється з пам'яті
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appLostFocus() {
        guard isRecording else { return }
        DispatchQueue.main.async {
            self.distractionScore += 5
            self.phoneState = "Відволікання!"
            self.pendingEvent = "Distraction"
            self.triggerHapticFeedback(style: .error)
        }
    }

    @objc private func appGainedFocus() {
        guard isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.isRecording {
                self.phoneState = "Запис іде"
            }
        }
    }

    func startRecording() {
        guard motionManager.isDeviceMotionAvailable else { return }
        isRecording = true
        resetData()
        phoneState = "Запис іде"

        // Ініціалізація CSV
        startTime = Date()
        csvData.removeAll()
        // ФІКС 3: додана колонка Event
        csvData.append("Timestamp,Filtered_Y,State,Event")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileName = "Velox_Data_\(formatter.string(from: Date())).csv"

        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let motion = motion, error == nil else { return }
            self?.processMotionData(motion)
        }
    }

    func stopRecording() {
        isRecording = false
        phoneState = "Очікування"
        motionManager.stopDeviceMotionUpdates()
        saveCSV()
    }

    func resetData() {
        hardBrakingCount = 0; hardAccelerationCount = 0; distractionScore = 0
        currentGForceY = 0.0
        phoneState = "Очікування"
        pendingEvent = ""
        csvData.removeAll()
    }

    private func processMotionData(_ motion: CMDeviceMotion) {
        let accelY = motion.userAcceleration.y

        DispatchQueue.main.async {
            // Low-Pass фільтр
            self.currentGForceY = (0.2 * accelY) + (0.8 * self.currentGForceY)
            self.detectManeuvers(currentY: self.currentGForceY)

            // Запис у CSV
            let timestamp = Date().timeIntervalSince(self.startTime)
            let safeState = self.phoneState.replacingOccurrences(of: ",", with: "")
            let row = "\(timestamp),\(self.currentGForceY),\(safeState),\(self.pendingEvent)"
            self.csvData.append(row)

            self.pendingEvent = ""
        }
    }

    private func detectManeuvers(currentY: Double) {
        let now = Date()
        if now.timeIntervalSince(lastEventTime) < 3.0 { return }

        // ФІКС 1: використовуємо спільну константу
        if currentY < -Self.maneuverThreshold {
            hardBrakingCount += 1
            pendingEvent = "HardBraking"
            triggerHapticFeedback(style: .error)
            lastEventTime = now
        } else if currentY > Self.maneuverThreshold {
            hardAccelerationCount += 1
            pendingEvent = "HardAcceleration"
            triggerHapticFeedback(style: .error)
            lastEventTime = now
        }
    }

    private func triggerHapticFeedback(style: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(style)
    }

    private func saveCSV() {
        let csvString = csvData.joined(separator: "\n")
        if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = documentDirectory.appendingPathComponent(fileName)
            do {
                try csvString.write(to: fileURL, atomically: true, encoding: .utf8)
                print("Файл успішно збережено: \(fileURL.path)")
            } catch {
                print("Помилка збереження файлу: \(error)")
            }
        }
    }
}
