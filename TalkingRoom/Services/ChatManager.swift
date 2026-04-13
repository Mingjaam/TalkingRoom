//
//  ChatManager.swift
//  TalkingRoom
//

import Foundation
import MultipeerConnectivity
import Observation

private let serviceType  = "talking-room"
private let maxConnections = 5
private let maxHopCount  = 5
private let messageTTL: TimeInterval = 600
private let presenceTTL: TimeInterval = 10
private let presenceBroadcastInterval: TimeInterval = 2

// MARK: - ReachablePeer
struct ReachablePeer: Identifiable, Equatable {
    let id: String
    let name: String
    let isDirect: Bool
    var isMe: Bool = false
}

// MARK: - TopologyNode
struct TopologyNode: Identifiable {
    let id: String
    let name: String
    let connectionCount: Int
    let isMe: Bool
    let isDirect: Bool
    var isRelay: Bool { connectionCount >= 3 }
}

// MARK: - TopologyBroadcast  (chat 메시지와 구분되는 별도 패킷)
struct TopologyBroadcast: Codable {
    struct PeerInfo: Codable {
        let id: String
        let name: String
    }
    /// 메시지와 구분하기 위한 고정 식별자
    let packetType: String
    let senderId: String
    let senderName: String
    let connections: [PeerInfo]   // 브로드캐스터의 직접 연결 목록

    static let typeKey = "topo_v1"

    init(senderId: String, senderName: String, connections: [PeerInfo]) {
        self.packetType = Self.typeKey
        self.senderId   = senderId
        self.senderName = senderName
        self.connections = connections
    }
}

// MARK: - PresencePacket (online roster용 heartbeat)
struct PresencePacket: Codable {
    /// 메시지와 구분하기 위한 고정 식별자
    let packetType: String
    /// 루프/중복 방지용
    let packetId: UUID
    let senderId: String
    let senderName: String
    /// 발신자가 실제로 쓰는 MCPeerID.displayName (직접 연결 판정 보강용)
    let senderPeerDisplayName: String
    var hopCount: Int

    static let typeKey = "presence_v1"

    init(senderId: String, senderName: String, senderPeerDisplayName: String, hopCount: Int) {
        self.packetType = Self.typeKey
        self.packetId = UUID()
        self.senderId = senderId
        self.senderName = senderName
        self.senderPeerDisplayName = senderPeerDisplayName
        self.hopCount = hopCount
    }
}

// MARK: - ChatManager
@Observable
final class ChatManager: NSObject {

    // MARK: Observable State
    var messages: [Message] = []
    var connectedPeers: [MCPeerID] = []
    var reachablePeers: [ReachablePeer] = []
    var isSearching: Bool = false

    // MARK: Identity
    private(set) var anonymousId: String
    private(set) var anonymousName: String

    // MARK: MPC
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    // MARK: Gossip State
    private var seenMessageIDs: Set<UUID> = []
    private var seenSenders: [String: String] = [:]        // anonymousId -> name
    private var peerAnonymousIds: [MCPeerID: String] = [:] // MCPeerID -> anonymousId
    private var seenPresencePacketIDs: Set<UUID> = []

    // MARK: Smart-Connect State
    private var peerConnectionCounts: [MCPeerID: Int] = [:]
    private var pendingInvites: [(peer: MCPeerID, connections: Int)] = []

    // MARK: Topology State
    /// peerId -> 해당 피어가 알려준 직접 연결 목록
    private var peerTopologies: [String: [TopologyBroadcast.PeerInfo]] = [:]
    /// peerId -> 마지막 토폴로지 수신 시각 (stale 제거용)
    private var peerTopologyLastUpdatedAt: [String: Date] = [:]

    // MARK: Presence / System Message De-dupe
    /// peerId(displayName) 기준 최근 시스템 이벤트 기록 (중복 참여/나가기 방지)
    private var recentSystemEvents: [String: Date] = [:]
    private let systemEventDedupeWindow: TimeInterval = 6
    private let disconnectGraceWindow: TimeInterval = 5

    // MARK: Topology Timer
    private var topologyTimer: Timer?

    // MARK: Presence State
    private struct PresenceEntry {
        var name: String
        var peerDisplayName: String?
        var lastSeenAt: Date
    }
    private var presenceById: [String: PresenceEntry] = [:]
    private var onlinePeerIds: Set<String> = []
    private var presenceTimer: Timer?

    // MARK: Room-Making State
    /// 연결 교체 시 일시적으로 재연결을 피할 anonymousId 목록
    private var avoidPeerIds: Set<String> = []
    /// 세션 리셋 중 참여/나가기 시스템 메시지 억제 플래그
    private var isMakingRoom = false
    /// 중복 room-making 방지 쿨다운
    private var lastMakeRoomTime: Date = .distantPast

    // MARK: Disconnect Message Debounce
    /// 잠깐 끊겼다 재연결 시 메시지 취소용 — MCPeerID → 보류 중인 나가기 메시지
    private var pendingDisconnectMessages: [MCPeerID: DispatchWorkItem] = [:]

    // MARK: TTL Timer
    private var ttlTimer: Timer?

    // MARK: - Init
    override init() {
        let uuid = UUID().uuidString
        self.anonymousId = uuid
        let shortId = String(uuid.replacingOccurrences(of: "-", with: "").prefix(4).uppercased())
        self.anonymousName = "익명-\(shortId)"
        super.init()
    }

    // MARK: - Topology Nodes (me + direct + 2-hop indirect, 중복 없음)
    var topologyNodes: [TopologyNode] {
        var result: [TopologyNode] = []
        var shownIds = Set<String>()

        // 1) 나
        result.append(TopologyNode(
            id: anonymousId, name: anonymousName,
            connectionCount: connectedPeers.count,
            isMe: true, isDirect: true))
        shownIds.insert(anonymousId)

        // 2) 직접 연결 피어 — anonymousId 우선, 없으면 displayName을 임시 id로
        for peer in connectedPeers {
            let id   = peerAnonymousIds[peer] ?? peer.displayName
            let name = seenSenders[id] ?? peer.displayName
            let cnt  = peerConnectionCounts[peer] ?? 0
            if shownIds.insert(id).inserted {
                result.append(TopologyNode(id: id, name: name, connectionCount: cnt,
                                           isMe: false, isDirect: true))
            }
        }

        // 3) 각 직접 피어의 토폴로지 브로드캐스트에서 알게 된 2-hop 노드
        //    단, 이미 등록된 id(나 포함)는 건너뜀
        for (_, connections) in peerTopologies {
            for conn in connections where !shownIds.contains(conn.id) {
                shownIds.insert(conn.id)
                result.append(TopologyNode(id: conn.id, name: conn.name,
                                           connectionCount: 0,
                                           isMe: false, isDirect: false))
            }
        }
        return result
    }

    /// 나를 제외한 "채팅 가능 인원" (UI에서 이 값만 쓰도록 단일화)
    var reachablePeerCountExcludingMe: Int {
        // presence가 늦게 도착해도 직접 연결 수가 0으로 떨어지지 않게 하한을 둠
        let rosterCount = max(onlinePeerIds.count - 1, 0)
        return max(rosterCount, connectedPeers.count)
    }

    /// 표시용 "나 포함" 인원수
    var reachablePeerCountIncludingMe: Int {
        max(reachablePeerCountExcludingMe + 1, 1)
    }

    /// 알려진 모든 연결 엣지 (중복 제거)
    var topologyEdges: [(from: String, to: String)] {
        var edges: [(from: String, to: String)] = []
        var seen  = Set<String>()

        func add(_ a: String, _ b: String) {
            let key = [a, b].sorted().joined(separator: "↔")
            if seen.insert(key).inserted { edges.append((from: a, to: b)) }
        }

        // 내 직접 연결
        for peer in connectedPeers {
            let id = peerAnonymousIds[peer] ?? peer.displayName
            add(anonymousId, id)
        }
        // 각 피어가 알려준 연결
        for (peerId, connections) in peerTopologies {
            for conn in connections { add(peerId, conn.id) }
        }
        return edges
    }

    // MARK: - Start
    func start(displayName: String? = nil) {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { anonymousName = trimmed }

        let truncated = String(anonymousName.prefix(15))
        myPeerID = MCPeerID(displayName: truncated)

        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let discoveryInfo: [String: String] = ["id": anonymousId, "connections": "0"]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: discoveryInfo,
                                               serviceType: serviceType)
        advertiser.delegate = self

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self

        isSearching = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startTTLTimer()
        startTopologyTimer()
        startPresenceTimer()
    }

    // MARK: - Stop
    func stop() {
        session?.delegate    = nil
        advertiser?.delegate = nil
        browser?.delegate    = nil

        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        ttlTimer?.invalidate()
        topologyTimer?.invalidate()
        presenceTimer?.invalidate()

        pendingDisconnectMessages.forEach { $0.value.cancel() }
        pendingDisconnectMessages = [:]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.messages             = []
            self.connectedPeers       = []
            self.reachablePeers       = []
            self.seenSenders          = [:]
            self.seenMessageIDs       = []
            self.peerAnonymousIds     = [:]
            self.peerConnectionCounts = [:]
            self.pendingInvites       = []
            self.peerTopologies       = [:]
            self.peerTopologyLastUpdatedAt = [:]
            self.recentSystemEvents   = [:]
            self.presenceById         = [:]
            self.onlinePeerIds        = []
            self.seenPresencePacketIDs = []
            self.avoidPeerIds         = []
            self.isMakingRoom         = false
            self.lastMakeRoomTime     = .distantPast
            self.isSearching          = false
        }
    }

    // MARK: - Reachable Peers (나 + 직접 + 간접)
    private func updateReachablePeers() {
        var result: [ReachablePeer] = []
        var seenIds = Set<String>()

        // 나
        seenIds.insert(anonymousId)
        result.append(ReachablePeer(id: anonymousId, name: anonymousName,
                                    isDirect: true, isMe: true))

        // 직접 연결 피어는 항상 먼저 표시 (presence 수신 전에도 direct가 보이게)
        let directPeerDisplayNames = Set(connectedPeers.map { $0.displayName })
        var directAnonIds = Set<String>()
        for peer in connectedPeers {
            if let anonId = peerAnonymousIds[peer] { directAnonIds.insert(anonId) }
        }

        for peer in connectedPeers {
            let id = peerAnonymousIds[peer] ?? peer.displayName
            let name = seenSenders[id] ?? peer.displayName
            // 먼저 대표 id로 중복 체크/삽입 (id == displayName인 케이스를 위해 선삽입 금지)
            guard seenIds.insert(id).inserted else { continue }
            // 중복 방지 보강: alias들도 마킹해두되, 대표 id 삽입 이후에 수행
            _ = seenIds.insert(peer.displayName)
            if let anonId = peerAnonymousIds[peer] { _ = seenIds.insert(anonId) }
            result.append(ReachablePeer(id: id, name: name, isDirect: true))
        }

        // presence 기반: online roster를 reachable로 구성 (직접/간접 판정 포함)
        let now = Date()
        let cutoff = now.addingTimeInterval(-presenceTTL)
        for (id, entry) in presenceById where entry.lastSeenAt >= cutoff {
            guard seenIds.insert(id).inserted else { continue }
            let isMe = (id == anonymousId)
            let isDirect = isMe
                || directAnonIds.contains(id)
                || (entry.peerDisplayName.map { directPeerDisplayNames.contains($0) } ?? false)
            result.append(ReachablePeer(id: id,
                                        name: entry.name,
                                        isDirect: isDirect,
                                        isMe: isMe))
        }

        // 마지막 fallback: topo 기반 간접 (presence가 비어있을 때만 보조)
        if result.count <= 1 {
            for (_, connections) in peerTopologies {
                for conn in connections where seenIds.insert(conn.id).inserted {
                    result.append(ReachablePeer(id: conn.id, name: conn.name, isDirect: false))
                }
            }
        }
        reachablePeers = result
    }

    // MARK: - Restart Advertising
    private func restartAdvertising() {
        guard isSearching else { return }
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        let info: [String: String] = ["id": anonymousId,
                                      "connections": "\(connectedPeers.count)"]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: info,
                                               serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
    }

    // MARK: - Topology Broadcast
    /// 내 직접 연결 목록을 모든 직접 피어에게 전송
    private func broadcastTopology() {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let connections: [TopologyBroadcast.PeerInfo] = connectedPeers.compactMap { peer in
            guard let id = peerAnonymousIds[peer] else { return nil }
            let name = seenSenders[id] ?? peer.displayName
            return TopologyBroadcast.PeerInfo(id: id, name: name)
        }
        let broadcast = TopologyBroadcast(senderId: anonymousId,
                                          senderName: anonymousName,
                                          connections: connections)
        guard let data = try? JSONEncoder().encode(broadcast) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func handleTopologyBroadcast(_ broadcast: TopologyBroadcast,
                                         from senderPeer: MCPeerID) {
        DispatchQueue.main.async {
            // MCPeerID → anonymousId 매핑 확정 (advertiser 경로로 연결 시 foundPeer 전에 알 수 있음)
            self.peerAnonymousIds[senderPeer] = broadcast.senderId
            // 직접 피어 이름만 seenSenders에 저장 (간접 노드는 넣지 않아 ghost 방지)
            self.seenSenders[broadcast.senderId] = broadcast.senderName
            // 간접 노드 정보는 peerTopologies에만 유지
            self.peerTopologies[broadcast.senderId] = broadcast.connections
            self.peerTopologyLastUpdatedAt[broadcast.senderId] = Date()
            self.updateReachablePeers()   // 간접 연결 즉시 반영
        }
    }

    private func startTopologyTimer() {
        topologyTimer?.invalidate()
        topologyTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.purgeStaleTopology()
            self.broadcastTopology()
        }
    }

    private func purgeStaleTopology() {
        let cutoff = Date().addingTimeInterval(-15)
        var removedAny = false
        for (peerId, updatedAt) in peerTopologyLastUpdatedAt where updatedAt < cutoff {
            peerTopologyLastUpdatedAt.removeValue(forKey: peerId)
            peerTopologies.removeValue(forKey: peerId)
            removedAny = true
        }
        if removedAny { updateReachablePeers() }
    }

    // MARK: - Pending Invites
    private func processPendingInvites() {
        guard let session, let browser else { return }
        // session.connectedPeers는 MPC 실측값 — 초대 전송 후 연결 완료 전에도 정확한 수를 반영
        let currentCount = session.connectedPeers.count
        guard currentCount < maxConnections else { return }
        let capacity = maxConnections - currentCount

        var remaining: [(peer: MCPeerID, connections: Int)] = []
        var invited = 0
        for item in pendingInvites {
            if invited < capacity && !session.connectedPeers.contains(item.peer) {
                browser.invitePeer(item.peer, to: session, withContext: nil, timeout: 10)
                invited += 1
            } else {
                remaining.append(item)
            }
        }
        pendingInvites = remaining
    }

    // MARK: - Room-Making
    /// 꽉 찬 상태에서 격리된 신규 피어를 위해 가장 많이 연결된 기존 피어를 드롭하고 세션 리셋
    private func tryMakeRoomFor(_ newPeer: MCPeerID) {
        // 10초 내 중복 호출 방지 — 여러 기기가 동시에 room-making하는 것을 막음
        let now = Date()
        guard now.timeIntervalSince(lastMakeRoomTime) > 10 else { return }
        lastMakeRoomTime = now

        // 드롭 대상: 연결 수가 가장 많은 기존 피어 (최소 2개 이상 연결)
        guard let dropPeer = connectedPeers.max(by: {
            (peerConnectionCounts[$0] ?? 0) < (peerConnectionCounts[$1] ?? 0)
        }), let dropAnonId = peerAnonymousIds[dropPeer],
        (peerConnectionCounts[dropPeer] ?? 0) >= 2 else { return }

        print("[ChatManager] 방 만들기: \(dropAnonId) 드롭 → \(newPeer.displayName) 수용")
        isMakingRoom = true
        avoidPeerIds.insert(dropAnonId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.avoidPeerIds.remove(dropAnonId)
        }

        // 신규 피어를 pendingInvites 맨 앞으로
        pendingInvites.removeAll { $0.peer == newPeer }
        pendingInvites.insert((peer: newPeer, connections: 0), at: 0)

        // 세션 리셋: delegate nil → disconnect → 새 세션
        session?.delegate = nil
        session?.disconnect()

        let newSession = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        session = newSession

        connectedPeers = []
        reachablePeers = []
        peerTopologies = [:]

        // 브라우저 재시작 → foundPeer → processPendingInvites (avoided 피어 제외)
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
        restartAdvertising()
        // 재연결 완료 후 시스템 메시지 억제 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.isMakingRoom = false
        }
    }

    // MARK: - Send Message
    func send(text: String) {
        let message = Message(senderId: anonymousId, senderName: anonymousName,
                              text: text, hopCount: maxHopCount)
        addToLocal(message)
        propagate(message, excluding: nil)
    }

    // MARK: - Gossip Propagation
    private func propagate(_ message: Message, excluding senderPeer: MCPeerID?) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        var targets = session.connectedPeers
        if let sender = senderPeer { targets = targets.filter { $0 != sender } }
        let selected = Array(targets.shuffled().prefix(min(4, targets.count)))
        guard !selected.isEmpty else { return }
        var forwarded = message
        forwarded.hopCount -= 1
        guard let data = try? JSONEncoder().encode(forwarded) else { return }
        try? session.send(data, toPeers: selected, with: .reliable)
    }

    // MARK: - Local State Update
    private func addToLocal(_ message: Message) {
        seenMessageIDs.insert(message.id)
        DispatchQueue.main.async { self.messages.append(message) }
    }

    // MARK: - Receive
    private func receive(_ data: Data, from senderPeer: MCPeerID) {
        // 토폴로지 패킷 먼저 확인
        if let topo = try? JSONDecoder().decode(TopologyBroadcast.self, from: data),
           topo.packetType == TopologyBroadcast.typeKey {
            handleTopologyBroadcast(topo, from: senderPeer)
            return
        }

        // presence 패킷 확인
        if let presence = try? JSONDecoder().decode(PresencePacket.self, from: data),
           presence.packetType == PresencePacket.typeKey {
            handlePresencePacket(presence, from: senderPeer)
            return
        }

        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        guard !seenMessageIDs.contains(message.id) else { return }

        addToLocal(message)

        if !message.isSystemMessage {
            DispatchQueue.main.async {
                self.seenSenders[message.senderId] = message.senderName
            }
        }

        if message.hopCount > 0 { propagate(message, excluding: senderPeer) }
    }

    // MARK: - System Messages
    private func addSystemMessage(_ text: String) {
        let msg = Message(senderId: "system", senderName: "system",
                          text: text, hopCount: 0, isSystemMessage: true)
        DispatchQueue.main.async { self.messages.append(msg) }
    }

    private func shouldEmitSystemEvent(key: String) -> Bool {
        let now = Date()
        if let last = recentSystemEvents[key], now.timeIntervalSince(last) < systemEventDedupeWindow {
            return false
        }
        recentSystemEvents[key] = now
        return true
    }

    // MARK: - TTL Timer
    private func startTTLTimer() {
        ttlTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.purgeOldMessages()
        }
    }

    private func purgeOldMessages() {
        let cutoff = Date().addingTimeInterval(-messageTTL)
        DispatchQueue.main.async {
            self.messages.removeAll { !$0.isSystemMessage && $0.timestamp < cutoff }
            self.purgeStaleTopology()
        }
    }

    // MARK: - Presence (Roster)
    private func startPresenceTimer() {
        presenceTimer?.invalidate()
        // 내 presence 초기 등록
        let now = Date()
        presenceById[anonymousId] = PresenceEntry(name: anonymousName, peerDisplayName: myPeerID?.displayName, lastSeenAt: now)
        onlinePeerIds.insert(anonymousId)
        updateReachablePeers()

        presenceTimer = Timer.scheduledTimer(withTimeInterval: presenceBroadcastInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.broadcastPresence()
            self.purgeStalePresenceAndEmitEvents()
        }
    }

    private func broadcastPresence() {
        // 내 lastSeen 갱신
        let now = Date()
        presenceById[anonymousId] = PresenceEntry(name: anonymousName, peerDisplayName: myPeerID?.displayName, lastSeenAt: now)
        onlinePeerIds.insert(anonymousId)

        guard let session, !session.connectedPeers.isEmpty else { return }
        let packet = PresencePacket(senderId: anonymousId,
                                    senderName: anonymousName,
                                    senderPeerDisplayName: myPeerID.displayName,
                                    hopCount: 3)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func handlePresencePacket(_ packet: PresencePacket, from senderPeer: MCPeerID) {
        // 루프 방지
        guard seenPresencePacketIDs.insert(packet.packetId).inserted else { return }

        let senderId = packet.senderId
        let senderName = packet.senderName
        let senderPeerDisplayName = packet.senderPeerDisplayName

        DispatchQueue.main.async {
            let now = Date()
            self.presenceById[senderId] = PresenceEntry(name: senderName,
                                                       peerDisplayName: senderPeerDisplayName,
                                                       lastSeenAt: now)
            self.seenSenders[senderId] = senderName

            // online set (시스템 참여/나가기 메시지는 요구사항에 따라 표시하지 않음)
            _ = self.onlinePeerIds.insert(senderId)

            self.updateReachablePeers()
        }

        // 가십 전파 (짧은 hop)
        guard packet.hopCount > 0 else { return }
        var forwarded = packet
        forwarded.hopCount -= 1
        guard let data = try? JSONEncoder().encode(forwarded),
              let session else { return }
        var targets = session.connectedPeers.filter { $0 != senderPeer }
        targets = Array(targets.shuffled().prefix(min(4, targets.count)))
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    private func purgeStalePresenceAndEmitEvents() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-presenceTTL)

        // stale 제거
        var toRemove: [String] = []
        for (id, entry) in presenceById where id != anonymousId && entry.lastSeenAt < cutoff {
            toRemove.append(id)
        }
        guard !toRemove.isEmpty else { return }

        DispatchQueue.main.async {
            for id in toRemove {
                self.presenceById.removeValue(forKey: id)
                _ = self.onlinePeerIds.remove(id)
            }
            self.updateReachablePeers()
        }
    }

    // MARK: - Peer Management
    private func handlePeerConnected(_ peerID: MCPeerID) {
        DispatchQueue.main.async {
            // presence 기반 join/leave를 신뢰하므로 MPC 이벤트는 시스템 메시지로 쓰지 않음
            if let pending = self.pendingDisconnectMessages.removeValue(forKey: peerID) { pending.cancel() }
            if !self.connectedPeers.contains(peerID) {
                self.connectedPeers.append(peerID)
            }
            self.pendingInvites.removeAll { $0.peer == peerID }
            self.updateReachablePeers()
            self.restartAdvertising()
            self.broadcastTopology()
            self.broadcastPresence()
        }
    }

    private func handlePeerDisconnected(_ peerID: MCPeerID) {
        DispatchQueue.main.async {
            // 상태 즉시 업데이트
            self.connectedPeers.removeAll { $0 == peerID }
            if let anonId = self.peerAnonymousIds[peerID] {
                self.seenSenders.removeValue(forKey: anonId)
                self.peerTopologies.removeValue(forKey: anonId)
                self.peerTopologyLastUpdatedAt.removeValue(forKey: anonId)
            }
            self.peerAnonymousIds.removeValue(forKey: peerID)
            self.peerConnectionCounts.removeValue(forKey: peerID)
            self.updateReachablePeers()
            self.restartAdvertising()
            self.broadcastTopology()
            self.processPendingInvites()
            if self.pendingInvites.isEmpty {
                self.browser?.startBrowsingForPeers()
            }
        }
    }
}

// MARK: - MCSessionDelegate
extension ChatManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:    handlePeerConnected(peerID)
        case .notConnected: handlePeerDisconnected(peerID)
        case .connecting:   break
        @unknown default:   break
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        receive(data, from: peerID)
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension ChatManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // avoid 목록에 있으면 거절
        if let anonId = peerAnonymousIds[peerID], avoidPeerIds.contains(anonId) {
            invitationHandler(false, nil)
            return
        }
        let canAccept = (session?.connectedPeers.count ?? 0) < maxConnections
        invitationHandler(canAccept, canAccept ? session : nil)
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[ChatManager] 광고 시작 실패: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension ChatManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        let theirConnections = Int(info?["connections"] ?? "99") ?? 99
        let theirAnonId = info?["id"]
        if let anonId = theirAnonId {
            DispatchQueue.main.async { self.peerAnonymousIds[peerID] = anonId }
        }
        DispatchQueue.main.async {
            // avoid 목록에 있으면 무시
            if let anonId = theirAnonId, self.avoidPeerIds.contains(anonId) { return }
            self.peerConnectionCounts[peerID] = theirConnections
            guard let session = self.session else { return }
            guard !session.connectedPeers.contains(peerID) else { return }
            if session.connectedPeers.count >= maxConnections {
                // 꽉 찼을 때: 신규 피어가 고립(연결≤1)이면 방 만들기 시도
                if theirConnections <= 1 {
                    self.tryMakeRoomFor(peerID)
                }
                return
            }
            self.pendingInvites.removeAll { $0.peer == peerID }
            self.pendingInvites.append((peer: peerID, connections: theirConnections))
            self.pendingInvites.sort { $0.connections < $1.connections }
            self.processPendingInvites()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.pendingInvites.removeAll { $0.peer == peerID }
            self.peerConnectionCounts.removeValue(forKey: peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[ChatManager] 탐색 시작 실패: \(error.localizedDescription)")
    }
}
