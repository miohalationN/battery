import SwiftUI
import Observation

/// SyncTab 的视图状态模型（@Observable 说明见 CycleTabModel）。
/// 由 AppDelegate 持有：config 在 app 启动时从 DataStore 载入一次，
/// 窗口关闭重开不重置表单。
@Observable
final class SyncTabModel {
    var config = DataStore.shared.currentConfig()
    var testing = false
    var testResult: String?
    var password = ""
    var refreshInterval: Int = 1
    // 密码防抖：用户停止输入 0.6s 后才写入 Keychain，避免每次按键都触发 SecItem 操作
    var passwordDebounceTask: Task<Void, Never>?
}

struct SyncTab: View {
    @ObservedObject var syncEngine: SyncEngine
    @Bindable var model: SyncTabModel

    // 读侧透传：body 内沿用原属性名，改动面最小
    private var config: SyncConfig { model.config }
    private var testing: Bool { model.testing }
    private var testResult: String? { model.testResult }
    private var password: String { model.password }
    private var refreshInterval: Int { model.refreshInterval }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                refreshSection

                HStack {
                    Image(systemName: config.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(config.isEnabled ? .green : .secondary)
                    Text("启用 WebDAV 同步").font(.headline)
                    Spacer()
                    Toggle("", isOn: $model.config.isEnabled).labelsHidden().onChange(of: config.isEnabled) { save() }
                }
                .padding(20)
                .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }

                if config.isEnabled {
                    configWarning
                    serverSection
                    settingsSection
                    statusSection
                    actionButtons
                }
            }
            .padding(20)
        }
        .onAppear {
            // 从 DataStore 恢复用户上次设置的刷新间隔
            model.refreshInterval = Int(DataStore.shared.currentRefreshInterval())
            // 预填密码（用于测试连接 / 同步），从 Keychain 读取
            if let pw = KeychainHelper.getPassword(for: config.username) { model.password = pw }
        }
    }

    // MARK: - 刷新频率

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.blue)
                Text("数据刷新").font(.headline)
                Spacer()
                HStack(spacing: 0) {
                    Button { if model.refreshInterval > 1 { model.refreshInterval -= 1; applyRefreshInterval() } } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Text("\(refreshInterval)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(width: 36)

                    Button { if model.refreshInterval < 30 { model.refreshInterval += 1; applyRefreshInterval() } } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Text("秒").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    private func applyRefreshInterval() {
        DataStore.shared.updateRefreshInterval(Double(model.refreshInterval))
        NotificationCenter.default.post(name: .init("RefreshIntervalChanged"), object: Double(model.refreshInterval))
    }

    // MARK: - Server

    /// 启用同步但服务器地址/用户名/密码未填全时的警告（password 含 Keychain 预填）
    @ViewBuilder
    private var configWarning: some View {
        if config.serverURL.isEmpty || config.username.isEmpty || model.password.isEmpty {
            Label("配置不完整：请填写服务器地址、用户名与密码，否则同步不会执行", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)) }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("服务器配置", systemImage: "server.rack").font(.headline)
            glassField("服务器地址", text: $model.config.serverURL, placeholder: "https://dav.jianguoyun.com/dav/")
            glassField("用户名", text: $model.config.username, placeholder: "username")
            glassField("远程路径", text: $model.config.remotePath, placeholder: "/BatteryBar")
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(.secondary)
                SecureField("密码", text: $model.password).textFieldStyle(.plain).font(.system(size: 13))
                    .onChange(of: model.password) { schedulePasswordSave() }
            }
            .padding(10).background { RoundedRectangle(cornerRadius: 10).fill(.quaternary) }

            HStack {
                Button { model.testing = true; model.testResult = nil; Task { await testConnection(); model.testing = false } } label: {
                    HStack(spacing: 6) { if testing { ProgressView().controlSize(.mini) } else { Image(systemName: "network") }; Text("测试连接") }
                }
                .disabled(testing || config.serverURL.isEmpty).buttonStyle(.bordered)
                if let r = testResult { Text(r).font(.caption).foregroundStyle(r.contains("✅") ? .green : .red) }
            }
        }
        .padding(20)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    /// 密码防抖：停止输入 0.6s 后才写入 Keychain。
    /// 避免每次按键都触发 SecItem 操作（涉及 Keychain daemon IPC，开销大）。
    private func schedulePasswordSave() {
        model.passwordDebounceTask?.cancel()
        let pw = model.password
        let user = model.config.username
        guard !pw.isEmpty else { return }
        model.passwordDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            try? KeychainHelper.setPassword(pw, for: user)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("同步设置", systemImage: "gearshape").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("同步间隔").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $model.config.syncInterval) { ForEach(SyncInterval.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: config.syncInterval) { save() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("同步方向").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $model.config.syncDirection) { ForEach(SyncDirection.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: config.syncDirection) { save() }
            }
        }
        .padding(20)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("同步状态", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            HStack {
                Text("上次同步").foregroundStyle(.secondary); Spacer()
                if let last = config.lastSyncAt { Text(last, format: .dateTime.month().day().hour().minute()).font(.system(size: 13, design: .rounded).monospacedDigit()) }
                else { Text("尚未同步").foregroundStyle(.tertiary) }
            }
            // 实时同步状态（由共享 SyncEngine @Published state 驱动）
            HStack {
                Text("当前状态").foregroundStyle(.secondary); Spacer()
                syncStateLabel
            }
            HStack {
                Text("设备 ID").foregroundStyle(.secondary); Spacer()
                Text(config.deviceID).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .padding(20)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    @ViewBuilder
    private var syncStateLabel: some View {
        switch syncEngine.state {
        case .idle:
            Text("空闲").font(.system(size: 13)).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("同步中…").font(.system(size: 13)).foregroundStyle(.blue)
            }
        case .success(let date):
            Text("成功 \(date, format: .dateTime.hour().minute().second())")
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(.green)
        case .failed(let msg):
            Text("失败：\(msg)").font(.system(size: 12)).foregroundStyle(.red).lineLimit(1)
        }
    }

    private var actionButtons: some View {
        HStack {
            Button {
                Task { await syncEngine.sync(config: model.config); model.config.lastSyncAt = Date(); save() }
            } label: {
                HStack(spacing: 6) {
                    if case .syncing = syncEngine.state {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("立即同步")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(config.serverURL.isEmpty || (syncEngine.state == .syncing))
            Spacer()
        }
    }

    private func glassField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13))
                .padding(8).background { RoundedRectangle(cornerRadius: 10).fill(.quaternary) }
                .onChange(of: text.wrappedValue) { save() }
        }
    }

    private func save() { DataStore.shared.updateConfig(model.config) }

    private func testConnection() async {
        guard let url = URL(string: model.config.serverURL) else { model.testResult = "❌ 无效的 URL"; return }
        let pw = KeychainHelper.getPassword(for: model.config.username) ?? model.password
        guard !pw.isEmpty else { model.testResult = "❌ 请先输入密码"; return }
        let client = WebDAVClient(baseURL: url, username: model.config.username, password: pw)
        do { _ = try await client.listFiles(at: model.config.remotePath); model.testResult = "✅ 连接成功" }
        catch { model.testResult = "❌ \(error.localizedDescription)" }
    }
}
