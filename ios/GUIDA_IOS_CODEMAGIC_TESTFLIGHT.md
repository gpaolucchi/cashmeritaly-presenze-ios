# Guida iOS — Cashmeritaly Gestione Presenze

Obiettivo: app iPhone come Android (sito + GPS zona + token anche dopo logout), senza possedere un Mac, al costo più basso e semplice possibile.

---

## 1. Costi fissi

| Voce | Circa |
|------|--------|
| Apple Developer Program | 99 € / anno |
| Codemagic | spesso gratis nei limiti free; poi a consumo |
| Mac fisico | non necessario |

---

## 2. Account Apple Developer

1. Vai su https://developer.apple.com/programs/
2. Iscriviti con un Apple ID (meglio aziendale)
3. Completa pagamento e verifica (può richiedere 1–2 giorni)

Poi su https://appstoreconnect.apple.com :

1. **My Apps → +** → New App
2. Piattaforma iOS, nome es. **Gestione Presenze**
3. Bundle ID: `cloud.cashmeritaly.presenze` (crealo prima in Certificates, Identifiers & Profiles se manca)
4. Annota l’**Apple ID numerico** dell’app (in App Information)

### Bundle ID e capacità

In Developer → Identifiers → App IDs:

- Identifier: `cloud.cashmeritaly.presenze`
- Capabilities utili: (di base basta l’app; la location è gestita da Info.plist)

---

## 3. Progetto già pronto

Cartella:

```text
CashmeritalyNative/ios/CashmeritalyPresenze/
```

Contiene:

- `WKWebView` sul sito Aruba
- Bridge JS uguale ad Android (`CashmeritalyNativeStartMonitor` / `Stop`)
- `LocationMonitor` in background + `monitor_token`
- Bundle ID: `cloud.cashmeritaly.presenze`

URL in `Config.swift` (modifica se serve):

```swift
webURL  = https://www.cashmeritaly.cloud/gestionepresenze/public/index.html
apiBase = https://www.cashmeritaly.cloud/gestionepresenze/api
```

---

## 4. Mettere il codice su GitHub (consigliato per Codemagic)

1. Crea un repository privato su GitHub
2. Carica almeno la cartella `ios/` (o tutto `CashmeritalyNative`)
3. Non mettere password o certificati nel repo

---

## 5. Codemagic — setup una tantum

1. Registrati su https://codemagic.io con GitHub
2. **Add application** → seleziona il repo
3. Project type: **iOS App**
4. Project path: cartella che contiene `CashmeritalyPresenze.xcodeproj`

### Firma (code signing) — modo più semplice

**Opzione A — Automatic con App Store Connect API Key**

1. App Store Connect → Users and Access → Keys → App Store Connect API
2. Genera una chiave con ruolo **Admin** o **App Manager**
3. Scarica il file `.p8` (una sola volta)
4. In Codemagic → Teams → Integrations → App Store Connect: carica Issuer ID, Key ID, file `.p8`
5. Abilita **automatic code signing** nel workflow

**Opzione B — Certificati manuali**

1. Su developer.apple.com crea iOS Distribution certificate + profilo App Store
2. Caricali in Codemagic → Code signing identities

### Workflow

Nel repo c’è un esempio `ios/codemagic.yaml`.  
Adatta i nomi di integrazione / profili, poi in Codemagic scegli quel workflow e lancia **Start new build**.

Al termine:

- viene prodotto un **.ipa**
- se configurato, viene caricato su **TestFlight**

---

## 6. TestFlight — dipendenti

1. App Store Connect → la tua app → **TestFlight**
2. Attendi elaborazione build (anche 10–30 minuti)
3. Aggiungi **Internal Testing** (fino a 100 utenti del team) oppure **External** (review Apple leggera)
4. Invita i dipendenti per **email**
5. Sul iPhone installano l’app **TestFlight** dall’App Store, poi accettano l’invito e installano **Gestione Presenze**

---

## 7. Permessi sul iPhone (dipendente)

Alla prima apertura:

1. Consentire **posizione**
2. Quando richiesto, preferire **Sempre** / *Always* (per il monitoraggio in servizio)
3. Consentire **notifiche** se chieste

Senza “Sempre”, il GPS in background è molto limitato.

---

## 8. Test funzionale (come Android)

1. Login → **Entrata** (nel raggio)
2. Verificare notifica / monitoraggio attivo
3. Logout: il token nativo resta; il monitoraggio può continuare
4. Allontanamento / cambio coordinate di test → **Alert GPS** in admin
5. **Uscita** → monitoraggio si ferma

---

## 9. Se non usi Codemagic

- **MacinCloud** / altro Mac a noleggio: apri `CashmeritalyPresenze.xcodeproj` in Xcode → Team Apple → Archive → Distribute → TestFlight
- **EC2 Mac**: stesso flusso Xcode, più tecnico

---

## 10. Checklist ordine consigliato

1. [ ] Apple Developer iscritto e attivo  
2. [ ] Bundle ID `cloud.cashmeritaly.presenze` creato  
3. [ ] App creata in App Store Connect  
4. [ ] Codice su GitHub  
5. [ ] Codemagic collegato + API Key App Store Connect  
6. [ ] Prima build verde + IPA su TestFlight  
7. [ ] Invito a 1 iPhone di prova  
8. [ ] Test entrata / alert / uscita  

---

## Note realistiche su iOS

- Apple è più restrittiva di Android sulla posizione in background.
- Chiudere l’app dallo switcher può ridurre gli aggiornamenti GPS.
- In review (se pubblichi sull’App Store pubblico) potrebbe servire spiegare perché serve la posizione “Always” (controllo presenza sul luogo di lavoro).

Per uso interno aziendale, **TestFlight** è di solito sufficiente e più semplice dello Store pubblico.
