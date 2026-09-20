import Foundation

enum AppConfig {
    /// URL pagina dipendente (modifica se il percorso su Aruba cambia)
    static let webURL = URL(string: "https://www.cashmeritaly.cloud/gestionepresenze/public/index.html")!
    /// Base API senza slash finale
    static let apiBase = "https://www.cashmeritaly.cloud/gestionepresenze/api"
}
