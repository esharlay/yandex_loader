import AppKit

func symbol(_ name: String, _ description: String = "") -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: description) }
func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
    let v = NSTextField(labelWithString: text); v.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size); v.textColor = color; v.lineBreakMode = .byTruncatingMiddle; return v
}
func button(_ title: String, image: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action); b.bezelStyle = .texturedRounded
    if let image { b.image = symbol(image); b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
    return b
}
extension NSView {
    func pin(to parent: NSView, inset: CGFloat = 0) { translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)]) }
}

final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, image: String? = nil, perform: @escaping () -> Void) {
        super.init(frame: .zero); self.title = title; self.perform = perform; target = self; action = #selector(run); bezelStyle = .texturedRounded
        if let image { self.image = symbol(image); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func run() { perform?() }
}

final class FileRow: NSTableRowView {
    var active = false { didSet { needsDisplay = true; recolor() } }
    override var isSelected: Bool { didSet { recolor() } }
    override func drawSelection(in dirtyRect: NSRect) {
        (active ? NSColor.controlAccentColor : NSColor(white: 0.85, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    func recolor() {
        for case let cell as NSTableCellView in subviews { cell.textField?.textColor = isSelected && active ? .white : (cell.identifier?.rawValue == "name" ? .labelColor : .secondaryLabelColor) }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && active ? .emphasized : .normal }
}

final class FileTable: NSTableView {
    weak var pane: PaneView?
    override func mouseDown(with event: NSEvent) { pane?.activate(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        pane?.activate()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option]) {
            switch event.keyCode {
            case 36, 76: pane?.onRename?(); return
            case 49: pane?.onPreview?(); return
            case 48: pane?.onTab?(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? { pane?.contextMenu() }
}

final class DragPayload {
    static let type = NSPasteboard.PasteboardType("com.blueeggs.yandexloader.items")
    static var entries: [FileEntry] = []
    static weak var source: PaneView?
}
