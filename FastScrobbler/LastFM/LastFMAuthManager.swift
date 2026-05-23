import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class LastFMAuthManager: NSObject, ObservableObject {
    enum AuthError: Error, LocalizedError {
        case missingCallbackScheme
        case invalidCallbackURL
        case missingTokenInCallback
        case failedToStartWebAuthentication
        case signInAlreadyInProgress

        var errorDescription: String? {
            switch self {
            case .missingCallbackScheme: return NSLocalizedString("Missing callback URL scheme.", comment: "")
            case .invalidCallbackURL: return NSLocalizedString("Invalid sign-in callback URL.", comment: "")
            case .missingTokenInCallback: return NSLocalizedString("Last.fm callback did not include an auth token.", comment: "")
            case .failedToStartWebAuthentication: return NSLocalizedString("Could not start Last.fm sign-in.", comment: "")
            case .signInAlreadyInProgress: return NSLocalizedString("Last.fm sign-in is already in progress.", comment: "")
            }
        }
    }

    @Published private(set) var sessionKey: String?
    @Published private(set) var username: String?

    private let usernameDefaultsKey = "FastScrobbler.lastfm.username"
    private var webAuth: ASWebAuthenticationSession?

    override init() {
        super.init()
        sessionKey = LastFMSessionStore.readSessionKey()
        username = UserDefaults.standard.string(forKey: usernameDefaultsKey)
    }

    func connect() async throws {
        guard webAuth == nil else { throw AuthError.signInAlreadyInProgress }
        let client = try LastFMClient()
        guard !LastFMSecrets.callbackScheme.isEmpty else { throw AuthError.missingCallbackScheme }
        let callback = "\(LastFMSecrets.callbackScheme)://\(LastFMSecrets.callbackPath)"
        var comps = URLComponents(string: "https://www.last.fm/api/auth/")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: LastFMSecrets.apiKey),
            URLQueryItem(name: "cb", value: callback),
        ]
        guard let url = comps.url else { throw AuthError.invalidCallbackURL }

        let callbackURL: URL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            var hasResumed = false
            let resume: (Result<URL, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let callbackURL):
                    cont.resume(returning: callbackURL)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: LastFMSecrets.callbackScheme) { callbackURL, error in
                self.webAuth = nil
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin
                {
                    resume(.failure(CancellationError()))
                    return
                }
                if let error {
                    resume(.failure(error))
                    return
                }
                guard let callbackURL else {
                    resume(.failure(AuthError.invalidCallbackURL))
                    return
                }
                resume(.success(callbackURL))
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.webAuth = session
            guard session.start() else {
                self.webAuth = nil
                resume(.failure(AuthError.failedToStartWebAuthentication))
                return
            }
        }

        let callbackComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        guard let token = callbackComps?.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            throw AuthError.missingTokenInCallback
        }

        let key = try await client.getSession(token: token)
        LastFMSessionStore.writeSessionKey(key)
        sessionKey = key
        do {
            try await refreshUserInfo()
        } catch {
            // Non-fatal: the app can still scrobble without a cached username.
        }
    }

    func disconnect() {
        LastFMSessionStore.deleteSessionKey()
        sessionKey = nil
        UserDefaults.standard.removeObject(forKey: usernameDefaultsKey)
        username = nil
    }

    func refreshUserInfoIfNeeded() async {
        guard sessionKey != nil else { return }
        guard username == nil else { return }
        do {
            try await refreshUserInfo()
        } catch {
            // Non-fatal.
        }
    }

    func refreshUserInfo() async throws {
        guard let sessionKey else { return }
        let client = try LastFMClient()
        let name = try await client.getUsername(sessionKey: sessionKey)
        UserDefaults.standard.set(name, forKey: usernameDefaultsKey)
        username = name
    }

    var profileURL: URL? {
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else { return nil }
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return URL(string: "https://www.last.fm/user/\(encoded)")
    }

    func freshProfileURL() -> URL? {
        guard let profileURL else { return nil }
        guard var components = URLComponents(url: profileURL, resolvingAgainstBaseURL: false) else {
            return profileURL
        }

        // Last.fm profile pages can lag behind a successful API scrobble when the same URL is reopened in-app.
        // Use a unique query item per tap so Safari fetches a fresh page.
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == "fs_refresh" })
        items.append(URLQueryItem(name: "fs_refresh", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url ?? profileURL
    }
}

extension LastFMAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
#elseif os(macOS)
        return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
#else
        return ASPresentationAnchor()
#endif
    }
}
