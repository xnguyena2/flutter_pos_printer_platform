//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_pos_printer_platform_image_3_sdt/flutter_pos_printer_platform_plugin.h>
#include <universal_ble/universal_ble_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterPosPrinterPlatformPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterPosPrinterPlatformPlugin"));
  UniversalBlePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UniversalBlePluginCApi"));
}
