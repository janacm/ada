import Foundation
import Testing
@testable import ADAAlertCore

// Where the menu bar helper looks for the ada install, for every layout it is
// run from: an ADA_HOME override, a checkout, a SwiftPM build directory, an app
// bundle, and Homebrew's bin/ symlink into libexec.
@Suite struct InstallDirectoryTests {
    private func resolve(_ executable: String, environment: [String: String] = [:]) -> String {
        InstallDirectory.resolve(environment: environment, executableURL: URL(fileURLWithPath: executable)).path
    }

    @Test func adaHomeWins() {
        #expect(resolve("/src/ada/.build/release/ada-menubar", environment: ["ADA_HOME": "/opt/ada"]) == "/opt/ada")
    }

    @Test func anEmptyAdaHomeIsIgnored() {
        #expect(resolve("/src/ada/ada-menubar", environment: ["ADA_HOME": ""]) == "/src/ada")
    }

    @Test func aHelperBesideTheScriptsUsesItsOwnDirectory() {
        #expect(resolve("/src/ada/ada-menubar") == "/src/ada")
    }

    @Test func anAppBundleResolvesToTheFolderHoldingTheApp() {
        #expect(resolve("/src/ada/ADA Menu Bar.app/Contents/MacOS/ada-menubar") == "/src/ada")
    }

    // `swift build -c release` output, under both SwiftPM build systems. The
    // README's `.build/release/ada-menubar &` used to leave the helper looking
    // for the launcher inside .build/release.
    @Test(arguments: [
        "/src/ada/.build/release/ada-menubar",
        "/src/ada/.build/arm64-apple-macosx/release/ada-menubar",
        "/src/ada/.build/out/Products/Release/ada-menubar",
    ])
    func aSwiftPMBuildResolvesToThePackageRoot(_ executable: String) {
        #expect(resolve(executable) == "/src/ada")
    }

    // Homebrew links bin/ada-menubar to libexec/ada-menubar, and
    // Bundle.main.executableURL reports the link's own path, so the install is
    // only found by resolving it.
    @Test func aSymlinkedHelperResolvesToTheRealInstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libexec = root.appendingPathComponent("libexec")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: libexec.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try executable(at: libexec.appendingPathComponent("ada-menubar"))
        try executable(at: libexec.appendingPathComponent(InstallDirectory.launcherPath))
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("ada-menubar"),
            withDestinationURL: libexec.appendingPathComponent("ada-menubar")
        )

        let install = InstallDirectory.resolve(environment: [:], executableURL: bin.appendingPathComponent("ada-menubar"))
        #expect(install.resolvingSymlinksInPath().path == libexec.resolvingSymlinksInPath().path)
        #expect(InstallDirectory.launcher(in: install) != nil)
    }

    // Homebrew: bin/ada-menubar -> ../Cellar/ada/<v>/bin/ada-menubar ->
    // ../libexec/ada-menubar, and opt/ada -> ../Cellar/ada/<v>. The menu bar
    // caches the install for its lifetime, so it must hold the opt path: after a
    // `brew upgrade` swaps the keg, Test Alert still finds the launcher.
    @Test func aHomebrewKegResolvesToItsOptPathAndSurvivesAnUpgrade() throws {
        let prefix = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: prefix) }
        func keg(_ version: String) throws -> URL {
            let keg = prefix.appendingPathComponent("Cellar/ada/\(version)")
            try FileManager.default.createDirectory(at: keg.appendingPathComponent("libexec/lib"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: keg.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try executable(at: keg.appendingPathComponent("libexec/ada-menubar"))
            try executable(at: keg.appendingPathComponent("libexec").appendingPathComponent(InstallDirectory.launcherPath))
            try FileManager.default.createSymbolicLink(atPath: keg.appendingPathComponent("bin/ada-menubar").path,
                                                       withDestinationPath: "../libexec/ada-menubar")
            return keg
        }
        let old = try keg("9.9.9")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("opt"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("opt/ada").path,
                                                   withDestinationPath: "../Cellar/ada/9.9.9")
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/ada-menubar").path,
                                                   withDestinationPath: "../Cellar/ada/9.9.9/bin/ada-menubar")

        let install = InstallDirectory.resolve(environment: [:], executableURL: prefix.appendingPathComponent("bin/ada-menubar"))
        #expect(install.path == prefix.resolvingSymlinksInPath().appendingPathComponent("opt/ada/libexec").path)

        // brew upgrade: a new keg, opt repointed, the old keg removed.
        _ = try keg("10.0.0")
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("opt/ada"))
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("opt/ada").path,
                                                   withDestinationPath: "../Cellar/ada/10.0.0")
        try FileManager.default.removeItem(at: old)
        #expect(InstallDirectory.launcher(in: install) != nil)
    }

    @Test func aKegWithNoOptLinkIsLeftAsItIs() throws {
        let prefix = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let libexec = prefix.appendingPathComponent("Cellar/ada/9.9.9/libexec")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        #expect(InstallDirectory.stable(libexec).path == libexec.path)
    }

    @Test func theLauncherIsFoundUnderLib() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent(InstallDirectory.launcherPath)
        try executable(at: launcher)
        #expect(InstallDirectory.launcher(in: root)?.path == launcher.path)
    }

    // The launcher moved into lib/ on 2026-06-18; a copy at the install root is
    // not what the scripts use, so it must not satisfy the lookup.
    @Test func aLauncherAtTheInstallRootIsNotUsed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try executable(at: root.appendingPathComponent("ada-show-alert.sh"))
        #expect(InstallDirectory.launcher(in: root) == nil)
    }

    @Test func aLauncherThatIsNotExecutableIsNotUsed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent(InstallDirectory.launcherPath)
        try Data("#!/bin/sh\n".utf8).write(to: launcher)
        #expect(InstallDirectory.launcher(in: root) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ada-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
