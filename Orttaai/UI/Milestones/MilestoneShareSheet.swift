// MilestoneShareSheet.swift
// Orttaai

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pick a card for a badge (or for the numbers so far), see it at size, and
/// save, copy or share the image. Cards show numbers only.
struct MilestoneShareSheet: View {
    let subject: MilestoneShareSubject

    @ObservedObject private var center = MilestoneCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MilestoneShareSubject
    @State private var template: ShareCardTemplate = .mountain
    @State private var size: ShareCardSize = .portrait
    @State private var stripStart = 0
    @State private var feedback: String?
    @State private var anchor = ShareAnchorBox()

    private static let thumbnailScale: CGFloat = 78.0 / 1080.0
    private static let visibleThumbnails = 5

    init(subject: MilestoneShareSubject) {
        self.subject = subject
        _selection = State(initialValue: subject)
        _template = State(initialValue: Self.templates(for: subject).first ?? .mountain)
    }

    /// The designs for a milestone's kind: its own picture first.
    private static func templates(for subject: MilestoneShareSubject) -> [ShareCardTemplate] {
        if case .badge(let badge) = subject { return ShareCardKind(badge: badge).templates }
        return ShareCardKind.progress.templates
    }

    private var templates: [ShareCardTemplate] { Self.templates(for: selection) }

    private var badge: MilestoneBadge? {
        if case .badge(let badge) = selection { return badge }
        return nil
    }

    private var content: ShareCardContent {
        ShareCardContent(
            stats: center.stats,
            badge: badge,
            earnedOn: badge.flatMap { center.unlocks[$0.id]?.unlockedAt }
        )
    }

    private func card(_ template: ShareCardTemplate, _ size: ShareCardSize) -> ShareCardView {
        ShareCardView(template: template, content: content, size: size, unlocked: center.unlockedBadges)
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(width: 560)
                .frame(maxHeight: .infinity)
                .background(Color(hex: "141416"))
            Divider()
            controls
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 1080, height: 680)
        .background(Color.Orttaai.bgPrimary)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Preview

    private var preview: some View {
        let pixels = size.pixels
        let scale = min(470 / pixels.width, 600 / pixels.height)
        return card(template, size)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: pixels.width * scale, height: pixels.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(template.title) card preview")
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Share your milestone")
                        .font(.system(size: 22, weight: .heavy))
                    Text("Cards show your numbers only, never anything you dictated.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Color.Orttaai.border, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Milestone")
                OrttaaiDropdown(selection: $selection, options: milestoneOptions)
                    .accessibilityLabel("Milestone")
                    .onChange(of: selection) { _, newValue in
                        // Each milestone opens on its own picture.
                        template = Self.templates(for: newValue).first ?? .signal
                        stripStart = 0
                    }
            }

            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Design · \(templates.count) for this milestone")
                templateStrip
            }

            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Size")
                HStack(spacing: 8) {
                    ForEach(ShareCardSize.allCases) { option in
                        chip(option.title, selected: size == option) { size = option }
                    }
                }
            }

            Spacer(minLength: 0)

            if let feedback {
                Text(feedback)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                Button(action: saveImage) {
                    Label("Save image", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(ShareSheetButtonStyle(primary: false))
                Button(action: copyImage) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(ShareSheetButtonStyle(primary: false))
                Button(action: shareImage) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ShareSheetButtonStyle(primary: true))
                .background(ShareAnchorView(box: anchor))
                .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(Color.Orttaai.textPrimary)
    }

    private var milestoneOptions: [OrttaaiDropdown<MilestoneShareSubject>.Option] {
        [.init(.progress, "\(center.stats.totalWords.formatted()) words · my stats so far")]
            + center.unlockedBadges.map { .init(.badge($0), badgeLabel($0)) }
    }

    private func badgeLabel(_ badge: MilestoneBadge) -> String {
        guard let date = center.unlocks[badge.id]?.unlockedAt else { return badge.name }
        return "\(badge.name) · \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.Orttaai.textSecondary)
    }

    /// Five thumbnails at a time, moved two at a time by the arrows; the
    /// edge where more are waiting fades out under its arrow.
    private var templateStrip: some View {
        let all = templates
        let maxStart = max(0, all.count - Self.visibleThumbnails)
        let start = min(stripStart, maxStart)
        return ZStack {
            HStack(spacing: 12) {
                ForEach(all) { option in
                    thumbnail(option)
                }
            }
            .padding(4)
            .offset(x: -CGFloat(start) * 90)
            .frame(width: 466, alignment: .leading)
            .clipped()
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: start)

            HStack {
                if start > 0 {
                    stripArrow("chevron.left", label: "Show earlier templates", edge: .leading) {
                        stripStart = max(0, start - 2)
                    }
                }
                Spacer()
                if start < maxStart {
                    stripArrow("chevron.right", label: "Show more templates", edge: .trailing) {
                        stripStart = min(maxStart, start + 2)
                    }
                }
            }
        }
        .frame(width: 466)
    }

    private func thumbnail(_ option: ShareCardTemplate) -> some View {
        let selected = option == template
        return Button {
            template = option
        } label: {
            VStack(spacing: 8) {
                card(option, .portrait)
                    .scaleEffect(Self.thumbnailScale, anchor: .topLeading)
                    .frame(width: 78, height: 97.5, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.Orttaai.accent : Color.Orttaai.border, lineWidth: selected ? 2 : 1)
                            .padding(-3)
                    )
                Text(option.title)
                    .font(.system(size: 12, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color(hex: "E8B45A") : Color(hex: "C7C7CC"))
                    .lineLimit(1)
            }
            .frame(width: 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel("\(option.title) template")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stripArrow(_ symbol: String, label: String, edge: HorizontalEdge, action: @escaping () -> Void) -> some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            LinearGradient(
                colors: [Color.Orttaai.bgPrimary.opacity(0), Color.Orttaai.bgPrimary],
                startPoint: edge == .leading ? .trailing : .leading,
                endPoint: edge == .leading ? .leading : .trailing
            )
            .frame(width: 90)
            .allowsHitTesting(false)
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(edge == .trailing ? Color(hex: "E8B45A") : Color.Orttaai.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.Orttaai.bgSecondary))
                    .overlay(Circle().strokeBorder(edge == .trailing ? Color.Orttaai.accent : Color(hex: "48484A"), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel(label)
        }
        .frame(height: 130)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Color(hex: "E8B45A") : Color(hex: "C7C7CC"))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(selected ? Color.Orttaai.accent.opacity(0.14) : .clear))
                .overlay(Capsule().strokeBorder(selected ? Color.Orttaai.accent : Color.Orttaai.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Export

    private var fileName: String {
        let what = badge?.id ?? "progress"
        return "Orttaai-\(what)-\(template.rawValue)-\(size.rawValue).png"
    }

    private func renderPNG() -> Data? {
        ShareCardRenderer.pngData(for: card(template, size))
    }

    private func saveImage() {
        guard let data = renderPNG() else { return show("Couldn't draw the card.") }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            show("Saved \(url.lastPathComponent)")
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
    }

    private func copyImage() {
        guard let image = ShareCardRenderer.image(for: card(template, size)) else { return show("Couldn't draw the card.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        show("Copied. Paste it into a post or a message.")
    }

    private func shareImage() {
        guard let data = renderPNG() else { return show("Couldn't draw the card.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrttaaiShare", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return show("Couldn't prepare the card: \(error.localizedDescription)")
        }
        guard let view = anchor.view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func show(_ message: String) {
        withAnimation { feedback = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if feedback == message { feedback = nil } }
        }
    }
}

private struct ShareSheetButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: primary ? .bold : .semibold))
            .foregroundStyle(primary ? Color.Orttaai.bgPrimary : Color.Orttaai.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(primary ? Color.Orttaai.accent : .clear))
            .overlay(Capsule().strokeBorder(primary ? .clear : Color.Orttaai.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .pointingHandCursor()
    }
}

/// Holds the AppKit view the macOS share picker opens from.
final class ShareAnchorBox {
    weak var view: NSView?
}

private struct ShareAnchorView: NSViewRepresentable {
    let box: ShareAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
