//
//  SocialTabView.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Community sections from the former Social tab: Rivals board (player
//  cards / QR) with rival activity, Game Center boards and duels, Gym Party
//  (nearby co-op boss) and share cards. See Docs/SOCIAL_DESIGN.md.
//
//  NOTE: use `SwiftUI.ProgressView` (the app shadows ProgressView).
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage
#if os(iOS)
import AVFoundation
#endif

// MARK: - Shared bits

private struct SocialCard<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let symbol { Label(title, systemImage: symbol).font(.headline) } else { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CardAvatar: View {
    let card: PlayerCard
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: card.symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(card.color, in: Circle())
    }
}

// MARK: - Rivals

struct RivalsPane: View {
    @ObservedObject private var store = RivalStore.shared
    @State private var metric: RivalMetric = .weeklyVolume
    @State private var showMyCard = false
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { showMyCard = true } label: { Label("My player card", systemImage: "qrcode") }
                    .buttonStyle(.borderedProminent)
                Button { showAdd = true } label: { Label("Add rival", systemImage: "person.badge.plus") }
                    .buttonStyle(.bordered)
                Spacer()
            }
            if let last = store.lastImport {
                Text(last.isNew ? "Added \(last.name) to your rivals." : "Updated \(last.name)'s card.")
                    .font(.callout).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
            }
            SocialCard(title: "Rivals board", symbol: "trophy.fill") {
                Picker("Metric", selection: $metric) {
                    ForEach(RivalMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                let rows = store.board(metric: metric, me: PlayerCardBuilder.current())
                if rows.count <= 1 {
                    Text("No rivals yet. Share your player card, scan a friend's QR code, or join a Gym Party nearby.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.element.card.id) { i, row in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.headline.monospacedDigit()).frame(width: 24)
                        CardAvatar(card: row.card)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.isMe ? "\(row.card.name) (you)" : row.card.name).font(.body.weight(.semibold))
                            Text("Lv \(row.card.level)\(row.card.heroClass.map { " · \($0.capitalized)" } ?? "") · updated \(Date(timeIntervalSince1970: TimeInterval(row.card.issuedAt)).formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(metric.label(row.card)).font(.headline.monospacedDigit())
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        if !row.isMe {
                            Button("Remove rival", role: .destructive) { store.remove(row.card.id) }
                        }
                    }
                }
                Text("Rival cards are snapshots: ask friends to re-share to update them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Rival and Gym Party events (local players' activity is in Feed).
            if !store.events.isEmpty {
                SocialCard(title: "Rival activity", symbol: "bolt.horizontal.fill") {
                    ForEach(store.events.sorted { $0.at > $1.at }.prefix(50), id: \.id) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: e.symbol).foregroundStyle(Color.brandOrange).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.text)
                                Text(Date(timeIntervalSince1970: TimeInterval(e.at)).formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .onAppear { store.reload() }
        .onChange(of: LocalPlayerStore.shared.currentID) { _, _ in store.reload() }
        .sheet(isPresented: $showMyCard) { MyPlayerCardSheet() }
        .sheet(isPresented: $showAdd) { AddRivalSheet() }
    }
}

struct MyPlayerCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if let card = PlayerCardBuilder.current() {
                    let link = PlayerCardCode.deepLink(card)
                    ScrollView {
                        VStack(spacing: 16) {
                            if let qr = PlayerCardCode.qrImage(link.absoluteString) {
                                Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit()
                                    .frame(maxWidth: 260).padding(12)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            }
                            Text("\(card.name) · Lv \(card.level)").font(.title3.weight(.bold))
                            Text("Friends scan this, open the link, or paste the code in Add rival.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            HStack {
                                ShareLink(item: link, subject: Text("Rival me in Endgame Fitness"),
                                          message: Text("Add me as a rival in Endgame Fitness: ")) {
                                    Label("Share link", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderedProminent)
                                Button {
                                    Platform.copyToClipboard(PlayerCardCode.encode(card))
                                    copied = true
                                } label: { Label(copied ? "Copied" : "Copy code", systemImage: "doc.on.doc") }
                                    .buttonStyle(.bordered)
                            }
                            Text("Shares your name, level, class, this week's volume, top 5 lifts and streak. Nothing else.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(24)
                    }
                } else {
                    Text("Pick a player first.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("My player card")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 380, minHeight: 520)
    }
}

struct AddRivalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RivalStore.shared
    @State private var text = ""
    @State private var importing = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paste a code or link") {
                    TextField("EGF1.… or endgamefitness://card/…", text: $text, axis: .vertical)
                .multilineTextAlignment(.leading)
                        .lineLimit(3...6)
                    HStack {
                        Button("Paste") { text = Platform.pasteboardString() ?? text }
                        Spacer()
                        Button("Add rival") { if store.importText(text, source: "code") { dismiss() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.isEmpty)
                    }
                }
                Section("Or") {
                    #if os(iOS)
                    if QRScannerView.isAvailable {
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                    }
                    #endif
                    Button { importing = true } label: { Label("Import from image or file", systemImage: "photo.on.rectangle") }
                }
                if let error = store.importError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add rival")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .plainText, .text, .json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let image = CIImage(contentsOf: url), let payload = PlayerCardCode.readQR(from: image) {
                    if store.importText(payload, source: "qr") { dismiss() }
                } else if let s = try? String(contentsOf: url, encoding: .utf8) {
                    if store.importText(s, source: "file") { dismiss() }
                } else {
                    store.importError = "No player card found in that file."
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                ZStack(alignment: .topTrailing) {
                    QRScannerView { payload in
                        scanning = false
                        if store.importText(payload, source: "qr") { dismiss() }
                    }
                    .ignoresSafeArea()
                    Button { scanning = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white)
                    }
                    .padding()
                }
            }
            #endif
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}

#if os(iOS)
/// Camera QR scanner (AVFoundation metadata output).
struct QRScannerView: UIViewControllerRepresentable {
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(code)
        }
    }
}
#endif

// MARK: - Gym Party

struct GymPartyPane: View {
    @ObservedObject private var party = GymParty.shared
    @State private var weight = 135.0
    @State private var reps = 8

    var body: some View {
        VStack(spacing: 16) {
            SocialCard(title: "Gym Party", symbol: "dot.radiowaves.left.and.right") {
                Text("Players near you (same Wi-Fi or Bluetooth range) join automatically and trade player cards. Summon a boss and every set anyone completes hits it live.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if party.isActive {
                        Button("Leave party", role: .destructive) { party.stop() }.buttonStyle(.bordered)
                    } else {
                        Button { party.start() } label: { Label("Start Gym Party", systemImage: "antenna.radiowaves.left.and.right") }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    if party.isActive { Text("\(party.members.count + 1) in party").font(.callout.weight(.semibold)) }
                }
                if let status = party.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if party.isActive {
                    ForEach(party.members) { m in
                        HStack {
                            if let card = m.card { CardAvatar(card: card, size: 28) } else { SwiftUI.ProgressView().controlSize(.small) }
                            Text(m.card.map { "\($0.name) · Lv \($0.level)" } ?? m.id)
                            Spacer()
                        }
                    }
                }
            }
            if party.isActive { bossCard }
        }
    }

    @ViewBuilder
    private var bossCard: some View {
        SocialCard(title: "Co-op boss", symbol: "burst.fill") {
            if let boss = party.boss {
                HStack(spacing: 12) {
                    Image(systemName: boss.symbol).font(.system(size: 36, weight: .bold)).foregroundStyle(Color.brandOrange)
                    VStack(alignment: .leading) {
                        Text(boss.name).font(.headline)
                        Text(boss.defeatedAt != nil ? "Defeated!" : "\(boss.hpRemaining.formatted()) / \(boss.hp.formatted()) HP")
                            .font(.callout.monospacedDigit()).foregroundStyle(boss.defeatedAt != nil ? .green : .secondary)
                    }
                }
                SwiftUI.ProgressView(value: Double(boss.hpRemaining), total: Double(max(1, boss.hp))).tint(.red)
                ForEach(party.leaderboard, id: \.name) { row in
                    HStack { Text(row.name); Spacer(); Text("\(row.damage.formatted())").monospacedDigit() }.font(.callout)
                }
                Divider()
                Text("Sets you complete in a workout hit the boss automatically. Training without the app's workout screen? Log a set here:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper("\(Int(weight)) lb", value: $weight, in: 0...1000, step: 5)
                    Stepper("\(reps) reps", value: $reps, in: 1...100)
                }
                HStack {
                    Button { party.setLogged(weight: weight, reps: reps, exercise: "Set") } label: { Label("Log set", systemImage: "bolt.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(boss.defeatedAt != nil)
                    if boss.defeatedAt != nil { Button("New boss") { party.summonBoss() }.buttonStyle(.bordered) }
                }
            } else {
                Text("No boss yet. Anyone in the party can summon this week's boss; HP scales with party size.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { party.summonBoss() } label: { Label("Summon boss", systemImage: "flame.fill") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Game Center

struct GameCenterPane: View {
    @ObservedObject private var gc = GameCenterService.shared
    @State private var board = GameCenterService.boards[0].id

    var body: some View {
        VStack(spacing: 16) {
            SocialCard(title: "Game Center", symbol: "gamecontroller.fill") {
                Toggle("Post this player's progress to Game Center", isOn: Binding(
                    get: { gc.isEnabledForCurrent }, set: { gc.setEnabledForCurrent($0) }))
                Text(gc.isAuthenticated ? "Signed in as \(gc.gcName ?? "player")." : "Optional. Game Center is one Apple account per device; each local player chooses whether to post to it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = gc.status { Text(status).font(.caption).foregroundStyle(.orange) }
                if gc.isEnabledForCurrent, !gc.isAuthenticated {
                    Button("Sign in to Game Center") { gc.authenticate() }.buttonStyle(.borderedProminent)
                }
            }
            if gc.isAuthenticated {
                SocialCard(title: "Leaderboards (this week)", symbol: "list.number") {
                    Picker("Board", selection: $board) {
                        ForEach(GameCenterService.boards) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    let rows = gc.entries[board] ?? []
                    if rows.isEmpty { Text(gc.isWorking ? "Loading…" : "No scores yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(rows) { r in
                        HStack {
                            Text("\(r.rank)").monospacedDigit().frame(width: 28)
                            Text(r.name).fontWeight(r.isMe ? .bold : .regular)
                            Spacer()
                            Text(r.score).monospacedDigit()
                        }
                    }
                    Button("Refresh") { Task { await gc.publish(); await gc.loadBoards() } }.buttonStyle(.bordered)
                }
                SocialCard(title: "Duels", symbol: "flag.2.crossed.fill") {
                    Text("Weekly volume duel: each side posts this week's volume; higher wins.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await gc.startDuel() } } label: { Label("New duel", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    ForEach(gc.duels) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("vs \(d.opponent)").font(.body.weight(.semibold))
                                Text("You \(d.myVolume.map { Int($0).formatted() } ?? "-") · Them \(d.theirVolume.map { Int($0).formatted() } ?? "-")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let o = d.outcome { Text(o).bold() }
                            else if d.myTurn { Button("Post my volume") { Task { await gc.play(d.id) } }.buttonStyle(.bordered) }
                            else { Text("Their turn").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if !gc.friends.isEmpty {
                    SocialCard(title: "Game Center friends", symbol: "person.2.fill") {
                        ForEach(gc.friends, id: \.self) { Text($0) }
                    }
                }
            }
        }
        .task { gc.resumeIfEnabled() }
    }
}

// MARK: - Share

struct SharePane: View {
    var body: some View {
        SocialCard(title: "Share to Messages, Instagram, Facebook…", symbol: "square.and.arrow.up") {
            if let card = PlayerCardBuilder.current() {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(ShareCardRenderer.options(card: card)) { ShareCardButton(kind: $0, card: card) }
                    }
                }
                Text("Images open the system share sheet; apps you have installed (Instagram, Facebook, Messages) appear there.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pick a player first.").foregroundStyle(.secondary)
            }
        }
    }
}
