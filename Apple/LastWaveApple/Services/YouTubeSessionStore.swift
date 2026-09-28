import CryptoKit
import Foundation
import Security

struct YouTubeSession: Codable, Sendable {
    var cookie: String
    var visitorData: String?
    var dataSyncID: String?
    var authUser: String

    var sapisid: String? {
        cookie.split(separator: ";").lazy.compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "SAPISID" || pair[0] == "__Secure-3PAPISID" else { return nil }
            return String(pair[1])
        }.first
    }

    func authorization(origin: String = "https://music.youtube.com") -> String? {
        guard let sapisid, !sapisid.isEmpty else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }
}

@MainActor
final class YouTubeSessionStore: ObservableObject {
    static let shared = YouTubeSessionStore()

    @Published private(set) var session: YouTubeSession?
    @Published private(set) var statusText = "Not connected"

    private let account = "youtube-music-session"
    private let service = "org.lastwave.community"

    private init() {
        if let data = readKeychain(), let value = try? JSONDecoder().decode(YouTubeSession.self, from: data) {
            session = value
            statusText = "Connected to YouTube Music"
        }
    }

    var isConnected: Bool { session?.sapisid != nil }

    func save(cookies: [HTTPCookie]) throws {
        let youtubeCookies = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        let values = Dictionary(uniqueKeysWithValues: youtubeCookies.map { ($0.name, $0.value) })
        guard values["SAPISID"] != nil || values["__Secure-3PAPISID"] != nil else {
            throw SessionError.missingSAPISID
        }
        let cookie = youtubeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let value = YouTubeSession(cookie: cookie,
                                   visitorData: values["VISITOR_INFO1_LIVE"],
                                   dataSyncID: nil,
                                   authUser: "0")
        let data = try JSONEncoder().encode(value)
        try writeKeychain(data)
        session = value
        statusText = "Connected to YouTube Music"
    }

    func disconnect() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        session = nil
        statusText = "Not connected"
    }

    private func readKeychain() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeKeychain(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw SessionError.keychain }
    }
}

enum SessionError: LocalizedError {
    case missingSAPISID, keychain
    var errorDescription: String? {
        switch self {
        case .missingSAPISID: "YouTube login did not finish. Please complete Google sign-in first."
        case .keychain: "Could not securely save the YouTube Music session."
        }
    }
}
