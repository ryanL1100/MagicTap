import AppKit
import CoreAudio
import CoreGraphics
import Darwin

struct ActionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func boundedLevel(_ value: Float) -> Float { min(1,max(0,value)) }

struct AudioControl {
    private static func device() throws -> AudioDeviceID {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var id=AudioDeviceID(0), size=UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&id)==noErr, id != 0 else { throw ActionFailure(message:"没有可用的音频输出设备") }
        return id
    }
    private static func read(_ device: AudioDeviceID,_ address: inout AudioObjectPropertyAddress) throws -> Float {
        var value: Float=0, size=UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,&value)==noErr, value.isFinite, (0...1).contains(value) else { throw ActionFailure(message:"无法读取当前设备的音量") }
        return value
    }
    private static func volumeAddresses(_ device: AudioDeviceID) throws -> [AudioObjectPropertyAddress] {
        var master=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device,&master) { return [master] }
        // Stereo devices commonly expose separate output channel controls.
        let channels: [AudioObjectPropertyElement]=[1,2]
        let addresses=channels.compactMap { channel -> AudioObjectPropertyAddress? in
            var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:channel)
            return AudioObjectHasProperty(device,&address) ? address : nil
        }
        guard !addresses.isEmpty else { throw ActionFailure(message:"当前音频设备不支持系统音量调节，请使用设备自身的音量控制") }
        return addresses
    }
    private static func writable(_ device: AudioDeviceID,_ address: inout AudioObjectPropertyAddress) -> Bool {
        var result: DarwinBoolean=false
        return AudioObjectIsPropertySettable(device,&address,&result)==noErr && result.boolValue
    }
    static func changeVolume(by delta: Float) throws -> String {
        let id=try device(), addresses=try volumeAddresses(id)
        var original: [Float]=[]
        for var address in addresses {
            guard writable(id,&address) else { throw ActionFailure(message:"当前音频输出的音量不可调节") }
            original.append(try read(id,&address))
        }
        for (index,var address) in addresses.enumerated() {
            var value=boundedLevel(original[index]+delta)
            if AudioObjectSetPropertyData(id,&address,0,nil,UInt32(MemoryLayout<Float>.size),&value) != noErr {
                for (rollbackIndex,var previousAddress) in addresses.prefix(index).enumerated() {
                    var previous=original[rollbackIndex]
                    _=AudioObjectSetPropertyData(id,&previousAddress,0,nil,UInt32(MemoryLayout<Float>.size),&previous)
                }
                throw ActionFailure(message:"音量调节失败，请检查当前音频输出设备")
            }
        }
        let current=try addresses.map { address -> Float in var a=address;return try read(id,&a) }
        let average=current.reduce(0,+)/Float(current.count)
        return "音量 \(Int((average*100).rounded()))%"
    }
    static func toggleMute() throws -> String {
        let id=try device()
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id,&address), writable(id,&address) else { throw ActionFailure(message:"当前音频设备不支持系统静音控制") }
        var muted: UInt32=0, size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&muted)==noErr else { throw ActionFailure(message:"无法读取静音状态") }
        muted=muted==0 ? 1 : 0
        guard AudioObjectSetPropertyData(id,&address,0,nil,size,&muted)==noErr else { throw ActionFailure(message:"静音切换失败") }
        return muted==1 ? "已静音" : "已取消静音"
    }
    static func diagnostic() -> String {
        do {
            let id=try device()
            let values=try volumeAddresses(id).map { address -> String in
                var a=address
                let value=try read(id,&a)
                return "channel=\(a.mElement) level=\(value) writable=\(writable(id,&a))"
            }
            return "Audio device \(id): "+values.joined(separator:", ")
        } catch { return "Audio: \(error.localizedDescription)" }
    }
}

final class BrightnessControl {
    static let shared=BrightnessControl()
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private init() {
        let handle=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_NOW)
        library=handle
        if let symbol=handle.flatMap({dlsym($0,"DisplayServicesGetBrightness")}) { getBrightness=unsafeBitCast(symbol,to:GetBrightness.self) } else { getBrightness=nil }
        if let symbol=handle.flatMap({dlsym($0,"DisplayServicesSetBrightness")}) { setBrightness=unsafeBitCast(symbol,to:SetBrightness.self) } else { setBrightness=nil }
    }
    private func target() -> CGDirectDisplayID {
        var displays=[CGDirectDisplayID](repeating:0,count:16), count: UInt32=0
        if CGGetOnlineDisplayList(16,&displays,&count) == .success,
           let builtIn=displays.prefix(Int(count)).first(where:{CGDisplayIsBuiltin($0) != 0}) { return builtIn }
        return CGMainDisplayID()
    }
    private func read(_ display: CGDirectDisplayID) throws -> Float {
        var value: Float=0
        guard let getter=getBrightness, getter(display,&value)==0, value.isFinite, (0...1).contains(value) else {
            throw ActionFailure(message:"此显示器不支持亮度调节；目前优先控制内置屏幕，外接显示器取决于设备支持")
        }
        return value
    }
    func change(by delta: Float) throws -> String {
        let display=target(), previous=try read(display)
        let value=boundedLevel(previous+delta)
        guard let setter=setBrightness, setter(display,value)==0 else { throw ActionFailure(message:"亮度调节失败，当前系统或显示器不支持此接口") }
        let actual=try read(display)
        return "亮度 \(Int((actual*100).rounded()))%"
    }
    func diagnostic() -> String {
        do { let display=target();return "Display \(display), builtIn=\(CGDisplayIsBuiltin(display) != 0), brightness=\(try read(display))" }
        catch { return "Brightness: \(error.localizedDescription)" }
    }
}

struct AppControl {
    static func applicationURL(path: String) throws -> URL {
        guard !path.isEmpty else { throw ActionFailure(message:"请先为此手势选择要打开的 App") }
        let url=URL(fileURLWithPath:path)
        guard url.pathExtension.lowercased()=="app", FileManager.default.fileExists(atPath:path),
              let bundle=Bundle(url:url), let executable=bundle.executableURL,
              FileManager.default.isExecutableFile(atPath:executable.path) else {
            throw ActionFailure(message:"找不到所选 App，请重新选择")
        }
        return url
    }
    static func open(path: String,completion: @escaping (String)->Void) throws {
        let url=try applicationURL(path:path)
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        NSWorkspace.shared.openApplication(at:url,configuration:configuration) { app,error in
            DispatchQueue.main.async {
                completion(error.map { "打开 App 失败：\($0.localizedDescription)" } ?? "已打开 \(app?.localizedName ?? url.deletingPathExtension().lastPathComponent)")
            }
        }
    }
}
