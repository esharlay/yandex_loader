import AppKit
import UniformTypeIdentifiers

final class PaneView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let id: String
    let files: FileService
    private(set) var location: Location
    private(set) var entries: [FileEntry] = []
    private var rows: [DisplayRow] = []
    private var history: [Location] = [], forwardHistory: [Location] = []
    private var loading: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var watchWork: DispatchWorkItem?
    var active = false { didSet { stripe.layer?.backgroundColor = (active ? NSColor.controlAccentColor : .clear).cgColor; updateSelection() } }
    var showHidden = false { didSet { rebuild() } }
    var cutLocations: Set<Location> = [] { didSet { table.reloadData(); updateSelection() } }
    var onActivate: ((PaneView) -> Void)?
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onViewportChange: (() -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    var onRename: (() -> Void)?
    var onPreview: (() -> Void)?
    var onTab: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onLogin: (() -> Void)?
    var onDrop: (([FileEntry], Bool) -> Void)?
    var onError: ((Error) -> Void)?
    let table = FileTable()
    let search = NSSearchField()
    let stripe = NSView()
    let crumbs = NSStackView()
    let back = NSButton(), forward = NSButton(), up = NSButton()
    let sort = NSPopUpButton()
    let overlay = NSStackView()
    let message = label("", size: 13, color: .secondaryLabelColor)
    let retry = NSButton(title: "Повторить", target: nil, action: nil)
    let privacy = NSButton(title: "Настройки конфиденциальности", target: nil, action: nil)
    private var mode: SortMode = .groups
    private var ascending = false
    private var viewportObserver: NSObjectProtocol?

    init(id: String, files: FileService, location: Location) {
        self.id = id; self.files = files; self.location = location
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }
    var selected: [FileEntry] { table.selectedRowIndexes.compactMap { index in guard rows.indices.contains(index), case .file(let f) = rows[index] else { return nil }; return f } }
    var visibleFiles: [FileEntry] { rows.compactMap { if case .file(let f) = $0 { return f }; return nil } }
    func activate() { onActivate?(self) }
    func focus() { window?.makeFirstResponder(table); activate() }

    private func setup() {
        stripe.wantsLayer = true
        let navigation = NSStackView(); navigation.spacing = 3; navigation.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        for (b, icon, action, tip) in [(back, "chevron.left", #selector(goBack), "Назад (⌘[)"), (forward, "chevron.right", #selector(goForward), "Вперёд (⌘])"), (up, "chevron.up", #selector(goUp), "Вверх (⌘↑)")] {
            b.image = symbol(icon); b.isBordered = false; b.target = self; b.action = action; b.toolTip = tip; b.widthAnchor.constraint(equalToConstant: 21).isActive = true; navigation.addArrangedSubview(b)
        }
        crumbs.spacing = 2; crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); navigation.addArrangedSubview(crumbs)
        let filler = NSView(); navigation.addArrangedSubview(filler); filler.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.placeholderString = "Фильтр по имени"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 24).isActive = true
        sort.addItems(withTitles: SortMode.allCases.map(\.title)); sort.target = self; sort.action = #selector(sortChanged); sort.font = .systemFont(ofSize: 11); sort.widthAnchor.constraint(equalToConstant: 139).isActive = true
        let filter = NSStackView(views: [search, sort]); filter.spacing = 7; filter.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 7, right: 10)
        filter.distribution = .fill; search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        table.pane = self; table.dataSource = self; table.delegate = self; table.headerView = NSTableHeaderView(); table.allowsMultipleSelection = true; table.allowsEmptySelection = true; table.rowHeight = 28; table.intercellSpacing = NSSize(width: 0, height: 0); table.backgroundColor = .white; table.selectionHighlightStyle = .regular; table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (key, title, width) in [("name", "Имя", CGFloat(240)), ("date", "Дата", CGFloat(112)), ("size", "Размер", CGFloat(78))] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); c.title = title; c.width = width; c.minWidth = key == "name" ? 80 : 48; c.resizingMask = key == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.headerCell.font = .systemFont(ofSize: 11); table.addTableColumn(c)
        }
        table.target = self; table.doubleAction = #selector(doubleClick)
        table.registerForDraggedTypes([DragPayload.type]); table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = true; scroll.backgroundColor = .white
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.onViewportChange?() }
        let content = NSView(); content.addSubview(scroll); scroll.pin(to: content)
        overlay.orientation = .vertical; overlay.spacing = 12; message.alignment = .center; message.maximumNumberOfLines = 5; message.lineBreakMode = .byWordWrapping
        retry.target = self; retry.action = #selector(reloadAction); retry.bezelStyle = .rounded
        privacy.target = self; privacy.action = #selector(openPrivacy); privacy.bezelStyle = .rounded
        overlay.addArrangedSubview(message); overlay.addArrangedSubview(retry); overlay.addArrangedSubview(privacy); content.addSubview(overlay); overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor), overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor), overlay.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32)])
        let stack = NSStackView(views: [stripe, navigation, filter, content]); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .width; addSubview(stack); stack.pin(to: self)
        for view in [stripe, navigation, filter, content] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        stripe.heightAnchor.constraint(equalToConstant: 2).isActive = true; navigation.heightAnchor.constraint(equalToConstant: 34).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        updateCrumbs()
    }
    func navigate(_ target: Location, record: Bool = true) {
        activate()
        if target != location && record { history.append(location); forwardHistory.removeAll() }
        if location != target { entries = []; rows = []; table.reloadData() }
        location = target; table.deselectAll(nil); search.stringValue = ""
        if let data = try? JSONEncoder().encode(target) { UserDefaults.standard.set(data, forKey: "location." + id) }
        updateCrumbs(); reload(); onChange?()
    }
    @objc func goBack() { if let target = history.popLast() { forwardHistory.append(location); navigate(target, record: false) } }
    @objc func goForward() { if let target = forwardHistory.popLast() { history.append(location); navigate(target, record: false) } }
    @objc func goUp() { navigate(location.parent) }
    private func updateCrumbs() {
        crumbs.arrangedSubviews.forEach { crumbs.removeArrangedSubview($0); $0.removeFromSuperview() }
        let all = location.breadcrumbs
        // A path menu keeps every ancestor reachable even in a narrow panel.
        if all.count > 3 {
            let popup = NSPopUpButton(); popup.pullsDown = true; popup.isBordered = false; popup.addItem(withTitle: "…")
            for (name, target) in all.dropLast(2) { let item = NSMenuItem(title: name, action: #selector(crumbMenu(_:)), keyEquivalent: ""); item.target = self; item.representedObject = target; popup.menu?.addItem(item) }
            crumbs.addArrangedSubview(popup)
        }
        for (index, value) in all.suffix(all.count > 3 ? 2 : 3).enumerated() {
            if index > 0 { crumbs.addArrangedSubview(label("›", color: .tertiaryLabelColor)) }
            let b = ActionButton(value.0) { [weak self] in self?.navigate(value.1) }; b.isBordered = false; b.font = .systemFont(ofSize: 12); b.toolTip = value.1.path; b.lineBreakMode = .byTruncatingMiddle; b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); crumbs.addArrangedSubview(b)
        }
        back.isEnabled = !history.isEmpty; forward.isEnabled = !forwardHistory.isEmpty; up.isEnabled = location != location.parent
    }
    @objc private func crumbMenu(_ sender: NSMenuItem) { if let l = sender.representedObject as? Location { navigate(l) } }
    @objc private func reloadAction() { if location.isDisk && files.disk.token == nil { onLogin?() } else { reload() } }
    @objc private func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) }
    func reload() {
        loading?.cancel(); stopWatcher(); let target = location
        if target.isDisk && files.disk.token == nil { entries = []; rebuild(); showMessage("Подключите Яндекс Диск,\nчтобы увидеть свои файлы", retryTitle: "Войти через Яндекс"); return }
        if entries.isEmpty { showMessage("Читаем папку…") }
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await files.list(target); try Task.checkCancellation(); guard location == target else { return }
                entries = result; rebuild(); startWatcher(); onChange?()
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, location == target else { return }
                entries = []; rows = []; table.reloadData()
                let denied = (error as NSError).code == NSFileReadNoPermissionError || (error as NSError).code == Int(EACCES)
                showMessage(errorText(error), retryTitle: "Повторить", privacy: denied)
                if case LoaderError.unauthorized = error { onError?(error) }
            }
        }
    }
    func select(locations: Set<Location>) {
        let indexes = rows.indices.filter { if case .file(let f) = rows[$0] { return locations.contains(f.location) }; return false }
        table.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
    }
    func applyRename(_ original: Location, to file: FileEntry) {
        guard location == file.location.parent else { return }
        loading?.cancel(); stopWatcher()
        let chosen = Set(selected.map { $0.location == original ? file.location : $0.location })
        let selectRenamed = chosen.isEmpty || chosen.contains(file.location)
        entries.removeAll { $0.location == original || $0.location == file.location }
        entries.append(file)
        rebuild()
        select(locations: selectRenamed ? [file.location] : chosen)
        startWatcher()
    }
    private func rebuild() {
        let selection = Set(selected.map(\.location))
        rows = Listing.rows(entries, mode: mode, ascending: ascending, filter: search.stringValue, hidden: showHidden)
        table.reloadData(); select(locations: selection); updateSelection()
        overlay.isHidden = !visibleFiles.isEmpty
        if visibleFiles.isEmpty { showMessage(search.stringValue.isEmpty ? "В этой папке пока нет файлов" : "Ничего не найдено\nИзмените фильтр по имени") }
        onChange?()
    }
    private func showMessage(_ text: String, retryTitle: String? = nil, privacy showPrivacy: Bool = false) {
        message.stringValue = text; retry.title = retryTitle ?? "Повторить"; retry.isHidden = retryTitle == nil; privacy.isHidden = !showPrivacy; overlay.isHidden = false
    }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    @objc private func sortChanged() { mode = SortMode(rawValue: sort.indexOfSelectedItem) ?? .groups; ascending = mode == .name; rebuild() }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let next: SortMode = tableColumn.identifier.rawValue == "name" ? .name : tableColumn.identifier.rawValue == "size" ? .size : .date
        ascending = mode == next ? !ascending : next == .name; mode = next; sort.selectItem(at: next.rawValue); rebuild()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 36 }; return 28 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .group = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .file = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { if case .file(let f) = rows[row] { return f.name }; return nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let v = FileRow(); v.active = active; return v }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .group(let title) = rows[row] { let t = label(title, size: 11, color: .secondaryLabelColor, bold: true); return t }
        guard case .file(let file) = rows[row], let column = tableColumn else { return nil }
        let key = column.identifier.rawValue
        let cell = NSTableCellView(); cell.identifier = column.identifier
        let text = label(key == "name" ? file.name : key == "date" ? dateText(file.modified) : file.isDirectory ? "—" : sizeText(file.size), size: 12, color: key == "name" ? .labelColor : .secondaryLabelColor)
        cell.textField = text; cell.addSubview(text); text.translatesAutoresizingMaskIntoConstraints = false
        if key == "name" {
            let icon = NSImageView(); icon.image = file.location.isDisk ? (file.isDirectory ? NSImage(named: NSImage.folderName) : NSWorkspace.shared.icon(for: UTType(filenameExtension: file.ext) ?? .data)) : NSWorkspace.shared.icon(forFile: file.location.path)
            cell.addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)])
        } else { text.alignment = .right; text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true }
        NSLayoutConstraint.activate([text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.alphaValue = cutLocations.contains(file.location) ? 0.45 : 1
        if table.isRowSelected(row) && active { text.textColor = .white }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection(); onChange?(); onSelectionChange?() }
    func updateSelection() {
        table.enumerateAvailableRowViews { view, _ in if let r = view as? FileRow { r.active = self.active; r.recolor(); r.needsDisplay = true } }
    }
    /// Row centres and viewport are converted together, so the anchor follows scrolling and resizing.
    func transferAnchor(in view: NSView) -> (centerY: CGFloat, viewport: NSRect)? {
        guard let clip = table.enclosingScrollView?.contentView else { return nil }
        let viewport = clip.convert(clip.bounds, to: view)
        guard let first = table.selectedRowIndexes.first, let last = table.selectedRowIndexes.last else { return (viewport.midY, viewport) }
        let center = (table.rect(ofRow: first).midY + table.rect(ofRow: last).midY) / 2
        return (table.convert(NSPoint(x: 0, y: center), to: view).y, viewport)
    }
    @objc private func doubleClick() { guard table.clickedRow >= 0, rows.indices.contains(table.clickedRow), case .file(let file) = rows[table.clickedRow] else { return }; activate(); onOpen?(file) }
    @objc private func openSelection() { activate(); selected.forEach { onOpen?($0) } }
    @objc private func renameSelection() { activate(); onRename?() }
    @objc private func deleteSelection() { activate(); onDelete?() }
    @objc private func copySelection() { activate(); onCopy?() }
    @objc private func cutSelection() { activate(); onCut?() }
    @objc private func newFolder() { activate(); onNewFolder?() }
    @objc private func previewSelection() { activate(); onPreview?() }
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Открыть", #selector(openSelection)), ("Быстрый просмотр", #selector(previewSelection)), ("Переименовать", #selector(renameSelection)), ("Копировать", #selector(copySelection)), ("Вырезать", #selector(cutSelection)), ("В Корзину", #selector(deleteSelection)), ("Новая папка", #selector(newFolder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .file = rows[row] else { return nil }
        let p = NSPasteboardItem(); p.setString(UUID().uuidString, forType: DragPayload.type); return p
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        activate(); DragPayload.source = self; DragPayload.entries = rowIndexes.compactMap { if case .file(let f) = rows[$0] { return f }; return nil }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard DragPayload.source !== self, !DragPayload.entries.isEmpty else { return [] }
        table.setDropRow(-1, dropOperation: .on); return NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool { onDrop?(DragPayload.entries, NSEvent.modifierFlags.contains(.option)); DragPayload.entries = []; return true }
    private func startWatcher() {
        guard !location.isDisk else { return }
        watchFD = open(location.path, O_EVTONLY); guard watchFD >= 0 else { return }
        let fd = watchFD
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }; watchWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.reload() }; watchWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        source.setCancelHandler { close(fd) }; watcher = source; source.resume()
    }
    private func stopWatcher() { watchWork?.cancel(); watcher?.cancel(); watcher = nil; watchFD = -1 }
    deinit { loading?.cancel(); watcher?.cancel(); if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
}
