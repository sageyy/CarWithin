import Foundation
import NetworkExtension

/// Joins the configured dashboard Wi-Fi before casting. Requires the Hotspot Configuration
/// entitlement; when the signing identity lacks it, the callback returns an error and the
/// caller falls back to the system's own Wi-Fi auto-join.
enum WiFiAutoJoin {
    static func join(ssid: String, password: String, isOpen: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !ssid.isEmpty else {
            completion(.failure(JoinError.missingSSID)); return
        }
        let configuration: NEHotspotConfiguration
        if isOpen || password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        }
        // Do not remove the configuration after joining: keep it like a user-added network.
        configuration.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(configuration) { error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    enum JoinError: LocalizedError {
        case missingSSID
        var errorDescription: String? { "Wi-Fi 名称为空" }
    }
}
