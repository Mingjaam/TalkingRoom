//
//  TopologyView.swift
//  TalkingRoom
//

import SwiftUI

// MARK: - Force-Directed Physics Simulation
@Observable
final class PhysicsSimulation {
    var positions: [String: CGPoint] = [:]

    private var velocities: [String: CGVector] = [:]
    private var pinnedId: String? = nil
    private var nodeIds: [String] = []
    private var edgeSet: [(from: String, to: String)] = []
    private var size: CGSize = .zero
    private var timer: Timer?

    // 물리 상수
    private let repulsion:   Double = 6000
    private let springK:     Double = 0.10
    private let idealLength: Double = 170
    private let centerK:     Double = 0.025
    private let damping:     Double = 0.76
    private let dt:          Double = 0.016
    private let maxSpeed:    Double = 350
    private let minNodeDist: Double = 90   // 노드 간 최소 거리 (겹침 방지)

    // MARK: Setup
    func setup(nodeIds: [String],
               edges: [(from: String, to: String)],
               size: CGSize) {
        // size가 아직 0이면 실제 레이아웃 전 — 위치 초기화만 미루고 edge/node 목록은 업데이트
        let effectiveW = max(size.width,  390.0)
        let effectiveH = max(size.height, 680.0)
        if size.width > 0 { self.size = size }
        else { self.size = CGSize(width: effectiveW, height: effectiveH) }
        self.edgeSet = edges

        let newSet = Set(nodeIds)
        let oldSet = Set(self.nodeIds)
        let margin = 70.0

        // 새 노드: 캔버스 전체에 고르게 랜덤 배치
        for id in nodeIds where !oldSet.contains(id) {
            positions[id] = CGPoint(
                x: Double.random(in: margin ..< effectiveW - margin),
                y: Double.random(in: margin ..< effectiveH - margin))
            velocities[id] = .zero
        }
        // 사라진 노드 제거
        for id in oldSet where !newSet.contains(id) {
            positions.removeValue(forKey: id)
            velocities.removeValue(forKey: id)
        }
        self.nodeIds = nodeIds
    }

    /// 레이아웃 완료 후 실제 크기가 들어오면 size만 갱신 (위치 리셋 없음)
    func updateSize(_ newSize: CGSize) {
        guard newSize.width > 0 else { return }
        self.size = newSize
    }

    // MARK: Timer
    func startSimulation() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stopSimulation() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Drag
    func pin(_ id: String, at point: CGPoint) {
        pinnedId = id
        positions[id] = point
        velocities[id] = .zero
    }

    func unpin() { pinnedId = nil }

    // MARK: Physics Step
    private func step() {
        let ids = nodeIds
        var forces: [String: CGVector] = [:]
        for id in ids { forces[id] = .zero }

        // 반발력 (모든 쌍)
        for i in 0 ..< ids.count {
            for j in (i + 1) ..< ids.count {
                let a = ids[i], b = ids[j]
                guard let pa = positions[a], let pb = positions[b] else { continue }
                let dx = Double(pa.x - pb.x)
                let dy = Double(pa.y - pb.y)
                let d2 = max(dx * dx + dy * dy, 1)
                let d  = sqrt(d2)
                let f  = repulsion / d2
                let fx = f * dx / d
                let fy = f * dy / d
                forces[a]! = CGVector(dx: forces[a]!.dx + fx, dy: forces[a]!.dy + fy)
                forces[b]! = CGVector(dx: forces[b]!.dx - fx, dy: forces[b]!.dy - fy)
            }
        }

        // 스프링 인력 (엣지)
        for edge in edgeSet {
            guard let pa = positions[edge.from],
                  let pb = positions[edge.to] else { continue }
            let dx = Double(pb.x - pa.x)
            let dy = Double(pb.y - pa.y)
            let d  = max(sqrt(dx * dx + dy * dy), 1)
            let f  = springK * (d - idealLength)
            let fx = f * dx / d, fy = f * dy / d
            if forces[edge.from] != nil {
                forces[edge.from]! = CGVector(dx: forces[edge.from]!.dx + fx,
                                              dy: forces[edge.from]!.dy + fy)
            }
            if forces[edge.to] != nil {
                forces[edge.to]! = CGVector(dx: forces[edge.to]!.dx - fx,
                                            dy: forces[edge.to]!.dy - fy)
            }
        }

        // 중심 인력
        let cx = size.width / 2, cy = size.height / 2
        for id in ids {
            guard let p = positions[id] else { continue }
            forces[id]! = CGVector(
                dx: forces[id]!.dx + centerK * Double(cx - p.x),
                dy: forces[id]!.dy + centerK * Double(cy - p.y))
        }

        // 속도 & 위치 업데이트
        let margin: Double = 48
        for id in ids {
            if id == pinnedId { continue }
            guard var v = velocities[id],
                  var p = positions[id],
                  let f = forces[id] else { continue }

            v = CGVector(dx: (v.dx + f.dx * dt) * damping,
                         dy: (v.dy + f.dy * dt) * damping)

            let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
            if speed > maxSpeed {
                v = CGVector(dx: v.dx * maxSpeed / speed, dy: v.dy * maxSpeed / speed)
            }

            p.x = max(CGFloat(margin), min(size.width  - CGFloat(margin),
                                            p.x + CGFloat(v.dx * dt)))
            p.y = max(CGFloat(margin), min(size.height - CGFloat(margin),
                                            p.y + CGFloat(v.dy * dt)))
            velocities[id] = v
            positions[id]  = p
        }

        // 충돌 해소: 겹친 노드를 강제로 밀어냄
        for i in 0 ..< ids.count {
            for j in (i + 1) ..< ids.count {
                let a = ids[i], b = ids[j]
                guard var pa = positions[a], var pb = positions[b] else { continue }
                let dx = Double(pa.x - pb.x)
                let dy = Double(pa.y - pb.y)
                let d  = sqrt(dx * dx + dy * dy)
                guard d < minNodeDist, d > 0 else { continue }
                let overlap = (minNodeDist - d) / 2.0
                let nx = dx / d, ny = dy / d
                if a != pinnedId {
                    pa.x += CGFloat(nx * overlap)
                    pa.y += CGFloat(ny * overlap)
                    positions[a] = pa
                }
                if b != pinnedId {
                    pb.x -= CGFloat(nx * overlap)
                    pb.y -= CGFloat(ny * overlap)
                    positions[b] = pb
                }
            }
        }
    }
}

// MARK: - Force-Directed Graph View
struct TopologyGraphView: View {
    let nodes: [TopologyNode]
    let edges: [(from: String, to: String)]

    @State private var sim = PhysicsSimulation()
    @State private var canvasSize: CGSize = .zero

    private var meId: String { nodes.first(where: { $0.isMe })?.id ?? "" }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 엣지 레이어: 내 직접 연결 = 파란선, 간접 노드 포함 나머지 = 회색 점선
                Canvas { ctx, _ in
                    for edge in edges {
                        guard let from = sim.positions[edge.from],
                              let to   = sim.positions[edge.to] else { continue }
                        let isMyEdge = (edge.from == meId || edge.to == meId)
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        ctx.stroke(
                            path,
                            with: .color(isMyEdge
                                         ? Color.blue.opacity(0.5)
                                         : Color(.systemGray3).opacity(0.5)),
                            style: StrokeStyle(
                                lineWidth: isMyEdge ? 2.2 : 1.2,
                                dash: isMyEdge ? [] : [5, 4]))
                    }
                }
                // 노드 레이어
                ForEach(nodes) { node in
                    if let pos = sim.positions[node.id] {
                        TopologyNodeView(node: node)
                            .position(pos)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { v in sim.pin(node.id, at: v.location) }
                                    .onEnded   { _ in sim.unpin() }
                            )
                    }
                }
            }
            .onAppear {
                canvasSize = geo.size
                sim.setup(nodeIds: nodes.map { $0.id }, edges: edges, size: geo.size)
                sim.startSimulation()
            }
            .onDisappear {
                sim.stopSimulation()
            }
            // 레이아웃 완료 후 실제 크기 전달 (초기 위치 리셋 없이 경계만 업데이트)
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                sim.updateSize(newSize)
            }
            .onChange(of: nodes.map { $0.id }) {
                sim.setup(nodeIds: nodes.map { $0.id }, edges: edges, size: canvasSize)
            }
            .onChange(of: edges.count) {
                sim.setup(nodeIds: nodes.map { $0.id }, edges: edges, size: canvasSize)
            }
        }
    }
}

// MARK: - Node View
struct TopologyNodeView: View {
    let node: TopologyNode

    private var color: Color {
        if node.isMe     { return .blue }
        if node.isDirect { return node.isRelay ? .blue : Color(.systemGray2) }
        return Color(.systemGray3)
    }
    private var nodeSize: CGFloat { node.isMe ? 54 : (node.isDirect ? 44 : 34) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(node.isMe ? color : color.opacity(0.12))
                    .frame(width: nodeSize, height: nodeSize)
                if !node.isMe {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: nodeSize, height: nodeSize)
                }
                Image(systemName: iconName)
                    .font(.system(size: node.isMe ? 20 : 13, weight: .medium))
                    .foregroundStyle(node.isMe ? .white : color)
            }
            Text(node.isMe ? "나" : node.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 72)
        }
    }

    private var iconName: String {
        if node.isMe      { return "person.fill" }
        if node.isDirect  { return node.isRelay ? "antenna.radiowaves.left.and.right" : "person.fill" }
        return "person.fill.questionmark"
    }
}

#Preview {
    TopologyGraphView(nodes: [], edges: [])
}
