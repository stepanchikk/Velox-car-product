import Foundation
import Combine

/// Об'єкти OSM поруч із GPS-позицією. Не означають, що знак стосується нашої смуги.
nonisolated struct RoadFeature: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case signal, stop, giveWay, speedLimit }
    let id: Int64
    let point: RoutePoint
    let kind: Kind
    let speedLabel: String?

    var title: String {
        switch kind {
        case .signal: "Світлофор"
        case .stop: "STOP"
        case .giveWay: "Дати дорогу"
        case .speedLimit: "Обмеження: \(speedLabel ?? "?")"
        }
    }
    var symbol: String {
        switch kind {
        case .signal: "trafficlight"
        case .stop: "stop.fill"
        case .giveWay: "triangle"
        case .speedLimit: "speedometer"
        }
    }
}

nonisolated enum RoadFeatureParser {
    private struct Response: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
    }

    static func parse(_ data: Data) throws -> [RoadFeature] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<Int64>()
        return response.elements.compactMap { element in
            guard element.type == "node", let lat = element.lat, let lon = element.lon,
                  lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon),
                  let tags = element.tags, seen.insert(element.id).inserted else { return nil }
            let kind: RoadFeature.Kind
            switch tags["highway"] {
            case "traffic_signals": kind = .signal
            case "stop": kind = .stop
            case "give_way": kind = .giveWay
            default:
                guard tags["traffic_sign"] == "maxspeed", tags["maxspeed"] != nil else { return nil }
                kind = .speedLimit
            }
            return RoadFeature(id: element.id, point: RoutePoint(latitude: lat, longitude: lon),
                               kind: kind, speedLabel: tags["maxspeed"].map { String($0.prefix(16)) })
        }
    }
}

nonisolated enum RoadFeaturePolicy {
    static func isValid(_ point: RoutePoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
    }

    static let radius = 1_500.0
    static let refreshDistance = 600.0
    static let minimumInterval: TimeInterval = 60
    static let maximumAge: TimeInterval = 15 * 60

    static func shouldRefresh(center: RoutePoint?, lastAttempt: Date?, near point: RoutePoint, now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        guard let center, let lastAttempt else { return true }
        return center.distance(to: point) >= refreshDistance || now.timeIntervalSince(lastAttempt) >= maximumAge
    }

    static func query(near point: RoutePoint) -> String {
        // Числа не залежать від локалі; лише невеликий радіус, без історії маршруту.
        let around = "around:1500,\(point.latitude),\(point.longitude)"
        return "[out:json][timeout:12];(node(\(around))[highway~\"^(traffic_signals|stop|give_way)$\"];node(\(around))[traffic_sign=\"maxspeed\"];);out body 300;"
    }
}

@MainActor
final class RoadFeatureStore: ObservableObject {
    @Published private(set) var features: [RoadFeature] = []
    @Published private(set) var status = "Об’єкти OSM вимкнено"
    private var center: RoutePoint?
    private var lastAttempt: Date?
    private var fetchedAt: Date?
    private var generation = 0
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func clear() {
        generation += 1
        features = []
        center = nil
        lastAttempt = nil
        fetchedAt = nil
        status = "Об’єкти OSM вимкнено"
    }

    func waitingForLocation() {
        generation += 1
        features = []
        center = nil
        status = "OSM: очікування свіжої GPS-позиції"
    }

    func refresh(near point: RoutePoint, now: Date = Date()) async {
        guard RoadFeaturePolicy.isValid(point) else { return }
        // Старий район/старі об'єкти не зберігаємо як поточні після втрати мережі.
        if center.map({ $0.distance(to: point) > RoadFeaturePolicy.radius }) == true
            || fetchedAt.map({ now.timeIntervalSince($0) >= RoadFeaturePolicy.maximumAge }) == true {
            features = []
        }
        guard RoadFeaturePolicy.shouldRefresh(center: center, lastAttempt: lastAttempt, near: point, now: now) else { return }
        lastAttempt = now
        let requestGeneration = generation
        status = "Завантаження об’єктів OSM…"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("VeloxCoursework/1.0", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: RoadFeaturePolicy.query(near: point))]
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
            let parsed = try RoadFeatureParser.parse(data)
            features = parsed.filter { point.distance(to: $0.point) <= RoadFeaturePolicy.radius }
            center = point
            fetchedAt = now
            status = features.isEmpty ? "OSM: поблизу немає нанесених об’єктів" : "OSM: \(features.count) об’єктів поблизу"
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            // На невдачі дозволяємо повтор через хвилину, навіть у тому самому районі.
            center = nil
            features = []
            status = "Об’єкти OSM недоступні — перевірте мережу"
        }
    }
}
