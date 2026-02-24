// AppLinks.swift
// Orttaai

import Foundation

enum FeedbackIssueKind {
    case bug
    case support
}

enum AppLinks {
    static let githubOwner = "theoyinbooke"
    static let githubRepo = "orttaai"

    static var githubProfileURL: URL {
        URL(string: "https://github.com/\(githubOwner)")!
    }

    static var githubRepositoryURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)")!
    }

    static func newIssueURL(kind: FeedbackIssueKind, version: String, build: String) -> URL {
        let titlePrefix: String
        let labels: String
        let bodyIntro: String

        switch kind {
        case .bug:
            titlePrefix = "[Bug] "
            labels = "bug"
            bodyIntro = "What happened?"
        case .support:
            titlePrefix = "[Support] "
            labels = "support"
            bodyIntro = "What do you need help with?"
        }

        let body = """
        ### \(bodyIntro)

        ### Steps to reproduce
        1.
        2.
        3.

        ### Expected behavior

        ### Actual behavior

        ### Environment
        - App version: \(version) (\(build))
        - macOS:
        - Model:
        """

        var components = URLComponents(url: githubRepositoryURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: titlePrefix),
            URLQueryItem(name: "labels", value: labels),
            URLQueryItem(name: "body", value: body),
        ]

        return components?.url ?? githubRepositoryURL
    }
}
