import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Monitoraggio zona negozio in background (iOS / iPad).
///
/// Strategia:
/// - Geofence nativa: uscita + rientro
/// - GPS continuo / significant: soprattutto per rilevare l'uscita
/// - Rientro da GPS continuo solo se stato == outside
/// - Debounce robusto per iPad Wi-Fi (salti triangolazione)
/// - Reset stato dopo lunghi silenzi (iPad fuori Wi-Fi = buio totale)
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMonitor()

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let regionIdPrefix = "negozio_"

    private var state: String? // inside | outside
    private var pending: String?
    private var pendingCount = 0
    private var lastUscitaAt: Date = .distantPast
    private var lastRientroAt: Date = .distantPast
    private var lastProcessAt: Date = .distantPast
    private var lastLocationReceivedAt: Date = .distantPast
    private var regionMonitoringActive = false

    private var negozioId: Int = 0
    private var storeLat: Double = 0
    private var storeLng: Double = 0
    private var raggio: Int = 150
    private var token: String = ""

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.activityType = .otherNavigation
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
    }

    func start(negozioId: Int, lat: Double, lng: Double, raggio: Int, token: String) {
        guard (lat != 0 || lng != 0), !token.isEmpty else { return }
        self.negozioId = negozioId
        self.storeLat = lat
        self.storeLng = lng
        self.raggio = max(80, raggio)
        self.token = token
        self.state = nil
        self.pending = nil
        self.pendingCount = 0
        self.lastUscitaAt = .distantPast
        self.lastRientroAt = .distantPast
        self.lastProcessAt = .distantPast
        self.lastLocationReceivedAt = .distantPast
        self.regionMonitoringActive = false

        defaults.set(true, forKey: "mon_active")
        defaults.set(negozioId, forKey: "mon_negozio")
        defaults.set(lat, forKey: "mon_lat")
        defaults.set(lng, forKey: "mon_lng")
        defaults.set(self.raggio, forKey: "mon_raggio")
        defaults.set(token, forKey: "mon_token")

        requestPermissionAndStart()
        showLocalNotification(title: "In servizio", body: "Monitoraggio zona negozio attivo")
    }

    func stop() {
        stopAllMonitoring()
        defaults.set(false, forKey: "mon_active")
        defaults.removeObject(forKey: "mon_token")
        token = ""
        state = nil
        pending = nil
        pendingCount = 0
        regionMonitoringActive = false
        lastUscitaAt = .distantPast
        lastRientroAt = .distantPast
        lastLocationReceivedAt = .distantPast
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["in_servizio"])
    }

    func restoreIfNeeded() {
        guard defaults.bool(forKey: "mon_active"),
              let tok = defaults.string(forKey: "mon_token"), !tok.isEmpty else { return }
        negozioId = defaults.integer(forKey: "mon_negozio")
        storeLat = defaults.double(forKey: "mon_lat")
        storeLng = defaults.double(forKey: "mon_lng")
        raggio = max(80, defaults.integer(forKey: "mon_raggio"))
        token = tok
        state = nil
        pending = nil
        pendingCount = 0
        lastLocationReceivedAt = .distantPast
        requestPermissionAndStart()
    }

    private func stopAllMonitoring() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionIdPrefix) {
            manager.stopMonitoring(for: region)
        }
    }

    private func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginMonitoring()
        case .authorizedAlways:
            beginMonitoring()
        default:
            showLocalNotification(
                title: "Posizione non consentita",
                body: "Impostazioni → Gestione Presenze → Posizione → Sempre"
            )
        }
    }

    private func beginMonitoring() {
        stopAllMonitoring()
        regionMonitoringActive = false

        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            startStoreRegion()
            regionMonitoringActive = true
        }

        // Sempre attivo: serve a intercettare l'USCITA quando didExitRegion non arriva (iPad)
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    private func startStoreRegion() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionIdPrefix) {
            manager.stopMonitoring(for: region)
        }
        let center = CLLocationCoordinate2D(latitude: storeLat, longitude: storeLng)
        let radius = min(max(Double(raggio), 80), 400)
        let region = CLCircularRegion(
            center: center,
            radius: radius,
            identifier: "\(regionIdPrefix)\(negozioId)"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    // MARK: - Auth

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            if defaults.bool(forKey: "mon_active") { beginMonitoring() }
        default:
            break
        }
    }

    // MARK: - Geofence

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix),
              defaults.bool(forKey: "mon_active") else { return }
        applyTransition(to: "outside", lat: storeLat, lng: storeLng, dist: raggio + 1, source: "region")
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix),
              defaults.bool(forKey: "mon_active") else { return }
        applyTransition(to: "inside", lat: storeLat, lng: storeLng, dist: 0, source: "region")
    }

    /// Solo stato iniziale, nessun evento.
    func locationManager(_ manager: CLLocationManager, didDetermineState regionState: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix),
              defaults.bool(forKey: "mon_active") else { return }
        guard state == nil else { return }
        switch regionState {
        case .inside:  state = "inside"
        case .outside: state = "outside"
        case .unknown: break
        @unknown default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        regionMonitoringActive = false
    }

    // MARK: - GPS continuo (uscita prioritaria)

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, defaults.bool(forKey: "mon_active") else { return }

        // Reset stato dopo lungo silenzio (iPad Wi-Fi fuori copertura)
        let gap = Date().timeIntervalSince(lastLocationReceivedAt)
        if gap > 15 * 60 {
            state = nil
            pending = nil
            pendingCount = 0
        }
        lastLocationReceivedAt = Date()

        // Filtro precisione: scarta letture troppo imprecise (iPad Wi-Fi spesso > 100m)
        if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 50 { return }

        // Intervallo minimo tra elaborazioni
        if Date().timeIntervalSince(lastProcessAt) < 10 { return }
        lastProcessAt = Date()

        let dist = loc.distance(from: CLLocation(latitude: storeLat, longitude: storeLng))
        let rOut = Double(raggio) + 35
        let rIn = max(40.0, Double(raggio) * 0.9)

        let nowState: String
        if dist > rOut {
            nowState = "outside"
        } else if dist <= rIn {
            nowState = "inside"
        } else {
            nowState = state ?? (dist <= Double(raggio) ? "inside" : "outside")
        }

        if state == nil {
            state = nowState
            pending = nil
            pendingCount = 0
            return
        }

        if nowState == state {
            pending = nil
            pendingCount = 0
            return
        }

        if pending == nowState {
            pendingCount += 1
        } else {
            pending = nowState
            pendingCount = 1
        }

        // Richiedi 5 letture consecutive (~50 secondi)
        guard pendingCount >= 5 else { return }

        pending = nil
        pendingCount = 0
        applyTransition(
            to: nowState,
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            dist: Int(dist),
            source: "gps"
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - State machine unica

    private func applyTransition(to nowState: String, lat: Double, lng: Double, dist: Int, source: String) {
        let prev = state

        if prev == nil {
            state = nowState
            // Nessun evento sullo stato iniziale
            return
        }

        if nowState == prev {
            return
        }

        state = nowState

        if prev == "inside" && nowState == "outside" {
            emit(tipo: "uscita_zona", lat: lat, lng: lng, dist: dist)
        } else if prev == "outside" && nowState == "inside" {
            emit(tipo: "rientro_zona", lat: lat, lng: lng, dist: dist)
        }
    }

    private func emit(tipo: String, lat: Double, lng: Double, dist: Int) {
        let now = Date()

        if tipo == "uscita_zona" {
            // Non emettere uscita se troppo vicina a un rientro (falso allarme iPad)
            if now.timeIntervalSince(lastRientroAt) < 90 { return }
            // Non emettere due uscite ravvicinate
            if now.timeIntervalSince(lastUscitaAt) < 120 { return }
            lastUscitaAt = now

        } else if tipo == "rientro_zona" {
            // Non emettere rientro se troppo vicino a un'uscita (evita il bug 0h 00m)
            if now.timeIntervalSince(lastUscitaAt) < 90 { return }
            // Non emettere due rientri ravvicinati
            if now.timeIntervalSince(lastRientroAt) < 120 { return }
            lastRientroAt = now
        }

        postEvent(tipo: tipo, lat: lat, lng: lng, dist: dist)

        let msg = (tipo == "uscita_zona") ? "Uscita zona rilevata" : "Rientro zona rilevato"
        showLocalNotification(title: "Alert GPS", body: msg)
    }

    private func postEvent(tipo: String, lat: Double, lng: Double, dist: Int) {
        guard !token.isEmpty, let url = URL(string: AppConfig.apiBase + "/gps-evento") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Monitor-Token")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "tipo": tipo,
            "lat": lat,
            "lng": lng,
            "distanza_metri": dist,
            "negozio_id": negozioId,
            "monitor_token": token
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        URLSession(configuration: cfg).dataTask(with: req) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                DispatchQueue.main.async { self?.stop() }
            }
        }.resume()
    }

    private func showLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let id = "gps_\(Int(Date().timeIntervalSince1970))_\(title.hashValue)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }
}