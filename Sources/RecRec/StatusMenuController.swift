import AppKit
import RecRecCore

/// Owns the status-bar item and its menu; every option lives in the menu (no windows).
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: SettingsStore
    private let recorder: Recorder
    private var settings: RecordingSettings
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var elapsedTimer: Timer?
    private var lastResult: RecordingResult?
    private var exportInProgress = false
    private var displays: [(id: UInt32, name: String)] = []

    init(store: SettingsStore, recorder: Recorder) {
        self.store = store
        self.recorder = recorder
        self.settings = store.load()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        recorder.onStateChange = { [weak self] state in self?.stateChanged(state) }
        recorder.onFinished = { [weak self] result in self?.recordingFinished(result) }
        displays = DisplaySelection.connectedDisplays()
        updateStatusButton()
        rebuildMenu()
    }

    // MARK: - Recording

    func toggleRecording() {
        switch recorder.state {
        case .idle:
            startRecording()
        case .recording:
            Task { await recorder.stop() }
        case .preparing, .stopping:
            break
        }
    }

    private func startRecording() {
        let settings = self.settings
        Task { @MainActor in
            do {
                try await recorder.start(settings: settings)
            } catch {
                presentStartError(error)
            }
        }
    }

    private func presentStartError(_ error: Error) {
        switch error as? RecorderError {
        case .screenRecordingDenied?:
            Permissions.presentScreenRecordingDenied()
        case .microphoneDenied?:
            Permissions.presentMicrophoneDenied()
        default:
            Permissions.presentError(error, title: "Could not start recording")
        }
    }

    // MARK: - Menu actions

    @objc private func toggleRecordingAction(_ sender: Any?) { toggleRecording() }

    @objc private func toggleMicrophone(_ sender: Any?) {
        settings.microphoneEnabled.toggle()
        save()
        if settings.microphoneEnabled { requestMicrophoneIfNeeded() }
    }

    @objc private func toggleSystemAudio(_ sender: Any?) { settings.systemAudioEnabled.toggle(); save() }
    @objc private func toggleCursor(_ sender: Any?) { settings.showsCursor.toggle(); save() }
    @objc private func toggleReveal(_ sender: Any?) { settings.revealInFinder.toggle(); save() }

    @objc private func selectQuality(_ sender: NSMenuItem) {
        if let tier = sender.representedObject as? QualityTier { settings.quality = tier; save() }
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let container = Container(rawValue: pair[0]), let codec = VideoCodec(rawValue: pair[1]) else { return }
        settings.container = container
        settings.codec = codec
        save()
    }

    @objc private func selectFrameRate(_ sender: NSMenuItem) {
        if let rate = sender.representedObject as? Int { settings.frameRate = rate; save() }
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        if let scale = sender.representedObject as? ResolutionScale { settings.resolution = scale; save() }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        settings.pinnedDisplayID = sender.representedObject as? UInt32
        save()
    }

    @objc private func selectFolder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            settings.saveDirectory = url
            save()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Recordings will be saved in this folder."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
            save()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
            Permissions.presentError(error, title: "Launch at Login")
        }
        rebuildMenu()
    }

    @objc private func openLast(_ sender: Any?) {
        if let url = lastResult?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func revealLast(_ sender: Any?) {
        if let url = lastResult?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func exportGIF(_ sender: Any?) {
        guard let url = lastResult?.url, !exportInProgress else { return }
        exportInProgress = true
        rebuildMenu()
        let gif = OutputNaming.gifURL(for: url)
        Task { @MainActor in
            do {
                try await GIFExporter.export(video: url, to: gif)
                NSWorkspace.shared.activateFileViewerSelecting([gif])
            } catch {
                Permissions.presentError(error, title: "GIF export failed")
            }
            exportInProgress = false
            rebuildMenu()
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func requestMicrophoneIfNeeded() {
        Task { @MainActor in
            let granted = await MicrophoneCapture.requestAccess()
            if !granted {
                settings.microphoneEnabled = false
                save()
                Permissions.presentMicrophoneDenied()
            }
        }
    }

    private func save() {
        store.save(settings)
        rebuildMenu()
    }

    // MARK: - State

    private func stateChanged(_ state: RecorderState) {
        updateStatusButton()
        rebuildMenu()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .recording = state {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.updateStatusButton() }
            }
            RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a menu is open
            elapsedTimer = timer
        }
    }

    private func recordingFinished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .success(let recording):
            lastResult = recording
            if settings.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
        case .failure(let error):
            Permissions.presentError(error, title: "Recording stopped with an error")
        }
        rebuildMenu()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        switch recorder.state {
        case .recording(let since):
            let elapsed = Int(Date().timeIntervalSince(since))
            let text = String(format: "● %02d:%02d", elapsed / 60, elapsed % 60)
            button.image = nil
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ])
        case .preparing, .stopping:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "RecRec is busy")
        case .idle:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "RecRec")
        }
    }

    // MARK: - Menu construction

    func menuWillOpen(_ menu: NSMenu) {
        displays = DisplaySelection.connectedDisplays()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let busy: Bool
        switch recorder.state {
        case .idle: busy = false
        case .preparing, .recording, .stopping: busy = true
        }

        let toggle: NSMenuItem
        switch recorder.state {
        case .idle: toggle = item("Start Recording", #selector(toggleRecordingAction(_:)), key: "r")
        case .recording: toggle = item("Stop Recording", #selector(toggleRecordingAction(_:)), key: "r")
        case .preparing: toggle = item("Starting…", nil)
        case .stopping: toggle = item("Saving…", nil)
        }
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(check("Microphone", settings.microphoneEnabled, #selector(toggleMicrophone(_:)), enabled: !busy))
        menu.addItem(check("System Audio", settings.systemAudioEnabled, #selector(toggleSystemAudio(_:)), enabled: !busy))
        menu.addItem(check("Show Cursor", settings.showsCursor, #selector(toggleCursor(_:)), enabled: !busy))
        menu.addItem(.separator())

        let quality = submenu("Quality", enabled: !busy)
        for (tier, name) in [(QualityTier.small, "Small"), (.balanced, "Balanced"), (.high, "High")] {
            quality.submenu?.addItem(radio(name, settings.quality == tier, #selector(selectQuality(_:)), tier))
        }
        menu.addItem(quality)

        let format = submenu("Format", enabled: !busy)
        let formats: [(Container, VideoCodec, String)] = [
            (.mp4, .hevc, "MP4 · HEVC (smallest)"),
            (.mp4, .h264, "MP4 · H.264 (most compatible)"),
            (.mov, .hevc, "MOV · HEVC"),
            (.mov, .h264, "MOV · H.264"),
        ]
        for (container, codec, name) in formats {
            let selected = settings.container == container && settings.codec == codec
            format.submenu?.addItem(radio(name, selected, #selector(selectFormat(_:)), [container.rawValue, codec.rawValue]))
        }
        menu.addItem(format)

        let frameRate = submenu("Frame Rate", enabled: !busy)
        for rate in RecordingSettings.frameRateChoices {
            frameRate.submenu?.addItem(radio("\(rate) fps", settings.frameRate == rate, #selector(selectFrameRate(_:)), rate))
        }
        menu.addItem(frameRate)

        let resolution = submenu("Resolution", enabled: !busy)
        resolution.submenu?.addItem(radio("Retina (native pixels)", settings.resolution == .retina, #selector(selectResolution(_:)), ResolutionScale.retina))
        resolution.submenu?.addItem(radio("Standard (1x, smaller files)", settings.resolution == .standard, #selector(selectResolution(_:)), ResolutionScale.standard))
        menu.addItem(resolution)

        if displays.count > 1 {
            let display = submenu("Display", enabled: !busy)
            display.submenu?.addItem(radio("Screen under the mouse", settings.pinnedDisplayID == nil, #selector(selectDisplay(_:)), nil))
            for entry in displays {
                display.submenu?.addItem(radio(entry.name, settings.pinnedDisplayID == entry.id, #selector(selectDisplay(_:)), entry.id))
            }
            menu.addItem(display)
        }
        menu.addItem(.separator())

        if let last = lastResult {
            let size = ByteCountFormatter.string(fromByteCount: last.fileSize, countStyle: .file)
            let lastItem = submenu("Last: \(last.url.lastPathComponent) (\(size))", enabled: true)
            lastItem.submenu?.addItem(item("Open", #selector(openLast(_:))))
            lastItem.submenu?.addItem(item("Reveal in Finder", #selector(revealLast(_:))))
            lastItem.submenu?.addItem(item(exportInProgress ? "Exporting GIF…" : "Export GIF", exportInProgress ? nil : #selector(exportGIF(_:))))
            menu.addItem(lastItem)
        }

        let folder = submenu("Save to: \(settings.saveDirectory.lastPathComponent)", enabled: !busy)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(String, URL)] = [
            ("Movies/RecRec", RecordingSettings.defaultSaveDirectory),
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true)),
        ]
        for (name, url) in folders {
            let selected = settings.saveDirectory.standardizedFileURL.path == url.standardizedFileURL.path
            folder.submenu?.addItem(radio(name, selected, #selector(selectFolder(_:)), url))
        }
        folder.submenu?.addItem(.separator())
        folder.submenu?.addItem(item("Choose Folder…", #selector(selectFolder(_:))))
        menu.addItem(folder)
        menu.addItem(check("Reveal in Finder After Recording", settings.revealInFinder, #selector(toggleReveal(_:)), enabled: true))
        menu.addItem(.separator())

        menu.addItem(check("Launch at Login", LaunchAtLogin.isEnabled, #selector(toggleLaunchAtLogin(_:)), enabled: true))
        let quit = item("Quit RecRec", #selector(quit(_:)), key: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.isEnabled = action != nil
        return menuItem
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let menuItem = item(title, action)
        menuItem.state = on ? .on : .off
        menuItem.isEnabled = enabled
        return menuItem
    }

    private func radio(_ title: String, _ on: Bool, _ action: Selector, _ value: Any?) -> NSMenuItem {
        let menuItem = item(title, action)
        menuItem.state = on ? .on : .off
        menuItem.representedObject = value
        return menuItem
    }

    private func submenu(_ title: String, enabled: Bool) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        menuItem.submenu = sub
        menuItem.isEnabled = enabled
        return menuItem
    }
}
