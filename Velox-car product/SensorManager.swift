import Foundation
import CoreMotion
import Combine

class SensorManager: ObservableObject {
    private var motionManager = CMMotionManager()
    
    // Сирі дані (для логування)
    @Published var x: Double = 0.0
    @Published var y: Double = 0.0
    @Published var z: Double = 0.0
    
    // Відфільтровані дані
    @Published var filteredX: Double = 0.0
    @Published var filteredY: Double = 0.0
    @Published var filteredZ: Double = 0.0
    
    @Published var isRecording: Bool = false
    private var csvData: [String] = []
    
    // Коефіцієнт фільтрації. 0.2 означає: 20% нових даних + 80% історії
    private let filterFactor = 0.2
    
    func startSensors() {
        if motionManager.isAccelerometerAvailable {
            // Тепер у CSV є сирі і відфільтровані дані для порівняння
            csvData = ["Timestamp,Raw_X,Raw_Y,Raw_Z,Filtered_X,Filtered_Y,Filtered_Z"]
            motionManager.accelerometerUpdateInterval = 0.1
            
            // Скидаємо початкові значення фільтра перед новим записом
            filteredX = 0.0
            filteredY = 0.0
            filteredZ = 0.0
            
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data, error == nil else { return }
                
                // 1. Отримуємо сирі дані
                self.x = data.acceleration.x
                self.y = data.acceleration.y
                self.z = data.acceleration.z
                
                // 2. Застосовуємо Low-Pass Filter
                self.filteredX = (self.x * self.filterFactor) + (self.filteredX * (1.0 - self.filterFactor))
                self.filteredY = (self.y * self.filterFactor) + (self.filteredY * (1.0 - self.filterFactor))
                self.filteredZ = (self.z * self.filterFactor) + (self.filteredZ * (1.0 - self.filterFactor))
                
                // 3. Записуємо все у файл
                let timestamp = Date().timeIntervalSince1970
                let row = "\(timestamp),\(self.x),\(self.y),\(self.z),\(self.filteredX),\(self.filteredY),\(self.filteredZ)"
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
    
    
    func resetData() {
        filteredX = 0.0
        filteredY = 0.0
        filteredZ = 0.0
        x = 0.0
        y = 0.0
        z = 0.0
        csvData = ["Timestamp,Raw_X,Raw_Y,Raw_Z,Filtered_X,Filtered_Y,Filtered_Z"]
    }
    
    
    
    private func saveDataToCSV() {
        let csvString = csvData.joined(separator: "\n")
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentDirectory = paths.first else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "Velox_Filtered_\(formatter.string(from: Date())).csv"
        
        let fileURL = documentDirectory.appendingPathComponent(fileName)
        
        do {
            try csvString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Файл збережено: \(fileURL.path)")
        } catch {
            print("Помилка збереження файлу: \(error.localizedDescription)")
        }
    }
}
