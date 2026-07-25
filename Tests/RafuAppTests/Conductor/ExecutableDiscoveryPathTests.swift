import Foundation
import Testing

@testable import RafuApp

/// Regression: Cline was installed under nvm
/// (`~/.nvm/versions/node/<version>/bin/cline`) and Settings said "Not found
/// on this Mac". Two causes, both covered here:
///
/// 1. `curatedPath` contains no version-manager directories, and no adapter's
///    hardcoded candidate list mentioned nvm.
/// 2. Rafu.app launched from Finder inherits launchd's minimal `PATH`
///    (`/usr/bin:/bin:/usr/sbin:/sbin`), so `which` found nothing — and C3's
///    resolver PREFERRED that host value over the curated one, losing even
///    `/opt/homebrew/bin` and `~/.local/bin`.
@Test("The discovery path keeps curated entries even under launchd's minimal PATH")
func discoveryPathSurvivesLaunchdMinimalPath() {
    // Exactly what a Finder-launched app sees.
    let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let discovery = RafuConductorEnvironment.discoverySearchPath(hostSearchPath: launchdPath)
    let components = discovery.split(separator: ":").map(String.init)

    // The old `host ?? curated` logic returned launchdPath verbatim.
    #expect(discovery != launchdPath)
    #expect(components.contains("/opt/homebrew/bin"))
    #expect(components.contains("/usr/local/bin"))
    let localBin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true).path
    #expect(components.contains(localBin))
    // The launchd entries are still there — widening, never replacing.
    #expect(components.contains("/usr/bin"))
}

@Test("The discovery path includes every existing version-manager bin directory")
func discoveryPathIncludesVersionManagerDirectories() {
    let discovery = RafuConductorEnvironment.discoverySearchPath(hostSearchPath: "")
    let components = Set(discovery.split(separator: ":").map(String.init))

    // Whatever this machine actually has — the property drops nonexistent
    // entries, so on a machine with no version managers this is vacuous
    // rather than failing.
    for directory in RafuConductorEnvironment.versionManagerBinDirectories {
        #expect(components.contains(directory.path))
    }
}

@Test("Version-manager directories are real, absolute, existing directories")
func versionManagerDirectoriesAreValid() {
    let manager = FileManager.default
    for url in RafuConductorEnvironment.versionManagerBinDirectories {
        #expect(url.path.hasPrefix("/"))
        var isDirectory: ObjCBool = false
        #expect(manager.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@Test("The discovery path is deduplicated and absolute-only")
func discoveryPathIsDeduplicatedAndAbsolute() {
    // A host PATH with duplicates and a relative entry — the latter must not
    // survive into a path Rafu searches for executables.
    let messy = "/usr/bin:relative/bin:/usr/bin:/opt/homebrew/bin"
    let components = RafuConductorEnvironment.discoverySearchPath(hostSearchPath: messy)
        .split(separator: ":").map(String.init)

    #expect(components.count == Set(components).count)
    #expect(!components.contains("relative/bin"))
    #expect(components.allSatisfy { $0.hasPrefix("/") })
}

@Test("Widening discovery never widens what a child process inherits")
func childEnvironmentStaysCurated() {
    // The security invariant this fix had to respect (ADR 0018): looking in
    // more places is not the same as handing a child more places. A child's
    // PATH is still exactly `curatedPath` — no nvm, no host entries.
    let environment = RafuConductorEnvironment.childEnvironment(
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))

    #expect(environment[RafuConductorEnvironment.path] == RafuConductorEnvironment.curatedPath)
    for directory in RafuConductorEnvironment.versionManagerBinDirectories {
        #expect(environment[RafuConductorEnvironment.path]?.contains(directory.path) != true)
    }
}
