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

/// `up` used to derive its DNS domain from the compose project name alone, so a
/// project named `dev-cluster` looked for a `dev-cluster` domain while the operator
/// had registered the one their setup documented. `dnsAvailable` came out false,
/// `--dns-domain` was never passed, and the DNS readiness barrier silently never
/// ran — the /etc/hosts fallback it dropped to is best-effort by design, so nothing
/// reported a problem.
@Suite("DNS Domain Selection")
struct DnsDomainSelectionTests {

    // MARK: - dnsDomainProperty

    private static let propertyList = """
    [build]
    cpus = 2
    image = "ghcr.io/apple/container-builder-shim/builder:0.12.0"

    [dns]
    domain = "dcf"

    [registry]
    domain = "docker.io"
    """

    @Test("the dns section's domain is read")
    func readsDnsDomain() {
        #expect(ComposeUp.dnsDomainProperty(Self.propertyList) == "dcf")
    }

    /// `[registry]` carries a `domain` of its own. Matching a bare `domain =` line
    /// without tracking the section in force would register every container under
    /// `docker.io`.
    @Test("the registry section's domain is not mistaken for it")
    func ignoresRegistryDomain() {
        let withoutDNS = """
        [build]
        cpus = 2

        [registry]
        domain = "docker.io"
        """
        #expect(ComposeUp.dnsDomainProperty(withoutDNS) == nil)
    }

    @Test("no dns section yields nil")
    func noDnsSection() {
        #expect(ComposeUp.dnsDomainProperty("[build]\ncpus = 2\n") == nil)
    }

    @Test("an empty domain value yields nil rather than an empty string")
    func emptyValueIsNil() {
        #expect(ComposeUp.dnsDomainProperty("[dns]\ndomain = \"\"\n") == nil)
    }

    @Test("an unquoted value is accepted")
    func unquotedValue() {
        #expect(ComposeUp.dnsDomainProperty("[dns]\ndomain = dcf\n") == "dcf")
    }

    @Test("empty output yields nil")
    func emptyOutput() {
        #expect(ComposeUp.dnsDomainProperty("") == nil)
    }

    // MARK: - preferredDnsDomain

    /// The case this exists for: the operator registered the global domain, the
    /// project is named something else, and only the global one is registered.
    @Test("the registered global domain wins over an unregistered derived one")
    func globalWinsWhenRegistered() {
        let choice = ComposeUp.preferredDnsDomain(
            global: "dcf", derived: "dev-cluster", isRegistered: { $0 == "dcf" })
        #expect(choice?.domain == "dcf")
        #expect(choice?.available == true)
    }

    /// A project that did register its own name keeps working.
    @Test("the derived domain is used when only it is registered")
    func derivedUsedWhenOnlyItRegistered() {
        let choice = ComposeUp.preferredDnsDomain(
            global: "dcf", derived: "dev-cluster", isRegistered: { $0 == "dev-cluster" })
        #expect(choice?.domain == "dev-cluster")
        #expect(choice?.available == true)
    }

    @Test("the global domain wins when both are registered")
    func globalWinsWhenBothRegistered() {
        let choice = ComposeUp.preferredDnsDomain(
            global: "dcf", derived: "dev-cluster", isRegistered: { _ in true })
        #expect(choice?.domain == "dcf")
        #expect(choice?.available == true)
    }

    /// With nothing registered the caller still needs a name for the hint it prints,
    /// and the useful one to print is the domain the operator actually configured.
    @Test("with neither registered it reports the global domain as unavailable")
    func neitherRegistered() {
        let choice = ComposeUp.preferredDnsDomain(
            global: "dcf", derived: "dev-cluster", isRegistered: { _ in false })
        #expect(choice?.domain == "dcf")
        #expect(choice?.available == false)
    }

    @Test("with no global domain the derived one is the only candidate")
    func noGlobalDomain() {
        let choice = ComposeUp.preferredDnsDomain(
            global: nil, derived: "dev-cluster", isRegistered: { $0 == "dev-cluster" })
        #expect(choice?.domain == "dev-cluster")
        #expect(choice?.available == true)
    }

    @Test("an empty global domain is skipped rather than tried")
    func emptyGlobalSkipped() {
        var asked: [String] = []
        let choice = ComposeUp.preferredDnsDomain(
            global: "", derived: "dev-cluster",
            isRegistered: { asked.append($0); return true })
        #expect(choice?.domain == "dev-cluster")
        #expect(asked == ["dev-cluster"])
    }

    @Test("no candidates at all yields nil")
    func noCandidates() {
        #expect(ComposeUp.preferredDnsDomain(global: nil, derived: nil, isRegistered: { _ in true }) == nil)
    }
}
