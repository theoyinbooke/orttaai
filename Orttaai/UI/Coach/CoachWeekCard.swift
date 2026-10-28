// CoachWeekCard.swift
// Orttaai
//
// The weekly card to share: the week's headline, your voice shape and three
// numbers. Numbers only, never anything you said, as with Milestones cards.

import AppKit
import CoachCore
import SwiftUI
import UniformTypeIdentifiers

struct CoachWeekCard: View {
    static let size = CGSize(width: 1_080, height: 1_350)

    let snapshot: CoachSnapshot

    var body: some View {
        let shape = snapshot.allShape
        VStack(alignment: .leading, spacing: 40) {
            HStack(spacing: 16) {
                OrttaaiBrandMark()
                    .frame(width: 42, height: 36)
                Text("COACH")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(2.6)
                    .foregroundStyle(Color.Orttaai.accent)
                Spacer()
                Text("Week of \(weekStart.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 22))
                    .foregroundStyle(CoachStyle.ink3)
            }
            headline
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .foregroundStyle(CoachStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            VoiceShapeView(shape: shape, labelFont: .system(size: 20, weight: .semibold))
                .frame(width: 600, height: 600)
                .frame(maxWidth: .infinity)
            HStack(spacing: 24) {
                stat("\(snapshot.dictationsThisWeek)", "dictations")
                stat(snapshot.wordsThisWeek.formatted(), "words")
                stat("\(snapshot.week.filter(\.dictated).count)", "days dictated")
            }
            Spacer(minLength: 0)
            HStack {
                Text("Counted on my Mac")
                Spacer()
                Text("Made with Orttaai")
            }
            .font(.system(size: 20))
            .foregroundStyle(CoachStyle.ink3)
        }
        .padding(80)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(CoachStyle.ground)
        .environment(\.colorScheme, .dark)
    }

    private var weekStart: Date {
        snapshot.week.first?.date ?? snapshot.builtAt
    }

    private var headline: Text {
        if let habit = snapshot.headlineHabit, let share = habit.verdict.afterShare {
            return Text("I \(Self.phrase(for: habit)) in ")
                + Text(CoachFormat.percent(share)).foregroundColor(Color.Orttaai.accent)
                + Text(" of my recent dictations.")
        }
        let days = snapshot.week.filter(\.dictated).count
        return Text("I talked instead of typed on ")
            + Text("\(days) \(days == 1 ? "day" : "days")").foregroundColor(Color.Orttaai.accent)
            + Text(" this week.")
    }

    static func phrase(for habit: CoachHabitState) -> String {
        guard let measure = habit.measure else {
            return "met \"\(habit.title.lowercased())\""
        }
        switch measure {
        case .fillers: return "kept ums and uhs down"
        case .phrases: return "kept filler phrases out"
        case .pace: return "kept a steady pace"
        case .sentences: return "kept my sentences short"
        case .repeats: return "said each word once"
        case .clarity: return "said it right first time"
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundStyle(CoachStyle.ink)
            Text(label)
                .font(.system(size: 22))
                .foregroundStyle(CoachStyle.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preview the weekly card, then save, copy or share it.
struct CoachWeekShareSheet: View {
    let snapshot: CoachSnapshot

    var body: some View {
        CoachCardShareSheet(
            title: "Share this week",
            fileName: "Orttaai-Coach-week-\(snapshot.builtAt.formatted(.iso8601.year().month().day())).png",
            size: CoachWeekCard.size,
            card: CoachWeekCard(snapshot: snapshot)
        )
    }
}

/// Preview a Coach card, then save, copy or share it as a PNG.
struct CoachCardShareSheet<Card: View>: View {
    let title: String
    let fileName: String
    let size: CGSize
    let card: Card
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?
    @State private var anchor = CoachShareAnchor()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            card
                .scaleEffect(0.36, anchor: .topLeading)
                .frame(width: size.width * 0.36, height: size.height * 0.36, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Card preview")
            HStack(spacing: 10) {
                Button("Save image…", action: save)
                Button("Copy", action: copy)
                Button("Share…", action: share)
                    .background(CoachShareAnchorView(anchor: anchor))
            }
            .buttonStyle(CoachSecondaryButtonStyle())
            if let feedback {
                Text(feedback)
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(CoachStyle.ground)
        .preferredColorScheme(.dark)
    }

    private func pngData() -> Data? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func save() {
        guard let data = pngData() else { return feedback = "Couldn't draw the card." }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            feedback = "Saved \(url.lastPathComponent)"
        } catch {
            feedback = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func copy() {
        guard let data = pngData(), let image = NSImage(data: data) else { return feedback = "Couldn't draw the card." }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        feedback = "Copied. Paste it into a post or a message."
    }

    private func share() {
        guard let data = pngData() else { return feedback = "Couldn't draw the card." }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrttaaiShare", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return feedback = "Couldn't prepare the card: \(error.localizedDescription)"
        }
        guard let view = anchor.view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Where the share picker opens from.
final class CoachShareAnchor {
    weak var view: NSView?
}

private struct CoachShareAnchorView: NSViewRepresentable {
    let anchor: CoachShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
