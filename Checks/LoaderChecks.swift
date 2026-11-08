import Foundation
import SceneKit
import AppKit
import simd
import ImageIO

// Standalone checks keep validation available with Command Line Tools only (no XCTest/Xcode).
var checkFailures = 0
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { checkFailures += 1; print("FAIL \(file):\(line): \(message)") }
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows { if try !value() { XCTFail("Expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows { if try value() { XCTFail("Expected false", file: file, line: line) } }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { XCTFail("Expected nil", file: file, line: line) } }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { XCTFail("\(a) != \(b)", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body(); XCTFail("Expected error", file: file, line: line) } catch { } }

final class MockDiskProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class SlowCopyService: FileService {
    var trashed: [Location] = []
    override func copyFile(_ entry: FileEntry, to target: Location, progress: ByteProgress? = nil) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: entry.location.path))
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: target.path)); defer { try? output.close() }
        let chunk = max(1, data.count / 12)
        for start in stride(from: 0, to: data.count, by: chunk) {
            try Task.checkCancellation()
            let end = min(data.count, start + chunk)
            try output.write(contentsOf: data.subdata(in: start..<end))
            progress?(Int64(end), Int64(data.count))
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    override func trash(_ location: Location) async throws {
        trashed.append(location)
        try FileManager.default.removeItem(atPath: location.path)
    }
}

final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func append(_ bytes: Int64, _ total: Int64) { lock.lock(); values.append((bytes,total)); lock.unlock() }
    var samples: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return values }
}

final class LoaderTests {
    var root: URL!
    func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("YandexLoaderTests-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func tearDownWithError() throws { try? FileManager.default.removeItem(at: root); MockDiskProtocol.handler = nil }
    func mockClient() -> DiskClient { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockDiskProtocol.self]; return DiskClient(token: "test-token", session: URLSession(configuration: config)) }
    func entry(_ path: String, directory: Bool = false) -> FileEntry { FileEntry(location: .local(path), name: (path as NSString).lastPathComponent, isDirectory: directory, size: 0, modified: nil) }

    func testPathsAndAncestorProtection() {
        XCTAssertEqual(Location.parse("disk:/models/a/../b").path, "disk:/models/b")
        XCTAssertEqual(Location.disk("disk:/").parent, .disk("disk:/"))
        XCTAssertEqual(Location.disk("disk:/models/a").parent, .disk("disk:/models"))
        XCTAssertTrue(Location.disk("disk:/models").contains(.disk("disk:/models/a")))
        XCTAssertFalse(Location.disk("disk:/models").contains(.disk("disk:/models2")))
        XCTAssertFalse(Location.local("/models").contains(.disk("disk:/models/a")))
        XCTAssertEqual(Location.disk("disk:/models/папка").breadcrumbs.map(\.0), ["Яндекс Диск", "models", "папка"])
    }
    func testDateGroupsAndNameRules() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(Listing.group(for: now, now: now, calendar: calendar), "Сегодня")
        XCTAssertEqual(Listing.group(for: yesterday, now: now, calendar: calendar), "Вчера")
        XCTAssertEqual(Listing.group(for: calendar.date(byAdding: .day, value: -6, to: now), now: now, calendar: calendar), "Предыдущие 7 дней")
        XCTAssertEqual(Listing.group(for: calendar.date(byAdding: .day, value: -20, to: now), now: now, calendar: calendar), "Предыдущие 30 дней")
        XCTAssertEqual(Listing.group(for: calendar.date(from: DateComponents(year: 2025, month: 4, day: 1)), now: now, calendar: calendar), "Апрель 2025")
        XCTAssertEqual(Listing.group(for: nil), "Без даты")
        XCTAssertEqual(Listing.numberedName("model.stl", number: 2, isDirectory: false), "model (2).stl")
        XCTAssertEqual(Listing.numberedName("folder.v1", number: 3, isDirectory: true), "folder.v1 (3)")
        XCTAssertThrowsError(try Listing.validateName("../a")); XCTAssertThrowsError(try Listing.validateName("..")); try Listing.validateName("модель 2.stl")
    }
    func testTokenExtraction() {
        XCTAssertEqual(TokenStore.extract("https://oauth.yandex.ru/verification_code#access_token=abc%2B123&token_type=bearer"), "abc+123")
        XCTAssertEqual(TokenStore.extract(" test-token \n"), "test-token")
        XCTAssertNil(TokenStore.extract("https://oauth.yandex.ru/")); XCTAssertNil(TokenStore.extract(""))
    }
    func testPaginationEncodingAndOAuthHeader() async throws {
        let client = mockClient(); var offsets: [Int] = []
        MockDiskProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth test-token")
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(q.first(where: { $0.name == "path" })?.value, "disk:/модели & готовое")
            XCTAssertEqual(q.first(where: { $0.name == "limit" })?.value, "200")
            let offset = Int(q.first(where: { $0.name == "offset" })!.value!)!; offsets.append(offset)
            let items = (offset..<min(offset+200, 235)).map { ["name": "\($0).stl", "path": "disk:/\($0).stl", "type": "file", "size": 123] as [String: Any] }
            return (200, try JSONSerialization.data(withJSONObject: ["_embedded": ["items": items, "total": 235]]))
        }
        let files = try await client.list(.disk("disk:/модели & готовое"))
        XCTAssertEqual(files.count, 235); XCTAssertEqual(offsets, [0,200])
    }
    func testUnauthorizedAndNotFound() async throws {
        let client = mockClient(); MockDiskProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client.list(.disk("disk:/")); XCTFail("Expected 401") } catch { XCTAssertEqual(error.localizedDescription, LoaderError.unauthorized.localizedDescription) }
        MockDiskProtocol.handler = { _ in (404, Data()) }; let value = try await client.metadata(.disk("disk:/missing")); XCTAssertNil(value)
    }
    func testServerCopyWaitsFor202() async throws {
        let client = mockClient(); var polls = 0; var methods: [String] = []
        MockDiskProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.url!.path.contains("operations") { polls += 1; return (200, Data("{\"status\":\"\(polls == 1 ? "in-progress" : "success")\"}".utf8)) }
            XCTAssertEqual(request.url!.path, "/v1/disk/resources/copy")
            return (202, Data("{\"href\":\"https://cloud-api.yandex.net/v1/disk/operations/test\"}".utf8))
        }
        try await client.copy(.disk("disk:/a"), to: .disk("disk:/b"), move: false)
        XCTAssertEqual(polls, 2); XCTAssertEqual(methods, ["POST", "GET", "GET"])
    }
    @MainActor func testRecursiveCopySkipsDSStoreAndPreservesOriginal() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("mesh".utf8).write(to: source.appendingPathComponent("nested/model.stl")); try Data().write(to: source.appendingPathComponent(".DS_Store")); try Data("hidden".utf8).write(to: source.appendingPathComponent(".config"))
        let engine = TransferEngine(files: FileService(disk: DiskClient()))
        let report = try await engine.run([entry(source.path, directory: true)], to: .local(target.path), move: false)
        XCTAssertEqual(report.completed.count, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("source/nested/model.stl")), Data("mesh".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("nested/model.stl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("source/.DS_Store").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("source/.config").path))
    }
    @MainActor func testConflictKeepBothAndApplyAll() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["a.stl", "b.stl"] { try Data("new".utf8).write(to: source.appendingPathComponent(name)); try Data("old".utf8).write(to: target.appendingPathComponent(name)) }
        let engine = TransferEngine(files: FileService(disk: DiskClient())); var prompts = 0
        engine.resolve = { _, _ in prompts += 1; return ConflictAnswer(choice: .keepBoth, applyToAll: true) }
        _ = try await engine.run([entry(source.appendingPathComponent("a.stl").path), entry(source.appendingPathComponent("b.stl").path)], to: .local(target.path), move: false)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.stl")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a (2).stl")), Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("b (2).stl").path))
    }
    @MainActor func testRejectsSelfCopyAndSymlinkDescendant() async throws {
        let dir = root.appendingPathComponent("models"), child = dir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        let engine = TransferEngine(files: FileService(disk: DiskClient()))
        for target in [dir, child, link] { do { _ = try await engine.run([entry(dir.path, directory: true)], to: .local(target.path), move: false); XCTFail("Expected self-copy rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("самой себя")) } }
    }
    @MainActor func testFailedMoveKeepsSourceAndCleansStaging() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // A missing child source forces a failure before publication and before trashing.
        let missing = source.appendingPathComponent("missing.stl")
        let engine = TransferEngine(files: FileService(disk: DiskClient()))
        do { _ = try await engine.run([entry(missing.path)], to: .local(target.path), move: true); XCTFail("Expected read failure") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testSTLAndPLYGeometry() throws {
        let stl = Data("solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 10 0 0\nvertex 0 10 0\nendloop\nendfacet\nendsolid".utf8)
        let node = try ModelLoader.stl(stl); XCTAssertEqual(ModelLoader.triangleCount(node), 1)
        XCTAssertEqual(node.boundingBox.max.x, 10)
        let ply = Data("ply\nformat ascii 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n1 1 0\n0 1 0\n4 0 1 2 3\n".utf8)
        XCTAssertEqual(ModelLoader.triangleCount(try ModelLoader.ply(ply)), 2)
        XCTAssertThrowsError(try ModelLoader.stl(Data("broken".utf8)))
        XCTAssertThrowsError(try ModelLoader.ply(Data("broken".utf8)))
    }
    func testEmbeddedGLTFAndGLB() throws {
        let positions: [Float] = [0,0,0, 1,0,0, 0,1,0]; let bytes = positions.withUnsafeBytes { Data($0) }
        let object: [String: Any] = ["asset": ["version": "2.0"], "buffers": [["uri": "data:application/octet-stream;base64," + bytes.base64EncodedString(), "byteLength": bytes.count]], "bufferViews": [["buffer": 0, "byteLength": bytes.count]], "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]], "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]], "nodes": [["mesh": 0]], "scenes": [["nodes": [0]]]]
        var json = try JSONSerialization.data(withJSONObject: object)
        let url = root.appendingPathComponent("triangle.gltf"); try json.write(to: url)
        XCTAssertEqual(ModelLoader.triangleCount(try ModelLoader.load(url)), 1)
        while json.count % 4 != 0 { json.append(0x20) }
        var glb = Data(); func word(_ n: UInt32) { var le = n.littleEndian; withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) } }
        word(0x46546C67); word(2); word(UInt32(20 + json.count)); word(UInt32(json.count)); word(0x4E4F534A); glb.append(json)
        let binary = root.appendingPathComponent("triangle.glb"); try glb.write(to: binary)
        XCTAssertEqual(ModelLoader.triangleCount(try ModelLoader.load(binary)), 1)
    }
    @MainActor func testCancellationPreservesWholeSource() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for i in 0..<4 { try Data(repeating: UInt8(i), count: 1024).write(to: source.appendingPathComponent("\(i).stl")) }
        let engine = TransferEngine(files: FileService(disk: DiskClient()))
        var operation: Task<TransferReport, Error>?
        var children = 0
        engine.onProgress = { name, _, _ in if name.hasSuffix("stl") { children += 1; if children == 2 { operation?.cancel() } } }
        operation = Task { try await engine.run([self.entry(source.path, directory: true)], to: .local(target.path), move: true) }
        do { _ = try await operation!.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    @MainActor func testDiskMoveUsesOnlyServer() async throws {
        let client = mockClient(); var calls: [String] = []
        MockDiskProtocol.handler = { request in
            let path = request.url!.path; calls.append(request.httpMethod! + " " + path)
            if request.httpMethod == "GET" { return (404, Data()) }
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(q.first(where: { $0.name == "from" })?.value, "disk:/models/a")
            XCTAssertEqual(q.first(where: { $0.name == "path" })?.value, "disk:/ready/a")
            return (201, Data())
        }
        let engine = TransferEngine(files: FileService(disk: client))
        let file = FileEntry(location: .disk("disk:/models/a"), name: "a", isDirectory: true, size: 0, modified: nil)
        _ = try await engine.run([file], to: .disk("disk:/ready"), move: true)
        XCTAssertEqual(calls, ["GET /v1/disk/resources", "POST /v1/disk/resources/move"])
    }
    @MainActor func testPaneSelectionAndContextOwnership() async throws {
        _ = NSApplication.shared
        try Data("a".utf8).write(to: root.appendingPathComponent("first.txt")); try Data("b".utf8).write(to: root.appendingPathComponent("second.txt"))
        let files = FileService(disk: DiskClient())
        let pane = PaneView(id: "check", files: files, location: .local(root.path))
        pane.reload()
        for _ in 0..<100 { if pane.entries.count == 2 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(pane.entries.count, 2)
        pane.select(locations: Set(pane.entries.map(\.location))); XCTAssertEqual(pane.selected.count, 2)
        pane.active = false; pane.active = true; XCTAssertEqual(pane.selected.count, 2)
        pane.select(locations: [pane.entries[0].location]); XCTAssertEqual(pane.selected.count, 1)
        var activated: PaneView?, opened: FileEntry?
        pane.onActivate = { activated = $0 }; pane.onOpen = { opened = $0 }
        let item = pane.contextMenu().items[0]
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        XCTAssertTrue(activated === pane); XCTAssertEqual(opened?.location, pane.entries[0].location)
        pane.search.stringValue = "no-such-name"; pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); XCTAssertTrue(pane.visibleFiles.isEmpty)
        pane.search.stringValue = ""; pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); pane.select(locations: [pane.entries[1].location]); XCTAssertEqual(pane.selected.count, 1)
        let row = FileRow(); let cell = NSTableCellView(); cell.identifier = .init("date"); let dateLabel = label("date"); cell.addSubview(dateLabel); cell.textField = dateLabel; row.addSubview(cell); row.active = true; row.isSelected = true
        XCTAssertEqual(cell.textField?.textColor, NSColor.white); row.active = false; XCTAssertEqual(cell.textField?.textColor, NSColor.secondaryLabelColor)
    }
    @MainActor func testWindowFillsContentArea() {
        _ = NSApplication.shared
        let coordinator = AppCoordinator(); coordinator.makeWindow()
        for size in [NSSize(width: 1240, height: 780), NSSize(width: 900, height: 600)] {
            coordinator.window.setContentSize(size); coordinator.window.contentView?.layoutSubtreeIfNeeded()
            let root = coordinator.window.contentView!, split = root.subviews.compactMap { $0 as? NSSplitView }.first!
            XCTAssertEqual(split.frame.minX, 0); XCTAssertEqual(split.frame.width, root.bounds.width)
            XCTAssertEqual(coordinator.sidebar.frame.minX, 0)
            XCTAssertTrue(coordinator.dual.frame.width > 440)
            XCTAssertEqual(coordinator.sidebar.scroll.frame.minX, 0)
            coordinator.dual.layoutSubtreeIfNeeded()
            for pane in [coordinator.left, coordinator.right] {
                pane.layoutSubtreeIfNeeded()
                XCTAssertTrue(pane.sort.convert(pane.sort.bounds, to: pane).maxX <= pane.bounds.maxX + 1)
                XCTAssertTrue(pane.search.convert(pane.search.bounds, to: pane).minX >= 0)
            }
        }
        coordinator.window.orderOut(nil)
    }
    @MainActor func testTransferIconsFollowSelection() async throws {
        _ = NSApplication.shared
        for i in 0..<80 { try Data().write(to: root.appendingPathComponent(String(format: "%03d.txt", i))) }
        let coordinator = AppCoordinator(); coordinator.makeWindow()
        defer { coordinator.window.orderOut(nil) }
        let panes = [coordinator.left, coordinator.right]
        for pane in panes {
            pane.onActivate = { coordinator.activate($0) }
            pane.onChange = { coordinator.updateState() }
            pane.onViewportChange = { coordinator.dual.updateControlPosition() }
            pane.navigate(.local(root.path))
        }
        for _ in 0..<100 { if panes.allSatisfy({ $0.entries.count == 80 }) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        coordinator.window.contentView?.layoutSubtreeIfNeeded(); coordinator.dual.layoutSubtreeIfNeeded()
        let dual = coordinator.dual
        func rowCenter(_ pane: PaneView, _ row: Int) -> CGFloat { pane.table.convert(NSPoint(x: 0, y: pane.table.rect(ofRow: row).midY), to: dual).y }
        func checkCenter(_ expected: CGFloat) { XCTAssertTrue(abs(dual.transferControls.frame.midY - expected) < 1); XCTAssertTrue(abs(dual.transferControls.frame.midX - dual.band.frame.midX) < 1) }
        coordinator.left.select(locations: [coordinator.left.visibleFiles[2].location]); coordinator.activate(coordinator.left)
        let first = coordinator.left.table.selectedRowIndexes.first!
        checkCenter(rowCenter(coordinator.left, first))
        XCTAssertEqual(dual.copyButton.title, ""); XCTAssertEqual(dual.moveButton.title, "")
        XCTAssertTrue(dual.moveButton.toolTip!.contains("правую")); XCTAssertTrue(dual.moveButton.isEnabled)
        coordinator.left.select(locations: [coordinator.left.visibleFiles[2].location, coordinator.left.visibleFiles[8].location])
        let indexes = coordinator.left.table.selectedRowIndexes
        checkCenter((rowCenter(coordinator.left, indexes.first!) + rowCenter(coordinator.left, indexes.last!)) / 2)
        coordinator.left.table.scrollRowToVisible(8)
        checkCenter((rowCenter(coordinator.left, indexes.first!) + rowCenter(coordinator.left, indexes.last!)) / 2)
        coordinator.right.select(locations: [coordinator.right.visibleFiles[3].location]); coordinator.activate(coordinator.right)
        checkCenter(rowCenter(coordinator.right, coordinator.right.table.selectedRowIndexes.first!))
        XCTAssertTrue(dual.moveButton.toolTip!.contains("левую"))
        // The selected source can be offscreen, but the controls remain inside the list viewport.
        coordinator.right.table.scrollRowToVisible(70)
        let viewport = coordinator.right.transferAnchor(in: dual)!.viewport
        XCTAssertTrue(dual.transferControls.frame.minY >= viewport.minY)
        XCTAssertTrue(dual.transferControls.frame.maxY <= viewport.maxY)
        coordinator.left.table.deselectAll(nil); coordinator.right.table.deselectAll(nil)
        XCTAssertFalse(dual.copyButton.isEnabled); XCTAssertFalse(dual.moveButton.isEnabled)
    }
    func testPreviewOrientationAndCenter() {
        func check(_ ext: String, zUp: Bool, expectedUp: SCNVector3) {
            let model = SCNNode(geometry: SCNBox(width: 10, height: 12, length: 40, chamferRadius: 0))
            model.position = SCNVector3(100, -60, 20)
            let preview = ModelPreviewScene.make(model: model, fileExtension: ext, zUp: zUp, aspectRatio: 1.5)
            let bounds = preview.modelRoot.boundingBox
            let center = preview.modelRoot.convertPosition(SCNVector3((bounds.min.x + bounds.max.x)/2, (bounds.min.y + bounds.max.y)/2, (bounds.min.z + bounds.max.z)/2), to: nil)
            XCTAssertTrue(abs(center.x) < 0.001 && abs(center.y) < 0.001 && abs(center.z) < 0.001)
            let localUp = zUp && ["stl", "ply"].contains(ext) ? SCNVector3(0, 0, 1) : SCNVector3(0, 1, 0)
            let up = model.convertVector(localUp, to: nil)
            XCTAssertTrue(abs(up.x - expectedUp.x) < 0.001 && abs(up.y - expectedUp.y) < 0.001 && abs(up.z - expectedUp.z) < 0.001)
            // The camera sits above the centred model and its forward ray meets the origin.
            XCTAssertTrue(preview.camera.position.y > 0)
            let forward = preview.camera.simdWorldFront, camera = preview.camera.simdWorldPosition
            let target = camera + forward * simd_length(camera)
            XCTAssertTrue(simd_length(target) < 0.001)
            XCTAssertTrue(preview.dimensions.x == 10 && preview.dimensions.y == 12 && preview.dimensions.z == 40)
        }
        check("stl", zUp: false, expectedUp: SCNVector3(0, 1, 0))
        check("ply", zUp: false, expectedUp: SCNVector3(0, 1, 0))
        check("stl", zUp: true, expectedUp: SCNVector3(0, 1, 0))
        check("ply", zUp: true, expectedUp: SCNVector3(0, 1, 0))
        check("glb", zUp: true, expectedUp: SCNVector3(0, 1, 0))
    }
    func testPreviewFollowsVisibleFileOrder() {
        let a = entry("/fixture/a.stl"), b = entry("/fixture/b.stl"), c = entry("/fixture/c.stl"), folder = entry("/fixture/folder", directory: true)
        var preview = PreviewSelection()
        preview.start(selected: [b], visible: [folder, a, b, c])
        XCTAssertEqual(preview.files, [a,b,c]); XCTAssertEqual(preview.current, b)
        XCTAssertEqual(preview.step(1), c); XCTAssertNil(preview.step(1)); XCTAssertEqual(preview.current, c)
        XCTAssertEqual(preview.step(-1), b)
        XCTAssertTrue(preview.follow(selected: [a], visible: [c,folder,b,a])); XCTAssertEqual(preview.index, 2); XCTAssertEqual(preview.files, [c,b,a])
        XCTAssertFalse(preview.follow(selected: [a], visible: [c,folder,b,a]))
        XCTAssertFalse(preview.follow(selected: [folder], visible: [c,folder,b,a])); XCTAssertEqual(preview.current, a)
        XCTAssertFalse(preview.follow(selected: [], visible: [c,b,a]))
        XCTAssertEqual(preview.step(-1), b)
        XCTAssertTrue(preview.follow(selected: [c], visible: [c,a])); XCTAssertEqual(preview.files, [c,a])
        XCTAssertNil(preview.step(-1)); XCTAssertEqual(preview.step(1), a)
        let updated = FileEntry(location: a.location, name: a.name, isDirectory: false, size: 123, modified: Date())
        XCTAssertTrue(preview.follow(selected: [updated], visible: [updated])); XCTAssertEqual(preview.current, updated)
    }
    @MainActor func testCancelOneFileContinuesQueue() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data(repeating: 37, count: 48_000)
        for name in ["cancel.stl", "keep.stl"] { try data.write(to: source.appendingPathComponent(name)) }
        let queue = TransferQueue(), service = SlowCopyService(disk: DiskClient())
        queue.observe {
            if let row = queue.records.first(where: { $0.entry.name == "cancel.stl" && $0.phase == .transferring && $0.bytes > 0 }) { queue.cancel(row.id) }
        }
        let engine = TransferEngine(files: service, queue: queue)
        let report = try await engine.run([entry(source.appendingPathComponent("cancel.stl").path), entry(source.appendingPathComponent("keep.stl").path)], to: .local(target.path), move: true)
        XCTAssertEqual(report.cancelled, 1); XCTAssertEqual(report.completed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("cancel.stl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("cancel.stl").path))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("keep.stl")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("keep.stl").path))
        XCTAssertEqual(service.trashed, [.local(source.appendingPathComponent("keep.stl").path)])
        XCTAssertEqual(queue.records.map(\.phase), [.cancelled, .completed])
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".yandexloader-") }))
    }
    @MainActor func testCancelledChildKeepsFolderOriginal() async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data(repeating: 42, count: 1000)
        for name in ["cancel.stl", "keep.stl"] { try data.write(to: source.appendingPathComponent(name)) }
        let queue = TransferQueue(), service = SlowCopyService(disk: DiskClient())
        queue.observe {
            if let row = queue.records.first(where: { $0.entry.name == "cancel.stl" && $0.phase == .waiting }) { queue.cancel(row.id) }
        }
        let engine = TransferEngine(files: service, queue: queue)
        let report = try await engine.run([entry(source.path, directory: true)], to: .local(target.path), move: true)
        XCTAssertEqual(report.partial.count, 1); XCTAssertEqual(report.completed.count, 0); XCTAssertEqual(report.cancelled, 1)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("cancel.stl")), data)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("keep.stl")), data)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("source/keep.stl")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("source/cancel.stl").path))
        XCTAssertTrue(service.trashed.isEmpty)
    }
    @MainActor func testByteWeightedProgressAndUnknownSize() {
        let queue = TransferQueue(); queue.begin(operation: "Загрузка", destination: .disk("disk:/test"))
        func file(_ name: String, _ size: Int64) -> FileEntry { FileEntry(location: .local("/" + name), name: name, isDirectory: false, size: size, modified: nil) }
        let a = queue.append(file("a.stl", 100), displayName: "a.stl"), b = queue.append(file("b.stl", 300), displayName: "b.stl")
        queue.prepared(); queue.setPhase(a, .transferring); queue.updateBytes(a, sent: 50, total: 100)
        XCTAssertTrue(abs(queue.fraction - 0.125) < 0.001)
        queue.setPhase(a, .completed); XCTAssertTrue(abs(queue.fraction - 0.25) < 0.001)
        queue.cancel(b); XCTAssertEqual(queue.fraction, 1)
        let unknown = TransferQueue(); unknown.begin(operation: "Скачивание", destination: .local("/tmp"))
        let id = unknown.append(file("unknown", 0), displayName: "unknown"); unknown.prepared(); unknown.setPhase(id, .transferring)
        unknown.updateBytes(id, sent: 123, total: 0); XCTAssertTrue(unknown.isIndeterminate); XCTAssertEqual(unknown.record(id)?.bytes, 123)
    }
    func testModelRenameNamesAndSelection() throws {
        let file = FileEntry(location: .disk("disk:/Модели/hero.STL"), name: "hero.STL", isDirectory: false, size: 42, modified: Date(timeIntervalSince1970: 100))
        let renamed = try ModelRename.entry(for: file, proposedName: "  Новый герой.v2  ")
        XCTAssertEqual(renamed.name, "Новый герой.v2.STL")
        XCTAssertEqual(renamed.location, .disk("disk:/Модели/Новый герой.v2.STL"))
        XCTAssertEqual(renamed.size, file.size); XCTAssertEqual(renamed.modified, file.modified)
        XCTAssertEqual(try ModelRename.entry(for: file, proposedName: "other.stl").name, "other.stl")
        for name in ["", " ", ".", "..", ".STL", "../other", "bad/name", "bad:name"] {
            XCTAssertThrowsError(try ModelRename.entry(for: file, proposedName: name))
        }
        let next = FileEntry(location: .disk("disk:/Модели/next.stl"), name: "next.stl", isDirectory: false, size: 1, modified: nil)
        var selection = PreviewSelection(); selection.start(selected: [file], visible: [next, file])
        selection.renamed(file.location, to: renamed)
        XCTAssertEqual(selection.index, 1); XCTAssertEqual(selection.current, renamed)
        XCTAssertEqual(selection.step(-1), next); XCTAssertEqual(selection.step(1), renamed)
    }
    func testLocalModelRenameProtectsFiles() async throws {
        let files = FileService(disk: mockClient())
        let original = root.appendingPathComponent("hero.stl")
        let data = Data("model data must remain unchanged".utf8)
        try data.write(to: original)
        let result = try await files.renameModel(entry(original.path), proposedName: "Новый герой")
        XCTAssertEqual(result.name, "Новый герой.stl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.location.path)), data)
        let occupied = root.appendingPathComponent("occupied.stl"), other = Data("other model".utf8)
        try other.write(to: occupied)
        do { _ = try await files.renameModel(result, proposedName: "occupied"); XCTFail("Must not replace another model") } catch { }
        XCTAssertEqual(try Data(contentsOf: occupied), other)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.location.path)), data)
        let capitalized = try await files.renameModel(result, proposedName: "НОВЫЙ ГЕРОЙ.stl")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capitalized.location.path)), data)
    }
    func testCloudModelRenameDoesNotDownload() async throws {
        let client = mockClient(), original = FileEntry(location: .disk("disk:/Models/hero.stl"), name: "hero.stl", isDirectory: false, size: 300_000_000, modified: nil)
        var moves = 0
        MockDiskProtocol.handler = { request in
            let path = request.url!.path
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if path.hasSuffix("/resources/move") {
                moves += 1
                XCTAssertEqual(query.first { $0.name == "from" }?.value, original.location.path)
                XCTAssertEqual(query.first { $0.name == "path" }?.value, "disk:/Models/New Hero.stl")
                XCTAssertEqual(query.first { $0.name == "overwrite" }?.value, "false")
                return (201, Data())
            }
            XCTAssertTrue(path.hasSuffix("/resources")); XCTAssertEqual(request.httpMethod, "GET")
            return (404, Data())
        }
        let renamed = try await FileService(disk: client).renameModel(original, proposedName: "New Hero")
        XCTAssertEqual(moves, 1); XCTAssertEqual(renamed.size, original.size)
        XCTAssertEqual(ModelSnapshot.destination(for: renamed), .disk("disk:/Models/New Hero.webp"))
    }
    func testSnapshotWebPEncoding() throws {
        let pixels: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255]
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = try ModelSnapshot.encode(image)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WEBP")
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(decoded.width, 2); XCTAssertEqual(decoded.height, 2)
        var restored = [UInt8](repeating: 0, count: 16)
        restored.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        XCTAssertEqual(restored, pixels) // lossless, with the same colours and orientation
    }
    func testSnapshotLocalSaveAndConflicts() async throws {
        let files = FileService(disk: mockClient())
        let model = root.appendingPathComponent("Герой.final.STL")
        let original = Data("original model".utf8), first = Data("first snapshot".utf8), second = Data("second snapshot".utf8)
        try original.write(to: model)
        let target = ModelSnapshot.destination(for: entry(model.path))
        XCTAssertEqual(target, .local(root.appendingPathComponent("Герой.final.webp").path))
        try await files.writeSnapshot(first, to: target)
        do { try await files.writeSnapshot(second, to: target); XCTFail("Existing snapshot must not be overwritten without confirmation") } catch { }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path)), first)
        let copy = try await ModelSnapshot.availableCopy(of: target, files: files)
        XCTAssertEqual(copy.name, "Герой.final (2).webp")
        try await files.writeSnapshot(second, to: copy)
        try await files.writeSnapshot(second, to: target, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path)), second)
        XCTAssertEqual(try Data(contentsOf: model), original)
        let folder = root.appendingPathComponent("folder.webp"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("keep.txt"); try original.write(to: child)
        do { try await files.writeSnapshot(second, to: .local(folder.path), overwrite: true); XCTFail("Must preserve existing folder") } catch { }
        XCTAssertEqual(try Data(contentsOf: child), original)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".yandexloader-snapshot-") })
    }
    func testSnapshotCloudDestinationAndOverwrite() async throws {
        let client = mockClient()
        let service = FileService(disk: client)
        let model = FileEntry(location: .disk("disk:/Модели/hero.stl"), name: "hero.stl", isDirectory: false, size: 10, modified: nil)
        let target = ModelSnapshot.destination(for: model)
        XCTAssertEqual(target, .disk("disk:/Модели/hero.webp"))
        var requests: [(String, String)] = [], uploads = 0
        MockDiskProtocol.handler = { request in
            if request.url!.path.hasSuffix("/resources/upload") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                requests.append((query.first { $0.name == "path" }!.value!, query.first { $0.name == "overwrite" }!.value!))
                return (200, Data("{\"href\":\"https://upload.example/snapshot\"}".utf8))
            }
            if request.httpMethod == "PUT" { uploads += 1; return (201, Data()) }
            return (200, Data("{\"name\":\"hero.webp\",\"path\":\"disk:/Модели/hero.webp\",\"type\":\"file\",\"size\":20}".utf8))
        }
        try await service.writeSnapshot(Data("image".utf8), to: target)
        try await service.writeSnapshot(Data("replacement".utf8), to: target, overwrite: true)
        XCTAssertEqual(requests.map { $0.0 }, [target.path, target.path])
        XCTAssertEqual(requests.map { $0.1 }, ["false", "true"])
        XCTAssertEqual(uploads, 2)
        MockDiskProtocol.handler = { _ in (200, Data("{\"name\":\"hero.webp\",\"path\":\"disk:/Модели/hero.webp\",\"type\":\"dir\"}".utf8)) }
        do { try await service.writeSnapshot(Data("image".utf8), to: target, overwrite: true); XCTFail("Must not overwrite a cloud folder") } catch { }
    }
    @MainActor func testUpdateWaitsForTransfers() {
        var busy = true, installed = 0
        let gate = UpdateInstallationGate(isBusy: { busy })
        XCTAssertTrue(gate.postpone { installed += 1 })
        gate.resumeIfIdle(); XCTAssertEqual(installed, 0)
        busy = false
        gate.resumeIfIdle(); XCTAssertEqual(installed, 1)
        gate.resumeIfIdle(); XCTAssertEqual(installed, 1)
        XCTAssertFalse(gate.postpone { installed += 1 })
        XCTAssertEqual(installed, 1)
        // A new operation postpones the next update independently.
        busy = true
        XCTAssertTrue(gate.postpone { installed += 1 })
        gate.resumeIfIdle(); XCTAssertEqual(installed, 1)
        busy = false
        gate.resumeIfIdle(); XCTAssertEqual(installed, 2)
    }
    func testNetworkProgressMonotonicity() {
        let captured = ProgressSamples()
        let delegate = NetworkProgressDelegate(expected: 1000) { captured.append($0, $1) }
        delegate.report(100, total: 1000, force: true); delegate.report(200, total: 1000, force: true); delegate.report(150, total: 1000, force: true)
        XCTAssertEqual(captured.samples.map { $0.0 }, [100,200,200])
        let unknown = ProgressSamples(); NetworkProgressDelegate(expected: 0, callback: { unknown.append($0,$1) }).report(100, total: -1, force: true)
        XCTAssertEqual(unknown.samples.first?.1, 0)
    }
    func testHTTPTransportProgress(_ base: URL) async throws {
        let length = 8 * 1024 * 1024
        let file = root.appendingPathComponent("network.bin"); try Data(repeating: 89, count: length).write(to: file)
        let session = URLSession(configuration: .ephemeral)
        let uploads = ProgressSamples(), downloads = ProgressSamples()
        var request = URLRequest(url: base.appendingPathComponent("upload")); request.httpMethod = "PUT"
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: NetworkProgressDelegate(expected: Int64(length), callback: { uploads.append($0,$1) }))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertTrue(uploads.samples.contains { $0.0 > 0 && $0.0 < Int64(length) })
        XCTAssertEqual(uploads.samples.last?.0, Int64(length))
        let (temp, _) = try await NetworkDownloadOperation.download(URLRequest(url: base.appendingPathComponent("download")), configuration: session.configuration, expected: Int64(length), progress: { downloads.append($0,$1) })
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertEqual(try Data(contentsOf: temp).count, length)
        XCTAssertTrue(downloads.samples.contains { $0.0 > 0 && $0.0 < Int64(length) })
        XCTAssertEqual(downloads.samples.last?.0, Int64(length))
        let operation = Task { try await session.upload(for: request, fromFile: file) }
        try await Task.sleep(nanoseconds: 120_000_000); operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected an interrupted upload") } catch { XCTAssertTrue(operation.isCancelled) }
        session.invalidateAndCancel()
    }
}

@main struct CheckRunner {
    @MainActor static func main() async {
        let tests = LoaderTests()
        var checks: [(String, () async throws -> Void)] = [
            ("paths and self-copy protection", { tests.testPathsAndAncestorProtection() }),
            ("date groups and names", { try tests.testDateGroupsAndNameRules() }),
            ("token extraction", { tests.testTokenExtraction() }),
            ("pagination and authorization", { try await tests.testPaginationEncodingAndOAuthHeader() }),
            ("401 and 404", { try await tests.testUnauthorizedAndNotFound() }),
            ("202 server polling", { try await tests.testServerCopyWaitsFor202() }),
            ("recursive local copy", { try await tests.testRecursiveCopySkipsDSStoreAndPreservesOriginal() }),
            ("conflicts and apply to all", { try await tests.testConflictKeepBothAndApplyAll() }),
            ("self-copy via symlink", { try await tests.testRejectsSelfCopyAndSymlinkDescendant() }),
            ("failed move preserves source", { try await tests.testFailedMoveKeepsSourceAndCleansStaging() }),
            ("STL and PLY", { try tests.testSTLAndPLYGeometry() }),
            ("glTF and GLB", { try tests.testEmbeddedGLTFAndGLB() }),
            ("cancelled move preserves subtree", { try await tests.testCancellationPreservesWholeSource() }),
            ("cloud move stays on server", { try await tests.testDiskMoveUsesOnlyServer() }),
            ("selection, filtering and context ownership", { try await tests.testPaneSelectionAndContextOwnership() }),
            ("window fills content at both sizes", { tests.testWindowFillsContentArea() }),
            ("divider icons follow selection and scroll", { try await tests.testTransferIconsFollowSelection() }),
            ("preview axes, transformed centre and camera", { tests.testPreviewOrientationAndCenter() }),
            ("preview follows selection, sorting and folder filtering", { tests.testPreviewFollowsVisibleFileOrder() }),
            ("cancel one active file and continue queue", { try await tests.testCancelOneFileContinuesQueue() }),
            ("cancel child and preserve folder source", { try await tests.testCancelledChildKeepsFolderOriginal() }),
            ("byte weighted progress and unknown sizes", { tests.testByteWeightedProgressAndUnknownSize() }),
            ("network progress remains monotonic", { tests.testNetworkProgressMonotonicity() }),
            ("update waits for transfer and resumes exactly once", { tests.testUpdateWaitsForTransfers() }),
            ("real lossless WebP keeps size, colours and orientation", { try tests.testSnapshotWebPEncoding() }),
            ("snapshot beside model, conflicts and source protection", { try await tests.testSnapshotLocalSaveAndConflicts() }),
            ("cloud snapshot uses original folder and explicit overwrite", { try await tests.testSnapshotCloudDestinationAndOverwrite() }),
            ("model rename keeps extension and preview position", { try tests.testModelRenameNamesAndSelection() }),
            ("local model rename preserves data and rejects collisions", { try await tests.testLocalModelRenameProtectsFiles() }),
            ("cloud rename moves on server without downloading model", { try await tests.testCloudModelRenameDoesNotDownload() })
        ]
        if let address = ProcessInfo.processInfo.environment["YANDEX_LOADER_TEST_SERVER"], let url = URL(string: address) { checks.append(("real upload/download byte progress and cancellation", { try await tests.testHTTPTransportProgress(url) })) }
        for (name, check) in checks {
            let before = checkFailures
            do { try tests.setUpWithError(); try await check() } catch { XCTFail("\(name): \(error)") }
            try? tests.tearDownWithError()
            print("\(checkFailures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count) scenarios, \(checkFailures) failures")
        exit(checkFailures == 0 ? 0 : 1)
    }
}
