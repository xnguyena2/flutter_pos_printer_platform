import 'dart:io';

import 'package:flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_image_3_sdt.dart';
import 'package:flutter_pos_printer_platform_image_3_sdt/src/connectors/bluetooth_universal.dart';

enum PrinterType { bluetooth, usb, network }

class PrinterManager {
  final bluetoothPrinterConnector = BluetoothPrinterUniversalConnector.instance;
  final bluetoothPrinterOldConnector = BluetoothPrinterConnector.instance;
  final tcpPrinterConnector = TcpPrinterConnector.instance;
  final usbPrinterConnector = UsbPrinterConnector.instance;

  PrinterManager._();

  static PrinterManager _instance = PrinterManager._();

  static PrinterManager get instance => _instance;

  Stream<PrinterDevice> discovery(
      {required PrinterType type, bool isBle = false, TcpPrinterInput? model}) {
    if (type == PrinterType.bluetooth &&
        (Platform.isIOS || Platform.isAndroid)) {
      if (Platform.isAndroid) {
        return bluetoothPrinterOldConnector.discovery(isBle: isBle);
      }
      return bluetoothPrinterConnector.discovery(isBle: isBle);
    } else if (type == PrinterType.usb &&
        (Platform.isAndroid || Platform.isWindows)) {
      return usbPrinterConnector.discovery();
    } else {
      return tcpPrinterConnector.discovery(model: model);
    }
  }

  Future<bool> connect(
      {required PrinterType type, required BasePrinterInput model}) async {
    if (type == PrinterType.bluetooth &&
        (Platform.isIOS || Platform.isAndroid)) {
      try {
        if (Platform.isAndroid) {
          return bluetoothPrinterOldConnector
              .connect(model as BluetoothPrinterInput);
        }
        return await bluetoothPrinterConnector
            .connect(model as BluetoothPrinterInput);
      } catch (e) {
        throw Exception('model must be type of BluetoothPrinterInput');
      }
    } else if (type == PrinterType.usb &&
        (Platform.isAndroid || Platform.isWindows)) {
      try {
        return await usbPrinterConnector.connect(model as UsbPrinterInput);
      } catch (e) {
        throw Exception('model must be type of UsbPrinterInput');
      }
    } else {
      try {
        return await tcpPrinterConnector.connect(model as TcpPrinterInput);
      } catch (e) {
        throw Exception('model must be type of TcpPrinterInput');
      }
    }
  }

  Future<bool> disconnect({required PrinterType type, int? delayMs}) async {
    if (type == PrinterType.bluetooth &&
        (Platform.isIOS || Platform.isAndroid)) {
      if (Platform.isAndroid) {
        return bluetoothPrinterOldConnector.disconnect();
      }
      return await bluetoothPrinterConnector.disconnect();
    } else if (type == PrinterType.usb &&
        (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.disconnect(delayMs: delayMs);
    } else {
      return await tcpPrinterConnector.disconnect();
    }
  }

  Future<bool> send(
      {required PrinterType type, required List<int> bytes}) async {
    if (type == PrinterType.bluetooth &&
        (Platform.isIOS || Platform.isAndroid)) {
      if (Platform.isAndroid) {
        return await bluetoothPrinterOldConnector.send(bytes);
      }
      return await bluetoothPrinterConnector.send(bytes);
    } else if (type == PrinterType.usb &&
        (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.send(bytes);
    } else {
      return await tcpPrinterConnector.send(bytes);
    }
  }

  Stream<BTStatus> get stateBluetooth => Platform.isAndroid
      ? bluetoothPrinterOldConnector.currentStatus.cast<BTStatus>()
      : bluetoothPrinterConnector.currentStatus.cast<BTStatus>();

  Stream<USBStatus> get stateUSB =>
      usbPrinterConnector.currentStatus.cast<USBStatus>();

  BTStatus get currentStatusBT => Platform.isAndroid
      ? bluetoothPrinterOldConnector.status
      : bluetoothPrinterConnector.status;

  USBStatus get currentStatusUSB => usbPrinterConnector.status;
}
