import XCTest
@testable import Velox_car_product

// Юніт-тести чистої логіки Velox. Сенсори не потрібні: тести запускаються
// в симуляторі (Cmd+U). Числа в очікуваннях пояснено в коментарях.

// MARK: - Допоміжні функції

private func assertVector(_ v: Vector3?, _ e: Vector3, accuracy: Double = 1e-9,
                          file: StaticString = #filePath, line: UInt = #line) {
    guard let v = v else {
        return XCTFail("вектор відсутній", file: file, line: line)
    }
    XCTAssertEqual(v.x, e.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(v.y, e.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(v.z, e.z, accuracy: accuracy, file: file, line: line)
}

// Сила тяжіння для телефона, нахиленого на degrees від положення "екраном вгору"
private func gravity(tiltedBy degrees: Double) -> Vector3 {
    let r = degrees * .pi / 180
    return Vector3(x: 0, y: -sin(r), z: -cos(r))
}

// MARK: - Low-Pass фільтр

final class LowPassFilterTests: XCTestCase {

    func testFirstStepsMatchFormula() {
        var f = LowPassFilter(alpha: 0.2)
        XCTAssertEqual(f.process(1.0), 0.2, accuracy: 1e-12)    // 0.2 * 1
        XCTAssertEqual(f.process(1.0), 0.36, accuracy: 1e-12)   // 0.2 * 1 + 0.8 * 0.2
        f.reset()
        XCTAssertEqual(f.value, 0.0)
    }

    // Тривале гальмування 0.6 G перетинає поріг 0.4 G на 5-му вимірі (0.5 с):
    // 0.6 * (1 - 0.8^5) = 0.403
    func testSustainedSixTenthsCrossesThresholdAfterHalfSecond() {
        var f = LowPassFilter(alpha: 0.2)
        var crossedAt: Int?
        for n in 1...20 where crossedAt == nil {
            if f.process(0.6) > 0.4 { crossedAt = n }
        }
        XCTAssertEqual(crossedAt, 5)
    }

    // Тривале прискорення рівно 0.4 G поріг не перетинає ніколи
    func testSustainedFourTenthsNeverCrossesThreshold() {
        var f = LowPassFilter(alpha: 0.2)
        for _ in 0..<60 {
            XCTAssertLessThan(f.process(0.4), 0.4)
        }
    }
}

// MARK: - Маневри

final class ManeuverDetectorTests: XCTestCase {

    func testThresholdIsStrict() {
        var d = ManeuverDetector(threshold: 0.4)
        XCTAssertNil(d.detect(filtered: 0.4, at: 0))
        XCTAssertNil(d.detect(filtered: -0.4, at: 0))
        XCTAssertEqual(d.detect(filtered: 0.41, at: 0), .hardAcceleration)
    }

    func testCooldownPerType() {
        var d = ManeuverDetector(threshold: 0.4, cooldown: 3.0)
        XCTAssertEqual(d.detect(filtered: 0.5, at: 0.0), .hardAcceleration)
        XCTAssertNil(d.detect(filtered: 0.5, at: 1.0))                       // пауза розгону
        // Гальмування через 1.5 с після розгону зараховується: паузи окремі
        XCTAssertEqual(d.detect(filtered: -0.5, at: 1.5), .hardBraking)
        XCTAssertNil(d.detect(filtered: -0.5, at: 2.0))                      // пауза гальмування
        XCTAssertEqual(d.detect(filtered: 0.5, at: 3.0), .hardAcceleration)  // рівно 3 с: дозволено
    }

    // Одиночний сирий сплеск має перевищувати 2 G, щоб пройти фільтр і поріг
    func testSingleSpikeThroughFilter() {
        for (spike, expected) in [(1.9, false), (2.5, true)] {
            var f = LowPassFilter(alpha: 0.2)
            var d = ManeuverDetector(threshold: 0.4)
            let detected = d.detect(filtered: f.process(spike), at: 0) != nil
            XCTAssertEqual(detected, expected, "сплеск \(spike) G")
        }
    }

    func testEventCodes() {
        XCTAssertEqual(Maneuver.hardBraking.eventCode, "HardBraking")
        XCTAssertEqual(Maneuver.hardAcceleration.eventCode, "HardAcceleration")
    }
}

// MARK: - Anti-Fraud

final class DistractionPolicyTests: XCTestCase {

    func testGracePeriodAndCooldown() {
        var p = DistractionPolicy(gracePeriod: 3.0, cooldown: 1.5)
        XCTAssertFalse(p.register(at: 2.0))   // перші 3 с ігноруються
        XCTAssertFalse(p.register(at: 3.0))   // межа не включається
        XCTAssertTrue(p.register(at: 3.5))
        XCTAssertFalse(p.register(at: 4.0))   // 0.5 с після попереднього
        XCTAssertTrue(p.register(at: 5.1))    // 1.6 с після попереднього
    }

    func testResetAllowsImmediateDistraction() {
        var p = DistractionPolicy()
        XCTAssertTrue(p.register(at: 10.0))
        p.reset()
        XCTAssertTrue(p.register(at: 10.5))
    }
}

// MARK: - Зміна положення телефона

final class OrientationChangeDetectorTests: XCTestCase {
    private let up = Vector3(x: 0, y: 0, z: 1)

    func testLargeTiltMustLastTwoSeconds() {
        var d = OrientationChangeDetector(angleThreshold: 30, holdTime: 2)
        XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 0.0))
        XCTAssertEqual(d.lastAngle, 45, accuracy: 1e-6)
        XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 1.0))
        XCTAssertTrue(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 2.0))
    }

    func testReturnToCalibratedPositionResetsTimer() {
        var d = OrientationChangeDetector()
        XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 0.0))
        XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 5), calibratedUp: up, time: 1.5))
        XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 2.5))  // таймер знову з нуля
        XCTAssertTrue(d.update(gravity: gravity(tiltedBy: 45), calibratedUp: up, time: 4.5))
    }

    // Нахил дороги (до ~20°) не повинен запускати перекалібрування
    func testRoadSlopeIsIgnored() {
        var d = OrientationChangeDetector()
        for i in 0..<100 {
            XCTAssertFalse(d.update(gravity: gravity(tiltedBy: 20), calibratedUp: up, time: Double(i) * 0.1))
        }
    }
}

// MARK: - Safety Score

final class SafetyScoreTests: XCTestCase {

    func testFormula() {
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 0, distractions: 0), 100)
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 3, distractions: 0), 94)
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 0, distractions: 4), 80)
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 5, distractions: 3), 75)
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 40, distractions: 10), 0)   // не менше 0
    }

    func testClassBoundaries() {
        XCTAssertEqual(SafetyClass.classify(100), .safe)
        XCTAssertEqual(SafetyClass.classify(90), .safe)
        XCTAssertEqual(SafetyClass.classify(89), .medium)
        XCTAssertEqual(SafetyClass.classify(75), .medium)
        XCTAssertEqual(SafetyClass.classify(74), .dangerous)
        XCTAssertEqual(SafetyClass.classify(0), .dangerous)
    }
}

// MARK: - CSV

final class TripCSVWriterTests: XCTestCase {

    private func row(time: Double, state: String = "Запис іде", event: String = "") -> TelemetryRow {
        TelemetryRow(time: time, filtered: 0.1, state: state, event: event, raw: 0.2,
                     userAcceleration: Vector3(x: 0.01, y: 0.02, z: 0.03),
                     tiltDegrees: 1.5, score: 98, speed: 12.5)
    }

    private func documentsURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    func testRowHasSameColumnCountAsHeaderAndNoExtraCommas() {
        let header = TripCSVWriter.header.split(separator: ",", omittingEmptySubsequences: false)
        let line = row(time: 1, state: "Запис, іде").csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(header.count, 11)
        XCTAssertEqual(line.count, header.count)
        XCTAssertEqual(String(line[2]), "Запис іде")   // кома зі стану прибрана
    }

    func testMissingSpeedLeavesEmptyLastColumn() {
        let r = TelemetryRow(time: 1, filtered: 0, state: "Запис іде", event: "", raw: 0,
                             userAcceleration: .zero, tiltDegrees: 0, score: 100, speed: nil)
        let fields = r.csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 11)
        XCTAssertEqual(String(fields[10]), "")
    }

    func testWritesInChunksAndFinishes() throws {
        let name = "VeloxTest_\(UUID().uuidString).csv"
        let url = documentsURL(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = TripCSVWriter(flushEveryRows: 3)
        XCTAssertNil(writer.open(fileName: name))
        for i in 0..<3 {
            XCTAssertNil(writer.append(row(time: Double(i)), isSample: true))
        }
        // Після 3 рядків буфер уже у файлі, навіть без finish()
        let partial = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(partial.split(separator: "\n").count, 4)   // заголовок + 3 рядки

        XCTAssertNil(writer.append(row(time: 3, event: "Distraction"), isSample: false))
        XCTAssertTrue(writer.finish().contains(name))
        XCTAssertEqual(writer.recordedSamples, 3)                  // службовий рядок не рахується

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(String(lines[0]), TripCSVWriter.header)
    }

    func testTripWithoutSamplesLeavesNoFile() {
        let name = "VeloxTest_\(UUID().uuidString).csv"
        let url = documentsURL(name)
        let writer = TripCSVWriter()
        XCTAssertNil(writer.open(fileName: name))
        XCTAssertNil(writer.append(row(time: 0, event: "CalibrationStart"), isSample: false))
        XCTAssertTrue(writer.finish().contains("немає"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Вектори

final class Vector3Tests: XCTestCase {

    func testBasicOperations() {
        let x = Vector3(x: 1, y: 0, z: 0)
        let y = Vector3(x: 0, y: 1, z: 0)
        assertVector(x.cross(y), Vector3(x: 0, y: 0, z: 1))
        XCTAssertEqual(x.dot(y), 0)
        XCTAssertNil(Vector3.zero.normalized())
        XCTAssertEqual(Vector3(x: 3, y: 4, z: 0).length, 5, accuracy: 1e-12)
        XCTAssertEqual(OrientationCalibrator.angleDegrees(x, y), 90, accuracy: 1e-9)
    }
}

// MARK: - Калібрування напрямку руху (GPS)

final class ForwardCalibratorTests: XCTestCase {

    // Імітація руху: інтервали по 1 с, у кожному 10 вимірів прискорення
    // a (м/с²) уздовж forward і оновлення швидкості GPS у кінці інтервалу.
    // sign = -1 імітує протилежну знакову угоду сенсора.
    private func drive(_ fc: ForwardCalibrator, forward: Vector3, accelerations: [Double],
                       sign: Double = 1, lateral: Vector3 = .zero, accuracy: Double = 0.5) -> Vector3? {
        var speed = 10.0
        var t = 0.0
        _ = fc.addLocationSample(speed: speed, speedAccuracy: accuracy, time: t)
        var result: Vector3?
        for a in accelerations {
            for _ in 0..<10 {
                fc.addMotionSample(userAcceleration: forward * (sign * a / 9.81) + lateral)
            }
            speed += a
            t += 1.0
            if let r = fc.addLocationSample(speed: speed, speedAccuracy: accuracy, time: t) {
                result = r
            }
        }
        return result
    }

    func testFindsForwardForFlatPhone() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 0, y: 1, z: 0)
        // Один інтервал з розгоном 2 м/с²: energy = 4, оцінка готова
        assertVector(drive(ForwardCalibrator(up: up), forward: forward, accelerations: [2.0]), forward)
    }

    func testFindsForwardForArbitraryOrientation() {
        let up = Vector3(x: 0.3, y: -0.5, z: 0.81).normalized()!
        let forward = up.cross(Vector3(x: 1, y: 0, z: 0)).normalized()!   // горизонтальний
        assertVector(drive(ForwardCalibrator(up: up), forward: forward, accelerations: [2.0]), forward)
    }

    func testBrakingAlsoPointsForward() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 1, y: 0, z: 0)
        assertVector(drive(ForwardCalibrator(up: up), forward: forward, accelerations: [-2.0]), forward)
    }

    // Головна властивість методу: знак розгону правильний за будь-якої
    // знакової угоди сенсора
    func testSignConventionDoesNotMatter() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 0, y: 1, z: 0)
        guard let estimate = drive(ForwardCalibrator(up: up), forward: forward, accelerations: [2.0], sign: -1) else {
            return XCTFail("оцінка напряму відсутня")
        }
        assertVector(estimate, forward * -1)
        let result = CalibrationResult(up: up, forward: estimate, forwardSource: .gps, forwardQuality: 1)
        let measuredAcceleration = forward * (-1 * 2.0 / 9.81)    // розгін у "перевернутій" угоді
        XCTAssertGreaterThan(result.longitudinal(measuredAcceleration), 0)
    }

    // Постійне бокове прискорення (поворот) взаємно компенсується між
    // розгоном і гальмуванням
    func testConstantLateralAccelerationCancels() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 1, y: 0, z: 0)
        let lateral = up.cross(forward) * 0.05
        let estimate = drive(ForwardCalibrator(up: up), forward: forward, accelerations: [1.5, -1.5], lateral: lateral)
        assertVector(estimate, forward, accuracy: 1e-6)
    }

    func testInaccurateGPSIsIgnored() {
        let fc = ForwardCalibrator(up: Vector3(x: 0, y: 0, z: 1))
        XCTAssertNil(drive(fc, forward: Vector3(x: 1, y: 0, z: 0), accelerations: [2.0, 2.0], accuracy: 5.0))
        XCTAssertEqual(fc.energy, 0)
    }
}

// MARK: - Повне калібрування

final class OrientationCalibratorTests: XCTestCase {
    private let flat = Vector3(x: 0, y: 0, z: -1)   // сила тяжіння: телефон екраном вгору

    private func feedStill(_ cal: OrientationCalibrator, gravity: Vector3, count: Int,
                           from start: Double = 0) -> CalibrationOutcome {
        var outcome: CalibrationOutcome = .calibratingUp(0)
        for i in 0..<count {
            outcome = cal.feedMotion(gravity: gravity, userAcceleration: .zero, rotationRate: .zero,
                                     time: start + Double(i) * 0.1)
        }
        return outcome
    }

    func testProgressAndFallbackWithoutLocation() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: false)
        guard case .calibratingUp(let progress) = feedStill(cal, gravity: flat, count: 19) else {
            return XCTFail("після 19 вимірів калібрування ще має тривати")
        }
        XCTAssertEqual(progress, 0.95, accuracy: 1e-9)

        let outcome = cal.feedMotion(gravity: flat, userAcceleration: .zero, rotationRate: .zero, time: 1.9)
        guard case .finished(let result) = outcome else {
            return XCTFail("очікувалось завершення, отримано \(outcome)")
        }
        assertVector(result.up, Vector3(x: 0, y: 0, z: 1))
        assertVector(result.forward, Vector3(x: 0, y: 1, z: 0))   // запасний варіант: вісь Y
        XCTAssertEqual(result.forwardSource, .fallbackFlatMount)
    }

    func testMovementRestartsStillnessCount() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: false)
        _ = feedStill(cal, gravity: flat, count: 10)
        let shaken = cal.feedMotion(gravity: flat, userAcceleration: Vector3(x: 0.1, y: 0, z: 0),
                                    rotationRate: .zero, time: 1.0)
        guard case .calibratingUp(let progress) = shaken else {
            return XCTFail("рух не повинен завершувати калібрування")
        }
        XCTAssertEqual(progress, 0)
    }

    func testVerticalPhoneWithoutLocationFails() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: false)
        let outcome = feedStill(cal, gravity: Vector3(x: 0, y: -1, z: 0), count: 20)
        guard case .failed = outcome else {
            return XCTFail("без GPS напрям для вертикального телефона визначити неможливо, отримано \(outcome)")
        }
    }

    func testTimeoutGivesApproximateResult() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: false)
        var outcome: CalibrationOutcome = .calibratingUp(0)
        for i in 0..<90 {   // 9 с постійної вібрації
            outcome = cal.feedMotion(gravity: flat, userAcceleration: Vector3(x: 0.1, y: 0, z: 0),
                                     rotationRate: .zero, time: Double(i) * 0.1)
            if case .finished = outcome { break }
        }
        guard case .finished = outcome else {
            return XCTFail("після таймауту 8 с очікувався наближений результат, отримано \(outcome)")
        }
    }

    // Якщо GPS не надсилає оновлень, фаза 2 завершується за таймаутом (25 с),
    // а не зависає назавжди
    func testForwardPhaseTimesOutWithoutGPS() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: true)
        _ = feedStill(cal, gravity: flat, count: 20)          // фаза 1 завершилась на 1.9 с
        var outcome: CalibrationOutcome = .calibratingForward(0)
        for i in 0..<300 {                                       // 30 с без жодного оновлення GPS
            outcome = cal.feedMotion(gravity: flat, userAcceleration: .zero, rotationRate: .zero,
                                     time: 2.0 + Double(i) * 0.1)
            if case .calibratingForward = outcome { continue }
            break
        }
        guard case .failed(let message) = outcome else {
            return XCTFail("без GPS очікувалась помилка за таймаутом, отримано \(outcome)")
        }
        XCTAssertTrue(message.contains("GPS"))
    }

    func testFullCalibrationWithGPS() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: true)
        guard case .calibratingForward = feedStill(cal, gravity: flat, count: 20) else {
            return XCTFail("з GPS після вертикалі має початись фаза напряму руху")
        }
        // Розгін 2 м/с² уздовж осі X телефона протягом 1 с
        _ = cal.feedLocation(speed: 10, speedAccuracy: 0.5, time: 2.0)
        for i in 0..<10 {
            _ = cal.feedMotion(gravity: flat, userAcceleration: Vector3(x: 2.0 / 9.81, y: 0, z: 0),
                               rotationRate: .zero, time: 2.0 + Double(i) * 0.1)
        }
        guard case .finished(let result)? = cal.feedLocation(speed: 12, speedAccuracy: 0.5, time: 3.0) else {
            return XCTFail("калібрування за GPS мало завершитись")
        }
        assertVector(result.forward, Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(result.forwardSource, .gps)
        XCTAssertEqual(result.forwardQuality, 1.0)
    }
}
