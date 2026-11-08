import AppKit

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SidebarButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    var selectedPlace = false { didSet { needsDisplay = true } }
    var remove: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        if selectedPlace { NSColor(white: 0.83, alpha: 1).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill() }
        super.draw(dirtyRect)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard remove != nil else { return nil }; let m = NSMenu(); let i = NSMenuItem(title: "Убрать из боковой панели", action: #selector(removePlace), keyEquivalent: ""); i.target = self; m.addItem(i); return m
    }
    @objc private func removePlace() { remove?() }
}

final class SidebarView: NSView {
    var onNavigate: ((Location) -> Void)?
    var onAdd: (() -> Void)?
    var current: Location? { didSet { updateHighlight() } }
    var account = "Не подключён"
    var hasModels = false
    let scroll = NSScrollView()
    let document = FlippedView()
    let addButton = NSButton()
    let separator = NSBox()
    var layoutRows: [(NSView, CGFloat)] = []
    var places: [(SidebarButton, Location)] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.925, alpha: 1).cgColor
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; addSubview(scroll)
        addButton.title = "В боковую панель"; addButton.image = symbol("plus"); addButton.imagePosition = .imageLeading
        addButton.isBordered = false; addButton.alignment = .left; addButton.font = .systemFont(ofSize: 12)
        addButton.target = self; addButton.action = #selector(addCurrent); addSubview(addButton)
        separator.boxType = .separator; addSubview(separator)
        rebuild()
        NotificationCenter.default.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }; layoutRows = []; places = []
        func section(_ title: String) {
            if !layoutRows.isEmpty { layoutRows.append((NSView(), 12)) }
            let t = label(title, size: 11, color: .secondaryLabelColor, bold: true)
            document.addSubview(t); layoutRows.append((t, 22))
        }
        section("Облако")
        addPlace("Яндекс Диск", .disk("disk:/"), icon: "cloud.fill", subtitle: account)
        if hasModels { addPlace("models", .disk("disk:/models"), icon: "cube.box.fill") }
        section("Избранное")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (name, path, icon) in [("Дом", "", "house.fill"), ("Рабочий стол", "Desktop", "desktopcomputer"), ("Документы", "Documents", "doc.fill"), ("Загрузки", "Downloads", "arrow.down.circle.fill"), ("Изображения", "Pictures", "photo.fill"), ("Фильмы", "Movies", "film.fill"), ("Музыка", "Music", "music.note"), ("work", "work", "folder.fill")] {
            let l = Location.local(path.isEmpty ? home : (home as NSString).appendingPathComponent(path))
            if FileManager.default.fileExists(atPath: l.path) { addPlace(name, l, icon: icon) }
        }
        for path in UserDefaults.standard.stringArray(forKey: "favorites") ?? [] {
            let l = Location.local(path); addPlace(l.name, l, icon: "folder.fill", removable: true)
        }
        section("Места")
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsBrowsableKey]); guard values?.volumeIsBrowsable != false else { continue }
            addPlace(values?.volumeLocalizedName ?? url.lastPathComponent, .local(url.path), icon: "externaldrive.fill")
        }
        updateHighlight(); needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 35, width: bounds.width, height: max(0, bounds.height - 35))
        separator.frame = NSRect(x: 0, y: 34, width: bounds.width, height: 1)
        addButton.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20), height: 25)
        let width = scroll.contentSize.width
        var y: CGFloat = 10
        for (view, height) in layoutRows {
            if view.superview === document { view.frame = NSRect(x: view is NSTextField ? 12 : 6, y: y, width: max(0, width - (view is NSTextField ? 24 : 12)), height: height) }
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y + 10)
    }
    @objc private func addCurrent() { onAdd?() }
    private func addPlace(_ title: String, _ location: Location, icon: String, subtitle: String? = nil, removable: Bool = false) {
        let b = SidebarButton(); b.isBordered = false; b.title = ""
        let image = NSImageView(); image.image = location.isDisk ? symbol(icon) : NSWorkspace.shared.icon(forFile: location.path); image.contentTintColor = location.isDisk ? .systemRed : nil
        let titleLabel = label(title, size: 12); let texts = NSStackView(views: [titleLabel]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 1
        if let subtitle { texts.addArrangedSubview(label(subtitle, size: 11, color: .secondaryLabelColor)) }
        image.translatesAutoresizingMaskIntoConstraints = false; texts.translatesAutoresizingMaskIntoConstraints = false; b.addSubview(image); b.addSubview(texts)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 8), image.centerYAnchor.constraint(equalTo: b.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), texts.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), texts.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -8), texts.centerYAnchor.constraint(equalTo: b.centerYAnchor)])
        b.target = self; b.action = #selector(clicked(_:)); b.toolTip = location.path; b.setAccessibilityLabel(title); places.append((b, location)); document.addSubview(b); layoutRows.append((b, subtitle == nil ? 27 : 42))
        if removable { b.remove = { [weak self] in let paths = (UserDefaults.standard.stringArray(forKey: "favorites") ?? []).filter { $0 != location.path }; UserDefaults.standard.set(paths, forKey: "favorites"); self?.rebuild() } }
    }
    @objc private func clicked(_ sender: NSButton) { if let item = places.first(where: { $0.0 === sender }) { onNavigate?(item.1) } }
    private func updateHighlight() { for (b, l) in places { b.selectedPlace = l == current } }
}

final class DividerGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.x
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }; let x = e.locationInWindow.x; onDrag?(x - last); last = x
        }
    }
}

final class DualPaneView: NSView {
    let left: PaneView, right: PaneView
    let band = NSView(), leftGrip = DividerGrip(), rightGrip = DividerGrip()
    let transferControls = NSView()
    let copyButton = NSButton(), moveButton = NSButton()
    private weak var sourcePane: PaneView?
    var fraction: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "paneFraction"))
    var onTransfer: ((Bool) -> Void)?
    init(left: PaneView, right: PaneView) {
        self.left = left; self.right = right; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor
        if fraction < 0.1 || fraction > 0.9 { fraction = 0.5 }
        band.wantsLayer = true; band.layer?.backgroundColor = NSColor.separatorColor.cgColor
        for view in [left, right, band, leftGrip, rightGrip] { addSubview(view) }
        transferControls.wantsLayer = true
        transferControls.layer?.backgroundColor = NSColor.white.cgColor
        transferControls.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        transferControls.layer?.borderWidth = 0.5
        transferControls.layer?.cornerRadius = 7
        transferControls.shadow = NSShadow()
        transferControls.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.12)
        transferControls.shadow?.shadowBlurRadius = 3
        transferControls.shadow?.shadowOffset = NSSize(width: 0, height: -1)
        addSubview(transferControls)
        for (b, title, action) in [(copyButton, "Копировать", #selector(copyNow)), (moveButton, "Переместить", #selector(moveNow))] {
            b.title = ""; b.imagePosition = .imageOnly; b.bezelStyle = .regularSquare; b.controlSize = .small; b.isBordered = false
            b.imageScaling = .scaleNone; b.target = self; b.action = action; b.setAccessibilityLabel(title)
            transferControls.addSubview(b)
        }
        copyButton.frame = NSRect(x: 1, y: 27, width: 24, height: 24)
        moveButton.frame = NSRect(x: 1, y: 1, width: 24, height: 24)
        for grip in [leftGrip, rightGrip] { grip.onDrag = { [weak self] delta in guard let self else { return }; fraction = max(220 / max(1, bounds.width - 7), min(1 - 220 / max(1, bounds.width - 7), fraction + delta / max(1, bounds.width - 7))); UserDefaults.standard.set(Double(fraction), forKey: "paneFraction"); needsLayout = true } }
        update(enabled: false, source: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); let available = max(440, bounds.width - 7); let width = max(220, min(available - 220, available * fraction))
        left.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height); band.frame = NSRect(x: width + 3, y: 0, width: 1, height: bounds.height); right.frame = NSRect(x: width + 7, y: 0, width: max(220, bounds.width - width - 7), height: bounds.height)
        leftGrip.frame = NSRect(x: width, y: 0, width: 4, height: bounds.height); rightGrip.frame = NSRect(x: width + 4, y: 0, width: 3, height: bounds.height)
        left.layoutSubtreeIfNeeded(); right.layoutSubtreeIfNeeded()
        updateControlPosition()
    }
    func update(enabled: Bool, source: PaneView?) {
        sourcePane = source
        let toRight = source !== right
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        copyButton.image = symbol("doc.on.doc", "Копировать " + (toRight ? "вправо" : "влево"))?.withSymbolConfiguration(configuration)
        moveButton.image = symbol(toRight ? "arrow.right" : "arrow.left", "Переместить " + (toRight ? "вправо" : "влево"))?.withSymbolConfiguration(configuration)
        moveButton.toolTip = "Переместить выделение " + (toRight ? "в правую панель" : "в левую панель"); copyButton.toolTip = "Скопировать выделение " + (toRight ? "в правую панель" : "в левую панель")
        for b in [copyButton, moveButton] { b.isEnabled = enabled; b.contentTintColor = enabled ? .controlAccentColor : .disabledControlTextColor }
        updateControlPosition()
    }
    func updateControlPosition() {
        let anchor = (sourcePane ?? left).transferAnchor(in: self)
        let viewport = anchor?.viewport ?? bounds
        let margin: CGFloat = 30
        // Keep the controls reachable when the selection is scrolled beyond the visible rows.
        let center = max(viewport.minY + margin, min(viewport.maxY - margin, anchor?.centerY ?? viewport.midY))
        transferControls.frame = NSRect(x: band.frame.midX - 13, y: center - 26, width: 26, height: 52)
    }
    @objc private func copyNow() { onTransfer?(false) }
    @objc private func moveNow() { onTransfer?(true) }
}

final class MainWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() { onClose?(); super.close() }
}
