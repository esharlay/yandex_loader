import Foundation

/// The preview follows the file order currently shown by a pane, including its filter and sort.
struct PreviewSelection {
    private(set) var files: [FileEntry] = []
    private(set) var index = 0
    var current: FileEntry? { files.indices.contains(index) ? files[index] : nil }

    mutating func start(selected: [FileEntry], visible: [FileEntry]) {
        files = visible.filter { !$0.isDirectory }
        index = selected.compactMap { selected in files.firstIndex(where: { $0.location == selected.location }) }.first ?? 0
    }
    @discardableResult mutating func follow(selected: [FileEntry], visible: [FileEntry]) -> Bool {
        let candidates = visible.filter { !$0.isDirectory }
        guard let file = selected.first(where: { chosen in candidates.contains(where: { $0.location == chosen.location }) }),
              let next = candidates.firstIndex(where: { $0.location == file.location }) else { return false }
        let previous = current
        files = candidates; index = next
        return current != previous
    }
    @discardableResult mutating func step(_ delta: Int) -> FileEntry? {
        guard files.indices.contains(index + delta) else { return nil }
        index += delta
        return current
    }
}
