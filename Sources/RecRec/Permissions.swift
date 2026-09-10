import AppKit

@MainActor
enum Permissions {
    static let screenCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let cameraSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    static func presentError(_ error: Error, title: String = "RecRec") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func presentScreenRecordingDenied() {
        presentSettingsAlert(
            title: "Screen Recording permission needed",
            text: "Allow RecRec under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen RecRec.",
            url: screenCaptureSettingsURL)
    }

    static func presentMicrophoneDenied() {
        presentSettingsAlert(
            title: "Microphone permission needed",
            text: "Allow RecRec under System Settings → Privacy & Security → Microphone, or turn the Microphone option off.",
            url: microphoneSettingsURL)
    }

    static func presentCameraDenied() {
        presentSettingsAlert(
            title: "Camera permission needed",
            text: "Allow RecRec under System Settings → Privacy & Security → Camera, or leave the Camera option off.",
            url: cameraSettingsURL)
    }

    private static func presentSettingsAlert(title: String, text: String, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
}
