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

/// Waiting for a container to start and waiting for a one-shot to finish are two
/// different questions sharing one loop, and the idle timeout only answers the
/// first. A one-shot that works quietly — `chown -R` over a large volume prints
/// nothing — used to be failed by the startup budget after it had already been
/// seen running, and told the operator it had timed out "waiting for it to be
/// running".
@Suite("Wait Verdict")
struct WaitVerdictTests {

    private func verdict(
        started: Bool, silentFor: TimeInterval, elapsed: TimeInterval,
        idle: TimeInterval = 30, max: TimeInterval = 300
    ) -> ComposeUp.WaitVerdict {
        ComposeUp.waitVerdict(
            hasStarted: started, silentFor: silentFor, elapsed: elapsed,
            idleTimeout: idle, maxWait: max)
    }

    /// The regression: silent well past the idle timeout, but already running.
    @Test("a silent one-shot that has started is not failed by the idle timeout")
    func silentAfterStartingKeepsWaiting() {
        #expect(verdict(started: true, silentFor: 120, elapsed: 130) == .keepWaiting)
    }

    /// The behaviour the idle timeout exists for, unchanged.
    @Test("silence before starting still trips the idle timeout")
    func silentBeforeStartingTimesOut() {
        #expect(verdict(started: false, silentFor: 31, elapsed: 31) == .idleTimeout)
    }

    /// An active pull keeps refreshing activity, so a slow download is not silence.
    @Test("a noisy pull that has not started yet keeps waiting")
    func noisyBeforeStartingKeepsWaiting() {
        #expect(verdict(started: false, silentFor: 2, elapsed: 200) == .keepWaiting)
    }

    /// The backstop still applies once running: unbounded is the worse failure.
    @Test("the total budget still bounds a one-shot that has started")
    func totalBudgetStillApplies() {
        #expect(verdict(started: true, silentFor: 400, elapsed: 301) == .totalTimeout)
    }

    @Test("the total budget bounds a noisy container that never starts")
    func totalBudgetBoundsNoisyStartup() {
        #expect(verdict(started: false, silentFor: 1, elapsed: 301) == .totalTimeout)
    }

    /// Exactly at each threshold is still waiting; the comparisons are strict.
    @Test("the thresholds are exclusive")
    func thresholdsAreExclusive() {
        #expect(verdict(started: false, silentFor: 30, elapsed: 30) == .keepWaiting)
        #expect(verdict(started: true, silentFor: 500, elapsed: 300) == .keepWaiting)
    }

    /// Idle is reported ahead of total when both are past, because it is the more
    /// specific diagnosis: nothing came out and nothing started.
    @Test("idle wins over total before the container starts")
    func idlePreferredBeforeStart() {
        #expect(verdict(started: false, silentFor: 400, elapsed: 400) == .idleTimeout)
    }
}
