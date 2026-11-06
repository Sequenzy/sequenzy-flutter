// Shared by sequenzy_flutter_geofences and @sequenzy/react-native-geofences.
// Edit mobile-sdks/geofence-bridge/ios/SequenzyGeofenceBridge.swift and run
// mobile-sdks/geofence-bridge/sync.sh; the copies in the plugins are generated.
#if os(iOS)
    import CoreLocation
    import Foundation
    import UIKit

    /// Region monitoring for the Flutter and React Native plugins. iOS wakes
    /// the app for a region event without starting Dart or JavaScript, so this
    /// class fetches the nearest geofences and reports transitions itself,
    /// with the configuration and identity the plugin last handed it.
    ///
    /// Everything runs on the main queue.
    public final class SequenzyGeofenceBridge: NSObject, CLLocationManagerDelegate {
        public static let shared = SequenzyGeofenceBridge()

        public static let refreshRegionId = "sequenzy.refresh"
        public static let defaultMaxRegions = 20
        static let debounceInterval: TimeInterval = 60
        static let minRefreshInterval: TimeInterval = 60
        static let staleAfter: TimeInterval = 6 * 60 * 60
        static let maxQueuedEvents = 100
        static let maxBatchSize = 20
        static let maxEventAge: TimeInterval = 24 * 60 * 60

        /// Called when the server rejected the identity token, so the plugin
        /// can ask the app for a fresh one.
        public var onIdentityRejected: (() -> Void)?
        public var onLog: ((String) -> Void)?

        private let manager = CLLocationManager()
        private let defaults = UserDefaults.standard
        private let session: URLSession
        private var started = false
        private var fetchPending = false
        private var lastRefreshRequest: Date?
        private var flushing = false
        private var authorizationCallbacks: [(String) -> Void] = []

        private enum Key {
            static let prefix = "sequenzy.geofences.bridge."
            static let config = prefix + "config"
            static let identity = prefix + "identity"
            static let identityRejected = prefix + "identityRejected"
            static let enabled = prefix + "enabled"
            static let maxRegions = prefix + "maxRegions"
            static let regions = prefix + "regions"
            static let lastFetch = prefix + "lastFetch"
            static let transitions = prefix + "transitions"
            static let queue = prefix + "queue"
        }

        override private init() {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            session = URLSession(configuration: configuration)
            super.init()
        }

        // MARK: Setup

        /// Attaches the location delegate. Call on every launch, including the
        /// background launches iOS makes to deliver a region event.
        public func start() {
            guard !started else { return }
            started = true
            manager.delegate = self
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            if isEnabled, isStale { refresh() }
            flush()
        }

        public func configure(apiBaseUrl: String, companyId: String, publicKey: String, appId: String, userAgent: String) {
            let config: [String: String] = [
                "apiBaseUrl": apiBaseUrl, "companyId": companyId, "publicKey": publicKey,
                "appId": appId, "userAgent": userAgent,
            ]
            defaults.set(config, forKey: Key.config)
        }

        /// The signed-in contact. Another email (or nil) drops everything
        /// recorded for the previous one; a new token for the same email
        /// retries what was held back. Returns true when this token was
        /// rejected earlier (possibly while the plugin was not running), so
        /// the plugin should ask the app for a fresh one.
        @discardableResult
        public func setIdentity(email: String?, identityToken: String?) -> Bool {
            let previous = identity
            let next = email.flatMap { email -> [String: String]? in
                guard !email.isEmpty, let token = identityToken, !token.isEmpty else { return nil }
                return ["email": email, "identityToken": token]
            }
            if let next { defaults.set(next, forKey: Key.identity) } else { defaults.removeObject(forKey: Key.identity) }
            if previous?["email"] != next?["email"] {
                defaults.removeObject(forKey: Key.queue)
                defaults.removeObject(forKey: Key.transitions)
                defaults.removeObject(forKey: Key.lastFetch)
                defaults.set(false, forKey: Key.identityRejected)
                apply([])
                if next != nil { refresh(force: true) }
                return false
            }
            if previous?["identityToken"] != next?["identityToken"] {
                defaults.set(false, forKey: Key.identityRejected)
                flush()
                if isStale { refresh() }
            }
            return next != nil && defaults.bool(forKey: Key.identityRejected)
        }

        // MARK: Authorization

        /// `notDetermined`, `denied`, `whenInUse` or `always`.
        public var authorization: String {
            switch authorizationStatus {
            case .notDetermined: return "notDetermined"
            case .authorizedAlways: return "always"
            case .authorizedWhenInUse: return "whenInUse"
            default: return "denied"
            }
        }

        public var hasPreciseLocation: Bool {
            if #available(iOS 14.0, *) { return manager.accuracyAuthorization == .fullAccuracy }
            return true
        }

        private var authorizationStatus: CLAuthorizationStatus {
            if #available(iOS 14.0, *) { return manager.authorizationStatus }
            return CLLocationManager.authorizationStatus()
        }

        /// Asks for "When In Use" access, then "Always". Completes with the
        /// resulting authorization once iOS answers.
        public func requestAuthorization(completion: @escaping (String) -> Void) {
            start()
            switch authorizationStatus {
            case .notDetermined:
                authorizationCallbacks.append(completion)
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse:
                authorizationCallbacks.append(completion)
                manager.requestAlwaysAuthorization()
                // iOS shows the upgrade prompt at most once and does not call
                // back when it decides not to; answer anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.answerAuthorization() }
            default:
                completion(authorization)
            }
        }

        private func answerAuthorization() {
            let callbacks = authorizationCallbacks
            authorizationCallbacks = []
            callbacks.forEach { $0(authorization) }
        }

        // MARK: Enable and refresh

        public var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

        public var maxRegions: Int {
            let stored = defaults.integer(forKey: Key.maxRegions)
            return stored > 0 ? stored : Self.defaultMaxRegions
        }

        /// Turns geofencing on and fetches the nearest geofences.
        public func enable(maxRegions: Int?) {
            start()
            if let maxRegions { defaults.set(max(2, min(20, maxRegions)), forKey: Key.maxRegions) }
            defaults.set(true, forKey: Key.enabled)
            refresh(force: true)
        }

        /// Stops watching every Sequenzy region. Queued transitions are still sent.
        public func disable() {
            defaults.set(false, forKey: Key.enabled)
            fetchPending = false
            apply([])
            defaults.removeObject(forKey: Key.lastFetch)
        }

        public func refresh(force: Bool = false) {
            guard isEnabled else { return }
            if !force, let last = lastRefreshRequest, Date().timeIntervalSince(last) < Self.minRefreshInterval { return }
            lastRefreshRequest = Date()
            guard canMonitor else {
                log("Geofencing needs Always location access with precise location")
                return
            }
            guard identity != nil, !defaults.bool(forKey: Key.identityRejected) else { return }
            fetchPending = true
            manager.requestLocation()
        }

        public var registeredRegionIds: [String] { registered.map(\.id) }

        public var queuedEventCount: Int { queue.count }

        // MARK: Regions

        struct Region: Codable, Equatable {
            let id: String
            let latitude: Double
            let longitude: Double
            let radiusMeters: Double
        }

        private var canMonitor: Bool {
            CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
                && authorizationStatus == .authorizedAlways
                && hasPreciseLocation
        }

        private var isStale: Bool {
            let last = defaults.double(forKey: Key.lastFetch)
            return last == 0 || Date().timeIntervalSince1970 - last > Self.staleAfter
        }

        @objc private func appDidBecomeActive() {
            if isEnabled, isStale { refresh() }
            flush()
        }

        private var registered: [Region] {
            guard let data = defaults.data(forKey: Key.regions) else { return [] }
            return (try? JSONDecoder().decode([Region].self, from: data)) ?? []
        }

        /// Registers `planned` and stops regions that are no longer in it.
        private func apply(_ planned: [Region]) {
            let current = registered
            let next = Dictionary(planned.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let previous = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let removed = Set(current.filter { next[$0.id] != $0 }.map(\.id))
            for region in manager.monitoredRegions where removed.contains(region.identifier) {
                manager.stopMonitoring(for: region)
            }
            for region in planned where previous[region.id] != region {
                let circle = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
                    radius: min(region.radiusMeters, manager.maximumRegionMonitoringDistance),
                    identifier: region.id)
                circle.notifyOnEntry = true
                circle.notifyOnExit = true
                manager.startMonitoring(for: circle)
            }
            defaults.set(try? JSONEncoder().encode(planned), forKey: Key.regions)
        }

        private func fetch(latitude: Double, longitude: Double, done: @escaping () -> Void) {
            guard isEnabled, let identity = identity, let email = identity["email"] else { return done() }
            let token = identity["identityToken"]
            let limit = max(1, min(99, maxRegions - 1))
            let body: [String: Any] = [
                "email": email,
                "identityToken": identity["identityToken"] ?? "",
                "latitude": (latitude * 100).rounded() / 100,
                "longitude": (longitude * 100).rounded() / 100,
                "limit": limit,
            ]
            post("/api/v1/geofences/nearby", body) { [weak self] result in
                guard let self else { return done() }
                defer { done() }
                guard self.isEnabled, self.identity?["email"] == email else { return }
                switch result {
                case .ok(let json):
                    let list = (json["geofences"] as? [[String: Any]]) ?? []
                    var planned = list.compactMap { item -> Region? in
                        guard let id = item["id"] as? String, let lat = item["latitude"] as? Double,
                            let lng = item["longitude"] as? Double, let radius = item["radiusMeters"] as? Double
                        else { return nil }
                        return Region(id: id, latitude: lat, longitude: lng, radiusMeters: radius)
                    }
                    planned = Array(planned.prefix(limit))
                    if let radius = json["refreshRadiusMeters"] as? Double, radius > 0 {
                        planned.append(
                            Region(
                                id: Self.refreshRegionId, latitude: latitude, longitude: longitude,
                                radiusMeters: radius))
                    }
                    self.apply(planned)
                    self.defaults.set(Date().timeIntervalSince1970, forKey: Key.lastFetch)
                case .identityRejected:
                    self.identityRejected(token: token)
                case .retry(let message), .rejected(let message):
                    self.log("Could not fetch geofences: \(message)")
                }
            }
        }

        // MARK: Transitions and the event queue

        private func handle(regionId: String, entered: Bool) {
            if regionId == Self.refreshRegionId {
                if !entered {
                    // Stale until a fetch succeeds, so a failed one is retried
                    // on the next region event, launch or foreground.
                    defaults.removeObject(forKey: Key.lastFetch)
                    withBackgroundTime { done in self.refreshInBackground(done) }
                }
                return
            }
            guard registered.contains(where: { $0.id == regionId }), let email = identity?["email"] else { return }
            let transition = entered ? "enter" : "exit"
            let now = Date()
            var recent = (defaults.dictionary(forKey: Key.transitions) as? [String: Double]) ?? [:]
            let key = "\(regionId):\(transition)"
            if let last = recent[key], abs(now.timeIntervalSince1970 - last) < Self.debounceInterval { return }
            recent[key] = now.timeIntervalSince1970
            recent = recent.filter { now.timeIntervalSince1970 - $0.value < Self.maxEventAge }
            defaults.set(recent, forKey: Key.transitions)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var events = queue
            events.append([
                "email": email,
                "type": "geofence",
                "name": "geofence",
                "transition": transition,
                "geofenceId": regionId,
                "eventId": UUID().uuidString.lowercased(),
                "occurredAt": formatter.string(from: now),
                "properties": [String: Any](),
            ])
            queue = Array(events.suffix(Self.maxQueuedEvents))
            withBackgroundTime { done in self.flush(done) }
            if isStale { refresh() }
        }

        private func refreshInBackground(_ done: @escaping () -> Void) {
            refresh()
            // The location answer arrives through the delegate; give it time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: done)
        }

        private var queue: [[String: Any]] {
            get {
                guard let data = defaults.data(forKey: Key.queue),
                    let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return [] }
                return list
            }
            set {
                defaults.set(try? JSONSerialization.data(withJSONObject: newValue), forKey: Key.queue)
            }
        }

        /// Sends queued transitions in batches. Retryable failures keep them
        /// for the next region event or app launch.
        public func flush(_ done: (() -> Void)? = nil) {
            guard !flushing, let identity = identity, let email = identity["email"],
                !defaults.bool(forKey: Key.identityRejected)
            else { done?(); return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoff = Date().addingTimeInterval(-Self.maxEventAge)
            let fresh = queue.filter { event in
                guard event["email"] as? String == email, let occurredAt = event["occurredAt"] as? String,
                    let date = formatter.date(from: occurredAt)
                else { return false }
                return date > cutoff
            }
            queue = fresh
            guard !fresh.isEmpty else { done?(); return }
            let batch = Array(fresh.prefix(Self.maxBatchSize))
            let ids = Set(batch.compactMap { $0["eventId"] as? String })
            let events = batch.map { event in event.filter { $0.key != "email" } }
            flushing = true
            post(
                "/api/v1/app-events",
                ["email": email, "identityToken": identity["identityToken"] ?? "", "events": events]
            ) { [weak self] result in
                guard let self else { done?(); return }
                self.flushing = false
                switch result {
                case .ok, .rejected:
                    if case .rejected(let message) = result { self.log("Dropped geofence events: \(message)") }
                    self.queue = self.queue.filter { !ids.contains(($0["eventId"] as? String) ?? "") }
                    if self.queue.isEmpty { done?() } else { self.flush(done) }
                case .identityRejected:
                    self.identityRejected(token: identity["identityToken"])
                    done?()
                case .retry(let message):
                    self.log("Will retry geofence events: \(message)")
                    done?()
                }
            }
        }

        /// Only for the token still in use: a reply for a token the plugin has
        /// replaced since must not block the new one.
        private func identityRejected(token: String?) {
            guard identity?["identityToken"] == token else { return }
            defaults.set(true, forKey: Key.identityRejected)
            log("The identity token was rejected; waiting for a fresh one")
            onIdentityRejected?()
        }

        // MARK: HTTP

        private var identity: [String: String]? { defaults.dictionary(forKey: Key.identity) as? [String: String] }

        private enum Result {
            case ok([String: Any])
            case identityRejected
            case retry(String)
            case rejected(String)
        }

        private func post(_ path: String, _ fields: [String: Any], completion: @escaping (Result) -> Void) {
            guard let config = defaults.dictionary(forKey: Key.config) as? [String: String],
                let base = config["apiBaseUrl"], let url = URL(string: base.replacingOccurrences(
                    of: "/+$", with: "", options: .regularExpression) + path)
            else {
                completion(.retry("not configured"))
                return
            }
            var body = fields
            body["companyId"] = config["companyId"] ?? ""
            body["publicKey"] = config["publicKey"] ?? ""
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(config["publicKey"], forHTTPHeaderField: "x-sequenzy-key")
            request.setValue(config["appId"], forHTTPHeaderField: "x-sequenzy-app-id")
            request.setValue(config["userAgent"], forHTTPHeaderField: "user-agent")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            session.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let result: Result
                if let error {
                    result = .retry(error.localizedDescription)
                } else if (200..<300).contains(status) {
                    result = .ok(json)
                } else if (status == 401 || status == 403), json["code"] as? String == "invalid_web_tracking_identity" {
                    result = .identityRejected
                } else if status == 408 || status == 425 || status == 429 || status >= 500 {
                    result = .retry("HTTP \(status)")
                } else {
                    result = .rejected("HTTP \(status) \((json["error"] as? String) ?? "")")
                }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        }

        /// iOS gives a background launch about ten seconds; ask for the time
        /// the request needs.
        private func withBackgroundTime(_ work: (@escaping () -> Void) -> Void) {
            let application = UIApplication.shared
            var task = UIBackgroundTaskIdentifier.invalid
            let end = {
                if task != .invalid {
                    application.endBackgroundTask(task)
                    task = .invalid
                }
            }
            task = application.beginBackgroundTask(withName: "sequenzy.geofence", expirationHandler: end)
            work(end)
        }

        private func log(_ message: String) {
            if let onLog { onLog(message) } else { print("[Sequenzy] \(message)") }
        }

        // MARK: CLLocationManagerDelegate

        public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
            handle(regionId: region.identifier, entered: true)
        }

        public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
            handle(regionId: region.identifier, entered: false)
        }

        public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard fetchPending, let coordinate = locations.last?.coordinate else { return }
            fetchPending = false
            withBackgroundTime { done in
                self.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude, done: done)
            }
        }

        public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            fetchPending = false
            log("Location request failed: \(error.localizedDescription)")
        }

        /// iOS 13; later versions call locationManagerDidChangeAuthorization.
        public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            if #available(iOS 14.0, *) { return }
            authorizationChanged()
        }

        public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            authorizationChanged()
        }

        private func authorizationChanged() {
            switch authorizationStatus {
            case .notDetermined:
                return
            case .authorizedWhenInUse:
                if !authorizationCallbacks.isEmpty {
                    // The second step of requestAuthorization().
                    manager.requestAlwaysAuthorization()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.answerAuthorization() }
                    return
                }
            case .authorizedAlways:
                if isEnabled { refresh(force: true) }
            default:
                apply([])
            }
            answerAuthorization()
        }

        public func locationManager(
            _ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error
        ) {
            log("Could not monitor region \(region?.identifier ?? "unknown"): \(error.localizedDescription)")
            // Kept out of the stored plan, so the next plan registers it again.
            guard let id = region?.identifier else { return }
            defaults.set(try? JSONEncoder().encode(registered.filter { $0.id != id }), forKey: Key.regions)
        }
    }
#endif
