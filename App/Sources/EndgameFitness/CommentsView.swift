//
//  CommentsView.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The comment thread under a feed item (API_V2 §4). Anyone who can see the
//  item can read it; the server allows comments on your own, your friends'
//  and your guildmates' items, filters the text, and caps it at 30 an hour.
//  You can delete your own comments and any comment on your own post, and
//  report anyone else's.
//

import SwiftUI

struct CommentsSheet: View {
    let item: ActivityItem
    /// Opens the comment author's profile (the presenter swaps sheets).
    var onOpenPlayer: (PlayerRef) -> Void = { _ in }

    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [FeedComment] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var draft = ""
    @State private var isPosting = false
    @State private var postError: String?
    @State private var report: ReportRequest?
    @State private var pendingDelete: FeedComment?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CommentsItemHeader(item: item)
                Divider()
                thread
                Divider()
                composer
            }
            .navigationTitle("Comments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .desktopMinFrame(minWidth: 460, minHeight: 520)
        .task { await load() }
        .sheet(item: $report) { ReportSheet(request: $0) }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let comment = pendingDelete { Task { await delete(comment) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    @ViewBuilder
    private var thread: some View {
        if isLoading {
            SwiftUI.ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Text(loadError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if comments.isEmpty {
            CommunityEmptyState(icon: "bubble.left", title: "No comments yet",
                                message: "Say something encouraging.")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(comments) { comment in
                        CommentRow(
                            comment: comment,
                            canDelete: comment.isSelf || item.isSelf,
                            onAuthor: comment.isSelf ? nil : {
                                onOpenPlayer(PlayerRef(id: comment.userID, displayName: comment.displayName))
                            },
                            onDelete: { pendingDelete = comment },
                            onReport: {
                                report = ReportRequest(target: .comment, targetID: comment.id,
                                                       subject: "a comment by \(comment.displayName)")
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, value in
                        if value.count > ProfileRules.commentLimit {
                            draft = String(value.prefix(ProfileRules.commentLimit))
                        }
                    }
                Button(isPosting ? "Posting…" : "Post") { Task { await post() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandPurple)
                    .disabled(trimmedDraft.isEmpty || isPosting)
            }
            HStack {
                if let postError {
                    Text(postError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(draft.count)/\(ProfileRules.commentLimit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            comments = try await game.loadComments(for: item.id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func post() async {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            let comment = try await game.addComment(to: item.id, text: text)
            comments.append(comment)
            draft = ""
            postError = nil
        } catch {
            postError = error.localizedDescription
        }
    }

    private func delete(_ comment: FeedComment) async {
        do {
            try await game.deleteComment(comment.id, on: item.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            postError = error.localizedDescription
        }
    }
}

struct CommentsItemHeader: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(item.tint)
                .frame(width: 28, height: 28)
                .background(item.tint.opacity(0.12))
                .clipShape(Circle())
            (Text(item.isSelf ? "You " : "\(item.displayName) ").bold() + Text(item.summary))
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

struct CommentRow: View {
    let comment: FeedComment
    let canDelete: Bool
    let onAuthor: (() -> Void)?
    let onDelete: () -> Void
    let onReport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onAuthor?() } label: {
                AvatarBadgeView(config: nil, level: comment.level, size: 28,
                                tint: FitnessProfile.rankColor(for: comment.level))
            }
            .buttonStyle(.plain)
            .disabled(onAuthor == nil)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.isSelf ? "You" : comment.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(ActivityRowTime.relative(comment.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(comment.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Menu {
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                if !comment.isSelf {
                    Button(action: onReport) {
                        Label("Report comment…", systemImage: "exclamationmark.bubble")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(canDelete || !comment.isSelf ? 1 : 0)
            .accessibilityLabel("Comment actions")
        }
    }
}
