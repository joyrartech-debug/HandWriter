//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <pasteboard/pasteboard_plugin.h>
#include <printing/printing_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  PasteboardPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PasteboardPlugin"));
  PrintingPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PrintingPlugin"));
}
