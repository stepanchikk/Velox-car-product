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
    private var stableTicks: Int = 0
    private var rotationTicks: Int = 0
    
    // Історія для аналізу мікротремору (живої руки)
    private var pitchHistory: [Double] = []
    private var rollHistory: [Double] = []
    
    init() {
        // Підписуємося на сповіщення про згортання додатка
        NotificationCenter.default.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    // 1. ЗАХИСТ: Згортання додатка
    @objc private func appMovedToBackground() {
        guard isRecording else { return }
        DispatchQueue.main.async {
            self.distractionScore += 5 // Серйозний штраф за соцмережі/месенджери
            self.phoneState = "Додаток згорнуто! 📱"
            self.stableTicks = 0
            self.triggerHapticFeedback(style: .error)
        }
    }
    
    // 2. ЗАХИСТ: Дотики до екрана (викликається з UI)
    func registerScreenTouch() {
        guard isRecording else { return }
        DispatchQueue.main.async {
            // Штрафуємо тільки якщо телефон вважався стабільним
            if self.phoneState == "Стабільний рух ✅" {
                self.distractionScore += 1
                self.phoneState = "Дотик до екрана! 👆"
                self.stableTicks = 0 // Збиваємо калібрування
                self.triggerHapticFeedback(style: .warning)
            }
        }
    }
    
    func startRecording() {
        guard motionManager.isDeviceMotionAvailable else { return }
        isRecording = true
        resetData()
        phoneState = "Стабільний рух"
        
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
    }
    
    func resetData() {
        hardBrakingCount = 0; hardAccelerationCount = 0; distractionScore = 0
        currentGForceY = 0.0
        phoneState = "Очікування"
        stableTicks = 0; rotationTicks = 0
        pitchHistory.removeAll(); rollHistory.removeAll()
    }
    
    private func processMotionData(_ motion: CMDeviceMotion) {
        let rotX = motion.rotationRate.x, rotY = motion.rotationRate.y, rotZ = motion.rotationRate.z
        let rotationMagnitude = sqrt(rotX*rotX + rotY*rotY + rotZ*rotZ)
        
        // 3. ЗАХИСТ: Аналіз мікротремору (чи лежить телефон на твердому)
        pitchHistory.append(motion.attitude.pitch)
        rollHistory.append(motion.attitude.roll)
        if pitchHistory.count > 10 { pitchHistory.removeFirst() }
        if rollHistory.count > 10 { rollHistory.removeFirst() }
        
        let pitchRange = (pitchHistory.max() ?? 0) - (pitchHistory.min() ?? 0)
        let rollRange = (rollHistory.max() ?? 0) - (rollHistory.min() ?? 0)
        
        // Якщовання кута в межах від 0.002 до 0.05 - це мікротремор руки.
        // Менше 0.002 - це твердий пластик авто. Більше 0.05 - це вже активний рух.
        let isHandTremor = (pitchRange > 0.002 && pitchRange < 0.05) || (rollRange > 0.002 && rollRange < 0.05)
        
        if rotationMagnitude > 1.5 || isHandTremor {
            rotationTicks += 1
            if rotationTicks >= 3 {
                DispatchQueue.main.async {
                    self.phoneState = isHandTremor ? "Жива рука (Тремор) 🖐" : "Телефон крутять! ❌"
                    self.stableTicks = 0
                    if Int.random(in: 1...15) == 1 { // Трохи рідше даємо штраф, щоб не дратувати
                        self.distractionScore += 1
                        self.triggerHapticFeedback(style: .warning)
                    }
                }
            }
        } else {
            rotationTicks = 0
            if stableTicks < 20 {
                stableTicks += 1
                DispatchQueue.main.async { self.phoneState = "Калібрування... ⏳" }
            } else {
                DispatchQueue.main.async { self.phoneState = "Стабільний рух ✅" }
                let accelY = motion.userAcceleration.y
                DispatchQueue.main.async {
                    self.currentGForceY = (0.2 * accelY) + (0.8 * self.currentGForceY)
                    self.detectManeuvers(currentY: self.currentGForceY)
                }
            }
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
}
