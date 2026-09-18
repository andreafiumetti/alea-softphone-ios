/*
 * ALEA Softphone iOS — enroll parity with Android 6.3.0-alea
 * Join link, POST /api/softphone/enroll, multi-session store, SIP account install.
 */

import Foundation
import UIKit
import linphonesw

enum AleaJoinLink {
    struct Parsed {
        let apiBase: String
        let token: String
    }

    static func parse(_ raw: String?) -> Parsed? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), let parsed = parseURL(url) {
            return parsed
        }
        return parseLoose(raw)
    }

    static func parseURL(_ url: URL) -> Parsed? {
        let scheme = (url.scheme ?? "").lowercased()

        if scheme == "alea" {
            // alea://join/{token}?server=https://host
            let host = (url.host ?? "").lowercased()
            guard host == "join" else { return nil }
            let token = url.pathComponents.filter { $0 != "/" }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else { return nil }
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let server = comps.queryItems?.first(where: { $0.name == "server" })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !server.isEmpty else {
                return nil
            }
            return Parsed(apiBase: Self.trimTrailingSlash(server), token: token)
        }

        if scheme == "http" || scheme == "https" {
            // https://host[:port]/join/{token}
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, parts[0].lowercased() == "join" else { return nil }
            let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let host = url.host else { return nil }
            var apiBase = "\(scheme)://\(host)"
            if let port = url.port {
                apiBase += ":\(port)"
            }
            return Parsed(apiBase: apiBase, token: token)
        }
        return nil
    }

    private static func parseLoose(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let joinRange = trimmed.range(of: "/join/", options: .caseInsensitive) else { return nil }
        let apiBase = String(trimmed[..<joinRange.lowerBound])
        let afterJoin = String(trimmed[joinRange.upperBound...])
        let token = afterJoin.split(separator: "/", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty, token.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Parsed(apiBase: Self.trimTrailingSlash(apiBase), token: token)
    }

    static func trimTrailingSlash(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

enum AleaEnrollClient {
    struct Result {
        let extensionNumber: String
        let displayName: String
        let sipUsername: String
        let sipPassword: String
        let sipHost: String
        let sipPort: Int
        let transport: String
        let deviceId: String
        let appToken: String
        let apiBase: String
    }

    enum EnrollError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return msg
            }
        }
    }

    static func enroll(apiBase: String, token: String) throws -> Result {
        let base = AleaJoinLink.trimTrailingSlash(apiBase)
        guard let url = URL(string: "\(base)/api/softphone/enroll") else {
            throw EnrollError.failed("URL enroll non valida")
        }

        let device = UIDevice.current
        let body: [String: Any] = [
            "token": token,
            "device_name": device.name,
            "device_model": device.model,
            "platform": "ios",
            "device_uuid": UUID().uuidString
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        Log.info("[ALEA Enroll] POST \(url.absoluteString)")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode = 0
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            responseCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 25)

        if let responseError {
            throw EnrollError.failed(responseError.localizedDescription)
        }
        let text = String(data: responseData ?? Data(), encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: responseData ?? Data()) as? [String: Any]) ?? [:]

        guard (200...299).contains(responseCode) else {
            let err = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EnrollError.failed((err?.isEmpty == false ? err! : "Enroll fallito (\(responseCode))"))
        }

        let ext = (json["extension"] as? String) ?? ""
        let sipUser = ((json["sip_username"] as? String) ?? "").isEmpty ? ext : (json["sip_username"] as? String) ?? ext
        let transport = ((json["transport"] as? String) ?? "tcp").isEmpty ? "tcp" : ((json["transport"] as? String) ?? "tcp")
        let apiOut = ((json["api_base"] as? String) ?? "").isEmpty ? base : ((json["api_base"] as? String) ?? base)

        return Result(
            extensionNumber: ext,
            displayName: (json["display_name"] as? String) ?? "",
            sipUsername: sipUser,
            sipPassword: (json["sip_password"] as? String) ?? "",
            sipHost: (json["sip_host"] as? String) ?? "",
            sipPort: (json["sip_port"] as? Int) ?? 5060,
            transport: transport,
            deviceId: (json["device_id"] as? String) ?? "",
            appToken: (json["app_token"] as? String) ?? "",
            apiBase: AleaJoinLink.trimTrailingSlash(apiOut)
        )
    }
}

enum AleaEnrollStore {
    private static let prefsKey = "alea_enroll"
    private static let keySessions = "sessions_json"
    private static let keyActive = "active_key"

    struct Session {
        let apiBase: String
        let appToken: String
        let deviceId: String
        let extensionNumber: String
        let sipHost: String

        var key: String { Self.sessionKey(extensionNumber, sipHost) }

        static func sessionKey(_ extensionNumber: String, _ sipHost: String) -> String {
            "\(extensionNumber.trimmingCharacters(in: .whitespacesAndNewlines))@\(sipHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }

    private static var defaults: UserDefaults { .standard }

    static func save(_ result: AleaEnrollClient.Result) {
        let session = Session(
            apiBase: AleaJoinLink.trimTrailingSlash(result.apiBase),
            appToken: result.appToken.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceId: result.deviceId.trimmingCharacters(in: .whitespacesAndNewlines),
            extensionNumber: result.extensionNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            sipHost: result.sipHost.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !session.extensionNumber.isEmpty, !session.sipHost.isEmpty, !session.appToken.isEmpty else {
            Log.error("[ALEA Enroll Store] Refusing to save incomplete session")
            return
        }
        var map = loadAll()
        map[session.key] = session
        persist(map, activeKey: session.key)
        Log.info("[ALEA Enroll Store] Saved enroll meta for \(session.key) api=\(session.apiBase) (sessions=\(map.count))")
    }

    static func hasSession() -> Bool { activeSession() != nil }

    static func activeSession() -> Session? {
        let map = loadAll()
        if map.isEmpty { return nil }
        let active = defaults.string(forKey: keyActive) ?? ""
        return map[active] ?? map.values.first
    }

    static func allSessions() -> [Session] { Array(loadAll().values) }

    private static func persist(_ map: [String: Session], activeKey: String) {
        let arr: [[String: String]] = map.values.map {
            [
                "api_base": $0.apiBase,
                "app_token": $0.appToken,
                "device_id": $0.deviceId,
                "extension": $0.extensionNumber,
                "sip_host": $0.sipHost
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: keySessions)
        }
        defaults.set(activeKey, forKey: keyActive)
    }

    private static func loadAll() -> [String: Session] {
        guard let raw = defaults.string(forKey: keySessions), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var out: [String: Session] = [:]
        for o in arr {
            let s = Session(
                apiBase: AleaJoinLink.trimTrailingSlash((o["api_base"] as? String) ?? ""),
                appToken: ((o["app_token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: ((o["device_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                extensionNumber: ((o["extension"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                sipHost: ((o["sip_host"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if !s.extensionNumber.isEmpty && !s.sipHost.isEmpty && !s.appToken.isEmpty {
                out[s.key] = s
            }
        }
        return out
    }
}

enum AleaSipAccountInstaller {
    enum Outcome {
        case ok(Account)
        case error(String)
    }

    static func install(core: Core, enroll: AleaEnrollClient.Result) -> Outcome {
        let user = enroll.sipUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = enroll.sipHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty || host.isEmpty || enroll.sipPassword.isEmpty {
            return .error("Credenziali SIP incomplete dall'enroll")
        }

        do {
            let identity = try Factory.Instance.createAddress(addr: "sip:\(user)@\(host)")
            let dn = enroll.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dn.isEmpty {
                try? identity.setDisplayname(newValue: dn)
            }

            let transport: TransportType
            switch enroll.transport.lowercased() {
            case "tls", "sips": transport = .Tls
            case "udp": transport = .Udp
            default: transport = .Tcp // tcp, blank, unknown — mobile-friendly
            }

            let serverUri: String
            if enroll.sipPort > 0 && enroll.sipPort != 5060 {
                serverUri = "sip:\(host):\(enroll.sipPort)"
            } else {
                serverUri = "sip:\(host)"
            }
            let server = try Factory.Instance.createAddress(addr: serverUri)
            try server.setTransport(newValue: transport)

            for old in core.authInfoList {
                if (old.username ?? "").caseInsensitiveCompare(user) == .orderedSame {
                    core.removeAuthInfo(info: old)
                }
            }
            let auth = try Factory.Instance.createAuthInfo(
                username: user,
                userid: "",
                passwd: enroll.sipPassword,
                ha1: "",
                realm: "",
                domain: host
            )
            core.addAuthInfo(info: auth)

            let found = core.accountList.first { account in
                guard let id = account.params?.identityAddress else { return false }
                return id.weakEqual(address2: identity) ||
                    ((id.username ?? "").caseInsensitiveCompare(user) == .orderedSame &&
                     (id.domain ?? "").caseInsensitiveCompare(host) == .orderedSame)
            }

            if let found {
                Log.info("[ALEA SIP Install] Updating existing account \(identity.asStringUriOnly()) from QR enroll")
                if let params = found.params?.clone() {
                    try params.setIdentityaddress(newValue: identity)
                    try params.setServeraddress(newValue: server)
                    params.registerEnabled = true
                    params.instantMessagingEncryptionMandatory = false
                    found.params = params
                }
                core.defaultAccount = found
                found.refreshRegister()
                return .ok(found)
            }

            let params = try core.createAccountParams()
            try params.setIdentityaddress(newValue: identity)
            try params.setServeraddress(newValue: server)
            params.registerEnabled = true
            params.instantMessagingEncryptionMandatory = false

            let account = try core.createAccount(params: params)
            try core.addAccount(account: account)
            core.defaultAccount = account
            Log.info("[ALEA SIP Install] Added account \(identity.asStringUriOnly()) transport=\(transport)")
            return .ok(account)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

enum AleaEnrollFlow {
    /// Runs enroll + SIP install. Call from background; SIP install hops onto core queue.
    static func handleJoinLink(_ raw: String, completion: @escaping (Bool, String) -> Void) {
        guard let parsed = AleaJoinLink.parse(raw) else {
            completion(false, "Link ALEA non valido")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try AleaEnrollClient.enroll(apiBase: parsed.apiBase, token: parsed.token)
                AleaEnrollStore.save(result)
                CoreContext.shared.doOnCoreQueue { core in
                    switch AleaSipAccountInstaller.install(core: core, enroll: result) {
                    case .ok:
                        DispatchQueue.main.async {
                            ToastViewModel.shared.show("Account ALEA configurato")
                            CoreContext.shared.doOnCoreQueue { core in
                                AleaSipAccountInstaller.ensureTcpForEnrolledAccounts(core: core)
                            }
                            AleaPushRegistrar.registerPendingIfPossible()
                            AleaDirectorySync.syncIfNeeded()
                            completion(true, "ok")
                        }
                    case .error(let msg):
                        DispatchQueue.main.async {
                            ToastViewModel.shared.show("Enroll fallito")
                            completion(false, msg)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    ToastViewModel.shared.show("Enroll fallito")
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}

extension AleaSipAccountInstaller {
    /// Migra account ALEA già enrollati da UDP → TCP (senza riscan QR).
    static func ensureTcpForEnrolledAccounts(core: Core) {
        guard AleaEnrollStore.hasSession() else { return }
        for account in core.accountList {
            guard let id = account.params?.identityAddress else { continue }
            let user = (id.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = (id.domain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !domain.isEmpty else { continue }
            let sessions = AleaEnrollStore.allSessions()
            let match = sessions.contains {
                $0.extensionNumber.caseInsensitiveCompare(user) == .orderedSame &&
                $0.sipHost.caseInsensitiveCompare(domain) == .orderedSame
            }
            guard match else { continue }
            guard let params = account.params?.clone() else { continue }
            var server = params.serverAddress
            if server == nil {
                server = try? Factory.Instance.createAddress(addr: "sip:\(domain)")
            }
            guard let server else { continue }
            if server.transport == .Tcp || server.transport == .Tls { continue }
            do {
                try server.setTransport(newValue: .Tcp)
                try params.setServeraddress(newValue: server)
                params.registerEnabled = true
                account.params = params
                account.refreshRegister()
                Log.info("[ALEA SIP Install] Migrated \(id.asStringUriOnly()) to TCP")
            } catch {
                Log.warn("[ALEA SIP Install] TCP migrate failed: \(error)")
            }
        }
    }
}

