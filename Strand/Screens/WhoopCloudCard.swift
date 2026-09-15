import SwiftUI
import StrandDesign
import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// WhoopCloudCard.swift — connecting the WHOOP account, and saying what happened.
//
// The UI half of the cloud lane. Three states, and each of them says something the wearer can act on:
//
//   · NO KEYS YET — two fields for the wearer's own WHOOP developer-app credentials, plus the redirect
//     URL and the scope list to paste into WHOOP's portal. The shipped build carries no credentials of
//     its own, deliberately: the `.ipa` is public, and a secret compiled into it is a secret given away.
//   · NOT CONNECTED — a Connect button, which opens WHOOP's own consent page.
//   · CONNECTED — what the last sync actually said, per endpoint, and a button to sync now.
//
// THE NOTE IS SHOWN, NOT SWALLOWED. The Android lane learned this the hard way: a failed request that
// returned nothing looked exactly like an account with no data, and the only thing on screen was three
// dashes. A sync that cannot get something has to be able to say which thing and why, so the per-
// endpoint line goes on the card verbatim.

struct WhoopCloudCard: View {
    @EnvironmentObject var repo: Repository

    @State private var connected = WhoopCloudAuth.isConnected
    @State private var busy = false
    @State private var note: String? = WhoopCloudSync.lastNote
    @State private var lastResult: String?
    /// Whether the credential fields are showing. Open by default only when there is nothing stored,
    /// so a wearer who has already entered theirs is not shown two empty boxes every visit.
    @State private var editingCredentials = false
    @State private var clientIdField = WhoopCredentialStore.clientId ?? ""
    /// NEVER seeded from storage — see the note on `WhoopCredentialStore.clientId`.
    @State private var clientSecretField = ""
    @State private var credentialsSaved = WhoopCredentialStore.isSet

    private let auth = WhoopWebAuth()

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "icloud")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WHOOP cloud")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Their own recovery, strain and sleep scores")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }

                if !WhoopCloudAuth.isConfigured || editingCredentials {
                    credentialFields
                } else if connected {
                    if let lastResult {
                        Text(lastResult)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let note {
                        // Verbatim, including the HTTP status: this line is the difference between
                        // fixing a scope problem and guessing at one.
                        Text(note)
                            .font(StrandFont.caption)
                            .monospaced()
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button("Sync now") { Task { await syncNow() } }
                            .disabled(busy)
                        Button("Disconnect") {
                            WhoopCloudAuth.disconnect()
                            connected = false
                            lastResult = nil
                        }
                        .foregroundStyle(StrandPalette.statusCritical)
                    }
                    .font(StrandFont.footnote)
                } else {
                    Text("Sign in once. NOOP then reads a year of your cycles, recoveries and nights, "
                         + "and keeps them up to date.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    HStack(spacing: 12) {
                        Button("Connect WHOOP") { Task { await connect() } }
                            .disabled(busy)
                        if credentialsSaved {
                            Button("Change app keys") { editingCredentials = true }
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .font(StrandFont.footnote)
                }
            }
        }
        .task { connected = WhoopCloudAuth.isConnected }
    }

    // MARK: - The wearer's own developer-app keys
    //
    // WHY THIS IS TYPED IN THE APP rather than baked into the build: the shipped `.ipa` is public, and a
    // credential compiled into it is a credential given away. These are the wearer's own, they go
    // straight to the Keychain, and they are sent to exactly one place — WHOOP's token endpoint.
    //
    // THE REDIRECT IS NOT A FIELD. It has to match the URL scheme in the app's Info.plist exactly, so
    // offering it would be offering a box whose only correct value is already known. It is shown
    // instead, to be copied into WHOOP's portal, which is the half the wearer genuinely has to do.

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create a free app at developer.whoop.com, then paste its two keys here. They stay in "
                 + "this iPhone's Keychain — this build ships with none of its own.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Client ID", text: $clientIdField)
                .textFieldStyle(.roundedBorder)
                .font(StrandFont.footnote)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            SecureField("Client secret", text: $clientSecretField)
                .textFieldStyle(.roundedBorder)
                .font(StrandFont.footnote)

            // The two things to paste into WHOOP's portal, spelled out so they are not guessed at.
            VStack(alignment: .leading, spacing: 2) {
                Text("In WHOOP's portal, set the redirect URL to:")
                Text(WhoopCredentials.redirectURI).monospaced()
                Text("and tick the scopes: \(WhoopCloudAuth.scopes)")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Save keys") { saveCredentials() }
                    .disabled(clientIdField.trimmingCharacters(in: .whitespaces).isEmpty
                              || clientSecretField.isEmpty)
                if credentialsSaved {
                    Button("Forget keys") {
                        // The tokens go with them: a connection made under one app's credentials is
                        // meaningless under another's, and leaving them would look connected while
                        // every refresh quietly failed.
                        WhoopCloudAuth.disconnect()
                        WhoopCredentialStore.clear()
                        credentialsSaved = false
                        connected = false
                        clientIdField = ""
                        clientSecretField = ""
                        lastResult = nil
                    }
                    .foregroundStyle(StrandPalette.statusCritical)
                }
                if editingCredentials, credentialsSaved {
                    Button("Cancel") { editingCredentials = false }
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .font(StrandFont.footnote)
        }
    }

    private func saveCredentials() {
        guard WhoopCredentialStore.save(clientId: clientIdField, clientSecret: clientSecretField) else {
            lastResult = "Those keys could not be saved."
            return
        }
        credentialsSaved = true
        editingCredentials = false
        // Cleared from memory the moment it is stored. Nothing on this screen ever needs it again, and
        // a secret sitting in view state outlives the screen that showed it.
        clientSecretField = ""
        lastResult = "Keys saved. Now sign in to WHOOP."
        SystemHaptics.play(.confirm)
    }

    private func connect() async {
        guard let url = WhoopCloudAuth.authorizeURL() else { return }
        busy = true
        defer { busy = false }
        guard let callback = await auth.run(url: url, scheme: callbackScheme) else {
            lastResult = "Sign-in was cancelled."
            return
        }
        guard await WhoopCloudAuth.complete(from: callback) else {
            // One message for every failure mode on purpose: a mismatched state, an error from WHOOP
            // and a dead network all have the same fix from here, which is to try again.
            lastResult = "Could not complete the sign-in. Try again."
            return
        }
        connected = true
        SystemHaptics.play(.confirm)
        await syncNow()
    }

    private func syncNow() async {
        busy = true
        defer { busy = false }
        let result = await WhoopCloudSync.sync(repo: repo)
        note = result.note
        lastResult = result.connected
            ? "Synced \(result.days) day\(result.days == 1 ? "" : "s")."
            : "Not signed in."
        connected = result.connected
    }

    /// The scheme half of the redirect, which is what the web session watches for.
    private var callbackScheme: String? {
        WhoopCredentials.fromBundle.flatMap { URL(string: $0.redirectURI)?.scheme }
    }
}

// MARK: - The web session
//
// `ASWebAuthenticationSession` in a shape SwiftUI can await. It has to be an `NSObject` to supply the
// presentation anchor, and it has to be held for the life of the session — a local that goes out of
// scope takes the sheet down with it, which reads as the browser closing itself the moment it opens.

@MainActor
private final class WhoopWebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?

    func run(url: URL, scheme: String?) async -> URL? {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, _ in
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            // NOT ephemeral: a wearer who is signed in to WHOOP in Safari should not have to type their
            // password again, which is the whole reason this is a system web session and not a WKWebView.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(returning: nil) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
            #elseif os(macOS)
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
