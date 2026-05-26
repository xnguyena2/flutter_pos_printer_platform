import Flutter
import UIKit
import CoreBluetooth
import ObjCSupport

let NAMESPACE = "flutter_pos_printer_platform"

public class FlutterPosPrinterPlatformPlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    private var registrar: FlutterPluginRegistrar?
    private var channel: FlutterMethodChannel?
    private var stateStreamHandler: BluetoothPrintStreamHandler?
    private var scannedPeripherals: [String: CBPeripheral] = [:]
    
    // Tracks connection state using the block declaration from the underlying library
    public var state: ConnectDeviceState? 

    // Mapped to the macro '#define Manager [ConnecterManager sharedInstance]'
    private var Manager: ConnecterManager {
        return ConnecterManager.sharedInstance()
    }

    // MARK: - Flutter Plugin Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "\(NAMESPACE)/methods",
            binaryMessenger: registrar.messenger()
        )
        let stateChannel = FlutterEventChannel(
            name: "\(NAMESPACE)/state",
            binaryMessenger: registrar.messenger()
        )
        
        let instance = FlutterPosPrinterPlatformPlugin()
        instance.channel = channel
        instance.scannedPeripherals = [:]
        
        let stateStreamHandler = BluetoothPrintStreamHandler()
        stateChannel.setStreamHandler(stateStreamHandler)
        instance.stateStreamHandler = stateStreamHandler
        
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Method Channel Handling
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("call method -> \(call.method)")
        
        switch call.method {
        case "state":
            result(nil)
            
        case "isAvailable", "isOn":
            result(true)
            
        case "isConnected":
            result(false)
            
        case "startScan":
            print("getDevices method -> \(call.method)")
            self.scannedPeripherals.removeAll()
            
            if Manager.bleConnecter == nil {
                Manager.didUpdateState { [weak self] (state: Int) in
                    guard let self = self else { return }
                    switch state {
                    case 4: // CBCentralManagerStateUnsupported
                        print("The platform/hardware doesn't support Bluetooth Low Energy.")
                    case 3: // CBCentralManagerStateUnauthorized
                        print("The app is not authorized to use Bluetooth Low Energy.")
                    case 2: // CBCentralManagerStatePoweredOff
                        print("Bluetooth is currently powered off.")
                    case 5: // CBCentralManagerStatePoweredOn
                        self.startScan()
                        print("Bluetooth power on")
                    default:
                        break
                    }
                }
            } else {
                self.startScan()
            }
            result(nil)
            
        case "stopScan":
            Manager.stopScan()
            result(nil)
            
        case "connect":
            guard let device = call.arguments as? [String: Any],
                  let address = device["address"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing address target", details: nil))
                return
            }
            
            print("connect device begin -> \(device["name"] ?? "")")
            if let peripheral = self.scannedPeripherals[address] {
                self.state = { [weak self] (state: ConnectState) in
                    self?.updateConnectState(state)
                }
                
                // ✅ FIXED: Using modern SPM bridged name 'connect' and passing your state closure
                Manager.connect(peripheral, options: nil, timeout: 2, connectBlack: self.state)
            }
            result(nil)
            
        case "disconnect":
            Manager.close()
            result(nil)
            
        case "writeData":
            guard let args = call.arguments as? [String: Any],
                  let bytesList = args["bytes"] as? [Int],
                  let length = args["length"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid payload params", details: nil))
                return
            }
            
            // Replaces the character array logic with modern Swift Data buffers
            let byteArray = bytesList.prefix(length).map { UInt8($0) }
            let data = Data(byteArray)
            
            Manager.write(data)
            result(nil)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Core Bluetooth Operations
    private func startScan() {
        Manager.scanForPeripherals(withServices: nil, options: nil) { [weak self] (peripheral, advertisementData, RSSI) in
            guard let self = self, let peripheral = peripheral, let name = peripheral.name else { return }
            
            print("find device -> \(name)")
            let uuidString = peripheral.identifier.uuidString
            self.scannedPeripherals[uuidString] = peripheral
            
            let deviceData: [String: Any?] = [
                "address": uuidString,
                "name": name,
                "type": nil
            ]
            self.channel?.invokeMethod("ScanResult", arguments: deviceData)
        }
    }

    private func updateConnectState(_ state: ConnectState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var ret: Int = 0
            
            // ✅ FIXED: Using raw bridged names mapping perfectly to Swift Package Manager compilation
            switch state {
            case CONNECT_STATE_CONNECTING:
                print("status -> Connecting ...")
                ret = 1
            case CONNECT_STATE_CONNECTED:
                print("status -> Connection success")
                ret = 2
            case CONNECT_STATE_FAILT:
                print("status -> Connection failed")
                ret = 0
            case CONNECT_STATE_DISCONNECT:
                print("status -> Disconnected")
                ret = 0
            default:
                print("status -> Connection timed out")
                ret = 0
            }
            
            if let sink = self.stateStreamHandler?.sink {
                sink(ret)
            }
        }
    }
    
    // MARK: - CBCentralManagerDelegate Protocol Requirement
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Stub required for protocol conformity
    }
}

// MARK: - Event Stream Handler Implementation
public class BluetoothPrintStreamHandler: NSObject, FlutterStreamHandler {
    var sink: FlutterEventSink?

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.sink = nil
        return nil
    }
}