import AppKit
import RecRecCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var recorder: ScreenRecorder!
    private var menu: StatusMenuController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder = ScreenRecorder()
        menu = StatusMenuController(store: store, recorder: recorder)
        hotKey = HotKey { [weak self] in
            self?.menu.toggleRecording()
        }
    }

    /// Never leave a recording unfinished: stop and finalize before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch recorder.state {
        case .idle:
            return .terminateNow
        case .preparing, .recording, .stopping:
            Task { @MainActor in
                await recorder.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
