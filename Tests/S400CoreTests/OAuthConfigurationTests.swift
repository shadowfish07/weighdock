// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import S400Core

struct OAuthConfigurationTests {
    let id = "123456-demo-client.apps.googleusercontent.com"
    let secret = "fictional-desktop-secret"
    typealias Configuration = OAuthClientConfiguration
    typealias Failure = Configuration.ValidationError

    private func json(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root)
    }

    @Test func desktopJSONMatchesManualConfigurationAndRoundTrips() throws {
        let data = try json(["installed": ["client_id": id, "client_secret": secret]])
        let imported = try Configuration.parseDesktopJSON(data)
        let manual = try Configuration(clientID: id, clientSecret: secret)
        #expect(imported == manual)
        #expect(try Configuration.parseDesktopJSON(data) == imported)
        #expect(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(imported)) == imported)
    }

    @Test func ignoresUntrustedEndpointsAndRedirects() throws {
        let data = try json(["installed": ["client_id": id, "client_secret": secret,
            "auth_uri": "https://invalid.example/authorize", "token_uri": "http://invalid.example/token",
            "redirect_uris": ["https://invalid.example/callback"], "project_id": "fictional-project"]])
        let parsed = try Configuration.parseDesktopJSON(data)
        let expected = try Configuration(clientID: id, clientSecret: secret)
        #expect(parsed == expected)
        let output = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
        #expect(!output.contains("invalid.example") && !output.contains("project_id"))
    }

    @Test func rejectsWebAndAmbiguousOrMissingDesktopRoots() throws {
        let fields = ["client_id": id, "client_secret": secret]
        for root: [String: Any] in [["web": fields], ["installed": fields, "web": fields],
                                   ["installed": fields, "web": NSNull()], [:], ["installed": "wrong-type"]] {
            let data = try json(root)
            #expect(throws: Failure.desktopClientRequired) { try Configuration.parseDesktopJSON(data) }
        }
    }

    @Test func rejectsMissingNullAndWrongTypedFieldsWithoutEchoingContents() throws {
        for value: Any in [NSNull(), 123, ["nested": "value"]] {
            #expect(throws: Failure.missingClientID) {
                try Configuration.parseDesktopJSON(json(["installed": ["client_id": value, "client_secret": secret]]))
            }
            #expect(throws: Failure.missingClientSecret) {
                try Configuration.parseDesktopJSON(json(["installed": ["client_id": id, "client_secret": value]]))
            }
        }
        #expect(throws: Failure.missingClientID) { try Configuration.parseDesktopJSON(json(["installed": ["client_secret": secret]])) }
        #expect(throws: Failure.missingClientSecret) { try Configuration.parseDesktopJSON(json(["installed": ["client_id": id]])) }
    }

    @Test func malformedAndOversizedJSONHaveStableRedactedErrors() {
        for data in [Data(), Data("not-json".utf8), Data("[]".utf8), Data("null".utf8), Data("{\"installed\":".utf8)] {
            #expect(throws: Failure.invalidJSON) { try Configuration.parseDesktopJSON(data) }
        }
        #expect(throws: Failure.oversizedJSON) {
            try Configuration.parseDesktopJSON(Data(repeating: 32, count: Configuration.maximumJSONBytes + 1))
        }
        for error in [Failure.invalidJSON, .desktopClientRequired, .missingClientID, .missingClientSecret,
                      .invalidClientID, .invalidClientSecret, .oversizedJSON] {
            #expect(!error.localizedDescription.contains(secret) && !error.localizedDescription.contains(id))
        }
    }

    @Test func validatesManualIDAndNormalizesSurroundingSpaces() throws {
        #expect(try Configuration(clientID: "  " + id + " ", clientSecret: " " + secret + " ") == Configuration(clientID: id, clientSecret: secret))
        #expect(throws: Failure.missingClientID) { try Configuration(clientID: "  ", clientSecret: secret) }
        for bad in [".apps.googleusercontent.com", "example.com", "abc.apps.googleusercontent.com.attacker.example",
                    "https://abc.apps.googleusercontent.com", "a b.apps.googleusercontent.com",
                    id + "\n", id + "\t", id + "\r", "demo\0.apps.googleusercontent.com",
                    String(repeating: "x", count: 257) + ".apps.googleusercontent.com"] {
            #expect(throws: Failure.invalidClientID) { try Configuration(clientID: bad, clientSecret: secret) }
        }
    }

    @Test func validatesManualSecretAndRedactsDescriptions() throws {
        #expect(throws: Failure.missingClientSecret) { try Configuration(clientID: id, clientSecret: "  ") }
        for bad in [secret + "\n", secret + "\t", secret + "\r", secret + "\0", String(repeating: "x", count: 513)] {
            #expect(throws: Failure.invalidClientSecret) { try Configuration(clientID: id, clientSecret: bad) }
        }
        let valid = try Configuration(clientID: id, clientSecret: secret)
        #expect(!String(describing: valid).contains(secret) && !String(reflecting: valid).contains(secret))
        #expect(!String(describing: valid).contains(id) && !String(reflecting: valid).contains(id))
    }

    @Test func sizeLimitsAcceptBoundariesAndCountUTF8Bytes() throws {
        let boundarySecret = String(repeating: "x", count: Configuration.maximumClientSecretBytes)
        #expect(try Configuration(clientID: id, clientSecret: boundarySecret).clientSecret == boundarySecret)
        #expect(throws: Failure.invalidClientSecret) {
            try Configuration(clientID: id, clientSecret: String(repeating: "界", count: 171))
        }
        var padded = try json(["installed": ["client_id": id, "client_secret": secret]])
        padded.append(Data(repeating: 32, count: Configuration.maximumJSONBytes - padded.count))
        #expect(try Configuration.parseDesktopJSON(padded).clientID == id)
        padded.append(32)
        #expect(throws: Failure.oversizedJSON) { try Configuration.parseDesktopJSON(padded) }
    }

    @Test func importingUsesTheSameValidationAndCannotMutateExistingConfiguration() throws {
        let saved = try Configuration(clientID: id, clientSecret: secret)
        #expect(throws: Failure.invalidClientID) {
            try Configuration.parseDesktopJSON(json(["installed": ["client_id": id + "\n", "client_secret": secret]]))
        }
        #expect(throws: Failure.invalidClientSecret) {
            try Configuration.parseDesktopJSON(json(["installed": ["client_id": id, "client_secret": secret + "\n"]]))
        }
        #expect(saved.clientID == id && saved.clientSecret == secret)
        let invalidSavedJSON = try json(["clientID": id, "clientSecret": ""])
        #expect(throws: Failure.missingClientSecret) { try JSONDecoder().decode(Configuration.self, from: invalidSavedJSON) }
    }
}
