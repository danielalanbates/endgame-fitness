//
//  GymParty.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Nearby play over MultipeerConnectivity (Wi-Fi / peer-to-peer Wi-Fi /
//  Bluetooth, no internet, no accounts). While the Gym Party screen is open:
//  - devices advertise + browse the "egf-gymparty" Bonjour service and join
//    one session automatically (lower peer name invites, to avoid double links);
//  - each joiner sends its player card, which lands on the Rivals board;
//  - anyone can summon a co-op boss; every completed set on any device deals
//    weight x reps damage (bodyweight sets: reps x 25) and is broadcast, so all
//    screens show the same HP bar in real time. Hits carry ids, so a hit that
//    arrives twice is counted once.
//

import Foundation
import SwiftUI
import MultipeerConnectivity

struct PartyHit: Codable, Identifiable, Equatable {
    var id: String
    var player: String
    var exercise: String
    var damage: Int
    var at: Int
}

struct PartyBoss: Codable, Equatable {
    var raidID: String
    var bossID: String
    var name: String
    var symbol: String
    var hp: Int
    var damage: Int
    var defeatedAt: Int?
    var hpRemaining: Int { max(0, hp - damage) }
}

private enum PartyMessage: Codable {
    case card(String)
    case boss(PartyBoss, hits: [PartyHit])
    case hit(PartyHit)
}

struct PartyMember: Identifiable, Equatable {
    var id: String          // MCPeerID.displayName
    var card: PlayerCard?
}

@MainActor
final class GymParty: NSObject, ObservableObject {
    static let shared = GymParty()
    static let serviceType = "egf-gymparty"

    @Published private(set) var isActive = false
    @Published private(set) var members: [PartyMember] = []
    @Published private(set) var boss: PartyBoss?
    @Published private(set) var hits: [PartyHit] = []
    @Published private(set) var status: String?

    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var seenHits = Set<String>()

    // MARK: Lifecycle

    func start() {
        guard !isActive, let player = LocalPlayerStore.shared.current else {
            if LocalPlayerStore.shared.current == nil { status = "Pick a player first." }
            return
        }
        // Unique per launch so two players with the same name both show up.
        let name = String("\(player.name)#\(String(UUID().uuidString.prefix(4)))".prefix(60))
        let peer = MCPeerID(displayName: name)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["lv": "\(GameProfileService.shared.profile?.level ?? 1)"], serviceType: Self.serviceType)
        advertiser.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        browser.delegate = self
        self.peerID = peer
        self.session = session
        self.advertiser = advertiser
        self.browser = browser
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isActive = true
        status = "Looking for players nearby…"
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        peerID = nil
        isActive = false
        members = []
        status = nil
    }

    // MARK: Boss

    func summonBoss() {
        let boss = GameRules.bossForWeek(Int(Date().timeIntervalSince1970))
        // Sized for a session: ~8 working sets each at a moderate load.
        let hp = 8000 * max(1, members.count + 1)
        self.boss = PartyBoss(raidID: UUID().uuidString, bossID: boss.id, name: boss.name, symbol: boss.symbol, hp: hp, damage: 0)
        hits = []
        seenHits = []
        broadcastBoss()
    }

    /// Called for every completed set on this device.
    func setLogged(weight: Double, reps: Int, exercise: String) {
        guard isActive, let boss, boss.defeatedAt == nil, reps > 0 else { return }
        let damage = weight > 0 ? Int(weight * Double(reps)) : reps * 25
        let hit = PartyHit(id: UUID().uuidString, player: LocalPlayerStore.shared.current?.name ?? "You",
                           exercise: exercise, damage: damage, at: Int(Date().timeIntervalSince1970))
        apply(hit)
        send(.hit(hit))
    }

    private func apply(_ hit: PartyHit) {
        guard var b = boss, seenHits.insert(hit.id).inserted else { return }
        hits.insert(hit, at: 0)
        b.damage = hits.reduce(0) { $0 + $1.damage }
        if b.defeatedAt == nil, b.damage >= b.hp {
            b.defeatedAt = Int(Date().timeIntervalSince1970)
            let crew = ([LocalPlayerStore.shared.current?.name ?? "You"] + members.compactMap { $0.card?.name }).joined(separator: ", ")
            RivalStore.shared.log(SocialEvent(at: b.defeatedAt!, symbol: "burst.fill", text: "Gym Party defeated \(b.name): \(crew)."))
        }
        boss = b
    }

    /// Damage per player name for the current boss.
    var leaderboard: [(name: String, damage: Int)] {
        Dictionary(grouping: hits, by: \.player).map { ($0.key, $0.value.reduce(0) { $0 + $1.damage }) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: Messaging

    private func broadcastBoss() {
        guard let boss else { return }
        send(.boss(boss, hits: hits))
    }

    private func sendCard(to peers: [MCPeerID]) {
        guard let card = PlayerCardBuilder.current() else { return }
        send(.card(PlayerCardCode.encode(card)), to: peers)
    }

    private func send(_ message: PartyMessage, to peers: [MCPeerID]? = nil) {
        guard let session, let data = try? JSONEncoder().encode(message) else { return }
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard let message = try? JSONDecoder().decode(PartyMessage.self, from: data) else { return }
        switch message {
        case .card(let code):
            guard let card = try? PlayerCardCode.decode(code) else { return }
            if let i = members.firstIndex(where: { $0.id == peer.displayName }) { members[i].card = card }
            RivalStore.shared.add(card, source: "nearby")
        case .boss(let incoming, let incomingHits):
            if boss?.raidID != incoming.raidID {
                boss = PartyBoss(raidID: incoming.raidID, bossID: incoming.bossID, name: incoming.name,
                                 symbol: incoming.symbol, hp: incoming.hp, damage: 0)
                hits = []
                seenHits = []
            }
            for hit in incomingHits.reversed() { apply(hit) }
        case .hit(let hit):
            apply(hit)
        }
    }

    private func peerChanged(_ peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            if !members.contains(where: { $0.id == peer.displayName }) {
                members.append(PartyMember(id: peer.displayName, card: nil))
            }
            status = nil
            sendCard(to: [peer])
            if boss != nil { send(.boss(boss!, hits: hits), to: [peer]) }
        case .notConnected:
            members.removeAll { $0.id == peer.displayName }
        default:
            break
        }
    }
}

// MARK: - Multipeer delegates (called off the main thread)

extension GymParty: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerChanged(peerID, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.receive(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // Only while the party screen is open (advertiser exists only then).
            invitationHandler(self.isActive, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.status = "Can't advertise: \(error.localizedDescription). Allow Local Network access in Settings." }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let me = self.peerID, let session = self.session else { return }
            // One side invites: the lexically smaller name.
            if me.displayName < peerID.displayName, !session.connectedPeers.contains(peerID) {
                browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.status = "Can't search nearby: \(error.localizedDescription)" }
    }
}
