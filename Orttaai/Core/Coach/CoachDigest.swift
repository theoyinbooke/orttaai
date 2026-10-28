// CoachDigest.swift
// Orttaai
//
// Coach on this Mac in a few names and numbers, sent to the phone inside the
// Mac's summary: the voice shapes, habits and how far each track has come.
// Never anything that was said.

import CoachCore
import Foundation
import OrttaaiSyncCore
import os

nonisolated enum CoachDigest {
    private static let latestDigest = OSAllocatedUnfairLock<CoachDigestPayload?>(initialState: nil)

    /// The digest to send with the next summary; nil while Coach is off or
    /// hasn't looked yet.
    static var latest: CoachDigestPayload? {
        latestDigest.withLock { $0 }
    }

    static func update(_ digest: CoachDigestPayload?) {
        latestDigest.withLock { $0 = digest }
    }

    static func make(from snapshot: CoachSnapshot) -> CoachDigestPayload {
        let shapes = CoachMode.shaped.compactMap { mode -> CoachDigestPayload.Shape? in
            let shape = snapshot.shape(for: mode)
            let dictations = snapshot.recentByMode[mode] ?? 0
            guard dictations > 0 else { return nil }
            return CoachDigestPayload.Shape(
                mode: mode.title,
                dictations: dictations,
                axes: shape.axes.map { axis in
                    CoachDigestPayload.Axis(title: axis.title, now: shape.nowAxes[axis], before: shape.thenAxes[axis])
                }
            )
        }
        let habits = snapshot.habits.map { state in
            CoachDigestPayload.Habit(
                title: state.title,
                mode: state.mode?.title,
                status: status(state.verdict.status),
                since: min(state.verdict.sinceCount, HabitJudge.window),
                window: HabitJudge.window,
                beforeShare: state.verdict.beforeShare,
                sinceShare: state.verdict.afterShare
            )
        }
        let tracks = CoachTrack.allCases.map { track in
            CoachDigestPayload.Track(
                title: track.title,
                level: snapshot.level(of: track),
                mastered: snapshot.masteredCount(in: track),
                skills: track.skills.count,
                current: snapshot.currentSkill(in: track).title
            )
        }
        return CoachDigestPayload(shapes: shapes, habits: habits, tracks: tracks, repsThisWeek: snapshot.repsThisWeek)
    }

    private static func status(_ status: HabitStatus) -> CoachDigestPayload.Habit.Status {
        switch status {
        case .watching: return .watching
        case .working: return .working
        case .notMoving: return .notMoving
        }
    }
}
