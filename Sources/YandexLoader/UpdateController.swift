import AppKit
import Sparkle

/// Keep a requested update waiting until all file operations have finished.
@MainActor final class UpdateInstallationGate {
    var isBusy: () -> Bool
    private var pendingInstallation: (() -> Void)?

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func postpone(_ installation: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstallation = installation
        return true
    }

    func resumeIfIdle() {
        guard !isBusy(), let installation = pendingInstallation else { return }
        pendingInstallation = nil
        installation()
    }
}

@MainActor final class UpdateController: NSObject, SPUUpdaterDelegate {
    let installationGate: UpdateInstallationGate
    var onPostpone: (() -> Void)?
    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    init(isBusy: @escaping () -> Bool) { installationGate = UpdateInstallationGate(isBusy: isBusy) }

    func start() { controller.startUpdater() }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Проверить обновления…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let postponed = installationGate.postpone(installHandler)
        if postponed { onPostpone?() }
        return postponed
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !installationGate.isBusy() }
}
