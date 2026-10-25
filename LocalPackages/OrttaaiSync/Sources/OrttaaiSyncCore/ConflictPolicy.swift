// ConflictPolicy.swift
// OrttaaiSync
//
// What to do when a record arrives that this device also holds: from a
// fetch, or as the server's copy when a save was refused. One rule for both,
// so every device ends up with the same record.

import Foundation

/// The parts of a local record a decision needs.
public struct LocalRecordState: Equatable, Sendable {
    public var revision: Revision
    public var isDeleted: Bool
    public var generation: Int64

    public init(revision: Revision, isDeleted: Bool, generation: Int64 = 0) {
        self.revision = revision
        self.isDeleted = isDeleted
        self.generation = generation
    }
}

public enum InboundDecision: Equatable, Sendable {
    /// The remote version wins: store its content and system fields. A local
    /// change still waiting to be sent lost and is dropped.
    case acceptRemote
    /// The local version wins: keep it, store the remote system fields (so
    /// the next save overwrites the server's copy) and send it again.
    case keepLocal
    /// Both hold the same version: store the system fields; a pending send of
    /// that same revision is done.
    case alreadyCurrent
}

public enum ConflictPolicy {
    public static func decide(local: LocalRecordState?, remote: SyncEnvelope) -> InboundDecision {
        guard let local else { return .acceptRemote }
        guard let kind = remote.kind else { return .keepLocal }

        if kind.deletionIsTerminal {
            switch (local.isDeleted, remote.isDeleted) {
            case (true, true):
                // Gone on both sides; nothing left to compare.
                return .alreadyCurrent
            case (true, false):
                // A deleted dictation never comes back, whatever the clocks say.
                return .keepLocal
            case (false, true):
                return .acceptRemote
            case (false, false):
                break
            }
        }

        if !kind.deletionIsTerminal {
            // A later life of the record wins outright; within one life, a
            // delete beats any edit, so only an explicit re-add (a new
            // generation) brings a deleted word back.
            if remote.generation != local.generation {
                return remote.generation > local.generation ? .acceptRemote : .keepLocal
            }
            if local.isDeleted != remote.isDeleted {
                return remote.isDeleted ? .acceptRemote : .keepLocal
            }
        }

        if remote.revision > local.revision { return .acceptRemote }
        if remote.revision < local.revision { return .keepLocal }
        return .alreadyCurrent
    }
}
