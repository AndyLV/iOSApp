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
///   * stream 128 lines x 160 px (RGB565, 2 bytes/px) with a fixed
///     0.15 s delay before each line.
///
/// Write type and MTU chunking adapt to the device's characteristic
/// properties, just like bluez/bleak do on the PC version.
///
/// iOS cannot connect by a fixed MAC address, so the device is found by
/// scanning; its identifier is remembered (UserDefaults) and reused on
/// every later send.
@MainActor
final class SketcherService: NSObject, ObservableObject {

    // MARK: Protocol constants
    private let charUUID = CBUUID(string: "0000FFE3-0000-1000-8000-00805F9B34FB")
    private let sendCommand = Data([0x01, 0x00, 0x00, 0x00, 0x50, 0x00, 0x01, 0x00])
    private let imageWidth = 160
    private let imageHeight = 128
    private let lineDelayMs = 150                      // matches the Python script
    private let maxFrameLength = 20                    // conservative BLE payload

    private let idKey = "sketcher.peripheral.id"
    private let nameKey = "sketcher.peripheral.name"

    // MARK: Errors
    enum SketcherError: LocalizedError {
        case notPoweredOn
        case notAuthorized
        case noRememberedDevice
        case deviceNotFound
        case connectFailed(String?)
        case phaseTimedOut(String)
        case noWwritableCharacteristic
        case disconnected
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .notPoweredOn:
                return "Bluetooth is off or unavailable. Turn on Bluetooth and try again."
            case .notAuthorized:
                return "This app needs Bluetooth access. Allow it in the Settings app, then retry."
            case .noRememberedDevice:
                return "No device selected yet. Scan and pick one first."
            case .deviceNotFound:
                return "The saved device was not found while scanning. Is it powered on and nearby? Scan and select it again."
            case .connectFailed(let m):
                return "Could not connect to the device\(m.map { ": \($0)" } ?? "")."
            case .phaseTimedOut(let phase):
                return "Timed out while \(phase). Check the Bluetooth device and try again."
            case .noWwritableCharacteristic:
                return "The sketcher data characteristic (0xFFE3) was not found or is not writable on this device."
            case .disconnected:
                return "The device disconnected during sending. Try again."
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
        case idle
        case scanning
        case connecting
        case sending
        case done
        case failed
    }

    // MARK: One-shot async wait with timeout (prevents any phase hanging)
    private final class Phase<T> {
        var continuation: CheckedContinuation<T, Error>?

        func finish(_ value: T) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }

        func fail(_ error: Error) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func withPhase<T>(
        _ label: String,
        in seconds: Double,
        _ begin: (Phase<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let phase = Phase<T>()
            phase.continuation = cont
            begin(phase)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                phase.fail(SketcherError.phaseTimedOut(label))
            }
        }
    }

    // MARK: Published state
    @Published var status: Status = .idle
    @Published var step = ""
    @Published var progress = 0.0
    @Published var notifications = 0
    @Published var discovered: [DiscoveredDevice] = []
    @Published var errorMessage: String?
    @Published var rememberedName: String?

    // MARK: Internals
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var targetCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var writeChunkLength = 20

    private var poweredOnPhase: Phase<Void>?
    private var connectPhase: Phase<Void>?
    private var servicesPhase: Phase<Void>?
    private var charsPhase: Phase<Void>?
    private var notifyPhase: Phase<Void>?
    private var writePhase: Phase<Void>?
    private var acquirePhase: Phase<CBPeripheral?>?
    private var acquireTargetID: UUID?

    private var allCharacteristics: [CBCharacteristic] = []
    private var expectedCharDiscovers = 0
    private var receivedCharDiscovers = 0

    private var rememberedID: String? {
        UserDefaults.standard.string(forKey: idKey)
    }

    var isBusy: Bool {
        switch status {
        case .scanning, .connecting, .sending:
            return true
        default:
            return false
        }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        rememberedName = UserDefaults.standard.string(forKey: nameKey)
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
        acquireTargetID = nil
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
        guard !isBusy else { return }
        errorMessage = nil
        step = ""
        progress = 0
        notifications = 0
        do {
            // Process the image first: no BLE involved, fail fast.
            let lines = try encode(image)

            status = .connecting
            try await waitPoweredOn()

            let peripheral = try await obtainPeripheral()
            let characteristic = try await configure(peripheral)

            status = .sending
            step = "Sending image..."
            targetCharacteristic = characteristic
            writeType = characteristic.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse
            if writeType == .withResponse {
                writeChunkLength = max(3, Int(peripheral.maximumWriteValueLength(for: .withResponse)) - 3)
            } else {
                writeChunkLength = maxFrameLength
            }

            try await write(sendCommand)
            for (i, line) in lines.enumerated() {
                try await Task.sleep(for: .milliseconds(lineDelayMs))
                try await write(Data(line))
                progress = Double(i + 1) / Double(lines.count)
            }

            step = "Done"
            disconnect()
            status = .done
        } catch {
            stopScan()
            disconnect()
            step = ""
            errorMessage = error.localizedDescription
            status = .failed
        }
    }

    // MARK: Phases

    private func waitPoweredOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw SketcherError.notAuthorized
        case .poweredOff, .unsupported:
            throw SketcherError.notPoweredOn
        case .resetting:
            try await withPhase("waiting for Bluetooth", in: 10) { phase in
                self.poweredOnPhase = phase
            }
        @unknown default:
            throw SketcherError.notPoweredOn
        }
    }

    /// The remembered peripheral: via its stored UUID, or a brief scan if the
    /// OS has not seen it since app launch.
    private func obtainPeripheral() async throws -> CBPeripheral {
        guard let idString = rememberedID, let id = UUID(uuidString: idString) else {
            throw SketcherError.noRememberedDevice
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            return peripheral
        }
        guard central.state == .poweredOn else {
            throw SketcherError.notPoweredOn
        }
        step = "Looking for saved device..."
        acquireTargetID = id
        defer {
            acquireTargetID = nil
        }
        stopScan()
        let found: CBPeripheral? = try await withPhase("scanning for the saved device", in: 15) { phase in
            self.acquirePhase = phase
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        stopScan()
        guard let found else {
            throw SketcherError.deviceNotFound
        }
        return found
    }

    /// Connect, discover, subscribe. Returns the writable data characteristic.
    private func configure(_ peripheral: CBPeripheral) async throws -> CBCharacteristic {
        targetPeripheral = peripheral
        allCharacteristics = []
        expectedCharDiscovers = 0
        receivedCharDiscovers = 0

        step = "Connecting..."
        try await withPhase("connecting to the device", in: 20) { phase in
            self.connectPhase = phase
            self.central.connect(peripheral, options: nil)
        }
        peripheral.delegate = self

        step = "Reading device services..."
        try await withPhase("reading the device's services", in: 10) { phase in
            self.servicesPhase = phase
            peripheral.discoverServices(nil)
        }

        guard let services = peripheral.services, !services.isEmpty else {
            throw SketcherError.phaseTimedOut("reading services (device exposes none)")
        }
        step = "Reading device characteristics..."
        expectedCharDiscovers = services.count
        receivedCharDiscovers = 0
        allCharacteristics = []
        try await withPhase("reading the device's characteristics", in: 15) { phase in
            self.charsPhase = phase
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }

        guard let characteristic = allCharacteristics.first(where: { $0.uuid == charUUID }),
              characteristic.properties.contains(.write)
            || characteristic.properties.contains(.writeWithoutResponse)
        else {
            throw SketcherError.noWwritableCharacteristic
        }

        step = "Preparing data channel..."
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            // Same as the Python script: subscribe to the "OK" notifications.
            // If this fails we continue anyway — the fixed line delay is the
            // pacing, notifications are only diagnostics.
            do {
                try await withPhase("subscribing to device notifications", in: 10) { phase in
                    self.notifyPhase = phase
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } catch {
                step = "Preparing data channel (no ack channel)"
            }
        }
        return characteristic
    }

    private func write(_ data: Data) async throws {
        guard let peripheral = targetPeripheral, let characteristic = targetCharacteristic else {
            throw SketcherError.disconnected
        }
        if peripheral.state != .connected { throw SketcherError.disconnected }

        if writeType == .withoutResponse {
            // Fire and forget; the BLE stack fragments long frames itself and
            // the fixed delay between writes paces the device.
            for chunk in data.chunked(size: writeChunkLength) {
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            }
            return
        }
        // Write-with-response: wait for the ack for every chunk.
        for chunk in data.chunked(size: writeChunkLength) {
            try await withPhase("writing data to the device", in: 5) { phase in
                self.writePhase = phase
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
        }
    }

    private func disconnect() {
        if let peripheral = targetPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        targetPeripheral = nil
        targetCharacteristic = nil
    }

    /// Stretch the image to 160x128 and convert to RGB565 (2 bytes per pixel,
    /// big-endian byte order). One array per line, like the Python script.
    private func encode(_ image: UIImage) throws -> [[UInt8]] {
        let w = imageWidth
        let h = imageHeight

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stretched = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        guard let cg = stretched.cgImage else { throw SketcherError.encodeFailed }
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
            )
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
            if let phase = self.poweredOnPhase {
                self.poweredOnPhase = nil
                if central.state == .poweredOn {
                    phase.finish(())
                } else if central.state == .unauthorized {
                    phase.fail(SketcherError.notAuthorized)
                } else {
                    phase.fail(SketcherError.notPoweredOn)
                }
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
            // Internal "find the saved device" scan during a send.
            if let targetID = self.acquireTargetID, peripheral.identifier == targetID {
                if let phase = self.acquirePhase {
                    self.acquirePhase = nil
                    self.stopScan()
                    phase.finish(peripheral)
                }
                return
            }

            guard self.status == .scanning else { return }
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
            if let phase = self.connectPhase {
                self.connectPhase = nil
                phase.finish(())
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if let phase = self.connectPhase {
                self.connectPhase = nil
                phase.fail(SketcherError.connectFailed(error?.localizedDescription))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if let phase = self.connectPhase {
                self.connectPhase = nil
                phase.fail(SketcherError.connectFailed(error?.localizedDescription))
            }
            if let phase = self.writePhase {
                self.writePhase = nil
                phase.fail(SketcherError.disconnected)
            }
            if self.status == .sending {
                self.errorMessage = SketcherError.disconnected.errorDescription
                self.status = .failed
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didWrite value: Data,
        for characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let phase = self.writePhase {
                self.writePhase = nil
                if let error {
                    phase.fail(SketcherError.disconnected)
                } else {
                    phase.finish(())
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension SketcherService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let phase = self.servicesPhase {
                self.servicesPhase = nil
                phase.finish(())
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristics characteristics: [CBCharacteristic],
        for service: CBService
    ) {
        Task { @MainActor in
            self.allCharacteristics.append(contentsOf: characteristics)
            self.receivedCharDiscovers += 1
            if self.receivedCharDiscovers >= self.expectedCharDiscovers,
               let phase = self.charsPhase {
                self.charsPhase = nil
                phase.finish(())
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationState error: Error?,
        for characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if let phase = self.notifyPhase {
                self.notifyPhase = nil
                if let error {
                    phase.fail(SketcherError.noWwritableCharacteristic)
                } else {
                    phase.finish(())
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let phase = self.writePhase {
                self.writePhase = nil
                if let error {
                    phase.fail(SketcherError.disconnected)
                } else {
                    phase.finish(())
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didReceive data: [UInt8],
        for characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if let targetCharacteristic, characteristic.uuid == targetCharacteristic.uuid {
                self.notifications += data.count > 0 ? 1 : 0
            }
        }
    }
}

// MARK: - Helpers
private extension Data {
    /// Splits the data into chunks of at most `size` bytes.
    func chunked(size: Int) -> [Data] {
        let size = Swift.max(size, 1)
        guard count > size else { return [self] }
        var chunks: [Data] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(subdata(in: start..<end))
            start = end
        }
        return chunks
    }
}
