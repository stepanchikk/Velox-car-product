import Foundation
import CoreLocation
import LocalAuthentication

// Геолокація: доступ, оновлення позиції і швидкості, енергоспоживання GPS
extension SensorManager {

    func currentLocationAccess() -> LocationAccess {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways:
            // Приблизне місцезнаходження не дає швидкості, потрібної калібруванню
            return locationManager.accuracyAuthorization == .fullAccuracy ? .authorized : .reducedAccuracy
        default:
            return .denied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = currentLocationAccess()
        // Користувач відповів на системний запит: стартуємо (з GPS або без)
        if startAfterAuthorization, locationStatus != .notDetermined {
            startAfterAuthorization = false
            startRecording()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, isRecording else { return }

        // Перше оновлення може бути старою закешованою позицією: пропускаємо її
        let time = sessionTime(of: location)
        guard time > -1.0 else { return }

        let speed = location.speed
        // speed < 0 означає, що iOS не змогла визначити швидкість
        if speed >= 0 {
            lastKnownSpeed = speed
            lastSpeedTime = time
        }
        // Координати з поганою точністю (вулиця між висотками) не пишемо і не малюємо
        if location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= VeloxConfig.routeMaxHorizontalAccuracy {
            let point = RoutePoint(latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude)
            liveRoute.add(point, at: time)
            if recordRoute {
                lastCoordinate = point
                lastCoordinateTime = time
            }
        }

        guard isCalibrating else { return }
        if let outcome = calibrator.feedLocation(speed: speed, speedAccuracy: location.speedAccuracy, time: time) {
            apply(outcome)
        }
    }

    // Момент визначення координат GPS
    private func sessionTime(of location: CLLocation) -> TimeInterval {
        location.timestamp.timeIntervalSince(startTime)
    }

    // MARK: - Енергоспоживання GPS

    // Режим BestForNavigation (максимальна точність і злиття з іншими сенсорами)
    // потрібен лише для калібрування напряму руху. Під час запису швидкість
    // потрібна для колонки Speed_mps і блокування ручного перекалібрування в русі;
    // для цього вистачає NearestTenMeters, що витрачає помітно менше енергії.
    func setLocationPrecision(forCalibration: Bool) {
        locationManager.desiredAccuracy = forCalibration
            ? kCLLocationAccuracyBestForNavigation
            : kCLLocationAccuracyNearestTenMeters
    }

    // Швидкість для CSV: nil, якщо GPS давно мовчить (порожнє значення в колонці
    // краще за застаріле: analyzer.py пропускає порожні значення)
    var freshSpeed: Double? {
        sessionTime() - lastSpeedTime <= Self.speedMaxAge ? lastKnownSpeed : nil
    }

    // Те саме для координат маршруту
    var freshCoordinate: RoutePoint? {
        guard recordRoute, sessionTime() - lastCoordinateTime <= Self.speedMaxAge else { return nil }
        return lastCoordinate
    }

    // MARK: - Запис у фоні

    /// iOS дозволяє застосунку працювати у фоні, поки він отримує геолокацію
    /// (так працюють навігатори). Для цього в проєкті потрібна можливість
    /// Background Modes → Location updates, на телефоні - код-пароль (без нього
    /// не приходять сповіщення про блокування) і точна геолокація.
    var backgroundRecordingAvailability: BackgroundRecordingAvailability {
        guard Self.hasLocationBackgroundMode else { return .noBackgroundMode }
        guard locationAuthorized else { return .noLocation }
        guard Self.deviceHasPasscode else { return .noPasscode }
        return .available
    }

    static var hasLocationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }

    static var deviceHasPasscode: Bool {
        // .deviceOwnerAuthentication можливе з будь-яким захистом: код, Face ID чи Touch ID
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func setBackgroundLocation(enabled: Bool) {
        // Без Background Modes → Location updates iOS аварійно завершує застосунок
        // на цьому рядку, тому спершу перевіряємо налаштування проєкту
        guard Self.hasLocationBackgroundMode else { return }
        locationManager.allowsBackgroundLocationUpdates = enabled
        // Синя позначка в рядку стану: водій бачить, що запис триває
        locationManager.showsBackgroundLocationIndicator = enabled
    }
}
