import AppKit
import AVFoundation
import RecRecCore

/// Loom-style camera bubble: a borderless, always-on-top circular panel with the camera preview, draggable
/// anywhere. RecRec records the whole screen, so the bubble is part of the recording without any compositing.
@MainActor
final class CameraBubbleController {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private(set) var isVisible = false
    private var panel: NSPanel?
    private var bubbleView: CameraBubbleView?
    private let session = AVCaptureSession()
    private var sessionConfigured = false
    private let sessionQueue = DispatchQueue(label: "com.barsmike.RecRec.camera", qos: .userInitiated)
    private var currentSettings = RecordingSettings.defaults
    /// Where the user last dragged the bubble (kept while the app runs); nil means "use the default corner".
    private var rememberedOrigin: CGPoint?
    private var screenObserver: NSObjectProtocol?
    private let diagnostics = DiagnosticLog.shared

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.keepOnScreen() }
        }
    }

    func show(settings: RecordingSettings) throws {
        currentSettings = settings
        try configureSessionIfNeeded()
        let panel = self.panel ?? makePanel()
        let diameter = settings.cameraSize.diameter
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame: CGRect
        if let origin = rememberedOrigin {
            frame = CameraBubbleLayout.clamped(CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)), to: visible)
        } else {
            frame = CameraBubbleLayout.frame(corner: settings.cameraCorner, diameter: diameter, in: visible)
        }
        panel.setFrame(frame, display: true)
        bubbleView?.apply(mirrored: settings.cameraMirrored)
        panel.orderFrontRegardless()
        isVisible = true
        let session = self.session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
        diagnostics.log("camera", "bubble shown \(Int(diameter)) pt at \(Int(frame.origin.x)),\(Int(frame.origin.y)) mirrored=\(settings.cameraMirrored)")
    }

    func hide() {
        guard isVisible, let panel else { return }
        rememberedOrigin = panel.frame.origin
        panel.orderOut(nil)
        isVisible = false
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
        diagnostics.log("camera", "bubble hidden")
    }

    /// Applies corner, size and mirror changes; a corner change moves the bubble back to that corner.
    func apply(settings: RecordingSettings) {
        let previous = currentSettings
        currentSettings = settings
        guard isVisible, let panel else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let diameter = settings.cameraSize.diameter
        var frame = panel.frame
        if settings.cameraCorner != previous.cameraCorner {
            rememberedOrigin = nil
            frame = CameraBubbleLayout.frame(corner: settings.cameraCorner, diameter: diameter, in: visible)
        } else if settings.cameraSize != previous.cameraSize {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            frame = CameraBubbleLayout.clamped(CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter), to: visible)
        }
        panel.setFrame(frame, display: true)
        bubbleView?.apply(mirrored: settings.cameraMirrored)
        panel.invalidateShadow()
    }

    // MARK: - Private

    private func keepOnScreen() {
        guard isVisible, let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let clamped = CameraBubbleLayout.clamped(panel.frame, to: visible)
        if clamped != panel.frame { panel.setFrame(clamped, display: true) }
    }

    private func configureSessionIfNeeded() throws {
        guard !sessionConfigured else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw RecorderError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.noCamera
        }
        session.addInput(input)
        session.commitConfiguration()
        sessionConfigured = true
        diagnostics.log("camera", "using \"\(device.localizedName)\"")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = CameraBubbleView(session: session)
        panel.contentView = view
        bubbleView = view
        self.panel = panel
        return panel
    }
}

/// Circular, layer-hosting view around an AVCaptureVideoPreviewLayer. Clicking anywhere drags the window.
final class CameraBubbleView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        let root = CALayer()
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        root.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        root.borderWidth = 3
        previewLayer.videoGravity = .resizeAspectFill
        root.addSublayer(previewLayer)
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    func apply(mirrored: Bool) {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
