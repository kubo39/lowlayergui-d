module vk_platform;

// erupted が wl_display / wl_surface の型を必要とするため公開インポート
public import wayland.native.client : wl_display, wl_proxy;
import erupted.platform_extensions;

// wayland-d では wl_surface は wl_proxy の typedef
alias wl_surface = wl_proxy;

// VK_KHR_wayland_surface に必要な型・関数ポインタを mixin で生成
mixin Platform_Extensions!USE_PLATFORM_WAYLAND_KHR;

// erupted.functions の loadInstanceLevelFunctions / loadDeviceLevelFunctions と
// mixin の alias が衝突するため、明示的な名前で再公開する
alias loadInstanceLevelFunctionsWithPlatform = loadInstanceLevelFunctionsExt;
alias loadDeviceLevelFunctionsWithPlatform   = loadDeviceLevelFunctionsExtD;
