import AppKit
import SceneKit
import Quartz
import CryptoKit

final class ModelWindow: NSWindow {
    var onKey: ((UInt16) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event.keyCode) == true { return }; super.keyDown(with: event) }
}

@MainActor final class PreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    let files: FileService
    private(set) var selection = PreviewSelection()
    private weak var sourcePane: PaneView?
    private var selectingFromPreview = false
    var queue: [FileEntry] { selection.files }
    var index: Int { selection.index }
    var isOpen: Bool { window?.isVisible == true || QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true }
    var window: ModelWindow?
    var sceneView: SCNView?
    var currentURL: URL?
    var loadTask: Task<Void, Never>?
    private var displayedFile: FileEntry?
    private var modelDetails = ""
    private var snapshotButton: NSButton?
    private var snapshotTask: Task<Void, Never>?
    var isSavingSnapshot: Bool { snapshotTask != nil }
    var onSnapshotSaved: ((Location) -> Void)?
    var onSnapshotError: ((Error) -> Void)?
    var onSnapshotActivityChange: (() -> Void)?
    var keyMonitor: Any?
    var header = label("", size: 14, bold: true)
    var footer = label("", size: 12, color: .secondaryLabelColor)
    var cachedRoot: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.blueeggs.yandexloader/Preview", isDirectory: true) }
    init(files: FileService) { self.files = files; super.init(); cleanCache() }
    func toggle(in pane: PaneView) {
        if isOpen { close(); return }
        sourcePane = pane
        selection.start(selected: pane.selected, visible: pane.visibleFiles)
        if selection.current != nil { showCurrent() }
    }
    func close() { loadTask?.cancel(); sourcePane = nil; window?.orderOut(nil); if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) } }
    func followSelection(in pane: PaneView) {
        guard isOpen, !selectingFromPreview else { return }
        sourcePane = pane
        if selection.follow(selected: pane.selected, visible: pane.visibleFiles) {
            showCurrent(activate: false, debounce: true)
        }
    }
    func step(_ delta: Int) {
        guard let file = selection.step(delta) else { return }
        selectingFromPreview = true
        sourcePane?.select(locations: [file.location])
        if let pane = sourcePane, pane.table.selectedRow >= 0 { pane.table.scrollRowToVisible(pane.table.selectedRow) }
        selectingFromPreview = false
        showCurrent(activate: false)
    }
    private func present(_ window: NSWindow?, activate: Bool) {
        if activate { window?.makeKeyAndOrderFront(nil) }
        else if window?.isVisible != true { window?.orderFront(nil) }
    }
    func showCurrent(activate: Bool = true, debounce: Bool = false) {
        loadTask?.cancel(); guard let file = selection.current else { return }
        displayedFile = nil; updateSnapshotButton()
        if ModelLoader.extensions.contains(file.ext) { if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }; ensureWindow(); present(window, activate: activate); header.stringValue = file.name; footer.stringValue = "Загружаем модель…"; sceneView?.scene = nil }
        else { window?.orderOut(nil) }
        loadTask = Task { @MainActor in
            do {
                if debounce { try await Task.sleep(nanoseconds: 120_000_000) }
                let url = try await localURL(for: file); try Task.checkCancellation(); currentURL = url
                if ModelLoader.extensions.contains(file.ext) {
                    let task = Task.detached(priority: .userInitiated) { try ModelLoader.load(url) }
                    let model = try await task.value; try Task.checkCancellation(); display(model, file: file)
                } else {
                    let panel = QLPreviewPanel.shared()!; panel.updateController(); present(panel, activate: activate); panel.reloadData()
                }
            } catch is CancellationError { } catch { guard !Task.isCancelled else { return }; ensureWindow(); present(window, activate: activate); header.stringValue = file.name; footer.stringValue = errorText(error) }
        }
    }
    func ensureWindow() {
        guard window == nil else { return }
        let w = ModelWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false); w.title = "Быстрый просмотр"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 500, height: 380); w.level = .floating
        let previous = ActionButton("", image: "chevron.left") { [weak self] in self?.step(-1) }
        let next = ActionButton("", image: "chevron.right") { [weak self] in self?.step(1) }
        let reset = ActionButton("Сбросить вид", image: "arrow.counterclockwise") { [weak self] in self?.showCurrent() }
        let snapshot = ActionButton("Снимок", image: "camera") { [weak self] in self?.takeSnapshot() }
        snapshot.toolTip = "Сохранить текущий ракурс в WebP рядом с моделью"
        snapshot.setAccessibilityLabel("Сохранить снимок модели")
        snapshot.isEnabled = false; snapshotButton = snapshot
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [previous, next, header, spacer, snapshot, reset]); top.spacing = 12; top.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let view = SCNView(); view.allowsCameraControl = true; view.autoenablesDefaultLighting = false; view.antialiasingMode = .multisampling4X; view.backgroundColor = NSColor(white: 0.13, alpha: 1); sceneView = view
        footer.maximumNumberOfLines = 3; footer.lineBreakMode = .byWordWrapping
        let hint = label("Мышь — вращение · Колесо — масштаб · ↑ ↓ — файлы · Пробел — закрыть", size: 11, color: .secondaryLabelColor)
        let bottom = NSStackView(views: [footer, hint]); bottom.orientation = .vertical; bottom.alignment = .leading; bottom.spacing = 4; bottom.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        let stack = NSStackView(views: [top, view, bottom]); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 0; w.contentView = stack
        for section in [top, view, bottom] { section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        w.onKey = { [weak self] key in switch key { case 49, 53: self?.close(); return true; case 123, 126: self?.step(-1); return true; case 124, 125: self?.step(1); return true; default: return false } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] event in
            if event.window === w && w?.isVisible == true && w?.onKey?(event.keyCode) == true { return nil }
            return event
        }
        w.center(); window = w
    }
    func display(_ model: SCNNode, file: FileEntry) {
        let zUp = UserDefaults.standard.bool(forKey: "zUp")
        let viewport = sceneView?.bounds.size ?? NSSize(width: 880, height: 580)
        let preview = ModelPreviewScene.make(model: model, fileExtension: file.ext, zUp: zUp, aspectRatio: viewport.width / max(1, viewport.height))
        let dimensions = preview.dimensions
        sceneView?.scene = preview.scene
        sceneView?.pointOfView = preview.camera
        sceneView?.defaultCameraController.automaticTarget = false
        sceneView?.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        sceneView?.defaultCameraController.target = SCNVector3Zero
        sceneView?.defaultCameraController.interactionMode = .orbitTurntable
        let triangles = ModelLoader.triangleCount(model)
        modelDetails = "\(triangles.formatted()) треугольников · Габариты: \(String(format: "%.3g × %.3g × %.3g", dimensions.x, dimensions.y, dimensions.z)) (единицы файла)"
        footer.stringValue = modelDetails
        header.stringValue = file.name + (queue.count > 1 ? "   \(index+1)/\(queue.count)" : "")
        displayedFile = file; updateSnapshotButton()
    }
    private func updateSnapshotButton() {
        snapshotButton?.isEnabled = displayedFile != nil && sceneView?.scene != nil && !isSavingSnapshot
    }
    func cancelSnapshot() { snapshotTask?.cancel() }
    func takeSnapshot() {
        guard !isSavingSnapshot, let file = displayedFile, let view = sceneView, view.scene != nil else { return }
        // Capture before any await: changing selection while saving cannot mix a model's image and name.
        guard let image = view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            footer.stringValue = "Не удалось получить снимок модели."; return
        }
        footer.stringValue = "Сохраняем снимок…"
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { snapshotTask = nil; updateSnapshotButton(); onSnapshotActivityChange?() }
            do {
                var target = ModelSnapshot.destination(for: file)
                var overwrite = false
                if try await files.exists(target) {
                    let response = await snapshotConflict(target)
                    try Task.checkCancellation()
                    switch response {
                    case .alertFirstButtonReturn: overwrite = true
                    case .alertSecondButtonReturn: target = try await ModelSnapshot.availableCopy(of: target, files: files)
                    default:
                        if displayedFile?.location == file.location { footer.stringValue = modelDetails }
                        return
                    }
                }
                let encoding = Task.detached(priority: .userInitiated) { try ModelSnapshot.encode(image) }
                let data = try await encoding.value
                try Task.checkCancellation()
                try await files.writeSnapshot(data, to: target, overwrite: overwrite)
                if displayedFile?.location == file.location { footer.stringValue = "Сохранён снимок: \(target.name)" }
                onSnapshotSaved?(target)
            } catch is CancellationError {
                if displayedFile?.location == file.location { footer.stringValue = modelDetails }
            } catch {
                if displayedFile?.location == file.location { footer.stringValue = "Снимок не сохранён: " + errorText(error) }
                onSnapshotError?(error)
            }
        }
        updateSnapshotButton(); onSnapshotActivityChange?()
    }
    private func snapshotConflict(_ target: Location) async -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "«\(target.name)» уже существует"
            alert.informativeText = "Заменить изображение в папке \(target.parent.name)?"
            alert.addButton(withTitle: "Заменить")
            alert.addButton(withTitle: "Сохранить копию")
            alert.addButton(withTitle: "Отмена")
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { currentURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { currentURL as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode { case 49, 53: close(); return true; case 123, 126: step(-1); return true; case 124, 125: step(1); return true; default: return false }
    }
    func localURL(for file: FileEntry) async throws -> URL {
        guard file.location.isDisk else { return URL(fileURLWithPath: file.location.path) }
        let key = file.location.path + "|" + String(file.modified?.timeIntervalSince1970 ?? 0) + "|" + String(file.size)
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = cachedRoot.appendingPathComponent(hash, isDirectory: true); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let temp = directory.appendingPathComponent(UUID().uuidString)
            do { try await files.disk.download(file.location, to: temp); try Task.checkCancellation(); try FileManager.default.moveItem(at: temp, to: url) } catch { try? FileManager.default.removeItem(at: temp); throw error }
        }
        // glTF and OBJ can reference sibling buffers, materials and textures.
        if file.ext == "gltf", let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] {
            for resource in (object["buffers"] as? [[String: Any]] ?? []) + (object["images"] as? [[String: Any]] ?? []) {
                if let uri = resource["uri"] as? String, !uri.hasPrefix("data:") { try await cacheDependency(uri, parent: file.location.parent, directory: directory) }
            }
        }
        if file.ext == "obj" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("mtllib ") {
                let name = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                try await cacheDependency(name, parent: file.location.parent, directory: directory)
                if let mtl = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) {
                    for line in mtl.components(separatedBy: .newlines) where line.hasPrefix("map_") || line.hasPrefix("bump ") {
                        let parts = line.split(whereSeparator: { $0.isWhitespace }); if let texture = parts.last { try await cacheDependency(String(texture), parent: file.location.parent, directory: directory) }
                    }
                }
            }
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        return url
    }
    private func cacheDependency(_ uri: String, parent: Location, directory: URL) async throws {
        let name = uri.removingPercentEncoding ?? uri
        guard !name.contains("://"), !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw LoaderError.message("Модель ссылается на ресурс вне своей папки: \(name)") }
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        do { try await files.disk.download(parent.child(name), to: temp); try FileManager.default.moveItem(at: temp, to: url) } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
    private func cleanCache() {
        for url in (try? FileManager.default.contentsOfDirectory(at: cachedRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < Date().addingTimeInterval(-7 * 86400) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
