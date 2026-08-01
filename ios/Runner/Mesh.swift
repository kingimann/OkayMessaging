import CoreBluetooth
import Flutter
import Foundation

/// Bluetooth mesh transport: every phone is a beacon and a listener at once.
///
/// iOS lets one app be a peripheral and a central at the same time, which is
/// the whole trick — without both, two phones can only talk if one of them
/// agreed in advance to be the server. Here each device advertises the service
/// below and scans for it, so any two in range connect, and anything either of
/// them hears gets passed on.
///
/// WHAT THIS FILE DOES NOT DO: look inside a frame. The bytes arriving from
/// Dart are already a sealed envelope, and they go back to Dart untouched.
/// There is no logging of frame contents here and there must never be — a
/// relayed message belongs to two strangers, and this is the one process on
/// the path that has no business with it.
///
/// FOREGROUND ONLY as shipped. `Info.plist` asks for no Bluetooth background
/// modes, so iOS stops the radio when the app suspends. The code below needs
/// no change to work in the background — adding `bluetooth-central` and
/// `bluetooth-peripheral` to `UIBackgroundModes` is all it takes — but
/// background advertising drops the local name and moves the service UUID into
/// the overflow area, where only a device explicitly scanning for this exact
/// UUID can see it. Discovery gets slow and uneven, and App Review asks about
/// those modes. Turn them on deliberately.
final class Mesh: NSObject {
  /// The service every OkayMessenger advertises and scans for. Fixed, because
  /// two phones that have never met have no way to agree on one.
  static let serviceUUID = CBUUID(string: "0A9E5C21-6F3B-4C7D-9E1A-2B8D4F60C3A7")

  /// One characteristic, written to and notified on. A frame is small enough
  /// that there is nothing to be gained from more.
  static let frameUUID = CBUUID(string: "0A9E5C22-6F3B-4C7D-9E1A-2B8D4F60C3A7")

  private var channel: FlutterMethodChannel?
  private var central: CBCentralManager?
  private var peripheral: CBPeripheralManager?

  /// Phones we have connected to, and the characteristic to write frames on.
  private var connected: [UUID: (CBPeripheral, CBCharacteristic?)] = [:]

  /// Phones subscribed to our own characteristic, i.e. listening to us.
  private var subscribers: [CBCentral] = []

  /// Frames we could not send yet because nothing was connected. Bounded —
  /// a phone alone in a field must not accumulate a day of messages in RAM.
  private var outbox: [Data] = []
  private static let maxOutbox = 200

  private var localCharacteristic: CBMutableCharacteristic?
  private var wantRunning = false

  static func register(with messenger: FlutterBinaryMessenger) -> Mesh {
    let mesh = Mesh()
    let channel = FlutterMethodChannel(name: "okay/mesh", binaryMessenger: messenger)
    mesh.channel = channel
    channel.setMethodCallHandler { [weak mesh] call, result in
      guard let mesh = mesh else {
        result(nil)
        return
      }
      switch call.method {
      case "available":
        // The frameworks exist on every iPhone this runs on; whether the radio
        // is on is a question only CBCentralManager can answer, and it answers
        // asynchronously. Saying yes here and reporting peers of zero is
        // honest — the user is told what is happening by the peer count, not
        // by a capability check that would have to block.
        result(true)
      case "start":
        mesh.start()
        result(nil)
      case "stop":
        mesh.stop()
        result(nil)
      case "send":
        guard let args = call.arguments as? [String: Any],
          let frames = args["frames"] as? [String]
        else {
          result(FlutterError(code: "bad_args", message: "frames required", details: nil))
          return
        }
        mesh.send(frames: frames)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return mesh
  }

  private func start() {
    guard !wantRunning else { return }
    wantRunning = true
    // Created lazily: instantiating either manager prompts for Bluetooth
    // permission, and an app that asks on launch for a feature the user has
    // not turned on is an app people say no to.
    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)
    }
    if peripheral == nil {
      peripheral = CBPeripheralManager(delegate: self, queue: .main)
    }
    startScanning()
    startAdvertising()
  }

  private func stop() {
    wantRunning = false
    central?.stopScan()
    peripheral?.stopAdvertising()
    for entry in connected.values {
      central?.cancelPeripheralConnection(entry.0)
    }
    connected.removeAll()
    subscribers.removeAll()
    outbox.removeAll()
    reportPeers()
  }

  private func startScanning() {
    guard wantRunning, central?.state == .poweredOn else { return }
    // Duplicates off: we want to know a phone is there, not be told sixty
    // times a second while it is.
    central?.scanForPeripherals(
      withServices: [Mesh.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
  }

  private func startAdvertising() {
    guard wantRunning, peripheral?.state == .poweredOn else { return }
    if localCharacteristic == nil {
      let characteristic = CBMutableCharacteristic(
        type: Mesh.frameUUID,
        properties: [.write, .writeWithoutResponse, .notify],
        value: nil,
        permissions: [.writeable])
      let service = CBMutableService(type: Mesh.serviceUUID, primary: true)
      service.characteristics = [characteristic]
      peripheral?.add(service)
      localCharacteristic = characteristic
    }
    peripheral?.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [Mesh.serviceUUID]
    ])
  }

  private func send(frames: [String]) {
    for frame in frames {
      guard let data = frame.data(using: .utf8) else { continue }
      if !deliver(data) {
        outbox.append(data)
        if outbox.count > Mesh.maxOutbox { outbox.removeFirst(outbox.count - Mesh.maxOutbox) }
      }
    }
  }

  /// Writes one frame to everything in range, both directions. Returns whether
  /// anybody took it.
  @discardableResult
  private func deliver(_ data: Data) -> Bool {
    var sent = false
    // To phones we connected to.
    for entry in connected.values {
      let peer = entry.0
      guard let characteristic = entry.1, peer.state == .connected else {
        continue
      }
      let type: CBCharacteristicWriteType =
        characteristic.properties.contains(.writeWithoutResponse)
        ? .withoutResponse : .withResponse
      peer.writeValue(data, for: characteristic, type: type)
      sent = true
    }
    // To phones that connected to us.
    if let characteristic = localCharacteristic, !subscribers.isEmpty {
      if peripheral?.updateValue(data, for: characteristic, onSubscribedCentrals: subscribers)
        == true
      {
        sent = true
      }
    }
    return sent
  }

  private func drainOutbox() {
    guard !outbox.isEmpty else { return }
    let pending = outbox
    outbox.removeAll()
    for data in pending where !deliver(data) {
      outbox.append(data)
    }
  }

  private func reportPeers() {
    channel?.invokeMethod("peers", arguments: connected.count + subscribers.count)
  }

  private func forward(_ data: Data, from peer: String) {
    guard let frame = String(data: data, encoding: .utf8) else { return }
    channel?.invokeMethod("frame", arguments: ["peer": peer, "frame": frame])
  }
}

extension Mesh: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn { startScanning() } else { reportPeers() }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard connected[peripheral.identifier] == nil else { return }
    connected[peripheral.identifier] = (peripheral, nil)
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Mesh.serviceUUID])
    reportPeers()
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    connected.removeValue(forKey: peripheral.identifier)
    reportPeers()
    // Keep looking: a phone that walked out of range may walk back in.
    startScanning()
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    connected.removeValue(forKey: peripheral.identifier)
    reportPeers()
  }
}

extension Mesh: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == Mesh.serviceUUID })
    else { return }
    peripheral.discoverCharacteristics([Mesh.frameUUID], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard
      let characteristic = service.characteristics?.first(where: { $0.uuid == Mesh.frameUUID })
    else { return }
    connected[peripheral.identifier] = (peripheral, characteristic)
    peripheral.setNotifyValue(true, for: characteristic)
    reportPeers()
    drainOutbox()
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let data = characteristic.value else { return }
    forward(data, from: peripheral.identifier.uuidString)
  }
}

extension Mesh: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn { startAdvertising() } else { reportPeers() }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    subscribers.append(central)
    reportPeers()
    drainOutbox()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    subscribers.removeAll { $0.identifier == central.identifier }
    reportPeers()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      guard let data = request.value else { continue }
      forward(data, from: request.central.identifier.uuidString)
    }
    if let first = requests.first {
      peripheral.respond(to: first, withResult: .success)
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    drainOutbox()
  }
}
