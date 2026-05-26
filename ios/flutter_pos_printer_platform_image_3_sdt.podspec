#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_pos_printer_platform.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_pos_printer_platform_image_3_sdt'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_pos_printer_platform_image_3_sdt/Sources/flutter_pos_printer_platform_image_3_sdt/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Import all * .a libraries in the Classes folder
  s.frameworks = ["SystemConfiguration", "CoreTelephony","WebKit"]
  s.vendored_libraries = '**/*.a'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
