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

    r.test("container file extensions") {
        try expectEqual(Container.mp4.fileExtension, "mp4")
        try expectEqual(Container.mov.fileExtension, "mov")
    }
}
