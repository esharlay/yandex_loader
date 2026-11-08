import Foundation

enum TransferPhase: Equatable {
    case waiting, transferring, finishing, server, cancelling, completed, cancelled, skipped, failed
    var isTerminal: Bool { [.completed, .cancelled, .skipped, .failed].contains(self) }
    var canCancel: Bool { self == .waiting || self == .transferring }
    var title: String {
        switch self {
        case .waiting: return "В очереди"
        case .transferring: return "Передаётся"
        case .finishing: return "Завершение"
        case .server: return "Выполняется на Диске"
        case .cancelling: return "Отменяем…"
        case .completed: return "Готово"
        case .cancelled: return "Отменено"
        case .skipped: return "Пропущено"
        case .failed: return "Ошибка"
        }
    }
}

struct TransferRecord: Identifiable {
    let id: UUID
    let entry: FileEntry
    let displayName: String
    var bytes: Int64 = 0
    var total: Int64
    var phase: TransferPhase = .waiting
    var note = ""
    var fraction: Double {
        if phase == .completed { return 1 }
        guard total > 0 else { return 0 }
        return min(0.99, max(0, Double(bytes) / Double(total)))
    }
    var detail: String {
        if !note.isEmpty { return note }
        if phase == .transferring && total > 0 { return "\(sizeText(bytes)) из \(sizeText(total))" }
        return (total > 0 ? sizeText(total) + " · " : "") + phase.title
    }
}

@MainActor final class TransferQueue {
    private(set) var records: [TransferRecord] = []
    private var indexes: [UUID: Int] = [:]
    private var cancellations: [UUID: () -> Void] = [:]
    private var requested: Set<UUID> = []
    private var observers: [() -> Void] = []
    private var updateScheduled = false
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var operation = "Передачи"
    private(set) var destination: Location?
    var onCancelAll: (() -> Void)?

    func observe(_ observer: @escaping () -> Void) { observers.append(observer) }
    private func notify() { for observer in observers { observer() } }
    func begin(operation: String, destination: Location) {
        records = []; indexes = [:]; cancellations = [:]; requested = []
        self.operation = operation; self.destination = destination
        isRunning = true; isPreparing = true; notify()
    }
    @discardableResult func append(_ entry: FileEntry, displayName: String) -> UUID {
        let id = UUID(); indexes[id] = records.count
        records.append(TransferRecord(id: id, entry: entry, displayName: displayName, total: max(0, entry.size)))
        notify(); return id
    }
    func prepared() { isPreparing = false; notify() }
    func record(_ id: UUID) -> TransferRecord? { indexes[id].map { records[$0] } }
    func cancellationRequested(_ id: UUID) -> Bool { requested.contains(id) }
    func bindCancellation(_ id: UUID, _ cancel: @escaping () -> Void) { cancellations[id] = cancel; if requested.contains(id) { cancel() } }
    func unbindCancellation(_ id: UUID) { cancellations[id] = nil }
    func cancel(_ id: UUID) {
        guard let i = indexes[id], records[i].phase.canCancel else { return }
        requested.insert(id)
        if let cancel = cancellations[id] { records[i].phase = .cancelling; cancel() }
        else { records[i].phase = .cancelled }
        notify()
    }
    func cancelAll() {
        for id in records.map(\.id) { cancel(id) }
        onCancelAll?()
    }
    func setPhase(_ id: UUID, _ phase: TransferPhase, note: String = "") {
        guard let i = indexes[id] else { return }
        records[i].phase = phase; records[i].note = note
        if phase == .completed { records[i].bytes = records[i].total }
        notify()
    }
    func setPhase(_ ids: [UUID], _ phase: TransferPhase, note: String = "") {
        for id in ids where record(id)?.phase.isTerminal == false { setPhase(id, phase, note: note) }
    }
    func updateBytes(_ id: UUID, sent: Int64, total: Int64) {
        guard let i = indexes[id], records[i].phase == .transferring else { return }
        records[i].total = max(records[i].total, total)
        records[i].bytes = max(records[i].bytes, records[i].total > 0 ? min(sent, records[i].total) : sent)
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            updateScheduled = false; notify()
        }
    }
    func finish(cancelled: Bool = false, error: String? = nil) {
        isRunning = false; isPreparing = false; cancellations = [:]
        for i in records.indices where !records[i].phase.isTerminal {
            let serverWasRunning = records[i].phase == .server
            records[i].phase = cancelled ? .cancelled : records[i].phase == .waiting ? .skipped : .failed
            records[i].note = serverWasRunning && cancelled ? "Ожидание остановлено; операция на Диске может завершиться" : error ?? (cancelled ? "Передача отменена" : "Передача прервана")
        }
        notify()
    }
    var fraction: Double {
        let included = records.filter { ![.cancelled, .skipped, .failed].contains($0.phase) }
        let total = included.reduce(0.0) { $0 + Double(max(1, $1.total)) }
        return total > 0 ? included.reduce(0.0) { $0 + $1.fraction * Double(max(1, $1.total)) } / total : 0
    }
    var isIndeterminate: Bool { isPreparing || records.contains { $0.phase == .server || $0.phase == .transferring && $0.total <= 0 } }
    var cancelledCount: Int { records.filter { $0.phase == .cancelled }.count }
    var completedCount: Int { records.filter { $0.phase == .completed }.count }
    var activeName: String? { records.first { [.transferring, .finishing, .server, .cancelling].contains($0.phase) }?.displayName }
    var summary: String {
        if isPreparing { return "Подготовка передачи…" }
        if isRunning {
            if isIndeterminate { return operation + "…" }
            let f = NumberFormatter(); f.locale = Locale(identifier: "ru_RU"); f.maximumFractionDigits = 1
            return operation + " " + (f.string(from: NSNumber(value: fraction * 100)) ?? "0") + "%"
        }
        if records.isEmpty { return "Нет передач" }
        if records.contains(where: { $0.phase == .failed }) { return "Передача прервана" }
        if cancelledCount == records.count { return "Передача отменена" }
        return "Готово: \(completedCount)" + (cancelledCount > 0 ? " · отменено: \(cancelledCount)" : "")
    }
}
