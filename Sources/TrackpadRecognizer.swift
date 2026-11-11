import Foundation

// One gesture per all-fingers-up cycle. Low-finger pointer/scroll input is ignored.
struct TrackpadRecognizer {
    enum Gesture: Int, CaseIterable {
        case threeTap, fourTap, left, right, up, down
        var title: String {
            ["三指轻触", "四指轻触", "四指左滑", "四指右滑", "四指上滑", "四指下滑"][rawValue]
        }
    }
    var maximumDuration = 0.25
    var movementLimit = 0.035
    var swipeDistance = 0.12
    private var began: Double?
    private var peak = 0
    private var origin: (Double,Double)?
    private var invalid = false
    private var tapInvalid = false
    private var fired = false
    private var swipeDisabled = false
    private var lastTime: Double?
    mutating func reset() { self = TrackpadRecognizer(maximumDuration:maximumDuration,movementLimit:movementLimit,swipeDistance:swipeDistance) }
    mutating func cancel() { if began != nil { invalid=true } }
    mutating func feed(time: Double, points: [(Double,Double)], physicalButton: Bool) -> Gesture? {
        guard time.isFinite, points.allSatisfy({$0.0.isFinite && $0.1.isFinite && (0...1).contains($0.0) && (0...1).contains($0.1)}) else { invalid=true;return nil }
        if let previous=lastTime, time<previous { invalid=true }
        lastTime=time
        if physicalButton { invalid=true }
        if points.isEmpty {
            defer { reset() }
            guard let start=began, !invalid, !fired, !tapInvalid,
                  (0.035...maximumDuration).contains(time-start) else { return nil }
            return peak==3 ? .threeTap : (peak==4 ? .fourTap : nil)
        }
        if began==nil { began=time }
        if points.count>4 { invalid=true }
        guard !invalid, !fired, let start=began else { return nil }
        let center=(points.map(\.0).reduce(0,+)/Double(points.count), points.map(\.1).reduce(0,+)/Double(points.count))
        if points.count>peak { peak=points.count;origin=center }
        // Do not compare centroids across a changing contact count (staggered release).
        if points.count==peak, let origin {
            let dx=center.0-origin.0, dy=center.1-origin.1
            if hypot(dx,dy)>movementLimit { tapInvalid=true }
            if peak==4, !swipeDisabled, time-start<=0.8, time-start>=0.04,
               max(abs(dx),abs(dy))>=swipeDistance,
               max(abs(dx),abs(dy))>=min(abs(dx),abs(dy))*1.5 {
                fired=true
                return abs(dx)>abs(dy) ? (dx>0 ? .right : .left) : (dy>0 ? .up : .down)
            }
        }
        // Once fingers begin lifting, do not count a re-contact as a continuing swipe.
        if points.count<peak { swipeDisabled=true }
        return nil
    }
}

func runTrackpadTests() {
    func check(_ name: String,_ condition: Bool) { precondition(condition,"FAIL: \(name)");print("PASS: \(name)") }
    func points(_ count:Int,_ x:Double=0.5,_ y:Double=0.5)->[(Double,Double)] { Array(repeating:(x,y),count:count) }
    for count in [3,4] {
        var r=TrackpadRecognizer()
        _=r.feed(time:1,points:points(count),physicalButton:false)
        check("trackpad \(count) tap",r.feed(time:1.1,points:[],physicalButton:false)?.rawValue==count-3)
    }
    for (x,y,expected) in [(0.3,0.5,TrackpadRecognizer.Gesture.left),(0.7,0.5,.right),(0.5,0.7,.up),(0.5,0.3,.down)] {
        var r=TrackpadRecognizer()
        _=r.feed(time:1,points:points(4),physicalButton:false)
        check("trackpad \(expected.title)",r.feed(time:1.1,points:points(4,x,y),physicalButton:false)==expected)
        check("swipe fires once",r.feed(time:1.2,points:points(4,x,y),physicalButton:false)==nil && r.feed(time:1.3,points:[],physicalButton:false)==nil)
    }
    for count in [1,2,5] {
        var r=TrackpadRecognizer()
        _=r.feed(time:1,points:points(count),physicalButton:false)
        check("ignore \(count) contacts",r.feed(time:1.1,points:[],physicalButton:false)==nil)
    }
    var r=TrackpadRecognizer()
    _=r.feed(time:1,points:points(3),physicalButton:false)
    _=r.feed(time:1.05,points:points(3,0.6),physicalButton:false)
    check("reject moving tap",r.feed(time:1.1,points:[],physicalButton:false)==nil)
    _=r.feed(time:2,points:points(4),physicalButton:true)
    check("reject physical click",r.feed(time:2.1,points:[],physicalButton:false)==nil)
    _=r.feed(time:3,points:points(4),physicalButton:false)
    check("reject diagonal swipe",r.feed(time:3.1,points:points(4,0.7,0.7),physicalButton:false)==nil)
    check("diagonal is not tap",r.feed(time:3.2,points:[],physicalButton:false)==nil)
    _=r.feed(time:4,points:points(4),physicalButton:false)
    check("reject slow swipe",r.feed(time:5,points:points(4,0.7),physicalButton:false)==nil)
    _=r.feed(time:5.1,points:[],physicalButton:false)
    _=r.feed(time:6,points:points(4),physicalButton:false)
    _=r.feed(time:6.08,points:points(3),physicalButton:false)
    _=r.feed(time:6.09,points:points(1),physicalButton:false)
    check("staggered four-finger release",r.feed(time:6.1,points:[],physicalButton:false) == .fourTap)
    _=r.feed(time:7,points:points(4),physicalButton:false)
    _=r.feed(time:7.05,points:points(3),physicalButton:false)
    check("recontact cannot produce swipe",r.feed(time:7.1,points:points(4,0.8),physicalButton:false)==nil)
    _=r.feed(time:7.2,points:[],physicalButton:false)
    _=r.feed(time:8,points:points(3),physicalButton:false)
    r.cancel()
    check("cancel gesture",r.feed(time:8.1,points:[],physicalButton:false)==nil)
    _=r.feed(time:9,points:points(4),physicalButton:false)
    _=r.feed(time:9.01,points:[(.nan,0.5)],physicalButton:false)
    check("invalid trackpad coordinates",r.feed(time:9.1,points:[],physicalButton:false)==nil)
    _=r.feed(time:10,points:points(3),physicalButton:false)
    check("recover after invalid frame",r.feed(time:10.1,points:[],physicalButton:false) == .threeTap)
}
