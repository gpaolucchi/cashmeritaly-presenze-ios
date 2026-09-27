import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Monitoraggio zona negozio in background.
/// Usa **geofence nativo** (CLCircularRegion) per uscita/rientro: iOS sveglia l'app
/// al varco del confine, molto più affidabile dei soli aggiornamenti GPS continui
/// (che spesso perdono il rientro dopo 10–20 minuti fuori).
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMonitor()

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let regionIdPrefix = "negozio_"

    private var state: String? // inside | outside
    private var pending: String?
    private var pendingCount = 0
    private var lastEventTipo: String?
    private var lastEventAt: Date = .distantPast
    private var lastProcessAt: Date = .distantPast

    private var negozioId: Int = 0
    private var storeLat: Double = 0
    private var storeLng: Double = 0
    private var raggio: Int = 150
    private var token: String = ""

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
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
        self.raggio = max(50, raggio) // geofence sotto ~50m è poco affidabile su iOS
        self.token = token
        self.state = nil
        self.pending = nil
        self.pendingCount = 0
        self.lastEventTipo = nil
        self.lastEventAt = .distantPast

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
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["in_servizio"])
    }

    func restoreIfNeeded() {
        guard defaults.bool(forKey: "mon_active"),
              let tok = defaults.string(forKey: "mon_token"), !tok.isEmpty else { return }
        negozioId = defaults.integer(forKey: "mon_negozio")
        storeLat = defaults.double(forKey: "mon_lat")
        storeLng = defaults.double(forKey: "mon_lng")
        raggio = defaults.integer(forKey: "mon_raggio")
        if raggio < 50 { raggio = 150 }
        token = tok
        requestPermissionAndStart()
    }

    private func stopAllMonitoring() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions {
            if region.identifier.hasPrefix(regionIdPrefix) {
                manager.stopMonitoring(for: region)
            }
        }
    }

    private func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginLocationUpdates()
        case .authorizedAlways:
            beginLocationUpdates()
        default:
            showLocalNotification(
                title: "Posizione non consentita",
                body: "Per Alert GPS: Impostazioni → Gestione Presenze → Posizione → Sempre"
            )
        }
    }

    private func beginLocationUpdates() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            // Fallback solo GPS continuo
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
            return
        }

        // 1) Geofence nativo (priorità per rientro/uscita)
        startStoreRegion()

        // 2) GPS continuo come supporto (stato iniziale + drift)
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    private func startStoreRegion() {
        // Rimuovi eventuali regioni negozio precedenti
        for region in manager.monitoredRegions {
            if region.identifier.hasPrefix(regionIdPrefix) {
                manager.stopMonitoring(for: region)
            }
        }
        let center = CLLocationCoordinate2D(latitude: storeLat, longitude: storeLng)
        // iOS: raggio minimo pratico ~50–100 m; usiamo il raggio negozio (min 50)
        let radius = min(max(Double(raggio), 50), 500)
        let region = CLCircularRegion(
            center: center,
            radius: radius,
            identifier: "\(regionIdPrefix)\(negozioId)"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        // Chiede lo stato attuale (dentro/fuori) senza aspettare un varco
        manager.requestState(for: region)
    }

    // MARK: - Authorization

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if defaults.bool(forKey: "mon_active") {
                if manager.authorizationStatus == .authorizedWhenInUse {
                    manager.requestAlwaysAuthorization()
                }
                beginLocationUpdates()
            }
        default:
            break
        }
    }

    // MARK: - Region (geofence) — principale

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        handleBoundary(nowState: "inside", lat: storeLat, lng: storeLng, dist: 0)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        handleBoundary(nowState: "outside", lat: storeLat, lng: storeLng, dist: raggio + 1)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        switch state {
        case .inside:
            if self.state == nil { self.state = "inside" }
        case .outside:
            if self.state == nil {
                self.state = "outside"
                // Se parte già fuori dopo entrata, registra uscita zona
                emit(tipo: "uscita_zona", lat: storeLat, lng: storeLng, dist: raggio + 1)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Se la geofence fallisce, resta attivo il GPS continuo
    }

    // MARK: - Continuous GPS (backup)

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, defaults.bool(forKey: "mon_active") else { return }
        // Evita flood
        if Date().timeIntervalSince(lastProcessAt) < 8 { return }
        // Scarta letture molto imprecise (tipiche Wi‑Fi / indoor)
        if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 120 { return }
        lastProcessAt = Date()
        processContinuous(location: loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// Geofence: una conferma basta (iOS ha già filtrato il varco).
    private func handleBoundary(nowState: String, lat: Double, lng: Double, dist: Int) {
        let prev = state
        if prev == nil {
            state = nowState
            if nowState == "outside" {
                emit(tipo: "uscita_zona", lat: lat, lng: lng, dist: dist)
            }
            return
        }
        if nowState == prev { return }
        state = nowState
        if prev == "inside" && nowState == "outside" {
            emit(tipo: "uscita_zona", lat: lat, lng: lng, dist: dist)
        } else if prev == "outside" && nowState == "inside" {
            emit(tipo: "rientro_zona", lat: lat, lng: lng, dist: dist)
        }
    }

    /// GPS continuo: richiede 2 letture consecutive (meno falsi positivi).
    private func processContinuous(location: CLLocation) {
        let dist = location.distance(from: CLLocation(latitude: storeLat, longitude: storeLng))
        // Isteresi: uscita più “larga”, rientro un po’ più “stretto” ma non eccessivo
        let rOut = Double(raggio) + 40
        let rIn = max(30.0, Double(raggio) * 0.85)
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
            return // non emettere subito: lascia alla geofence lo stato iniziale
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
        // 2 conferme consecutive
        guard pendingCount >= 2 else { return }

        let prev = state
        state = nowState
        pending = nil
        pendingCount = 0

        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let d = Int(dist)
        if prev == "inside" && nowState == "outside" {
            emit(tipo: "uscita_zona", lat: lat, lng: lng, dist: d)
        } else if prev == "outside" && nowState == "inside" {
            emit(tipo: "rientro_zona", lat: lat, lng: lng, dist: d)
        }
    }

    private func emit(tipo: String, lat: Double, lng: Double, dist: Int) {
        // Debounce 45s sullo stesso tipo
        if tipo == lastEventTipo, Date().timeIntervalSince(lastEventAt) < 45 { return }
        lastEventTipo = tipo
        lastEventAt = Date()
        postEvent(tipo: tipo, lat: lat, lng: lng, dist: dist)
        let msg = (tipo == "uscita_zona")
            ? "Uscita zona rilevata"
            : "Rientro zona rilevato"
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
        let id = "gps_\(tipoSafe(title))_\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func tipoSafe(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
    }
}
