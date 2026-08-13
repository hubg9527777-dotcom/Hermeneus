import SwiftUI
import AppKit

@main
struct AILiveInterpreterApp: App {
    @StateObject private var orchestrator = PipelineOrchestrator()
    @StateObject private var offlineTools = OfflineToolsPrototypeController()

    var body: some Scene {
        WindowGroup("Hermeneus", id: "live-interpreter") {
            SubtitleView(
                orchestrator: orchestrator,
                offlineTools: offlineTools
            )
            .background(WindowAccessor())
            .onAppear { Task { await orchestrator.startSession() } }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Window("离线工具", id: "offline-tools") {
            OfflineToolsPrototypeView(
                orchestrator: orchestrator,
                controller: offlineTools,
                meetingRecorder: orchestrator.meetingRecorder
            )
            .background(OfflineWindowAccessor())
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                
                // 1. 解禁原生 macOS 窗口的 8 方向 (上下左右 + 四个角) 拉伸权限
                window.styleMask = [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                
                // 2. 点击顶部标题栏或任意背景区域即可直接拖拽移动窗口
                window.isMovableByWindowBackground = true
                
                // 3. 确保交互响应正常
                window.ignoresMouseEvents = false
                window.level = .floating
                window.showsResizeIndicator = true
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


struct OfflineWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask = [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView]
            window.title = "Hermeneus · 离线工具"
            // Keep the title-bar glass and system window controls visible, while the SwiftUI content
            // supplies an opaque readable surface below it.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.level = .normal
            window.minSize = NSSize(width: 640, height: 520)
            if window.frame.size.width < 640 || window.frame.size.height < 520 {
                window.setContentSize(NSSize(width: 740, height: 720))
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
