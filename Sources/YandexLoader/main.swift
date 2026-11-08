import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let coordinator = AppCoordinator()
    application.delegate = coordinator
    withExtendedLifetime(coordinator) { application.run() }
}
