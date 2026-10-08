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

final class DistractionTrackerTests: XCTestCase {

    func testDurationPenaltyAndResume() throws {
        var tracker = DistractionTracker(policy: DistractionPolicy(gracePeriod: 3.0, cooldown: 1.5))
        XCTAssertEqual(tracker.begin(at: 2.0), .ignored)              // перші 3 с після старту
        XCTAssertNil(tracker.end(at: 2.5))                            // нічого не тривало

        XCTAssertEqual(tracker.begin(at: 10.0), .counted)
        XCTAssertEqual(tracker.begin(at: 10.2), .alreadyActive)
        let first = try XCTUnwrap(tracker.end(at: 10.4))
        XCTAssertEqual(first.duration, 0.4, accuracy: 1e-9)
        XCTAssertEqual(first.addedPenalty, 0)

        // Знову вийшов через 1 с після початку попереднього: те саме відволікання,
        // штраф за тривалість рахується за сумарні 19.4 с
        XCTAssertEqual(tracker.begin(at: 11.0), .resumed)
        XCTAssertEqual(tracker.end(at: 30.0)?.addedPenalty, 1)

        // Нове відволікання на хвилину: штраф за тривалість не більше 5
        XCTAssertEqual(tracker.begin(at: 40.0), .counted)
        XCTAssertEqual(tracker.end(at: 100.0)?.addedPenalty, 5)

        XCTAssertEqual(tracker.durationPenalty, 6)
        XCTAssertEqual(tracker.totalDuration, 79.4, accuracy: 1e-9)
        XCTAssertFalse(tracker.isActive)

        tracker.reset()
        XCTAssertEqual(tracker.durationPenalty, 0)
        XCTAssertEqual(tracker.totalDuration, 0)
    }

    func testDurationPenaltySteps() {
        XCTAssertEqual(SafetyScoreCalculator.durationPenalty(for: 0), 0)
        XCTAssertEqual(SafetyScoreCalculator.durationPenalty(for: 9.9), 0)
        XCTAssertEqual(SafetyScoreCalculator.durationPenalty(for: 10), 1)
        XCTAssertEqual(SafetyScoreCalculator.durationPenalty(for: 25), 2)
        XCTAssertEqual(SafetyScoreCalculator.durationPenalty(for: 300), 5)   // обмеження
    }

    func testCallPolicy() {
        // Без дзвінка вихід із застосунку - відволікання
        XCTAssertEqual(CallPolicy.cause(for: .none, callWasActive: false), .distraction)
        // Екран вхідного дзвінка відкрила система
        XCTAssertEqual(CallPolicy.cause(for: .incomingRinging, callWasActive: false), .incomingCall)
        // Розмова почалась через гарнітуру чи CarPlay
        XCTAssertEqual(CallPolicy.cause(for: .active(handheld: false), callWasActive: false), .handsFreeCall)
        // Телефон біля вуха
        XCTAssertEqual(CallPolicy.cause(for: .active(handheld: true), callWasActive: false), .distraction)
        // Розмова вже йшла, а водій відкрив інший застосунок
        XCTAssertEqual(CallPolicy.cause(for: .active(handheld: false), callWasActive: true), .distraction)
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
        // 1 маневр, 1 відволікання на 25 с: 100 - 2 - 5 - 2
        XCTAssertEqual(SafetyScoreCalculator.score(maneuvers: 1, distractions: 1, durationPenalty: 2), 91)
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

    private func row(time: Double, state: String = "Запис іде", event: String = "",
                     coordinate: RoutePoint? = nil) -> TelemetryRow {
        TelemetryRow(time: time, filtered: 0.1, state: state, event: event, raw: 0.2,
                     userAcceleration: Vector3(x: 0.01, y: 0.02, z: 0.03),
                     rotationRate: Vector3(x: 0.1, y: 0.2, z: 0.3),
                     tiltDegrees: 1.5, score: 98, speed: 12.5, coordinate: coordinate)
    }

    private func documentsURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    func testRowHasSameColumnCountAsHeaderAndNoExtraCommas() {
        let header = TripCSVWriter.header.split(separator: ",", omittingEmptySubsequences: false)
        let line = row(time: 1, state: "Запис, іде").csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(header.count, 16)
        XCTAssertEqual(line.count, header.count)
        XCTAssertEqual(String(line[2]), "Запис іде")   // кома зі стану прибрана
        // Гіроскоп - після прискорень, у колонках Gx, Gy, Gz
        XCTAssertEqual(header[8...10].map(String.init), ["Gx", "Gy", "Gz"])
        XCTAssertEqual(line[8...10].map(String.init), ["0.1", "0.2", "0.3"])
    }

    func testMissingSpeedAndRouteLeaveEmptyColumns() {
        let r = TelemetryRow(time: 1, filtered: 0, state: "Запис іде", event: "", raw: 0,
                             userAcceleration: .zero, rotationRate: .zero, tiltDegrees: 0,
                             score: 100, speed: nil, coordinate: nil)
        let fields = r.csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 16)
        XCTAssertEqual(fields[13...15].map(String.init), ["", "", ""])   // Speed_mps, Lat, Lon
    }

    func testCoordinatesGoToLatLon() {
        let line = row(time: 1, coordinate: RoutePoint(latitude: 48.29, longitude: 25.94)).csvLine
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[14...15].map(String.init), ["48.29", "25.94"])
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
        XCTAssertEqual(writer.finish(), .saved(fileName: name, warning: nil))
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
        XCTAssertEqual(writer.finish(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(writer.finish(), .notCreated)               // повторний виклик нічого не ламає
    }

    // Параметри запису стоять перед заголовком, і парсер історії їх читає
    func testMetadataIsWrittenBeforeHeaderAndParsedBack() throws {
        let name = "VeloxTest_\(UUID().uuidString).csv"
        let url = documentsURL(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = TripMetadata.recording(startedAt: Date())
        let writer = TripCSVWriter()
        XCTAssertNil(writer.open(fileName: name, metadata: metadata))
        XCTAssertNil(writer.append(row(time: 0.1), isSample: true))
        _ = writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(String(lines[0]), "# format=\(TripMetadata.formatVersion)")
        XCTAssertEqual(String(lines[metadata.entries.count]), TripCSVWriter.header)

        let stats = try XCTUnwrap(TripCSVParser.parse(text))
        XCTAssertEqual(stats.samples, 1)
        XCTAssertEqual(stats.skippedLines, 0)
        let parsed = try XCTUnwrap(stats.metadata)
        XCTAssertEqual(parsed, metadata)
        XCTAssertEqual(parsed.double("maneuverThreshold"), VeloxConfig.maneuverThreshold)
        XCTAssertEqual(parsed["maneuverPenalty"], "\(VeloxConfig.maneuverPenalty)")
        XCTAssertTrue(parsed.changedParameters.isEmpty)
    }
}

// MARK: - Параметри запису

final class TripMetadataTests: XCTestCase {

    func testLineParsing() {
        XCTAssertEqual(TripMetadata.parseLine("# maneuverThreshold=0.4"),
                       TripMetadata.Entry(key: "maneuverThreshold", value: "0.4"))
        XCTAssertEqual(TripMetadata.parseLine("#app = 1.0 (5)"),
                       TripMetadata.Entry(key: "app", value: "1.0 (5)"))
        XCTAssertNil(TripMetadata.parseLine("# просто коментар"))
        XCTAssertNil(TripMetadata.parseLine("# =0.4"))
        XCTAssertNil(TripMetadata.parseLine("Timestamp,Filtered_Y"))
    }

    func testSetReplacesAndCleansValue() {
        var metadata = TripMetadata()
        metadata.set("app", "1.0")
        metadata.set("app", "2.0,\nbeta")
        XCTAssertEqual(metadata.entries.count, 1)
        XCTAssertEqual(metadata["app"], "2.0  beta")       // кома і перенос рядка прибрані
        XCTAssertEqual(metadata.lines, ["# app=2.0  beta"])
    }

    func testNumberFormatting() {
        XCTAssertEqual(TripMetadata.format(2), "2")
        XCTAssertEqual(TripMetadata.format(3.0), "3")
        XCTAssertEqual(TripMetadata.format(0.4), "0.4")
        XCTAssertEqual(TripMetadata.format(0.1), "0.1")
    }

    func testChangedParameters() {
        var metadata = TripMetadata.recording(startedAt: Date())
        XCTAssertTrue(metadata.changedParameters.isEmpty)
        metadata.set("maneuverThreshold", "0.35")
        XCTAssertEqual(metadata.changedParameters, ["maneuverThreshold"])
    }

    func testOldFileHasNoMetadata() throws {
        let stats = try XCTUnwrap(TripCSVParser.parse("Timestamp,Filtered_Y,State\n0.1,0,Запис іде\n"))
        XCTAssertNil(stats.metadata)
    }

    func testFileWithOnlyMetadataIsNotATrip() {
        XCTAssertNil(TripCSVParser.parse("# format=2\n# app=1.0\n"))
    }

    // Тривалість відволікань і службові рядки дзвінків
    func testDistractionDurationAndCallRows() throws {
        let csv = """
        Timestamp,Filtered_Y,State,Event,Raw_Y,Ax,Ay,Az,Tilt_deg,Score,Speed_mps
        0.0,0,Калібрування...,CalibrationStart,0,0,0,0,0,100,
        2.0,0,Запис іде,CalibrationDone,0,0,0,0,0,100,
        2.1,0,Запис іде,,0,0,0,0,0,100,
        10.0,0,Відволікання!,Distraction,0,0,0,0,0,95,
        10.4,0,Відволікання!,DistractionEnd,0,0,0,0,0,95,
        11.0,0,Відволікання!,DistractionResume,0,0,0,0,0,95,
        30.0,0,Відволікання!,DistractionEnd,0,0,0,0,0,94,
        31.0,0,Запис іде,,0,0,0,0,0,94,
        40.0,0,Дзвінок,CallIncoming,0,0,0,0,0,94,
        50.0,0,Дзвінок,CallStart,0,0,0,0,0,94,
        60.0,0,Дзвінок,CallEnd,0,0,0,0,0,94,
        61.0,0,Запис іде,,0,0,0,0,0,94,
        """
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertEqual(stats.samples, 3)                     // службові рядки не рахуються
        XCTAssertEqual(stats.distractions, 1)                // продовження - не нове відволікання
        XCTAssertEqual(try XCTUnwrap(stats.distractionSeconds), 19.4, accuracy: 1e-9)
        XCTAssertEqual(stats.score, 94)
    }

    // Маршрут: однакові точки підряд прибираються, події стають на останню відому точку
    func testRouteParsing() throws {
        let csv = """
        # format=3
        # route=on
        Timestamp,Filtered_Y,Event,Speed_mps,Lat,Lon
        0.1,0,,,,
        0.2,0,,10,48.1,25.1
        0.3,0,,10,48.1,25.1
        0.4,-0.5,HardBraking,10,,
        1.2,0,,9,48.2,25.2
        1.3,0,Distraction,9,48.2,25.2
        2.2,0,,9,48.3,25.3
        """
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertTrue(stats.hasRoute)
        let route = try XCTUnwrap(TripRoute.parse(csv))
        XCTAssertEqual(route.points, [RoutePoint(latitude: 48.1, longitude: 25.1),
                                      RoutePoint(latitude: 48.2, longitude: 25.2),
                                      RoutePoint(latitude: 48.3, longitude: 25.3)])
        XCTAssertEqual(route.events.map(\.kind), [.hardBraking, .distraction])
        XCTAssertEqual(route.events[0].point, RoutePoint(latitude: 48.1, longitude: 25.1))
    }

    func testNoRouteWithoutCoordinates() throws {
        let csv = "Timestamp,Filtered_Y,Event,Lat,Lon\n0.1,0,,,\n0.2,0,,,\n"
        XCTAssertFalse(try XCTUnwrap(TripCSVParser.parse(csv)).hasRoute)
        XCTAssertNil(TripRoute.parse(csv))
    }

    func testRouteThinningKeepsEnds() {
        let points = (0..<5_000).map { RoutePoint(latitude: Double($0), longitude: 0) }
        let thinned = TripRoute.thin(points)
        XCTAssertEqual(thinned.count, TripRoute.maxPoints)
        XCTAssertEqual(thinned.first, points.first)
        XCTAssertEqual(thinned.last, points.last)
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

// MARK: - Напрям руху без GPS (за поворотами)

final class YawForwardEstimatorTests: XCTestCase {

    // Повороти на швидкості 10 м/с: доцентрове прискорення v * omega уздовж
    // up x forward, плюс гальмування перед кожним поворотом (заважає оцінці)
    private func drive(_ estimator: YawForwardEstimator, up: Vector3, forward: Vector3,
                       turns: [Double], speed: Double = 10) {
        let side = up.cross(forward)
        for omega in turns {
            for _ in 0..<20 {   // гальмування 0.15 G перед поворотом, без повороту
                estimator.addSample(userAcceleration: forward * -0.15, rotationRate: .zero)
            }
            for _ in 0..<40 {   // 4 с повороту з легким гальмуванням
                let acceleration = side * (speed * omega / 9.81) + forward * -0.05
                estimator.addSample(userAcceleration: acceleration, rotationRate: up * omega)
            }
        }
    }

    func testFindsForwardFromLeftAndRightTurns() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 1, y: 0, z: 0)          // телефон лежить боком (як у реальній поїздці)
        let estimator = YawForwardEstimator(up: up)
        // Ліві й праві повороти попарно однакові: гальмування в них взаємно гаситься
        drive(estimator, up: up, forward: forward, turns: [0.2, -0.2, 0.25, -0.25])
        assertVector(estimator.estimate, forward, accuracy: 1e-6)
        XCTAssertEqual(estimator.consistency, 1, accuracy: 0.05)
    }

    // Нерівні повороти: гальмування гаситься не повністю, похибка кілька градусів
    func testUnequalTurnsGiveSmallError() throws {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 1, y: 0, z: 0)
        let estimator = YawForwardEstimator(up: up)
        drive(estimator, up: up, forward: forward, turns: [0.2, -0.25])
        let estimate = try XCTUnwrap(estimator.estimate)
        XCTAssertLessThan(OrientationCalibrator.angleDegrees(estimate, forward), 3)
    }

    func testArbitraryOrientation() {
        let up = Vector3(x: 0.3, y: -0.5, z: 0.81).normalized()!
        let forward = up.cross(Vector3(x: 1, y: 0, z: 0)).normalized()!
        let estimator = YawForwardEstimator(up: up)
        drive(estimator, up: up, forward: forward, turns: [-0.2, 0.2, 0.3, -0.3])
        assertVector(estimator.estimate, forward, accuracy: 1e-6)
    }

    // Розворот заднім ходом на малій швидкості не перекидає оцінку
    // (похибка близько 12 градусів, далі зменшується з кожним поворотом)
    func testSlowReverseDoesNotFlipDirection() throws {
        let up = Vector3(x: 0, y: 0, z: 1)
        let forward = Vector3(x: 0, y: 1, z: 0)
        let estimator = YawForwardEstimator(up: up)
        drive(estimator, up: up, forward: forward, turns: [0.3], speed: -1.5)
        drive(estimator, up: up, forward: forward, turns: [0.2, -0.2])
        let estimate = try XCTUnwrap(estimator.estimate)
        XCTAssertLessThan(OrientationCalibrator.angleDegrees(estimate, forward), 15)
    }

    func testNoTurnsNoEstimate() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let estimator = YawForwardEstimator(up: up)
        for i in 0..<600 {   // хвилина прямої їзди з розгонами й гальмуваннями
            let a = Vector3(x: 0, y: 0.2 * sin(Double(i) * 0.05), z: 0)
            estimator.addSample(userAcceleration: a, rotationRate: Vector3(x: 0, y: 0, z: 0.01))
        }
        XCTAssertNil(estimator.estimate)
        XCTAssertEqual(estimator.energy, 0)
    }

    // Обертання без відповідного бокового прискорення (телефон крутять у руках
    // на стоянці) дає неузгоджений сигнал, і рішення не приймається
    func testInconsistentSignalGivesNoEstimate() {
        let up = Vector3(x: 0, y: 0, z: 1)
        let estimator = YawForwardEstimator(up: up)
        for i in 0..<200 {
            let omega = i % 2 == 0 ? 0.3 : -0.3
            let a = i % 4 < 2 ? Vector3(x: 0.1, y: 0, z: 0) : Vector3(x: -0.1, y: 0, z: 0)
            estimator.addSample(userAcceleration: a, rotationRate: up * omega)
        }
        XCTAssertGreaterThan(estimator.energy, YawForwardEstimator.requiredEnergy)
        XCTAssertNil(estimator.estimate)
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

    // Перекалібрування в русі: вібрація 0.1 G не зриває фазу вертикалі
    func testRecalibrationInMotionToleratesVibration() {
        let shake = Vector3(x: 0.06, y: 0.05, z: 0.06)    // ~0.1 G
        let feed = { (cal: OrientationCalibrator) -> CalibrationOutcome in
            var outcome: CalibrationOutcome = .calibratingUp(0)
            for i in 0..<20 {
                outcome = cal.feedMotion(gravity: self.flat, userAcceleration: shake,
                                         rotationRate: Vector3(x: 0, y: 0, z: 0.15), time: Double(i) * 0.1)
            }
            return outcome
        }

        let strict = OrientationCalibrator()
        strict.reset(locationAvailable: false)
        guard case .calibratingUp = feed(strict) else {
            return XCTFail("на старті вібрація має перезапускати відлік спокою")
        }

        let relaxed = OrientationCalibrator()
        relaxed.reset(locationAvailable: false, inMotion: true)
        guard case .finished(let result) = feed(relaxed) else {
            return XCTFail("у русі 2 с без обертання телефона достатньо")
        }
        assertVector(result.up, Vector3(x: 0, y: 0, z: 1))
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

    // Телефон стоїть у тримачі екраном до водія: без GPS вперед - задня кришка (-Z)
    func testVerticalPhoneWithoutLocationUsesBackOfPhone() {
        let cal = OrientationCalibrator()
        cal.reset(locationAvailable: false)
        let outcome = feedStill(cal, gravity: Vector3(x: 0, y: -1, z: 0), count: 20)
        guard case .finished(let result) = outcome else {
            return XCTFail("очікувалось завершення, отримано \(outcome)")
        }
        assertVector(result.forward, Vector3(x: 0, y: 0, z: -1))
        XCTAssertEqual(result.forwardSource, .fallbackFlatMount)
    }

    // Хоча б одна з осей (+Y чи -Z) завжди дає горизонтальний напрям
    func testFallbackForwardExistsForAnyOrientation() {
        for i in 0..<200 {
            let a = Double(i) * 0.37, b = Double(i) * 0.91
            let up = Vector3(x: cos(a) * sin(b), y: sin(a) * sin(b), z: cos(b))
            guard let forward = OrientationCalibrator.fallbackForward(up: up) else {
                return XCTFail("немає напряму для up = \(up)")
            }
            XCTAssertEqual(forward.dot(up), 0, accuracy: 1e-9)       // горизонтальний
            XCTAssertEqual(forward.length, 1, accuracy: 1e-9)
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

// MARK: - Історія поїздок

final class TripCSVParserTests: XCTestCase {

    // Поточний формат: калібрування, маневри, відволікання, швидкість і обірваний останній рядок
    func testCurrentFormat() throws {
        let csv = """
        Timestamp,Filtered_Y,State,Event,Raw_Y,Ax,Ay,Az,Tilt_deg,Score,Speed_mps
        0.0,0,Калібрування...,CalibrationStart,0,0,0,0,0,100,
        2.0,0,Запис іде,CalibrationDone,0,0,0,0,0,100,10
        2.1,0.1,Запис іде,,0,0,0,0,0,100,10
        3.1,0.5,Запис іде,HardAcceleration,0,0,0,0,0,98,12
        4.1,0.1,Запис іде,,0,0,0,0,0,98,12
        4.2,0.1,Відволікання!,Distraction,0,0,0,0,0,93,12
        5.1,-0.5,Запис іде,HardBraking,0,0,0,0,0,91,8
        5.2,0.1,Запис
        """
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertEqual(stats.samples, 4)                 // службові рядки не рахуються
        XCTAssertEqual(stats.duration, 5.1, accuracy: 1e-9)
        XCTAssertEqual(stats.hardBrakings, 1)
        XCTAssertEqual(stats.hardAccelerations, 1)
        XCTAssertEqual(stats.distractions, 1)
        XCTAssertEqual(stats.maneuvers, 2)
        XCTAssertEqual(stats.score, 91)                  // останнє значення колонки Score
        XCTAssertEqual(stats.calibration, .gps)
        XCTAssertEqual(stats.skippedLines, 1)            // обірваний рядок
        // Трапеції по вимірах: (10+12)/2*1 + 12*1 + (12+8)/2*1 = 33 м
        XCTAssertEqual(try XCTUnwrap(stats.distanceMeters), 33, accuracy: 1e-9)
    }

    // Файл без колонки Score: оцінка рахується за подіями
    func testScoreComputedWhenColumnMissing() throws {
        let csv = """
        Timestamp,Filtered_Y,State,Event
        0.1,0,Запис іде,
        0.2,0.5,Запис іде,HardAcceleration
        0.3,0,Відволікання!,Distraction
        """
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertEqual(stats.score, 93)                  // 100 - 2 - 5
        XCTAssertNil(stats.distanceMeters)
        XCTAssertEqual(stats.calibration, .unknown)
    }

    // Найстаріший формат без Event: події невідомі, а не нульові
    func testOldestFormat() throws {
        let csv = "Timestamp,Filtered_Y,State\n0.0,0.0,Запис іде\n0.1,0.01,Запис іде\n"
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertEqual(stats.samples, 2)
        XCTAssertNil(stats.hardBrakings)
        XCTAssertNil(stats.maneuvers)
        XCTAssertNil(stats.score)
    }

    func testFallbackCalibrationAndCRLF() throws {
        let csv = "Timestamp,Filtered_Y,State,Event\r\n0.0,0,Калібрування...,CalibrationStart\r\n2.0,0,Запис іде,CalibrationDoneFallback\r\n2.1,0,Запис іде,\r\n"
        let stats = try XCTUnwrap(TripCSVParser.parse(csv))
        XCTAssertEqual(stats.calibration, .fallback)
        XCTAssertEqual(stats.samples, 1)
        XCTAssertEqual(stats.skippedLines, 0)
    }

    func testNotATripFile() {
        XCTAssertNil(TripCSVParser.parse("a,b\n1,2\n"))
        XCTAssertNil(TripCSVParser.parse(""))
    }

    func testDateFromFileName() throws {
        let date = try XCTUnwrap(TripLibrary.date(fromFileName: "Velox_Data_2026-09-29_09-49-45.csv"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 9, 29, 9, 49, 45])
        XCTAssertNil(TripLibrary.date(fromFileName: "notes.csv"))
    }

    func testFormatting() {
        XCTAssertEqual(TripFormat.duration(915.1), "15 хв 15 с")
        XCTAssertEqual(TripFormat.duration(45), "45 с")
        XCTAssertEqual(TripFormat.duration(3725), "1 год 2 хв")
        XCTAssertEqual(TripFormat.distance(850), "850 м")
        XCTAssertEqual(TripFormat.distance(12345), "12.3 км")
    }
}

// MARK: - Профіль: перевірка даних і пароль

final class CredentialsTests: XCTestCase {

    func testEmailValidation() {
        XCTAssertTrue(CredentialsValidator.isValidEmail("driver@mail.com"))
        XCTAssertTrue(CredentialsValidator.isValidEmail("s.shudrovskyi+velox@chnu.edu.ua"))
        XCTAssertFalse(CredentialsValidator.isValidEmail("driver@mail"))
        XCTAssertFalse(CredentialsValidator.isValidEmail("driver mail.com"))
        XCTAssertFalse(CredentialsValidator.isValidEmail(""))
        XCTAssertEqual(CredentialsValidator.normalizedEmail("  Driver@Mail.COM "), "driver@mail.com")
    }

    func testPasswordRequirements() {
        XCTAssertFalse(CredentialsValidator.isStrongPassword("Sh0rt!"))
        XCTAssertFalse(CredentialsValidator.isStrongPassword("alllowercase1!"))
        XCTAssertFalse(CredentialsValidator.isStrongPassword("NoDigitsHere!"))
        XCTAssertFalse(CredentialsValidator.isStrongPassword("NoSpecial123"))
        XCTAssertTrue(CredentialsValidator.isStrongPassword("Velox2026!"))
        let unmet = CredentialsValidator.passwordRequirements("abc").filter { !$0.met }
        XCTAssertEqual(unmet.count, 4)
    }

    func testPasswordHashing() {
        let credential = PasswordHasher.makeCredential("Velox2026!")
        XCTAssertEqual(credential.count, PasswordHasher.saltLength + PasswordHasher.hashLength)
        XCTAssertTrue(PasswordHasher.verify("Velox2026!", credential: credential))
        XCTAssertFalse(PasswordHasher.verify("velox2026!", credential: credential))
        XCTAssertFalse(PasswordHasher.verify("", credential: credential))
        // Однаковий пароль із різною сіллю дає різні записи
        XCTAssertNotEqual(credential, PasswordHasher.makeCredential("Velox2026!"))
        // Пароль не міститься в записі у відкритому вигляді
        XCTAssertNil(credential.range(of: Data("Velox2026!".utf8)))
    }

    func testHashIsDeterministicForSameSalt() {
        let salt = Data(repeating: 7, count: PasswordHasher.saltLength)
        let a = PasswordHasher.hash("Velox2026!", salt: salt, rounds: 1_000)
        let b = PasswordHasher.hash("Velox2026!", salt: salt, rounds: 1_000)
        XCTAssertEqual(a.count, PasswordHasher.hashLength)
        XCTAssertEqual(a, b)
        XCTAssertTrue(PasswordHasher.hash("", salt: salt).isEmpty)
    }
}

// MARK: - Статистика і досягнення

final class GamificationTests: XCTestCase {

    private func trip(day: Int, score: Int?, duration: TimeInterval = 600,
                      distance: Double? = 5_000, distractions: Int? = 0) -> TripSummary {
        var stats = TripStats()
        stats.duration = duration
        stats.score = score
        stats.distanceMeters = distance
        stats.distractions = distractions
        stats.hardBrakings = 0
        stats.hardAccelerations = 0
        return TripSummary(fileName: "Velox_Data_\(day).csv",
                           url: URL(fileURLWithPath: "/tmp/velox-\(day).csv"),
                           date: Date(timeIntervalSince1970: Double(day) * 86_400),
                           fileSize: nil,
                           stats: stats)
    }

    func testStatsUseTenNewestTrips() {
        // День 1 - найстаріша поїздка з оцінкою 0, далі 11 поїздок по 90
        var trips = [trip(day: 1, score: 0)]
        trips += (2...12).map { trip(day: $0, score: 90) }
        let stats = DrivingStats(trips: trips.shuffled())
        XCTAssertEqual(stats.tripCount, 12)
        XCTAssertEqual(stats.recentScoreCount, 10)
        XCTAssertEqual(stats.averageRecentScore, 90)          // стара поїздка не враховується
        XCTAssertEqual(stats.recentScores.count, 10)
        XCTAssertEqual(stats.totalDistanceMeters, 60_000, accuracy: 1e-9)
    }

    func testRecentScoresGoFromOldToNew() {
        let stats = DrivingStats(trips: [trip(day: 3, score: 70), trip(day: 1, score: 100), trip(day: 2, score: 85)])
        XCTAssertEqual(stats.recentScores, [100, 85, 70])
        XCTAssertEqual(stats.averageRecentScore, 85)
    }

    func testEmptyHistory() {
        let stats = DrivingStats(trips: [])
        XCTAssertNil(stats.averageRecentScore)
        XCTAssertTrue(AchievementCatalog.evaluate([]).allSatisfy { !$0.isUnlocked })
    }

    func testAchievements() {
        let unlocked = { (trips: [TripSummary]) in
            Set(AchievementCatalog.evaluate(trips).filter(\.isUnlocked).map(\.id))
        }
        // 10 хвилин, оцінка 100, без відволікань
        XCTAssertEqual(unlocked([trip(day: 1, score: 100)]), ["first", "perfect", "focused"])
        // Хвилинний заїзд не дає "ідеальних" досягнень
        XCTAssertEqual(unlocked([trip(day: 1, score: 100, duration: 60)]), ["first"])
        // Відволікання забирає "Телефон відкладено"
        XCTAssertFalse(unlocked([trip(day: 1, score: 95, distractions: 1)]).contains("focused"))
        // 10 поїздок по 10 км з оцінкою 92
        let many = (1...10).map { trip(day: $0, score: 92, distance: 10_000) }
        XCTAssertTrue(unlocked(many).isSuperset(of: ["ten", "smooth", "hundred"]))
    }

    func testAchievementProgress() {
        let smooth = AchievementCatalog.evaluate((1...2).map { trip(day: $0, score: 95) })
            .first { $0.id == "smooth" }
        XCTAssertEqual(smooth?.progress ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(smooth?.progressText, "2 з 5")
    }

    // Оцінка водія: штрафи на 10 км, а не на поїздку
    func testDriverRatingNormalizesByDistance() {
        // 10 км з оцінкою 90 і 30 км з оцінкою 94: штрафи 16 на 40 км = 4 на 10 км
        let stats = DrivingStats(trips: [trip(day: 1, score: 90, distance: 10_000),
                                         trip(day: 2, score: 94, distance: 30_000)])
        XCTAssertEqual(stats.driverRating, 96)
        XCTAssertEqual(stats.averageRecentScore, 92)
    }

    func testLongTripIsNotPunishedForLength() {
        // Коротка поїздка з одним відволіканням (95) і довга з трьома (85):
        // за середнім оцінки довга гірша, а на кілометр - безпечніша
        let short = DrivingStats(trips: [trip(day: 1, score: 95, distance: 5_000)])
        let long = DrivingStats(trips: [trip(day: 1, score: 85, distance: 50_000)])
        XCTAssertEqual(short.driverRating, 95)      // пробіг менше 10 км рахується як 10 км
        XCTAssertEqual(long.driverRating, 97)       // 15 штрафу на 50 км = 3 на 10 км
    }

    func testDriverRatingWithoutGPSUsesDuration() {
        // Без GPS 30 хвилин дорівнюють 15 км (30 км/год): 15 штрафу на 15 км
        let stats = DrivingStats(trips: [trip(day: 1, score: 85, duration: 1_800, distance: nil)])
        XCTAssertEqual(stats.driverRating, 90)
        XCTAssertNil(DrivingStats(trips: []).driverRating)
    }

    func testTipIsStableDuringDay() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let morning = day.addingTimeInterval(8 * 3_600)
        let evening = day.addingTimeInterval(20 * 3_600)
        XCTAssertEqual(DrivingTips.tip(for: morning), DrivingTips.tip(for: evening))
        XCTAssertFalse(DrivingTips.tip(for: morning).isEmpty)
    }
}
