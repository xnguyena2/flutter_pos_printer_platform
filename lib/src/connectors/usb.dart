import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/discovery.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_image_3_sdt.dart';
import 'package:usb_device/usb_device.dart';

class UsbPrinterInput extends BasePrinterInput {
  final String? name;
  final String? vendorId;
  final String? productId;
  UsbPrinterInput({
    this.name,
    this.vendorId,
    this.productId,
  });
}

class UsbPrinterInfo {
  String vendorId;
  String productId;
  String manufacturer;
  String product;
  String name;
  String? model;
  bool isDefault = false;
  String deviceId;
  UsbPrinterInfo.Android({
    required this.vendorId,
    required this.productId,
    required this.manufacturer,
    required this.product,
    required this.name,
    required this.deviceId,
  });
  UsbPrinterInfo.Windows({
    required this.name,
    required this.model,
    required this.isDefault,
    this.vendorId = '',
    this.productId = '',
    this.manufacturer = '',
    this.product = '',
    this.deviceId = '',
  });
}

class UsbPrinterConnector implements PrinterConnector<UsbPrinterInput> {
  UsbPrinterConnector._()
      : vendorId = '',
        productId = '',
        name = '' {
    if (kIsWeb) {
      return;
    }
    if (Platform.isAndroid)
      flutterPrinterEventChannelUSB.receiveBroadcastStream().listen((data) {
        if (data is int) {
          // log('Received event status usb: $data');
          _status = USBStatus.values[data];
          _statusStreamController.add(_status);
        }
      });
  }

  static UsbPrinterConnector _instance = UsbPrinterConnector._();

  static UsbPrinterConnector get instance => _instance;

  Stream<USBStatus> get _statusStream => _statusStreamController.stream;
  final StreamController<USBStatus> _statusStreamController =
      StreamController.broadcast();

  UsbPrinterConnector.Android({required this.vendorId, required this.productId})
      : name = '';
  UsbPrinterConnector.Windows({required this.name})
      : vendorId = '',
        productId = '';

  String vendorId;
  String productId;
  String name;
  USBStatus _status = USBStatus.none;
  USBStatus get status => _status;

  setVendor(String vendorId) => this.vendorId = vendorId;
  setProduct(String productId) => this.productId = productId;
  setName(String name) => this.name = name;

  /// Gets the current state of the Bluetooth module
  Stream<USBStatus> get currentStatus async* {
    if (kIsWeb || Platform.isAndroid) {
      yield* _statusStream.cast<USBStatus>();
    }
  }

  static DiscoverResult<UsbPrinterInfo> discoverPrinters() async {
    if (kIsWeb) {
      //Ignore web
    } else if (Platform.isAndroid) {
      final List<dynamic> results =
          await flutterPrinterChannel.invokeMethod('getList');
      return results
          .map((dynamic r) => PrinterDiscovered<UsbPrinterInfo>(
                name: r['product'],
                detail: UsbPrinterInfo.Android(
                  vendorId: r['vendorId'],
                  productId: r['productId'],
                  manufacturer: r['manufacturer'],
                  product: r['product'],
                  name: r['name'],
                  deviceId: r['deviceId'],
                ),
              ))
          .toList();
    }
    if (Platform.isWindows) {
      final List<dynamic> results =
          await flutterPrinterChannel.invokeMethod('getList');
      return results
          .map((dynamic result) => PrinterDiscovered<UsbPrinterInfo>(
                name: result['name'],
                detail: UsbPrinterInfo.Windows(
                    isDefault: result['default'],
                    name: result['name'],
                    model: result['model']),
              ))
          .toList();
    }
    return [];
  }

  Stream<PrinterDevice> discovery() async* {
    if (kIsWeb) {
      //Ignore web
    } else if (Platform.isAndroid) {
      final List<dynamic> results =
          await flutterPrinterChannel.invokeMethod('getList');
      for (final device in results) {
        var r = await device;
        //print("---------------------" + name);
        //print(r);
        // fix: unknown usb device product is NULL
        var name = (r['product'] ?? r['name']) ?? 'unknown device';
        yield PrinterDevice(
          name: name,
          vendorId: r['vendorId'],
          productId: r['productId'],
          // name: r['name'],
        );
      }
    } else if (Platform.isWindows) {
      final List<dynamic> results =
          await flutterPrinterChannel.invokeMethod('getList');
      for (final device in results) {
        var r = await device;
        yield PrinterDevice(
          name: r['name'],
          // model: r['model'],
        );
      }
    }
  }

  final UsbDevice usbDevice = UsbDevice();
  var pairedDevice;
  //By Default, it is usually 0
  final int interfaceNumber = 0;

  //By Default, it is usually 1
  final int endpointNumber = 1;
  Future<bool> _connect({UsbPrinterInput? model}) async {
    if (kIsWeb) {
      pairedDevice ??= await usbDevice.requestDevices([
        DeviceFilter(
          vendorId: int.parse(model?.vendorId ?? vendorId),
          productId: int.parse(model?.productId ?? productId),
        )
      ]);
      await usbDevice.open(pairedDevice);
      await usbDevice.claimInterface(pairedDevice, interfaceNumber);
    } else if (Platform.isAndroid) {
      Map<String, dynamic> params = {
        "vendor": int.parse(model?.vendorId ?? vendorId),
        "product": int.parse(model?.productId ?? productId)
      };
      return await flutterPrinterChannel.invokeMethod('connectPrinter', params);
    } else if (Platform.isWindows) {
      Map<String, dynamic> params = {"name": model?.name ?? name};
      return await flutterPrinterChannel.invokeMethod(
                  'connectPrinter', params) ==
              1
          ? true
          : false;
    }
    return false;
  }

  Future<bool> _close() async {
    if (kIsWeb) {
      await usbDevice.close(pairedDevice);
      return true;
    } else if (Platform.isWindows)
      return await flutterPrinterChannel.invokeMethod('close') == 1
          ? true
          : false;
    return false;
  }

  @override
  Future<bool> connect(UsbPrinterInput model) async {
    try {
      return await _connect(model: model);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      return await _close();
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> send(List<int> bytes) async {
    if (kIsWeb) {
      final result = await usbDevice.transferOut(
          pairedDevice, endpointNumber, Uint8List.fromList(bytes).buffer);
      // print(result.status);
      return true;
    } else if (Platform.isAndroid)
      try {
        // final connected = await _connect();
        // if (!connected) return false;
        Map<String, dynamic> params = {"bytes": bytes};
        return await flutterPrinterChannel.invokeMethod('printBytes', params);
      } catch (e) {
        return false;
      }
    else if (Platform.isWindows)
      try {
        Map<String, dynamic> params = {"bytes": Uint8List.fromList(bytes)};
        return await flutterPrinterChannel.invokeMethod('printBytes', params) ==
                1
            ? true
            : false;
      } catch (e) {
        await this._close();
        return false;
      }
    else
      return false;
  }
}
