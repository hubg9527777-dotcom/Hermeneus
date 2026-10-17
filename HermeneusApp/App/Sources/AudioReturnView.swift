import SwiftUI
import TTSKit

@MainActor
private final class AudioReturnState: ObservableObject {
    @Published var devices: [AudioOutputDevice] = []
    @Published var selectedUID = AudioOutputDevice.systemDefault
    @Published var status = ""
    @Published var testing = false
    @Published var testTask: Task<Void, Never>?
}

struct AudioReturnView: View {
    let engine: BlackHoleTTSEngine
    let close: () -> Void
    @StateObject private var state = AudioReturnState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("语音回传设备").font(.title2.bold())
            Text("选择合成西语要送往的设备。这里只改变 Hermeneus 的播报输出，不改变电脑的系统音频设备。")
            Picker("输出到", selection: $state.selectedUID) {
                Text("本机播放 · 系统默认输出").tag(AudioOutputDevice.systemDefault)
                ForEach(state.devices) { device in
                    Text(device.name + (device.isLoopback ? " · 会议回传" : "")).tag(device.id)
                }
                if state.selectedUID != AudioOutputDevice.systemDefault && !state.devices.contains(where: { $0.id == state.selectedUID }) {
                    Text("之前选择的设备已断开").tag(state.selectedUID)
                }
            }.disabled(state.testing)
            HStack {
                Button("刷新设备") { refresh() }.disabled(state.testing)
                Link("安装 BlackHole 2ch（官网）", destination: URL(string: "https://existential.audio/blackhole/")!)
            }
            if state.devices.first(where: { $0.id == state.selectedUID })?.isLoopback == true {
                Text("下一步：在 Zoom、Teams 或其他会议软件的“麦克风 / 输入设备”中选择同名的 BlackHole。会议的扬声器保持耳机或原来的输出设备。")
                Text("点击测试后，查看会议软件的麦克风音量条是否跳动，或请对方确认听到测试语音。BlackHole 本身不会从扬声器播放声音。")
            } else {
                Text("本机扬声器或耳机只能用于本地听译；会议软件要收到译音，请选择 BlackHole 等虚拟回传设备，并在会议软件中选择同名输入。")
            }
            Text("没有 BlackHole 时，点击官网下载安装包，双击安装并按系统提示确认；如要求重新打开应用，请照提示操作，然后刷新设备。无需终端配置。")
                .font(.callout).foregroundStyle(.secondary)
            if !state.status.isEmpty { Text(state.status).textSelection(.enabled) }
            HStack {
                if state.testing {
                    ProgressView().controlSize(.small)
                    Button("停止测试") { state.testTask?.cancel() }
                } else {
                    Button("向所选设备发送测试语音") {
                        state.testing = true
                        state.status = "正在向所选设备发送测试语音…"
                        state.testTask = Task { @MainActor in
                            defer { state.testing = false }
                            do {
                                if state.devices.first(where: { $0.id == state.selectedUID })?.isLoopback == true {
                                    _ = try await AudioReturnProbe.test(engine: engine, deviceUID: state.selectedUID)
                                    state.status = "已在 BlackHole 输入收到测试语音，应用内回传链路通过。请再确认会议软件的音量条或对方反馈。"
                                } else {
                                    try await engine.testOutput(to: state.selectedUID)
                                    state.status = "本机测试语音已播放完成。用于会议回传时，请选择 BlackHole。"
                                }
                            } catch is CancellationError { state.status = "测试已停止。" }
                            catch { state.status = error.localizedDescription }
                        }
                    }
                }
                Spacer()
                Button("确认并返回") {
                    Task {
                        do { try await engine.selectDevice(state.selectedUID); close() }
                        catch { state.status = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(state.testing)
            }
        }
        .padding(28).frame(width: 680)
        .onAppear { refresh() }
        .onDisappear { state.testTask?.cancel() }
    }
    private func refresh() {
        state.devices = AudioOutputDevice.available()
        let saved = engine.selectedDeviceUID
        state.selectedUID = UserDefaults.standard.string(forKey: AudioOutputDevice.preferenceKey) == nil
            ? (state.devices.first(where: { $0.isLoopback })?.id ?? saved) : saved
    }
}
