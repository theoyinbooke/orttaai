// SharedDefaultsLock.swift
// OrttaaiTests
//
// Test classes run in parallel processes that share one preferences domain.
// Classes that write the dictation and Express settings hold this lock for
// each test, so one process's setUp or tearDown can't change those settings
// under another's test (seen as a flaky ExpressControllerTests failure).

import Foundation

enum SharedDefaultsLock {
    private static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("orttaai-tests-dictation-settings.lock").path
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    /// Blocks until no other test process holds the lock.
    static func acquire() {
        guard descriptor < 0 else { return }
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        descriptor = fd
    }

    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
