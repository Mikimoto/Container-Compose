//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing
import Foundation
@testable import ContainerComposeCore

/// What the wave barrier exists to guarantee, asserted where it matters.
///
/// The barrier resolves the name with `getaddrinfo` in the compose process, which
/// goes through the host's resolver. A dependent resolves through its own
/// `/etc/resolv.conf` against the daemon's DNS from inside the container network —
/// a different path, so a host lookup succeeding does not establish that the
/// dependent can resolve the name. This starts a real dependency pair and asks the
/// dependent.
///
/// The project is named after a domain that is actually registered, discovered
/// rather than hardcoded, because `up` derives its DNS domain from the project
/// name: with a name that is not a registered domain the DNS path is never taken
/// and there is nothing to assert.
@Suite("Dependent Resolution", .containerDependent, .serialized)
struct DependentResolutionTests {

    /// First domain from `container system dns list`, or nil when none is
    /// registered — in which case the DNS path cannot engage at all.
    private static func registeredDomain() -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["container", "system", "dns", "list"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "DOMAIN" }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    private func exec(_ container: String, _ args: [String]) async throws -> String {
        let output = Output()
        _ = try await ComposeUp.parse(["-d", "--cwd", NSTemporaryDirectory()])
            .streamCommand(
                "container", args: ["exec", container] + args,
                onStdout: { output.append($0) }, onStderr: { _ in })
        return output.value
    }

    @Test("a dependent resolves its dependency's name from inside the container")
    func dependentResolvesDependency() async throws {
        guard let domain = Self.registeredDomain() else {
            print("""
            Skipping: no DNS domain is registered, so `up` never takes the DNS path.
            Register one with: sudo container system dns create <domain>
            """)
            return
        }

        let dir = URL.temporaryDirectory.appending(path: "depres-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = """
        name: \(domain)
        services:
          upstream:
            image: alpine:latest
            command: ["sleep", "120"]
          dependent:
            image: alpine:latest
            command: ["sleep", "120"]
            depends_on: [upstream]
        """
        try yaml.write(to: dir.appending(path: "docker-compose.yaml"), atomically: false, encoding: .utf8)
        // On the DNS path containers are named `<service>.<domain>`, not
        // `<project>-<service>`. Getting this wrong makes every exec target a
        // container that does not exist, and `getent` returning nothing then looks
        // exactly like a resolution failure — which is how this test first "failed".
        let upstream = "upstream.\(domain)"
        let dependent = "dependent.\(domain)"

        func tearDown() async {
            var down = try? ComposeDown.parse(["--cwd", dir.path(percentEncoded: false)])
            try? await down?.run()
            for name in [upstream, dependent] {
                _ = try? await ComposeUp.parse(["-d", "--cwd", dir.path(percentEncoded: false)])
                    .streamCommand("container", args: ["delete", "-f", name],
                                   onStdout: { _ in }, onStderr: { _ in })
            }
            try? FileManager.default.removeItem(at: dir)
        }

        var composeUp = try ComposeUp.parse(["-d", "--cwd", dir.path(percentEncoded: false)])
        do {
            try await composeUp.run()

            // Anti-vacuity: an exec against a container that does not exist also
            // returns nothing, so prove the target is there before reading a miss
            // as a resolution failure.
            let selfCheck = try await exec(dependent, ["echo", "alive"])
            #expect(selfCheck.contains("alive"),
                    "could not exec into '\(dependent)' — the assertions below would be vacuous")

            // Resolution goes through the container's own resolver, which is a
            // different path from the `getaddrinfo` the barrier runs on the host.
            let resolv = try await exec(dependent, ["cat", "/etc/resolv.conf"])
            #expect(resolv.contains("domain \(domain)"),
                    "dependent's resolv.conf does not carry the domain: \(resolv)")

            // The claim the barrier exists to make: by the time the dependent is
            // up, it can resolve the service it depends on.
            let short = try await exec(dependent, ["getent", "hosts", "upstream"])
            let dotted = try await exec(dependent, ["getent", "hosts", upstream])
            #expect(short.contains("upstream"),
                    "dependent could not resolve short name 'upstream' (got: \(short))")
            #expect(dotted.contains("upstream"),
                    "dependent could not resolve '\(upstream)' (got: \(dotted))")
        } catch {
            await tearDown()
            throw error
        }
        await tearDown()
    }
}
