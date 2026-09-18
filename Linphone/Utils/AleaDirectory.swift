/*
 * ALEA Softphone iOS — directory sync parity with Android AleaDirectoryClient/Sync
 */

import Foundation
import linphonesw

enum AleaDirectoryClient {
    struct Entry {
        let extensionNumber: String
        let name: String
        let online: Bool
    }

    enum DirectoryError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return msg
            }
        }
    }

    static func fetch(apiBase: String, appToken: String) throws -> [Entry] {
        let base = AleaJoinLink.trimTrailingSlash(apiBase)
        guard let url = URL(string: "\(base)/api/softphone/directory") else {
            throw DirectoryError.failed("URL directory non valida")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

        Log.info("[ALEA Directory] GET \(url.absoluteString)")

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
            throw DirectoryError.failed(responseError.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: responseData ?? Data()) as? [String: Any]) ?? [:]
        guard (200...299).contains(responseCode) else {
            let err = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DirectoryError.failed((err?.isEmpty == false ? err! : "Directory fallita (\(responseCode))"))
        }
        let items = (json["items"] as? [[String: Any]]) ?? []
        var out: [Entry] = []
        out.reserveCapacity(items.count)
        for o in items {
            let ext = ((o["extension"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ext.isEmpty { continue }
            let nameRaw = ((o["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let online = (o["online"] as? Bool) ?? false
            out.append(Entry(extensionNumber: ext, name: nameRaw.isEmpty ? ext : nameRaw, online: online))
        }
        Log.info("[ALEA Directory] Loaded \(out.count) entries")
        return out
    }
}

enum AleaDirectorySync {
    static let friendListName = "ALEA directory"
    private static let lock = NSLock()
    private static var running = false
    private static var pollTimer: Timer?

    static func syncIfNeeded() {
        lock.lock()
        if running {
            lock.unlock()
            Log.info("[ALEA Directory Sync] Already running")
            return
        }
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            do {
                guard let session = AleaEnrollStore.activeSession() else {
                    Log.info("[ALEA Directory Sync] Skip: no enroll session — rescansiona il QR")
                    DispatchQueue.main.async {
                        ToastViewModel.shared.show("Rubrica: riscatta il QR ALEA")
                    }
                    return
                }
                let entries = try AleaDirectoryClient.fetch(apiBase: session.apiBase, appToken: session.appToken)
                CoreContext.shared.doOnCoreQueue { core in
                    // Clear Linphone-cloud-only contacts filter (same as Android)
                    if AppServices.corePreferences.contactsFilter == "sip.linphone.org" {
                        Log.warn("[ALEA Directory Sync] Clearing contacts_filter=sip.linphone.org")
                        AppServices.corePreferences.contactsFilter = ""
                    }
                    MagicSearchSingleton.shared.allContact = true
                    applyToCore(core: core, entries: entries, sipHost: session.sipHost)
                }
            } catch {
                Log.error("[ALEA Directory Sync] Sync failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    ToastViewModel.shared.show("Rubrica: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func applyToCore(core: Core, entries: [AleaDirectoryClient.Entry], sipHost: String) {
        let list: FriendList
        if let existing = core.getFriendListByName(name: friendListName) {
            list = existing
        } else {
            guard let created = try? core.createFriendList() else {
                Log.error("[ALEA Directory Sync] createFriendList failed")
                return
            }
            created.displayName = friendListName
            created.databaseStorageEnabled = true
            created.type = .Default
            core.addFriendList(list: created)
            list = created
            Log.info("[ALEA Directory Sync] Created friend list [\(friendListName)]")
        }

        for friend in list.friends {
            if (friend.refKey ?? "").hasPrefix("alea:") {
                _ = list.removeFriend(linphoneFriend: friend)
            }
        }

        var onlineCount = 0
        for entry in entries {
            let uri = "sip:\(entry.extensionNumber)@\(sipHost)"
            guard let address = core.interpretUrl(url: uri, applyInternationalPrefix: false) else { continue }
            try? address.setDisplayname(newValue: entry.name)
            guard let friend = try? core.createFriend() else { continue }
            try? friend.setName(newValue: entry.name)
            friend.refKey = "alea:\(entry.extensionNumber)"
            try? friend.setAddress(newValue: address)
            applyPresence(core: core, friend: friend, online: entry.online)
            _ = list.addLocalFriend(linphoneFriend: friend)
            if entry.online { onlineCount += 1 }
        }
        list.updateSubscriptions()
        Log.info("[ALEA Directory Sync] Applied \(entries.count) friends (online=\(onlineCount))")
        DispatchQueue.main.async {
            MagicSearchSingleton.shared.searchForContacts()
            NotificationCenter.default.post(name: NSNotification.Name("ContactLoaded"), object: nil)
        }
    }

    private static func applyPresence(core: Core, friend: Friend, online: Bool) {
        do {
            let model = try core.createPresenceModel()
            try model.setBasicstatus(newValue: online ? .Open : .Closed)
            friend.edit()
            friend.presenceModel = model
            friend.done()
        } catch {
            Log.warn("[ALEA Directory Sync] Presence apply failed for [\(friend.name ?? "?")]: \(error)")
        }
    }

    static func startPolling() {
        DispatchQueue.main.async {
            CoreContext.shared.doOnCoreQueue { core in
                AleaSipAccountInstaller.ensureTcpForEnrolledAccounts(core: core)
            }
            AleaPushRegistrar.registerPendingIfPossible()
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                AleaDirectorySync.syncIfNeeded()
            }
            if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
            syncIfNeeded()
        }
    }
}
