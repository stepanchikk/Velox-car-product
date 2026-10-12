import Foundation
import CoreLocation

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
}
