import Foundation

class FileService {
    let disk: DiskClient
    init(disk: DiskClient) { self.disk = disk }
    func list(_ location: Location) async throws -> [FileEntry] {
        if location.isDisk { return try await disk.list(location) }
        return try await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: location.path), includingPropertiesForKeys: Array(keys)).map { url in
                let v = try url.resourceValues(forKeys: keys)
                return FileEntry(location: .local(url.path), name: url.lastPathComponent, isDirectory: v.isDirectory == true && v.isSymbolicLink != true, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate)
            }
        }.value
    }
    func exists(_ location: Location) async throws -> Bool {
        if location.isDisk { return try await disk.metadata(location) != nil }
        // lstat also sees broken symbolic links.
        return (try? FileManager.default.attributesOfItem(atPath: location.path)) != nil
    }
    func mkdir(_ location: Location) async throws {
        if location.isDisk { try await disk.mkdir(location) }
        else { try FileManager.default.createDirectory(atPath: location.path, withIntermediateDirectories: false) }
    }
    func trash(_ location: Location) async throws {
        if location.isDisk { try await disk.remove(location) }
        else { try FileManager.default.trashItem(at: URL(fileURLWithPath: location.path), resultingItemURL: nil) }
    }
    func rename(_ source: Location, to target: Location) async throws {
        if source.isDisk { try await disk.copy(source, to: target, move: true) }
        else { try FileManager.default.moveItem(atPath: source.path, toPath: target.path) }
    }
    func copyFile(_ entry: FileEntry, to target: Location, progress: ByteProgress? = nil) async throws {
        try Task.checkCancellation()
        if entry.location.isDisk {
            try await disk.download(entry.location, to: URL(fileURLWithPath: target.path), expectedSize: entry.size, progress: progress)
        } else if target.isDisk {
            let attrs = try FileManager.default.attributesOfItem(atPath: entry.location.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw LoaderError.message("Символическую ссылку «\(entry.name)» нельзя загрузить на Диск. Скопируйте сам файл.") }
            try await disk.upload(URL(fileURLWithPath: entry.location.path), to: target, progress: progress)
        } else {
            // A detached worker keeps large local copies off the UI thread, with cancellation between chunks.
            let task = Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let attrs = try fm.attributesOfItem(atPath: entry.location.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let reporter = progress.map { NetworkProgressDelegate(expected: size, callback: $0) }
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    try fm.copyItem(atPath: entry.location.path, toPath: target.path); reporter?.report(size, total: size, force: true); return
                }
                guard fm.createFile(atPath: target.path, contents: nil) else { throw LoaderError.message("Не удалось создать «\(target.name)».") }
                let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: entry.location.path))
                let output = try FileHandle(forWritingTo: URL(fileURLWithPath: target.path))
                defer { try? input.close(); try? output.close() }
                var copied: Int64 = 0
                while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data); copied += Int64(data.count); reporter?.report(copied, total: size) }
                try output.synchronize()
                var metadata = attrs; metadata.removeValue(forKey: .size); metadata.removeValue(forKey: .type)
                try? fm.setAttributes(metadata, ofItemAtPath: target.path)
                reporter?.report(copied, total: size, force: true)
            }
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
}

enum ConflictChoice { case replace, skip, keepBoth, cancel }
struct ConflictAnswer { var choice: ConflictChoice; var applyToAll: Bool }
struct TransferReport {
    var completed: [Location] = []
    var partial: [Location] = []
    var skipped = 0
    var cancelled = 0
}

private struct TransferPlan {
    let entry: FileEntry
    let children: [TransferPlan]
    let rowID: UUID?
    var ids: [UUID] { (rowID.map { [$0] } ?? []) + children.flatMap(\.ids) }
}

@MainActor final class TransferEngine {
    let files: FileService
    let queue: TransferQueue
    var onProgress: ((String, Int, Int) -> Void)?
    var onCompleted: ((Location) -> Void)?
    var resolve: ((FileEntry, Location) async -> ConflictAnswer)?
    var total = 0, completed = 0
    init(files: FileService, queue: TransferQueue? = nil) { self.files = files; self.queue = queue ?? TransferQueue() }

    func run(_ entries: [FileEntry], to folder: Location, move: Bool) async throws -> TransferReport {
        let operation = folder.isDisk && entries.contains(where: { !$0.location.isDisk }) ? "Загрузка" : !folder.isDisk && entries.contains(where: { $0.location.isDisk }) ? "Скачивание" : move ? "Перенос" : "Копирование"
        queue.begin(operation: operation, destination: folder)
        do {
            let report = try await execute(entries, to: folder, move: move)
            queue.finish()
            return report
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            queue.finish(cancelled: cancelled, error: cancelled ? nil : errorText(error))
            if cancelled { throw CancellationError() }
            throw error
        }
    }
    private func plan(_ entry: FileEntry, name: String, server: Bool) async throws -> TransferPlan {
        try Task.checkCancellation()
        if entry.isDirectory && !server {
            var children: [TransferPlan] = []
            for child in try await files.list(entry.location) where child.name != ".DS_Store" {
                children.append(try await plan(child, name: name + "/" + child.name, server: false))
            }
            return TransferPlan(entry: entry, children: children, rowID: children.isEmpty ? queue.append(entry, displayName: name) : nil)
        }
        return TransferPlan(entry: entry, children: [], rowID: queue.append(entry, displayName: name))
    }
    private func execute(_ entries: [FileEntry], to folder: Location, move: Bool) async throws -> TransferReport {
        var report = TransferReport(); var policy: ConflictChoice?
        total = entries.count; completed = 0
        for entry in entries {
            if entry.isDirectory && entry.location.contains(folder) { throw LoaderError.message("Нельзя поместить папку «\(entry.name)» внутрь самой себя.") }
            if entry.location.canonicalPath == folder.child(entry.name).canonicalPath && entry.location.isDisk == folder.isDisk { throw LoaderError.message("Источник и назначение «\(entry.name)» совпадают.") }
        }
        var plans: [TransferPlan] = []
        for entry in entries { plans.append(try await plan(entry, name: entry.name, server: entry.location.isDisk && folder.isDisk)) }
        queue.prepared()
        for item in plans {
            try Task.checkCancellation()
            let entry = item.entry, ids = item.ids
            if ids.allSatisfy({ queue.cancellationRequested($0) }) { completed += 1; continue }
            var target = folder.child(entry.name)
            onProgress?(entry.name, completed, total)
            if try await files.exists(target) {
                let answer: ConflictAnswer
                if let policy { answer = ConflictAnswer(choice: policy, applyToAll: true) }
                else { answer = await resolve?(entry, target) ?? ConflictAnswer(choice: .cancel, applyToAll: false) }
                try Task.checkCancellation()
                if answer.applyToAll { policy = answer.choice }
                if ids.allSatisfy({ queue.cancellationRequested($0) }) { completed += 1; continue }
                switch answer.choice {
                case .cancel: throw CancellationError()
                case .skip: report.skipped += 1; completed += 1; queue.setPhase(ids, .skipped); continue
                case .replace: try await files.trash(target)
                case .keepBoth:
                    var number = 2
                    repeat { target = folder.child(Listing.numberedName(entry.name, number: number, isDirectory: entry.isDirectory)); number += 1 } while try await files.exists(target)
                }
            }
            var entireItem = true
            if entry.location.isDisk && target.isDisk {
                guard let id = item.rowID else { continue }
                if queue.cancellationRequested(id) { completed += 1; continue }
                // Once accepted, a server operation has no cancellation endpoint.
                queue.setPhase(id, .server)
                do { try await files.disk.copy(entry.location, to: target, move: move) }
                catch { if !Task.isCancelled { queue.setPhase(id, .failed, note: errorText(error)) }; throw error }
            } else {
                let staging = folder.child(".yandexloader-" + UUID().uuidString)
                do {
                    entireItem = try await copyTree(item, to: staging)
                    try Task.checkCancellation()
                    let staged = ids.filter { queue.record($0)?.phase == .finishing }
                    if staged.isEmpty { await discard(staging); completed += 1; continue }
                    try await files.rename(staging, to: target)
                } catch {
                    await discard(staging)
                    throw error
                }
                // A partially cancelled folder keeps its entire original subtree.
                if move && entireItem { try await files.trash(entry.location) }
            }
            let note = move && !entireItem ? "Скопировано · исходник сохранён" : ""
            queue.setPhase(ids, .completed, note: note)
            if entireItem { report.completed.append(entry.location); onCompleted?(entry.location) }
            else { report.partial.append(entry.location) }
            completed += 1
            onProgress?(entry.name, completed, total)
        }
        report.cancelled = queue.cancelledCount
        return report
    }
    private func copyTree(_ item: TransferPlan, to target: Location) async throws -> Bool {
        try Task.checkCancellation()
        if item.ids.allSatisfy({ queue.cancellationRequested($0) }) { return false }
        if item.entry.isDirectory {
            if let id = item.rowID { return try await perform(id, target: target) { [files] in try await files.mkdir(target) } }
            try await files.mkdir(target)
            var whole = true
            for child in item.children {
                onProgress?(child.entry.name, completed, total)
                let copied = try await copyTree(child, to: target.child(child.entry.name))
                whole = copied && whole
            }
            return whole
        }
        guard let id = item.rowID else { return true }
        return try await perform(id, target: target) { [files, queue] in
            try await files.copyFile(item.entry, to: target, progress: { sent, total in
                Task { @MainActor in queue.updateBytes(id, sent: sent, total: total) }
            })
        }
    }
    private func perform(_ id: UUID, target: Location, action: @escaping @MainActor () async throws -> Void) async throws -> Bool {
        if queue.cancellationRequested(id) { return false }
        queue.setPhase(id, .transferring)
        let task = Task { @MainActor in try await action() }
        queue.bindCancellation(id) { task.cancel() }
        defer { queue.unbindCancellation(id) }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            if queue.cancellationRequested(id) { await discard(target); queue.setPhase(id, .cancelled); return false }
            queue.setPhase(id, .finishing)
            return true
        } catch {
            await discard(target)
            if Task.isCancelled { throw CancellationError() }
            if queue.cancellationRequested(id) { queue.setPhase(id, .cancelled); return false }
            queue.setPhase(id, .failed, note: errorText(error))
            throw error
        }
    }
    private func discard(_ location: Location) async {
        let cleanup = Task.detached { [files] in
            if location.isDisk { try? await files.disk.remove(location) }
            else { try? FileManager.default.removeItem(atPath: location.path) }
        }
        _ = await cleanup.value
    }
}
