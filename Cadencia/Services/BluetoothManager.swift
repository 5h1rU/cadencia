import Foundation
import CoreBluetooth
import Observation
import CadenciaCore

/// Discovers and drives the three device roles a trainer ride needs: a smart trainer (FTMS), a heart
/// rate band and, optionally, a separate power meter. Parsing and control-point encoding live in
/// `CadenciaCore`; this class only moves bytes over CoreBluetooth and publishes live values.
@Observable
final class BluetoothManager: NSObject {
    enum Role: String, CaseIterable, Identifiable {
        case trainer, heartRate, powerMeter
        var id: String { rawValue }
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        var name: String
        var roles: Set<Role>
        var rssi: Int
    }

    struct Connection: Equatable {
        let id: UUID
        var name: String
        var role: Role
        var isReady: Bool
        var batteryPercent: Int?
    }

    struct Live: Equatable {
        var watts: Int?
        var heartRate: Int?
        var cadence: Int?
        var speedKmh: Double?
        var updatedAt: Date?
    }

    private(set) var isPoweredOn = false
    private(set) var isScanning = false
    private(set) var discovered: [Discovered] = []
    private(set) var connections: [Role: Connection] = [:]
    private(set) var live = Live()
    private(set) var ergAcknowledged = false
    private(set) var lastControlError: String?
    /// Set when a connected trainer drops mid-ride. The ride screen turns this into an alert.
    var trainerDroppedAt: Date?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var controlPoint: CBCharacteristic?
    private var lastPowerMeasurement: CyclingPowerMeasurement?
    private var pendingTarget: Int?
    private var lastSentTarget: Int?

    private let rememberedKey = "cadencia.devices.remembered"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: Remembered devices

    private(set) var remembered: [Role: UUID] = {
        let raw = UserDefaults.standard.dictionary(forKey: "cadencia.devices.remembered") as? [String: String] ?? [:]
        var out: [Role: UUID] = [:]
        for (k, v) in raw { if let r = Role(rawValue: k), let id = UUID(uuidString: v) { out[r] = id } }
        return out
    }()

    private func remember(_ id: UUID, as role: Role) {
        remembered[role] = id
        let raw = Dictionary(uniqueKeysWithValues: remembered.map { ($0.key.rawValue, $0.value.uuidString) })
        UserDefaults.standard.set(raw, forKey: rememberedKey)
    }

    func forget(_ role: Role) {
        disconnect(role)
        remembered[role] = nil
        let raw = Dictionary(uniqueKeysWithValues: remembered.map { ($0.key.rawValue, $0.value.uuidString) })
        UserDefaults.standard.set(raw, forKey: rememberedKey)
    }

    // MARK: Scanning

    func startScanning() {
        guard isPoweredOn, !isScanning else { return }
        discovered = []
        let services = [GATT.fitnessMachineService, GATT.heartRateService, GATT.cyclingPowerService].map { CBUUID(string: $0) }
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScanning() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    /// Reconnects whatever was used last time. Called when the pre-ride screen appears.
    func reconnectRemembered() {
        guard isPoweredOn else { return }
        let ids = Array(remembered.values)
        for p in central.retrievePeripherals(withIdentifiers: ids) {
            peripherals[p.identifier] = p
            if let role = remembered.first(where: { $0.value == p.identifier })?.key, connections[role] == nil {
                connections[role] = Connection(id: p.identifier, name: p.name ?? "Device", role: role, isReady: false)
                p.delegate = self
                central.connect(p)
            }
        }
    }

    // MARK: Connecting

    func connect(_ device: Discovered, as role: Role) {
        guard let p = peripherals[device.id] else { return }
        if let existing = connections[role], existing.id != device.id { disconnect(role) }
        connections[role] = Connection(id: device.id, name: device.name, role: role, isReady: false)
        remember(device.id, as: role)
        p.delegate = self
        central.connect(p)
    }

    func disconnect(_ role: Role) {
        guard let c = connections[role], let p = peripherals[c.id] else { connections[role] = nil; return }
        let stillUsed = connections.values.contains { $0.id == c.id && $0.role != role }
        connections[role] = nil
        if role == .trainer { controlPoint = nil; ergAcknowledged = false }
        if !stillUsed { central.cancelPeripheralConnection(p) }
    }

    func disconnectAll() {
        for role in Role.allCases { disconnect(role) }
    }

    var trainer: Connection? { connections[.trainer] }
    var heartRateMonitor: Connection? { connections[.heartRate] }
    var powerMeter: Connection? { connections[.powerMeter] }

    // MARK: ERG control

    /// Sends a target power to the trainer. Duplicates are skipped; the value is queued until control is granted.
    func setTargetPower(_ watts: Int) {
        pendingTarget = watts
        flushTarget()
    }

    /// Tells the trainer the session is over so it drops back to free-ride resistance.
    func releaseControl() {
        guard let cp = controlPoint, let p = trainerPeripheral else { return }
        p.writeValue(FTMSControl.stop(), for: cp, type: .withResponse)
        lastSentTarget = nil
        pendingTarget = nil
    }

    /// Pauses the trainer's ERG hold without giving up control.
    func pauseTrainer() {
        guard let cp = controlPoint, let p = trainerPeripheral else { return }
        p.writeValue(FTMSControl.pause(), for: cp, type: .withResponse)
        lastSentTarget = nil
    }

    func resumeTrainer() {
        guard let cp = controlPoint, let p = trainerPeripheral else { return }
        p.writeValue(FTMSControl.start(), for: cp, type: .withResponse)
        flushTarget()
    }

    private var trainerPeripheral: CBPeripheral? { trainer.flatMap { peripherals[$0.id] } }

    private func flushTarget() {
        guard ergAcknowledged, let cp = controlPoint, let p = trainerPeripheral, let target = pendingTarget, target != lastSentTarget else { return }
        p.writeValue(FTMSControl.setTargetPower(target), for: cp, type: .withResponse)
        lastSentTarget = target
    }

    private func requestControl(_ p: CBPeripheral, _ cp: CBCharacteristic) {
        p.writeValue(FTMSControl.requestControl(), for: cp, type: .withResponse)
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isPoweredOn = central.state == .poweredOn
        if !isPoweredOn {
            isScanning = false
            for role in Role.allCases { connections[role]?.isReady = false }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString.uppercased() }
        var roles = Set<Role>()
        if advertised.contains(GATT.fitnessMachineService) { roles.insert(.trainer) }
        if advertised.contains(GATT.heartRateService) { roles.insert(.heartRate) }
        if advertised.contains(GATT.cyclingPowerService) { roles.insert(.powerMeter) }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown device"
        if let i = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[i].rssi = RSSI.intValue
            discovered[i].roles.formUnion(roles)
            if discovered[i].name == "Unknown device" { discovered[i].name = name }
        } else {
            discovered.append(Discovered(id: peripheral.identifier, name: name, roles: roles, rssi: RSSI.intValue))
        }
        discovered.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([GATT.fitnessMachineService, GATT.heartRateService, GATT.cyclingPowerService, GATT.batteryService].map { CBUUID(string: $0) })
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        for role in Role.allCases where connections[role]?.id == peripheral.identifier {
            connections[role] = nil
        }
        lastControlError = error?.localizedDescription
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        for role in Role.allCases where connections[role]?.id == peripheral.identifier {
            connections[role]?.isReady = false
            if role == .trainer {
                controlPoint = nil
                ergAcknowledged = false
                lastSentTarget = nil
                trainerDroppedAt = Date()
            }
        }
        // Keep the role registered and let iOS reconnect when the device comes back in range.
        if connections.values.contains(where: { $0.id == peripheral.identifier }) {
            central.connect(peripheral)
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid.uuidString.uppercased() {
            case GATT.fitnessMachineService:
                peripheral.discoverCharacteristics([GATT.indoorBikeData, GATT.fitnessMachineControlPoint, GATT.fitnessMachineStatus].map { CBUUID(string: $0) }, for: service)
            case GATT.heartRateService:
                peripheral.discoverCharacteristics([CBUUID(string: GATT.heartRateMeasurement)], for: service)
            case GATT.cyclingPowerService:
                peripheral.discoverCharacteristics([CBUUID(string: GATT.cyclingPowerMeasurement)], for: service)
            case GATT.batteryService:
                peripheral.discoverCharacteristics([CBUUID(string: GATT.batteryLevel)], for: service)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid.uuidString.uppercased() {
            case GATT.indoorBikeData where role(of: peripheral) == .trainer:
                peripheral.setNotifyValue(true, for: c)
                connections[.trainer]?.isReady = true
            case GATT.fitnessMachineControlPoint where role(of: peripheral) == .trainer:
                controlPoint = c
                peripheral.setNotifyValue(true, for: c)
                requestControl(peripheral, c)
            case GATT.fitnessMachineStatus:
                peripheral.setNotifyValue(true, for: c)
            case GATT.heartRateMeasurement where connections[.heartRate]?.id == peripheral.identifier:
                peripheral.setNotifyValue(true, for: c)
                connections[.heartRate]?.isReady = true
            case GATT.cyclingPowerMeasurement where connections[.powerMeter]?.id == peripheral.identifier:
                peripheral.setNotifyValue(true, for: c)
                connections[.powerMeter]?.isReady = true
            case GATT.batteryLevel:
                peripheral.readValue(for: c)
            default: break
            }
        }
    }

    private func role(of peripheral: CBPeripheral) -> Role? {
        connections.first { $0.value.id == peripheral.identifier }?.key
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid.uuidString.uppercased() {
        case GATT.indoorBikeData:
            guard let bike = IndoorBikeData.parse(data) else { return }
            // A separate power meter wins over the trainer's own power reading.
            if connections[.powerMeter]?.isReady != true, let w = bike.instantaneousPower { live.watts = w }
            if let c = bike.cadenceRPM { live.cadence = Int(c.rounded()) }
            if let s = bike.speedKmh { live.speedKmh = s }
            if connections[.heartRate]?.isReady != true, let hr = bike.heartRate, hr > 0 { live.heartRate = hr }
            live.updatedAt = Date()
        case GATT.heartRateMeasurement:
            guard let hr = HeartRateMeasurement.parse(data) else { return }
            live.heartRate = hr.bpm
            live.updatedAt = Date()
        case GATT.cyclingPowerMeasurement:
            guard let m = CyclingPowerMeasurement.parse(data) else { return }
            live.watts = m.watts
            if let prev = lastPowerMeasurement, let rpm = CyclingPowerMeasurement.cadence(previous: prev, current: m) {
                live.cadence = Int(rpm.rounded())
            }
            lastPowerMeasurement = m
            live.updatedAt = Date()
        case GATT.fitnessMachineControlPoint:
            guard let r = FTMSControl.parseResponse(data) else { return }
            if r.request == .requestControl {
                ergAcknowledged = r.result == .success
                lastControlError = r.result == .success ? nil : "Trainer refused control (\(r.result))"
                if ergAcknowledged, let p = trainerPeripheral, let cp = controlPoint {
                    p.writeValue(FTMSControl.start(), for: cp, type: .withResponse)
                }
                flushTarget()
            } else if r.request == .setTargetPower, r.result != .success {
                lastControlError = "Trainer rejected target (\(r.result))"
                lastSentTarget = nil
            }
        case GATT.batteryLevel:
            if let first = data.first, let role = role(of: peripheral) { connections[role]?.batteryPercent = Int(first) }
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { lastControlError = error.localizedDescription }
    }
}
