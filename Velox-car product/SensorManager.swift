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
    
    // Масив для збереження рядків таблиці
    private var csvData: [String] = []
    
    func startSensors() {
        // Перевірка, чи датчик взагалі доступний
        if motionManager.isAccelerometerAvailable {
            // Очищаємо старі дані і створюємо заголовки стовпців
            csvData = ["Timestamp,X,Y,Z"]
            
            motionManager.accelerometerUpdateInterval = 0.1
            
            // Запуск збору даних в основному потоці
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data, error == nil else { return }
                
                self.x = data.acceleration.x
                self.y = data.acceleration.y
                self.z = data.acceleration.z
                
                // Фіксуємо точний час (UNIX) та записуємо координати
                let timestamp = Date().timeIntervalSince1970
                let row = "\(timestamp),\(self.x),\(self.y),\(self.z)"
                self.csvData.append(row)
            }
            isRecording = true
        }
    }
    
    func stopSensors() {
        motionManager.stopAccelerometerUpdates()
        isRecording = false
        saveDataToCSV()
    }
    
    private func saveDataToCSV() {
        // З'єднуємо всі рядки через перенесення
        let csvString = csvData.joined(separator: "\n")
        
        // Знаходимо папку документів додатку на iPhone
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentDirectory = paths.first else { return }
        
        // Генеруємо унікальну назву з датою
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "Velox_\(formatter.string(from: Date())).csv"
        
        let fileURL = documentDirectory.appendingPathComponent(fileName)
        
        do {
            try csvString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Файл збережено: \(fileURL.path)")
        } catch {
            print("Помилка збереження файлу: \(error.localizedDescription)")
        }
    }
}
