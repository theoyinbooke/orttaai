// Payloads.swift
// OrttaaiSync
//
// What each record says, encoded as JSON into the encrypted payload field.
// New fields are always optional, so an older app can still read a payload a
// newer one wrote; anything that would break that bumps the schema version.

import Foundation

public enum PayloadCoder {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// A dictation, whichever device made it.
public struct DictationPayload: Codable, Hashable, Sendable {
    public var createdAt: Date
    /// What was written or typed in.
    public var text: String
    /// What the speech model heard before formatting or Polish, when the
    /// device recorded it. Nil means "not recorded", never "the same".
    public var rawText: String?
    /// The app it was typed into. Nil from the keyboard: iOS doesn't tell a
    /// keyboard which app it's in.
    public var targetAppName: String?
    public var targetAppBundleID: String?
    public var modelID: String?
    public var recordingMs: Int?
    /// The whole pipeline, when known. Not the same as transcription time.
    public var processingMs: Int?
    public var transcriptionMs: Int?
    public var textProcessingMs: Int?
    public var injectionMs: Int?
    public var settingsSyncMs: Int?
    public var appActivationMs: Int?
    public var clipboardRestoreDelayMs: Int?
    public var audioDevice: String?
    public var injectionMethod: String?
    /// "edit" for a voice edit command, nil for a dictation.
    public var entryKind: String?
    public var editInstruction: String?
    /// Where it was said, as an IANA identifier ("Europe/London"), so its
    /// hour and weekday read in that place's time. Nil from older versions.
    public var timeZoneIdentifier: String?

    public init(
        createdAt: Date,
        text: String,
        rawText: String? = nil,
        targetAppName: String? = nil,
        targetAppBundleID: String? = nil,
        modelID: String? = nil,
        recordingMs: Int? = nil,
        processingMs: Int? = nil,
        transcriptionMs: Int? = nil,
        textProcessingMs: Int? = nil,
        injectionMs: Int? = nil,
        settingsSyncMs: Int? = nil,
        appActivationMs: Int? = nil,
        clipboardRestoreDelayMs: Int? = nil,
        audioDevice: String? = nil,
        injectionMethod: String? = nil,
        entryKind: String? = nil,
        editInstruction: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.targetAppName = targetAppName
        self.targetAppBundleID = targetAppBundleID
        self.modelID = modelID
        self.recordingMs = recordingMs
        self.processingMs = processingMs
        self.transcriptionMs = transcriptionMs
        self.textProcessingMs = textProcessingMs
        self.injectionMs = injectionMs
        self.settingsSyncMs = settingsSyncMs
        self.appActivationMs = appActivationMs
        self.clipboardRestoreDelayMs = clipboardRestoreDelayMs
        self.audioDevice = audioDevice
        self.injectionMethod = injectionMethod
        self.entryKind = entryKind
        self.editInstruction = editInstruction
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var isEdit: Bool { entryKind == "edit" }
}

/// A dictionary word or "say this → write that" pair. Usage counts are
/// local to each device and never synced.
public struct DictionaryEntryPayload: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public var normalizedSource: String
    public var isCaseSensitive: Bool
    public var isActive: Bool
    public var createdAt: Date

    public init(source: String, target: String, isCaseSensitive: Bool = false, isActive: Bool = true, createdAt: Date) {
        self.source = source
        self.target = target
        self.normalizedSource = SyncNormalization.normalizedKey(source)
        self.isCaseSensitive = isCaseSensitive
        self.isActive = isActive
        self.createdAt = createdAt
    }

    /// A plain word: written as itself, the way Orttakey's Words list keeps it.
    public var isPlainWord: Bool { normalizedSource == SyncNormalization.normalizedKey(target) }
}

public struct SnippetPayload: Codable, Hashable, Sendable {
    public var trigger: String
    public var expansion: String
    public var normalizedTrigger: String
    public var isActive: Bool
    public var createdAt: Date

    public init(trigger: String, expansion: String, isActive: Bool = true, createdAt: Date) {
        self.trigger = trigger
        self.expansion = expansion
        self.normalizedTrigger = SyncNormalization.normalizedKey(trigger)
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

/// Totals for dictations made on one device (its own, never imported ones).
public struct DeviceTotals: Codable, Hashable, Sendable {
    public var dictations: Int
    public var words: Int
    public var recordingMs: Int
    public var firstAt: Date?
    public var lastAt: Date?

    public init(dictations: Int = 0, words: Int = 0, recordingMs: Int = 0, firstAt: Date? = nil, lastAt: Date? = nil) {
        self.dictations = dictations
        self.words = words
        self.recordingMs = recordingMs
        self.firstAt = firstAt
        self.lastAt = lastAt
    }
}

/// A device taking part in sync, written only by that device.
public struct DevicePayload: Codable, Hashable, Sendable {
    public var deviceID: String
    public var kind: DeviceKind
    public var name: String
    public var model: String?
    /// "Orttaai" or "Orttakey".
    public var app: String
    public var appVersion: String?
    public var osVersion: String?
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var totals: DeviceTotals

    public init(
        deviceID: String,
        kind: DeviceKind,
        name: String,
        model: String? = nil,
        app: String,
        appVersion: String? = nil,
        osVersion: String? = nil,
        firstSeenAt: Date,
        lastSeenAt: Date,
        totals: DeviceTotals = DeviceTotals()
    ) {
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.model = model
        self.app = app
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.totals = totals
    }

    public var dictationZone: SyncZone { .dictations(originDeviceID: deviceID) }
}

public struct DayCount: Codable, Hashable, Sendable {
    /// "yyyy-MM-dd" in the publisher's time zone.
    public var day: String
    public var dictations: Int
    public var words: Int

    public init(day: String, dictations: Int, words: Int) {
        self.day = day
        self.dictations = dictations
        self.words = words
    }
}

public struct AppCount: Codable, Hashable, Sendable {
    public var name: String
    public var dictations: Int

    public init(name: String, dictations: Int) {
        self.name = name
        self.dictations = dictations
    }
}

/// What a Mac knows about the whole archive: the stats the phone shows,
/// since the phone never downloads the Mac's dictations.
public struct MacSummaryPayload: Codable, Hashable, Sendable {
    public var publisherDeviceID: String
    public var publisherName: String
    public var asOf: Date
    public var timeZoneIdentifier: String
    /// Dictation zones this Mac had caught up on, with their live counts.
    public var coverage: [String: Int]
    /// Unique live dictations across every device.
    public var totals: DeviceTotals
    /// Each device's own dictations, by device ID ("unknown" for legacy).
    public var perDevice: [String: DeviceTotals]
    /// The last 30 days, oldest first.
    public var recentDays: [DayCount]
    public var topApps: [AppCount]
    /// Coach on this Mac. Nil when Coach is off, and from Macs older than
    /// Coach; phones older than it ignore the field.
    public var coach: CoachDigestPayload?

    public init(
        publisherDeviceID: String,
        publisherName: String,
        asOf: Date,
        timeZoneIdentifier: String,
        coverage: [String: Int],
        totals: DeviceTotals,
        perDevice: [String: DeviceTotals],
        recentDays: [DayCount],
        topApps: [AppCount],
        coach: CoachDigestPayload? = nil
    ) {
        self.publisherDeviceID = publisherDeviceID
        self.publisherName = publisherName
        self.asOf = asOf
        self.timeZoneIdentifier = timeZoneIdentifier
        self.coverage = coverage
        self.totals = totals
        self.perDevice = perDevice
        self.recentDays = recentDays
        self.topApps = topApps
        self.coach = coach
    }
}

/// Coach on a Mac, for the phone to show: names and numbers only, never
/// anything that was said.
public struct CoachDigestPayload: Codable, Hashable, Sendable {
    /// One side of a way of talking's voice shape, 0 to 1.
    public struct Axis: Codable, Hashable, Sendable {
        public var title: String
        /// The last 28 days.
        public var now: Double?
        /// The 28 days before.
        public var before: Double?

        public init(title: String, now: Double?, before: Double?) {
            self.title = title
            self.now = now
            self.before = before
        }
    }

    /// A way of talking (to AI, to people, on the page).
    public struct Shape: Codable, Hashable, Sendable {
        public var mode: String
        /// Dictations in the last 28 days.
        public var dictations: Int
        public var axes: [Axis]

        public init(mode: String, dictations: Int, axes: [Axis]) {
            self.mode = mode
            self.dictations = dictations
            self.axes = axes
        }
    }

    public struct Habit: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            case watching
            case working
            case notMoving
        }

        public var title: String
        public var mode: String?
        public var status: Status
        /// Dictations since it started, out of `window`.
        public var since: Int
        public var window: Int
        /// How often the habit was met, 0 to 1, before it started and since.
        public var beforeShare: Double?
        public var sinceShare: Double?

        public init(title: String, mode: String?, status: Status, since: Int, window: Int, beforeShare: Double?, sinceShare: Double?) {
            self.title = title
            self.mode = mode
            self.status = status
            self.since = since
            self.window = window
            self.beforeShare = beforeShare
            self.sinceShare = sinceShare
        }
    }

    public struct Track: Codable, Hashable, Sendable {
        public var title: String
        public var level: Int
        public var mastered: Int
        public var skills: Int
        /// The skill you're on.
        public var current: String

        public init(title: String, level: Int, mastered: Int, skills: Int, current: String) {
            self.title = title
            self.level = level
            self.mastered = mastered
            self.skills = skills
            self.current = current
        }
    }

    public var shapes: [Shape]
    public var habits: [Habit]
    public var tracks: [Track]
    public var repsThisWeek: Int

    public init(shapes: [Shape], habits: [Habit], tracks: [Track], repsThisWeek: Int) {
        self.shapes = shapes
        self.habits = habits
        self.tracks = tracks
        self.repsThisWeek = repsThisWeek
    }
}

/// A preference value, as UserDefaults holds it.
public enum PreferenceValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case data(Data)
}

/// Mac settings, each key with its own revision so changing one setting on
/// one Mac never undoes another setting changed on another Mac.
public struct MacPreferencesPayload: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        /// Nil: the key was removed.
        public var value: PreferenceValue?
        public var revision: Revision

        public init(value: PreferenceValue?, revision: Revision) {
            self.value = value
            self.revision = revision
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    /// Key by key, the newer entry wins.
    public static func merged(_ lhs: MacPreferencesPayload, _ rhs: MacPreferencesPayload) -> MacPreferencesPayload {
        var entries = lhs.entries
        for (key, entry) in rhs.entries {
            if let existing = entries[key], existing.revision >= entry.revision { continue }
            entries[key] = entry
        }
        return MacPreferencesPayload(entries: entries)
    }
}

/// An opaque JSON value a Mac keeps as one blob: the tone profile, or one
/// chat conversation.
public struct BlobPayload: Codable, Hashable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct LearningSuggestionPayload: Codable, Hashable, Sendable {
    public var type: String
    public var candidateSource: String
    public var candidateTarget: String
    public var normalizedSource: String
    public var confidence: Double
    public var status: String
    public var evidence: String?
    public var createdAt: Date

    public init(
        type: String,
        candidateSource: String,
        candidateTarget: String,
        normalizedSource: String,
        confidence: Double,
        status: String,
        evidence: String?,
        createdAt: Date
    ) {
        self.type = type
        self.candidateSource = candidateSource
        self.candidateTarget = candidateTarget
        self.normalizedSource = normalizedSource
        self.confidence = confidence
        self.status = status
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public struct WritingInsightPayload: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var analyzerName: String
    public var usedFallback: Bool
    public var isPinned: Bool
    public var sampleCount: Int
    public var requestJSON: String
    public var snapshotJSON: String

    public init(
        generatedAt: Date,
        analyzerName: String,
        usedFallback: Bool,
        isPinned: Bool,
        sampleCount: Int,
        requestJSON: String,
        snapshotJSON: String
    ) {
        self.generatedAt = generatedAt
        self.analyzerName = analyzerName
        self.usedFallback = usedFallback
        self.isPinned = isPinned
        self.sampleCount = sampleCount
        self.requestJSON = requestJSON
        self.snapshotJSON = snapshotJSON
    }
}
