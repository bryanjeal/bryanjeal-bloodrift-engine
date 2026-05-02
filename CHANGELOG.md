# Engine Changelog

All changes to the Blood Rift Engine, newest first.

## [2026-05-01] Detect optimal SSBO upload path at init, fix MoltenVK coherency

**Summary:** On macOS with MoltenVK (unified memory), `vkCmdCopyBuffer` between two
`MTLStorageModeShared` buffers can be a no-op because they share physical memory,
causing GPU cache-coherency bugs (MoltenVK issue #1846).  The fix detects the
memory type at init and picks the optimal upload path: `vkCmdCopyBuffer` via
staging buffer for discrete GPUs, `vkCmdUpdateBuffer` directly from host pointer
for unified memory.  Also adds `IMMEDIATE_KHR` present-mode fallback for older
MoltenVK versions that lack `MAILBOX_KHR`.

**Changes:**
- `vulkan/backend.zig`: Added `UploadMethod` enum + `upload_method` field.
  `createInstanceBuffer` tries `DEVICE_LOCAL` first; on failure creates a single
  `HOST_VISIBLE` buffer (no staging).  `submitQueue` dispatches to `vkCmdCopyBuffer`
  (discrete) or chunked `vkCmdUpdateBuffer` (unified).  Barrier changed from global
  `vk.MemoryBarrier` to `vk.BufferMemoryBarrier` targeting the SSBO.
- `vulkan/swapchain.zig`: `choosePresentMode` now prefers `MAILBOX_KHR` >
  `IMMEDIATE_KHR` > `FIFO_KHR` for uncapped FPS on MoltenVK versions that do not
  expose `MAILBOX_KHR`.

## [2026-04-12] Replace runtime vtable Renderer with comptime backend abstraction

**Summary:** Remove the runtime vtable-based Renderer abstraction and replace it with a comptime-validated backend selection layer. Backends are now chosen at build time via `-Dbackend=` and validated at compile time via `assertRendererInterface`.

**Changes:**
- `build.zig`: Added `Renderer` enum (`vulkan`, `webgpu`, `opengl`), `parseRendererOption()`, `build_options` module with `addOptions` so .zig code can import `build_options`
- `renderer.zig`: Removed vtable-based `Renderer` struct (ptr + vtable + VTable + wrappers). Added `assertRendererInterface(comptime T: type)` for comptime backend validation. Renamed `MaterialDef.vertex_spv`/`fragment_spv` to `vertex_shader`/`fragment_shader`. Added `ShaderPayload` type (comptime switch on selected_renderer).
- `renderer/root.zig`: `Renderer` is now comptime `switch (build_options.renderer) { .vulkan => VulkanBackend, ... }`. Added `comptime { _ = assertRendererInterface(Renderer); }` guard.
- `vulkan/backend.zig`: Removed `renderer()` method and ~40 lines of vtable shim functions. Changed `mat.vertex_spv`/`fragment_spv` to `mat.vertex_shader`/`fragment_shader`. Fixed SSBO flush to read `non_coherent_atom_size` and use `std.mem.alignForward`.
- `vulkan/device.zig`: Added `properties: vk.PhysicalDeviceProperties` field to `DeviceState`, populated in `init()` via `getPhysicalDeviceProperties`.
- `vulkan/pipeline.zig`: Changed shader params from `[]const u8` to `[]align(@alignOf(u32)) const u8`. Removed runtime `@alignCast`.

**Breaking changes:**
- `MaterialDef.vertex_spv` and `fragment_spv` renamed to `vertex_shader` and `fragment_shader`
- `VulkanBackend.renderer()` method removed -- use `Renderer` (comptime alias) directly
- `build_options` module now required (added via `addOptions` in build.zig)