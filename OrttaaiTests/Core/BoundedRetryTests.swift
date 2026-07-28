// BoundedRetryTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class BoundedRetryTests: XCTestCase {
    private struct TestError: Error {}

    func testSucceedsFirstTryWithoutSleeping() async {
        var calls = 0
        var sleeps = 0

        let failure = await BoundedRetry.run(
            attempts: 3,
            delayNs: 1,
            sleep: { _ in sleeps += 1 }
        ) {
            calls += 1
        }

        XCTAssertNil(failure)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sleeps, 0)
    }

    func testRetriesTransientFailureUntilSuccess() async {
        var calls = 0
        var sleeps = 0

        let failure = await BoundedRetry.run(
            attempts: 3,
            delayNs: 1,
            sleep: { _ in sleeps += 1 }
        ) {
            calls += 1
            if calls < 3 {
                throw TestError()
            }
        }

        XCTAssertNil(failure, "Third attempt succeeds; no failure should be reported")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(sleeps, 2, "Sleeps only between attempts")
    }

    func testReportsFailureAfterExhaustingAttempts() async {
        var calls = 0

        let failure = await BoundedRetry.run(
            attempts: 3,
            delayNs: 1,
            sleep: { _ in }
        ) {
            calls += 1
            throw TestError()
        }

        XCTAssertEqual(calls, 3)
        XCTAssertEqual(failure?.attempts, 3)
        XCTAssertTrue(failure?.lastError is TestError)
    }

    func testSingleAttemptDoesNotSleep() async {
        var sleeps = 0

        let failure = await BoundedRetry.run(
            attempts: 1,
            delayNs: 1,
            sleep: { _ in sleeps += 1 }
        ) {
            throw TestError()
        }

        XCTAssertNotNil(failure)
        XCTAssertEqual(sleeps, 0)
    }
}
