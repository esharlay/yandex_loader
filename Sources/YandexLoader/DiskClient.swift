import Foundation
import Security

enum TokenStore {
    static let service = "com.blueeggs.yandexloader"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "accessToken"] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; let s = SecItemAdd(q as CFDictionary, nil); if s != errSecSuccess { throw LoaderError.message("Не удалось сохранить токен в Связке ключей (\(s)).") } }
        else if status != errSecSuccess { throw LoaderError.message("Связка ключей недоступна (\(status)).") }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
    static func extract(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("access_token=") {
            let fragment = value.components(separatedBy: "#").last ?? value
            return URLComponents(string: "https://local/?" + fragment)?.queryItems?.first(where: { $0.name == "access_token" })?.value
        }
        return !value.isEmpty && !value.contains("://") && !value.contains(where: { $0.isWhitespace }) ? value : nil
    }
}

struct DiskResource: Decodable {
    var name: String; var path: String; var type: String; var size: Int64?; var modified: String?
    var entry: FileEntry {
        let f = ISO8601DateFormatter()
        var date = modified.flatMap { f.date(from: $0) }
        if date == nil { f.formatOptions.insert(.withFractionalSeconds); date = modified.flatMap { f.date(from: $0) } }
        return FileEntry(location: .disk(path), name: name, isDirectory: type == "dir", size: size ?? 0, modified: date)
    }
}
private struct DiskFolder: Decodable { var _embedded: Embedded?; struct Embedded: Decodable { var items: [DiskResource]; var total: Int? } }
struct DiskInfo: Decodable { var total_space: Int64; var used_space: Int64; var user: User?; struct User: Decodable { var login: String?; var display_name: String? } }
private struct Link: Decodable { var href: String }

final class DiskClient {
    var token: String?
    let session: URLSession
    let base = "https://cloud-api.yandex.net/v1/disk"
    init(token: String? = nil, session: URLSession = .shared) { self.token = token; self.session = session }
    func request(_ endpoint: String = "", method: String = "GET", params: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let token, !token.isEmpty else { throw LoaderError.unauthorized }
        var components = URLComponents(string: base + endpoint)!
        components.queryItems = params.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!); request.httpMethod = method
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = try check(response)
        return (data, http)
    }
    func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LoaderError.message("Диск вернул неизвестный ответ.") }
        if http.statusCode == 401 { throw LoaderError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw LoaderError.http(http.statusCode) }
        return http
    }
    func info() async throws -> DiskInfo { let (data, _) = try await request(); return try JSONDecoder().decode(DiskInfo.self, from: data) }
    func list(_ location: Location) async throws -> [FileEntry] {
        var entries: [FileEntry] = []; var offset = 0
        while true {
            try Task.checkCancellation()
            let (data, _) = try await request("/resources", params: ["path": location.path, "limit": "200", "offset": String(offset)])
            let result = try JSONDecoder().decode(DiskFolder.self, from: data)
            let items = result._embedded?.items ?? []; entries += items.map(\.entry); offset += items.count
            if items.isEmpty || offset >= (result._embedded?.total ?? Int.max) || items.count < 200 { break }
        }
        return entries
    }
    func metadata(_ location: Location) async throws -> FileEntry? {
        do { let (d, _) = try await request("/resources", params: ["path": location.path]); return try JSONDecoder().decode(DiskResource.self, from: d).entry }
        catch LoaderError.http(404) { return nil }
    }
    func finish(_ result: (Data, HTTPURLResponse)) async throws {
        guard result.1.statusCode == 202 else { return }
        let link = try JSONDecoder().decode(Link.self, from: result.0)
        guard let url = URL(string: link.href), url.scheme == "https", url.host == "cloud-api.yandex.net" else { throw LoaderError.message("Недопустимый адрес статуса операции.") }
        while true {
            try await Task.sleep(nanoseconds: 600_000_000)
            var r = URLRequest(url: url); r.setValue("OAuth " + (token ?? ""), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: r); _ = try check(response)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch obj?["status"] as? String {
            case "success": return
            case "failed": throw LoaderError.message("Яндекс Диск не смог завершить операцию.")
            case "in-progress": continue
            default: throw LoaderError.message("Неизвестный статус операции Яндекс Диска.")
            }
        }
    }
    func mkdir(_ location: Location) async throws { try await finish(request("/resources", method: "PUT", params: ["path": location.path])) }
    func remove(_ location: Location) async throws { try await finish(request("/resources", method: "DELETE", params: ["path": location.path, "permanently": "false"])) }
    func copy(_ from: Location, to: Location, move: Bool, overwrite: Bool = false) async throws {
        try await finish(request(move ? "/resources/move" : "/resources/copy", method: "POST", params: ["from": from.path, "path": to.path, "overwrite": String(overwrite)]))
    }
    func download(_ source: Location, to destination: URL, expectedSize: Int64 = 0, progress: ByteProgress? = nil) async throws {
        let (data, _) = try await request("/resources/download", params: ["path": source.path])
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard let url = URL(string: link.href), url.scheme == "https" else { throw LoaderError.message("Не удалось получить ссылку для скачивания.") }
        let (temp, response): (URL, URLResponse)
        if let progress { (temp, response) = try await NetworkDownloadOperation.download(URLRequest(url: url), configuration: session.configuration, expected: expectedSize, progress: progress) }
        else { (temp, response) = try await session.download(from: url) }
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation(); _ = try check(response)
        do { try FileManager.default.moveItem(at: temp, to: destination) } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
    func upload(_ source: URL, to destination: Location, progress: ByteProgress? = nil) async throws {
        let (data, _) = try await request("/resources/upload", params: ["path": destination.path, "overwrite": "false"])
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard let url = URL(string: link.href), url.scheme == "https" else { throw LoaderError.message("Не удалось получить ссылку для загрузки.") }
        var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = 3600
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let delegate = progress.map { NetworkProgressDelegate(expected: size, callback: $0) }
        let (_, response) = try await session.upload(for: r, fromFile: source, delegate: delegate); _ = try check(response)
        delegate?.report(size, total: size, force: true)
    }
}
