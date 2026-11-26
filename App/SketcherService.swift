import Foundation
import CoreBluetooth
import UIKit
import Combine

/// Port of smart-sketcher-tools/sketcher.py to CoreBluetooth.
///
/// Protocol (matched to the Python tool):
///   * connect to the peripheral,
///   * subscribe to notifications on characteristic 0xFFE3,
///   * write the 8-byte "send image" command,
///   * stream 128 lines x 160 px (RGB565, 2 bytes/px) with a fixed delay
///     between lines.
///
/// iOS cannot connect by a fixed MAC address, so the device is found by
/// scanning once; its identifier is remembered (UserDefaults) and reused on
/// every later send.
@MainActor
final class SketcherService: NSObject, ObservableObject {
    // MARK: Protocol constants
    private let charUUID = CBUUID(string: "0000FFE3-0000-1000-8000-00805F9B34FB")
    private let sendCommand: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x50, 0x00, 0x01, 0x00]
    private let imageWidth = 160
    private let imageHeight = 128
    private let lineDelay: UInt64 = 150_000_000          // 0.15 s, matches script
    private let writeTimeoutNs: UInt64 = 5_000_000_000   // 5 s safety net per write

    private let idKey = "sketcher.peripheral.id"
    private let nameKey = "sketcher.peripheral.name"

    // MARK: Errors
    enum SketcherError: LocalizedError {
        case notPoweredOn
        case noRememberedDevice
        case deviceNotFound
        case notConnected(String?)
        case noCharacteristic
        case writeFailed(String?)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .notPoweredOn:
                return "Bluetooth is off or unavailable. Turn on Bluetooth and try again."
            case .noRememberedDevice:
                return "No device selected yet. Scan and pick one first."
            case .deviceNotFound:
                return "The saved device was not found. Scan for it again."
            case .notConnected(let m):
                return "Not connected\(m.map { ": \($0)" } ?? "")."
            case .noCharacteristic:
                return "Device does not expose the sketcher data characteristic."
            case .writeFailed(let m):
                return "Write failed\(m.map { ": \($0)" } ?? "")."
            case .encodeFailed:
                return "Could not process the image."
            }
        }
    }

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: String
        var name: String
    }

    enum Status: Equatable {
        case idle, scanning, connecting, sending, done, failed
    }

    // MARK: Published state
    @Published var status: Status = .idle
    @Published var progress: Double = 0
    @Published var discovered: [DiscoveredDevice] = []
    @Published var errorMessage: String?
    @Published var rememberedName: String?

    // MARK: Internals
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var targetChar: CBCharacteristic?

    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var servicesContinuation: CheckedContinuation<Void, Never>?
    private var charContinuation: CheckedContinuation<Void, Never>?
    private var notifyContinuation: CheckedContinuation<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Error>?

    private var expectedCharDiscovers = 0
    private var receivedCharDiscovers = 0
    private var allCharacteristics: [CBCharacteristic] = []

    private var rememberedID: String? {
        UserDefaults.standard.string(forKey: idKey)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        rememberedName = UserDefaults.standard.string(forKey: nameKey)
    }

    var isBusy: Bool {
        switch status {
        case .scanning, .connecting, .sending:
            return true
        default:
            return false
        }
    }

    // MARK: Scanning
    func startScan() {
        discovered = []
        errorMessage = nil
        guard central.state == .poweredOn else {
            errorMessage = SketcherError.notPoweredOn.errorDescription
            return
        }
        status = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
    }

    func select(_ device: DiscoveredDevice) {
        stopScan()
        UserDefaults.standard.set(device.id, forKey: idKey)
        UserDefaults.standard.set(device.name, forKey: nameKey)
        rememberedName = device.name
        discovered = []
        errorMessage = nil
        status = .idle
    }

    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
        rememberedName = nil
        status = .idle
    }

    // MARK: Sending
    func send(_ image: UIImage) async {
        errorMessage = nil
        progress = 0
        do {
            guard let pid = rememberedID, !pid.isEmpty else {
                throw SketcherError.noRememberedDevice
            }
            status = .connecting
            let (peripheral, characteristic) = try await prepare(peripheralID: pid)
            targetChar = characteristic

            status = .sending
            let lines = try encode(image)

            try await write(sendCommand)
            for (i, line) in lines.enumerated() {
                // Matches sketcher.py: fixed delay BEFORE each write (the
                // device's "OK" notifications are too easily bundled to be
                // trusted as the sole pacing signal).
                try await Task.sleep(nanoseconds: lineDelay)
                try await write(line)
                progress = Double(i + 1) / Double(lines.count)
            }

            disconnect()
            status = .done
        } catch {
            disconnect()
            errorMessage = error.localizedDescription
            status = .failed
        }
    }

    /// Connect + discover + subscribe. Returns the peripheral and its char.
    private func prepare(peripheralID: String) async throws -> (CBPeripheral, CBCharacteristic) {
        try await waitPoweredOn()
        stopScan()

        guard let id = UUID(uuidString: peripheralID),
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        else {
            throw SketcherError.deviceNotFound
        }

        targetPeripheral = peripheral
        allCharacteristics = []
        try await connect(peripheral)
        peripheral.delegate = self

        try await discoverServices(peripheral)
        try await discoverAllCharacteristics(peripheral)

        guard let char = allCharacteristics.first(where: { $0.uuid == charUUID }) else {
            throw SketcherError.noCharacteristic
        }
        try await enableNotify(peripheral, char)
        return (peripheral, char)
    }

    private func waitPoweredOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff, .unauthorized, .unsupported:
            throw SketcherError.notPoweredOn
        case .unknown, .resetting:
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.poweredOnContinuation = cont
            }
        @unknown default:
            throw SketcherError.notPoweredOn
        }
    }

    private func connect(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            central.connect(peripheral, options: nil)
        }
    }

    private func discoverServices(_ peripheral: CBPeripheral) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.servicesContinuation = cont
            peripheral.discoverServices(nil)
        }
    }

    private func discoverAllCharacteristics(_ peripheral: CBPeripheral) async {
        guard let services = peripheral.services, !services.isEmpty else { return }
        expectedCharDiscovers = services.count
        receivedCharDiscovers = 0
        allCharacteristics = []
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.charContinuation = cont
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    private func enableNotify(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.notifyContinuation = cont
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func write(_ bytes: [UInt8]) async throws {
        guard let peripheral = targetPeripheral, let characteristic = targetChar else {
            throw SketcherError.notConnected(nil)
        }
        let data = Data(bytes: bytes)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.writeContinuation = cont
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            // Safety net: if the device never acknowledges the write, fail the
            // send instead of hanging forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: self.writeTimeoutNs)
                guard let cont = self.writeContinuation else { return }
                self.writeContinuation = nil
                cont.resume(throwing: SketcherError.writeFailed("device did not respond"))
            }
        }
    }

    private func disconnect() {
        if let peripheral = targetPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        targetPeripheral = nil
        targetChar = nil
    }

    /// Stretch the image to 160x128 and convert to RGB565 (2 bytes per pixel,
    /// big-endian: red high byte, blue low byte). Returns one array per row.
    private func encode(_ image: UIImage) throws -> [[UInt8]] {
        let w = imageWidth
        let h = imageHeight

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stretched = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let cg = stretched.cgImage
        else {
            throw SketcherError.encodeFailed
        }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var lines: [[UInt8]] = []
        lines.reserveCapacity(h)
        for y in 0..<h {
            var line = [UInt8]()
            line.reserveCapacity(w * 2)
            for x in 0..<w {
                let offset = (y * w + x) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                line.append(UInt8((r & 0xF8) | (g >> 5)))
                line.append(UInt8(((g & 0x1C) << 3) | (b >> 3)))
            }
            lines.append(line)
        }
        guard lines.count == h else { throw SketcherError.encodeFailed }
        return lines
    }
}

// MARK: - CBCentralManagerDelegate
extension SketcherService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if let cont = self.poweredOnContinuation {
                self.poweredOnContinuation = nil
                if central.state == .poweredOn { cont.resume() }
                else { cont.resume(throwing: SketcherError.notPoweredOn) }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? peripheral.name
                ?? "Unnamed"
            if let index = self.discovered.firstIndex(where: { $0.id == peripheral.identifier.uuidString }) {
                if self.discovered[index].name == "Unnamed" {
                    self.discovered[index].name = name
                }
            } else {
                self.discovered.append(DiscoveredDevice(id: peripheral.identifier.uuidString, name: name))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            if let cont = self.connectContinuation {
                self.connectContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if let cont = self.connectContinuation {
                self.connectContinuation = nil
                cont.resume(throwing: SketcherError.notConnected(error?.localizedDescription))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if let cont = self.connectContinuation {
                self.connectContinuation = nil
                cont.resume(throwing: SketcherError.notConnected(error?.localizedDescription))
            }
            if let cont = self.writeContinuation {
                self.writeContinuation = nil
                cont.resume(throwing: SketcherError.notConnected("device disconnected"))
            }
        }
    }

}

// MARK: - CBPeripheralDelegate
extension SketcherService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let cont = self.servicesContinuation {
                self.servicesContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristics characteristics: [CBCharacteristic],
        for service: CBService
    ) {
        Task { @MainActor in
            guard peripheral === self.targetPeripheral else { return }
            self.allCharacteristics.append(contentsOf: characteristics)
            self.receivedCharDiscovers += 1
            if self.receivedCharDiscovers >= self.expectedCharDiscovers, let cont = self.charContinuation {
                self.charContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationState error: Error?,
        for characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if let cont = self.notifyContinuation {
                self.notifyContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let cont = self.writeContinuation {
                self.writeContinuation = nil
                if let error = error {
                    cont.resume(throwing: SketcherError.writeFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }
}
