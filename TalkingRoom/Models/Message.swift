//
//  Message.swift
//  TalkingRoom
//

import Foundation

struct Message: Identifiable, Codable {
    let id: UUID
    let senderId: String
    let senderName: String
    let timestamp: Date
    let text: String
    var hopCount: Int
    var isSystemMessage: Bool

    init(
        id: UUID = UUID(),
        senderId: String,
        senderName: String,
        timestamp: Date = Date(),
        text: String,
        hopCount: Int,
        isSystemMessage: Bool = false
    ) {
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.timestamp = timestamp
        self.text = text
        self.hopCount = hopCount
        self.isSystemMessage = isSystemMessage
    }
}
