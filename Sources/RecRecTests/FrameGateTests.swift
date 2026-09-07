import CoreMedia
import RecRecCore

func registerFrameGateTests(_ r: TestRunner) {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    r.test("first frame must be complete; idle and other frames are skipped before start") {
        var g = FrameGate(heartbeatInterval: t(2))
        try expectEqual(g.decide(status: .idle, presentationTime: t(0)), false)
        try expectEqual(g.decide(status: .other, presentationTime: t(0.1)), false)
        try expectEqual(g.hasStarted, false)
        try expectEqual(g.decide(status: .complete, presentationTime: t(0.2)), true)
        try expectEqual(g.hasStarted, true)
        try expectEqual(g.lastAppended, t(0.2))
    }

    r.test("complete frames append, idle frames skip, non-increasing timestamps skip") {
        var g = FrameGate(heartbeatInterval: t(2))
        _ = g.decide(status: .complete, presentationTime: t(1))
        try expectEqual(g.decide(status: .idle, presentationTime: t(1.1)), false)
        try expectEqual(g.decide(status: .complete, presentationTime: t(1)), false, "same pts")
        try expectEqual(g.decide(status: .complete, presentationTime: t(0.5)), false, "earlier pts")
        try expectEqual(g.decide(status: .complete, presentationTime: .invalid), false, "invalid pts")
        try expectEqual(g.decide(status: .complete, presentationTime: t(1.2)), true)
        try expectEqual(g.lastAppended, t(1.2))
    }

    r.test("heartbeat is due only after the interval, and only after start") {
        var g = FrameGate(heartbeatInterval: t(2))
        try expectEqual(g.heartbeatDue(now: t(10)), false)
        _ = g.decide(status: .complete, presentationTime: t(1))
        try expectEqual(g.heartbeatDue(now: t(2.5)), false)
        try expectEqual(g.heartbeatDue(now: t(3)), true)
        g.noteAppended(at: t(3))
        try expectEqual(g.heartbeatDue(now: t(4)), false)
        try expectEqual(g.lastAppended, t(3))
    }
}
