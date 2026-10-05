import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// iOS: invia heartbeat posizione al server.
/// Il server rileva uscite/rientri anche se i ping sono irregolari
/// (buco di segnale → uscita stimata + rientro al ripresa).
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMonitor()

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let regionIdPrefix = "negozio_"

    private var negozioId: Int = 0
    private var storeLat: Double = 0
    private var storeLng: Double = 0
    private var raggio: Int = 150
    private var token: String = ""

    private var lastHeartbeatAt: Date = .distantPast
    private var lastNotifiedTipo: String?
    private var lastNotifiedAt: Date = .distantPast

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
        self.raggio = max(50, raggio)
        self.token = token
        self.lastHeartbeatAt = .distantPast

        defaults.set(true, forKey: "mon_active")
        defaults.set(negozioId, forKey: "mon_negozio")
        defaults.set(lat, forKey: "mon_lat")
        defaults.set(lng, forKey: "mon_lng")
        defaults.set(self.raggio, forKey: "mon_raggio")
        defaults.set(token, forKey: "mon_token")

        requestPermissionAndStart()
        showLocalNotification(title: "In servizio", body: "Monitoraggio posizione attivo")
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionIdPrefix) {
            manager.stopMonitoring(for: region)
        }
        defaults.set(false, forKey: "mon_active")
        defaults.removeObject(forKey: "mon_token")
        token = ""
    }

    func restoreIfNeeded() {
        guard defaults.bool(forKey: "mon_active"),
              let tok = defaults.string(forKey: "mon_token"), !tok.isEmpty else { return }
        negozioId = defaults.integer(forKey: "mon_negozio")
        storeLat = defaults.double(forKey: "mon_lat")
        storeLng = defaults.double(forKey: "mon_lng")
        raggio = max(50, defaults.integer(forKey: "mon_raggio"))
        token = tok
        requestPermissionAndStart()
    }

    private func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            begin()
        case .authorizedAlways:
            begin()
        default:
            showLocalNotification(
                title: "Posizione non consentita",
                body: "Impostazioni → Gestione Presenze → Posizione → Sempre"
            )
        }
    }

    private func begin() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionIdPrefix) {
            manager.stopMonitoring(for: region)
        }

        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: storeLat, longitude: storeLng),
                radius: min(max(Double(raggio), 80), 400),
                identifier: "\(regionIdPrefix)\(negozioId)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }

        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if defaults.bool(forKey: "mon_active"),
           manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            begin()
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // Forza un heartbeat immediato (non aspetta i 45s)
        lastHeartbeatAt = .distantPast
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        lastHeartbeatAt = .distantPast
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, defaults.bool(forKey: "mon_active") else { return }
        if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 250 { return }

        // Heartbeat ogni 45s (più frequente = meno uscite perse su iOS)
        if Date().timeIntervalSince(lastHeartbeatAt) < 45 { return }
        lastHeartbeatAt = Date()
        sendHeartbeat(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func sendHeartbeat(lat: Double, lng: Double) {
        guard !token.isEmpty, let url = URL(string: AppConfig.apiBase + "/gps-heartbeat") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Monitor-Token")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "lat": lat,
            "lng": lng,
            "negozio_id": negozioId,
            "monitor_token": token
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        URLSession(configuration: cfg).dataTask(with: req) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                DispatchQueue.main.async { self?.stop() }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // Supporta sia "evento" singolo sia "eventi" multipli (uscita stimata + rientro)
            var tipi: [String] = []
            if let ev = json["evento"] as? String { tipi.append(ev) }
            if let arr = json["eventi"] as? [String] { tipi.append(contentsOf: arr) }
            for t in Set(tipi) {
                DispatchQueue.main.async { self?.notifyEvent(t) }
            }
        }.resume()
    }

    private func notifyEvent(_ tipo: String) {
        if tipo == lastNotifiedTipo, Date().timeIntervalSince(lastNotifiedAt) < 45 { return }
        lastNotifiedTipo = tipo
        lastNotifiedAt = Date()
        let msg = (tipo == "uscita_zona") ? "Uscita zona rilevata" : "Rientro zona rilevato"
        showLocalNotification(title: "Alert GPS", body: msg)
    }

    private func showLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let id = "gps_\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }
}
