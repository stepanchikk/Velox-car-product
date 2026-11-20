import CarPlay
import MapKit
import Combine

/// Підготовча інтеграція. Не зареєстрована в scene manifest і не заявляє entitlement.
/// Перед випуском потрібні дозвіл Apple, підпис і повноцінна покрокова навігація.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayMapController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        let controller = CarPlayMapController()
        self.controller = controller
        window.rootViewController = controller
        let template = CPMapTemplate()
        let follow = CPMapButton { [weak controller] _ in controller?.followCar() }
        follow.image = UIImage(systemName: "location.fill")
        let zoomIn = CPMapButton { [weak controller] _ in controller?.zoom(by: 0.65) }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")
        let zoomOut = CPMapButton { [weak controller] _ in controller?.zoom(by: 1.5) }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")
        template.mapButtons = [follow, zoomIn, zoomOut]
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        controller?.stop()
        window.rootViewController = nil
        controller = nil
    }
}

/// Лише картографічна основа, без власних кнопок поверх базової карти CarPlay.
@MainActor
final class CarPlayMapController: UIViewController, MKMapViewDelegate {
    private let map = MKMapView()
    private var settingsObserver: AnyCancellable?

    override func loadView() { view = map }

    override func viewDidLoad() {
        super.viewDidLoad()
        map.delegate = self
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        applySettings()
        map.showsUserLocation = true
        followCar()
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
    }

    private func applySettings() {
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = UserDefaults.standard.object(forKey: AppSettings.showTrafficKey) as? Bool ?? true
        map.preferredConfiguration = config
    }

    func followCar() { map.setUserTrackingMode(.followWithHeading, animated: true) }

    func zoom(by factor: Double) {
        var region = map.region
        region.span.latitudeDelta = min(120, max(0.001, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = min(180, max(0.001, region.span.longitudeDelta * factor))
        map.setRegion(region, animated: true)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKUserLocation else { return nil }
        let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "velox-car")
        let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
        view.image = UIImage(systemName: "car.circle.fill", withConfiguration: configuration)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        view.canShowCallout = false
        return view
    }

    func stop() {
        settingsObserver = nil
        map.showsUserLocation = false
        map.delegate = nil
    }
}
