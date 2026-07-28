// DatabaseBootstrapTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class DatabaseBootstrapTests: XCTestCase {
    private struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testHealthyStoreOpensWithoutRecovery() {
        var sidelineCalls = 0

        let outcome = DatabaseBootstrap.bootstrap(
            create: { "store" },
            sidelineStore: { _ in
                sidelineCalls += 1
                return true
            }
        )

        guard case .ready(let store, let recovery) = outcome else {
            return XCTFail("Expected ready outcome")
        }
        XCTAssertEqual(store, "store")
        XCTAssertNil(recovery)
        XCTAssertEqual(sidelineCalls, 0, "Healthy launch must not touch the store file")
    }

    func testTransientFailureRecoversViaRetryWithoutSidelining() {
        var attempts = 0
        var sidelineCalls = 0

        let outcome = DatabaseBootstrap.bootstrap(
            create: { () throws -> String in
                attempts += 1
                if attempts == 1 {
                    throw StoreError(message: "transient lock")
                }
                return "store"
            },
            sidelineStore: { _ in
                sidelineCalls += 1
                return true
            }
        )

        guard case .ready(let store, let recovery) = outcome else {
            return XCTFail("Expected ready outcome")
        }
        XCTAssertEqual(store, "store")
        XCTAssertEqual(recovery, .retried)
        XCTAssertEqual(sidelineCalls, 0, "A transient failure must not sideline the user's data")
    }

    func testCorruptStoreIsSidelinedAndRecreated() {
        var attempts = 0
        var sidelineCalls = 0

        let outcome = DatabaseBootstrap.bootstrap(
            create: { () throws -> String in
                attempts += 1
                if attempts <= 2 {
                    throw StoreError(message: "malformed database")
                }
                return "fresh-store"
            },
            sidelineStore: { _ in
                sidelineCalls += 1
                return true
            }
        )

        guard case .ready(let store, let recovery) = outcome else {
            return XCTFail("Expected ready outcome")
        }
        XCTAssertEqual(store, "fresh-store")
        XCTAssertEqual(recovery, .sidelinedCorruptStore)
        XCTAssertEqual(sidelineCalls, 1)
        XCTAssertEqual(attempts, 3)
    }

    func testFailureSurfacesWhenSidelineIsNotPossible() {
        let outcome = DatabaseBootstrap.bootstrap(
            create: { () throws -> String in
                throw StoreError(message: "disk full")
            },
            sidelineStore: { _ in false }
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("Expected failed outcome — silent nil services are forbidden")
        }
        XCTAssertEqual(message, "disk full")
    }

    func testFailureSurfacesWhenFreshStoreAlsoFails() {
        var attempts = 0

        let outcome = DatabaseBootstrap.bootstrap(
            create: { () throws -> String in
                attempts += 1
                throw StoreError(message: "failure \(attempts)")
            },
            sidelineStore: { _ in true }
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("Expected failed outcome")
        }
        XCTAssertEqual(message, "failure 3", "The post-recovery error is the actionable one")
        XCTAssertEqual(attempts, 3)
    }
}
