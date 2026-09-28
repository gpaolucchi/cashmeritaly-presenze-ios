import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Monitoraggio zona negozio in background.
/// Eventi (uscita/rientro) partono **solo** da geofence nativo (didExit / didEnter).
/// Il GPS continuo serve solo a conoscere lo stato iniziale, non genera alert
/// (evita la coppia uscita+rientro alla stessa ora al rientro).
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMonitor()

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let regionIdPrefix = "negozio_"

    /// inside | outside | nil (sconosciuto)
    private var state: String?
    private var lastEventTipo: String?
    private var lastEventAt: Date = .distantPast
    private var regionMonitoringActive = false

    private var negozioId: Int = 0
    private var storeLat: Double = 0
    private var storeLng: Double = 0
    private var raggio: Int = 150
    private var token: String = ""

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 30
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
        // Geofence iOS: sotto ~100m è instabile; usiamo almeno 100m operativi
        self.raggio = max(100, raggio)
        self.token = token
        self.state = nil
        self.lastEventTipo = nil
        self.lastEventAt = .distantPast
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
        regionMonitoringActive = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["in_servizio"])
    }

    func restoreIfNeeded() {
        guard defaults.bool(forKey: "mon_active"),
              let tok = defaults.string(forKey: "mon_token"), !tok.isEmpty else { return }
        negozioId = defaults.integer(forKey: "mon_negozio")
        storeLat = defaults.double(forKey: "mon_lat")
        storeLng = defaults.double(forKey: "mon_lng")
        raggio = max(100, defaults.integer(forKey: "mon_raggio"))
        token = tok
        // Non azzerare state se possibile: meglio sconosciuto al restore
        state = nil
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

        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            startStoreRegion()
            regionMonitoringActive = true
        } else {
            regionMonitoringActive = false
        }

        // GPS: solo per stato iniziale / fallback se geofence non disponibile
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    private func startStoreRegion() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionIdPrefix) {
            manager.stopMonitoring(for: region)
        }
        let center = CLLocationCoordinate2D(latitude: storeLat, longitude: storeLng)
        let radius = min(max(Double(raggio), 100), 400)
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
        case .authorizedAlways:
            if defaults.bool(forKey: "mon_active") { beginMonitoring() }
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            if defaults.bool(forKey: "mon_active") { beginMonitoring() }
        default:
            break
        }
    }

    // MARK: - Geofence (unica fonte di eventi)

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        // Uscita vera dal confine
        if state == "outside" { return }
        state = "outside"
        emit(tipo: "uscita_zona", lat: storeLat, lng: storeLng, dist: raggio + 1)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        // Rientro solo se eravamo fuori (niente coppia inventata)
        if state == "outside" {
            state = "inside"
            emit(tipo: "rientro_zona", lat: storeLat, lng: storeLng, dist: 0)
        } else {
            // Eravamo già inside o sconosciuti: solo aggiorna stato, nessun evento
            state = "inside"
        }
    }

    /// Solo per conoscere dentro/fuori all'avvio — **non** emette alert.
    func locationManager(_ manager: CLLocationManager, didDetermineState regionState: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(regionIdPrefix), defaults.bool(forKey: "mon_active") else { return }
        // Imposta stato iniziale senza generare uscita/rientro
        if state == nil {
            switch regionState {
            case .inside:  state = "inside"
            case .outside: state = "outside"
            case .unknown: break
            @unknown default: break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        regionMonitoringActive = false
    }

    // MARK: - GPS continuo (niente eventi se geofence attiva)

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, defaults.bool(forKey: "mon_active") else { return }
        if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 150 { return }

        let dist = loc.distance(from: CLLocation(latitude: storeLat, longitude: storeLng))
        let inside = dist <= Double(raggio)

        // Con geofence attiva: aggiorna solo stato iniziale, zero emit
        if regionMonitoringActive {
            if state == nil {
                state = inside ? "inside" : "outside"
            }
            return
        }

        // Fallback senza geofence: logica semplice con debounce
        let nowState = inside ? "inside" : "outside"
        if state == nil {
            state = nowState
            return
        }
        guard nowState != state else { return }
        let prev = state
        state = nowState
        if prev == "inside" && nowState == "outside" {
            emit(tipo: "uscita_zona", lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, dist: Int(dist))
        } else if prev == "outside" && nowState == "inside" {
            emit(tipo: "rientro_zona", lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, dist: Int(dist))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - Emit / network

    private func emit(tipo: String, lat: Double, lng: Double, dist: Int) {
        // Evita doppioni ravvicinati dello stesso tipo
        if tipo == lastEventTipo, Date().timeIntervalSince(lastEventAt) < 60 { return }
        // Evita uscita+rientro nello stesso istante (race)
        if tipo == "rientro_zona", lastEventTipo == "uscita_zona",
           Date().timeIntervalSince(lastEventAt) < 30 {
            // Se l'uscita è stata appena inventata/errata, non bloccare il rientro:
            // ma se sono entro 2 secondi è quasi sicuramente la race al rientro → salta uscita già inviata non possiamo,
            // almeno non emettere di nuovo uscita. Rientro ok.
        }
        if tipo == "uscita_zona", lastEventTipo == "rientro_zona",
           Date().timeIntervalSince(lastEventAt) < 30 {
            return
        }

        lastEventTipo = tipo
        lastEventAt = Date()
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
