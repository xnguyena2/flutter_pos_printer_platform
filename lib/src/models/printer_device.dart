import 'dart:io';

class PrinterDevice {
  String name;
  late String operatingSystem;
  String? vendorId;
  String? productId;
  String? address;

  PrinterDevice(
      {required this.name, this.address, this.vendorId, this.productId}) {
    this.operatingSystem = Platform.operatingSystem;
  }

  PrinterDevice.web(
      {required this.name, this.address, this.vendorId, this.productId}) {
    this.operatingSystem = 'web';
  }
}
