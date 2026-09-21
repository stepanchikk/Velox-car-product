import Foundation
import CoreMotion
import Combine
import UIKit

class SensorManager: ObservableObject {
    private let motionManager = CMMotionManager()
    
    @Published var isRecording = false
    @Published var currentGForceY: Double = 0.0
    
    @Published var hardBrakingCount: Int = 0
    @Published var hardAccelerationCount: Int = 0
    @Published var distractionScore: Int = 0
    @Published var phoneState: String = "Очікування"
    
    private var lastEventTime: Date = Date.distantPast
    
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
    
    @objc private func appLostFocus() {
        guard isRecording else { return }
        DispatchQueue.main.async {
            self.distractionScore += 5
            self.phoneState = "Відволікання! ⚠️"
            self.triggerHapticFeedback(style: .error)
        }
    }
    
    @objc private func appGainedFocus() {
        guard isRecording else { return }
        // Через 2 секунди після повернення в додаток повертаємо зелений статус
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.isRecording {
                self.phoneState = "Запис іде ✅"
            }
        }
    }
    
    func startRecording() {
        guard motionManager.isDeviceMotionAvailable else { return }
        isRecording = true
        resetData()
        phoneState = "Запис іде ✅"
        
        // Ініціалізація CSV
        startTime = Date()
        csvData.removeAll()
        csvData.append("Timestamp,Filtered_Y,State")
        
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
            let row = "\(timestamp),\(self.currentGForceY),\(safeState)"
            self.csvData.append(row)
        }
    }
    
    private func detectManeuvers(currentY: Double) {
        let now = Date()
        if now.timeIntervalSince(lastEventTime) < 3.0 { return }
        
        if currentY < -0.4 {
            hardBrakingCount += 1
            triggerHapticFeedback(style: .error)
            lastEventTime = now
        } else if currentY > 0.4 {
            hardAccelerationCount += 1
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
                print("✅ Файл успішно збережено: \(fileURL.path)")
            } catch {
                print("❌ Помилка збереження файлу: \(error)")
            }
        }
    }
}
