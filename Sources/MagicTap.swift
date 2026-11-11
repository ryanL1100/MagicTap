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
func magicTapFrame(_ timestamp: Double, _ count: Int32, _ coordinates: UnsafePointer<Float>?) {
    let n = Int(count)
    guard n >= 0, n <= 32 else { return }
    let points: [(Double,Double)] = (0..<n).map { (Double(coordinates![$0*2]),Double(coordinates![$0*2+1])) }
    let pressed = CGEventSource.buttonState(.combinedSessionState,button: .left) || CGEventSource.buttonState(.combinedSessionState,button: .right) || CGEventSource.buttonState(.combinedSessionState,button: .center)
    DispatchQueue.main.async {
        if diagnostic {
            diagnosticFrames += 1
            diagnosticPeak = max(diagnosticPeak,n)
        } else { GestureModel.shared.frame(timestamp,points,pressed) }
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
    @Published var status = "轻触识别已暂停"
    @Published var activeFingers = 0
    @Published var frames = 0
    @Published var recent = "尚未识别轻触"
    @Published var trusted = AXIsProcessTrusted()
    @Published var appPaths: [String] = ["","",""] { didSet { UserDefaults.standard.set(appPaths,forKey:"appPaths") } }
    @Published var actionFeedback = ""
    @Published var actions: [Action] = [.left,.right,.middle] { didSet { save() } }
    @Published var duration = 0.25 { didSet { UserDefaults.standard.set(duration,forKey:"duration") } }
    @Published var movement = 0.035 { didSet { UserDefaults.standard.set(movement,forKey:"movement") } }
    @Published var previewOnly = true
    private var recognizer = TapRecognizer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey:"actions"), saved.count==3 { actions = saved.map { Action(rawValue:$0) ?? .none } }
        if defaults.object(forKey:"duration") != nil { duration = max(0.12,min(0.45,defaults.double(forKey:"duration"))) }
        if defaults.object(forKey:"movement") != nil { movement = max(0.015,min(0.08,defaults.double(forKey:"movement"))) }
        if let paths = defaults.stringArray(forKey:"appPaths"), paths.count == 3 { appPaths = paths }
        rescan()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in self?.physicalClick(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in self?.physicalClick(event); return event }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2,repeats:true) { [weak self] _ in self?.trusted = AXIsProcessTrusted() }
    }
    private func save() { UserDefaults.standard.set(actions.map(\.rawValue),forKey:"actions") }
    private func physicalClick(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != eventMarker { recognizer.cancel() }
    }
    func rescan() {
        let resume = enabled
        enabled = false
        recognizer.reset();activeFingers=0
        let count = tap_scan()
        devices = (0..<count).filter { tap_device_is_mouse($0) }.map { String(cString:tap_device_name($0)) }
        status = devices.isEmpty ? "未检测到 Magic Mouse，请连接蓝牙后刷新" : "已连接，轻触识别已暂停"
        let error = String(cString:tap_error())
        if !error.isEmpty { status = error }
        if resume { start() }
    }
    func start() {
        recognizer.reset(); frames=0
        guard !devices.isEmpty else { status="请先连接 Magic Mouse，再刷新设备";return }
        let started = tap_start(magicTapFrame)
        enabled = started>0
        status = enabled ? "监听中 · 请先抬起所有手指，再轻触" : "未能启动触控监听，请刷新设备"
    }
    func stop() {
        enabled=false;tap_stop();recognizer.reset();activeFingers=0;status="轻触识别已暂停"
    }
    func frame(_ time: Double,_ points: [(Double,Double)],_ physical: Bool) {
        guard enabled else { return }
        frames += 1;activeFingers=points.count
        recognizer.maximumDuration=duration;recognizer.movementLimit=movement
        if let fingers=recognizer.feed(time:time,points:points,physicalButton:physical) {
            let action=actions[fingers-1]
            recent="\(fingers) 指轻触 → \(action.title)\(previewOnly ? "（预览）" : "")"
            guard !previewOnly, action != .none else { return }
            guard !action.needsAccessibility || AXIsProcessTrusted() else { actionFeedback="需要辅助功能权限才能执行此动作";return }
            perform(action,gesture:fingers-1)
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
        panel.begin { [weak self] response in
            guard response == .OK, let url=panel.url else { return }
            guard (try? AppControl.applicationURL(path:url.path)) != nil else {
                self?.actionFeedback="请选择有效的 macOS 应用程序";return
            }
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
                    Text("让妙控鼠标的轻触，成为你习惯的动作。") .foregroundStyle(.secondary)
                }
                Spacer()
                Text("实验版 0.2").font(.caption).padding(7).background(.quaternary,in:Capsule())
            }
            GroupBox {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Label(model.devices.isEmpty ? "鼠标未连接" : "Magic Mouse 已连接",systemImage:model.devices.isEmpty ? "circle" : "checkmark.circle.fill")
                        Spacer()
                        Button("刷新设备") { model.rescan() }
                    }
                    ForEach(model.devices,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(model.enabled ? "暂停识别" : "开始识别") { if model.enabled { model.stop() } else { model.start() } }
                            .buttonStyle(.borderedProminent).disabled(model.devices.isEmpty)
                        Toggle("仅预览，不执行动作",isOn:$model.previewOnly).toggleStyle(.checkbox)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(7)
            }
            GroupBox("轻触动作") {
                VStack(spacing:12) {
                    ForEach(0..<3) { index in
                        VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(["单指轻触","双指轻触","三指轻触"][index]).frame(width:90,alignment:.leading)
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
            Text("轻触前请先抬起所有手指。支持同时落下的 1–3 指；停留、滑动和实体按压会过滤。三指效果取决于鼠标触控上报，仍需实测。")
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
            for i in 0..<n { print("\(tap_device_is_mouse(i) ? "Magic Mouse" : "Ignored"): \(String(cString:tap_device_name(i)))") }
            if CommandLine.arguments.contains("--capture") {
                diagnostic=true;print("Started: \(tap_start(magicTapFrame))")
                RunLoop.main.run(until:Date().addingTimeInterval(5));tap_stop()
                print("Frames: \(diagnosticFrames), peak active contacts: \(diagnosticPeak)")
            }
            return
        }
        MagicTapApp.main()
    }
}
