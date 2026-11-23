import CoreBluetooth
import Foundation

/// Ready-to-use CoreBluetooth central manager for future BLE functionality.
///
/// Not connected to any UI yet. The required `NSBluetoothAlwaysUsageDescription`
/// entry is already in Info.plist, so scanning/connecting can be added later
/// without touching project settings.
@MainActor
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var state: CBManagerState = .unknown

    private let centralManager = CBCentralManager(delegate: nil, queue: nil)

    override init() {
        super.init()
        centralManager.delegate = self
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.state = central.state
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {}

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {}

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {}
}
