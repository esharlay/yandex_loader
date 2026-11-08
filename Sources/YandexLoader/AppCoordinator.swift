import AppKit
import Quartz

@MainActor final class AppCoordinator: NSResponder, NSApplicationDelegate, NSMenuItemValidation {
    let disk = DiskClient()
    lazy var files = FileService(disk: disk)
    lazy var left = PaneView(id: "left", files: files, location: restored("left") ?? initialLocal())
    lazy var right = PaneView(id: "right", files: files, location: restored("right") ?? .disk("disk:/"))
    lazy var dual = DualPaneView(left: left, right: right)
    let sidebar = SidebarView()
    var window: MainWindow!
    var activePane: PaneView!
    let statusLeft = label(""), statusRight = label("", size: 11, color: .secondaryLabelColor)
    let progress = NSProgressIndicator()
    let cancel = NSButton()
    let transferStatus = TransferStatusControl()
    let transferQueue = TransferQueue()
    lazy var transferWindow = TransferWindowController(queue: transferQueue)
    lazy var updates = UpdateController(isBusy: { [weak self] in self?.transfer != nil })
    var accountInfo: DiskInfo?
    var buffer: [FileEntry] = []
    var bufferMove = false
    var transfer: Task<Void, Never>?
    var statusTimer: Timer?
    var accountTask: Task<Void, Never>?
    var preview: PreviewController!
    var auth: AuthController!
    var toolbarSearch: NSSearchField!
    var operationName = ""

    private func restored(_ id: String) -> Location? { UserDefaults.standard.data(forKey: "location." + id).flatMap { try? JSONDecoder().decode(Location.self, from: $0) } }
    private func initialLocal() -> Location {
        let home = FileManager.default.homeDirectoryForCurrentUser; let work = home.appendingPathComponent("work")
        return .local(FileManager.default.fileExists(atPath: work.path) ? work.path : home.path)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        makeMenus(); makeWindow()
        preview = PreviewController(files: files); auth = AuthController(owner: self)
        for pane in [left, right] {
            pane.onActivate = { [weak self] p in self?.activate(p) }
            pane.onChange = { [weak self] in self?.updateState() }
            pane.onSelectionChange = { [weak self, weak pane] in if let self, let pane, pane === activePane { preview?.followSelection(in: pane) } }
            pane.onViewportChange = { [weak self] in self?.dual.updateControlPosition() }
            pane.onOpen = { [weak self, weak pane] file in if let pane { self?.open(file, in: pane) } }
            pane.onRename = { [weak self, weak pane] in if let pane { self?.activate(pane); self?.rename(nil) } }
            pane.onPreview = { [weak self, weak pane] in if let pane { self?.activate(pane); self?.quickLook(nil) } }
            pane.onTab = { [weak self] in self?.switchPane(nil) }
            pane.onDelete = { [weak self] in self?.deleteItems(nil) }
            pane.onCopy = { [weak self] in self?.copy(nil) }
            pane.onCut = { [weak self] in self?.cut(nil) }
            pane.onNewFolder = { [weak self] in self?.newFolder(nil) }
            pane.onLogin = { [weak self] in self?.connect(nil) }
            pane.onError = { [weak self] error in if case LoaderError.unauthorized = error { self?.expireSession() } }
            pane.onDrop = { [weak self, weak pane] entries, move in if let pane { self?.startTransfer(entries, to: pane.location, move: move) } }
        }
        sidebar.onNavigate = { [weak self] location in guard let self else { return }; if location.isDisk && disk.token == nil { connect(nil) } else { activePane.navigate(location) } }
        sidebar.onAdd = { [weak self] in self?.addFavorite(nil) }
        dual.onTransfer = { [weak self] move in guard let self, let source = transferSource else { return }; startTransfer(source.selected, to: other(source).location, move: move) }
        activate(left); left.reload(); right.reload()
        window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); left.focus(); NSApp.activate(ignoringOtherApps: true)
        updates.onPostpone = { [weak self] in self?.brief("Обновление установится после завершения передачи") }
        updates.start()
        Task { @MainActor in
            let token = await Task.detached(priority: .userInitiated) { TokenStore.read() }.value
            guard disk.token == nil else { return }
            disk.token = token
            if token != nil { if left.location.isDisk { left.reload() }; if right.location.isDisk { right.reload() }; refreshAccount(preferModels: right.location == .disk("disk:/")) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard transfer != nil else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Передача ещё идёт"; alert.informativeText = "Завершить приложение и отменить передачу? Исходные файлы незавершённых элементов сохранятся."; alert.addButton(withTitle: "Продолжить передачу"); alert.addButton(withTitle: "Завершить")
        if alert.runModal() == .alertSecondButtonReturn { transfer?.cancel(); return .terminateNow }; return .terminateCancel
    }
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { auth?.handleCallback($0) } }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { preview?.currentURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = preview; panel.delegate = preview }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func makeWindow() {
        window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Yandex Loader"; window.titlebarAppearsTransparent = true; window.minSize = NSSize(width: 800, height: 460); window.setFrameAutosaveName("YandexLoaderMainWindow"); window.center(); window.nextResponder = self
        let toolbar = NSToolbar(identifier: "MainToolbar"); toolbar.displayMode = .iconOnly; toolbar.delegate = self; window.toolbar = toolbar; window.toolbarStyle = .unified
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.autosaveName = "MainSidebarSplit"; split.addArrangedSubview(sidebar); split.addArrangedSubview(dual); split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true; sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 310).isActive = true
        dual.widthAnchor.constraint(greaterThanOrEqualToConstant: 447).isActive = true
        let separator = NSBox(); separator.boxType = .separator
        progress.isIndeterminate = false; progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true; progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        cancel.image = symbol("xmark.circle.fill"); cancel.isBordered = false; cancel.target = self; cancel.action = #selector(cancelTransfer); cancel.isHidden = true; cancel.toolTip = "Отменить передачу"
        statusLeft.font = .systemFont(ofSize: 11); statusLeft.textColor = .secondaryLabelColor
        statusRight.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        statusRight.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transferContents = NSStackView(views: [statusRight, progress]); transferContents.spacing = 8
        transferStatus.addSubview(transferContents); transferContents.pin(to: transferStatus)
        transferStatus.isEnabled = false; transferStatus.setAccessibilityRole(.button); transferStatus.setAccessibilityLabel("Открыть окно передач")
        transferStatus.onClick = { [weak self] in self?.showTransfers(nil) }
        transferQueue.observe { [weak self] in self?.updateTransferStatus() }
        transferQueue.onCancelAll = { [weak self] in self?.cancelTransfer(nil) }
        let status = NSStackView(views: [statusLeft, spacer, transferStatus, cancel]); status.spacing = 10; status.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10); status.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        for view in [split, separator, status] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor), separator.trailingAnchor.constraint(equalTo: root.trailingAnchor), separator.heightAnchor.constraint(equalToConstant: 1), separator.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor), status.trailingAnchor.constraint(equalTo: root.trailingAnchor), status.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root; root.layoutSubtreeIfNeeded(); split.setPosition(220, ofDividerAt: 0)
    }
    func other(_ pane: PaneView) -> PaneView { pane === left ? right : left }
    var transferSource: PaneView? {
        if activePane != nil && !activePane.selected.isEmpty { return activePane }
        if !left.selected.isEmpty { return left }; if !right.selected.isEmpty { return right }; return nil
    }
    func activate(_ pane: PaneView) { let changed = activePane !== pane; activePane = pane; left.active = pane === left; right.active = pane === right; updateState(); if changed { preview?.followSelection(in: pane) } }
    func updateState() {
        guard activePane != nil else { return }
        dual.update(enabled: transfer == nil && transferSource != nil, source: transferSource)
        sidebar.current = activePane.location
        let count = activePane.selected.count
        statusLeft.stringValue = count > 0 ? "Выбрано объектов: \(count)" : "Объектов: \(activePane.visibleFiles.count)"
        window?.subtitle = activePane.location.name
    }
    func showError(_ error: Error) {
        if error is CancellationError { return }
        if case LoaderError.unauthorized = error { expireSession() }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Не удалось выполнить операцию"; alert.informativeText = errorText(error); alert.addButton(withTitle: "Закрыть")
        if case LoaderError.unauthorized = error { alert.addButton(withTitle: "Войти снова") }
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertSecondButtonReturn { self?.connect(nil) } }
    }
    func expireSession() { disk.token = nil; TokenStore.delete(); accountInfo = nil; sidebar.account = "Войдите снова"; sidebar.hasModels = false; sidebar.rebuild(); statusRight.stringValue = "Нужно подключить Яндекс Диск" }
    func refreshAccount(preferModels: Bool = false) {
        guard disk.token != nil else { return }
        accountTask?.cancel()
        accountTask = Task { @MainActor in
            do {
                let info = try await disk.info(); try Task.checkCancellation(); accountInfo = info
                let login = info.user?.login ?? info.user?.display_name ?? "Яндекс Диск"
                sidebar.account = login; statusRight.stringValue = "\(login) · \(sizeText(info.used_space)) из \(sizeText(info.total_space))"
                sidebar.hasModels = (try? await disk.metadata(.disk("disk:/models")))?.isDirectory == true; sidebar.rebuild()
                if preferModels && sidebar.hasModels { right.navigate(.disk("disk:/models")) }
            } catch is CancellationError { } catch { showError(error) }
        }
    }
    func brief(_ message: String) {
        statusTimer?.invalidate(); statusRight.stringValue = message
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in if let info = self.accountInfo { self.statusRight.stringValue = "\(info.user?.login ?? "Яндекс Диск") · \(sizeText(info.used_space)) из \(sizeText(info.total_space))" } else { self.statusRight.stringValue = "" } }
        }
    }
    func open(_ file: FileEntry, in pane: PaneView) {
        if file.isDirectory { pane.navigate(file.location); return }
        Task { do { let url = try await preview.localURL(for: file); if !NSWorkspace.shared.open(url) { throw LoaderError.message("Для этого типа файла не найдено приложение.") } } catch { showError(error) } }
    }
    @objc func openItems(_ sender: Any?) { activePane.selected.forEach { open($0, in: activePane) } }
    @objc func switchPane(_ sender: Any?) { other(activePane).focus() }
    @objc func back(_ sender: Any?) { activePane.goBack() }
    @objc func forward(_ sender: Any?) { activePane.goForward() }
    @objc func up(_ sender: Any?) { activePane.goUp() }
    @objc func refresh(_ sender: Any?) { left.reload(); right.reload(); refreshAccount() }
    @objc func hidden(_ sender: Any?) { let value = !activePane.showHidden; left.showHidden = value; right.showHidden = value }
    @objc func copy(_ sender: Any?) { buffer = activePane.selected; bufferMove = false; updateCut() }
    @objc func cut(_ sender: Any?) { buffer = activePane.selected; bufferMove = true; updateCut() }
    @objc func paste(_ sender: Any?) { startTransfer(buffer, to: activePane.location, move: bufferMove) }
    @objc func movePaste(_ sender: Any?) { startTransfer(buffer, to: activePane.location, move: true) }
    @objc override func selectAll(_ sender: Any?) { activePane.select(locations: Set(activePane.visibleFiles.map(\.location))) }
    @objc func copyPath(_ sender: Any?) { let paths = activePane.selected.isEmpty ? [activePane.location.path] : activePane.selected.map { $0.location.path }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string); brief("Путь скопирован") }
    func updateCut() { let paths = bufferMove ? Set(buffer.map(\.location)) : []; left.cutLocations = paths; right.cutLocations = paths }
    @objc func quickLook(_ sender: Any?) { preview.toggle(in: activePane) }
    @objc func connect(_ sender: Any?) { auth.show() }
    @objc func disconnect(_ sender: Any?) { transfer?.cancel(); accountTask?.cancel(); TokenStore.delete(); disk.token = nil; accountInfo = nil; sidebar.account = "Не подключён"; sidebar.hasModels = false; sidebar.rebuild(); left.reload(); right.reload(); brief("Вы вышли из Яндекс Диска") }
    @objc func addFavorite(_ sender: Any?) {
        guard !activePane.location.isDisk else { brief("В избранное можно добавить локальную папку"); return }
        var paths = UserDefaults.standard.stringArray(forKey: "favorites") ?? []; if !paths.contains(activePane.location.path) { paths.append(activePane.location.path); UserDefaults.standard.set(paths, forKey: "favorites"); sidebar.rebuild() }
    }
    @objc func goToPath(_ sender: Any?) {
        textSheet(title: "Перейти в папку", value: activePane.location.path, button: "Перейти") { [weak self] value in self?.activePane.navigate(Location.parse(value)) }
    }
    @objc func rename(_ sender: Any?) {
        guard let file = activePane.selected.first, activePane.selected.count == 1 else { return }
        let pane = activePane!
        textSheet(title: "Переименовать", value: file.name, button: "Переименовать", selectExtension: file.isDirectory) { [weak self] name in
            guard let self, name != file.name else { return }
            Task { do { try Listing.validateName(name); let target = file.location.parent.child(name); guard try await !self.files.exists(target) else { throw LoaderError.message("Имя «\(name)» уже занято.") }; try await self.files.rename(file.location, to: target); pane.reload() } catch { self.showError(error) } }
        }
    }
    @objc func newFolder(_ sender: Any?) {
        guard transfer == nil else { return }; let pane = activePane!
        Task { do { var name = "новая папка"; var n = 2; while try await files.exists(pane.location.child(name)) { name = "новая папка (\(n))"; n += 1 }; try await files.mkdir(pane.location.child(name)); pane.reload(); brief("Создана папка «\(name)»") } catch { showError(error) } }
    }
    @objc func deleteItems(_ sender: Any?) {
        let entries = activePane.selected; guard !entries.isEmpty, transfer == nil else { return }
        let alert = NSAlert(); alert.messageText = "Отправить в Корзину?"; alert.informativeText = entries.count == 1 ? entries[0].name : "Выбрано объектов: \(entries.count)"; alert.addButton(withTitle: "В Корзину"); alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                do { for entry in entries { try await self.files.trash(entry.location) }; self.left.reload(); self.right.reload(); self.brief("Отправлено в Корзину") }
                catch { self.left.reload(); self.right.reload(); self.showError(error) }
            }
        }
    }
    func textSheet(title: String, value: String, button: String, selectExtension: Bool = true, completion: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: button); alert.addButton(withTitle: "Отмена")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 390, height: 26); alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { completion(field.stringValue) } }
        alert.window.makeFirstResponder(field)
        let length = !selectExtension && !(value as NSString).pathExtension.isEmpty ? ((value as NSString).deletingPathExtension as NSString).length : (value as NSString).length
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: length))
    }
    func startTransfer(_ entries: [FileEntry], to folder: Location, move: Bool) {
        guard transfer == nil, !entries.isEmpty else { return }
        operationName = move ? "Перенос" : "Копирование"; progress.doubleValue = 0; progress.isHidden = false; cancel.isHidden = false; statusTimer?.invalidate()
        let engine = TransferEngine(files: files, queue: transferQueue)
        engine.onCompleted = { [weak self] location in
            guard let self, move else { return }
            buffer.removeAll { $0.location == location }; updateCut()
        }
        engine.resolve = { [weak self] file, target in guard let self else { return ConflictAnswer(choice: .cancel, applyToAll: false) }; return await conflict(file, target: target) }
        transfer = Task { @MainActor in
            do {
                let report = try await engine.run(entries, to: folder, move: move)
                if move { let done = Set(report.completed); buffer.removeAll { done.contains($0.location) }; updateCut() }
                brief((move ? "Перемещено" : "Скопировано") + ": \(report.completed.count)" + (report.partial.isEmpty ? "" : ", частично: \(report.partial.count)") + (report.cancelled > 0 ? ", отменено файлов: \(report.cancelled)" : "") + (report.skipped > 0 ? ", пропущено: \(report.skipped)" : ""))
            } catch is CancellationError { brief("Передача отменена") } catch { brief("Передача прервана"); showError(error) }
            transfer = nil; progress.isHidden = true; cancel.isHidden = true; left.reload(); right.reload(); updateState()
            updates.installationGate.resumeIfIdle()
        }
        updateState()
    }
    func updateTransferStatus() {
        transferStatus.isEnabled = !transferQueue.records.isEmpty || transferQueue.isPreparing
        transferStatus.toolTip = transferStatus.isEnabled ? "Нажмите, чтобы открыть список передач" : nil
        window?.invalidateCursorRects(for: transferStatus)
        progress.isHidden = !transferQueue.isRunning; cancel.isHidden = !transferQueue.isRunning
        guard transferQueue.isRunning else { progress.stopAnimation(nil); return }
        statusRight.stringValue = transferQueue.summary + (transferQueue.activeName.map { " · " + $0 } ?? "")
        progress.isIndeterminate = transferQueue.isIndeterminate
        if transferQueue.isIndeterminate { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil); progress.doubleValue = transferQueue.fraction }
    }
    @objc func showTransfers(_ sender: Any?) { transferWindow.showWindow(nil); transferWindow.window?.makeKeyAndOrderFront(nil) }
    func conflict(_ file: FileEntry, target: Location) async -> ConflictAnswer {
        await withCheckedContinuation { continuation in
            let alert = NSAlert(); alert.messageText = "«\(file.name)» уже существует"; alert.informativeText = "Папка назначения: \(target.parent.path)\nПри замене существующий объект отправится в Корзину."; ["Заменить", "Пропустить", "Оставить оба", "Отменить передачу"].forEach { alert.addButton(withTitle: $0) }; alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Применить ко всем"
            alert.beginSheetModal(for: window) { response in let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue; let choices: [ConflictChoice] = [.replace, .skip, .keepBoth, .cancel]; continuation.resume(returning: ConflictAnswer(choice: choices.indices.contains(index) ? choices[index] : .cancel, applyToAll: alert.suppressionButton?.state == .on)) }
        }
    }
    @objc func cancelTransfer(_ sender: Any?) { transfer?.cancel() }
    @objc func showHelp(_ sender: Any?) {
        let a = NSAlert(); a.messageText = "Клавиатура Yandex Loader"; a.informativeText = "Tab — другая панель\n⌘O / ⌘↓ — открыть\nEnter — переименовать\nПробел — быстрый просмотр\n⌘↑ — вверх · ⌘[ / ⌘] — назад / вперёд\n⌘C / ⌘X / ⌘V — копировать / вырезать / вставить\n⌥⌘V — переместить из буфера\n⌘⇧N — новая папка · ⌘⌫ — в Корзину\n⌘A — выделить всё · ⌥⌘C — скопировать путь\n⌘⇧G — перейти по пути · ⌘R — обновить\n⌘⇧. — скрытые файлы\nПеретаскивание — копия, Option — перенос\nБуквы — перейти к имени файла"; a.beginSheetModal(for: window)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let a = menuItem.action
        if window?.firstResponder is NSTextView { return a == #selector(connect(_:)) || a == #selector(showHelp(_:)) }
        if [#selector(copy(_:)), #selector(cut(_:)), #selector(openItems(_:)), #selector(deleteItems(_:)), #selector(quickLook(_:))].contains(a) { return activePane != nil && !activePane.selected.isEmpty && (transfer == nil || a == #selector(quickLook(_:))) }
        if a == #selector(rename(_:)) { return activePane != nil && activePane.selected.count == 1 && transfer == nil }
        if a == #selector(paste(_:)) || a == #selector(movePaste(_:)) { return !buffer.isEmpty && transfer == nil }
        if a == #selector(disconnect(_:)) { return disk.token != nil }
        if a == #selector(hidden(_:)) { menuItem.state = activePane?.showHidden == true ? .on : .off }
        return true
    }
    private func makeMenus() {
        let root = NSMenu(); NSApp.mainMenu = root
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; root.addItem(item); let m = NSMenu(title: title); item.submenu = m; return m }
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) { let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = modifiers; i.target = target; m.addItem(i) }
        let app = menu("Yandex Loader"); add(app, "О программе Yandex Loader", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp); app.addItem(updates.makeMenuItem()); app.addItem(.separator()); add(app, "Настройки…", #selector(connect(_:)), ","); app.addItem(.separator()); add(app, "Скрыть Yandex Loader", #selector(NSApplication.hide(_:)), "h", target: NSApp); add(app, "Завершить Yandex Loader", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("Файл"); add(file, "Подключить Яндекс Диск…", #selector(connect(_:))); add(file, "Выйти из Яндекс Диска", #selector(disconnect(_:))); file.addItem(.separator()); add(file, "Открыть", #selector(openItems(_:)), "o"); add(file, "Открыть выделение", #selector(openItems(_:)), "\u{f701}"); add(file, "Новая папка", #selector(newFolder(_:)), "N", [.command, .shift]); add(file, "Переименовать…", #selector(rename(_:))); add(file, "В Корзину", #selector(deleteItems(_:)), "\u{8}"); add(file, "Закрыть окно", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Правка"); add(edit, "Копировать", #selector(copy(_:)), "c"); add(edit, "Вырезать", #selector(cut(_:)), "x"); add(edit, "Вставить", #selector(paste(_:)), "v"); add(edit, "Переместить из буфера", #selector(movePaste(_:)), "v", [.command, .option]); add(edit, "Выделить всё", #selector(selectAll(_:)), "a"); add(edit, "Скопировать путь", #selector(copyPath(_:)), "c", [.command, .option])
        let view = menu("Вид"); add(view, "Быстрый просмотр", #selector(quickLook(_:))); add(view, "Передачи", #selector(showTransfers(_:))); add(view, "Обновить обе панели", #selector(refresh(_:)), "r"); add(view, "Показывать скрытые файлы", #selector(hidden(_:)), ".", [.command, .shift]); add(view, "Добавить в боковую панель", #selector(addFavorite(_:)))
        let go = menu("Переход"); add(go, "Назад", #selector(back(_:)), "["); add(go, "Вперёд", #selector(forward(_:)), "]"); add(go, "Вверх", #selector(up(_:)), "\u{f700}"); add(go, "Перейти в папку…", #selector(goToPath(_:)), "G", [.command, .shift]); add(go, "Другая панель", #selector(switchPane(_:)))
        let help = menu("Справка"); add(help, "Сочетания клавиш", #selector(showHelp(_:))); NSApp.helpMenu = help
    }
}

extension AppCoordinator: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("new"), .init("preview"), .init("hidden"), .init("trash"), .init("refresh"), .init("settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let items: [String: (String, String, Selector)] = ["new": ("Новая папка", "folder.badge.plus", #selector(newFolder(_:))), "preview": ("Быстрый просмотр", "eye", #selector(quickLook(_:))), "hidden": ("Скрытые файлы", "eye.slash", #selector(hidden(_:))), "trash": ("В Корзину", "trash", #selector(deleteItems(_:))), "refresh": ("Обновить", "arrow.clockwise", #selector(refresh(_:))), "settings": ("Настройки и вход", "gearshape", #selector(connect(_:)))]
        guard let value = items[identifier.rawValue] else { return nil }; let i = NSToolbarItem(itemIdentifier: identifier); i.label = value.0; i.toolTip = value.0; i.image = symbol(value.1); i.target = self; i.action = value.2; return i
    }
}
