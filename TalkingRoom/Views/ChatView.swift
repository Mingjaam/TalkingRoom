//
//  ChatView.swift
//  TalkingRoom
//

import SwiftUI

struct ChatView: View {
    @Environment(ChatManager.self) private var chatManager
    @State private var inputText = ""
    @State private var showPeerList = false
    @State private var showLeaveAlert = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 연결 상태 배너
                StatusBannerView()

                // 메시지 리스트
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(chatManager.messages) { message in
                                MessageRowView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chatManager.messages.count) {
                        if let lastId = chatManager.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }

                // 입력창
                ChatInputBar(inputText: $inputText, isFocused: $isInputFocused) {
                    sendMessage()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("TalkingRoom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLeaveAlert = true
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPeerList = true } label: {
                        PeerCountBadge(count: chatManager.reachablePeers.count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if chatManager.messages.isEmpty {
                    EmptyChatPlaceholder()
                }
            }
            .sheet(isPresented: $showPeerList) {
                PeerListSheet()
            }
            .alert("채팅방 나가기", isPresented: $showLeaveAlert) {
                Button("취소", role: .cancel) {}
                Button("나가기", role: .destructive) {
                    chatManager.stop()
                }
            } message: {
                Text("연결이 끊깁니다.\n메시지는 모두 지워집니다.")
            }
        }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatManager.send(text: trimmed)
        inputText = ""
    }
}

// MARK: - Status Banner
struct StatusBannerView: View {
    @Environment(ChatManager.self) private var chatManager

    private var count: Int { chatManager.reachablePeers.count }
    private var isConnected: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 8) {
            // 깜빡이는 점
            PulsingDot(color: isConnected ? .green : .orange)

            Text(isConnected ? "\(count)명과 채팅 가능" : "주변 사용자 탐색 중...")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isConnected ? Color.green : Color.orange)

            Spacer()

            if isConnected {
                Text("익명 채팅")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Pulsing Dot
struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 14, height: 14)
                .scaleEffect(isPulsing ? 1.5 : 1.0)
                .opacity(isPulsing ? 0 : 1)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: isPulsing)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear { isPulsing = true }
    }
}

// MARK: - Peer Count Badge
struct PeerCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.fill")
                .font(.caption)
            Text("\(count)")
                .font(.caption.bold())
        }
        .foregroundStyle(count > 0 ? Color.blue : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(count > 0 ? Color.blue.opacity(0.1) : Color(.systemGray6))
        .clipShape(Capsule())
    }
}

// MARK: - Message Row
struct MessageRowView: View {
    @Environment(ChatManager.self) private var chatManager
    let message: Message

    private var isMyMessage: Bool {
        message.senderId == chatManager.anonymousId
    }

    var body: some View {
        if message.isSystemMessage {
            SystemMessageView(text: message.text)
        } else if isMyMessage {
            MyMessageBubble(message: message)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
        } else {
            OtherMessageBubble(message: message)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }
}

// MARK: - System Message
struct SystemMessageView: View {
    let text: String

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - My Message Bubble
struct MyMessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 64)

            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color(red: 0.25, green: 0.45, blue: 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(BubbleShape(isMe: true))
                    .shadow(color: Color.blue.opacity(0.2), radius: 4, y: 2)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
        }
    }
}

// MARK: - Other Message Bubble
struct OtherMessageBubble: View {
    let message: Message

    // 이름 기반으로 일관된 색상 생성
    private var avatarColor: Color {
        let hash = message.senderName.unicodeScalars.reduce(0) { $0 + $1.value }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.75)
    }

    private var initial: String {
        String(message.senderName.prefix(1))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 아바타
            Circle()
                .fill(avatarColor.opacity(0.2))
                .frame(width: 30, height: 30)
                .overlay {
                    Text(initial)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(avatarColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(message.senderName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemBackground))
                    .clipShape(BubbleShape(isMe: false))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 64)
        }
    }
}

// MARK: - Bubble Shape
struct BubbleShape: Shape {
    let isMe: Bool
    private let radius: CGFloat = 18
    private let tail: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let r = min(radius, h / 2)

        if isMe {
            // 오른쪽 말풍선 (오른쪽 하단 꼬리 없이 작은 각)
            path.move(to: CGPoint(x: w - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h - r))
            path.addQuadCurve(to: CGPoint(x: w - tail, y: h), control: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: r, y: h))
            path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        } else {
            // 왼쪽 말풍선
            path.move(to: CGPoint(x: r, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h - r))
            path.addQuadCurve(to: CGPoint(x: tail, y: h), control: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w - r, y: h))
            path.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: r))
            path.addQuadCurve(to: CGPoint(x: w - r, y: 0), control: CGPoint(x: w, y: 0))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Chat Input Bar
struct ChatInputBar: View {
    @Binding var inputText: String
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("메시지를 입력하세요...", text: $inputText, axis: .vertical)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                }
                .lineLimit(1...5)
                .focused(isFocused)

            Button(action: onSend) {
                ZStack {
                    Circle()
                        .fill(canSend
                              ? LinearGradient(colors: [.blue, Color(red: 0.25, green: 0.45, blue: 1)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                              : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray4)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)

                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Empty Placeholder
struct EmptyChatPlaceholder: View {
    @Environment(ChatManager.self) private var chatManager
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.blue.opacity(0.15 + Double(i) * 0.05), lineWidth: 1.5)
                        .frame(width: CGFloat(50 + i * 28))
                        .scaleEffect(isAnimating ? 1.12 : 0.92)
                        .animation(
                            .easeInOut(duration: 1.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: isAnimating
                        )
                }
                Image(systemName: "message.badge.waveform.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.blue.opacity(0.6))
            }
            .frame(width: 130, height: 130)

            Text(chatManager.connectedPeers.isEmpty ? "주변 사람을 찾는 중..." : "첫 메시지를 보내보세요")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { isAnimating = true }
    }
}

// MARK: - Peer List Sheet
struct PeerListSheet: View {
    @Environment(ChatManager.self) private var chatManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if chatManager.reachablePeers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("아직 연결된 사람이 없습니다")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(chatManager.reachablePeers) { peer in
                        HStack(spacing: 12) {
                            Image(systemName: peer.isDirect ? "wifi" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 14))
                                .foregroundStyle(peer.isDirect ? Color.blue : Color.orange)
                                .frame(width: 24)

                            Text(peer.name)
                                .font(.body)

                            Spacer()

                            Text(peer.isDirect ? "직접 연결" : "간접 연결")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.systemGray6))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .navigationTitle("채팅 가능한 사람 (\(chatManager.reachablePeers.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ChatView()
        .environment(ChatManager())
}
