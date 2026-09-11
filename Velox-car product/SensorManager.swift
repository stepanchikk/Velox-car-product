import Foundation
import CoreMotion
import Combine

class SensorManager: ObservableObject {
    // Головний об'єкт Apple для роботи з датчиками руху
    private var motionManager = CMMotionManager()
    
    // Властивості @Published автоматично оновлюватимуть інтерфейс при зміні значень
    @Published var x: Double = 0.0
    @Published var y: Double = 0.0
    @Published var z: Double = 0.0
    @Published var isRecording: Bool = false
    
    func startSensors() {
        // Перевірка, чи датчик взагалі доступний
        if motionManager.isAccelerometerAvailable {
            //Частота оновлень: 0.1 секунди
            motionManager.accelerometerUpdateInterval = 0.1
            
            // Запуск збору даних в основному потоці
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let data = data, error == nil else { return }
                
                // Запис отриманих сирих даних у змінні
                self?.x = data.acceleration.x
                self?.y = data.acceleration.y
                self?.z = data.acceleration.z
            }
            isRecording = true
        }
    }
    
    func stopSensors() {
        motionManager.stopAccelerometerUpdates()
        isRecording = false
    }
}
