// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import S400Core

enum MainTab: String, CaseIterable { case overview, records, settings }
enum ClientInputMethod: String, CaseIterable { case json, manual }
struct ProfileDraft: Equatable {
    var includesBodyFat = false
    var birthYear = ""
    var height = ""
    var male = true
    func validated(at date: Date = Date()) throws -> Profile? {
        guard includesBodyFat else { return nil }
        let yearText = birthYear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard date.timeIntervalSinceReferenceDate.isFinite,
              yearText.range(of: "^[0-9]{4}$", options: .regularExpression) != nil,
              let year = Int(yearText), let h = Double(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              h.isFinite, (100...230).contains(h),
              (18...120).contains(Calendar.current.component(.year, from: date) - year) else {
            throw FormError.invalidProfile
        }
        return Profile(birthYear: year, height: h, male: male)
    }
}
enum FormError: LocalizedError {
    case invalidProfile, invalidDevice, invalidThreshold, clientMissing, storeUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidProfile: return "请填写有效的出生年份与身高（100–230 cm），年龄须为 18–120 岁"
        case .invalidDevice: return "请填写原始 MAC 和 32 位十六进制 Bind Key"
        case .invalidThreshold: return "请输入 1–50 的整数百分比"
        case .clientMissing: return "请先配置 Desktop OAuth 客户端"
        case .storeUnavailable: return "本地记录无法读取，接收与同步已暂停"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var bluetoothStatus = "等待恢复设备"
    @Published var cloudStatus = "等待恢复 Google 连接"
    @Published var status = "就绪"
    @Published private(set) var rows: [S400Core.Measurement] = []
    @Published private(set) var receiving = false
    @Published private(set) var syncing = false
    @Published private(set) var hasDevice = false
    @Published private(set) var connected = false
    @Published private(set) var hasClient = false
    @Published private(set) var authorizing = false
    @Published private(set) var isRestoring = true
    @Published private(set) var recoveryUnresolved = true
    @Published private(set) var recoveryStatus = "正在恢复本机凭据"
    @Published private(set) var keychainActivity = CredentialActivity.idle
    @Published private var commandInProgress = false
    @Published private(set) var filterSettings = WeightFilterSettings.default
    @Published private(set) var clientMethod = ClientInputMethod.manual
    @Published var setupStep: Int?
    @Published var selectedTab = MainTab.overview
    @Published private(set) var profileDraft = ProfileDraft()
    let store: MeasurementStore?
    let auth: any GoogleConnecting
    let receiver: any ScaleReceiving
    var sync: SyncEngine?
    private(set) var profile: Profile?
    private let credentials: any CredentialStoring
    private let defaults: UserDefaults
    private let preview: Bool
    private var timer: Timer?
    private var client: OAuthClientConfiguration?
    private var oauthGeneration = UUID()
    private var recoveryGeneration = UUID()
    private var commandGeneration = UUID()
    private var receiverIntent = UUID()
    private var clientNeedsAuthorization = false
    private var devicePresenceKnown = false
    private var deviceRecovered = false
    private var googleRecovered = false
    private var clientRecovered = false
    private var recoveryTask: Task<Void, Never>?
    private var ownedPreviewDirectory: URL?
    var credentialBusy: Bool { keychainActivity.isBusy || commandInProgress || authorizing }
    var deviceRecoveryKnown: Bool { deviceRecovered }
    var googleRecoveryKnown: Bool { googleRecovered }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1" }
    var latestRow: S400Core.Measurement? { rows.last(where: { !$0.isFiltered }) }
    var pendingMeasurements: Int { store?.pendingMeasurementCount ?? 0 }
    var pendingMetrics: Int { store?.pendingMetricCount ?? 0 }
    var blockedMeasurements: Int { store?.blockedMeasurementCount ?? 0 }
    var needsSetup: Bool {
        guard !recoveryUnresolved else { return false }
        if let completed = defaults.object(forKey: "setupCompleted") as? Bool { return !completed }
        return !hasDevice
    }
    var storageAvailable: Bool { store != nil }

    init(preview: Bool = false, defaults suppliedDefaults: UserDefaults? = nil, storeURL: URL? = nil,
         credentials suppliedCredentials: (any CredentialStoring)? = nil,
         authorization: (any GoogleConnecting)? = nil, receiver suppliedReceiver: (any ScaleReceiving)? = nil,
         runTimer: Bool = true) {
        self.preview = preview
        defaults = suppliedDefaults ?? (preview ? EphemeralDefaults() : .standard)
        credentials = suppliedCredentials ?? (preview ? MemoryCredentials() : KeychainCredentials())
        auth = authorization ?? (preview ? PreviewGoogle() : GoogleAuthorization(credentials: credentials))
        receiver = suppliedReceiver ?? (preview ? PreviewReceiver() : BluetoothReceiver())
        let base = preview ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("S400Menu-qa-\(UUID().uuidString)") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("S400Menu")
        if preview && storeURL == nil { ownedPreviewDirectory = base }
        do { store = try MeasurementStore(url: storeURL ?? base.appendingPathComponent("measurements.json")) }
        catch { store = nil; status = FormError.storeUnavailable.localizedDescription }
        if let data = defaults.data(forKey: "profile") { profile = try? JSONDecoder().decode(Profile.self, from: data) }
        if let profile { profileDraft = ProfileDraft(includesBodyFat: true, birthYear: String(profile.birthYear), height: String(profile.height), male: profile.male) }
        if let data = defaults.data(forKey: "weightFilter"), let saved = try? JSONDecoder().decode(WeightFilterSettings.self, from: data) { filterSettings = saved }
        clientMethod = ClientInputMethod(rawValue: defaults.string(forKey: "clientInputMethod") ?? "") ?? .manual
        clientNeedsAuthorization = defaults.bool(forKey: "clientNeedsAuthorization")
        if let hint = defaults.object(forKey: "deviceConfigured") as? Bool {
            hasDevice = hint; devicePresenceKnown = true
        } else if defaults.bool(forKey: "receiverAllowed") {
            hasDevice = true; devicePresenceKnown = true
        }
        // No Security/Keychain or OAuth restore runs in this initializer. The
        // first UI frame can appear even when the system call never returns.
        setupStep = nil
        if let store { sync = SyncEngine(store: store, auth: auth) }
        credentials.onActivityChange = { [weak self] activity in
            guard let self else { return }
            let wasBusy = self.keychainActivity.isBusy
            self.keychainActivity = activity
            if activity.isWaiting { self.recoveryStatus = "钥匙串仍未响应" }
            else if activity.isBusy && self.isRestoring { self.recoveryStatus = "正在恢复本机凭据" }
            else if wasBusy && !activity.isBusy && !self.isRestoring && self.recoveryUnresolved {
                self.recoveryStatus = "系统操作已返回，可重试恢复"
            }
        }
        receiver.onStatus = { [weak self] in self?.bluetoothStatus = $0 }
        receiver.onReading = { [weak self] in self?.accept($0) }
        auth.onChange = { [weak self] in
            guard let self else { return }
            self.connected = self.connected && self.auth.authorized && !self.clientNeedsAuthorization
            if !self.connected && self.syncing { self.pauseSync(); self.cloudStatus = "授权不可用，已暂停同步" }
            self.refresh()
        }
        sync?.onStatus = { [weak self] message in
            guard let self else { return }
            self.cloudStatus = message
            if self.sync?.consent == false { self.syncing = false; self.defaults.set(false, forKey: "uploadAllowed") }
            self.connected = self.connected && self.auth.authorized && !self.clientNeedsAuthorization
            self.refresh()
        }
        refresh()
        if store != nil { scheduleRecovery() }
        else { isRestoring = false; recoveryStatus = FormError.storeUnavailable.localizedDescription }
        if runTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.receiver.tick()
                    if !self.preview && self.syncing { await self.sync?.run(); self.refresh() }
                }
            }
        }
    }
    private func scheduleRecovery() {
        recoveryGeneration = UUID()
        let generation = recoveryGeneration
        isRestoring = true; recoveryUnresolved = true; setupStep = nil
        recoveryStatus = "正在恢复本机凭据"
        recoveryTask = Task { [weak self] in await self?.restoreSavedState(generation) }
    }
    func waitForCredentialRecovery() async { await recoveryTask?.value }
    func retryCredentialRecovery() {
        guard store != nil else { recoveryStatus = FormError.storeUnavailable.localizedDescription; return }
        guard !isRestoring, !credentialBusy else { recoveryStatus = "系统操作尚未返回，暂不能重试"; return }
        scheduleRecovery()
    }
    func cancelCredentialRecovery() {
        recoveryGeneration = UUID(); recoveryTask?.cancel()
        isRestoring = false; recoveryUnresolved = true; setupStep = nil
        recoveryStatus = keychainActivity.isBusy ? "已停止等待，系统操作仍在进行" : "已停止恢复，可稍后重试"
    }
    private func currentRecovery(_ generation: UUID) -> Bool { generation == recoveryGeneration && !Task.isCancelled }
    private func restoreSavedState(_ generation: UUID) async {
        guard currentRecovery(generation), store != nil else { return }
        var failures = false
        if !deviceRecovered {
            do {
                if !devicePresenceKnown {
                    let found = try await credentials.contains("scale")
                    guard currentRecovery(generation) else { return }
                    hasDevice = found; devicePresenceKnown = true
                }
                if hasDevice && defaults.bool(forKey: "receiverAllowed") {
                    let intent = receiverIntent
                    let data = try await credentials.read("scale")
                    guard currentRecovery(generation) else { return }
                    if let data {
                        let config = try JSONDecoder().decode(ScaleCredential.self, from: data)
                        guard S400Decoder.validMAC(config.mac), config.key.count == 16 else { throw ScaleError.invalidInput }
                        if receiverIntent == intent && defaults.bool(forKey: "receiverAllowed") {
                            receiver.start(config); receiving = true
                        }
                    } else {
                        // A successful lookup with no item is known absence,
                        // unlike a system error/wait. Permit explicit reconfiguration.
                        hasDevice = false; bluetoothStatus = "未找到设备凭据，请重新配置"
                    }
                } else { bluetoothStatus = "接收已暂停" }
                deviceRecovered = true
            } catch {
                guard currentRecovery(generation) else { return }
                failures = true; receiving = false; bluetoothStatus = "设备凭据恢复失败，可重试"
            }
        }
        guard currentRecovery(generation) else { return }
        if !googleRecovered {
            do {
                if !clientRecovered {
                    let data = try await credentials.read("google-client")
                    guard currentRecovery(generation) else { return }
                    if let data { client = try JSONDecoder().decode(OAuthClientConfiguration.self, from: data) }
                    hasClient = client != nil; clientRecovered = true
                }
                try await auth.restoreAfterConsent()
                guard currentRecovery(generation) else { return }
                if client == nil { client = auth.existingClientConfiguration() }
                if let sessionClient = auth.existingClientConfiguration(), let client, sessionClient != client { clientNeedsAuthorization = true }
                hasClient = client != nil; connected = auth.authorized && !clientNeedsAuthorization
                cloudStatus = connected ? "已连接 Google Health" : hasClient ? "需要连接 Google Health" : "尚未连接 Google Health"
                googleRecovered = true
                if defaults.bool(forKey: "uploadAllowed"), connected {
                    sync?.consent = true; syncing = true; cloudStatus = "自动同步已启用"
                }
            } catch {
                guard currentRecovery(generation) else { return }
                failures = true; connected = false; syncing = false; sync?.consent = false
                cloudStatus = "Google 凭据恢复失败，可重试"
            }
        }
        guard currentRecovery(generation) else { return }
        isRestoring = false; recoveryUnresolved = failures
        recoveryStatus = failures ? "凭据恢复未完成，可重试" : "本机凭据已恢复"
        if !failures { resolveSetupRoute() }
        refresh()
    }
    private func resolveSetupRoute() {
        if defaults.object(forKey: "setupCompleted") == nil, hasDevice { setupStep = nil }
        else if defaults.bool(forKey: "setupCompleted") || defaults.bool(forKey: "setupDeferred") { setupStep = nil }
        else {
            setupStep = hasDevice ? max(1, min(3, defaults.integer(forKey: "setupStep"))) : 1
            defaults.set(false, forKey: "setupCompleted")
            defaults.set(setupStep!, forKey: "setupStep")
        }
    }
    private func beginCredentialCommand() -> UUID? {
        guard !isRestoring, !credentialBusy else { status = "钥匙串操作尚未完成，请稍候"; return nil }
        commandInProgress = true; commandGeneration = UUID(); return commandGeneration
    }
    private func finishCredentialCommand(_ generation: UUID) { if generation == commandGeneration { commandInProgress = false } }
    private func currentCommand(_ generation: UUID) -> Bool { generation == commandGeneration && !Task.isCancelled }
    func refresh() { rows = store?.rows.filter { !$0.simulated } ?? []; objectWillChange.send() }
    func accept(_ reading: FinalReading) {
        guard let store, receiving else { return }
        do {
            switch try store.insertWithResult(Measurement(reading: reading, profile: profile, simulated: false), filter: filterSettings) {
            case .added, .filtered: status = "称重已保存"
            case .duplicate: status = "重复称重已忽略"
            }
            refresh()
        } catch ScaleError.invalidInput { status = "无效体重已忽略" }
        catch { receiver.stop(); receiving = false; sync?.consent = false; syncing = false; status = "本地保存失败，接收与同步已暂停" }
    }
    @discardableResult func saveDevice(mac: String, bindKey: String) async -> Bool {
        let address = mac.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard store != nil else { status = FormError.storeUnavailable.localizedDescription; return false }
        guard S400Decoder.validMAC(address), let key = Data(hex: bindKey.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 16 else { status = FormError.invalidDevice.localizedDescription; return false }
        guard let command = beginCredentialCommand() else { return false }
        defer { finishCredentialCommand(command) }
        let intent = receiverIntent
        do {
            let config = ScaleCredential(mac: address, key: key)
            try await credentials.save(JSONEncoder().encode(config), name: "scale")
            guard currentCommand(command) else { return false }
            hasDevice = true; devicePresenceKnown = true; deviceRecovered = true; defaults.set(true, forKey: "deviceConfigured")
            if receiverIntent == intent {
                defaults.set(true, forKey: "receiverAllowed"); receiving = true; receiver.start(config)
            }
            status = "设备已保存"; return true
        } catch { status = "设备保存未完成，请检查钥匙串状态"; return false }
    }
    func startSavedReceiver() async {
        guard store != nil else { status = FormError.storeUnavailable.localizedDescription; return }
        guard let command = beginCredentialCommand() else { return }
        defer { finishCredentialCommand(command) }
        receiverIntent = UUID(); let intent = receiverIntent
        do {
            guard let data = try await credentials.read("scale") else { status = "请先配置设备"; return }
            guard currentCommand(command), intent == receiverIntent else { return }
            let config = try JSONDecoder().decode(ScaleCredential.self, from: data)
            guard S400Decoder.validMAC(config.mac), config.key.count == 16 else { throw ScaleError.invalidInput }
            receiver.start(config); receiving = true; deviceRecovered = true; defaults.set(true, forKey: "receiverAllowed")
        } catch { receiving = false; status = "设备凭据读取失败，可重试" }
    }
    func stopReceiver() { receiverIntent = UUID(); receiver.stop(); receiving = false; defaults.set(false, forKey: "receiverAllowed") }
    @discardableResult func saveProfile(_ draft: ProfileDraft) -> Bool {
        do {
            let next = try draft.validated()
            if let next { defaults.set(try JSONEncoder().encode(next), forKey: "profile") } else { defaults.removeObject(forKey: "profile") }
            profile = next; profileDraft = draft; status = "测量方式已保存"; return true
        } catch { status = error.localizedDescription; return false }
    }
    @discardableResult func saveFilter(enabled: Bool, threshold: String) -> Bool {
        let text = threshold.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Int
        if !enabled { value = filterSettings.thresholdPercent }
        else {
            guard text.range(of: "^[0-9]{1,2}$", options: .regularExpression) != nil, let parsed = Int(text) else { status = FormError.invalidThreshold.localizedDescription; return false }
            value = parsed
        }
        do {
            let next = try WeightFilterSettings(enabled: enabled, thresholdPercent: value)
            defaults.set(try JSONEncoder().encode(next), forKey: "weightFilter"); filterSettings = next; status = "体重变化检测已保存"; return true
        } catch { status = FormError.invalidThreshold.localizedDescription; return false }
    }
    @discardableResult func saveClient(_ next: OAuthClientConfiguration, method: ClientInputMethod) async -> Bool {
        guard let command = beginCredentialCommand() else { return false }
        defer { finishCredentialCommand(command) }
        do {
            try await credentials.save(JSONEncoder().encode(next), name: "google-client")
            guard currentCommand(command) else { return false }
            let changed = client != next
            client = next; clientRecovered = true; hasClient = true; clientMethod = method; defaults.set(method.rawValue, forKey: "clientInputMethod")
            if changed {
                cancelOAuth(); pauseSync(); googleRecovered = false
                clientNeedsAuthorization = true; defaults.set(true, forKey: "clientNeedsAuthorization"); connected = false
                do { try await auth.disconnect() }
                catch { status = "客户端已保存，移除旧授权未完成，请重试"; return true }
            }
            status = changed ? "客户端已保存，请连接 Google Health" : "客户端已保存"
            cloudStatus = connected ? cloudStatus : "等待连接 Google Health"; return true
        } catch { status = "客户端保存未完成，请检查钥匙串状态"; return false }
    }
    func beginOAuth(confirmed: Bool) async {
        guard confirmed, store != nil, !authorizing else { return }
        guard let client else { status = FormError.clientMissing.localizedDescription; return }
        guard !isRestoring, !credentialBusy else { status = "请等待钥匙串操作完成"; return }
        if syncing { pauseSync() }
        // A system write started by OAuth cannot be withdrawn. Until this exact
        // flow reports successful persistence, a late archive must not become
        // an accepted connection on the next launch, including same-client reauth.
        clientNeedsAuthorization = true
        defaults.set(true, forKey: "clientNeedsAuthorization")
        connected = false
        let generation = UUID(); oauthGeneration = generation; authorizing = true
        do {
            try await auth.begin(clientID: client.clientID, clientSecret: client.clientSecret) { [weak self] success in
                guard let self, self.oauthGeneration == generation else { return }
                self.authorizing = false
                if success {
                    self.clientNeedsAuthorization = false; self.defaults.set(false, forKey: "clientNeedsAuthorization")
                    self.connected = self.auth.authorized; self.googleRecovered = true
                    self.cloudStatus = "已连接，尚未开启同步"; self.status = "连接成功"
                } else { self.connected = false; self.cloudStatus = "授权未完成，请重试"; self.status = "连接未完成" }
            }
        } catch { if oauthGeneration == generation { authorizing = false; cloudStatus = "连接无法启动，请检查客户端配置"; status = cloudStatus } }
    }
    func cancelOAuth() { oauthGeneration = UUID(); auth.cancel(); authorizing = false }
    func enableSync(confirmed: Bool) {
        guard confirmed, store != nil, connected, !clientNeedsAuthorization, !isRestoring, !credentialBusy else { status = "请先完成 Google 连接恢复"; return }
        sync?.consent = true; syncing = true; defaults.set(true, forKey: "uploadAllowed"); cloudStatus = "自动同步已启用"
        if !preview { Task { await sync?.run(); refresh() } }
    }
    func pauseSync() { sync?.consent = false; syncing = false; defaults.set(false, forKey: "uploadAllowed"); cloudStatus = "同步已暂停" }
    func retrySync() { guard syncing, connected, !preview, !credentialBusy else { return }; Task { await sync?.run(); refresh() } }
    @discardableResult func disconnectGoogle() async -> Bool {
        guard let command = beginCredentialCommand() else { return false }
        defer { finishCredentialCommand(command) }
        cancelOAuth(); pauseSync()
        do {
            try await auth.disconnect()
            guard currentCommand(command) else { return false }
            connected = false; googleRecovered = true; cloudStatus = "已断开 Google Health"; return true
        } catch { status = "移除本机授权未完成，可重试"; return false }
    }
    func advanceSetup() { guard let step = setupStep else { return }; if step == 1, !hasDevice { return }; setupStep = min(3, step + 1); defaults.set(setupStep!, forKey: "setupStep"); defaults.set(false, forKey: "setupCompleted") }
    func previousSetupStep() { guard let step = setupStep else { return }; setupStep = max(1, step - 1); defaults.set(setupStep!, forKey: "setupStep") }
    func completeSetup() async {
        if needsSetup, hasDevice, !receiving { await startSavedReceiver() }
        defaults.set(true, forKey: "setupCompleted"); defaults.set(false, forKey: "setupDeferred"); setupStep = nil; selectedTab = .overview
    }
    func deferSetup() {
        if setupStep != nil || needsSetup { defaults.set(false, forKey: "setupCompleted"); stopReceiver() }
        cancelOAuth(); defaults.set(true, forKey: "setupDeferred"); setupStep = nil; selectedTab = .overview
    }
    func continueSetup() { guard !recoveryUnresolved, !isRestoring else { return }; defaults.set(false, forKey: "setupDeferred"); defaults.set(false, forKey: "setupCompleted"); setupStep = hasDevice ? max(1, min(3, defaults.integer(forKey: "setupStep"))) : 1 }
    func quit() { NSApp.terminate(nil) }
    func cleanupPreview() { guard preview else { return }; timer?.invalidate(); cancelCredentialRecovery(); if let ownedPreviewDirectory { try? FileManager.default.removeItem(at: ownedPreviewDirectory) } }
}
