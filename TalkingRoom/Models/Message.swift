//
//  Message.swift
//  TalkingRoom
//

import Foundation

// MARK: - NodeType
enum NodeType: String, Codable, Equatable {
    case relay  // 허브 역할, 최대 10개 연결
    case leaf   // 단말 역할, 최대 3개 연결
}

// MARK: - RoutingInfo
/// 기기의 토폴로지 위치를 나타내는 라우팅 정보 (시스템 메시지로 네트워크 전파)
struct RoutingInfo: Codable, Equatable {
    let nodeId: String       // 해당 기기의 anonymousId
    let nodeType: NodeType
    let connectedTo: String? // 연결된 릴레이 노드의 anonymousId (릴레이 자신은 nil)
}

// MARK: - Message
struct Message: Identifiable, Codable {
    let id: UUID
    let senderId: String
    let senderName: String
    let timestamp: Date
    let text: String
    var hopCount: Int
    var isSystemMessage: Bool
    var routingInfo: RoutingInfo? // non-nil이면 라우팅 전용 시스템 메시지

    init(
        id: UUID = UUID(),
        senderId: String,
        senderName: String,
        timestamp: Date = Date(),
        text: String,
        hopCount: Int,
        isSystemMessage: Bool = false,
        routingInfo: RoutingInfo? = nil
    ) {
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.timestamp = timestamp
        self.text = text
        self.hopCount = hopCount
        self.isSystemMessage = isSystemMessage
        self.routingInfo = routingInfo
    }
}
