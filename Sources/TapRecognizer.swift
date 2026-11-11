import Foundation

struct TapRecognizer {
    var maximumDuration = 0.25
    var movementLimit = 0.035
    private var began: Double?
    private var peak = 0
    private var origin: (Double, Double)?
    private var invalid = false
    private var lastTap = -Double.infinity

    mutating func cancel() { if began != nil { invalid = true } }

    mutating func reset() {
        began = nil; peak = 0; origin = nil; invalid = false
    }

    mutating func feed(time: Double, points: [(Double, Double)], physicalButton: Bool) -> Int? {
        guard time.isFinite, points.allSatisfy({ $0.0.isFinite && $0.1.isFinite && (-0.2...1.2).contains($0.0) && (-0.2...1.2).contains($0.1) }) else {
            invalid = true; return nil
        }
        if points.isEmpty {
            defer { reset() }
            guard let start = began, !invalid, !physicalButton, (0.035...maximumDuration).contains(time-start), (1...3).contains(peak), time-lastTap>0.18 else { return nil }
            lastTap = time; return peak
        }
        if began == nil { began = time }
        if physicalButton || points.count>3 { invalid = true }
        if let start = began, time-start>maximumDuration { invalid = true }
        // Compare centroids only while finger count is stable. A count change moves the centroid.
        let center = (points.map(\.0).reduce(0,+)/Double(points.count), points.map(\.1).reduce(0,+)/Double(points.count))
        if points.count == peak, let old = origin {
            if hypot(center.0-old.0,center.1-old.1)>movementLimit { invalid = true }
        } else { origin = center }
        peak = max(peak,points.count)
        return nil
    }
}

func runRecognizerTests() {
    func check(_ name: String, _ condition: Bool) { if !condition { fatalError("FAIL: \(name)") }; print("PASS: \(name)") }
    for count in 1...3 {
        var r = TapRecognizer()
        let p = Array(repeating: (0.5,0.5),count: count)
        _ = r.feed(time: 1,points: p,physicalButton: false)
        check("\(count)-finger tap",r.feed(time: 1.1,points: [],physicalButton: false)==count)
    }
    var r = TapRecognizer()
    _ = r.feed(time: 1,points: [(0.5,0.5)],physicalButton: false)
    _ = r.feed(time: 1.05,points: [(0.7,0.5)],physicalButton: false)
    check("movement rejected",r.feed(time: 1.1,points: [],physicalButton: false)==nil)
    _ = r.feed(time: 2,points: [(0.5,0.5)],physicalButton: false)
    check("long rest rejected",r.feed(time: 3,points: [],physicalButton: false)==nil)
    _ = r.feed(time: 4,points: [(0.5,0.5)],physicalButton: true)
    check("physical click rejected",r.feed(time: 4.1,points: [],physicalButton: false)==nil)
    _ = r.feed(time: 5,points: Array(repeating: (0.5,0.5),count: 4),physicalButton: false)
    check("four fingers rejected",r.feed(time: 5.1,points: [],physicalButton: false)==nil)
    _ = r.feed(time: 6,points: [(0.5,0.5)],physicalButton: false)
    _ = r.feed(time: 6.01,points: [(0.5,0.5),(0.6,0.5)],physicalButton: false)
    _ = r.feed(time: 6.08,points: [(0.5,0.5)],physicalButton: false)
    check("staggered two-finger release",r.feed(time: 6.1,points: [],physicalButton: false)==2)
    _ = r.feed(time: 6.12,points: [(0.5,0.5)],physicalButton: false)
    check("debounce",r.feed(time: 6.2,points: [],physicalButton: false)==nil)
    _ = r.feed(time: 7,points: [(Double.nan,0.5)],physicalButton: false)
    check("invalid coordinates",r.feed(time: 7.1,points: [],physicalButton: false)==nil)
}
