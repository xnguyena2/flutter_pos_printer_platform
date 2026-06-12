import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const MethodChannel channel = MethodChannel('flutter_pos_printer');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // THAY THẾ setMockMethodCallHandler bằng cách dùng TestDefaultBinaryMessenger
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '42';
        });
  });

  tearDown(() {
    // Khi xóa handler, bạn truyền null vào cho channel tương ứng
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    // Code test của bạn ở đây
  });
}
