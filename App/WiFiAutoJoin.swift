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

    /// 把 NEHotspotConfigurationError 的 code 翻译成可读信息，便于判断是权限、后台
    /// 限制还是密码错误。直接用 raw code 映射，避免 Swift 版本间 enum case 差异。
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let code = nsError.code
        let detail: String
        switch code {
        case 1:  detail = "网络已连接"
        case 2:  detail = "Wi-Fi 被系统禁用"
        case 7:  detail = "SSID 无效"
        case 8, 21: detail = "Wi-Fi 密码错误"
        case 9, 10: detail = "找不到该网络（SSID 不存在或信号范围外）"
        case 11: detail = "用户拒绝了系统确认框"
        case 15, 16: detail = "未授权/策略拒绝（签名可能缺少 Hotspot Configuration 权限）"
        case 17: detail = "系统配置失败（签名权限或系统状态问题）"
        case 20: detail = "App 不在前台，iOS 不允许后台加入 Wi-Fi"
        case 65: detail = "内部错误（通常是签名缺少 Hotspot Configuration 权限）"
        default: detail = nsError.localizedDescription
        }
        return "\(detail) [code=\(code), domain=\(nsError.domain)]"
    }

    enum JoinError: LocalizedError {
        case missingSSID
        var errorDescription: String? { "Wi-Fi 名称为空" }
    }
}
