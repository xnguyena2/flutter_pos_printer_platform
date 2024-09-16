import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/discovery.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_image_3_sdt.dart';
import 'package:rxdart/rxdart.dart';
import 'package:universal_ble/universal_ble.dart';

class BluetoothPrinterInput extends BasePrinterInput {
  final String address;
  final String? name;
  final bool isBle;
  final bool autoConnect;
  BluetoothPrinterInput({
    required this.address,
    this.name,
    this.isBle = false,
    this.autoConnect = false,
  });
}

class BluetoothPrinterDevice {
  final String? address;

  BluetoothPrinterDevice({required this.address});
}

class BluetoothPrinterConnector
    implements PrinterConnector<BluetoothPrinterInput> {
  // ignore: unused_element
  BluetoothPrinterConnector._({this.address = "", this.isBle = false}) {
    if (kIsWeb) {
      // Get connection/disconnection updates
      UniversalBle.onConnectionChange = (String deviceId, bool isConnected) {
        debugPrint('OnConnectionChange $deviceId, $isConnected');

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
    if (Platform.isAndroid)
      flutterPrinterChannel.setMethodCallHandler((MethodCall call) {
        _methodStreamController.add(call);
        return Future(() => null);
      });

    if (Platform.isIOS)
      iosChannel.setMethodCallHandler((MethodCall call) {
        _methodStreamController.add(call);
        return Future(() => null);
      });

    if (Platform.isAndroid)
      flutterPrinterEventChannelBT.receiveBroadcastStream().listen((data) {
        if (data is int) {
          // log('Received event status: $data');
          _status = BTStatus.values[data];
          _statusStreamController.add(_status);
        }
      });

    if (Platform.isIOS) {
      //  iosChannel.invokeMethod('state').then((s) => s);
      iosStateChannel.receiveBroadcastStream().listen((data) {
        if (data is int) {
          // log('Received event status: $data');
          _status = BTStatus.values[data];
          _statusStreamController.add(_status);
        }
      });
    }
  }
  static BluetoothPrinterConnector _instance = BluetoothPrinterConnector._();

  static BluetoothPrinterConnector get instance => _instance;

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

  BluetoothPrinterConnector(
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
    if (kIsWeb) {
      AvailabilityState state =
          await UniversalBle.getBluetoothAvailabilityState();
// Start scan only if Bluetooth is powered on
      if (state == AvailabilityState.poweredOn) {
        final listBleDevice = await UniversalBle.getSystemDevices();

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
    if (Platform.isAndroid) {
      final List<dynamic> results = isBle
          ? await flutterPrinterChannel.invokeMethod('getBluetoothLeList')
          : await flutterPrinterChannel.invokeMethod('getBluetoothList');
      return results
          .map((dynamic r) => PrinterDiscovered<BluetoothPrinterDevice>(
                name: r['name'],
                detail: BluetoothPrinterDevice(
                  address: r['address'],
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
    Duration? timeout = const Duration(seconds: 7),
  }) async* {
    final killStreams = <Stream>[];
    killStreams.add(_stopScanPill);
    killStreams.add(Rx.timer(null, timeout!));
    // Clear scan results list
    _scanResults.add(<PrinterDevice>[]);

    if (kIsWeb) {
      AvailabilityState state =
          await UniversalBle.getBluetoothAvailabilityState();
// Start scan only if Bluetooth is powered on
      if (state == AvailabilityState.poweredOn) {
        UniversalBle.startScan(
            scanFilter: ScanFilter(
          withServices: [printingServicesUUID],
        )).onError(
          (error, stackTrace) {
            // print(error);
            // print(stackTrace);
          },
        ).catchError((e) {
          // print(e);
        });
        // scan result
        UniversalBle.onScanResult = (bleDevice) {
          this.bleDevice = bleDevice;
          String deviceId = bleDevice.deviceId;
          UniversalBle.connect(deviceId);
          // e.g. Use BleDevice ID to connect
          // print('found device: ');
          // print(bleDevice);
          var device = PrinterDevice.web(
              name: bleDevice.name ?? bleDevice.deviceId,
              address: bleDevice.deviceId);
          if (!_addDevice(device)) return;
          // yield device;
        };
      }

// Or listen to bluetooth availability changes
      // UniversalBle.onAvailabilityChange = (state) {
      //   if (state == AvailabilityState.poweredOn) {
      //     UniversalBle.startScan(
      //         scanFilter: ScanFilter(
      //       withServices: [printingServicesUUID],
      //     ));
      //   }
      // };
// Enable Bluetooth programmatically
      // UniversalBle.enableBluetooth();
    } else if (Platform.isAndroid) {
      isBle
          ? flutterPrinterChannel.invokeMethod('getBluetoothLeList')
          : flutterPrinterChannel.invokeMethod('getBluetoothList');

      await for (dynamic data in _methodStream
          .where((m) => m.method == "ScanResult")
          .map((m) => m.arguments)
          .takeUntil(Rx.merge(killStreams))
          // .takeUntil(TimerStream(3, Duration(seconds: 5)))
          .doOnDone(stopScan)
          .map((message) => message)) {
        var device = PrinterDevice(
            name: data['name'] as String, address: data['address'] as String?);
        if (!_addDevice(device)) continue;
        yield device;
      }
    } else if (Platform.isIOS) {
      try {
        await iosChannel.invokeMethod('startScan');
      } catch (e) {
        print('Error starting scan.');
        _stopScanPill.add(null);
        _isScanning.add(false);
        throw e;
      }

      await for (dynamic data in _methodStream
          .where((m) => m.method == "ScanResult")
          .map((m) => m.arguments)
          .takeUntil(Rx.merge(killStreams))
          .doOnDone(stopScan)
          .map((message) => message)) {
        print('Scan result: $data');
        final device = PrinterDevice(
            name: data['name'] as String, address: data['address'] as String?);
        if (!_addDevice(device)) continue;
        yield device;
      }
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
    await discovery(timeout: timeout).drain();
    return _scanResults.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
    if (kIsWeb) {
// Stop scanning
      UniversalBle.stopScan();
    } else if (Platform.isIOS) await iosChannel.invokeMethod('stopScan');
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  Future<bool> _connect({BluetoothPrinterInput? model}) async {
    if (kIsWeb) {
      String? deviceId = model?.address;
      if (deviceId != null) {
        UniversalBle.connect(deviceId);
      }
      return true;
    } else if (Platform.isAndroid) {
      Map<String, dynamic> params = {
        "address": model?.address ?? address,
        "isBle": model?.isBle ?? isBle,
        "autoConnect": model?.autoConnect ?? false
      };
      return await flutterPrinterChannel.invokeMethod(
          'onStartConnection', params);
    } else if (Platform.isIOS) {
      Map<String, dynamic> params = {
        "name": model?.name ?? name,
        "address": model?.address ?? address
      };
      return await iosChannel.invokeMethod('connect', params);
    }
    return false;
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
    if (kIsWeb) {
// Disconnect from a device
      final deviceId = bleDevice?.deviceId;
      if (deviceId != null) {
        UniversalBle.disconnect(deviceId);
      }
    } else if (Platform.isAndroid)
      await flutterPrinterChannel.invokeMethod('disconnect');
    else if (Platform.isIOS) await iosChannel.invokeMethod('disconnect');
    return false;
  }

  Future<dynamic> destroy() => iosChannel.invokeMethod('destroy');

  @override
  Future<bool> send(List<int> bytes) async {
    try {
      if (kIsWeb) {
        //send data to bluetooth device
        final deviceId = bleDevice?.deviceId;
        if (deviceId != null && bleHavePrintingServices) {
          final data = Uint8List.fromList(bytes);
          UniversalBle.writeValue(deviceId, printingServicesUUID,
              _characteristicUUID, data, BleOutputProperty.withoutResponse);
        }
        return true;
      } else if (Platform.isAndroid) {
        // final connected = await _connect();
        // if (!connected) return false;
        Map<String, dynamic> params = {"bytes": bytes};
        return await flutterPrinterChannel.invokeMethod('sendDataByte', params);
      } else if (Platform.isIOS) {
        Map<String, Object> args = Map();
        args['bytes'] = bytes;
        args['length'] = bytes.length;
        iosChannel.invokeMethod('writeData', args);
        return Future.value(true);
      } else {
        return false;
      }
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
