// ConceptGraphCanvas.swift
// Orttaai

import SwiftUI
import AppKit

/// What the canvas draws: a node per concept, sized by importance and
/// grouped by theme, and a line per association.
struct GraphCanvasNode: Identifiable, Hashable {
    let id: String
    let title: String
    let color: Color
    /// Relative importance in 0...1; drives radius and label priority.
    let size: Double
    /// Theme membership; nodes of one group start (and tend to stay) together.
    let group: String?
}

struct GraphCanvasEdge: Hashable {
    let sourceID: String
    let targetID: String
    /// Association strength in 0...1.
    let strength: Double
}

struct GraphCanvasModel {
    var nodes: [GraphCanvasNode]
    var edges: [GraphCanvasEdge]

    var signature: String {
        var hasher = Hasher()
        for node in nodes { hasher.combine(node.id); hasher.combine(node.size) }
        for edge in edges { hasher.combine(edge.sourceID); hasher.combine(edge.targetID) }
        return "\(nodes.count)#\(edges.count)#\(hasher.finalize())"
    }
}

/// Zoomable, pannable force-directed map. Hover or select a concept to bring
/// it and its connections forward; everything else recedes.
struct ConceptGraphCanvas: View {
    let model: GraphCanvasModel
    @Binding var selectedNodeID: String?
    /// Nodes to bring forward when nothing is hovered or selected (a theme).
    var highlightedIDs: Set<String> = []

    @State private var layout = GraphCanvasLayout.empty
    @State private var layoutSignature = ""
    @State private var viewport = GraphViewport()
    @State private var hoveredNodeID: String?

    var body: some View {
        GeometryReader { proxy in
            let signature = model.signature
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(context: &context, size: size)
                }
                .background(Color.Orttaai.bgPrimary.opacity(0.92))

                GraphInteractionOverlay(
                    layout: layout,
                    viewport: $viewport,
                    hoveredNodeID: $hoveredNodeID,
                    selectedNodeID: $selectedNodeID,
                    onFit: { viewport.fit(bounds: layout.bounds, in: proxy.size) }
                )

                controls(size: proxy.size)
                    .padding(Spacing.sm)
            }
            .clipped()
            .onAppear { rebuildLayout(signature: signature, size: proxy.size) }
            .onChange(of: signature) { _, newSignature in rebuildLayout(signature: newSignature, size: proxy.size) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Concept map with \(model.nodes.count) concepts. Use the list beside it to explore them.")
        }
    }

    private var focusID: String? { hoveredNodeID ?? selectedNodeID }

    private var focusIDs: Set<String> {
        if let focusID {
            var ids = layout.neighborIDs[focusID] ?? []
            ids.insert(focusID)
            return ids
        }
        return highlightedIDs
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard !layout.nodes.isEmpty else { return }
        let focus = focusIDs
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)

        for edge in layout.edges {
            guard let a = layout.node(id: edge.sourceID), let b = layout.node(id: edge.targetID) else { continue }
            let start = viewport.project(a.position, in: size)
            let end = viewport.project(b.position, in: size)
            let touchesFocus = focusID.map { edge.sourceID == $0 || edge.targetID == $0 } ?? false
            let inFocus = focus.isEmpty || (focus.contains(edge.sourceID) && focus.contains(edge.targetID))
            let opacity = touchesFocus ? 0.35 + edge.strength * 0.5 : (inFocus ? 0.1 + edge.strength * 0.35 : 0.03)
            guard CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
                .insetBy(dx: -20, dy: -20).intersects(visible) else { continue }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(Color.Orttaai.textSecondary.opacity(opacity)),
                lineWidth: max(0.6, (0.6 + edge.strength * 2.4) * pow(viewport.scale, 0.3))
            )
        }

        let ordered = layout.nodes.sorted { $0.size < $1.size }
        let labelBudget = labelCount
        let labelled = Set(layout.nodes.sorted { $0.size > $1.size }.prefix(labelBudget).map(\.id))
        var pendingLabels: [(node: GraphCanvasLayoutNode, point: CGPoint, isFocus: Bool, isRelated: Bool)] = []
        for node in ordered {
            let position = viewport.project(node.position, in: size)
            guard visible.contains(position) else { continue }
            let radius = screenRadius(node)
            let isFocus = focusID == node.id
            let isRelated = focus.isEmpty || focus.contains(node.id)
            let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
            if isFocus {
                context.fill(Path(ellipseIn: rect.insetBy(dx: -7, dy: -7)), with: .color(node.color.opacity(0.2)))
            }
            context.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(isRelated ? 0.92 : 0.18)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(isFocus ? 0.7 : 0.14)), lineWidth: isFocus ? 1.6 : 1)

            let showsLabel = isFocus || (isRelated && (!focus.isEmpty || labelled.contains(node.id)))
            if showsLabel {
                pendingLabels.append((node, CGPoint(x: position.x, y: position.y + radius + 6), isFocus, isRelated))
            }
        }

        // Most important labels first; a label that would overlap one
        // already placed is skipped rather than drawn on top of it.
        var placed: [CGRect] = []
        for label in pendingLabels.sorted(by: { ($0.isFocus ? 2 : 0) + $0.node.size > ($1.isFocus ? 2 : 0) + $1.node.size }) {
            let fontSize = label.isFocus ? 12.5 : max(10, min(12.5, 10 + viewport.scale * 1.2))
            let text = Text(label.node.title)
                .font(.system(size: fontSize, weight: label.isFocus || label.node.size > 0.6 ? .semibold : .medium))
                .foregroundStyle(Color.Orttaai.textPrimary.opacity(label.isRelated ? 0.95 : 0.4))
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: CGSize(width: 240, height: 40))
            let rect = CGRect(x: label.point.x - measured.width / 2, y: label.point.y, width: measured.width, height: measured.height)
                .insetBy(dx: -3, dy: -1)
            guard label.isFocus || !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            context.draw(resolved, at: label.point, anchor: .top)
        }
    }

    /// More labels as you zoom in, so the overview stays readable.
    private var labelCount: Int {
        switch viewport.detailLevel {
        case .overview: return 12
        case .context: return 24
        case .detail: return 48
        case .inspection: return .max
        }
    }

    private func screenRadius(_ node: GraphCanvasLayoutNode) -> CGFloat {
        max(4, min(node.baseRadius * pow(viewport.scale, 0.55), node.baseRadius * 1.8))
    }

    private func controls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            controlButton("minus.magnifyingglass", help: "Zoom out") {
                viewport.zoom(by: 0.78, around: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            controlButton("plus.magnifyingglass", help: "Zoom in") {
                viewport.zoom(by: 1.28, around: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            controlButton("viewfinder", help: "Fit the map") {
                viewport.fit(bounds: layout.bounds, in: size)
            }
        }
        .padding(4)
        .background(Color.Orttaai.bgSecondary.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.7), lineWidth: BorderWidth.standard)
        )
    }

    private func controlButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Orttaai.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func rebuildLayout(signature: String, size: CGSize) {
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        layout = GraphCanvasLayoutEngine.build(for: model)
        hoveredNodeID = nil
        viewport.fit(bounds: layout.bounds, in: size)
    }
}

struct GraphCanvasLayout {
    var nodes: [GraphCanvasLayoutNode]
    var edges: [GraphCanvasEdge]
    var nodeByID: [String: GraphCanvasLayoutNode]
    var neighborIDs: [String: Set<String>]
    var bounds: CGRect

    static let empty = GraphCanvasLayout(nodes: [], edges: [], nodeByID: [:], neighborIDs: [:], bounds: .zero)

    func node(id: String) -> GraphCanvasLayoutNode? { nodeByID[id] }
}

struct GraphCanvasLayoutNode: Identifiable {
    let id: String
    let title: String
    let color: Color
    let size: Double
    let baseRadius: CGFloat
    let position: CGPoint
}

/// Force-directed layout, deterministic for a given model. Themes start in
/// their own sector and are pulled gently toward their center, so groups
/// read as regions rather than a single hairball.
enum GraphCanvasLayoutEngine {
    private struct Body {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        let radius: CGFloat
        let group: Int?
    }

    static func build(for model: GraphCanvasModel) -> GraphCanvasLayout {
        guard !model.nodes.isEmpty else { return .empty }
        let groups = Array(Set(model.nodes.compactMap(\.group))).sorted()
        let groupIndex = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element, $0.offset) })
        let index = Dictionary(uniqueKeysWithValues: model.nodes.enumerated().map { ($0.element.id, $0.offset) })

        var bodies = model.nodes.map { node -> Body in
            let radius = CGFloat(6 + node.size * 15)
            let jitter = jitter(for: node.id)
            if let group = node.group.flatMap({ groupIndex[$0] }) {
                let angle = Double(group) / Double(max(1, groups.count)) * 2 * .pi
                return Body(x: cos(angle) * 240 + jitter.x * 3, y: sin(angle) * 240 + jitter.y * 3, radius: radius, group: group)
            }
            let angle = Double(stableHash(node.id) % 360) / 180 * .pi
            return Body(x: cos(angle) * 280 + jitter.x, y: sin(angle) * 280 + jitter.y, radius: radius, group: nil)
        }
        let links = model.edges.compactMap { edge -> (Int, Int, CGFloat)? in
            guard let a = index[edge.sourceID], let b = index[edge.targetID] else { return nil }
            return (a, b, CGFloat(max(0.05, min(1, edge.strength))))
        }

        let iterations = bodies.count > 120 ? 240 : 320
        for _ in 0..<iterations {
            // Repulsion and collision.
            for i in 0..<bodies.count {
                for j in (i + 1)..<bodies.count {
                    var dx = bodies[j].x - bodies[i].x
                    var dy = bodies[j].y - bodies[i].y
                    var distanceSquared = dx * dx + dy * dy
                    if distanceSquared < 0.01 { dx = 1; dy = 1; distanceSquared = 2 }
                    let distance = sqrt(distanceSquared)
                    let minimum = bodies[i].radius + bodies[j].radius + 22
                    let force = 900 / max(40, distanceSquared) + (distance < minimum ? (minimum - distance) * 0.03 : 0)
                    let fx = dx / distance * force, fy = dy / distance * force
                    bodies[i].vx -= fx; bodies[i].vy -= fy
                    bodies[j].vx += fx; bodies[j].vy += fy
                }
            }
            // Links: stronger associations sit closer; links across themes
            // pull less so each theme reads as its own region.
            for (a, b, strength) in links {
                let dx = bodies[b].x - bodies[a].x, dy = bodies[b].y - bodies[a].y
                let distance = max(1, sqrt(dx * dx + dy * dy))
                let sameTheme = bodies[a].group != nil && bodies[a].group == bodies[b].group
                let target = (sameTheme ? 60 : 130) + (1 - strength) * 80
                let force = (distance - target) * (0.008 + strength * 0.02) * (sameTheme ? 1 : 0.35)
                let fx = dx / distance * force, fy = dy / distance * force
                bodies[a].vx += fx; bodies[a].vy += fy
                bodies[b].vx -= fx; bodies[b].vy -= fy
            }
            // Theme cohesion and a weak pull to the center.
            var centers: [Int: (CGFloat, CGFloat, CGFloat)] = [:]
            for body in bodies {
                guard let group = body.group else { continue }
                let current = centers[group] ?? (0, 0, 0)
                centers[group] = (current.0 + body.x, current.1 + body.y, current.2 + 1)
            }
            for i in bodies.indices {
                if let group = bodies[i].group, let center = centers[group] {
                    bodies[i].vx += (center.0 / center.2 - bodies[i].x) * 0.018
                    bodies[i].vy += (center.1 / center.2 - bodies[i].y) * 0.018
                }
                bodies[i].vx -= bodies[i].x * 0.0025
                bodies[i].vy -= bodies[i].y * 0.0025
                bodies[i].vx = max(-12, min(12, bodies[i].vx * 0.84))
                bodies[i].vy = max(-12, min(12, bodies[i].vy * 0.84))
                bodies[i].x += bodies[i].vx
                bodies[i].y += bodies[i].vy
            }
        }

        let nodes = zip(model.nodes, bodies).map { node, body in
            GraphCanvasLayoutNode(
                id: node.id,
                title: node.title,
                color: node.color,
                size: node.size,
                baseRadius: body.radius,
                position: CGPoint(x: body.x, y: body.y)
            )
        }
        var neighbors: [String: Set<String>] = [:]
        for edge in model.edges {
            neighbors[edge.sourceID, default: []].insert(edge.targetID)
            neighbors[edge.targetID, default: []].insert(edge.sourceID)
        }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for node in nodes {
            minX = min(minX, node.position.x - node.baseRadius)
            maxX = max(maxX, node.position.x + node.baseRadius)
            minY = min(minY, node.position.y - node.baseRadius)
            maxY = max(maxY, node.position.y + node.baseRadius + 18)
        }
        return GraphCanvasLayout(
            nodes: nodes,
            edges: model.edges,
            nodeByID: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            neighborIDs: neighbors,
            bounds: CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        )
    }

    private static func jitter(for value: String) -> CGPoint {
        let hash = stableHash(value)
        return CGPoint(x: CGFloat(Int(hash % 41) - 20), y: CGFloat(Int((hash / 41) % 41) - 20))
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in value.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        return hash
    }
}

enum GraphDetailLevel {
    case overview
    case context
    case detail
    case inspection
}

struct GraphViewport {
    static let minimumScale: CGFloat = 0.28
    static let maximumScale: CGFloat = 4.2

    var scale: CGFloat = 1
    var pan: CGSize = .zero

    var detailLevel: GraphDetailLevel {
        if scale < 0.58 { return .overview }
        if scale < 1.05 { return .context }
        if scale < 1.85 { return .detail }
        return .inspection
    }

    func project(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + point.x * scale + pan.width,
            y: size.height / 2 + point.y * scale + pan.height
        )
    }

    func unproject(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - size.width / 2 - pan.width) / scale,
            y: (point.y - size.height / 2 - pan.height) / scale
        )
    }

    mutating func zoom(by factor: CGFloat, around screenPoint: CGPoint, in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let oldScale = scale
        let newScale = min(Self.maximumScale, max(Self.minimumScale, oldScale * factor))
        guard newScale != oldScale else { return }
        let worldPoint = unproject(screenPoint, in: size)
        scale = newScale
        pan = CGSize(
            width: screenPoint.x - size.width / 2 - worldPoint.x * newScale,
            height: screenPoint.y - size.height / 2 - worldPoint.y * newScale
        )
    }

    mutating func pan(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    mutating func fit(bounds: CGRect, in size: CGSize) {
        guard !bounds.isEmpty, bounds.width > 1, bounds.height > 1, size.width > 1, size.height > 1 else {
            scale = 1
            pan = .zero
            return
        }
        let horizontalScale = (size.width - 72) / bounds.width
        let verticalScale = (size.height - 72) / bounds.height
        let nextScale = min(Self.maximumScale, max(Self.minimumScale, min(horizontalScale, verticalScale)))
        scale = nextScale
        pan = CGSize(
            width: -bounds.midX * nextScale,
            height: -bounds.midY * nextScale
        )
    }
}

struct GraphInteractionOverlay: NSViewRepresentable {
    let layout: GraphCanvasLayout
    @Binding var viewport: GraphViewport
    @Binding var hoveredNodeID: String?
    @Binding var selectedNodeID: String?
    let onFit: () -> Void

    func makeNSView(context: Context) -> GraphInteractionNSView {
        let view = GraphInteractionNSView()
        view.onViewportChange = { viewport = $0 }
        view.onHoverChange = { hoveredNodeID = $0 }
        view.onSelect = { selectedNodeID = $0 }
        view.onFit = onFit
        return view
    }

    func updateNSView(_ nsView: GraphInteractionNSView, context: Context) {
        nsView.layout = layout
        nsView.viewport = viewport
        nsView.hoveredNodeID = hoveredNodeID
        nsView.selectedNodeID = selectedNodeID
        nsView.onFit = onFit
    }
}

final class GraphInteractionNSView: NSView {
    var layout = GraphCanvasLayout.empty
    var viewport = GraphViewport()
    var hoveredNodeID: String?
    var selectedNodeID: String?
    var onViewportChange: (GraphViewport) -> Void = { _ in }
    var onHoverChange: (String?) -> Void = { _ in }
    var onSelect: (String?) -> Void = { _ in }
    var onFit: () -> Void = {}

    private var trackingAreaRef: NSTrackingArea?
    private var lastDragPoint: CGPoint?
    private var mouseDownPoint: CGPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredNodeID = nil
        onHoverChange(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        lastDragPoint = point
        didDrag = false
        updateHover(at: point)
        if event.clickCount == 2 {
            if let nodeID = hitNode(at: point) {
                selectedNodeID = nodeID
                onSelect(nodeID)
                zoomTowardNode(id: nodeID, point: point)
            } else {
                onFit()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastDragPoint else {
            self.lastDragPoint = point
            return
        }
        let delta = CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y)
        if abs(delta.width) > 0.1 || abs(delta.height) > 0.1 {
            didDrag = true
            viewport.pan(by: delta)
            onViewportChange(viewport)
        }
        self.lastDragPoint = point
        updateHover(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            didDrag = false
        }

        if didDrag {
            return
        }

        if let nodeID = hitNode(at: point) {
            selectedNodeID = nodeID
            onSelect(nodeID)
        } else {
            selectedNodeID = nil
            onSelect(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = hitNode(at: point) else {
            selectedNodeID = nil
            onSelect(nil)
            return
        }
        selectedNodeID = nodeID
        onSelect(nodeID)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 8
        let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8

        if abs(horizontal) > abs(vertical) * 1.4 {
            viewport.pan(by: CGSize(width: horizontal, height: 0))
        } else {
            let factor = exp(vertical * 0.006)
            viewport.zoom(by: factor, around: point, in: bounds.size)
        }
        onViewportChange(viewport)
        updateHover(at: point)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewport.zoom(by: max(0.2, 1 + event.magnification), around: point, in: bounds.size)
        onViewportChange(viewport)
        updateHover(at: point)
    }

    override func keyDown(with event: NSEvent) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch event.keyCode {
        case 24, 69:
            viewport.zoom(by: 1.18, around: center, in: bounds.size)
            onViewportChange(viewport)
        case 27, 78:
            viewport.zoom(by: 0.84, around: center, in: bounds.size)
            onViewportChange(viewport)
        case 29, 82:
            onFit()
        case 53:
            selectedNodeID = nil
            onSelect(nil)
        case 123, 124, 125, 126:
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 72 : 28
            switch event.keyCode {
            case 123:
                viewport.pan(by: CGSize(width: distance, height: 0))
            case 124:
                viewport.pan(by: CGSize(width: -distance, height: 0))
            case 125:
                viewport.pan(by: CGSize(width: 0, height: -distance))
            default:
                viewport.pan(by: CGSize(width: 0, height: distance))
            }
            onViewportChange(viewport)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateHover(at point: CGPoint) {
        let nextID = hitNode(at: point)
        guard nextID != hoveredNodeID else { return }
        hoveredNodeID = nextID
        onHoverChange(nextID)
    }

    private func hitNode(at point: CGPoint) -> String? {
        guard !layout.nodes.isEmpty else { return nil }
        var best: (id: String, distance: CGFloat)?
        for node in layout.nodes {
            let screenPoint = viewport.project(node.position, in: bounds.size)
            let radius = max(7, min(node.baseRadius * pow(viewport.scale, 0.58), node.baseRadius * 1.8) + 4)
            let distance = hypot(point.x - screenPoint.x, point.y - screenPoint.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    private func zoomTowardNode(id: String, point: CGPoint) {
        guard layout.node(id: id) != nil else { return }
        viewport.zoom(by: 1.55, around: point, in: bounds.size)
        onViewportChange(viewport)
    }
}
