import SwiftUI

struct SyncTab: View {
    @ObservedObject var syncEngine: SyncEngine
    @Environment(PowerSampler.self) private var sampler
    @Environment(LoginItemState.self) private var loginItem
    @State private var config = DataStore.shared.currentConfig()
    @State private var testing = false
    @State private var testResult: String?
    @State private var password = ""
    @State private var localSnapshotCount = 0
    @State private var localRecordCount = 0
    @State private var loginItemError: String?
    // 密码防抖：用户停止输入 0.6s 后才写入 Keychain，避免每次按键都触发 SecItem 操作
    @State private var passwordDebounceTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                PageHeader(
                    title: "数据与设置",
                    subtitle: "应用设置、自动采样节奏与安全备份",
                    systemImage: "arrow.triangle.branch",
                    tint: .bbPurple,
                    badge: config.isEnabled ? "WebDAV 已启用" : "仅本机"
                )
                appSettingsSection
                autoSamplingSection
                localDataSection
                syncToggleCard
                if config.isEnabled {
                    configWarning
                    serverSection
                    settingsSection
                    statusSection
                    actionButtons
                }
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.top, 46)
            .padding(.bottom, BBDesign.pagePadding)
        }
        .onAppear {
            reloadLocalCounts()
            // 页面重新出现时刷新登录项真实状态（用户可能在系统设置中改动）
            loginItem.refresh()
            password = KeychainHelper.getPassword(
                serverURL: config.serverURL,
                username: config.username,
                allowLegacyMigration: true
            ) ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
            reloadLocalCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batteryCyclesDidChange)) { _ in
            reloadLocalCounts()
        }
    }

    // MARK: - 应用设置（开机自启动）

    /// 与右键菜单共用同一 LoginItemState；requiresApproval 时不得假装已开启。
    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "应用设置", systemImage: "gearshape.fill", tint: .bbPurple)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开机时自动启动").font(.system(size: 12, weight: .medium))
                    Text(loginItem.statusSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(loginItem.needsApproval ? .orange : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { loginItem.isOn },
                    set: { newValue in
                        loginItemError = loginItem.setEnabled(newValue)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(loginItem.status == .notFound)
            }

            if loginItem.needsApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("已在登录项中提出请求，需要在系统设置的登录项里允许后才会生效")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("打开系统设置") { loginItem.openApprovalSettings() }
                        .controlSize(.small)
                }
                .foregroundStyle(.orange)
            }
            if let message = loginItemError {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .glassCard(accent: .bbPurple)
    }

    // MARK: - 自动采样（只读说明）

    /// 用户语言描述采样行为；精确秒数与最近读取时间属于排障细节，
    /// 收进默认折叠的「采样诊断」，不暗示传感器按固定频率更新。
    private var autoSamplingSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "自动采样", systemImage: "arrow.clockwise.circle.fill", tint: .bbBlue)
            VStack(spacing: 7) {
                cadenceRow("读数界面打开时自动提高读取频率，后台自动降低占用", value: "自动", tint: .bbBlue)
                cadenceRow("功率和温度何时变化取决于 macOS 驱动", value: "系统决定", tint: .secondary)
                cadenceRow("历史数据每分钟记录一次", value: "每分钟", tint: .bbTeal)

                DisclosureGroup("采样诊断") {
                    VStack(spacing: 7) {
                        cadenceRow("前台兜底读取", value: "每 \(Int(SamplingCadence.foregroundInterval)) 秒", tint: .secondary)
                        cadenceRow("后台保活读取", value: "每 \(Int(SamplingCadence.backgroundInterval)) 秒", tint: .secondary)
                        cadenceRow("历史记录落盘", value: "每 \(Int(SamplingCadence.historyInterval)) 秒", tint: .secondary)
                        cadenceRow(
                            "CPU / GPU 分项",
                            value: sampler.helperEnabled
                                ? "独立每 \(Int(SamplingCadence.componentPowerInterval)) 秒"
                                : "关闭（零采样）",
                            tint: sampler.helperEnabled ? .bbAmber : .secondary
                        )
                        cadenceRow("电源插拔 / 低电量模式 / 热压力", value: "系统事件立即读取", tint: .secondary)
                        PollingHeartbeat(sampler: sampler)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 10))
            }

            Divider().opacity(0.45)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .padding(.top, 1)
                Text("相邻两次读数相同代表驱动尚未发布新值，不是应用停止工作。")
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
        .glassCard(accent: .bbBlue)
    }

    private func cadenceRow(_ label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    // MARK: - 启用开关

    private var syncToggleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: config.isEnabled ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 17))
                .foregroundStyle(config.isEnabled ? Color.bbMint : Color.secondary)
            Text("启用 WebDAV 同步").font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: $config.isEnabled).labelsHidden().onChange(of: config.isEnabled) {
                save(reconfigureSchedule: true)
            }
        }
        .glassCard(accent: config.isEnabled ? .bbMint : .clear)
    }

    private var localDataSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "本机数据", systemImage: "internaldrive.fill", tint: .bbTeal)
            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "waveform.path.ecg", tint: .bbBlue,
                         value: "\(localSnapshotCount)", unit: "点", label: "历史采样")
                StatTile(icon: "list.bullet.rectangle", tint: .bbTeal,
                         value: "\(localRecordCount)", unit: "条", label: "离电记录")
                StatTile(icon: "clock.arrow.circlepath", tint: .bbAmber,
                         value: "24", unit: "小时", label: "采样保留")
            }
            Text("未启用 WebDAV 时，全部数据只保存在这台 Mac；历史采样每分钟写入一次。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .glassCard(accent: .bbTeal)
    }

    private func reloadLocalCounts() {
        localSnapshotCount = DataStore.shared.allSnapshots().count
        localRecordCount = OffPowerRecordAnalyzer.displayableRecords(from: DataStore.shared.allCycles()).count
    }

    // MARK: - 配置不完整警告

    /// 启用同步但服务器地址/用户名/密码未填全时的警告（password 含 Keychain 预填）
    @ViewBuilder
    private var configWarning: some View {
        if let warning = configurationWarningText {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(warning)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - 服务器配置

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "服务器配置", systemImage: "server.rack", tint: .bbPurple)
            glassField("服务器地址", text: $config.serverURL, placeholder: "https://dav.jianguoyun.com/dav/")
                .onChange(of: config.serverURL) { credentialIdentityDidChange() }
            glassField("用户名", text: $config.username, placeholder: "username")
                .onChange(of: config.username) { credentialIdentityDidChange() }
            glassField("远程路径", text: $config.remotePath, placeholder: "/BatteryBar")
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.tertiary)
                SecureField("密码", text: $password).textFieldStyle(.plain).font(.system(size: 12))
                    .onChange(of: password) { schedulePasswordSave() }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))

            HStack {
                Button { testing = true; testResult = nil; Task { await testConnection(); testing = false } } label: {
                    HStack(spacing: 6) { if testing { ProgressView().controlSize(.mini) } else { Image(systemName: "network") }; Text("测试连接") }
                }
                .disabled(testing || config.serverURL.isEmpty).buttonStyle(.bordered)
                if let r = testResult {
                    Text(r).font(.system(size: 10)).foregroundStyle(r.contains("✅") ? .green : .red)
                }
            }
        }
        .glassCard(accent: .bbPurple)
    }

    /// 密码防抖：停止输入 0.6s 后才写入 Keychain。
    /// 避免每次按键都触发 SecItem 操作（涉及 Keychain daemon IPC，开销大）。
    private func schedulePasswordSave() {
        passwordDebounceTask?.cancel()
        let pw = password
        let serverURL = config.serverURL
        let user = config.username
        guard !pw.isEmpty else { return }
        passwordDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            try? KeychainHelper.setPassword(pw, serverURL: serverURL, username: user)
        }
    }

    private func credentialIdentityDidChange() {
        passwordDebounceTask?.cancel()
        password = KeychainHelper.getPassword(serverURL: config.serverURL, username: config.username) ?? ""
        testResult = nil
    }

    // MARK: - 同步设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "同步设置", systemImage: "gearshape", tint: .bbTeal)
            VStack(alignment: .leading, spacing: 8) {
                Text("同步间隔").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $config.syncInterval) { ForEach(SyncInterval.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: config.syncInterval) {
                        save(reconfigureSchedule: true)
                    }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("同步方向").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $config.syncDirection) { ForEach(SyncDirection.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: config.syncDirection) { save() }
            }
        }
        .glassCard(accent: .bbTeal)
    }

    // MARK: - 同步状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "同步状态", systemImage: "arrow.triangle.2.circlepath", tint: .bbMint)
            statusRow("上次同步") {
                if let last = config.lastSyncAt {
                    Text(last, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                } else {
                    Text("尚未同步").foregroundStyle(.tertiary)
                }
            }
            // 实时同步状态（由共享 SyncEngine @Published state 驱动）
            statusRow("当前状态") { syncStateLabel }
            statusRow("设备 ID") {
                Text(config.deviceID)
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .glassCard(accent: .bbMint)
    }

    private func statusRow<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            value().font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var syncStateLabel: some View {
        switch syncEngine.state {
        case .idle:
            HStack(spacing: 5) {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("空闲").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .syncing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("同步中…").font(.system(size: 12)).foregroundStyle(.blue)
            }
        case .success(let date):
            HStack(spacing: 5) {
                Circle().fill(Color.bbMint).frame(width: 6, height: 6)
                Text("成功 \(date, format: .dateTime.hour().minute().second())")
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbMint)
            }
        case .failed(let msg):
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("失败：\(msg)").font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button {
                Task {
                    if let completedAt = await syncEngine.sync(config: config) {
                        config.lastSyncAt = completedAt
                    }
                }
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
            .disabled(!serverURLIsAllowed || (syncEngine.state == .syncing))
            Spacer()
        }
    }

    private func glassField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12))
                .padding(9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .onChange(of: text.wrappedValue) { save() }
        }
    }

    private func save(reconfigureSchedule: Bool = false) {
        DataStore.shared.updateConfig(config)
        if reconfigureSchedule {
            syncEngine.applySchedule(config: config)
        }
    }

    private var serverURLIsAllowed: Bool {
        guard let url = URL(string: config.serverURL) else { return false }
        return (try? WebDAVEndpointPolicy.validate(url)) != nil
    }

    private var configurationWarningText: String? {
        if config.serverURL.isEmpty || config.username.isEmpty || password.isEmpty {
            return "配置不完整：请填写服务器地址、用户名与密码，否则同步不会执行"
        }
        guard let url = URL(string: config.serverURL) else {
            return "服务器地址无效"
        }
        do {
            try WebDAVEndpointPolicy.validate(url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func testConnection() async {
        guard let url = URL(string: config.serverURL) else { testResult = "❌ 无效的 URL"; return }
        do { try WebDAVEndpointPolicy.validate(url) }
        catch { testResult = "❌ \(error.localizedDescription)"; return }
        let pw = password
        guard !pw.isEmpty else { testResult = "❌ 请先输入密码"; return }
        let client = WebDAVClient(baseURL: url, username: config.username, password: pw)
        do { _ = try await client.listFiles(at: config.remotePath); testResult = "✅ 连接成功" }
        catch { testResult = "❌ \(error.localizedDescription)" }
    }
}

/// 只让这一行跟随每次成功轮询失效，避免设置页其余表单每秒重建；同时给用户一个
/// 可核对的“定时器确实在走”证据，和底层传感器是否产生新值明确分开。
private struct PollingHeartbeat: View {
    let sampler: PowerSampler

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.bbBlue).frame(width: 5, height: 5)
            Text("上次成功读取").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(sampler.lastUpdateTime, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        }
    }
}
