//
//  ChatView.swift
//  TalkingRoom
//

import SwiftUI

struct ChatView: View {
    @Environment(ChatManager.self) private var chatManager
    @State private var inputText = ""
    @State private var showNetworkSheet = false
    @State private var networkInitialTab = NetworkTab.list
    @State private var showLeaveAlert = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBannerView()

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

                ChatInputBar(inputText: $inputText, isFocused: $isInputFocused) {
                    sendMessage()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("TalkingRoom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLeaveAlert = true } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            networkInitialTab = .topology
                            showNetworkSheet = true
                        } label: {
                            Image(systemName: "network")
                                .font(.system(size: 15, weight: .medium))
                        }
                        Button {
                            networkInitialTab = .list
                            showNetworkSheet = true
                        } label: {
                            PeerCountBadge(count: chatManager.reachablePeerCountIncludingMe)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if chatManager.messages.isEmpty {
                    EmptyChatPlaceholder()
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showNetworkSheet) {
                PeerNetworkSheet(initialTab: networkInitialTab)
            }
            .alert("채팅방 나가기", isPresented: $showLeaveAlert) {
                Button("취소", role: .cancel) {}
                Button("나가기", role: .destructive) { chatManager.stop() }
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

    private var count: Int { chatManager.reachablePeerCountIncludingMe }
    private var isConnected: Bool { chatManager.reachablePeerCountExcludingMe > 0 }

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(color: isConnected ? .green : .orange)

            Text(isConnected ? "\(count)명과 채팅 가능" : "주변 사용자 탐색 중...")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isConnected ? Color.green : Color.orange)

            Spacer()
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
            Image(systemName: "person.2.fill").font(.caption)
            Text("\(count)").font(.caption.bold())
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

    private var isMyMessage: Bool { message.senderId == chatManager.anonymousId }

    var body: some View {
        if message.isSystemMessage {
            SystemMessageView(text: message.text)
        } else if isMyMessage {
            MyMessageBubble(message: message)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
        } else {
            OtherMessageBubble(message: message)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .opacity))
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
                    .background(LinearGradient(
                        colors: [Color.blue, Color(red: 0.25, green: 0.45, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
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

    private var avatarColor: Color {
        let hash = message.senderName.unicodeScalars.reduce(0) { $0 + $1.value }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.6, brightness: 0.75)
    }
    private var initial: String { String(message.senderName.prefix(1)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
                    .font(.caption2).fontWeight(.medium)
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
        let w = rect.width, h = rect.height
        let r = min(radius, h / 2)
        if isMe {
            path.move(to: CGPoint(x: w - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: w, y: r),      control: CGPoint(x: w, y: 0))
            path.addLine(to:    CGPoint(x: w, y: h - r))
            path.addQuadCurve(to: CGPoint(x: w - tail, y: h), control: CGPoint(x: w, y: h))
            path.addLine(to:    CGPoint(x: r, y: h))
            path.addQuadCurve(to: CGPoint(x: 0, y: h - r),  control: CGPoint(x: 0, y: h))
            path.addLine(to:    CGPoint(x: 0, y: r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0),      control: CGPoint(x: 0, y: 0))
        } else {
            path.move(to: CGPoint(x: r, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: r),      control: CGPoint(x: 0, y: 0))
            path.addLine(to:    CGPoint(x: 0, y: h - r))
            path.addQuadCurve(to: CGPoint(x: tail, y: h),   control: CGPoint(x: 0, y: h))
            path.addLine(to:    CGPoint(x: w - r, y: h))
            path.addQuadCurve(to: CGPoint(x: w, y: h - r),  control: CGPoint(x: w, y: h))
            path.addLine(to:    CGPoint(x: w, y: r))
            path.addQuadCurve(to: CGPoint(x: w - r, y: 0),  control: CGPoint(x: w, y: 0))
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
                            value: isAnimating)
                }
                Image(systemName: "message.badge.waveform.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.blue.opacity(0.6))
            }
            .frame(width: 130, height: 130)

            Text(chatManager.connectedPeers.isEmpty ? "주변 사람을 찾는 중..." : "첫 메시지를 보내보세요")
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { isAnimating = true }
    }
}

// MARK: - Network Tab Enum
enum NetworkTab { case list, topology }

// MARK: - Combined Network Sheet (목록 + 토폴로지)
struct PeerNetworkSheet: View {
    @Environment(ChatManager.self) private var chatManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: NetworkTab

    init(initialTab: NetworkTab = .list) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch selectedTab {
                case .list:     peerListView
                case .topology: topologyView
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $selectedTab) {
                        Text("목록").tag(NetworkTab.list)
                        Text("지도").tag(NetworkTab.topology)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    // MARK: Peer List Tab
    private var peerListView: some View {
        Group {
            if chatManager.reachablePeerCountExcludingMe == 0 {
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
                        Image(systemName: peer.isMe
                              ? "person.fill"
                              : (peer.isDirect ? "wifi" : "dot.radiowaves.left.and.right"))
                            .font(.system(size: 14))
                            .foregroundStyle(peer.isMe
                                             ? Color.blue
                                             : (peer.isDirect ? Color.blue : Color.orange))
                            .frame(width: 24)
                        Text(peer.isMe ? "\(peer.name) (나)" : peer.name)
                            .font(.body)
                            .fontWeight(peer.isMe ? .semibold : .regular)
                        Spacer()
                        Text(peer.isMe ? "본인" : (peer.isDirect ? "직접" : "간접"))
                            .font(.caption2)
                            .foregroundStyle(peer.isMe ? Color.blue : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(peer.isMe
                                        ? Color.blue.opacity(0.1)
                                        : Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: Topology Tab
    private var topologyView: some View {
        VStack(spacing: 0) {
            if chatManager.topologyNodes.count <= 1 {
                VStack(spacing: 12) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("아직 연결된 피어가 없습니다")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TopologyGraphView(
                    nodes: chatManager.topologyNodes,
                    edges: chatManager.topologyEdges
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 20) {
                topoLegendItem(color: .blue,               filled: true,  label: "나")
                topoLegendItem(color: .blue,               filled: false, label: "직접 연결")
                topoLegendItem(color: Color(.systemGray2), filled: false, label: "간접 연결")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func topoLegendItem(color: Color, filled: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(filled ? color.opacity(0.85) : Color.clear)
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(label)
        }
    }
}

#Preview {
    ChatView()
        .environment(ChatManager())
}
