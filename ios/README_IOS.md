# Cashmeritaly Presenze — iOS (prossima fase)

## Stato
Il progetto **Android** è pronto come prima consegna.  
iOS richiede un Mac con **Xcode** e un account Apple Developer per installare sui dispositivi.

## Approccio consigliato (allineato ad Android)
1. App **WKWebView** che carica  
   `https://www.cashmeritaly.cloud/gestionepresenze/public/img/../index.html`
2. Bridge JavaScript `CashmeritalyNative` (stesso contratto usato su Android)
3. **CLLocationManager** con:
   - `allowsBackgroundLocationUpdates = true`
   - modalità background **Location updates** in Info.plist
   - notifica locale “In servizio” mentre il monitoraggio è attivo
4. Stesse API: `POST /api/gps-evento` con cookie di sessione

## Info.plist (chiavi necessarie)
- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes` → `location`
- `NSLocationAlwaysUsageDescription` (legacy)

## Note Apple
- La localizzazione “Always” viene revisionata con attenzione: va motivata (controllo presenza sul luogo di lavoro).
- In background iOS può ridurre la frequenza degli aggiornamenti; il geofence nativo (`CLCircularRegion`) è spesso più efficiente del polling continuo.

## Prossimi passi
Quando vuoi procedere su iOS:
1. Creiamo il progetto Xcode Swift completo (WebView + LocationManager + bridge)
2. Generiamo il profilo di provisioning / TestFlight
3. Allineiamo i testi di permesso e la privacy policy sul sito

Fino ad allora i dipendenti iPhone possono usare il **browser** (monitoraggio solo con app aperta); su Android, con l’APK, il monitoraggio continua anche ridotta in background grazie al Foreground Service.
