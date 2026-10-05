import Foundation
import CoreBluetooth
import Combine

struct DirectDroidDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int

    var displayName: String {
        "\(name) • \(id.uuidString.suffix(6)) • \(rssi) dBm"
    }
}

@MainActor
final class DirectDroidBLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "09B600A0-3E42-41FC-B474-E9C0C8F0C801")
    static let notifyUUID = CBUUID(string: "09B600B0-3E42-41FC-B474-E9C0C8F0C801")
    static let commandUUID = CBUUID(string: "09B600B1-3E42-41FC-B474-E9C0C8F0C801")

    @Published var devices: [DirectDroidDevice] = []
    @Published var status = "Bluetooth ready"
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectedName = ""
    @Published var lastRX = ""

    var onDisconnected: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredRSSI: [UUID: Int] = [:]
    private var heartbeat: Timer?
    private var actionGeneration = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        guard central.state == .poweredOn else {
            status = bluetoothStateText()
            return
        }

        discoveredPeripherals.removeAll()
        discoveredRSSI.removeAll()
        devices = []
        isScanning = true
        status = "Scanning for nearby DROID units…"

        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.isScanning else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.devices.isEmpty {
                self.status = "No R-Series found. Make sure R2 is powered on and not connected to the Mac."
            } else {
                self.status = "Tap your R2 below to connect"
            }
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if !isConnected {
            status = devices.isEmpty ? "Scan stopped" : "Tap your R2 below to connect"
        }
    }

    func connect(_ device: DirectDroidDevice) {
        guard central.state == .poweredOn else {
            status = bluetoothStateText()
            return
        }

        guard let candidate = discoveredPeripherals[device.id] else {
            status = "That R2 is no longer visible. Scan again."
            return
        }

        stopScan()
        peripheral = candidate
        candidate.delegate = self
        status = "Connecting to \(device.displayName)…"
        central.connect(candidate, options: nil)
    }

    func disconnect() {
        emergencyStop()
        heartbeat?.invalidate()
        heartbeat = nil

        guard let peripheral else {
            cleanup("Disconnected")
            return
        }

        central.cancelPeripheralConnection(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            if isConnected {
                emergencyStop()
            }
            status = bluetoothStateText()
        } else if !isConnected {
            status = "Bluetooth ready"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        guard name.uppercased() == "DROID" else { return }

        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredRSSI[peripheral.identifier] = RSSI.intValue
        publishDevices()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectedName = "DROID • \(peripheral.identifier.uuidString.suffix(6))"
        status = "Discovering R2 service…"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        cleanup("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let detail = error?.localizedDescription
        cleanup(detail == nil ? "R2 disconnected" : "R2 disconnected: \(detail!)")
        onDisconnected?()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            status = "R-Series Bluetooth service not found"
            return
        }

        peripheral.discoverCharacteristics([Self.notifyUUID, Self.commandUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            status = "Control discovery failed: \(error.localizedDescription)"
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.notifyUUID {
                notifyCharacteristic = characteristic
            } else if characteristic.uuid == Self.commandUUID {
                commandCharacteristic = characteristic
            }
        }

        guard let notifyCharacteristic, commandCharacteristic != nil else {
            status = "Required R2 controls were not found"
            return
        }

        peripheral.setNotifyValue(true, for: notifyCharacteristic)

        // Droid Depot handshake discovered by the open pyDroidDepot project.
        let handshake = Data([0x22, 0x20, 0x01])
        writeRaw(handshake)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.writeRaw(handshake)
        }

        isConnected = true
        status = "Direct Bluetooth connected to \(connectedName)"

        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendCommand(id: 14, data: Data())
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        lastRX = data.map { String(format: "%02x", $0) }.joined()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            status = "Bluetooth write failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Low-level Droid Depot protocol

    private func writeRaw(_ data: Data) {
        guard let peripheral, let commandCharacteristic else { return }
        let type: CBCharacteristicWriteType =
            commandCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: commandCharacteristic, type: type)
    }

    func sendCommand(id: UInt8, data: Data) {
        guard isConnected else { return }

        let dataLength = data.count
        let totalLength = dataLength + 3
        guard totalLength < 32, dataLength < 64 else { return }

        let byte1 = UInt8(totalLength | 0x20)
        let byte2: UInt8 = (id == 15) ? 0x42 : 0x00
        let byte3 = id
        let byte4 = UInt8(dataLength + 0x40)

        var packet = Data([byte1, byte2, byte3, byte4])
        packet.append(data)
        writeRaw(packet)
    }

    func sendMulti(id: UInt8, data: Data) {
        var payload = Data([0x44, id])
        payload.append(data)
        sendCommand(id: 15, data: payload)
    }

    // MARK: - Drive / dome

    private func motor(direction: UInt8, motor: UInt8, speed: UInt8, ramp: UInt16 = 300) {
        let selector: UInt8 = (direction == 8 ? 0x80 : 0x00) | motor
        let rampHi = UInt8((ramp >> 8) & 0xff)
        let rampLo = UInt8(ramp & 0xff)
        sendCommand(id: 5, data: Data([selector, speed, rampHi, rampLo, 0x00, 0x00]))
    }

    func forward(speed: UInt8) {
        motor(direction: 0, motor: 0, speed: speed)
        motor(direction: 0, motor: 1, speed: speed)
    }

    func rotateLeft(speed: UInt8) {
        motor(direction: 0, motor: 0, speed: speed)
        motor(direction: 8, motor: 1, speed: speed)
    }

    func rotateRight(speed: UInt8) {
        motor(direction: 8, motor: 0, speed: speed)
        motor(direction: 0, motor: 1, speed: speed)
    }

    func stopDrive() {
        motor(direction: 0, motor: 0, speed: 0)
        motor(direction: 0, motor: 1, speed: 0)
    }

    func domeLeft(speed: UInt8) {
        rotateDome(direction: 0x00, speed: speed)
    }

    func domeRight(speed: UInt8) {
        rotateDome(direction: 0xff, speed: speed)
    }

    private func rotateDome(direction: UInt8, speed: UInt8) {
        sendMulti(id: 2, data: Data([direction, speed, 0x01, 0x2c, 0x00, 0x00]))
    }

    func centerDome(speed: UInt8 = 200, offset: UInt8 = 0) {
        sendMulti(id: 1, data: Data([speed, offset]))
    }

    func stopDome() {
        rotateDome(direction: 0x00, speed: 0)
    }

    func emergencyStop() {
        actionGeneration += 1
        guard isConnected else { return }
        stopDrive()
        stopDome()
    }

    // MARK: - Audio / LEDs / scripts

    private func audioCommand(_ command: UInt8, parameter: UInt8 = 0) {
        sendMulti(id: 0, data: Data([command, parameter]))
    }

    func chirp(bank: Int = 1) {
        let trackCounts = [1: 4, 2: 4, 3: 3, 4: 1, 5: 1, 6: 4, 7: 5, 8: 1, 9: 1, 11: 2, 12: 2]
        let safeBank = trackCounts[bank] == nil ? 1 : bank
        let bankIndex = UInt8(max(0, safeBank - 1))
        let trackCount = max(1, trackCounts[safeBank] ?? 1)
        let trackIndex = UInt8(Int.random(in: 0..<trackCount))

        audioCommand(31, parameter: bankIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.audioCommand(24, parameter: trackIndex)
        }
    }

    func setAllHeadLEDs(on: Bool) {
        let command: UInt8 = on ? 72 : 73
        audioCommand(command, parameter: 1)
        audioCommand(command, parameter: 2)
        audioCommand(command, parameter: 4)
    }

    func executeScript(_ scriptID: Int) {
        guard scriptID > 0, scriptID != 13 else { return }
        sendCommand(id: 12, data: Data([bcd(scriptID), bcd(2)]))
    }

    private func bcd(_ value: Int) -> UInt8 {
        let tens = max(0, min(9, value / 10))
        let ones = max(0, min(9, value % 10))
        return UInt8((tens << 4) | ones)
    }

    // MARK: - Safe timed actions

    private func beginTimedAction() -> Int {
        actionGeneration += 1
        stopDrive()
        stopDome()
        return actionGeneration
    }

    private func schedule(after delay: TimeInterval, generation: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isConnected, self.actionGeneration == generation else { return }
            work()
        }
    }

    func turnLeftPulse() {
        let generation = beginTimedAction()
        rotateLeft(speed: 48)
        schedule(after: 0.32, generation: generation) { [weak self] in self?.stopDrive() }
    }

    func turnRightPulse() {
        let generation = beginTimedAction()
        rotateRight(speed: 48)
        schedule(after: 0.32, generation: generation) { [weak self] in self?.stopDrive() }
    }

    func spinLeft() {
        let generation = beginTimedAction()
        rotateLeft(speed: 55)
        schedule(after: 1.05, generation: generation) { [weak self] in self?.stopDrive() }
    }

    func spinRight() {
        let generation = beginTimedAction()
        rotateRight(speed: 55)
        schedule(after: 1.05, generation: generation) { [weak self] in self?.stopDrive() }
    }

    func lookLeft() {
        let generation = beginTimedAction()
        domeLeft(speed: 85)
        schedule(after: 0.48, generation: generation) { [weak self] in self?.stopDome() }
    }

    func lookRight() {
        let generation = beginTimedAction()
        domeRight(speed: 85)
        schedule(after: 0.48, generation: generation) { [weak self] in self?.stopDome() }
    }

    func scan() {
        let generation = beginTimedAction()
        domeLeft(speed: 75)
        schedule(after: 0.45, generation: generation) { [weak self] in
            self?.domeRight(speed: 75)
        }
        schedule(after: 1.20, generation: generation) { [weak self] in
            self?.centerDome()
        }
        schedule(after: 1.55, generation: generation) { [weak self] in
            self?.stopDome()
        }
        chirp(bank: 1)
    }

    func dance() {
        let generation = beginTimedAction()
        chirp(bank: 1)
        rotateLeft(speed: 50)
        schedule(after: 0.30, generation: generation) { [weak self] in
            self?.rotateRight(speed: 50)
        }
        schedule(after: 0.62, generation: generation) { [weak self] in
            self?.stopDrive()
            self?.domeLeft(speed: 80)
        }
        schedule(after: 0.95, generation: generation) { [weak self] in
            self?.domeRight(speed: 80)
        }
        schedule(after: 1.30, generation: generation) { [weak self] in
            self?.centerDome()
        }
        schedule(after: 1.55, generation: generation) { [weak self] in
            self?.stopDome()
        }
    }

    func greeting() {
        let generation = beginTimedAction()
        chirp(bank: 1)
        domeRight(speed: 65)
        schedule(after: 0.28, generation: generation) { [weak self] in
            self?.domeLeft(speed: 65)
        }
        schedule(after: 0.62, generation: generation) { [weak self] in
            self?.centerDome()
        }
    }

    func sleepReaction() {
        let generation = beginTimedAction()
        centerDome()
        schedule(after: 0.35, generation: generation) { [weak self] in
            self?.setAllHeadLEDs(on: false)
        }
    }

    func wakeReaction() {
        let generation = beginTimedAction()
        setAllHeadLEDs(on: true)
        chirp(bank: 1)
        domeLeft(speed: 65)
        schedule(after: 0.28, generation: generation) { [weak self] in
            self?.domeRight(speed: 65)
        }
        schedule(after: 0.60, generation: generation) { [weak self] in
            self?.centerDome()
        }
    }

    private func publishDevices() {
        devices = discoveredPeripherals.compactMap { id, peripheral in
            guard let rssi = discoveredRSSI[id] else { return nil }
            return DirectDroidDevice(id: id, name: peripheral.name ?? "DROID", rssi: rssi)
        }
        .sorted { $0.rssi > $1.rssi }
    }

    private func cleanup(_ message: String) {
        heartbeat?.invalidate()
        heartbeat = nil
        actionGeneration += 1
        isConnected = false
        connectedName = ""
        commandCharacteristic = nil
        notifyCharacteristic = nil
        peripheral = nil
        status = message
    }

    private func bluetoothStateText() -> String {
        switch central.state {
        case .poweredOn: return "Bluetooth ready"
        case .poweredOff: return "Turn Bluetooth on"
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported: return "Bluetooth is not supported on this iPhone"
        case .resetting: return "Bluetooth is resetting"
        case .unknown: return "Bluetooth is starting…"
        @unknown default: return "Bluetooth unavailable"
        }
    }
}
