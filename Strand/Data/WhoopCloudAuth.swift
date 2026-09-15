import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// WhoopCloudAuth.swift — signing in to WHOOP's cloud.
//
// Swift twin of the Android `com.noop.ingest.WhoopCloudAuth`. The OAuth 2.0 authorisation-code flow,
// which is what WHOOP's developer platform offers. The wearer is sent to WHOOP in a web session, comes
// back to `noop://whoop-oauth?code=…`, and the code is exchanged here for an access token and a
// refresh token.
//
// THE CLIENT SECRET IS A REAL WEAKNESS OF WHOOP'S FLOW, not a detail of this file. Their token endpoint
// requires `client_secret` and they offer no PKCE-only public-client mode, so any client that talks to
// it must hold one. The honest fix would be a token exchange on a server the wearer controls; short of
// that, the least-bad arrangement is the one below — the secret is the WEARER'S OWN, typed on their own
// phone, kept in their own Keychain, and absent from the shipped binary entirely.
//
// A BUILD-TIME SECRET WOULD NOT SURVIVE PUBLICATION. This app's testing builds are a downloadable
// `.ipa` from a public repository; a credential baked into that is a credential given away. So the
// build-time path (`Config/WhoopSecrets.xcconfig`) is kept only for somebody building privately, and
// the typed one is what the app actually offers.
//
// TOKENS LIVE IN THE KEYCHAIN, the same store the AI key uses — never in `UserDefaults`, and never
// written to a log.
//
// NOT CONFIGURED IS A FIRST-CLASS STATE. A clone with no credentials builds and runs; `isConfigured` is
// false and the UI simply does not offer the connection. Nothing here throws because a key is missing.

/// The wearer's own WHOOP developer-app credentials.
///
/// TWO SOURCES, AND THE TYPED ONE WINS.
///
///   1. Typed into the app and kept in the Keychain (`WhoopCredentialStore`). This is the path that
///      actually works for a sideloaded build, and it is the DEFAULT one.
///   2. Injected at build time through an untracked xcconfig into the Info.plist, the way Oura's are.
///      Useful only to somebody building the app themselves on a Mac.
///
/// WHY THE TYPED ONE IS THE DEFAULT, and not a fallback. A build-time secret is baked into the binary,
/// and this app's testing builds are published as a downloadable `.ipa` from a PUBLIC repository —
/// anyone who fetches it can unpack the secret. Since WHOOP's token endpoint requires `client_secret`
/// and their flow has no PKCE-only public-client mode, the only way for a distributed build to be
/// honest is to ship NO credential at all and let each wearer enter their own, which never leaves their
/// Keychain. The xcconfig path is kept for the private-build case and is deliberately second.
///
/// Absent credentials mean the connect flow is unavailable, which the UI says in words.
struct WhoopCredentials: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    /// Build from an Info-dictionary-shaped map. Nil unless all three keys are present and non-blank,
    /// so a build without the xcconfig cleanly disables that path rather than half-configuring it.
    static func from(_ info: [String: Any]) -> WhoopCredentials? {
        func nonBlank(_ key: String) -> String? {
            guard let s = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        guard let id = nonBlank("WHOOP_CLIENT_ID"),
              let secret = nonBlank("WHOOP_CLIENT_SECRET"),
              let redirect = nonBlank("WHOOP_REDIRECT_URI") else { return nil }
        return WhoopCredentials(clientId: id, clientSecret: secret, redirectURI: redirect)
    }

    static var fromBundle: WhoopCredentials? { from(Bundle.main.infoDictionary ?? [:]) }

    /// What the app should actually use: the wearer's own entry, else whatever the build carries.
    static var resolved: WhoopCredentials? { WhoopCredentialStore.read() ?? fromBundle }

    /// The redirect this app registers, and the one a wearer must paste into WHOOP's developer portal.
    ///
    /// NOT SOMETHING THE WEARER TYPES. It has to match the URL scheme declared in the app's Info.plist
    /// exactly, so letting it be entered would be offering a field whose only correct value is already
    /// known — and whose wrong values fail with an opaque error from WHOOP rather than from here.
    static let redirectURI = "noop://whoop-oauth"
}

// MARK: - The credentials the wearer typed
//
// Keychain-backed, this-device-only, and never written to a log or a backup. The same store the AI key
// uses, for the same reason: these are the wearer's own credentials for their own WHOOP developer app,
// and the app's job is to hold them carefully and never to transmit them anywhere except WHOOP's own
// token endpoint.

enum WhoopCredentialStore {

    private static let service = "com.noopapp.whoop.credentials"
    private static let idAccount = "client_id"
    private static let secretAccount = "client_secret"

    /// The stored pair, or nil when the wearer has not entered one.
    ///
    /// BOTH OR NEITHER. A half-entered pair would fail at the token exchange with an error from WHOOP
    /// that says nothing useful, so an incomplete entry reads here as no entry at all and the UI keeps
    /// asking for it.
    static func read() -> WhoopCredentials? {
        guard let id = KeychainItem.read(service: service, account: idAccount),
              let secret = KeychainItem.read(service: service, account: secretAccount),
              !id.isEmpty, !secret.isEmpty
        else { return nil }
        return WhoopCredentials(clientId: id, clientSecret: secret,
                                redirectURI: WhoopCredentials.redirectURI)
    }

    /// Store the pair. Either field blank clears both — see the note on `read`.
    @discardableResult
    static func save(clientId: String, clientSecret: String) -> Bool {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else {
            clear()
            return false
        }
        KeychainItem.write(id, service: service, account: idAccount)
        KeychainItem.write(secret, service: service, account: secretAccount)
        return read() != nil
    }

    /// Whether the wearer has entered a pair (as opposed to the build carrying one).
    static var isSet: Bool { read() != nil }

    /// The stored client id, for showing back what was entered.
    ///
    /// The ID ONLY. The secret is never read back into the UI: a field that re-displays a stored secret
    /// puts it on screen every time the screen is opened, for no benefit — the wearer cannot verify it
    /// by eye anyway, and re-entering it is the honest way to change it.
    static var clientId: String? { KeychainItem.read(service: service, account: idAccount) }

    static func clear() {
        KeychainItem.delete(service: service, account: idAccount)
        KeychainItem.delete(service: service, account: secretAccount)
    }
}

enum WhoopCloudAuth {

    private static let service = "com.noopapp.whoop.cloud"
    private static let accessAccount = "access_token"
    private static let refreshAccount = "refresh_token"
    private static let expiresAtKey = "whoop.cloud.expiresAt"
    private static let pendingStateKey = "whoop.cloud.pendingState"

    private static let authURL = "https://api.prod.whoop.com/oauth/oauth2/auth"
    private static let tokenURL = "https://api.prod.whoop.com/oauth/oauth2/token"

    /// What the app asks for.
    ///
    /// `offline` is the one that is not a data scope: it is what makes WHOOP return a REFRESH token,
    /// and without it the connection would die an hour after it was made and the wearer would have to
    /// sign in again every time they opened the app.
    static let scopes = "read:recovery read:cycles read:sleep read:workout read:profile offline"

    /// Refresh this long before the token actually expires, so a sync never races the clock.
    private static let expirySkew: TimeInterval = 120

    /// True when this build carries credentials at all. False is normal, not an error.
    static var isConfigured: Bool { WhoopCredentials.resolved != nil }

    /// True when the wearer has completed a sign-in and a refresh token is held.
    static var isConnected: Bool {
        (KeychainItem.read(service: service, account: refreshAccount)?.isEmpty == false)
    }

    /// The URL to open, and the `state` it is bound to.
    ///
    /// The state is random per attempt and stored, so the redirect can be checked against it — without
    /// that, any app that can claim the `noop://` scheme could hand this one a code of its own choosing.
    static func authorizeURL() -> URL? {
        guard let creds = WhoopCredentials.resolved else { return nil }
        let state = randomState()
        UserDefaults.standard.set(state, forKey: pendingStateKey)
        var components = URLComponents(string: authURL)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: creds.clientId),
            URLQueryItem(name: "redirect_uri", value: creds.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    /// Finish the flow from the redirect.
    ///
    /// Returns false for anything that is not a clean, expected redirect: a mismatched state, an error
    /// from WHOOP, a missing code, or a failed exchange. The caller shows "could not connect" rather
    /// than guessing which — the wearer's next move is the same for all of them.
    @discardableResult
    static func complete(from redirect: URL) async -> Bool {
        let expected = UserDefaults.standard.string(forKey: pendingStateKey)
        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value
        // Cleared whether or not it matched: a state is good for exactly one attempt.
        UserDefaults.standard.removeObject(forKey: pendingStateKey)
        guard let expected, !expected.isEmpty, state == expected else { return false }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return false }
        return await exchange(code: code)
    }

    /// A valid access token, refreshing when it is close to expiry, or nil when not connected.
    ///
    /// Every caller goes through this rather than reading the stored token, so there is one place that
    /// knows when a refresh is due.
    static func accessToken() async -> String? {
        let token = KeychainItem.read(service: service, account: accessAccount)
        let expiresAt = UserDefaults.standard.double(forKey: expiresAtKey)
        if let token, !token.isEmpty, Date().timeIntervalSince1970 < expiresAt - expirySkew { return token }
        guard await refresh() else { return nil }
        return KeychainItem.read(service: service, account: accessAccount)
    }

    /// Forget the connection. The tokens go; nothing that was already synced is touched.
    static func disconnect() {
        KeychainItem.delete(service: service, account: accessAccount)
        KeychainItem.delete(service: service, account: refreshAccount)
        UserDefaults.standard.removeObject(forKey: expiresAtKey)
        UserDefaults.standard.removeObject(forKey: pendingStateKey)
    }

    private static func exchange(code: String) async -> Bool {
        guard let creds = WhoopCredentials.resolved else { return false }
        return await post(form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "redirect_uri": creds.redirectURI,
        ])
    }

    private static func refresh() async -> Bool {
        guard let creds = WhoopCredentials.resolved,
              let refreshToken = KeychainItem.read(service: service, account: refreshAccount),
              !refreshToken.isEmpty
        else { return false }
        return await post(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            // WHOOP re-issues a refresh token only when `offline` is asked for again.
            "scope": "offline",
        ])
    }

    /// One token-endpoint round trip, storing whatever came back.
    ///
    /// Never throws: a dead network, a rejected refresh and a malformed body all read as false, and the
    /// connection is left exactly as it was so the next attempt can try again.
    private static func post(form: [String: String]) async -> Bool {
        guard let url = URL(string: tokenURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else { return false }

        KeychainItem.write(access, service: service, account: accessAccount)
        // A refresh response may omit the refresh token, which means KEEP the one held — a blanket
        // write would sign the wearer out on the first refresh that did not re-issue.
        if let refreshed = json["refresh_token"] as? String, !refreshed.isEmpty {
            KeychainItem.write(refreshed, service: service, account: refreshAccount)
        }
        let ttl = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        UserDefaults.standard.set(Date().timeIntervalSince1970 + ttl, forKey: expiresAtKey)
        return true
    }

    /// `application/x-www-form-urlencoded`, where a space is `+` and every reserved character goes.
    private static func formEncode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func randomState() -> String {
        (0..<24).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }
}

// MARK: - The Keychain, minimally

/// Just enough Keychain for four short strings — two tokens and the wearer's own client pair.
/// Deliberately not a general wrapper: a store this small is easier to audit than one that can do
/// everything, and these four items are all that is ever kept in it.
enum KeychainItem {

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add rather than update: an update on a missing item is an error to handle, and
        // there is nothing here worth preserving across a write.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // The tokens are useless without the device unlocked, and must not ride a backup to another
        // device — the wearer signs in again there, which is the honest outcome.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
