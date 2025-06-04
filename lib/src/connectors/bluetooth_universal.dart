import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/discovery.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_image_3_sdt.dart';
import 'package:rxdart/rxdart.dart';
import 'package:universal_ble/universal_ble.dart';

class BluetoothPrinterUniversalConnector
    implements PrinterConnector<BluetoothPrinterInput> {
  // ignore: unused_element
  BluetoothPrinterUniversalConnector._(
      {this.address = "", this.isBle = false}) {
    // Get connection/disconnection updates
    UniversalBle.onConnectionChange =
        (String deviceId, bool isConnected, String? error) {
      debugPrint('OnConnectionChange $deviceId, $isConnected, $error');

      if (deviceId == bleDevice?.deviceId) {
        // log('Received event status: $data');

        if (isConnected) {
          UniversalBle.discoverServices(deviceId).then(
            (value) {
              for (var element in value) {
                if (element.uuid.toUpperCase() == printingServicesUUID) {
                  for (var element in element.characteristics) {
                    if (element.properties.contains(
                        CharacteristicProperty.writeWithoutResponse)) {
                      // print('servicesUUID: $printingServicesUUID');
                      // print('characteristicUUID: ${element.uuid}');
                      _characteristicUUID = element.uuid;
                      bleHavePrintingServices = true;

                      _status =
                          isConnected ? BTStatus.connected : BTStatus.none;
                      _statusStreamController.add(_status);
                    }
                  }
                }
              }
            },
          );
          return;
        }
        bleHavePrintingServices = false;
        _status = isConnected ? BTStatus.connected : BTStatus.none;
        _statusStreamController.add(_status);
      }
    };
    return;
  }
  static BluetoothPrinterUniversalConnector _instance =
      BluetoothPrinterUniversalConnector._();

  static BluetoothPrinterUniversalConnector get instance => _instance;

  Stream<MethodCall> get _methodStream => _methodStreamController.stream;
  final StreamController<MethodCall> _methodStreamController =
      StreamController.broadcast();
  PublishSubject _stopScanPill = new PublishSubject();

  BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  Stream<bool> get isScanning => _isScanning.stream;

  BehaviorSubject<List<PrinterDevice>> _scanResults =
      BehaviorSubject.seeded([]);
  Stream<List<PrinterDevice>> get scanResults => _scanResults.stream;

  Stream<BTStatus> get _statusStream => _statusStreamController.stream;
  final StreamController<BTStatus> _statusStreamController =
      StreamController.broadcast();

  BluetoothPrinterUniversalConnector(
      {required this.address, required this.isBle, this.name}) {
    flutterPrinterChannel.setMethodCallHandler((MethodCall call) {
      _methodStreamController.add(call);
      return Future(() => null);
    });
  }

  static final String printingServicesUUID =
      'E7810A71-73AE-499D-8C15-FAA9AEF0C3F2';
  static final String characteristicUUID =
      'BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F';
  BleDevice? bleDevice;
  bool bleHavePrintingServices = false;
  String _characteristicUUID = '';

  String address;
  String? name;
  bool isBle;
  BTStatus _status = BTStatus.none;
  BTStatus get status => _status;

  StreamController<String> devices = new StreamController.broadcast();

  setAddress(String address) => this.address = address;
  setName(String name) => this.name = name;
  setIsBle(bool isBle) => this.isBle = isBle;

  static DiscoverResult<BluetoothPrinterDevice> discoverPrinters(
      {bool isBle = false}) async {
    AvailabilityState state =
        await UniversalBle.getBluetoothAvailabilityState();
// Start scan only if Bluetooth is powered on
    if (state == AvailabilityState.poweredOn) {
      final withServices =
          Platform.isIOS || Platform.isMacOS ? [printingServicesUUID] : null;
      final listBleDevice =
          await UniversalBle.getSystemDevices(withServices: withServices);

      return listBleDevice
          .map((BleDevice r) => PrinterDiscovered<BluetoothPrinterDevice>(
                name: r.name ?? r.deviceId,
                detail: BluetoothPrinterDevice(
                  address: r.deviceId,
                ),
              ))
          .toList();
    }
    return [];
  }

  /// Starts a scan for Bluetooth Low Energy devices
  /// Timeout closes the stream after a specified [Duration]
  /// this device is low energy [isBle]
  Stream<PrinterDevice> discovery({
    bool isBle = false,
    Duration timeout = const Duration(seconds: 7),
  }) async* {
    final killStreams = <Stream<dynamic>>[
      _stopScanPill,
      Rx.timer(null, timeout),
    ];

    // Clear previous scan results
    _scanResults.add(<PrinterDevice>[]);

    AvailabilityState state =
        await UniversalBle.getBluetoothAvailabilityState();

    if (state == AvailabilityState.poweredOn) {
      try {
        UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [printingServicesUUID]),
        );

        yield* UniversalBle.scanStream
            .takeUntil(Rx.merge(killStreams))
            .map((bleDevice) {
          this.bleDevice = bleDevice;
          final device = PrinterDevice.web(
            name: bleDevice.name ?? bleDevice.deviceId,
            address: bleDevice.deviceId,
          );
          _addDevice(device);
          return device;
        });
      } catch (e) {
        print('Scan error: $e');
        yield* Stream.empty(); // fallback nếu lỗi
      }
    } else {
      print("Bluetooth not powered on");
      yield* Stream.empty(); // không bật Bluetooth thì không yield
    }
  }

  bool _addDevice(PrinterDevice device) {
    bool isDeviceAdded = true;
    final list = _scanResults.value;
    if (!list.any((e) => e.address == device.address))
      list.add(device);
    else
      isDeviceAdded = false;
    _scanResults.add(list);
    return isDeviceAdded;
  }

  /// Start a scan for Bluetooth Low Energy devices
  Future startScan({
    Duration? timeout,
  }) async {
    await discovery(timeout: timeout ?? const Duration(seconds: 7)).drain();
    return _scanResults.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
// Stop scanning
    UniversalBle.stopScan();
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  Future<bool> _connect({BluetoothPrinterInput? model}) async {
    String? deviceId = model?.address;
    if (deviceId != null) {
      UniversalBle.connect(deviceId);
    }
    return true;
  }

  /// Gets the current state of the Bluetooth module
  Stream<BTStatus> get currentStatus async* {
    // if (Platform.isAndroid) {
    yield* _statusStream.cast<BTStatus>();

    /*} else if (Platform.isIOS) {
      await iosChannel.invokeMethod('state').then((s) => s);
      await for (dynamic data in iosStateChannel.receiveBroadcastStream().map((s) => s)) {
        if (data is int) {
          yield BTStatus.values[data];
        }
      }
      // yield* iosStateChannel.receiveBroadcastStream().map((s) => s);
    }*/
  }

  PrinterDevice? getWebBleDevice() {
    if (bleDevice == null) {
      return null;
    }
    return PrinterDevice.web(
        name: bleDevice!.name ?? bleDevice!.deviceId,
        address: bleDevice!.deviceId);
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    final deviceId = bleDevice?.deviceId;
    if (deviceId != null) {
      UniversalBle.disconnect(deviceId);
      return true;
    }
    return false;
  }

  Future<dynamic> destroy() => iosChannel.invokeMethod('destroy');

  @override
  Future<bool> send(List<int> bytes) async {
    try {
      //send data to bluetooth device
      final deviceId = bleDevice?.deviceId;
      if (deviceId != null && bleHavePrintingServices) {
        final data = Uint8List.fromList(bytes);
        UniversalBle.writeValue(deviceId, printingServicesUUID,
            _characteristicUUID, data, BleOutputProperty.withoutResponse);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> connect(BluetoothPrinterInput model) async {
    try {
      return await _connect(model: model);
    } catch (e) {
      return false;
    }
  }
}
