import XCTest
@testable import ORXAnalyticsCore

// Engine process management tests (task T012): runtime resolution,
// the upgrade backup guard, and the launch state machine. Everything
// runs against temp directories and injected fakes — no real engine,
// no real socket, no real projects (CONTRIBUTING: 测试用合成来源).

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orx-enginepm-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Runtime resolution

final class EngineRuntimeResolverTests: XCTestCase {
    func testBundledResolutionRequiresFullRuntime() throws {
        let root = makeTempDir()
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("python/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("orxanalytics"), withIntermediateDirectories: true)

        // Incomplete: no python, no serve script, no package.
        XCTAssertNil(EngineRuntimeResolver.bundled(bundleURL: root))

        // Complete bundle layout resolves.
        try "#!/bin/sh".write(to: resources.appendingPathComponent("python/bin/python3"),
                              atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: resources.appendingPathComponent("python/bin/python3").path)
        try "pass".write(to: resources.appendingPathComponent("orx_engine_serve.py"),
                         atomically: true, encoding: .utf8)
        try "".write(to: resources.appendingPathComponent("orxanalytics/__init__.py"),
                     atomically: true, encoding: .utf8)

        let location = try XCTUnwrap(EngineRuntimeResolver.bundled(bundleURL: root))
        XCTAssertEqual(location.origin, "bundled")
        XCTAssertEqual(location.pythonExecutable.lastPathComponent, "python3")
        XCTAssertEqual(location.serveScript.lastPathComponent, "orx_engine_serve.py")
        XCTAssertEqual(location.moduleSearchPath?.path, resources.path)
    }

    func testDevOverrideUsesEnvAndFindsServeScript() throws {
        let root = makeTempDir()
        let python = root.appendingPathComponent("bin/python3")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "#!/bin/sh".write(to: python, atomically: true, encoding: .utf8)

        // No env, no override.
        XCTAssertNil(EngineRuntimeResolver.devOverride(environment: [:]))

        // Python set but no serve script anywhere -> unavailable.
        XCTAssertNil(EngineRuntimeResolver.devOverride(
            environment: [EngineRuntimeResolver.pythonOverrideEnv: python.path]))

        // Serve script beside the interpreter (e.g. repo root) resolves.
        let serve = root.appendingPathComponent("orx_engine_serve.py")
        try "pass".write(to: serve, atomically: true, encoding: .utf8)
        let location = try XCTUnwrap(EngineRuntimeResolver.devOverride(
            environment: [EngineRuntimeResolver.pythonOverrideEnv: python.path,
                          EngineRuntimeResolver.pythonPathOverrideEnv: "/repo/src"]))
        XCTAssertEqual(location.origin, "dev-override")
        XCTAssertEqual(location.serveScript, serve)
        XCTAssertEqual(location.moduleSearchPath?.path, "/repo/src")

        // Explicit serve env wins over neighbor discovery.
        let serve2 = root.appendingPathComponent("elsewhere-serve.py")
        try "pass".write(to: serve2, atomically: true, encoding: .utf8)
        let location2 = try XCTUnwrap(EngineRuntimeResolver.devOverride(
            environment: [EngineRuntimeResolver.pythonOverrideEnv: python.path,
                          EngineRuntimeResolver.serveOverrideEnv: serve2.path]))
        XCTAssertEqual(location2.serveScript, serve2)
        XCTAssertNil(location2.moduleSearchPath)
    }
}

// MARK: - Upgrade guard

final class EngineUpgradeGuardTests: XCTestCase {
    func testNeedsBackupDecision() {
        // No database -> never (nothing to protect).
        XCTAssertFalse(EngineUpgradeGuard.needsBackup(databaseExists: false,
                                                      stampContents: nil, engineVersion: "2"))
        // Same version restarted -> no piling up backups.
        XCTAssertFalse(EngineUpgradeGuard.needsBackup(databaseExists: true,
                                                      stampContents: "2\n", engineVersion: "2"))
        // New version, or unknown previous version -> protect first.
        XCTAssertTrue(EngineUpgradeGuard.needsBackup(databaseExists: true,
                                                     stampContents: "1", engineVersion: "2"))
        XCTAssertTrue(EngineUpgradeGuard.needsBackup(databaseExists: true,
                                                     stampContents: nil, engineVersion: "2"))
        XCTAssertTrue(EngineUpgradeGuard.needsBackup(databaseExists: true,
                                                     stampContents: "  ", engineVersion: "2"))
    }

    func testBackupFileNameEmbedsVersionAndSortsByTime() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = EngineUpgradeGuard.backupFileName(engineVersion: "0.4.1", at: base)
        let b = EngineUpgradeGuard.backupFileName(engineVersion: "0.4.1",
                                                  at: base.addingTimeInterval(5))
        XCTAssertTrue(a.hasPrefix("analytics-pre-0.4.1-"))
        XCTAssertTrue(a.hasSuffix(".db"))
        XCTAssertLessThan(a, b)   // lexicographic == chronological for pruning
        XCTAssertEqual(EngineUpgradeGuard.backupFileName(engineVersion: "a/b", at: base)
                         .hasPrefix("analytics-pre-a-b-"), true)
    }

    func testBackupGuardCopiesStampsAndSkipsSameVersion() throws {
        let dataDir = makeTempDir()
        let db = EngineUpgradeGuard.databaseURL(dataDir: dataDir)
        try "existing data".write(to: db, atomically: true, encoding: .utf8)
        let guard_ = EngineUpgradeGuard(dataDir: dataDir)

        // New version over existing db -> one backup + stamp.
        let backup = try XCTUnwrap(guard_.backupIfNeeded(engineVersion: "0.5.0"))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "existing data")
        XCTAssertEqual(try String(contentsOf: EngineUpgradeGuard.stampURL(dataDir: dataDir),
                                  encoding: .utf8), "0.5.0")

        // Same version again -> no second backup.
        XCTAssertNil(try guard_.backupIfNeeded(engineVersion: "0.5.0"))
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: EngineUpgradeGuard.backupsDir(dataDir: dataDir).path)
        XCTAssertEqual(backups.count, 1)
    }

    func testPruneKeepsNewestThree() throws {
        let dataDir = makeTempDir()
        let dir = EngineUpgradeGuard.backupsDir(dataDir: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = (0..<5).map { String(format: "analytics-pre-0.5.0-20260101-00000%d.db", $0) }
        for name in names {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let guard_ = EngineUpgradeGuard(dataDir: dataDir)
        guard_.pruneBackups(dir: dir)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining, Array(names.suffix(EngineUpgradeGuard.keepBackups)))
    }
}

// MARK: - Launch state machine (fakes only)

private final class FakeChild: EngineChildProcess {
    let launchArguments: [String]
    var alive = true
    private(set) var launchCount = 0
    init(arguments: [String]) { launchArguments = arguments }
    var isAlive: Bool { alive && launchCount > 0 }
    func launch() throws { launchCount += 1 }
}

final class EngineProcessManagerTests: XCTestCase {
    private var clock: Date!
    private var probeResults: [Bool] = []
    private var launchedChildren: [FakeChild] = []

    @discardableResult
    private func makeManager(location: EngineRuntimeLocation? = EngineRuntimeLocation(
            pythonExecutable: URL(fileURLWithPath: "/fake/python3"),
            serveScript: URL(fileURLWithPath: "/fake/orx_engine_serve.py"),
            moduleSearchPath: nil, origin: "test"),
            version: String = "0.4.1",
            dataDirNeedingIO: Bool = false,
            probe: ((String) -> Bool)? = nil) -> (EngineProcessManager, String) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        clock = base
        let dir = makeTempDir()
        if dataDirNeedingIO {
            // Real upgrade-guard IO: a database that exists.
            try? "db".write(to: EngineUpgradeGuard.databaseURL(dataDir: dir),
                            atomically: true, encoding: .utf8)
        }
        let manager = EngineProcessManager(
            location: location,
            engineVersion: version,
            now: { [unowned self] in
                self.clock = self.clock.addingTimeInterval(1)   // 1s per call
                return self.clock
            },
            probe: probe ?? { [unowned self] _ in
                // Default: socket serves only after the child launched.
                guard let child = self.launchedChildren.last, child.launchCount > 0 else {
                    return false
                }
                self.probeResults.append(true)
                return true
            },
            childFactory: { [unowned self] loc, dataDir in
                let child = FakeChild(arguments: [loc.serveScript.path, dataDir])
                self.launchedChildren.append(child)
                return child
            },
            sleep: { _ in })
        return (manager, dir.path)
    }

    override func tearDown() {
        launchedChildren.removeAll()
        probeResults.removeAll()
        super.tearDown()
    }

    func testAlreadyRunningNeverSpawns() async {
        let (manager, _) = makeManager(
            location: nil,
            probe: { _ in true })
        let out = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: "/tmp/d")
        XCTAssertEqual(out, .alreadyRunning)
        XCTAssertTrue(launchedChildren.isEmpty)
    }

    func testUnavailableWithoutRuntimeReportsHowToFix() async {
        let (manager, _) = makeManager(location: nil, probe: { _ in false })
        let out = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: "/tmp/d")
        guard case let .unavailable(message) = out else {
            return XCTFail("expected unavailable, got \(out)")
        }
        XCTAssertTrue(message.contains("ORX_ANALYTICS_ENGINE_PYTHON"))
        XCTAssertTrue(launchedChildren.isEmpty)
    }

    func testLaunchesServeScriptWithDataDirAndWaitsForSocket() async {
        let (manager, dataDir) = makeManager(dataDirNeedingIO: true)
        let out = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: dataDir)
        XCTAssertEqual(out, .started)
        XCTAssertEqual(launchedChildren.count, 1)
        XCTAssertEqual(launchedChildren[0].launchArguments,
                       ["/fake/orx_engine_serve.py", dataDir])
        XCTAssertEqual(launchedChildren[0].launchCount, 1)
    }

    func testSocketNeverComingUpFailsThenBacksOff() async {
        let (manager, dataDir) = makeManager(
            dataDirNeedingIO: true,
            probe: { _ in false })   // socket never serves
        let first = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: dataDir)
        guard case .failed = first else { return XCTFail("expected failed, got \(first)") }
        XCTAssertEqual(launchedChildren.count, 1)

        // An immediate second attempt must back off, not respawn in a
        // tight loop (bounded respawn, design §8).
        let second = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: dataDir)
        guard case let .backingOff(seconds) = second else {
            return XCTFail("expected backingOff, got \(second)")
        }
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertLessThanOrEqual(seconds, EngineProcessManager.respawnBackoff)
        XCTAssertEqual(launchedChildren.count, 1)
    }

    func testChildDyingBeforeSocketIsReportedWithLogTail() async throws {
        let dataDir = makeTempDir()
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try "line1\nline2\nboom".write(to: dataDir.appendingPathComponent("logs/engine-launch.log"),
                                       atomically: true, encoding: .utf8)
        let (manager, _) = makeManager(
            dataDirNeedingIO: true,
            probe: { [unowned self] _ in
                // Kill the child on the first probe so isAlive is false.
                if let child = self.launchedChildren.last, child.launchCount > 0 {
                    child.alive = false
                }
                return false
            })
        let out = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: dataDir.path)
        guard case let .failed(message) = out else { return XCTFail("expected failed, got \(out)") }
        XCTAssertTrue(message.contains("boom"), "log tail missing from: \(message)")
    }

    func testUpgradeBackupFailureBlocksLaunch() async throws {
        // A file squatting on the backups/ path makes the backup throw;
        // the manager must refuse to launch over an unbacked database.
        let dataDir = makeTempDir()
        try "db".write(to: EngineUpgradeGuard.databaseURL(dataDir: dataDir),
                       atomically: true, encoding: .utf8)
        try "blocker".write(to: EngineUpgradeGuard.backupsDir(dataDir: dataDir),
                            atomically: true, encoding: .utf8)
        let (manager, _) = makeManager()
        let out = await manager.ensureRunning(socketPath: "/tmp/s.sock", dataDir: dataDir.path)
        guard case let .failed(message) = out else { return XCTFail("expected failed, got \(out)") }
        XCTAssertTrue(message.contains("备份"), message)
        XCTAssertTrue(launchedChildren.isEmpty, "must not launch before the backup succeeds")
    }
}
