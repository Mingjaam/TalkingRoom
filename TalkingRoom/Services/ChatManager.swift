//
//  ChatManager.swift
//  TalkingRoom
//

import Foundation
import MultipeerConnectivity
import Observation

private let serviceType = "talking-room"
private let maxConnections = 5
private let maxHopCount = 5
private let propagationFanOut = 3
private let messageTTL: TimeInterval = 600 // 10분

struct ReachablePeer: Identifiable, Equatable {
    let id: String       // anonymousId 또는 MCPeerID.displayName
    let name: String
    let isDirect: Bool   // 직접 MPC 연결 여부
}

@Observable
final class ChatManager: NSObject {
    // MARK: - Observable State
    var messages: [Message] = []
    var connectedPeers: [MCPeerID] = []
    var reachablePeers: [ReachablePeer] = []
    var isSearching: Bool = false

    // MARK: - Identity
    private(set) var anonymousId: String
    private(set) var anonymousName: String

    // MARK: - MultipeerConnectivity (lazy, created on start)
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    // MARK: - Gossip State
    private var seenMessageIDs: Set<UUID> = []
    // senderId(anonymousId) -> displayName (메시지를 통해 알게 된 모든 피어)
    private var seenSenders: [String: String] = [:]
    // MCPeerID -> anonymousId (foundPeer discoveryInfo에서 수집)
    private var peerAnonymousIds: [MCPeerID: String] = [:]

    // MARK: - TTL Timer
    private var ttlTimer: Timer?

    // MARK: - Init
    override init() {
        let uuid = UUID().uuidString
        self.anonymousId = uuid
        // 기본 익명 이름: 앞 4자리 대문자 hex
        let shortId = String(uuid.replacingOccurrences(of: "-", with: "").prefix(4).uppercased())
        self.anonymousName = "익명-\(shortId)"
        super.init()
    }

    // MARK: - Start
    /// 닉네임을 입력받아 네트워크 탐색을 시작한다
    func start(displayName: String? = nil) {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            anonymousName = trimmed
        }

        // MCPeerID는 displayName을 15자 이내로 제한
        let truncated = String(anonymousName.prefix(15))
        myPeerID = MCPeerID(displayName: truncated)

        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let discoveryInfo = ["id": anonymousId]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        advertiser.delegate = self

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self

        isSearching = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startTTLTimer()
    }

    // MARK: - Reachable Peers
    /// 직접 연결 + 메시지를 통해 알게 된 피어를 합산해 reachablePeers를 갱신 (반드시 메인 스레드에서 호출)
    private func updateReachablePeers() {
        var result: [ReachablePeer] = []
        var shownIds = Set<String>()

        // 직접 연결 피어 — anonymousId를 알면 그걸 id로, 모르면 displayName 사용
        for peer in connectedPeers {
            let id = peerAnonymousIds[peer] ?? peer.displayName
            let name = seenSenders[id] ?? peer.displayName
            result.append(ReachablePeer(id: id, name: name, isDirect: true))
            shownIds.insert(id)
        }

        // 메시지를 통해서만 알게 된 피어 (직접 연결 아님, 자신 제외)
        for (id, name) in seenSenders where id != anonymousId && !shownIds.contains(id) {
            result.append(ReachablePeer(id: id, name: name, isDirect: false))
        }

        reachablePeers = result
    }

    // MARK: - Stop
    func stop() {
        // 델리게이트를 먼저 해제 → disconnect 콜백이 우리 쪽에서 실행되지 않아
        // handlePeerDisconnected 내부의 browser.startBrowsingForPeers() 재실행을 차단
        session?.delegate = nil
        advertiser?.delegate = nil
        browser?.delegate = nil

        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        ttlTimer?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.messages = []
            self.connectedPeers = []
            self.reachablePeers = []
            self.seenSenders = [:]
            self.seenMessageIDs = []
            self.peerAnonymousIds = [:]
            self.isSearching = false
        }
    }

    // MARK: - Send Message
    func send(text: String) {
        let message = Message(
            senderId: anonymousId,
            senderName: anonymousName,
            text: text,
            hopCount: maxHopCount
        )
        addToLocal(message)
        propagate(message, excluding: nil)
    }

    // MARK: - Gossip Propagation
    private func propagate(_ message: Message, excluding senderPeer: MCPeerID?) {
        guard let session, !session.connectedPeers.isEmpty else { return }

        var targets = session.connectedPeers
        if let sender = senderPeer {
            targets = targets.filter { $0 != sender }
        }

        let count = min(propagationFanOut, targets.count)
        let selected = Array(targets.shuffled().prefix(count))
        guard !selected.isEmpty else { return }

        var forwarded = message
        forwarded.hopCount -= 1

        guard let data = try? JSONEncoder().encode(forwarded) else { return }
        do {
            try session.send(data, toPeers: selected, with: .reliable)
        } catch {
            print("[ChatManager] 전송 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Local State Update
    private func addToLocal(_ message: Message) {
        seenMessageIDs.insert(message.id)
        DispatchQueue.main.async {
            self.messages.append(message)
        }
    }

    // MARK: - Receive
    private func receive(_ data: Data, from senderPeer: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        guard !seenMessageIDs.contains(message.id) else { return }

        addToLocal(message)

        if !message.isSystemMessage {
            DispatchQueue.main.async {
                self.seenSenders[message.senderId] = message.senderName
                self.updateReachablePeers()
            }
        }

        if message.hopCount > 0 {
            propagate(message, excluding: senderPeer)
        }
    }

    // MARK: - System Messages
    private func addSystemMessage(_ text: String) {
        let msg = Message(
            senderId: "system",
            senderName: "system",
            text: text,
            hopCount: 0,
            isSystemMessage: true
        )
        DispatchQueue.main.async {
            self.messages.append(msg)
        }
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
        }
    }

    // MARK: - Peer Management
    private func handlePeerConnected(_ peerID: MCPeerID) {
        DispatchQueue.main.async {
            if !self.connectedPeers.contains(peerID) {
                self.connectedPeers.append(peerID)
            }
            self.updateReachablePeers()
        }
        addSystemMessage("\(peerID.displayName)님이 참여했습니다")
    }

    private func handlePeerDisconnected(_ peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0 == peerID }
            // 이 피어의 seenSenders 항목 제거 → 목록에서 완전히 사라짐
            if let anonId = self.peerAnonymousIds[peerID] {
                self.seenSenders.removeValue(forKey: anonId)
            }
            self.peerAnonymousIds.removeValue(forKey: peerID)
            self.updateReachablePeers()
        }
        addSystemMessage("\(peerID.displayName)님이 나갔습니다")

        if (session?.connectedPeers.count ?? 0) < maxConnections {
            browser?.startBrowsingForPeers()
        }
    }
}

// MARK: - MCSessionDelegate
extension ChatManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:   handlePeerConnected(peerID)
        case .notConnected: handlePeerDisconnected(peerID)
        case .connecting:  break
        @unknown default:  break
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
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let canAccept = (session?.connectedPeers.count ?? 0) < maxConnections
        invitationHandler(canAccept, canAccept ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[ChatManager] 광고 시작 실패: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension ChatManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // discoveryInfo에서 anonymousId를 미리 저장해 두어 disconnect 시 seenSenders 정리에 활용
        if let anonId = info?["id"] {
            DispatchQueue.main.async {
                self.peerAnonymousIds[peerID] = anonId
            }
        }
        guard (session?.connectedPeers.count ?? 0) < maxConnections else { return }
        guard !(session?.connectedPeers.contains(peerID) ?? false) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[ChatManager] 탐색 시작 실패: \(error.localizedDescription)")
    }
}
