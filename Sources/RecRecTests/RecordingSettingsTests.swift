import Foundation
import RecRecCore

func registerRecordingSettingsTests(_ r: TestRunner) {
    r.test("settings defaults match the spec") {
        let s = RecordingSettings.defaults
        try expectEqual(s.microphoneEnabled, false)
        try expectEqual(s.systemAudioEnabled, false)
        try expectEqual(s.showsCursor, true)
        try expectEqual(s.quality, .balanced)
        try expectEqual(s.codec, .hevc)
        try expectEqual(s.container, .mp4)
        try expectEqual(s.frameRate, 30)
        try expectEqual(s.resolution, .retina)
        try expectEqual(s.revealInFinder, true)
        try expectEqual(s.pinnedDisplayID, nil)
        try expectEqual(s.saveDirectory.path,
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/RecRec").path)
    }

    r.test("settings round-trip through JSON") {
        var s = RecordingSettings.defaults
        s.codec = .h264
        s.container = .mov
        s.frameRate = 60
        s.pinnedDisplayID = 42
        s.saveDirectory = URL(fileURLWithPath: "/tmp/recs")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(RecordingSettings.self, from: data)
        try expectEqual(back, s)
    }

    r.test("store saves and loads, and falls back to defaults on garbage") {
        let defaults = UserDefaults(suiteName: "com.barsmike.RecRec.tests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        try expectEqual(store.load(), RecordingSettings.defaults)
        var s = RecordingSettings.defaults
        s.quality = .high
        s.microphoneEnabled = true
        store.save(s)
        try expectEqual(store.load(), s)
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        try expectEqual(store.load(), RecordingSettings.defaults)
    }

    r.test("camera settings default to off, top-right, medium, mirrored") {
        let s = RecordingSettings.defaults
        try expectEqual(s.cameraEnabled, false)
        try expectEqual(s.cameraCorner, .topRight)
        try expectEqual(s.cameraSize, .medium)
        try expectEqual(s.cameraMirrored, true)
        try expectEqual(CameraBubbleSize.small.diameter, 160)
        try expectEqual(CameraBubbleSize.large.diameter, 300)
    }

    r.test("settings saved by an older version (no camera keys) still decode, with camera defaults") {
        let legacy = """
        {"microphoneEnabled":true,"systemAudioEnabled":false,"showsCursor":true,"quality":"high","codec":"h264",
         "container":"mov","frameRate":60,"resolution":"standard","revealInFinder":false,"saveDirectory":"file:///tmp/x/"}
        """
        let s = try JSONDecoder().decode(RecordingSettings.self, from: Data(legacy.utf8))
        try expectEqual(s.microphoneEnabled, true)
        try expectEqual(s.quality, .high)
        try expectEqual(s.codec, .h264)
        try expectEqual(s.frameRate, 60)
        try expectEqual(s.pinnedDisplayID, nil)
        try expectEqual(s.cameraEnabled, false)
        try expectEqual(s.cameraCorner, .topRight)
        try expectEqual(s.cameraSize, .medium)
        try expectEqual(s.cameraMirrored, true)
        var changed = s
        changed.cameraEnabled = true
        changed.cameraCorner = .bottomLeft
        changed.cameraSize = .large
        let back = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(changed))
        try expectEqual(back, changed)
    }

    r.test("camera bubble layout: corners respect the margin and stay on screen") {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)   // visibleFrame already excludes the menu bar
        let d: CGFloat = 220
        try expectEqual(CameraBubbleLayout.frame(corner: .topRight, diameter: d, in: screen), CGRect(x: 1728 - 24 - 220, y: 1080 - 24 - 220, width: 220, height: 220))
        try expectEqual(CameraBubbleLayout.frame(corner: .topLeft, diameter: d, in: screen), CGRect(x: 24, y: 1080 - 24 - 220, width: 220, height: 220))
        try expectEqual(CameraBubbleLayout.frame(corner: .bottomRight, diameter: d, in: screen), CGRect(x: 1728 - 24 - 220, y: 24, width: 220, height: 220))
        try expectEqual(CameraBubbleLayout.frame(corner: .bottomLeft, diameter: d, in: screen), CGRect(x: 24, y: 24, width: 220, height: 220))
        let offset = CGRect(x: 100, y: 200, width: 1728, height: 1080)   // a secondary display
        try expectEqual(CameraBubbleLayout.frame(corner: .bottomLeft, diameter: d, in: offset).origin, CGPoint(x: 124, y: 224))
        try expectEqual(CameraBubbleLayout.clamped(CGRect(x: -50, y: 2000, width: 220, height: 220), to: screen), CGRect(x: 0, y: 860, width: 220, height: 220))
        try expectEqual(CameraBubbleLayout.clamped(CGRect(x: 300, y: 300, width: 220, height: 220), to: screen), CGRect(x: 300, y: 300, width: 220, height: 220))
    }

    r.test("window numbers: negative and zero (off-screen windows) are ignored, valid ones convert") {
        // Regression: a hidden window reported windowNumber -1 and UInt32(-1) trapped at Start Recording.
        try expectEqual(WindowIDs.valid([-1, 0, 42, 7, Int(UInt32.max) + 1]), Set<CGWindowID>([42, 7]))
        try expectEqual(WindowIDs.valid([]), Set<CGWindowID>())
    }

    r.test("container file extensions") {
        try expectEqual(Container.mp4.fileExtension, "mp4")
        try expectEqual(Container.mov.fileExtension, "mov")
    }
}
