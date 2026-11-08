import Foundation

enum Location: Hashable, Codable {
    case local(String)
    case disk(String)

    var path: String { switch self { case .local(let p), .disk(let p): return p } }
    var isDisk: Bool { if case .disk = self { return true }; return false }
    var name: String {
        if path == "disk:/" { return "Яндекс Диск" }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "Дом" }
        return (path as NSString).lastPathComponent
    }
    var parent: Location {
        if isDisk {
            let parts = path.dropFirst(6).split(separator: "/").dropLast()
            return .disk("disk:/" + parts.joined(separator: "/"))
        }
        return .local((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent)
    }
    func child(_ name: String) -> Location {
        isDisk ? .disk(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name) : .local((path as NSString).appendingPathComponent(name))
    }
    func contains(_ other: Location) -> Bool {
        guard isDisk == other.isDisk else { return false }
        let base = canonicalPath
        let candidate = other.canonicalPath
        return candidate == base || candidate.hasPrefix(base == "/" || base == "disk:/" ? base : base + "/")
    }
    var canonicalPath: String {
        if !isDisk { return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        var parts: [String] = []
        for part in path.dropFirst(6).split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(String(part)) }
        }
        return "disk:/" + parts.joined(separator: "/")
    }
    static func parse(_ raw: String) -> Location {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("disk:") { let l = Location.disk("disk:/" + p.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "/"))); return .disk(l.canonicalPath) }
        return .local(URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.path)
    }
    var breadcrumbs: [(String, Location)] {
        if isDisk {
            var result: [(String, Location)] = [("Яндекс Диск", .disk("disk:/"))]
            var current = Location.disk("disk:/")
            for part in path.dropFirst(6).split(separator: "/") { current = current.child(String(part)); result.append((String(part), current)) }
            return result
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromHome = path == home || path.hasPrefix(home + "/")
        var current = Location.local(fromHome ? home : "/")
        var result = [(fromHome ? "Дом" : "Macintosh HD", current)]
        let tail = fromHome ? String(path.dropFirst(home.count)) : path
        for part in tail.split(separator: "/") { current = current.child(String(part)); result.append((String(part), current)) }
        return result
    }
}

struct FileEntry: Hashable {
    let location: Location
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    var isHidden: Bool { name.hasPrefix(".") }
    var ext: String { (name as NSString).pathExtension.lowercased() }
}

enum SortMode: Int, CaseIterable { case groups, name, date, size
    var title: String { ["Группы по дате", "Имя", "Дата", "Размер"][rawValue] }
}
enum DisplayRow { case group(String), file(FileEntry) }

enum Listing {
    static func sorted(_ entries: [FileEntry], by mode: SortMode, ascending: Bool) -> [FileEntry] {
        entries.sorted { a, b in
            let comparison: ComparisonResult
            switch mode {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .date, .groups:
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                comparison = da == db ? a.name.localizedStandardCompare(b.name) : (da < db ? .orderedAscending : .orderedDescending)
            case .size:
                comparison = a.size == b.size ? a.name.localizedStandardCompare(b.name) : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            return mode == .groups ? comparison == .orderedDescending : (ascending ? comparison == .orderedAscending : comparison == .orderedDescending)
        }
    }
    static func group(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Без даты" }
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "Вчера" }
        if (2...7).contains(days) { return "Предыдущие 7 дней" }
        if (8...30).contains(days) { return "Предыдущие 30 дней" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.calendar = calendar
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date).prefix(1).uppercased() + formatter.string(from: date).dropFirst()
    }
    static func rows(_ entries: [FileEntry], mode: SortMode, ascending: Bool, filter: String, hidden: Bool) -> [DisplayRow] {
        let items = sorted(entries.filter { (hidden || !$0.isHidden) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }, by: mode, ascending: ascending)
        var result: [DisplayRow] = [], previous: String?
        for file in items {
            if mode == .groups { let g = group(for: file.modified); if g != previous { result.append(.group(g)); previous = g } }
            result.append(.file(file))
        }
        return result
    }
    static func numberedName(_ name: String, number: Int, isDirectory: Bool) -> String {
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        return (ext.isEmpty ? name : ns.deletingPathExtension) + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
    }
    static func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") || name.contains("\0") { throw LoaderError.message("Имя не может быть пустым, содержать / или : либо состоять из точек.") }
    }
}

enum LoaderError: LocalizedError {
    case message(String), unauthorized, http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .unauthorized: return "Сессия Яндекс Диска закончилась. Подключите Диск снова."
        case .http(let code):
            return [403: "Нет доступа к этой папке или операции.", 404: "Файл или папка не найдены.", 409: "Имя уже занято или папка назначения недоступна.", 413: "Файл слишком большой для загрузки.", 423: "Файл временно заблокирован. Повторите позже.", 429: "Слишком много запросов. Повторите чуть позже.", 507: "На Яндекс Диске закончилось место." ][code] ?? "Не удалось выполнить запрос к Диску (\(code))."
        }
    }
}

func sizeText(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
func errorText(_ error: Error) -> String {
    if error is LoaderError { return error.localizedDescription }
    let e = error as NSError
    if e.domain == NSCocoaErrorDomain {
        switch e.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "macOS не разрешила доступ к папке. Проверьте разрешения в настройках конфиденциальности."
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "Файл или папка не найдены. Возможно, их переместили или переименовали."
        case NSFileWriteFileExistsError: return "Файл или папка с таким именем уже существуют."
        case NSFileWriteOutOfSpaceError: return "На локальном диске закончилось место."
        default: break
        }
    }
    if e.domain == NSURLErrorDomain {
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "Нет соединения с интернетом. Проверьте сеть и повторите операцию."
        case NSURLErrorTimedOut: return "Яндекс Диск долго не отвечает. Повторите операцию."
        case NSURLErrorCancelled: return "Операция отменена."
        default: return "Не удалось связаться с Яндекс Диском. Проверьте подключение к интернету."
        }
    }
    return error.localizedDescription
}
func dateText(_ date: Date?) -> String {
    guard let date else { return "—" }
    let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
    return f.string(from: date)
}
