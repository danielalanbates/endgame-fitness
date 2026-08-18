//
//  TalentViews.swift
//  Endgame Fitness
//
//  The talent tree: three branches (Strength / Endurance / Community), three
//  tiers each. The server owns validation and every effect; this file only
//  renders `TalentState` and asks the server to spend or respec.
//

import SwiftUI

// MARK: - Unspent-points badge (lives on the player card)

struct TalentPointsBadge: View {
    let points: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text("\(points)")
                .font(.caption.bold())
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.brandPurple))
        .accessibilityLabel("\(points) unspent talent points")
    }
}

// MARK: - Tree

struct TalentTreeView: View {
    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBranch: String = "strength"
    @State private var showRespecConfirm = false
    @State private var isBusy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let state = game.talents {
                branchPicker(state)
                ScrollView {
                    branchColumn(state, branch: selectedBranch)
                        .padding(16)
                }
            } else {
                Spacer()
                SwiftUI.ProgressView("Loading talents…")
                Spacer()
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
        .task { await game.loadTalents() }
        .confirmationDialog(
            "Reset all talents?", isPresented: $showRespecConfirm, titleVisibility: .visible
        ) {
            Button("Refund every point", role: .destructive) {
                Task { isBusy = true; await game.respecTalents(); isBusy = false; message = "All points refunded." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every spent point comes back as unspent. This is free for now.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Talents").font(.title2.bold())
                if let state = game.talents {
                    Text("\(state.spent) spent · \(state.unspent) unspent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let state = game.talents, state.unspent > 0 {
                TalentPointsBadge(points: state.unspent)
            }
            Button("Reset") { showRespecConfirm = true }
                .disabled((game.talents?.spent ?? 0) == 0 || isBusy)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func branchPicker(_ state: TalentState) -> some View {
        Picker("", selection: $selectedBranch) {
            ForEach(state.tree.branches) { branch in
                Label("\(branch.name) (\(state.spentInBranch(branch.id)))", systemImage: branch.icon)
                    .tag(branch.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(16)
    }

    private func branchColumn(_ state: TalentState, branch: String) -> some View {
        let tint = state.tree.branches.first { $0.id == branch }?.tint ?? .brandBlue
        let nodes = state.tree.nodes.filter { $0.branch == branch }.sorted { $0.tier < $1.tier }
        return VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    // Prerequisite line: lit once the previous node's requirement is met.
                    let met = node.requires.allSatisfy { state.rank(of: $0.id) >= $0.rank }
                    Rectangle()
                        .fill(met ? tint : Color.gray.opacity(0.3))
                        .frame(width: 3, height: 26)
                }
                TalentNodeCard(node: node, state: state, tint: tint, isBusy: isBusy) {
                    Task {
                        isBusy = true
                        message = await game.spendTalent(node.id)
                        isBusy = false
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Node

struct TalentNodeCard: View {
    let node: TalentNode
    let state: TalentState
    let tint: Color
    let isBusy: Bool
    let onSpend: () -> Void

    private var rank: Int { state.rank(of: node.id) }
    private var blocker: String? { state.blocker(for: node) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(rank > 0
                          ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.55)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.gray.opacity(0.25)))
                Image(systemName: node.icon)
                    .font(.title3)
                    .foregroundStyle(rank > 0 ? .white : .secondary)
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .bottomTrailing) {
                Text("\(rank)/\(node.maxRank)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(rank == node.maxRank ? Color.brandYellow : Color.platformControlBackground))
                    .foregroundStyle(rank == node.maxRank ? .black : .primary)
                    .offset(x: 8, y: 6)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).font(.headline)
                    Text("Tier \(node.tier)").font(.caption2).foregroundStyle(.secondary)
                }
                Text(node.description).font(.caption).foregroundStyle(.secondary)
                if !node.requires.isEmpty {
                    Text(node.requires.map { req in
                        "\(state.tree.nodes.first { $0.id == req.id }?.name ?? req.id) \(req.rank)"
                    }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(node.requires.allSatisfy { state.rank(of: $0.id) >= $0.rank } ? tint : .secondary)
                }
            }

            Spacer()

            Button {
                onSpend()
            } label: {
                Image(systemName: rank >= node.maxRank ? "checkmark" : "plus")
                    .font(.body.bold())
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(blocker != nil || isBusy)
            .help(blocker ?? "Spend one point")
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(blocker == nil ? tint : Color.clear, lineWidth: 1.5)
        )
    }
}
