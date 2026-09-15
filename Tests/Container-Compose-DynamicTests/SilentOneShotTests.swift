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

/// A one-shot that does its work without printing anything.
///
/// Waiting for a container to start and waiting for a one-shot to finish share a
/// loop, and the idle timeout only answers the first question. A `chown -R` over a
/// large volume prints nothing for minutes; judged by the startup budget it was
/// failed as "timed out waiting for it to be running" after it had already been
/// seen running.
@Suite("Silent One-Shot", .containerDependent, .serialized)
struct SilentOneShotTests {

    /// Comfortably past the idle timeout the wait uses while starting, and
    /// comfortably inside the total budget.
    private static let silentSeconds = 45

    @Test("a one-shot that runs silently past the idle timeout still completes")
    func silentOneShotCompletes() async throws {
        let project = "silent-oneshot-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = URL.temporaryDirectory.appending(path: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = """
        name: \(project)
        services:
          quiet:
            image: alpine:latest
            restart: "no"
            command: ["sleep", "\(Self.silentSeconds)"]
          after:
            image: alpine:latest
            command: ["sleep", "5"]
            depends_on:
              quiet:
                condition: service_completed_successfully
        """
        try yaml.write(to: dir.appending(path: "docker-compose.yaml"), atomically: false, encoding: .utf8)

        func tearDown() async {
            var down = try? ComposeDown.parse(["--cwd", dir.path(percentEncoded: false)])
            try? await down?.run()
            for name in ["\(project)-quiet", "\(project)-after"] {
                _ = try? await ComposeUp.parse(["-d", "--cwd", dir.path(percentEncoded: false)])
                    .streamCommand("container", args: ["delete", "-f", name],
                                   onStdout: { _ in }, onStderr: { _ in })
            }
            try? FileManager.default.removeItem(at: dir)
        }

        var composeUp = try ComposeUp.parse(["-d", "--cwd", dir.path(percentEncoded: false)])
        let start = ContinuousClock.now
        do {
            // Before the fix this threw at ~30s of silence, with a message saying
            // the container had timed out waiting to be running — by which point
            // it had been running for most of that time.
            try await composeUp.run()
        } catch {
            await tearDown()
            throw error
        }
        let elapsed = ContinuousClock.now - start
        await tearDown()

        // It had to outlast the idle timeout to prove anything.
        #expect(elapsed > .seconds(Self.silentSeconds - 10),
                "up returned in \(elapsed), too fast to have waited out the one-shot")
    }
}
