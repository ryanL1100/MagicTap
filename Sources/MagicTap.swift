import SwiftUI
import AppKit
import ApplicationServices
import Combine
import UniformTypeIdentifiers

private let eventMarker: Int64 = 0x4D544150
private var diagnostic = false
private var diagnosticFrames = 0
private var diagnosticPeak = 0

@_cdecl("magic_tap_frame")
func magicTapFrame(_ timestamp: Double, _ count: Int32, _ coordinates: UnsafePointer<Float>?, _ deviceIndex: Int32) {
    let n = Int(count)
    guard n >= 0, n <= 32, n == 0 || coordinates != nil else { return }
    let points: [(Double,Double)] = (0..<n).map { (Double(coordinates![$0*2]),Double(coordinates![$0*2+1])) }
    let pressed = CGEventSource.buttonState(.combinedSessionState,button: .left) || CGEventSource.buttonState(.combinedSessionState,button: .right) || CGEventSource.buttonState(.combinedSessionState,button: .center)
    DispatchQueue.main.async {
        if diagnostic {
            diagnosticFrames += 1
            diagnosticPeak = max(diagnosticPeak,n)
        } else { GestureModel.shared.frame(timestamp,points,pressed,deviceIndex) }
    }
}

enum Action: String, CaseIterable, Identifiable {
    case none, left, right, middle, missionControl, back, forward
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute, openApp
    var needsAccessibility: Bool { [.left,.right,.middle,.missionControl,.back,.forward].contains(self) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不执行动作"
        case .left: return "左键点击"
        case .right: return "右键点击"
        case .middle: return "中键点击"
        case .missionControl: return "调度中心"
        case .back: return "后退（⌘[）"
        case .forward: return "前进（⌘]）"
        case .brightnessUp: return "调亮屏幕"
        case .brightnessDown: return "调暗屏幕"
        case .volumeUp: return "增大音量"
        case .volumeDown: return "减小音量"
        case .mute: return "静音 / 取消静音"
        case .openApp: return "打开 App…"
        }
    }
}

final class GestureModel: ObservableObject {
    static let shared = GestureModel()
    @Published var enabled = false
    @Published var devices: [String] = []
    @Published var deviceIndices: [Int32] = []
    @Published var selectedDevice: Int32 = -1
    var isTrackpad: Bool { tap_device_is_trackpad(selectedDevice) }
    var gestureIndices: [Int] { isTrackpad ? Array(3..<9) : Array(0..<3) }
    func gestureTitle(_ index: Int) -> String {
        index<3 ? ["单指轻触","双指轻触","三指轻触"][index] : TrackpadRecognizer.Gesture(rawValue:index-3)!.title
    }
    func selectDevice(_ index: Int32) {
        stop();selectedDevice=index;recent="尚未识别手势";actionFeedback=""
    }
    @Published var status = "轻触识别已暂停"
    @Published var activeFingers = 0
    @Published var frames = 0
    @Published var recent = "尚未识别轻触"
    @Published var trusted = AXIsProcessTrusted()
    @Published var appPaths: [String] = Array(repeating:"",count:9) { didSet {
        UserDefaults.standard.set(Array(appPaths.prefix(3)),forKey:"appPaths")
        UserDefaults.standard.set(Array(appPaths.suffix(6)),forKey:"trackpadAppPaths")
    } }
    @Published var actionFeedback = ""
    @Published var actions: [Action] = [.left,.right,.middle] + Array(repeating:.none,count:6) { didSet { save() } }
    @Published var duration = 0.25 { didSet { UserDefaults.standard.set(duration,forKey:"duration") } }
    @Published var movement = 0.035 { didSet { UserDefaults.standard.set(movement,forKey:"movement") } }
    @Published var previewOnly = true
    private var recognizer = TapRecognizer()
    private var trackpadRecognizer = TrackpadRecognizer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private init() {
        let defaults = UserDefaults.standard
        // Read every namespace before assigning observed properties, preserving both profiles.
        let mouseActions=defaults.stringArray(forKey:"actions")
        let padActions=defaults.stringArray(forKey:"trackpadActions")
        let mousePaths=defaults.stringArray(forKey:"appPaths")
        let padPaths=defaults.stringArray(forKey:"trackpadAppPaths")
        let loadedMouse=mouseActions?.count==3 ? mouseActions!.map {Action(rawValue:$0) ?? .none} : [.left,.right,.middle]
        let loadedPad=padActions?.count==6 ? padActions!.map {Action(rawValue:$0) ?? .none} : Array(repeating:Action.none,count:6)
        actions=loadedMouse+loadedPad
        appPaths=(mousePaths?.count==3 ? mousePaths! : Array(repeating:"",count:3)) + (padPaths?.count==6 ? padPaths! : Array(repeating:"",count:6))
        if defaults.object(forKey:"duration") != nil { duration = max(0.12,min(0.45,defaults.double(forKey:"duration"))) }
        if defaults.object(forKey:"movement") != nil { movement = max(0.015,min(0.08,defaults.double(forKey:"movement"))) }
        rescan()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in self?.physicalClick(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in self?.physicalClick(event); return event }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2,repeats:true) { [weak self] _ in self?.trusted = AXIsProcessTrusted() }
    }
    private func save() {
        UserDefaults.standard.set(actions.prefix(3).map(\.rawValue),forKey:"actions")
        UserDefaults.standard.set(actions.suffix(6).map(\.rawValue),forKey:"trackpadActions")
    }
    private func physicalClick(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != eventMarker { recognizer.cancel();trackpadRecognizer.cancel() }
    }
    func rescan() {
        let resume = enabled
        enabled = false
        recognizer.reset();trackpadRecognizer.reset();activeFingers=0
        let count = tap_scan()
        let previousName=deviceIndices.firstIndex(of:selectedDevice).map { devices[$0] }
        deviceIndices=Array(0..<count).filter { tap_device_is_mouse($0) || tap_device_is_trackpad($0) }
        devices=deviceIndices.map { String(cString:tap_device_name($0)) }
        if let previousName, let offset=devices.firstIndex(of:previousName) { selectedDevice=deviceIndices[offset] }
        else { selectedDevice=deviceIndices.first(where:{tap_device_is_mouse($0)}) ?? deviceIndices.first ?? -1 }
        status = devices.isEmpty ? "未检测到鼠标或触控板，请连接后刷新" : "已连接，手势识别已暂停"
        let error = String(cString:tap_error())
        if !error.isEmpty { status = error }
        if resume { start() }
    }
    func start() {
        recognizer.reset();trackpadRecognizer.reset(); frames=0
        guard !devices.isEmpty else { status="请先连接鼠标或触控板，再刷新设备";return }
        let started = tap_start(magicTapFrame,selectedDevice)
        enabled = started>0
        status = enabled ? "监听中 · 请先抬起所有手指，再轻触" : "未能启动触控监听，请刷新设备"
    }
    func stop() {
        enabled=false;tap_stop();recognizer.reset();trackpadRecognizer.reset();activeFingers=0;status="轻触识别已暂停"
    }
    func frame(_ time: Double,_ points: [(Double,Double)],_ physical: Bool,_ deviceIndex: Int32) {
        guard enabled, deviceIndex==selectedDevice else { return }
        frames += 1;activeFingers=points.count
        recognizer.maximumDuration=duration;recognizer.movementLimit=movement
        let gestureIndex: Int?
        if isTrackpad {
            trackpadRecognizer.maximumDuration=duration
            trackpadRecognizer.movementLimit=movement
            gestureIndex=trackpadRecognizer.feed(time:time,points:points,physicalButton:physical).map { $0.rawValue+3 }
        } else {
            gestureIndex=recognizer.feed(time:time,points:points,physicalButton:physical).map { $0-1 }
        }
        if let index=gestureIndex {
            let action=actions[index]
            recent="\(gestureTitle(index)) → \(action.title)\(previewOnly ? "（预览）" : "")"
            guard !previewOnly, action != .none else { return }
            guard !action.needsAccessibility || AXIsProcessTrusted() else { actionFeedback="需要辅助功能权限才能执行此动作";return }
            perform(action,gesture:index)
        }
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        trusted=AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true,false] {
            let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
            e?.flags=flags;e?.setIntegerValueField(.eventSourceUserData,value:eventMarker);e?.post(tap:.cghidEventTap)
        }
    }
    func chooseApp(for gesture: Int) {
        let panel=NSOpenPanel()
        panel.title="选择要用轻触打开的 App"
        panel.allowedContentTypes=[.application]
        panel.allowsMultipleSelection=false
        panel.canChooseDirectories=false
        panel.directoryURL=URL(fileURLWithPath:"/Applications",isDirectory:true)
        let selectionIsTrackpad=isTrackpad
        panel.begin { [weak self] response in
            guard response == .OK, let url=panel.url else { return }
            guard (try? AppControl.applicationURL(path:url.path)) != nil else {
                self?.actionFeedback="请选择有效的 macOS 应用程序";return
            }
            guard self?.isTrackpad==selectionIsTrackpad else { return }
            self?.appPaths[gesture]=url.path
        }
    }
    func appName(for gesture: Int) -> String {
        let path=appPaths[gesture]
        return path.isEmpty ? "尚未选择 App" : URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent
    }
    private func perform(_ action: Action,gesture: Int) {
        actionFeedback=""
        do {
        switch action {
        case .brightnessUp: actionFeedback=try BrightnessControl.shared.change(by:0.0625)
        case .brightnessDown: actionFeedback=try BrightnessControl.shared.change(by:-0.0625)
        case .volumeUp: actionFeedback=try AudioControl.changeVolume(by:0.0625)
        case .volumeDown: actionFeedback=try AudioControl.changeVolume(by:-0.0625)
        case .mute: actionFeedback=try AudioControl.toggleMute()
        case .openApp:
            try AppControl.open(path:appPaths[gesture]) { [weak self] message in self?.actionFeedback=message }
        case .none: break
        case .back: postKey(33,flags:.maskCommand)
        case .forward: postKey(30,flags:.maskCommand)
        case .missionControl: postKey(126,flags:.maskControl)
        case .left,.right,.middle:
            guard let position=CGEvent(source:nil)?.location else { return }
            let button: CGMouseButton=action == .left ? .left : (action == .right ? .right : .center)
            let down: CGEventType=action == .left ? .leftMouseDown : (action == .right ? .rightMouseDown : .otherMouseDown)
            let up: CGEventType=action == .left ? .leftMouseUp : (action == .right ? .rightMouseUp : .otherMouseUp)
            for type in [down,up] {
                let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:position,mouseButton:button)
                e?.setIntegerValueField(.eventSourceUserData,value:eventMarker)
                e?.setIntegerValueField(.mouseEventClickState,value:1)
                e?.post(tap:.cghidEventTap)
            }
        }
        } catch { actionFeedback=error.localizedDescription }
    }
}

struct SettingsView: View {
    @ObservedObject var model = GestureModel.shared
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:12) {
                Image(systemName:"computermouse.fill").font(.system(size:32)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:4) {
                    Text("MagicTap").font(.title.bold())
                    Text("为鼠标和触控板配置你的手势。") .foregroundStyle(.secondary)
                }
                Spacer()
                Text("实验版 0.3").font(.caption).padding(7).background(.quaternary,in:Capsule())
            }
            GroupBox {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Label(model.devices.isEmpty ? "设备未连接" : "触控设备已连接",systemImage:model.devices.isEmpty ? "circle" : "checkmark.circle.fill")
                        Spacer()
                        Button("刷新设备") { model.rescan() }
                    }
                    Picker("输入设备",selection:Binding(get:{model.selectedDevice},set:{model.selectDevice($0)})) {
                        if model.deviceIndices.isEmpty { Text("无设备").tag(Int32(-1)) }
                        ForEach(model.deviceIndices,id:\.self) { index in
                            Text(String(cString:tap_device_name(index))).tag(index)
                        }
                    }
                    Text("切换设备会暂停识别。鼠标和触控板的动作分别保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(model.enabled ? "暂停识别" : "开始识别") { if model.enabled { model.stop() } else { model.start() } }
                            .buttonStyle(.borderedProminent).disabled(model.devices.isEmpty)
                        Toggle("仅预览，不执行动作",isOn:$model.previewOnly).toggleStyle(.checkbox)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(7)
            }
            GroupBox(model.isTrackpad ? "触控板手势" : "鼠标轻触") {
                VStack(spacing:12) {
                    ForEach(model.gestureIndices,id:\.self) { index in
                        VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(model.gestureTitle(index)).frame(width:90,alignment:.leading)
                            Picker("动作",selection:Binding(get:{model.actions[index]},set:{model.actions[index]=$0})) {
                                ForEach(Action.allCases) { action in Text(action.title).tag(action) }
                            }.labelsHidden().frame(maxWidth:.infinity)
                        }
                        if model.actions[index] == .openApp {
                            HStack {
                                Text(model.appName(for:index)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("选择 App…") { model.chooseApp(for:index) }
                            }.font(.callout).padding(.leading,98)
                        }
                        }
                    }
                    if model.isTrackpad {
                        Text("四指滑动按手指移动方向识别，每次落指只触发一次。请在系统设置 → 触控板 → 更多手势中关闭相同的系统手势，避免同时触发。三指拖移也可能与三指轻触冲突。本工具不会拦截系统手势。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Text("亮度、音量每次调整约 6%。亮度优先控制内置屏幕；音量控制当前输出设备。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Divider()
                    HStack {
                        Text("轻触时限").frame(width:90,alignment:.leading)
                        Slider(value:$model.duration,in:0.12...0.45,step:0.01)
                        Text("\(Int(model.duration*1000)) ms").monospacedDigit().frame(width:65)
                    }
                    HStack {
                        Text("移动容差").frame(width:90,alignment:.leading)
                        Slider(value:$model.movement,in:0.015...0.08,step:0.005)
                        Text(String(format:"%.1f%%",model.movement*100)).monospacedDigit().frame(width:65)
                    }
                }.padding(8)
            }
            HStack(alignment:.top) {
                Image(systemName:model.trusted ? "checkmark.shield" : "lock.shield")
                VStack(alignment:.leading,spacing:4) {
                    Text(model.trusted ? "辅助功能权限已开启" : "执行点击和快捷键需要辅助功能权限")
                    Text("可先用预览模式检查识别结果。若启动后没有触控帧，请检查系统的输入监控权限并重启应用。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer()
                Button("打开权限设置") { model.requestPermission() }
            }
            GroupBox {
                VStack(alignment:.leading,spacing:7) {
                    Text(model.recent).font(.callout.weight(.medium))
                    if !model.actionFeedback.isEmpty {
                        Text(model.actionFeedback).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    }
                    Text("当前触点：\(model.activeFingers)    已接收帧：\(model.frames)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            Text("手势前请先抬起全部手指。鼠标支持 1–3 指轻触；触控板支持三指、四指轻触和四指四向滑动。触控板默认所有动作关闭，请先在预览模式验证。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(24)
        }.frame(width:580,height:740)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { tap_stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
struct MagicTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = GestureModel.shared
    var body: some Scene {
        Window("MagicTap",id:"settings") { SettingsView() }.windowResizability(.contentSize)
        MenuBarExtra("MagicTap",systemImage:model.enabled ? "computermouse.fill" : "computermouse") {
            MenuContents(model:model)
        }
    }
}
struct MenuContents: View {
    @ObservedObject var model: GestureModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.status)
        Button("打开设置") { openWindow(id:"settings");NSApp.activate(ignoringOtherApps:true) }
        Button(model.enabled ? "暂停识别" : "开始识别") { if model.enabled { model.stop() } else { model.rescan();model.start() } }
        Divider()
        Button("退出 MagicTap") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
@main struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runRecognizerTests()
            runTrackpadTests()
            precondition(boundedLevel(-0.1)==0 && boundedLevel(1.1)==1 && boundedLevel(0.5)==0.5)
            print("PASS: system level bounds")
            precondition((try? AppControl.applicationURL(path:"")) == nil)
            precondition((try? AppControl.applicationURL(path:"/missing/Missing.app")) == nil)
            precondition(!Action.openApp.needsAccessibility && !Action.volumeUp.needsAccessibility && !Action.brightnessUp.needsAccessibility && Action.left.needsAccessibility)
            print("PASS: missing application validation and action permissions")
            return
        }
        if let index=CommandLine.arguments.firstIndex(of:"--open-app-check"), CommandLine.arguments.count>index+1 {
            var finished=false
            do {
                try AppControl.open(path:CommandLine.arguments[index+1]) { message in print(message);finished=true }
                let deadline=Date().addingTimeInterval(10)
                while !finished && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
                if !finished { print("App launch timed out");exit(1) }
            } catch { print(error.localizedDescription);exit(1) }
            return
        }
        if CommandLine.arguments.contains("--system-probe") {
            print(AudioControl.diagnostic())
            print(BrightnessControl.shared.diagnostic())
            return
        }
        if CommandLine.arguments.contains("--system-check") {
            // Write the current value back to verify setter availability without changing levels.
            do { print(try AudioControl.changeVolume(by:0)) } catch { print("Audio: \(error.localizedDescription)") }
            do { print(try BrightnessControl.shared.change(by:0)) } catch { print("Brightness: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--capture") {
            let n=tap_scan(); print("Touch devices: \(n)")
            for i in 0..<n { print("\(tap_device_is_mouse(i) ? "Magic Mouse" : (tap_device_is_trackpad(i) ? "Trackpad" : "Ignored")): \(String(cString:tap_device_name(i)))") }
            if CommandLine.arguments.contains("--capture") {
                let selected=(0..<n).first(where:{CommandLine.arguments.contains("--trackpad") ? tap_device_is_trackpad($0) : tap_device_is_mouse($0)}) ?? -1
                diagnostic=true;print("Started: \(tap_start(magicTapFrame,selected))")
                RunLoop.main.run(until:Date().addingTimeInterval(5));tap_stop()
                print("Frames: \(diagnosticFrames), peak active contacts: \(diagnosticPeak)")
            }
            return
        }
        MagicTapApp.main()
    }
}
