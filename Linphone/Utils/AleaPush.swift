/*
 * ALEA Softphone iOS — register PushKit VoIP token with PBX
 * so locked-phone incoming calls can wake the app via APNs.
 */

import Foundation
import PushKit
import UIKit
import linphonesw

enum AleaPushRegistrar {
    private static let pendingTokenKey = "alea_pending_voip_push_token"
    private static let lock = NSLock()

    /// Hex VoIP device token from PushKit.
    static func onVoipToken(_ data: Data) {
        let hex = data.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: pendingTokenKey)
        Log.info("[ALEA Push] VoIP token updated (\(hex.prefix(12))…)")
        registerPendingIfPossible()
    }

    static func registerPendingIfPossible() {
        lock.lock()
        defer { lock.unlock() }
        guard let token = UserDefaults.standard.string(forKey: pendingTokenKey), !token.isEmpty else {
            return
        }
        guard let session = AleaEnrollStore.activeSession(), !session.deviceId.isEmpty, !session.appToken.isEmpty else {
            Log.info("[ALEA Push] Token saved; waiting for enroll session")
            return
        }
        let apiBase = session.apiBase
        let appToken = session.appToken
        let deviceId = session.deviceId
        DispatchQueue.global(qos: .utility).async {
            do {
                try postRegister(apiBase: apiBase, appToken: appToken, deviceId: deviceId, pushToken: token)
                Log.info("[ALEA Push] Registered VoIP token with PBX")
            } catch {
                Log.error("[ALEA Push] Register failed: \(error.localizedDescription)")
            }
        }
    }

    private static func postRegister(apiBase: String, appToken: String, deviceId: String, pushToken: String) throws {
        let base = AleaJoinLink.trimTrailingSlash(apiBase)
        guard let url = URL(string: "\(base)/api/softphone/push/register") else {
            throw NSError(domain: "alea", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL push non valida"])
        }
        let body: [String: Any] = [
            "device_id": deviceId,
            "push_token": pushToken,
            "platform": "ios"
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = json

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var code = 0
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, resp, e in
            data = d
            err = e
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        if let err { throw err }
        guard (200...299).contains(code) else {
            let msg = String(data: data ?? Data(), encoding: .utf8) ?? ""
            throw NSError(domain: "alea", code: code, userInfo: [NSLocalizedDescriptionKey: "push/register \(code) \(msg)"])
        }
    }

    /// Handle ALEA VoIP push while app may be suspended: CallKit + wake SIP.
    static func handleIncomingPush(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let dict = payload as? [String: Any] ?? [:]
        let callId = (dict["call_id"] as? String) ?? ""
        let caller = (dict["caller"] as? String) ?? "Chiamata"
        Log.info("[ALEA Push] Incoming voip push caller=\(caller) call_id=\(callId)")

        // Wake / ensure core then process push + refresh register
        CoreContext.shared.doOnCoreQueue { core in
            if core.globalState != .On {
                try? core.start()
            }
            if !callId.isEmpty {
                core.processPushNotification(callId: callId)
            }
            if let account = core.defaultAccount {
                account.refreshRegister()
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }
}
