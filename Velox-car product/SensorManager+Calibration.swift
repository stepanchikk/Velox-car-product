import Foundation
import CoreLocation
import UIKit

// Калібрування орієнтації і перевірка напряму руху за поворотами
extension SensorManager {

    func beginCalibration(event: String) {
        setLocationPrecision(forCalibration: true)
        // Перекалібрування під час поїздки: авто може їхати, вимоги до спокою мʼякші
        calibrator.reset(locationAvailable: locationAuthorized, inMotion: hasCalibrated)
        retryCalibrationAt = nil
        forwardPhaseLogged = false
        isCalibrating = true
        calibrationProgress = 0.0
        orientationDetector.resetTimer()
        phoneState = .calibrating
        calibrationInfo = "Тримайте телефон нерухомо"
        appendEventRow(event: event)
    }

    func apply(_ outcome: CalibrationOutcome) {
        switch outcome {
        case .calibratingUp(let progress):
            calibrationProgress = progress
            calibrationInfo = "Тримайте телефон нерухомо"
        case .calibratingForward(let progress):
            calibrationProgress = progress
            calibrationInfo = "Проїдьте прямо, плавно прискорюючись і гальмуючи"
            if !forwardPhaseLogged {
                forwardPhaseLogged = true
                appendEventRow(event: "CalibrationForwardStart")
            }
        case .finished(let result):
            finishCalibration(result)
        case .failed(let message):
            isCalibrating = false
            guard hasCalibrated else {
                // На старті водій поруч із телефоном і може виправити причину сам
                stopRecording(reason: "Калібрування не вдалося: " + message)
                return
            }
            // Перекалібрування в русі: поїздку не зупиняємо, а пробуємо ще раз.
            // Поки калібрування немає, виміри не пишуться, але відволікання рахуються.
            calibration = nil
            calibrationProgress = 0.0
            let delay = Int(VeloxConfig.recalibrationRetryDelay)
            calibrationInfo = "Повторне калібрування через \(delay) с. \(message)"
            phoneState = .calibrating
            appendEventRow(event: "CalibrationFailed")
            retryCalibrationAt = sessionTime() + VeloxConfig.recalibrationRetryDelay
        }
    }

    private func finishCalibration(_ result: CalibrationResult) {
        setLocationPrecision(forCalibration: false)
        calibration = result
        hasCalibrated = true
        isCalibrating = false
        calibrationProgress = 1.0
        // Осі змінились, тому фільтр починає з нуля
        filter.reset()
        currentGForceY = 0.0
        orientationDetector.reset()
        phoneState = .recording

        switch result.forwardSource {
        case .gps:
            let percent = Int((result.forwardQuality * 100).rounded())
            calibrationInfo = "Калібрування завершено (GPS), якість \(percent)%"
            appendEventRow(event: "CalibrationDone")
        case .fallbackFlatMount, .yawCorrelation:
            calibrationInfo = "Калібрування без GPS: напрям руху уточниться на перших поворотах"
            appendEventRow(event: "CalibrationDoneFallback")
        }

        // Без GPS напрям руху - лише припущення про кріплення: перевіряємо його
        // за поворотами під час поїздки
        if result.forwardSource == .gps {
            yawEstimator = nil
        } else {
            yawEstimator = YawForwardEstimator(up: result.up)
            nextYawCheckEnergy = YawForwardEstimator.requiredEnergy
            yawDirectionChecked = false
        }

        triggerHapticFeedback(style: .success)
    }

    /// Порівнює напрям руху, знайдений за поворотами, з поточним і за потреби
    /// виправляє калібрування. Перевірка повторюється щоразу, коли поворотів
    /// стає вдвічі більше, тож оцінка з часом лише уточнюється.
    func checkYawEstimate(time: TimeInterval) {
        guard let estimator = yawEstimator, let current = calibration,
              estimator.energy >= nextYawCheckEnergy,
              let forward = estimator.estimate else { return }
        nextYawCheckEnergy = estimator.energy * 2

        let angle = OrientationCalibrator.angleDegrees(forward, current.forward)
        if angle > Self.yawCorrectionAngle {
            calibration = CalibrationResult(up: current.up, forward: forward,
                                            forwardSource: .yawCorrelation,
                                            forwardQuality: estimator.consistency)
            // Нова вісь: фільтр і паузи маневрів починають з нуля
            filter.reset()
            currentGForceY = 0.0
            maneuverDetector.reset()
            calibrationInfo = "Напрям руху виправлено за поворотами (на \(Int(angle.rounded()))°)"
            appendEventRow(event: "CalibrationDirectionFix", time: time)
        } else if !yawDirectionChecked {
            calibrationInfo = "Напрям руху підтверджено за поворотами"
            appendEventRow(event: "CalibrationDirectionConfirmed", time: time)
        }
        yawDirectionChecked = true
    }
}
