import Foundation

@main
struct TestMain {
    static func main() async {
        let runner = TestRunner()
        runner.test("harness smoke") { try expectEqual(1 + 1, 2) }
        registerRecordingSettingsTests(runner)
        let failures = await runner.run()
        exit(failures == 0 ? 0 : 1)
    }
}
