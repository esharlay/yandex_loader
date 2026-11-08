import AppKit
import UniformTypeIdentifiers

final class TransferStatusControl: NSControl {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return isEnabled ? self : super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; onClick?(); return true }
}

@MainActor final class TransferCell: NSTableCellView {
    let fileIcon = NSImageView()
    let nameLabel = label("", size: 12)
    let detailLabel = label("", size: 11, color: .secondaryLabelColor)
    let bar = NSProgressIndicator()
    let percent = label("", size: 10, color: .secondaryLabelColor)
    let cancelButton = NSButton()
    let resultIcon = NSImageView()
    var onCancel: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [fileIcon, nameLabel, detailLabel, bar, percent, cancelButton, resultIcon] { addSubview(view) }
        nameLabel.lineBreakMode = .byTruncatingMiddle; detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar; bar.controlSize = .small; bar.minValue = 0; bar.maxValue = 1
        percent.alignment = .right
        cancelButton.image = symbol("xmark", "Отменить файл"); cancelButton.isBordered = false
        cancelButton.imageScaling = .scaleProportionallyDown; cancelButton.target = self; cancelButton.action = #selector(cancelItem)
        cancelButton.contentTintColor = .secondaryLabelColor; cancelButton.toolTip = "Отменить только этот файл"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        fileIcon.frame = NSRect(x: 14, y: 18, width: 25, height: 30)
        let textWidth = max(80, bounds.width - 240)
        nameLabel.frame = NSRect(x: 52, y: 35, width: textWidth, height: 17)
        detailLabel.frame = NSRect(x: 52, y: 16, width: textWidth, height: 15)
        bar.frame = NSRect(x: bounds.width - 174, y: 36, width: 124, height: 7)
        percent.frame = NSRect(x: bounds.width - 174, y: 15, width: 124, height: 15)
        cancelButton.frame = NSRect(x: bounds.width - 34, y: 23, width: 22, height: 22)
        resultIcon.frame = NSRect(x: bounds.width - 31, y: 26, width: 16, height: 16)
    }
    func update(_ record: TransferRecord, cancel: @escaping () -> Void) {
        onCancel = cancel
        nameLabel.stringValue = record.displayName; nameLabel.toolTip = record.entry.location.path
        detailLabel.stringValue = record.detail; detailLabel.toolTip = record.note.isEmpty ? record.detail : record.note
        fileIcon.image = record.entry.isDirectory ? NSImage(named: NSImage.folderName) : NSWorkspace.shared.icon(for: UTType(filenameExtension: record.entry.ext) ?? .data)
        let indefinite = record.phase == .server || record.phase == .transferring && record.total <= 0
        bar.isIndeterminate = indefinite
        if indefinite { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = record.fraction }
        percent.stringValue = record.phase == .transferring && !indefinite ? "\(Int(record.fraction * 100))%" : record.phase.title
        cancelButton.isHidden = !record.phase.canCancel && record.phase != .cancelling
        cancelButton.isEnabled = record.phase.canCancel
        resultIcon.isHidden = !record.phase.isTerminal
        resultIcon.image = symbol(record.phase == .completed ? "checkmark.circle.fill" : record.phase == .failed ? "exclamationmark.circle.fill" : "minus.circle")
        resultIcon.contentTintColor = record.phase == .completed ? .systemGreen : record.phase == .failed ? .systemRed : .tertiaryLabelColor
        nameLabel.textColor = record.phase == .cancelled || record.phase == .skipped ? .secondaryLabelColor : .labelColor
        if record.phase == .server { percent.toolTip = "Яндекс Диск выполняет серверную операцию. Отменить её после запуска нельзя." }
        else { percent.toolTip = nil }
    }
    @objc private func cancelItem() { onCancel?() }
}

@MainActor final class TransferWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let queue: TransferQueue
    let table = NSTableView()
    let heading = label("Передачи", size: 17, bold: true)
    let destination = label("", size: 11, color: .secondaryLabelColor)
    let totalBar = NSProgressIndicator()
    let empty = label("Передач пока нет", size: 13, color: .secondaryLabelColor)
    let cancelAllButton = NSButton()
    private var previousCount = -1

    init(queue: TransferQueue) {
        self.queue = queue
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Передачи"; window.minSize = NSSize(width: 510, height: 260); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.setFrameAutosaveName("TransferQueueWindow")
        let hide = button("Свернуть", target: self, action: #selector(hideWindow)); hide.bezelStyle = .rounded
        let headerText = NSStackView(views: [heading, destination]); headerText.orientation = .vertical; headerText.alignment = .leading; headerText.spacing = 4
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerText, spacer, hide]); header.spacing = 12; header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        headerText.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -140).isActive = true
        destination.widthAnchor.constraint(lessThanOrEqualTo: headerText.widthAnchor).isActive = true
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        totalBar.style = .bar; totalBar.minValue = 0; totalBar.maxValue = 1; totalBar.controlSize = .small
        table.dataSource = self; table.delegate = self; table.style = .fullWidth; table.headerView = nil; table.rowHeight = 66; table.intercellSpacing = .zero; table.backgroundColor = .white; table.selectionHighlightStyle = .none; table.focusRingType = .none
        let column = NSTableColumn(identifier: .init("transfer")); column.width = 620; column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.backgroundColor = .white
        let content = NSView(); content.addSubview(scroll); scroll.pin(to: content)
        content.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        cancelAllButton.title = "Отменить все"; cancelAllButton.bezelStyle = .rounded; cancelAllButton.target = self; cancelAllButton.action = #selector(cancelAll)
        let hint = label("Крестик отменяет один файл. Остальные продолжат передачу.", size: 11, color: .secondaryLabelColor)
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [hint, footerSpacer, cancelAllButton]); footer.spacing = 10; footer.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        for view in [header, totalBar, content, footer] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            totalBar.topAnchor.constraint(equalTo: header.bottomAnchor), totalBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), totalBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), totalBar.heightAnchor.constraint(equalToConstant: 4),
            content.topAnchor.constraint(equalTo: totalBar.bottomAnchor, constant: 4), content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root; window.center()
        queue.observe { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update() {
        heading.stringValue = queue.summary
        destination.stringValue = queue.destination.map { "В папку: " + $0.path } ?? ""
        destination.toolTip = queue.destination?.path
        totalBar.isIndeterminate = queue.isIndeterminate
        if queue.isIndeterminate { totalBar.startAnimation(nil) } else { totalBar.stopAnimation(nil); totalBar.doubleValue = queue.fraction }
        empty.isHidden = !queue.records.isEmpty
        empty.stringValue = queue.isPreparing ? "Собираем список файлов…" : "Передач пока нет"
        cancelAllButton.isEnabled = queue.isRunning
        if previousCount != queue.records.count { previousCount = queue.records.count; table.reloadData() }
        else {
            table.enumerateAvailableRowViews { _, row in
                if self.queue.records.indices.contains(row), let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TransferCell { self.update(cell, row: row) }
            }
        }
    }
    private func update(_ cell: TransferCell, row: Int) {
        let record = queue.records[row]
        cell.update(record) { [weak self] in self?.queue.cancel(record.id) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { queue.records.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("transferCell")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? TransferCell ?? TransferCell()
        cell.identifier = identifier; update(cell, row: row); return cell
    }
    @objc private func hideWindow() { window?.orderOut(nil) }
    @objc private func cancelAll() { queue.cancelAll() }
}
