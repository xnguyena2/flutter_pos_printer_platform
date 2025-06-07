import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/discovery.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_image_3_sdt.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:universal_ble/universal_ble.dart';

class BluetoothPrinterUniversalConnector
    implements PrinterConnector<BluetoothPrinterInput> {
  // ignore: unused_element
  BluetoothPrinterUniversalConnector._({
    this.address = "",
    this.isBle = false,
  }) {
    // Get connection/disconnection updates
    UniversalBle.onConnectionChange =
        (String deviceId, bool isConnected, String? error) {
      debugPrint('OnConnectionChange $deviceId, $isConnected, $error');

      if (isConnected) {
        UniversalBle.discoverServices(deviceId).then((value) {
          for (var element in value) {
            if (element.uuid.toUpperCase() == printingServicesUUID) {
              for (var element in element.characteristics) {
                if (element.properties.contains(
                  CharacteristicProperty.writeWithoutResponse,
                )) {
                  print('servicesUUID: $printingServicesUUID');
                  print('characteristicUUID: ${element.uuid}');
                  _characteristicUUID = element.uuid.toUpperCase();
                  bleHavePrintingServices = true;

                  _status = isConnected ? BTStatus.connected : BTStatus.none;
                  _statusStreamController.add(_status);
                }
              }
            }
          }
        });
        return;
      }
      bleHavePrintingServices = false;
      _status = isConnected ? BTStatus.connected : BTStatus.none;
      _statusStreamController.add(_status);
    };
    return;
  }
  static BluetoothPrinterUniversalConnector _instance =
      BluetoothPrinterUniversalConnector._();

  static BluetoothPrinterUniversalConnector get instance => _instance;

  PublishSubject _stopScanPill = new PublishSubject();

  BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  Stream<bool> get isScanning => _isScanning.stream;

  BehaviorSubject<List<PrinterDevice>> _scanResults = BehaviorSubject.seeded(
    [],
  );
  Stream<List<PrinterDevice>> get scanResults => _scanResults.stream;

  Stream<BTStatus> get _statusStream => _statusStreamController.stream;
  final StreamController<BTStatus> _statusStreamController =
      StreamController.broadcast();

  BluetoothPrinterUniversalConnector({
    required this.address,
    required this.isBle,
    this.name,
  });

  static final String printingServicesUUID =
      'E7810A71-73AE-499D-8C15-FAA9AEF0C3F2';
  static final String characteristicUUID =
      'BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F';
  bool bleHavePrintingServices = false;
  String _characteristicUUID = characteristicUUID;
  String currentDeviceID = '';

  String address;
  String? name;
  bool isBle;
  BTStatus _status = BTStatus.none;
  BTStatus get status => _status;

  StreamController<String> devices = new StreamController.broadcast();

  setAddress(String address) => this.address = address;
  setName(String name) => this.name = name;
  setIsBle(bool isBle) => this.isBle = isBle;

  static DiscoverResult<BluetoothPrinterDevice> discoverPrinters({
    bool isBle = false,
  }) async {
    await requestBluetoothPermissions();
    AvailabilityState state =
        await UniversalBle.getBluetoothAvailabilityState();
    // Start scan only if Bluetooth is powered on
    if (state == AvailabilityState.poweredOn) {
      final withServices =
          Platform.isIOS || Platform.isMacOS ? [printingServicesUUID] : null;
      final listBleDevice = await UniversalBle.getSystemDevices(
        withServices: withServices,
      );

      return listBleDevice
          .map(
            (BleDevice r) => PrinterDiscovered<BluetoothPrinterDevice>(
              name: r.name ?? r.deviceId,
              detail: BluetoothPrinterDevice(address: r.deviceId),
            ),
          )
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
    await requestBluetoothPermissions();

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
          final device = PrinterDevice.web(
            name: bleDevice.name ?? bleDevice.deviceId,
            address: bleDevice.deviceId,
          );
          return device;
        }).where((device) => _addDevice(device));
      } catch (e) {
        print('Scan error: $e');
        yield* Stream.empty(); // fallback nếu lỗi
      }
    } else {
      print("Bluetooth not powered on");
      yield* Stream.empty(); // không bật Bluetooth thì không yield
    }
  }

  static Future<void> requestBluetoothPermissions() async {
    if (await Permission.bluetoothScan.isDenied) {
      await Permission.bluetoothScan.request();
    }

    if (await Permission.bluetoothConnect.isDenied) {
      await Permission.bluetoothConnect.request();
    }

    if (await Permission.locationWhenInUse.isDenied) {
      await Permission.locationWhenInUse.request();
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
  Future startScan({Duration? timeout}) async {
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
      currentDeviceID = deviceId;
      await UniversalBle.connect(deviceId);
      return true;
    }
    return false;
  }

  /// Gets the current state of the Bluetooth module
  Stream<BTStatus> get currentStatus async* {
    yield* _statusStream.cast<BTStatus>();
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    final deviceId = currentDeviceID;
    if (deviceId.isNotEmpty) {
      UniversalBle.disconnect(deviceId);
      return true;
    }
    return false;
  }

  @override
  Future<bool> send(List<int> bytes) async {
    try {
      //send data to bluetooth device
      final deviceId = currentDeviceID;
      print('send data length: ${bytes.length} to bluetooth device: $deviceId');
      if (deviceId.isNotEmpty) {
        final data = Uint8List.fromList(bytes);
        await UniversalBle.writeValue(
          deviceId,
          printingServicesUUID,
          _characteristicUUID,
          data,
          BleOutputProperty.withoutResponse,
        );
      }
      return true;
    } catch (e) {
      print(e);
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
