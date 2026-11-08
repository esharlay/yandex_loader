import AppKit
import WebKit

@MainActor final class AuthController: NSObject, WKNavigationDelegate, WKUIDelegate {
    unowned let owner: AppCoordinator
    var settings: NSWindow?
    var loginWindow: NSWindow?
    var clientField = NSTextField()
    var tokenField = NSSecureTextField()
    var status = label("")
    var pendingState: String?
    var connecting = false
    init(owner: AppCoordinator) { self.owner = owner }
    func show() {
        if let settings { settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false); window.title = "Настройки · Яндекс Диск"; window.isReleasedWhenClosed = false; settings = window
        let heading = label("Подключите Яндекс Диск", size: 20, bold: true)
        let details = label("Создайте приложение на oauth.yandex.ru с доступами\ncloud_api:disk.read и cloud_api:disk.write, затем вставьте Client ID.", size: 12, color: .secondaryLabelColor); details.maximumNumberOfLines = 3
        clientField.stringValue = UserDefaults.standard.string(forKey: "clientID") ?? ""; clientField.placeholderString = "Client ID"; clientField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let register = ActionButton("Открыть создание приложения ↗") { NSWorkspace.shared.open(URL(string: "https://oauth.yandex.ru/")!) }; register.isBordered = false; register.contentTintColor = .controlAccentColor
        let login = ActionButton("Войти через Яндекс", image: "cloud") { [weak self] in self?.beginOAuth() }; login.bezelStyle = .rounded
        tokenField.placeholderString = "Готовый токен или адрес после входа"; tokenField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let useToken = ActionButton("Подключить по токену") { [weak self] in guard let self else { return }; accept(tokenField.stringValue) }; useToken.bezelStyle = .rounded
        let zUp = NSButton(checkboxWithTitle: "Для STL и PLY ось Z смотрит вверх", target: self, action: #selector(changeAxis(_:))); zUp.state = UserDefaults.standard.bool(forKey: "zUp") ? .on : .off
        status.stringValue = owner.accountInfo.map { "\($0.user?.login ?? "Подключён") · \(sizeText($0.used_space)) из \(sizeText($0.total_space))" } ?? "Диск не подключён"; status.maximumNumberOfLines = 3; status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let logout = ActionButton("Выйти из аккаунта") { [weak self] in self?.owner.disconnect(nil); self?.status.stringValue = "Диск не подключён" }; logout.isBordered = false
        let column = NSStackView(views: [heading, details, register, clientField, login, label("Или используйте готовый токен", color: .secondaryLabelColor), tokenField, useToken, zUp, status, logout]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12; column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        window.contentView = column; for field in [clientField, tokenField] { field.widthAnchor.constraint(equalToConstant: 492).isActive = true }
        window.center(); window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in UserDefaults.standard.set(self.clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "clientID"); self.settings = nil }
        }
    }
    @objc private func changeAxis(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "zUp") }
    func beginOAuth() {
        let client = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { status.stringValue = "Сначала вставьте Client ID."; return }
        UserDefaults.standard.set(client, forKey: "clientID"); pendingState = UUID().uuidString
        var url = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        url.queryItems = [URLQueryItem(name: "response_type", value: "token"), URLQueryItem(name: "client_id", value: client), URLQueryItem(name: "state", value: pendingState), URLQueryItem(name: "scope", value: "cloud_api:disk.read cloud_api:disk.write")]
        let web = WKWebView(); web.navigationDelegate = self; web.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window.title = "Вход через Яндекс"; window.contentView = web; window.isReleasedWhenClosed = false; loginWindow = window; window.center(); window.makeKeyAndOrderFront(nil); web.load(URLRequest(url: url.url!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.fragment?.contains("access_token=") == true { handleCallback(url); decisionHandler(.cancel) }
        else if navigationAction.request.url?.scheme == "yandexloader" { if let url = navigationAction.request.url { handleCallback(url) }; decisionHandler(.cancel) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }; return nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let url = webView.url, url.fragment?.contains("access_token=") == true { handleCallback(url) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status.stringValue = errorText(error) + " Можно вставить готовый токен." }
    func handleCallback(_ url: URL) {
        let fragment = URLComponents(string: "https://local/?" + (url.fragment ?? ""))?.queryItems ?? []
        guard let expected = pendingState, fragment.first(where: { $0.name == "state" })?.value == expected else { status.stringValue = "Не удалось проверить ответ входа. Повторите вход или вставьте токен вручную."; return }
        guard TokenStore.extract(url.absoluteString) != nil else { status.stringValue = "Яндекс не вернул токен. Можно вставить токен вручную."; return }
        pendingState = nil; loginWindow?.close(); loginWindow = nil; accept(url.absoluteString)
    }
    func accept(_ value: String) {
        guard !connecting else { return }
        guard let token = TokenStore.extract(value) else { status.stringValue = "Вставьте токен либо полный адрес с access_token."; return }
        connecting = true; status.stringValue = "Проверяем подключение…"
        Task { @MainActor in
            defer { connecting = false }
            do {
                let candidate = DiskClient(token: token); let info = try await candidate.info(); try TokenStore.save(token); owner.disk.token = token; owner.accountInfo = info
                status.stringValue = "Подключён: \(info.user?.login ?? info.user?.display_name ?? "Яндекс Диск")"; tokenField.stringValue = ""
                owner.left.reload(); owner.right.reload(); owner.refreshAccount(preferModels: owner.right.location == .disk("disk:/"))
            } catch { status.stringValue = errorText(error) }
        }
    }
}
