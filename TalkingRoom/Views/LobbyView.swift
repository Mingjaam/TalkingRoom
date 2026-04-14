//
//  LobbyView.swift
//  TalkingRoom
//

import SwiftUI

struct LobbyView: View {
    @Environment(ChatManager.self) private var chatManager
    @State private var nameText = ""
    @State private var isAnimating = false
    @FocusState private var isNameFocused: Bool
    
    private let brandBlue = Color(red: 0x51 / 255, green: 0x70 / 255, blue: 0xFF / 255)

    // 파동 링 반지름 목록
    private let rings: [CGFloat] = [80, 120, 160, 200]

    var body: some View {
        ZStack {
            // 배경 그라데이션
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.985, blue: 1.0),
                    Color(red: 0.94, green: 0.96, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: - 레이더 애니메이션
                ZStack {
                    ForEach(Array(rings.enumerated()), id: \.offset) { index, diameter in
                        Circle()
                            .stroke(
                                Color.blue.opacity(0.2 - Double(index) * 0.04),
                                lineWidth: 1.5
                            )
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(isAnimating ? 1.08 : 0.95)
                            .animation(
                                .easeInOut(duration: 1.8)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.25),
                                value: isAnimating
                            )
                    }

                    // 중앙 아이콘 원
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 72, height: 72)
                        .overlay {
                            Circle()
                                .stroke(Color.blue.opacity(0.4), lineWidth: 1)
                        }
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(Color.blue)
                        }
                        .scaleEffect(isAnimating ? 1.04 : 0.96)
                        .animation(
                            .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                            value: isAnimating
                        )
                }
                .frame(width: 220, height: 220)
                .onAppear { isAnimating = true }

                // MARK: - 타이틀
                VStack(spacing: 6) {
                    Text("Room 404")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(brandBlue)

                    Text("같은 공간, 자유로운 대화")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.4, green: 0.45, blue: 0.55))
                }
                .padding(.top, 28)

                Spacer()

                // MARK: - 입력 영역
                VStack(spacing: 14) {
                    // 닉네임 입력
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.5, green: 0.55, blue: 0.65))

                        TextField("", text: $nameText)
                            .placeholder(when: nameText.isEmpty) {
                                Text("닉네임 (선택사항)")
                                    .foregroundStyle(Color(red: 0.65, green: 0.68, blue: 0.75))
                            }
                            .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.2))
                            .tint(Color.blue)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .onSubmit { isNameFocused = false }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isNameFocused ? Color.blue.opacity(0.5) : Color(red: 0.82, green: 0.85, blue: 0.9), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)

                    // 탐색 시작 버튼
                    Button {
                        isNameFocused = false
                        chatManager.start(displayName: nameText.isEmpty ? nil : nameText)
                    } label: {
                        HStack(spacing: 10) {
                            Text("주변 사람 찾기")
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color(red: 0.3, green: 0.5, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Color.blue.opacity(0.4), radius: 12, y: 4)
                    }

                    // 권한 안내
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                        Text("·")
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Wi-Fi · Bluetooth 권한이 필요합니다")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.55, green: 0.6, blue: 0.7))
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
            }
        }
        .onTapGesture {
            isNameFocused = false
        }
    }
}

// MARK: - Placeholder Helper
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow { placeholder() }
            self
        }
    }
}

#Preview {
    LobbyView()
        .environment(ChatManager())
}
