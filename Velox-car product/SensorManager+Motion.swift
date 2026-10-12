import Foundation
import CoreMotion
import UIKit

// Обробка вимірів CoreMotion і запис рядків CSV
extension SensorManager {

    // Момент, коли сенсор фактично зробив вимір (а не коли ми його обробили)
    private func sessionTime(of motion: CMDeviceMotion) -> TimeInterval {
        motion.timestamp - startUptime
    }

    func handleMotionError(_ error: Error) {
        guard isRecording else { return }
        stopRecording(reason: "Втрачено зв'язок із сенсором: \(error.localizedDescription)")
    }

    private func vector(_ a: CMAcceleration) -> Vector3 {
        Vector3(x: a.x, y: a.y, z: a.z)
    }

    private func vector(_ r: CMRotationRate) -> Vector3 {
        Vector3(x: r.x, y: r.y, z: r.z)
    }

    func processMotionData(_ motion: CMDeviceMotion) {
        // Захист від запізнілого виклику після зупинки запису
        guard isRecording else { return }

        let gravity = vector(motion.gravity)
        let userAcceleration = vector(motion.userAcceleration)
        let time = sessionTime(of: motion)
        // Запис із вимкненим екраном: відкладені рішення про блокування і розблокування
        checkScreenState(time: time)

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

        // Без GPS: перевірка напряму руху за поворотами (може замінити калібрування)
        if let estimator = yawEstimator {
            estimator.addSample(userAcceleration: userAcceleration, rotationRate: vector(motion.rotationRate))
            checkYawEstimate(time: time)
        }
        let activeCalibration = self.calibration ?? calibration

        // Поздовжнє прискорення в осях автомобіля, далі Low-Pass фільтр
        let raw = activeCalibration.longitudinal(userAcceleration)
        lastRawLongitudinal = raw
        lastUserAcceleration = userAcceleration
        lastRotationRate = vector(motion.rotationRate)
        currentGForceY = filter.process(raw)

        var event = ""
        if let maneuver = maneuverDetector.detect(filtered: currentGForceY, at: time) {
            switch maneuver {
            case .hardBraking:
                hardBrakingCount += 1
                liveRoute.addEvent(.hardBraking, at: time, maxAge: Self.speedMaxAge)
            case .hardAcceleration:
                hardAccelerationCount += 1
                liveRoute.addEvent(.hardAcceleration, at: time, maxAge: Self.speedMaxAge)
            }
            triggerHapticFeedback(style: .error)
            event = maneuver.eventCode
        }
        appendRow(event: event, time: time, isSample: true)
    }

    // MARK: - Рядки CSV

    // Рядок лише з подією (Distraction, Calibration...): повторює останні значення
    func appendEventRow(event: String, time: TimeInterval? = nil) {
        appendRow(event: event, time: time ?? sessionTime(), isSample: false)
    }

    /// stopOnError = false - під час зупинки: помилку запису покаже finish()
    func appendRow(event: String, time: TimeInterval, isSample: Bool, stopOnError: Bool = true) {
        let row = TelemetryRow(time: time,
                               filtered: currentGForceY,
                               state: phoneState.title,
                               event: event,
                               raw: lastRawLongitudinal,
                               userAcceleration: lastUserAcceleration,
                               rotationRate: lastRotationRate,
                               tiltDegrees: orientationDetector.lastAngle,
                               score: safetyScore,
                               speed: freshSpeed,
                               coordinate: freshCoordinate)
        if let error = csvWriter.append(row, isSample: isSample), stopOnError {
            stopRecording(reason: error)
            return
        }
        // Контролер сам відкидає однакові і надто часті оновлення
        liveActivity.update(liveActivityState())
    }
}
