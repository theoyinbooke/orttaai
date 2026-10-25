// Revision.swift
// OrttaaiSync
//
// Which of two versions of a record is newer. The counter is a Lamport
// clock: a change always takes a number above every one its device has seen,
// so an edit made after seeing another wins whatever the clocks say. Two
// edits made without seeing each other fall back to the wall clock, then the
// writer's ID, so every device picks the same winner.

import Foundation

public struct Revision: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var counter: Int64
    public var modifiedAt: Date
    public var writerDeviceID: String

    public init(counter: Int64, modifiedAt: Date, writerDeviceID: String) {
        self.counter = counter
        self.modifiedAt = modifiedAt
        self.writerDeviceID = writerDeviceID
    }

    public static func < (lhs: Revision, rhs: Revision) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.writerDeviceID < rhs.writerDeviceID
    }

    public var description: String {
        "r\(counter)@\(writerDeviceID.prefix(8))"
    }
}

/// Hands out revisions for one device. The app keeps `counter` in its
/// database and saves it in the same transaction as the change it numbers.
public struct RevisionClock: Sendable, Equatable {
    public private(set) var counter: Int64
    public let deviceID: String

    public init(counter: Int64, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }

    /// The revision for a change made now.
    public mutating func next(at date: Date = Date()) -> Revision {
        counter += 1
        return Revision(counter: counter, modifiedAt: SyncDate.rounded(date), writerDeviceID: deviceID)
    }

    /// Moves past a revision seen on another device.
    public mutating func observe(_ revision: Revision) {
        counter = max(counter, revision.counter)
    }
}

/// CloudKit keeps dates to the millisecond; rounding before comparing means
/// a date that went up and came back still compares equal.
public enum SyncDate {
    public static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
