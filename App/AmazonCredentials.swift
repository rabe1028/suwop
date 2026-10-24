import Foundation
import Security
import SuwopShell
import WebKit

/// Native cookie serialization only. This is not a copy of a Rust protocol DTO.
private struct NativeAmazonCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Date?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        secure = cookie.isSecure
        expires = cookie.expiresDate
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
            .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expires {
            properties[.expires] = expires
        }
        return HTTPCookie(properties: properties)
    }
}

enum AmazonCredentials {
    private static let service = "jp.rabe1028.suwop.amazon-photos"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

    static func save(_ cookies: [HTTPCookie]) throws -> String {
        let cookies = cookies.filter { cookie in
            [".amazon.co.jp", "amazon.co.jp", "www.amazon.co.jp"].contains(cookie.domain)
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        guard cookies.contains(where: { $0.name.hasPrefix("at-") && !$0.value.isEmpty }) else {
            throw SuwopError("Amazon Photosの写真一覧が表示されるまでログインを完了してください。")
        }
        let account = UUID().uuidString
        let data = try JSONEncoder().encode(cookies.map(NativeAmazonCookie.init))
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw SuwopError("Amazon Photosの認証情報をKeychainへ保存できません。")
        }
        return account
    }

    static func read(_ account: String) throws -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { throw SuwopError("Amazon Photosの認証情報を読み出せません。接続設定からログインし直してください。") }
        return try JSONDecoder().decode([NativeAmazonCookie].self, from: data).compactMap(\.cookie)
    }

    /// Recover an interrupted connection using metadata only. Never choose
    /// between multiple saved accounts or expose cookie data to the UI.
    static func unambiguousSavedAccount() throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        let accounts = (result as? [[String: Any]])?.compactMap { $0[kSecAttrAccount as String] as? String } ?? []
        guard status == errSecSuccess, accounts.count == 1, let account = accounts.first else {
            throw SuwopError("保存済みのAmazon認証を一意に確認できません。Amazon Photosにログインして接続してください。")
        }
        return account
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SuwopError("Amazon Photosの認証情報をKeychainから削除できません。")
        }
    }

    static func authorize(_ request: inout URLRequest, account: String, allowed: Bool) throws {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard allowed, let url = request.url else { return }
        let cookies = try read(account).filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let host = url.host ?? ""
            let domainMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let pathMatches = url.path == cookie.path || (url.path.hasPrefix(cookie.path)
                && (cookie.path.hasSuffix("/") || url.path.dropFirst(cookie.path.count).hasPrefix("/")))
            return domainMatches && pathMatches
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let session = cookies.first(where: { $0.name == "session-id" }) {
            request.setValue(session.value, forHTTPHeaderField: "x-amzn-sessionid")
        }
        request.setValue("https://www.amazon.co.jp/photos/all", forHTTPHeaderField: "Referer")
    }
}
