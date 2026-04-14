//
//  TalkingRoomApp.swift
//  TalkingRoom
//

import SwiftUI

@main
struct TalkingRoomApp: App {
    @State private var chatManager = ChatManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chatManager)
                .preferredColorScheme(.light)
        }
    }
}
