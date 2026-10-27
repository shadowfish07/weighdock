// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreBluetooth
import AppKit
import S400Core

// CoreBluetooth callbacks run on the explicitly supplied main queue.
@MainActor final class BluetoothReceiver: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var credential: ScaleCredential?
    private var wanted = false
    private var session = S400Session()
    private var seen = [Data: Date]()
    var onStatus: ((String) -> Void)?
    var onReading: ((FinalReading) -> Void)?
    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func willSleep() {
        guard wanted else { return }
        central?.stopScan(); session = S400Session(); seen = [:]; onStatus?("Mac 睡眠，接收暂停")
    }
    @objc private func didWake() { scanIfReady() }
    func start(_ credential: ScaleCredential) {
        // A replaced device must never complete a partial session from the old
        // scale. Resume is also an explicit new receiving session.
        session = S400Session(); seen = [:]
        self.credential = credential; wanted = true
        if central == nil {
            // Delayed creation prevents a Bluetooth permission request on first app launch.
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else { scanIfReady() }
    }
    func stop() {
        wanted = false; central?.stopScan(); credential = nil; seen = [:]; session = S400Session()
        onStatus?("接收已停止")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { scanIfReady() }
    private func scanIfReady() {
        guard wanted, let central else { return }
        switch central.state {
        case .poweredOn:
            // Unfiltered scan accommodates regional firmware advertising FE95 or 181B
            // service data without listing that UUID in the advertised service list.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            onStatus?("正在接收 S400")
        case .unauthorized: onStatus?("蓝牙权限未允许")
        case .poweredOff: onStatus?("蓝牙已关闭")
        case .unsupported: onStatus?("蓝牙不可用")
        default: onStatus?("蓝牙准备中")
        }
    }
    func tick() {
        if let result = session.expire(now: Date()) { onReading?(result) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wanted, let credential,
              let services = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] else { return }
        // peripheral.identifier is never used as the raw MAC. Authentication selects the scale.
        for (uuid, data) in services where ["181B", "FE95"].contains(uuid.uuidString.uppercased()) {
            guard [24, 26].contains(data.count) else { continue }
            let now = Date()
            seen = seen.filter { now.timeIntervalSince($0.value) < 90 }
            if seen[data] != nil { continue }
            guard let packet = try? S400Decoder.decode(data, mac: credential.mac, key: credential.key) else { continue }
            seen[data] = now
            if let expired = session.expire(now: now) { onReading?(expired) }
            if let reading = session.ingest(packet, now: now) { onReading?(reading) }
        }
    }
}
