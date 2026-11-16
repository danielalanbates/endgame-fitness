//
//  SafetyViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Reporting, blocking and getting help (API_V2 §4). Names, bios, posts,
//  comments and guilds are user-generated, so every one of them can be
//  reported, any player can be blocked, and a person is always reachable at
//  GitHub issues. Filtering happens on this device.
//

import SwiftUI

/// Something the player wants to report.
struct ReportRequest: Identifiable, Equatable {
    let id = UUID().uuidString
    let target: ReportTarget
    let targetID: String
    /// What is being reported, for the sheet title ("Sam's post").
    let subject: String
}

enum ReportReason: String, CaseIterable, Identifiable {
    case harassment = "Harassment or bullying"
    case hate = "Hate or discrimination"
    case sexual = "Sexual or inappropriate content"
    case spam = "Spam or scams"
    case cheating = "Fake workouts or cheating"
    case impersonation = "Impersonation"
    case other = "Something else"

    var id: String { rawValue }
}

// MARK: - Report sheet

struct ReportSheet: View {
    let request: ReportRequest

    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var sent = false

    private static let detailLimit = 500

    var body: some View {
        NavigationStack {
            Group {
                if sent { thanks } else { form }
            }
            .navigationTitle("Report \(request.target.noun)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSending ? "Sending…" : "Send") { Task { await send() } }
                            .disabled(isSending)
                    }
                }
            }
        }
        .desktopMinFrame(minWidth: 420, minHeight: 440)
    }

    private var form: some View {
        Form {
            Section {
                Text("You're reporting \(request.subject).")
                    .font(.callout)
                Picker("Reason", selection: $reason) {
                    ForEach(ReportReason.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                TextField("What happened? (optional)", text: $details, axis: .vertical)
                .multilineTextAlignment(.leading)
                    .lineLimit(3...6)
                    .onChange(of: details) { _, value in
                        if value.count > Self.detailLimit { details = String(value.prefix(Self.detailLimit)) }
                    }
            } footer: {
                Text("Reports are reviewed by the Endgame Fitness team. The person you report isn't told who sent it. For anything urgent, open an issue on the Endgame Fitness GitHub page.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private var thanks: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.brandGreen)
            Text("Thanks for the report").font(.title3.bold())
            Text("We'll review it. If you don't want to see this player at all, you can also block them from their profile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.isEmpty ? reason.rawValue : "\(reason.rawValue): \(note)"
        if let failure = await game.report(request.target, id: request.targetID, reason: text) {
            error = failure
        } else {
            error = nil
            sent = true
            Platform.success()
        }
    }
}

// MARK: - Blocked players

struct BlockedUsersView: View {
    @ObservedObject var game = GameProfileService.shared

    @State private var error: String?
    @State private var working: String?

    var body: some View {
        Form {
            Section {
                if game.blockedUsers.isEmpty {
                    Text("You haven't blocked anyone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(game.blockedUsers) { user in
                    HStack {
                        Text(user.displayName)
                        Spacer()
                        Button(working == user.userID ? "Unblocking…" : "Unblock") {
                            Task { await unblock(user) }
                        }
                        .disabled(working != nil)
                    }
                }
            } footer: {
                Text("Blocked players can't see your activity, comments, rankings or profile, and you won't see theirs. Unblocking doesn't restore a friendship.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Blocked players")
        .task { await game.loadBlocked() }
    }

    private func unblock(_ user: BlockedUser) async {
        working = user.userID
        error = await game.unblock(userID: user.userID)
        working = nil
    }
}

// MARK: - Help

/// "Get help" row (GitHub issues), used wherever a person might need one.
struct HelpContactLink: View {
    var subject = "Endgame Fitness help"

    var body: some View {
        Link(destination: AppInfo.helpURL) {
            Label("Get help on GitHub", systemImage: "questionmark.circle")
        }
    }
}
