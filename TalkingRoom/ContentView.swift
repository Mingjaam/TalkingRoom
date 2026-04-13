//
//  ContentView.swift
//  TalkingRoom
//

import SwiftUI

struct ContentView: View {
    @Environment(ChatManager.self) private var chatManager

    var body: some View {
        Group {
            if chatManager.isSearching {
                ChatView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                LobbyView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: chatManager.isSearching)
    }
}

#Preview {
    ContentView()
        .environment(ChatManager())
}
