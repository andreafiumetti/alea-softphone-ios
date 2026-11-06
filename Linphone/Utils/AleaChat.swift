/*
 * ALEA Softphone iOS — group chat via PBX API (device-local files).
 * No Flexisip / Linphone cloud chat.
 */

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AleaChatClient {
    struct Group: Identifiable {
        let id: String
        let name: String
        let memberCount: Int
        let updatedAt: String
    }

    struct Attachment {
        let id: String
        let filename: String
        let mime: String
        let sizeBytes: Int64
        let available: Bool
    }

    struct Message: Identifiable {
        let id: String
        let senderExtension: String
        let senderDisplayName: String
        let body: String?
        let createdAt: String
        let attachment: Attachment?
    }

    enum ChatError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return msg
            }
        }
    }

    static func listGroups(apiBase: String, appToken: String) throws -> [Group] {
        let data = try request(method: "GET", url: "\(trim(apiBase))/api/softphone/chat/groups", token: appToken)
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let arr = json["groups"] as? [[String: Any]] ?? []
        return arr.compactMap { o in
            guard let id = (o["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            return Group(
                id: id,
                name: (o["name"] as? String) ?? "",
                memberCount: o["member_count"] as? Int ?? 0,
                updatedAt: (o["updated_at"] as? String) ?? ""
            )
        }
    }

    static func createGroup(apiBase: String, appToken: String, name: String, members: [String]) throws -> String {
        let data = try request(
            method: "POST",
            url: "\(trim(apiBase))/api/softphone/chat/groups",
            token: appToken,
            jsonBody: ["name": name, "member_extensions": members]
        )
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let id = json["id"] as? String, !id.isEmpty else {
            throw ChatError.failed("risposta gruppo non valida")
        }
        return id
    }

    /// Creator deletes the group; other members leave.
    @discardableResult
    static func deleteOrLeaveGroup(apiBase: String, appToken: String, groupId: String) throws -> String {
        let data = try request(
            method: "DELETE",
            url: "\(trim(apiBase))/api/softphone/chat/groups/\(groupId)",
            token: appToken
        )
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["status"] as? String) ?? "deleted"
    }

    static func listMessages(apiBase: String, appToken: String, groupId: String) throws -> [Message] {
        let data = try request(
            method: "GET",
            url: "\(trim(apiBase))/api/softphone/chat/groups/\(groupId)/messages?limit=200",
            token: appToken
        )
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let arr = json["messages"] as? [[String: Any]] ?? []
        return arr.compactMap { parseMessage($0) }
    }

    static func postText(apiBase: String, appToken: String, groupId: String, body: String) throws {
        _ = try request(
            method: "POST",
            url: "\(trim(apiBase))/api/softphone/chat/groups/\(groupId)/messages",
            token: appToken,
            jsonBody: ["body": body]
        )
    }

    static func postFile(
        apiBase: String,
        appToken: String,
        groupId: String,
        body: String,
        fileURL: URL,
        mime: String
    ) throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: "\(trim(apiBase))/api/softphone/chat/groups/\(groupId)/messages") else {
            throw ChatError.failed("URL non valida")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var data = Data()
        if !body.isEmpty {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"body\"\r\n\r\n".data(using: .utf8)!)
            data.append(body.data(using: .utf8)!)
            data.append("\r\n".data(using: .utf8)!)
        }
        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = data

        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var respData: Data?
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, resp, e in
            respData = d
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 130)
        if let err { throw ChatError.failed(err.localizedDescription) }
        guard (200...299).contains(status) else {
            let msg = String(data: respData ?? Data(), encoding: .utf8) ?? ""
            throw ChatError.failed("upload fallito (\(status)) \(msg)")
        }
    }

    static func downloadAttachment(
        apiBase: String,
        appToken: String,
        attachmentId: String,
        to dest: URL
    ) throws {
        guard let url = URL(string: "\(trim(apiBase))/api/softphone/chat/attachments/\(attachmentId)") else {
            throw ChatError.failed("URL allegato non valida")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var status = 0
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, resp, e in
            outData = d
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 130)
        if let err { throw ChatError.failed(err.localizedDescription) }
        guard (200...299).contains(status), let outData else {
            throw ChatError.failed("download fallito (\(status))")
        }
        try outData.write(to: dest, options: .atomic)
    }

    static func localChatDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("alea-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func parseMessage(_ o: [String: Any]) -> Message? {
        guard let id = o["id"] as? String else { return nil }
        var att: Attachment?
        if let a = o["attachment"] as? [String: Any], let aid = a["id"] as? String {
            att = Attachment(
                id: aid,
                filename: a["filename"] as? String ?? "file",
                mime: a["mime"] as? String ?? "application/octet-stream",
                sizeBytes: (a["size_bytes"] as? NSNumber)?.int64Value ?? 0,
                available: a["available"] as? Bool ?? false
            )
        }
        return Message(
            id: id,
            senderExtension: o["sender_extension"] as? String ?? "",
            senderDisplayName: o["sender_display_name"] as? String ?? "",
            body: o["body"] as? String,
            createdAt: o["created_at"] as? String ?? "",
            attachment: att
        )
    }

    private static func trim(_ s: String) -> String {
        AleaJoinLink.trimTrailingSlash(s)
    }

    private static func request(
        method: String,
        url: String,
        token: String,
        jsonBody: [String: Any]? = nil
    ) throws -> Data {
        guard let u = URL(string: url) else { throw ChatError.failed("URL non valida") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var status = 0
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, resp, e in
            data = d
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        if let err { throw ChatError.failed(err.localizedDescription) }
        guard (200...299).contains(status), let data else {
            let msg = String(data: data ?? Data(), encoding: .utf8) ?? ""
            throw ChatError.failed("chat API \(status) \(msg)")
        }
        return data
    }
}

// MARK: - View models & UI

final class AleaChatGroupsViewModel: ObservableObject {
    @Published var groups: [AleaChatClient.Group] = []
    @Published var loading = false
    @Published var errorText: String?
    @Published var noSession = false

    func refresh() {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else {
            noSession = true
            groups = []
            return
        }
        noSession = false
        loading = true
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try AleaChatClient.listGroups(apiBase: session.apiBase, appToken: session.appToken)
                DispatchQueue.main.async {
                    self.groups = list
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func deleteOrLeave(_ group: AleaChatClient.Group) {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try AleaChatClient.deleteOrLeaveGroup(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    groupId: group.id
                )
                DispatchQueue.main.async { self.refresh() }
            } catch {
                DispatchQueue.main.async { self.errorText = error.localizedDescription }
            }
        }
    }
}

final class AleaChatThreadViewModel: ObservableObject {
    let groupId: String
    let groupName: String
    @Published var messages: [AleaChatClient.Message] = []
    @Published var draft = ""
    @Published var loading = false
    @Published var sending = false
    @Published var errorText: String?

    init(groupId: String, groupName: String) {
        self.groupId = groupId
        self.groupName = groupName
    }

    func refresh() {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else {
            errorText = "Enroll softphone richiesto"
            return
        }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try AleaChatClient.listMessages(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    groupId: self.groupId
                )
                DispatchQueue.main.async {
                    self.messages = list
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        sending = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AleaChatClient.postText(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    groupId: self.groupId,
                    body: text
                )
                DispatchQueue.main.async {
                    self.draft = ""
                    self.sending = false
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.sending = false
                }
            }
        }
    }

    func sendFile(url: URL) {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try AleaChatClient.postFile(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    groupId: self.groupId,
                    body: body,
                    fileURL: url,
                    mime: mime
                )
                // Keep a local copy under Documents/alea-chat
                let dest = AleaChatClient.localChatDir().appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async {
                    self.draft = ""
                    self.sending = false
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.sending = false
                }
            }
        }
    }

    func download(_ att: AleaChatClient.Attachment) {
        guard att.available else {
            errorText = "Allegato scaduto sul centralino (resta solo se già sul telefono)."
            return
        }
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        let dest = AleaChatClient.localChatDir().appendingPathComponent(att.filename)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AleaChatClient.downloadAttachment(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    attachmentId: att.id,
                    to: dest
                )
                DispatchQueue.main.async {
                    ToastViewModel.shared.show("Salvato: \(att.filename)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                }
            }
        }
    }
}

struct AleaChatFragment: View {
    @StateObject private var vm = AleaChatGroupsViewModel()
    @State private var showCreate = false

    var body: some View {
        // iOS 15 deployment target: NavigationView (not NavigationStack)
        NavigationView {
            VStack(spacing: 0) {
                if vm.loading && vm.groups.isEmpty {
                    Spacer()
                    ProgressView("Caricamento gruppi…")
                    Spacer()
                } else if vm.noSession {
                    Spacer()
                    Text("Enroll softphone richiesto per i Gruppi ALEA")
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color.grayMain2c600)
                        .padding()
                    Spacer()
                } else if vm.groups.isEmpty {
                    Spacer()
                    Text("Nessun gruppo. Tocca + per crearne uno.")
                        .foregroundColor(Color.grayMain2c600)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(vm.groups) { g in
                            NavigationLink(destination: AleaChatThreadView(groupId: g.id, groupName: g.name)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(g.name)
                                        .fontWeight(.semibold)
                                        .foregroundColor(Color.grayMain2c800)
                                    Text("\(g.memberCount) membri")
                                        .font(.caption)
                                        .foregroundColor(Color.grayMain2c500)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                guard vm.groups.indices.contains(i) else { continue }
                                vm.deleteOrLeave(vm.groups[i])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
                if let err = vm.errorText {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Color.redDanger500)
                        .padding(8)
                }
            }
            .navigationTitle("Gruppi ALEA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(vm.noSession)
                }
            }
            .sheet(isPresented: $showCreate) {
                AleaChatCreateView {
                    showCreate = false
                    vm.refresh()
                }
            }
            .onAppear { vm.refresh() }
        }
        .navigationViewStyle(.stack)
    }
}

struct AleaChatThreadView: View {
    @StateObject private var vm: AleaChatThreadViewModel
    @State private var showPicker = false

    init(groupId: String, groupName: String) {
        _vm = StateObject(wrappedValue: AleaChatThreadViewModel(groupId: groupId, groupName: groupName))
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.loading && vm.messages.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(vm.messages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.senderDisplayName.isEmpty ? msg.senderExtension : msg.senderDisplayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(Color.orangeMain500)
                            if let body = msg.body, !body.isEmpty {
                                Text(body)
                                    .foregroundColor(Color.grayMain2c800)
                            }
                            if let att = msg.attachment {
                                Button {
                                    vm.download(att)
                                } label: {
                                    Label(att.filename, systemImage: "paperclip")
                                        .font(.caption)
                                }
                                .disabled(!att.available)
                            }
                            Text(msg.createdAt)
                                .font(.caption2)
                                .foregroundColor(Color.grayMain2c500)
                        }
                        .padding(.vertical, 2)
                        .id(msg.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            if let err = vm.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Color.redDanger500)
                    .padding(4)
            }
            HStack(spacing: 8) {
                Button { showPicker = true } label: {
                    Image(systemName: "paperclip")
                }
                .disabled(vm.sending)
                TextField("Messaggio", text: $vm.draft)
                    .textFieldStyle(.roundedBorder)
                Button {
                    vm.sendText()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(vm.sending || vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .navigationTitle(vm.groupName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.refresh() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.sendFile(url: url)
            }
        }
    }
}

struct AleaChatCreateView: View {
    var onDone: () -> Void
    @State private var name = ""
    @State private var directory: [AleaDirectoryClient.Entry] = []
    @State private var selected = Set<String>()
    @State private var errorText: String?
    @State private var saving = false
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                TextField("Nome gruppo", text: $name)
                Section(header: Text("Interni")) {
                    ForEach(directory, id: \.extensionNumber) { e in
                        Button {
                            if selected.contains(e.extensionNumber) {
                                selected.remove(e.extensionNumber)
                            } else {
                                selected.insert(e.extensionNumber)
                            }
                        } label: {
                            HStack {
                                Text(e.name)
                                Spacer()
                                Text(e.extensionNumber)
                                    .foregroundColor(Color.grayMain2c500)
                                if selected.contains(e.extensionNumber) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.orangeMain500)
                                }
                            }
                        }
                    }
                }
                if let errorText = errorText {
                    Text(errorText).foregroundColor(Color.redDanger500)
                }
            }
            .navigationTitle("Nuovo gruppo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") { create() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty)
                }
            }
            .onAppear { loadDirectory() }
        }
        .navigationViewStyle(.stack)
    }

    private func loadDirectory() {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        DispatchQueue.global().async {
            do {
                let entries = try AleaDirectoryClient.fetch(apiBase: session.apiBase, appToken: session.appToken)
                DispatchQueue.main.async { self.directory = entries }
            } catch {
                DispatchQueue.main.async { self.errorText = error.localizedDescription }
            }
        }
    }

    private func create() {
        guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
        saving = true
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = Array(selected)
        DispatchQueue.global().async {
            do {
                _ = try AleaChatClient.createGroup(
                    apiBase: session.apiBase,
                    appToken: session.appToken,
                    name: n,
                    members: members
                )
                DispatchQueue.main.async {
                    self.saving = false
                    onDone()
                    self.presentationMode.wrappedValue.dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.saving = false
                }
            }
        }
    }
}
