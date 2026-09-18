/*
 * ALEA Softphone iOS — visual voicemail (Casella) parity with Android 6.3.0-alea
 */

import Foundation
import AVFoundation
import SwiftUI
import Combine
import linphonesw

enum AleaVoicemailClient {
	struct Message: Identifiable, Equatable {
		let id: String
		let callerId: String
		let durationSec: Int
		let createdAt: String
		var read: Bool
		let transcript: String?
		let transcriptStatus: String
	}

	struct Inbox {
		let unread: Int
		let items: [Message]
	}

	enum VoicemailError: LocalizedError {
		case failed(String)
		var errorDescription: String? {
			switch self {
			case .failed(let m): return m
			}
		}
	}

	static func list(apiBase: String, appToken: String) throws -> Inbox {
		let base = AleaJoinLink.trimTrailingSlash(apiBase)
		let text = try request("GET", "\(base)/api/softphone/voicemail", appToken)
		let json = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
		let arr = (json["items"] as? [[String: Any]]) ?? []
		var out: [Message] = []
		out.reserveCapacity(arr.count)
		for o in arr {
			let id = ((o["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			if id.isEmpty { continue }
			let caller = ((o["caller_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			out.append(Message(
				id: id,
				callerId: caller.isEmpty ? "Sconosciuto" : caller,
				durationSec: (o["duration_sec"] as? Int) ?? Int((o["duration_sec"] as? Double) ?? 0),
				createdAt: (o["created_at"] as? String) ?? "",
				read: (o["read"] as? Bool) ?? false,
				transcript: {
					let t = ((o["transcript"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
					return t.isEmpty ? nil : t
				}(),
				transcriptStatus: (o["transcript_status"] as? String) ?? "pending"
			))
		}
		return Inbox(unread: (json["unread"] as? Int) ?? 0, items: out)
	}

	static func audioURL(apiBase: String, messageId: String) -> URL? {
		let base = AleaJoinLink.trimTrailingSlash(apiBase)
		return URL(string: "\(base)/api/softphone/voicemail/\(messageId)/audio")
	}

	static func markRead(apiBase: String, appToken: String, messageId: String) throws {
		_ = try request("POST", "\(AleaJoinLink.trimTrailingSlash(apiBase))/api/softphone/voicemail/\(messageId)/read", appToken)
	}

	static func delete(apiBase: String, appToken: String, messageId: String) throws {
		_ = try request("DELETE", "\(AleaJoinLink.trimTrailingSlash(apiBase))/api/softphone/voicemail/\(messageId)", appToken)
	}

	private static func request(_ method: String, _ urlStr: String, _ appToken: String) throws -> String {
		guard let url = URL(string: urlStr) else { throw VoicemailError.failed("URL non valida") }
		var req = URLRequest(url: url)
		req.httpMethod = method
		req.timeoutInterval = 30
		req.setValue("application/json", forHTTPHeaderField: "Accept")
		req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

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
		_ = sem.wait(timeout: .now() + 35)
		if let err { throw VoicemailError.failed(err.localizedDescription) }
		let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
		if !(200...299).contains(code) && code != 204 {
			let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
			let e = ((j["error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			throw VoicemailError.failed(e.isEmpty ? "Casella vocale fallita (\(code))" : e)
		}
		return text
	}
}

@MainActor
final class AleaVoicemailViewModel: ObservableObject {
	@Published var messages: [AleaVoicemailClient.Message] = []
	@Published var loading = false
	@Published var noSession = false
	@Published var errorText: String?
	@Published var playingId: String?
	@Published var unread = 0

	private var player: AVPlayer?
	private var endObserver: NSObjectProtocol?

	func refresh() {
		guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else {
			noSession = true
			messages = []
			loading = false
			return
		}
		noSession = false
		loading = true
		errorText = nil
		let api = session.apiBase
		let token = session.appToken
		DispatchQueue.global(qos: .userInitiated).async {
			do {
				let inbox = try AleaVoicemailClient.list(apiBase: api, appToken: token)
				DispatchQueue.main.async {
					self.messages = inbox.items
					self.unread = inbox.unread
					self.loading = false
				}
			} catch {
				DispatchQueue.main.async {
					self.loading = false
					self.errorText = error.localizedDescription
				}
			}
		}
	}

	func togglePlay(_ msg: AleaVoicemailClient.Message) {
		if playingId == msg.id {
			stop()
			return
		}
		stop()
		guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first,
		      let url = AleaVoicemailClient.audioURL(apiBase: session.apiBase, messageId: msg.id) else { return }

		var req = URLRequest(url: url)
		req.setValue("Bearer \(session.appToken)", forHTTPHeaderField: "Authorization")
		// AVPlayer can't easily add auth headers — download to temp then play
		loading = true
		URLSession.shared.dataTask(with: req) { data, resp, err in
			DispatchQueue.main.async {
				self.loading = false
				guard let data, err == nil, let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
					self.errorText = "Riproduzione non riuscita"
					return
				}
				let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("alea-vm-\(msg.id).wav")
				try? data.write(to: tmp)
				let item = AVPlayerItem(url: tmp)
				let p = AVPlayer(playerItem: item)
				self.player = p
				self.playingId = msg.id
				self.endObserver = NotificationCenter.default.addObserver(
					forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
				) { [weak self] _ in
					Task { @MainActor in
						self?.stop()
					}
				}
				p.play()
				if !msg.read {
					self.markRead(msg)
				}
			}
		}.resume()
	}

	func markRead(_ msg: AleaVoicemailClient.Message) {
		guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
		DispatchQueue.global().async {
			try? AleaVoicemailClient.markRead(apiBase: session.apiBase, appToken: session.appToken, messageId: msg.id)
			DispatchQueue.main.async {
				if let i = self.messages.firstIndex(where: { $0.id == msg.id }) {
					self.messages[i].read = true
				}
			}
		}
	}

	func delete(_ msg: AleaVoicemailClient.Message) {
		guard let session = AleaEnrollStore.activeSession() ?? AleaEnrollStore.allSessions().first else { return }
		if playingId == msg.id { stop() }
		DispatchQueue.global().async {
			do {
				try AleaVoicemailClient.delete(apiBase: session.apiBase, appToken: session.appToken, messageId: msg.id)
				DispatchQueue.main.async {
					self.messages.removeAll { $0.id == msg.id }
				}
			} catch {
				DispatchQueue.main.async { self.errorText = error.localizedDescription }
			}
		}
	}

	func stop() {
		player?.pause()
		player = nil
		playingId = nil
		if let endObserver {
			NotificationCenter.default.removeObserver(endObserver)
			self.endObserver = nil
		}
	}
}

struct AleaVoicemailFragment: View {
	@StateObject private var vm = AleaVoicemailViewModel()

	var body: some View {
		VStack(spacing: 0) {
			if vm.loading && vm.messages.isEmpty {
				Spacer()
				ProgressView("Caricamento casella…")
				Spacer()
			} else if vm.noSession {
				Spacer()
				Text("Accedi con enroll ALEA per vedere i messaggi")
					.multilineTextAlignment(.center)
					.foregroundStyle(Color.grayMain2c600)
					.padding()
				Spacer()
			} else if vm.messages.isEmpty {
				Spacer()
				Text("Nessun messaggio registrato")
					.foregroundStyle(Color.grayMain2c600)
				Spacer()
			} else {
				List {
					ForEach(vm.messages) { msg in
						HStack(spacing: 12) {
							Button {
								vm.togglePlay(msg)
							} label: {
								Image(systemName: vm.playingId == msg.id ? "pause.circle.fill" : "play.circle.fill")
									.font(.system(size: 32))
									.foregroundStyle(Color.orangeMain500)
							}
							.buttonStyle(.plain)

							VStack(alignment: .leading, spacing: 4) {
								HStack {
									Text(msg.callerId)
										.fontWeight(msg.read ? .regular : .bold)
										.foregroundStyle(Color.grayMain2c800)
									if !msg.read {
										Circle()
											.fill(Color.orangeMain500)
											.frame(width: 8, height: 8)
									}
								}
								Text(formatDuration(msg.durationSec) + (msg.createdAt.isEmpty ? "" : " · \(msg.createdAt)"))
									.font(.caption)
									.foregroundStyle(Color.grayMain2c500)
								if let t = msg.transcript, !t.isEmpty {
									Text(t)
										.font(.caption)
										.foregroundStyle(Color.grayMain2c600)
										.lineLimit(2)
								}
							}
							Spacer()
						}
						.padding(.vertical, 4)
						.swipeActions(edge: .trailing) {
							Button(role: .destructive) {
								vm.delete(msg)
							} label: {
								Label("Elimina", systemImage: "trash")
							}
						}
					}
				}
				.listStyle(.plain)
			}

			if let err = vm.errorText {
				Text(err)
					.font(.caption)
					.foregroundStyle(Color.redDanger500)
					.padding(8)
			}
		}
		.onAppear { vm.refresh() }
		.onDisappear { vm.stop() }
		.refreshable { vm.refresh() }
	}

	private func formatDuration(_ sec: Int) -> String {
		let m = sec / 60
		let s = sec % 60
		return String(format: "%d:%02d", m, s)
	}
}
