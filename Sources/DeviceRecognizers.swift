import Foundation

/// Each physical device owns its recognizer state, including debounce and contact lifecycle.
struct DeviceRecognizers {
    private var mice: [Int32: TapRecognizer] = [:]
    private var trackpads: [Int32: TrackpadRecognizer] = [:]
    mutating func reset() { mice.removeAll(); trackpads.removeAll() }
    mutating func cancel() {
        for key in Array(mice.keys) { mice[key]?.cancel() }
        for key in Array(trackpads.keys) { trackpads[key]?.cancel() }
    }
    mutating func feed(device: Int32, isTrackpad: Bool, time: Double,
                       points: [(Double,Double)], physicalButton: Bool,
                       duration: Double, movement: Double) -> Int? {
        if isTrackpad {
            var recognizer=trackpads[device] ?? TrackpadRecognizer()
            recognizer.maximumDuration=duration;recognizer.movementLimit=movement
            let gesture=recognizer.feed(time:time,points:points,physicalButton:physicalButton)
            trackpads[device]=recognizer
            return gesture.map {$0.rawValue+3}
        }
        var recognizer=mice[device] ?? TapRecognizer()
        recognizer.maximumDuration=duration;recognizer.movementLimit=movement
        let fingers=recognizer.feed(time:time,points:points,physicalButton:physicalButton)
        mice[device]=recognizer
        return fingers.map {$0-1}
    }
}

func runDeviceTests() {
    var router=DeviceRecognizers()
    func points(_ count: Int,_ x: Double=0.5)->[(Double,Double)] {Array(repeating:(x,0.5),count:count)}
    func feed(_ device: Int32,_ pad: Bool,_ time: Double,_ p: [(Double,Double)])->Int? {
        router.feed(device:device,isTrackpad:pad,time:time,points:p,physicalButton:false,duration:0.25,movement:0.035)
    }
    _=feed(0,false,1,points(1))
    _=feed(1,true,1.01,points(3))
    precondition(feed(1,true,1.1,[])==3)
    precondition(feed(0,false,1.11,[])==0)
    print("PASS: interleaved mouse and trackpad taps remain independent")
    _=feed(0,false,2,points(1))
    _=feed(1,true,2,points(4))
    precondition(feed(1,true,2.1,points(4,0.7))==6)
    precondition(feed(0,false,2.11,[])==0)
    precondition(feed(1,true,2.12,[])==nil)
    print("PASS: trackpad swipe does not invalidate concurrent mouse tap")
    _=feed(0,false,3,points(1));_=feed(2,false,3,points(2))
    precondition(feed(0,false,3.1,[])==0 && feed(2,false,3.11,[])==1)
    print("PASS: separate mice do not share debounce state")
    _=feed(0,false,4,points(1));_=feed(1,true,4,points(3))
    router.cancel()
    precondition(feed(0,false,4.1,[])==nil && feed(1,true,4.1,[])==nil)
    _=feed(0,false,5,points(1));router.reset()
    precondition(feed(0,false,5.1,[])==nil)
    print("PASS: physical-click cancellation and reset cover all devices")
}
