import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Monitoraggio zona negozio anche in background, con monitor_token (come Android).
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMonitor()

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard

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
        // Più reattivo: su iPad Wi‑Fi la precisione è bassa, serve campionare di più
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
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
        self.raggio = max(20, raggio)
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
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
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
        if raggio <= 0 { raggio = 150 }
        token = tok
        requestPermissionAndStart()
    }

    private func requestPermissionAndStart() {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            // Su iOS moderni: prima WhenInUse, poi Always
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Escalation a Always (necessario per background affidabile)
            manager.requestAlwaysAuthorization()
            beginLocationUpdates()
        case .authorizedAlways:
            beginLocationUpdates()
        default:
            // Denied / Restricted
            showLocalNotification(
                title: "Posizione non consentita",
                body: "Per Alert GPS apri Impostazioni → Gestione Presenze → Posizione → Sempre"
            )
        }
    }

    private func beginLocationUpdates() {
        manager.startUpdatingLocation()
        // Backup: aggiornamenti “significativi” anche se iOS sospende il continuo
        manager.startMonitoringSignificantLocationChanges()
        // Forza una lettura immediata
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if defaults.bool(forKey: "mon_active") {
                beginLocationUpdates()
            }
        case .authorizedWhenInUse:
            // Chiedi Always per il monitoraggio in background
            manager.requestAlwaysAuthorization()
            if defaults.bool(forKey: "mon_active") {
                beginLocationUpdates()
            }
        case .denied, .restricted:
            break
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, defaults.bool(forKey: "mon_active") else { return }
        // Evita flood di eventi identici
        if Date().timeIntervalSince(lastProcessAt) < 5 { return }
        lastProcessAt = Date()
        process(location: loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silenzioso: GPS iPad Wi‑Fi può fallire spesso indoor
    }

    private func process(location: CLLocation) {
        let dist = location.distance(from: CLLocation(latitude: storeLat, longitude: storeLng))
        // Isteresi più larga su iPad (posizione Wi‑Fi meno stabile)
        let rOut = Double(raggio) + 60
        let rIn = max(15.0, Double(raggio) - 15)
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
            // Se parte già fuori zona dopo entrata, registra subito
            if nowState == "outside" {
                emit(tipo: "uscita_zona", lat: location.coordinate.latitude, lng: location.coordinate.longitude, dist: Int(dist))
            }
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
        // Su iOS/iPad: 1 conferma basta (gli update sono già più rari)
        guard pendingCount >= 1 else { return }

        let prev = state
        state = nowState
        pending = nil
        pendingCount = 0

        if prev == "inside" && nowState == "outside" {
            emit(tipo: "uscita_zona", lat: location.coordinate.latitude, lng: location.coordinate.longitude, dist: Int(dist))
        } else if prev == "outside" && nowState == "inside" {
            emit(tipo: "rientro_zona", lat: location.coordinate.latitude, lng: location.coordinate.longitude, dist: Int(dist))
        }
    }

    private func emit(tipo: String, lat: Double, lng: Double, dist: Int) {
        if tipo == lastEventTipo, Date().timeIntervalSince(lastEventAt) < 60 { return }
        lastEventTipo = tipo
        lastEventAt = Date()
        postEvent(tipo: tipo, lat: lat, lng: lng, dist: dist)
        let msg = (tipo == "uscita_zona") ? "Uscita zona rilevata (~\(dist) m)" : "Rientro zona rilevato"
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
        // background-friendly session
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
        let id = "gps_\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
