import AppKit

enum ModelRename {
    static func entry(for file: FileEntry, proposedName: String) throws -> FileEntry {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        try Listing.validateName(name)
        let ext = (file.name as NSString).pathExtension
        if !ext.isEmpty {
            let suffix = "." + ext
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                guard name.utf16.count > suffix.utf16.count else { throw LoaderError.message("Введите имя модели перед расширением \(suffix).") }
            } else { name += suffix }
        }
        try Listing.validateName(name)
        return FileEntry(location: file.location.parent.child(name), name: name, isDirectory: false, size: file.size, modified: file.modified)
    }
}

final class PreviewNameField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing, let editor = currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: (stringValue as NSString).deletingPathExtension.utf16.count))
        }
    }
}
