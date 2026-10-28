// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import S400Core

@MainActor struct AppShellView: View {
    @ObservedObject var model: AppModel
    @State private var sheet: SheetRoute?
    @State private var selectedRecord: S400Core.Measurement?
    @State private var cancelOAuthOnDismiss = false
    @State private var connectAfterClientSave = false
    @State private var previousSheet: SheetRoute?
    @State private var finishingSetup = false
    @State private var disconnecting = false
    @State private var disconnectGeneration = UUID()
    enum SheetRoute: String, Identifiable {
        case device, replaceDevice, deviceEditor, profile, filter, client, oauth, enableSync, connection, disconnect
        case help, deviceHelp, googleHelp, about, licenses, record, deferSetup
        var id: String { rawValue }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isRestoring || model.recoveryUnresolved || model.credentialBusy { credentialStatus }
                    if let step = model.setupStep { onboarding(step) }
                    else {
                        switch model.selectedTab {
                        case .overview: overview
                        case .records: records
                        case .settings: settings
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.setupStep == nil { Divider(); navigation }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 360, idealWidth: 390, maxWidth: 440, minHeight: 520, idealHeight: 620)
        .sheet(item: $sheet, onDismiss: {
            if cancelOAuthOnDismiss && model.authorizing { model.cancelOAuth() }
            cancelOAuthOnDismiss = false
        }) { route in sheetContent(route) }
        .onChange(of: sheet) { next in
            if previousSheet == .oauth && next != .oauth && model.authorizing { model.cancelOAuth() }
            previousSheet = next
        }
        .onAppear {
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scalemass").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.setupStep == nil ? pageTitle : "欢迎使用 WeighDock").font(.headline)
                if model.setupStep != nil || model.selectedTab == .overview {
                    Text(model.setupStep == nil ? "体重同步" : "首次配置").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
    private var pageTitle: String {
        switch model.selectedTab { case .overview: return "WeighDock"; case .records: return "称重记录"; case .settings: return "设置" }
    }
    private var navigation: some View {
        HStack(spacing: 0) {
            navButton("概览", symbol: "scalemass", tab: .overview)
            navButton("记录", symbol: "clock.arrow.circlepath", tab: .records)
            navButton("设置", symbol: "gearshape", tab: .settings)
        }.padding(.vertical, 11)
    }
    private func navButton(_ label: String, symbol: String, tab: MainTab) -> some View {
        Button { model.selectedTab = tab } label: {
            VStack(spacing: 4) { Image(systemName: symbol); Text(label).font(.caption) }.frame(maxWidth: .infinity)
                .foregroundStyle(model.selectedTab == tab ? Color.accentColor : Color.secondary)
        }.buttonStyle(.plain).accessibilityIdentifier("tab-\(label)")
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                StatusPill(title: receiverPillTitle, active: model.receiving && model.bluetoothStatus == "正在接收 S400")
                StatusPill(title: cloudPillTitle, active: model.syncing && !model.cloudStatus.contains("重试"))
            }
            if let row = model.latestRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最新称重").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(row.weight, format: .number.precision(.fractionLength(1))).font(.system(size: 54, weight: .light, design: .rounded)).monospacedDigit()
                        Text("kg").font(.title3).foregroundStyle(.secondary)
                    }
                    Text(row.fat.map { String(format: "体脂估算 %.1f%%", $0) } ?? "仅体重").font(.subheadline)
                    Text(dateText(row.date)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            } else {
                EmptyState(symbol: "scalemass", title: deviceStateUnknown ? "等待本机凭据" : model.hasDevice ? "准备好了" : "添加你的体脂秤", detail: deviceStateUnknown ? "可先查看本地记录与设置" : model.hasDevice ? "等待下一次称重\n让 Mac 保持唤醒并靠近体脂秤" : "先配置设备，再开始接收称重")
            }
            if model.needsSetup && !credentialStateUnknown {
                Button("继续配置") { model.continueSetup() }.buttonStyle(.borderedProminent).accessibilityIdentifier("continue-setup")
            }
            cloudCard
            AppCard {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("小米 S400").font(.subheadline.weight(.medium))
                        Text(model.bluetoothStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 5)
                    if model.hasDevice {
                        Button(model.receiving ? "暂停" : "恢复") { toggleReceiver() }.buttonStyle(.borderless).disabled(credentialActionsUnavailable && !model.receiving)
                    } else if !deviceStateUnknown { Button("配置") { model.continueSetup() }.buttonStyle(.borderless).disabled(credentialActionsUnavailable) }
                }
            }
            if !["就绪", "真实记录已保存", "重复记录已忽略"].contains(model.status) && !model.status.contains("偏差") {
                Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var cloudCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "cloud").foregroundStyle(model.connected ? Color.blue : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(googleStateUnknown ? (model.isRestoring ? "正在恢复本机连接" : "本机连接尚未恢复") : model.connected ? (model.pendingMeasurements > 0 ? "待同步 \(model.pendingMeasurements) 次称重" : "暂无待同步称重") : (model.hasClient ? "Google 授权需要更新" : "连接 Google Health"))
                            .font(.subheadline.weight(.medium))
                        Text(googleStateUnknown ? "连接状态尚未确认" : model.connected ? model.cloudStatus : "记录保留在本机").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 5)
                    Button(googleStateUnknown ? "等待恢复" : !model.connected ? "连接" : model.syncing ? "暂停" : "恢复") { syncAction() }.buttonStyle(.borderless).disabled(credentialActionsUnavailable && !model.syncing)
                }
                if model.pendingMeasurements > 0 && model.connected {
                    Text("\(model.pendingMetrics) 个指标分别确认同步").font(.caption2).foregroundStyle(.secondary)
                }
                if model.blockedMeasurements > 0 {
                    Text("\(model.blockedMeasurements) 次称重需要检查，可在记录中查看").font(.caption).foregroundStyle(.orange)
                }
                if model.syncing && model.cloudStatus.contains("重试") {
                    Button("重试连接") { model.retrySync() }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本地 \(model.rows.count) 次称重").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.pendingMeasurements > 0 ? "待同步 \(model.pendingMeasurements) 次" : "暂无待同步").font(.caption).foregroundStyle(.secondary)
            }
            if model.rows.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "还没有称重记录", detail: "收到的称重会显示在这里")
            }
            ForEach(Array(model.rows.reversed())) { row in
                Button {
                    selectedRecord = row; sheet = .record
                } label: {
                    AppCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: row.isFiltered ? "exclamationmark.circle" : "scalemass").foregroundStyle(row.isFiltered ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(String(format: "%.1f kg", row.weight)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(dateText(row.date)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(row.fat.map { String(format: "体脂 %.1f%%", $0) } ?? "仅体重").font(.caption).foregroundStyle(.primary)
                                    if !row.isFiltered { Text(recordState(row)).font(.caption2).foregroundStyle(recordState(row) == "已同步" ? Color.green : Color.secondary) }
                                }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if row.isFiltered { Text("体重偏差较大，未同步").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("record-\(row.id)")
            }
            if !model.rows.isEmpty { Text("每次称重合并显示，点开可看各项同步进度。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("设备与资料")
            AppCard {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "scalemass").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("小米 S400").font(.subheadline)
                            Text(deviceStateUnknown ? "等待恢复" : model.hasDevice ? model.bluetoothStatus : "尚未配置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("蓝牙接收", isOn: Binding(get: { model.receiving }, set: { wanted in if wanted { Task { await model.startSavedReceiver() } } else { model.stopReceiver() } }))
                            .labelsHidden().toggleStyle(.switch).disabled((!model.hasDevice || credentialActionsUnavailable) && !model.receiving).accessibilityLabel("蓝牙接收")
                    }.padding(.vertical, 6)
                    Divider().padding(.vertical, 10)
                    SettingLink("测量方式与资料", subtitle: model.profileDraft.includesBodyFat ? "体重与体脂估算" : "仅体重", symbol: "person") { sheet = .profile }
                    Divider().padding(.vertical, 10)
                    SettingLink("设备凭据", subtitle: deviceStateUnknown ? "等待恢复" : model.hasDevice ? "已保存 · 不显示密钥" : "尚未配置", symbol: "key") { sheet = model.hasDevice ? .device : .deviceEditor }.disabled(credentialActionsUnavailable)
                }
            }
            sectionLabel("Google Health")
            AppCard {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动同步").font(.subheadline)
                            Text(googleStateUnknown ? "等待恢复" : !model.connected ? "尚未连接" : model.syncing ? "已启用" : "已暂停").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("自动同步", isOn: Binding(get: { model.syncing }, set: { wanted in if wanted { syncAction() } else { model.pauseSync() } }))
                            .labelsHidden().toggleStyle(.switch).disabled(credentialActionsUnavailable && !model.syncing).accessibilityLabel("自动同步")
                    }
                    Divider().padding(.vertical, 10)
                    SettingLink(googleStateUnknown ? "Google 连接" : model.connected ? "管理连接" : "连接 Google Health", subtitle: "只写入体重与有效体脂", symbol: "cloud") {
                        if model.connected { sheet = .connection } else { connect() }
                    }.disabled(credentialActionsUnavailable)
                    Divider().padding(.vertical, 10)
                    SettingLink("OAuth 客户端", subtitle: googleStateUnknown && !model.hasClient ? "等待恢复" : model.hasClient ? (model.clientMethod == .json ? "JSON 导入" : "手动填写") : "尚未配置", symbol: "doc.badge.gearshape") { openClient() }.disabled(credentialActionsUnavailable)
                }
            }
            sectionLabel("偏好")
            AppCard {
                VStack(spacing: 0) {
                    SettingLink("体重变化检测", subtitle: model.filterSettings.enabled ? "开启 · 超过 \(model.filterSettings.thresholdPercent)% 不予同步" : "已关闭") { sheet = .filter }
                    Divider().padding(.vertical, 10)
                    SettingLink("使用帮助") { sheet = .help }
                    Divider().padding(.vertical, 10)
                    SettingLink("关于与隐私") { sheet = .about }
                }
            }
            HStack { Spacer(); Button("退出应用") { model.quit() }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary); Spacer() }
        }
    }
    private func onboarding(_ step: Int) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 6) { ForEach(1...3, id: \.self) { index in Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 3) } }
                .accessibilityLabel("第 \(step) 步，共 3 步")
            Text("0\(step) / \(["添加设备", "选择测量方式", "连接 Google Health"][min(max(step - 1, 0), 2)])").font(.caption).foregroundStyle(.secondary)
            switch step {
            case 1:
                Text("让体脂秤连上 Mac").font(.title2.weight(.semibold))
                Text("只添加你自己的 S400，凭据保存在本机。").font(.subheadline).foregroundStyle(.secondary)
                if model.hasDevice {
                    AppCard { Label("小米 S400 · 已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button("更换设备…") { sheet = .replaceDevice }.buttonStyle(.borderless).disabled(credentialActionsUnavailable)
                    HStack { Button("取消配置") { sheet = .deferSetup }; Spacer(); Button("继续") { model.advanceSetup() }.buttonStyle(.borderedProminent) }
                } else {
                    DeviceEditor(model: model, inline: true, cancel: { sheet = .deferSetup }, saved: { model.advanceSetup() })
                }
                Button("MAC 和 Bind Key 是什么？") { sheet = .deviceHelp }.buttonStyle(.borderless).font(.caption)
            case 2:
                Text("你想记录什么？").font(.title2.weight(.semibold))
                Text("先用体重就好，体脂也可以稍后开启。").font(.subheadline).foregroundStyle(.secondary)
                ProfileEditor(model: model, inline: true, cancel: { model.previousSetupStep() }, saved: { model.advanceSetup() })
            default:
                Text("把称重送到 Google").font(.title2.weight(.semibold))
                Text("也可以先留在本机，之后再连接。").font(.subheadline).foregroundStyle(.secondary)
                AppCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.hasClient ? "Desktop 客户端已准备" : "添加 Desktop OAuth 客户端", systemImage: model.hasClient ? "checkmark.circle" : "doc")
                        Button(model.hasClient ? "更换客户端配置" : "添加客户端") { openClient() }.buttonStyle(.borderless).disabled(credentialActionsUnavailable)
                    }
                }
                if model.connected { Text("已授权，尚未同步").font(.subheadline).foregroundStyle(.green) }
                Button("如何准备 Google Health？") { sheet = .googleHelp }.buttonStyle(.borderless).font(.caption)
                HStack {
                    Button("上一步") { model.previousSetupStep() }
                    Spacer()
                    Button(model.connected ? "开启同步" : "连接 Google Health") { if model.connected { sheet = .enableSync } else { connect() } }
                        .buttonStyle(.borderedProminent).disabled(!model.hasClient || model.authorizing || credentialActionsUnavailable)
                }
                Button(finishingSetup ? "正在完成配置…" : model.connected ? "暂不开启同步" : "暂不连接") { finishSetup() }.buttonStyle(.borderless).disabled(finishingSetup || credentialActionsUnavailable).frame(maxWidth: .infinity)
            }
        }
    }
    @ViewBuilder private func sheetContent(_ route: SheetRoute) -> some View {
        switch route {
        case .profile: ProfileEditor(model: model, cancel: close, saved: close)
        case .filter: FilterEditor(model: model, cancel: close, saved: close)
        case .client:
            OAuthClientEditor(model: model, cancel: close, saved: {
                if connectAfterClientSave {
                    connectAfterClientSave = false
                    cancelOAuthOnDismiss = true
                    sheet = .oauth
                } else { close() }
            })
        case .deviceEditor: DeviceEditor(model: model, cancel: close, saved: close)
        case .device:
            SheetFrame(title: "设备已配置", close: close) {
                Text("小米 S400 · 已保存").font(.headline)
                Text("凭据保存在本机钥匙串，日常不用重复填写。").foregroundStyle(.secondary)
                Button("更换设备…") { sheet = .replaceDevice }.disabled(credentialActionsUnavailable)
                Button("完成", action: close).buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .replaceDevice:
            SheetFrame(title: "更换设备？", close: close) {
                Text("更换设备不会删除称重记录或 Google 连接。")
                actionBar(cancel: "取消", confirm: "确认更换", cancelAction: { sheet = .device }, confirmDisabled: credentialActionsUnavailable, action: { sheet = .deviceEditor })
            }
        case .oauth:
            OAuthConsentView(model: model, cancel: close)
                .onDisappear { if model.authorizing { model.cancelOAuth() } }
        case .enableSync:
            SheetFrame(title: "开启自动同步？", close: close) {
                Text(model.pendingMeasurements > 0 ? "将本机待同步的 \(model.pendingMeasurements) 次称重及之后的真实体重与有效体脂直接写入 Google Health。" : "将之后的真实体重与有效体脂直接写入 Google Health。")
                Text("可随时暂停，已保存的本地记录不受影响。").font(.caption).foregroundStyle(.secondary)
                actionBar(cancel: "暂不开启", confirm: "确认开启", cancelAction: close, confirmDisabled: credentialActionsUnavailable || finishingSetup) {
                    model.enableSync(confirmed: true)
                    if model.syncing { if model.setupStep != nil { finishSetup(closeCurrentSheet: true) } else { close() } }
                }
                if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
            }
        case .connection:
            SheetFrame(title: "Google Health", close: close) {
                detail("连接状态", value: model.connected ? "已授权" : "未连接")
                detail("上传范围", value: "体重 · 有效体脂")
                Text("断开连接会暂停上传、移除本机授权。不会删除本地或已上传的记录。").font(.caption).foregroundStyle(.secondary)
                actionBar(cancel: "返回", confirm: "断开连接", cancelAction: close, confirmDisabled: credentialActionsUnavailable) { sheet = .disconnect }
            }
        case .disconnect:
            SheetFrame(title: "断开 Google Health？", close: close) {
                Text("本地接收继续，新的称重先保存在 Mac。")
                if disconnecting { Text("正在移除本机授权，返回不会撤销已发起的操作。").font(.caption).foregroundStyle(.secondary) }
                actionBar(cancel: disconnecting ? "返回" : "取消", confirm: disconnecting ? "处理中…" : "确认断开", cancelAction: { disconnectGeneration = UUID(); sheet = .connection }, confirmDisabled: credentialActionsUnavailable || disconnecting) { disconnect() }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        case .record:
            if let selectedRecord { recordDetail(model.rows.first(where: { $0.id == selectedRecord.id }) ?? selectedRecord) }
        case .help:
            SheetFrame(title: "称重后，交给 Mac", close: close) {
                Text("保持 Mac 唤醒，并放在体脂秤的蓝牙范围内。锁屏可继续接收，睡眠期间无法接收。")
                Text("只支持一人使用；体重接近的其他人仍可能被记录。")
                Button("知道了", action: close).buttonStyle(.borderedProminent)
            }
        case .deviceHelp:
            SheetFrame(title: "设备需要两项资料", close: close) {
                Text("原始 MAC 是解密输入，CoreBluetooth 的 UUID 不能替代它。")
                Text("Bind Key 是秤的 BLE 密钥，请使用这台秤的配对资料。")
                Button("返回配置", action: close).buttonStyle(.borderedProminent)
            }
        case .googleHelp:
            SheetFrame(title: "先准备 Google Health", close: close) {
                Text("先在 Google Health 移动应用关联账号，再准备启用 Health API 的 Desktop OAuth 客户端。")
                Text("可导入客户端 JSON，或填写 Client ID 和 Client Secret。连接后再开启同步。")
                Button("返回", action: close).buttonStyle(.borderedProminent)
            }
        case .about:
            SheetFrame(title: "WeighDock", close: close) {
                Text("版本 \(model.appVersion)").font(.caption).foregroundStyle(.secondary)
                Text("独立开源 macOS 工具，非小米或 Google 官方产品。体脂来自公式估算。")
                Text("健康记录保存在本机；启用同步后直接发送至 Google Health。凭据保存在钥匙串。")
                Text("删除本机授权不会删除称重记录或已上传数据。").font(.caption).foregroundStyle(.secondary)
                Button("开源许可与归属") { sheet = .licenses }.buttonStyle(.borderless)
                Button("完成", action: close).buttonStyle(.borderedProminent)
            }
        case .licenses:
            SheetFrame(title: "开源许可与归属", close: close) {
                Text(licenseText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("返回关于") { sheet = .about }
            }
        case .deferSetup:
            SheetFrame(title: "稍后继续配置？", close: close) {
                Text(model.credentialBusy ? "凭据操作仍在处理，返回不会撤销已发起的保存。" : "接收和同步暂不启用，之后可继续配置。")
                actionBar(cancel: "继续填写", confirm: "稍后配置", cancelAction: close) { model.deferSetup(); close() }
            }
        }
    }
    private func recordDetail(_ row: S400Core.Measurement) -> some View {
        SheetFrame(title: "称重详情", close: close) {
            Text(dateText(row.date, detail: true)).font(.caption).foregroundStyle(.secondary)
            detail(String(format: "体重 %.1f kg", row.weight), value: row.isFiltered ? "未同步" : metricState(row.deliveries["weight"]?.state))
            if let fat = row.fat { detail(String(format: "体脂估算 %.1f%%", fat), value: row.isFiltered ? "未同步" : metricState(row.deliveries["body-fat"]?.state)) }
            if let exclusion = row.exclusion {
                Text("体重偏差较大，未同步").foregroundStyle(.orange)
                Text("当时阈值 \(exclusion.thresholdPercent)% · 比较基线 \(String(format: "%.1f", exclusion.baselineWeight)) kg").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("体重与有效体脂保留独立上传进度。").font(.caption).foregroundStyle(.secondary)
                if row.deliveries.values.contains(where: { $0.state == "blocked" }) {
                    Text("此项尚未确认成功，请检查授权与 API 配置。不会自动重复创建。").font(.caption).foregroundStyle(.orange)
                }
            }
            Button("完成", action: close).buttonStyle(.borderedProminent)
        }
    }
    private var licenseText: String {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return "WeighDock：GPL-3.0-or-later。\nopenScale 协议改编：GPL-3.0-or-later。\nBodyMiScale 米家兼容公式、Google GTMAppAuth、AppAuth、GTMSessionFetcher：Apache-2.0。\n完整许可与归属随源码及发行包提供。"
        }
        return files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "\(url.lastPathComponent)\n\n\(text)"
        }.joined(separator: "\n\n————————\n\n")
    }
    private var credentialStateUnknown: Bool { model.isRestoring || model.recoveryUnresolved }
    private var deviceStateUnknown: Bool { credentialStateUnknown && !model.deviceRecoveryKnown && !model.receiving }
    private var googleStateUnknown: Bool { credentialStateUnknown && !model.googleRecoveryKnown && !model.connected && !model.syncing }
    private var credentialActionsUnavailable: Bool { credentialStateUnknown || model.credentialBusy }
    private var credentialStatusTitle: String {
        guard credentialStateUnknown else { return "正在处理本机凭据" }
        if !model.recoveryStatus.isEmpty { return model.recoveryStatus }
        return model.isRestoring ? "正在恢复本机凭据" : "本机凭据尚未恢复"
    }
    private var credentialStatus: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if model.isRestoring || model.credentialBusy { ProgressView().controlSize(.small) }
                    Text(credentialStatusTitle)
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if model.isRestoring {
                    Button("停止等待") { model.cancelCredentialRecovery() }.buttonStyle(.borderless).font(.caption)
                } else if model.recoveryUnresolved && model.credentialBusy {
                    Text("系统读取尚未返回，暂不能重试").font(.caption).foregroundStyle(.secondary)
                } else if model.recoveryUnresolved {
                    Button("重试恢复") { model.retryCredentialRecovery() }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }
    private func finishSetup(closeCurrentSheet: Bool = false) {
        guard !finishingSetup, !credentialActionsUnavailable else { return }
        finishingSetup = true
        let previous = sheet
        Task {
            await model.completeSetup()
            finishingSetup = false
            if closeCurrentSheet && sheet == previous { close() }
        }
    }
    private func disconnect() {
        guard !disconnecting, !credentialActionsUnavailable else { return }
        disconnecting = true
        let generation = UUID(); disconnectGeneration = generation
        Task {
            guard generation == disconnectGeneration else { disconnecting = false; return }
            let success = await model.disconnectGoogle()
            disconnecting = false
            guard generation == disconnectGeneration, sheet == .disconnect else { return }
            if success { close() }
        }
    }
    private var receiverPillTitle: String {
        if deviceStateUnknown { return "等待恢复" }
        guard model.receiving else { return "接收已暂停" }
        return model.bluetoothStatus == "正在接收 S400" ? "正在接收" : "等待蓝牙"
    }
    private var cloudPillTitle: String {
        if googleStateUnknown { return "等待恢复" }
        guard model.connected else { return "未连接 Google" }
        guard model.syncing else { return "同步已暂停" }
        return model.cloudStatus.contains("重试") ? "等待重试" : "自动同步中"
    }
    private func syncAction() {
        if !model.connected { connect() } else if model.syncing { model.pauseSync() } else { sheet = .enableSync }
    }
    private func connect() {
        guard !credentialActionsUnavailable else { return }
        if model.hasClient { cancelOAuthOnDismiss = true; sheet = .oauth }
        else { openClient(connectAfterSave: true) }
    }
    private func toggleReceiver() { if model.receiving { model.stopReceiver() } else { Task { await model.startSavedReceiver() } } }
    private func openClient(connectAfterSave: Bool = false) {
        guard !credentialActionsUnavailable else { return }
        connectAfterClientSave = connectAfterSave
        sheet = .client
    }
    private func close() {
        if sheet == .oauth && model.authorizing { model.cancelOAuth() }
        if sheet == .disconnect { disconnectGeneration = UUID() }
        connectAfterClientSave = false
        sheet = nil
    }
    private func dateText(_ date: Date, detail: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = detail ? "yyyy年M月d日 HH:mm:ss" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
    private func detail(_ title: String, value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) } }
    private func actionBar(cancel: String, confirm: String, cancelAction: @escaping () -> Void, confirmDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack { Button(cancel, action: cancelAction).keyboardShortcut(.cancelAction); Spacer(); Button(confirm, action: action).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(confirmDisabled) }
    }
    private func recordState(_ row: S400Core.Measurement) -> String {
        if row.isFiltered { return "体重偏差较大，未同步" }
        let states = row.deliveries.values.map(\.state)
        if states.contains("blocked") { return "待检查" }
        if states.contains("operation") { return "云端处理中" }
        return !states.isEmpty && states.allSatisfy { $0 == "synced" } ? "已同步" : "待同步"
    }
    private func metricState(_ state: String?) -> String {
        switch state { case "synced": return "已同步"; case "operation": return "云端处理中"; case "blocked": return "待检查"; default: return "待同步" }
    }
}

private struct StatusPill: View {
    let title: String
    let active: Bool
    var body: some View { HStack(spacing: 5) { Circle().fill(active ? Color.green : Color.secondary).frame(width: 5, height: 5); Text(title).font(.caption2) }.padding(.horizontal, 9).padding(.vertical, 7).background(Color.secondary.opacity(0.07)).clipShape(Capsule()) }
}
private struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous)) }
}
private struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View { VStack(spacing: 11) { Image(systemName: symbol).font(.system(size: 29, weight: .light)).foregroundStyle(.secondary); Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 24) }
}
private struct SettingLink: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    let action: () -> Void
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, action: @escaping () -> Void) { self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline).foregroundStyle(.primary); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) } }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
private struct SheetFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }.buttonStyle(.plain).accessibilityLabel("关闭") }.padding(22)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 18) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(22) }
        }.frame(width: 360, height: 500)
            .background(Color(nsColor: .windowBackgroundColor)).onExitCommand(perform: close)
    }
}

@MainActor private struct DeviceEditor: View {
    @ObservedObject var model: AppModel
    var inline = false
    let cancel: () -> Void
    let saved: () -> Void
    @State private var mac = ""
    @State private var key = ""
    @State private var error = ""
    @State private var saving = false
    @State private var hasSubmitted = false
    @State private var generation = UUID()
    var body: some View {
        Group {
            if inline { fields }
            else { SheetFrame(title: "设备凭据", close: leave) { fields } }
        }.onDisappear { generation = UUID(); mac = ""; key = "" }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) { Text("原始设备 MAC").font(.caption); TextField("AA:BB:CC:11:22:33", text: $mac).textFieldStyle(.roundedBorder).accessibilityIdentifier("device-mac") }.disabled(saving)
            VStack(alignment: .leading, spacing: 6) { Text("BLE Bind Key").font(.caption); SecureField("32 位十六进制", text: $key).textFieldStyle(.roundedBorder).accessibilityIdentifier("device-key") }.disabled(saving)
            Text(saving || (hasSubmitted && model.credentialBusy) ? "保存仍在处理，返回不会撤销已发起的保存。" : "保存到本机钥匙串，并开始接收称重。").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("device-error") }
            HStack {
                Button(hasSubmitted ? "返回" : inline ? "取消配置" : "取消", action: leave).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "保存中…" : inline ? "保存并继续" : "保存并接收", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-device")
                    .disabled(saving || model.credentialBusy || model.isRestoring || model.recoveryUnresolved)
            }
        }
    }
    private func leave() { generation = UUID(); cancel() }
    private func save() {
        guard !saving, !model.credentialBusy, !model.isRestoring, !model.recoveryUnresolved else { return }
        let address = mac, secret = key, requestGeneration = generation
        hasSubmitted = true; saving = true; error = ""
        Task {
            guard requestGeneration == generation else { saving = false; return }
            let success = await model.saveDevice(mac: address, bindKey: secret)
            saving = false
            guard requestGeneration == generation else { return }
            if success { mac = ""; key = ""; saved() } else { error = model.status }
        }
    }
}

@MainActor private struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    var inline = false
    let cancel: () -> Void
    let saved: () -> Void
    @State private var draft = ProfileDraft()
    @State private var error = ""
    var body: some View {
        Group { if inline { fields } else { SheetFrame(title: "测量方式与资料", close: cancel) { fields } } }
            .onAppear { draft = model.profileDraft }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker("测量方式", selection: $draft.includesBodyFat) {
                Text("仅体重").tag(false)
                Text("体重与体脂估算").tag(true)
            }.pickerStyle(.radioGroup)
            if draft.includesBodyFat {
                LabeledField(title: "出生年份", placeholder: "例如 1990", value: $draft.birthYear)
                LabeledField(title: "身高 · cm", placeholder: "100–230", value: $draft.height)
                Picker("体脂公式性别", selection: $draft.male) { Text("男").tag(true); Text("女").tag(false) }.pickerStyle(.segmented)
                Text("体脂是公式估算，与米家可能不同。").font(.caption).foregroundStyle(.secondary)
            } else { Text("无需个人资料。当前仅支持一人使用，不会自动识别称重者。").font(.caption).foregroundStyle(.secondary) }
            if !inline { Text("不会重算已有记录。").font(.caption).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("profile-error") }
            HStack {
                Button(inline ? "上一步" : "取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(inline ? "继续" : "保存资料") { if model.saveProfile(draft) { saved() } else { error = model.status } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-profile")
            }
        }
    }
}
private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption); TextField(placeholder, text: $value).textFieldStyle(.roundedBorder).accessibilityLabel(title) } }
}

@MainActor private struct FilterEditor: View {
    @ObservedObject var model: AppModel
    let cancel: () -> Void
    let saved: () -> Void
    @State private var enabled = true
    @State private var threshold = "10"
    @State private var error = ""
    var body: some View {
        SheetFrame(title: "体重变化检测", close: cancel) {
            Toggle("检测体重变化", isOn: $enabled).toggleStyle(.switch).accessibilityIdentifier("filter-enabled")
            HStack {
                Text("偏差超过")
                TextField("10", text: $threshold).textFieldStyle(.roundedBorder).frame(width: 55).disabled(!enabled).accessibilityLabel("偏差阈值百分比").accessibilityIdentifier("filter-threshold")
                Text("% 不予同步")
            }
            Text("1–50%，仅限整数；恰好达到阈值时不拦截。").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("filter-error") }
            Text(enabled ? "超过阈值的称重仅保留在记录中，不进入同步。" : "关闭后，新称重不再按体重偏差过滤。").font(.caption).foregroundStyle(.secondary)
            Text("已过滤的记录不会自动补传。").font(.caption).foregroundStyle(.secondary)
            Button("恢复默认") { enabled = true; threshold = "10"; error = "" }.buttonStyle(.borderless)
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { if model.saveFilter(enabled: enabled, threshold: threshold) { saved() } else { error = model.status } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-filter")
            }
        }.onAppear { enabled = model.filterSettings.enabled; threshold = String(model.filterSettings.thresholdPercent) }
    }
}

@MainActor private struct OAuthClientEditor: View {
    @ObservedObject var model: AppModel
    let cancel: () -> Void
    let saved: () -> Void
    @State private var method: ClientInputMethod = .json
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showSecret = false
    @State private var imported: OAuthClientConfiguration?
    @State private var fileReady = false
    @State private var error = ""
    @State private var saving = false
    @State private var hasSubmitted = false
    @State private var generation = UUID()
    var body: some View {
        SheetFrame(title: "OAuth 客户端", close: leave) {
            Picker("配置方式", selection: $method) { Text("JSON 导入").tag(ClientInputMethod.json); Text("手动填写").tag(ClientInputMethod.manual) }.pickerStyle(.segmented).accessibilityIdentifier("client-method").disabled(saving)
            if method == .json {
                AppCard {
                    VStack(spacing: 12) {
                        Image(systemName: fileReady ? "checkmark.circle" : "doc").font(.title2).foregroundStyle(fileReady ? Color.green : Color.secondary)
                        Text(fileReady ? "Desktop 客户端已准备" : "选择 Desktop OAuth 客户端 JSON").font(.caption).multilineTextAlignment(.center)
                        Button(fileReady ? "重新选择" : "选择 JSON 文件", action: selectJSON).accessibilityIdentifier("import-client-json").disabled(saving)
                    }.frame(maxWidth: .infinity)
                }
            } else {
                LabeledField(title: "Client ID", placeholder: "…apps.googleusercontent.com", value: $clientID).disabled(saving)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Client Secret").font(.caption)
                    HStack {
                        Group { if showSecret { TextField("Client Secret", text: $clientSecret) } else { SecureField("Client Secret", text: $clientSecret) } }.textFieldStyle(.roundedBorder).accessibilityIdentifier("client-secret").disabled(saving)
                        Button(showSecret ? "隐藏" : "显示") { showSecret.toggle() }.buttonStyle(.borderless).font(.caption).accessibilityLabel(showSecret ? "隐藏 Client Secret" : "显示 Client Secret").disabled(saving)
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("client-error") }
            Text(saving || (hasSubmitted && model.credentialBusy) ? "保存仍在处理，返回不会撤销已发起的保存。" : model.connected ? "配置保存在本机钥匙串。更换客户端后需要重新连接。" : "配置保存在本机钥匙串。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(hasSubmitted ? "返回" : "取消", action: leave).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "保存中…" : "保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-client").disabled(saving || model.credentialBusy || model.isRestoring || model.recoveryUnresolved)
            }
        }.onAppear { method = model.hasClient ? model.clientMethod : .json }
            .onChange(of: method) { _ in error = "" }
            .onDisappear { generation = UUID(); clientID = ""; clientSecret = ""; imported = nil }
    }
    private func leave() { generation = UUID(); cancel() }
    private func selectJSON() {
        guard !saving else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Desktop OAuth 客户端 JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= OAuthClientConfiguration.maximumJSONBytes else { throw OAuthClientConfiguration.ValidationError.oversizedJSON }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: OAuthClientConfiguration.maximumJSONBytes + 1) ?? Data()
            imported = try OAuthClientConfiguration.parseDesktopJSON(data)
            fileReady = true; error = ""
        } catch let validation as OAuthClientConfiguration.ValidationError { imported = nil; fileReady = false; error = validation.localizedDescription }
        catch { imported = nil; fileReady = false; self.error = "无法读取 JSON 文件" }
    }
    private func save() {
        guard !saving, !model.credentialBusy, !model.isRestoring, !model.recoveryUnresolved else { return }
        do {
            let value: OAuthClientConfiguration
            if method == .json {
                guard let imported else { error = "请选择客户端 JSON 文件"; return }
                value = imported
            } else { value = try OAuthClientConfiguration(clientID: clientID, clientSecret: clientSecret) }
            let requestMethod = method, requestGeneration = generation
            hasSubmitted = true; saving = true; error = ""
            Task {
                guard requestGeneration == generation else { saving = false; return }
                let success = await model.saveClient(value, method: requestMethod)
                saving = false
                guard requestGeneration == generation else { return }
                if success { saved() } else { error = model.status }
            }
        } catch let validation as OAuthClientConfiguration.ValidationError { error = validation.localizedDescription }
        catch { self.error = "请检查客户端配置" }
    }
}

@MainActor private struct OAuthConsentView: View {
    @ObservedObject var model: AppModel
    let cancel: () -> Void
    @State private var profileReady = false
    @State private var connecting = false
    @State private var generation = UUID()
    var body: some View {
        SheetFrame(title: "连接 Google Health", close: leave) {
            if model.connected {
                Label("已授权，尚未开启同步", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text("由你决定何时开始上传。").foregroundStyle(.secondary)
                Button("完成", action: leave).buttonStyle(.borderedProminent)
            } else {
                Text("仅允许写入体重与有效体脂，授权保存在本机钥匙串。")
                Toggle("此账号已开通 Google Health", isOn: $profileReady)
                if model.authorizing || connecting {
                    HStack { ProgressView().controlSize(.small); Text(model.credentialBusy ? "正在处理本机授权" : "在浏览器中完成授权").font(.caption) }
                    if model.credentialBusy { Text("系统处理仍在继续，返回不会撤销已发起的保存。").font(.caption).foregroundStyle(.secondary) }
                    Button(model.credentialBusy ? "返回" : "取消授权", action: leave).keyboardShortcut(.cancelAction)
                } else {
                    Text(model.cloudStatus).font(.caption).foregroundStyle(.secondary)
                    if model.credentialBusy { Text("系统处理仍在继续，返回不会撤销已发起的保存。").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(model.credentialBusy ? "返回" : "取消", action: leave).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("在浏览器中连接") {
                            guard !connecting, !model.credentialBusy, !model.isRestoring, !model.recoveryUnresolved else { return }
                            connecting = true
                            let requestGeneration = generation
                            Task {
                                guard requestGeneration == generation else { connecting = false; return }
                                await model.beginOAuth(confirmed: profileReady)
                                connecting = false
                            }
                        }.disabled(!profileReady || connecting || model.credentialBusy || model.isRestoring || model.recoveryUnresolved).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("begin-oauth")
                    }
                }
            }
        }.onDisappear { generation = UUID() }
    }
    private func leave() {
        generation = UUID()
        if model.authorizing { model.cancelOAuth() }
        cancel()
    }
}
