// Vulkan backend - implements the Renderer vtable with DOD render queue.
//
// Owns all Vulkan state. SDL3 Vulkan surface is created here via @cImport;
// no SDL Vulkan types escape this file.
//
// Architecture:
//   - Instance data uploaded to a host-visible SSBO each frame.
//   - Single push constant for VP matrix (shared across all instances).
//   - Per-material pipelines bound once; instanced draw per material range.
//   - Total draw calls = number of unique materials, not number of entities.
//
// Design decisions referenced:
//   S3: Vulkan first rendering backend; abstraction layer hides backend types
//   S33: DOD render queue, SSBO instancing, build-time material baking

const std = @import("std");
const vk = @import("vulkan");
const zgui = @import("zgui");
const tracy = @import("ztracy");
const renderer_mod = @import("../renderer.zig");
const instance_mod = @import("instance.zig");
const device_mod = @import("device.zig");
const swapchain_mod = @import("swapchain.zig");
const pipeline_mod = @import("pipeline.zig");
const commands_mod = @import("commands.zig");

// SDL3 Vulkan functions - not exposed beyond this file.
const c = @cImport({
    @cInclude("SDL3/SDL_vulkan.h");
});

// Unit quad: two triangles covering a 1x1 world-space square centred at origin.
// The VP matrix push constant and per-instance SSBO data place it in screen space.
const quad_verts = [12]f32{
    -0.5, -0.5, 0.5, -0.5, 0.5,  0.5,
    -0.5, -0.5, 0.5, 0.5,  -0.5, 0.5,
};

/// Maximum number of instances the SSBO can hold.
/// ~2 million instances * 96 bytes = 201,326,592 KB (~201 MB). Trivial for host-visible memory.
pub const max_instances: u32 = 1 << 21;

/// Maximum number of material pipelines that can be registered.
pub const max_materials: usize = 64;

/// SSBO push constant layout: VP matrix only (64 bytes, vertex stage).
const FramePushData = extern struct {
    vp: [16]f32, // view-projection matrix (column-major), bytes 0-63
};

comptime {
    std.debug.assert(@sizeOf(FramePushData) == 64);
}

/// How instance data reaches the SSBO each frame.  Chosen at init time based on
/// whether DEVICE_LOCAL memory is available (discrete GPU) or we fall back to
/// HOST_VISIBLE (unified memory: Apple Silicon, Intel iGPU).
const UploadMethod = enum {
    /// Discrete GPU path: memcpy to staging buffer + vkCmdCopyBuffer (DMA).
    staging_copy,
    /// Unified-memory path: vkCmdUpdateBuffer directly from host pointer.
    update_buffer,
};

pub const VulkanBackend = struct {
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
    instance: instance_mod.InstanceState,
    device: device_mod.DeviceState,
    swapchain: swapchain_mod.SwapchainState,
    pipeline: pipeline_mod.PipelineState,
    commands: commands_mod.CommandState,
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    imgui_descriptor_pool: vk.DescriptorPool,
    // Instance SSBO: per-instance data read by shaders, updated each frame
    // via either staging_copy (discrete GPU) or update_buffer (unified memory).
    instance_buffer: vk.Buffer,
    instance_buffer_memory: vk.DeviceMemory,
    upload_method: UploadMethod,
    // Staging buffer: only used when upload_method == .staging_copy.
    // Host-visible, CPU writes via memcpy, GPU reads via vkCmdCopyBuffer.
    staging_buffer: vk.Buffer,
    staging_memory: vk.DeviceMemory,
    staging_ptr: [*]u8,
    // Descriptor set for SSBO binding.
    descriptor_pool: vk.DescriptorPool,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    // Material pipelines: indexed by material_id (game-assigned u16).
    material_pipelines: [max_materials]vk.Pipeline,
    material_layouts: [max_materials]vk.PipelineLayout,
    material_count: usize,
    // Per-frame state (valid between beginFrame and present).
    current_frame: u32,
    current_image: u32,
    current_vp: [16]f32,
    /// Swapchain is invalid (window resized, display changed, etc.). Frame
    /// methods no-op while set; cleared by resize() after successful recreation.
    /// Prevents the OutOfDateKHR / SuboptimalKHR crash path from propagating.
    is_stale: bool,
    // GPU timestamp query pool: two slots per frame (begin + end of render pass).
    // .null_handle when the physical device reports timestamp_period == 0 (no support).
    timestamp_query_pool: vk.QueryPool = .null_handle,
    // Nanoseconds per timestamp tick; from VkPhysicalDeviceLimits.timestampPeriod.
    timestamp_period_ns: f64 = 0.0,
    // Set to true after the first successful begin+end pair so we know
    // the previous frame's slots contain valid data to read back.
    have_timestamp_prev: [commands_mod.max_frames_in_flight]bool =
        [_]bool{false} ** commands_mod.max_frames_in_flight,

    /// Open a Vulkan context attached to an SDL3 window.
    ///
    /// On macOS, VK_ICD_FILENAMES must point to MoltenVK_icd.json before calling
    /// this function. Use `zig build run` which sets it automatically, or set the
    /// environment variable before launching the binary directly.
    ///
    /// `materials` is a slice of MaterialDef loaded by the game during its init
    /// phase (e.g. from @embedFile, VFS, or .pak). No disk I/O occurs here.
    pub fn init(
        allocator: std.mem.Allocator,
        window: anytype,
        width: u32,
        height: u32,
        materials: []const renderer_mod.MaterialDef,
    ) !VulkanBackend {
        std.debug.assert(width > 0 and height > 0);
        const loader = try getSdlLoader();
        const sdl_exts = try getSdlExtensions(allocator);
        defer allocator.free(sdl_exts);
        const inst = try instance_mod.init(loader, sdl_exts, allocator);
        errdefer {
            var inst_copy = inst;
            instance_mod.deinit(&inst_copy);
        }
        const surface = try createSurface(window, inst.handle);
        errdefer inst.vki.destroySurfaceKHR(inst.handle, surface, null);
        const dev = try device_mod.init(inst.vki, inst.handle, surface, allocator);
        errdefer {
            var dev_copy = dev;
            device_mod.deinit(&dev_copy);
        }
        const sc = try swapchain_mod.init(
            inst.vki,
            dev.vkd,
            dev.physical,
            dev.handle,
            surface,
            dev.families.graphics,
            dev.families.present,
            width,
            height,
            allocator,
        );
        errdefer {
            var sc_copy = sc;
            swapchain_mod.deinit(&sc_copy, dev.vkd, dev.handle);
        }
        const pip = try pipeline_mod.init(dev.vkd, dev.handle, sc.format);
        errdefer {
            var pip_copy = pip;
            pipeline_mod.deinit(&pip_copy, dev.vkd, dev.handle);
        }
        const cmds = try commands_mod.init(
            dev.vkd,
            dev.handle,
            dev.families.graphics,
            &sc,
            &pip,
            allocator,
        );
        errdefer {
            var cmds_copy = cmds;
            commands_mod.deinit(&cmds_copy, dev.vkd, dev.handle);
        }
        const vb = try createVertexBuffer(inst.vki, dev.vkd, dev.handle, dev.physical);
        const imgui_pool = try createImguiDescriptorPool(dev.vkd, dev.handle);
        errdefer dev.vkd.destroyDescriptorPool(dev.handle, imgui_pool, null);

        // Create SSBO for instance data (upload path auto-detected).
        const ssbo = try createInstanceBuffer(
            inst.vki,
            dev.vkd,
            dev.handle,
            dev.physical,
            max_instances * @sizeOf(renderer_mod.InstanceData),
        );
        errdefer {
            if (ssbo.upload_method == .staging_copy) {
                dev.vkd.destroyBuffer(dev.handle, ssbo.staging, null);
                dev.vkd.freeMemory(dev.handle, ssbo.staging_memory, null);
            }
            dev.vkd.destroyBuffer(dev.handle, ssbo.ssbo, null);
            dev.vkd.freeMemory(dev.handle, ssbo.ssbo_memory, null);
        }

        // Create descriptor set layout + pool + set for the SSBO.
        const ds = try createInstanceDescriptor(
            dev.vkd,
            dev.handle,
            ssbo.ssbo,
        );
        errdefer {
            dev.vkd.destroyDescriptorSetLayout(dev.handle, ds.layout, null);
            dev.vkd.destroyDescriptorPool(dev.handle, ds.pool, null);
        }

        // Create per-material pipelines from the pre-loaded MaterialDef slice.
        var mat_pipelines: [max_materials]vk.Pipeline = undefined;
        var mat_layouts: [max_materials]vk.PipelineLayout = undefined;
        var mat_count: usize = 0;
        for (materials) |mat| {
            if (mat_count >= max_materials) break;
            const push_range = vk.PushConstantRange{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(FramePushData),
            };
            const layout = try dev.vkd.createPipelineLayout(dev.handle, &.{
                .set_layout_count = 1,
                .p_set_layouts = @ptrCast(&ds.layout),
                .push_constant_range_count = 1,
                .p_push_constant_ranges = @ptrCast(&push_range),
            }, null);
            errdefer dev.vkd.destroyPipelineLayout(dev.handle, layout, null);

            const pipeline = try pipeline_mod.createMaterialPipeline(
                dev.vkd,
                dev.handle,
                pip.render_pass,
                layout,
                sc.extent,
                mat.vertex_shader,
                mat.fragment_shader,
                mat.blend_enable,
            );
            errdefer dev.vkd.destroyPipeline(dev.handle, pipeline, null);
            // Pipeline stored at the material_id index for O(1) lookup.
            std.debug.assert(mat.material_id < max_materials);
            mat_pipelines[mat.material_id] = pipeline;
            mat_layouts[mat.material_id] = layout;
            mat_count += 1;
        }

        // Dear ImGui - SDL3 + Vulkan backend.
        // VK_NO_PROTOTYPES is set by zgui's build, so we must provide a function
        // loader before calling backend.init.
        zgui.init(allocator);
        const instance_ptr: ?*anyopaque = @ptrFromInt(@intFromEnum(inst.handle));
        _ = zgui.backend.loadFunctions(@bitCast(vk.API_VERSION_1_2), imguiVkLoader, instance_ptr);
        zgui.backend.init(.{
            .api_version = @bitCast(vk.API_VERSION_1_2),
            .instance = @ptrFromInt(@intFromEnum(inst.handle)),
            .physical_device = @ptrFromInt(@intFromEnum(dev.physical)),
            .device = @ptrFromInt(@intFromEnum(dev.handle)),
            .queue_family = dev.families.graphics,
            .queue = @ptrFromInt(@intFromEnum(dev.graphics_queue)),
            .descriptor_pool = @ptrFromInt(@intFromEnum(imgui_pool)),
            .render_pass = @ptrFromInt(@intFromEnum(pip.render_pass)),
            .min_image_count = commands_mod.max_frames_in_flight,
            .image_count = @intCast(sc.image_views.len),
        }, @ptrCast(window));

        // GPU timestamp query pool for Tracy gpu_frame_us plot.
        // Skip setup when timestamp_period == 0 (device does not support timestamps).
        // All subsequent logic gates on timestamp_query_pool != .null_handle.
        const ts_period: f64 = dev.properties.limits.timestamp_period;
        var ts_pool: vk.QueryPool = .null_handle;
        if (ts_period > 0.0) {
            const pool_info = vk.QueryPoolCreateInfo{
                .query_type = .timestamp,
                .query_count = commands_mod.max_frames_in_flight * 2,
            };
            ts_pool = try dev.vkd.createQueryPool(dev.handle, &pool_info, null);
            errdefer dev.vkd.destroyQueryPool(dev.handle, ts_pool, null);
        }

        return .{
            .allocator = allocator,
            .surface = surface,
            .instance = inst,
            .device = dev,
            .swapchain = sc,
            .pipeline = pip,
            .commands = cmds,
            .vertex_buffer = vb.buffer,
            .vertex_buffer_memory = vb.memory,
            .imgui_descriptor_pool = imgui_pool,
            .instance_buffer = ssbo.ssbo,
            .instance_buffer_memory = ssbo.ssbo_memory,
            .upload_method = ssbo.upload_method,
            .staging_buffer = ssbo.staging,
            .staging_memory = ssbo.staging_memory,
            .staging_ptr = ssbo.staging_ptr,
            .descriptor_pool = ds.pool,
            .descriptor_set_layout = ds.layout,
            .descriptor_set = ds.set,
            .material_pipelines = mat_pipelines,
            .material_layouts = mat_layouts,
            .material_count = mat_count,
            .current_frame = 0,
            .is_stale = false,
            .current_image = 0,
            .current_vp = [_]f32{0} ** 16,
            .timestamp_query_pool = ts_pool,
            .timestamp_period_ns = ts_period,
        };
    }

    pub fn deinit(self: *VulkanBackend) void {
        _ = self.device.vkd.deviceWaitIdle(self.device.handle) catch {};
        zgui.backend.deinit();
        zgui.deinit();
        // Destroy material pipelines and layouts.
        for (0..self.material_count) |i| {
            self.device.vkd.destroyPipeline(self.device.handle, self.material_pipelines[i], null);
            self.device.vkd.destroyPipelineLayout(self.device.handle, self.material_layouts[i], null);
        }
        self.device.vkd.destroyDescriptorSetLayout(self.device.handle, self.descriptor_set_layout, null);
        self.device.vkd.destroyDescriptorPool(self.device.handle, self.descriptor_pool, null);
        self.device.vkd.destroyBuffer(self.device.handle, self.instance_buffer, null);
        self.device.vkd.freeMemory(self.device.handle, self.instance_buffer_memory, null);
        if (self.upload_method == .staging_copy) {
            self.device.vkd.unmapMemory(self.device.handle, self.staging_memory);
            self.device.vkd.destroyBuffer(self.device.handle, self.staging_buffer, null);
            self.device.vkd.freeMemory(self.device.handle, self.staging_memory, null);
        }
        self.device.vkd.destroyDescriptorPool(self.device.handle, self.imgui_descriptor_pool, null);
        if (self.timestamp_query_pool != .null_handle) {
            self.device.vkd.destroyQueryPool(self.device.handle, self.timestamp_query_pool, null);
        }
        commands_mod.deinit(&self.commands, self.device.vkd, self.device.handle);
        pipeline_mod.deinit(&self.pipeline, self.device.vkd, self.device.handle);
        self.device.vkd.destroyBuffer(self.device.handle, self.vertex_buffer, null);
        self.device.vkd.freeMemory(self.device.handle, self.vertex_buffer_memory, null);
        swapchain_mod.deinit(&self.swapchain, self.device.vkd, self.device.handle);
        device_mod.deinit(&self.device);
        self.instance.vki.destroySurfaceKHR(self.instance.handle, self.surface, null);
        instance_mod.deinit(&self.instance);
        self.* = undefined;
    }

    // =========================================================================
    // Frame interface
    // =========================================================================

    pub fn beginFrame(self: *VulkanBackend, camera: renderer_mod.CameraData) !void {
        self.current_vp = camera.vp;
        // Self-heal if the swapchain was marked stale by a prior frame.
        // Query the current surface extent (Vulkan's authoritative framebuffer
        // size after resize / display-change) and rebuild. If the surface is
        // minimised (0x0), we leave is_stale set and ImGui newFrame below
        // will run with the last-known extent, keeping lifecycle valid.
        if (self.is_stale) {
            const caps = self.instance.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(self.device.physical, self.surface) catch |err| {
                std.log.warn("renderer: surface caps query failed during stale recovery: {s}", .{@errorName(err)});
                // Fall through; we'll try again next frame.
                zgui.backend.newFrame(self.swapchain.extent.width, self.swapchain.extent.height);
                // No GPU work was recorded this frame; mark the slot invalid so the
                // next beginFrame does not try to read back stale timestamp data.
                self.have_timestamp_prev[self.current_frame] = false;
                return;
            };
            if (caps.current_extent.width > 0 and caps.current_extent.height > 0) {
                self.resize(caps.current_extent.width, caps.current_extent.height) catch |err| {
                    std.log.warn("renderer: stale-recovery resize failed: {s}", .{@errorName(err)});
                    zgui.backend.newFrame(self.swapchain.extent.width, self.swapchain.extent.height);
                    self.have_timestamp_prev[self.current_frame] = false;
                    return;
                };
                // resize() clears is_stale on success; fall through to normal path.
            } else {
                // Minimised or zero-size - keep frame lifecycle balanced and skip work.
                zgui.backend.newFrame(self.swapchain.extent.width, self.swapchain.extent.height);
                self.have_timestamp_prev[self.current_frame] = false;
                return;
            }
        }
        // Always start ImGui frame FIRST so client ui_draw has a valid
        // WithinFrameScope even when the swapchain is stale (resize mid-frame).
        // endFrame closes ImGui's frame cleanly via zgui.endFrame() if stale,
        // instead of trying to record ImGui draws into a non-recording cmd buffer.
        zgui.backend.newFrame(self.swapchain.extent.width, self.swapchain.extent.height);
        if (self.is_stale) return;
        const frame = self.current_frame;
        const sync = &self.commands.sync[frame];
        const dev = self.device.handle;
        const vkd = self.device.vkd;
        _ = try vkd.waitForFences(dev, 1, @ptrCast(&sync.in_flight), vk.TRUE, std.math.maxInt(u64));
        // OutOfDateKHR / SuboptimalKHR signal the swapchain is stale (resize,
        // display change). Mark stale + no-op this frame; resize() clears.
        const acquire = vkd.acquireNextImageKHR(dev, self.swapchain.handle, std.math.maxInt(u64), sync.image_available, .null_handle) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.is_stale = true;
                self.have_timestamp_prev[frame] = false;
                return;
            },
            else => return err,
        };
        self.current_image = acquire.image_index;
        if (acquire.result == .suboptimal_khr) {
            self.is_stale = true;
            self.have_timestamp_prev[frame] = false;
            return;
        }
        try vkd.resetFences(dev, 1, @ptrCast(&sync.in_flight));
        try vkd.resetCommandBuffer(self.commands.buffers[frame], .{});
        try vkd.beginCommandBuffer(self.commands.buffers[frame], &.{ .flags = .{ .one_time_submit_bit = true } });
        if (self.timestamp_query_pool != .null_handle) {
            // After waitForFences above, the GPU has finished the previous frame's
            // work for this slot, so the previous frame's query results are ready.
            if (self.have_timestamp_prev[frame]) {
                var timestamps: [2]u64 = undefined;
                const result = vkd.getQueryPoolResults(
                    dev,
                    self.timestamp_query_pool,
                    @as(u32, @intCast(frame)) * 2,
                    2,
                    @sizeOf([2]u64),
                    &timestamps,
                    @sizeOf(u64),
                    .{ .@"64_bit" = true },
                ) catch |err| if (err == error.NotReady) null else return err;
                if (result != null) {
                    // Wrapping subtraction handles the rare rollover case cleanly.
                    const delta_ticks: u64 = timestamps[1] -% timestamps[0];
                    const delta_ns: f64 = @as(f64, @floatFromInt(delta_ticks)) * self.timestamp_period_ns;
                    const delta_us: u64 = @as(u64, @intFromFloat(delta_ns / 1000.0));
                    tracy.PlotU("gpu_frame_us", delta_us);
                }
            }
            // Reset this frame's two slots before recording new timestamps.
            vkd.cmdResetQueryPool(
                self.commands.buffers[frame],
                self.timestamp_query_pool,
                @as(u32, @intCast(frame)) * 2,
                2,
            );
            // Begin timestamp at the earliest measurable pipeline stage.
            vkd.cmdWriteTimestamp(
                self.commands.buffers[frame],
                .{ .top_of_pipe_bit = true },
                self.timestamp_query_pool,
                @as(u32, @intCast(frame)) * 2,
            );
        }
    }

    /// Submit a sorted render queue.  Uploads instance data to the SSBO, then
    /// issues one instanced draw per material range.
    ///
    /// Upload path (chosen at init):
    ///   staging_copy: memcpy -> flush -> vkCmdCopyBuffer -> TRANSFER barrier
    ///   update_buffer: vkCmdUpdateBuffer (chunked) -> TRANSFER barrier
    pub fn submitQueue(self: *VulkanBackend, queue: renderer_mod.RenderQueue) !void {
        if (self.is_stale) return;
        const cmd = self.commands.buffers[self.current_frame];
        const vkd = self.device.vkd;
        const dev = self.device.handle;

        // Upload instance data OUTSIDE the render pass.
        if (queue.count > 0) {
            const upload_size = queue.count * @sizeOf(renderer_mod.InstanceData);

            switch (self.upload_method) {
                .staging_copy => {
                    // Discrete GPU: memcpy to staging, flush, DMA copy.
                    const atom_size = self.device.properties.limits.non_coherent_atom_size;
                    const flush_size = std.mem.alignForward(u64, upload_size, atom_size);
                    @memcpy(self.staging_ptr[0..upload_size], @as([*]const u8, @ptrCast(queue.instances.ptr))[0..upload_size]);
                    const flush_range = vk.MappedMemoryRange{
                        .memory = self.staging_memory,
                        .offset = 0,
                        .size = flush_size,
                    };
                    // HOST_COHERENT memory was requested: the GPU automatically
                    // sees CPU writes without an explicit flush.  The call is a
                    // defensive no-op; if it somehow fails, the barrier below
                    // still ensures correct ordering.
                    _ = vkd.flushMappedMemoryRanges(dev, 1, @ptrCast(&flush_range)) catch {};
                    const copy_region = vk.BufferCopy{
                        .src_offset = 0,
                        .dst_offset = 0,
                        .size = upload_size,
                    };
                    vkd.cmdCopyBuffer(cmd, self.staging_buffer, self.instance_buffer, 1, @ptrCast(&copy_region));
                },
                .update_buffer => {
                    // Unified memory: vkCmdUpdateBuffer reads directly from the
                    // host pointer, avoiding the cache-coherency issue of
                    // vkCmdCopyBuffer on MoltenVK (issue #1846).  Chunked to
                    // respect maxUpdateBufferSize (guaranteed >= 65536).
                    const src: [*]const u8 = @ptrCast(queue.instances.ptr);
                    var offset: vk.DeviceSize = 0;
                    while (offset < upload_size) {
                        const chunk: vk.DeviceSize = @min(upload_size - offset, 65536);
                        vkd.cmdUpdateBuffer(cmd, self.instance_buffer, offset, chunk, src + offset);
                        offset += chunk;
                    }
                },
            }

            // Buffer memory barrier: TRANSFER_WRITE -> SHADER_READ.
            const buf_barrier = vk.BufferMemoryBarrier{
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = self.instance_buffer,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            };
            vkd.cmdPipelineBarrier(
                cmd,
                .{ .transfer_bit = true },
                .{ .vertex_shader_bit = true, .fragment_shader_bit = true },
                .{},
                0,
                null,
                1,
                @ptrCast(&buf_barrier),
                0,
                null,
            );
        }

        // Begin render pass (always — ImGui draws in endFrame need it).
        const clear = vk.ClearValue{ .color = .{ .float_32 = .{ 0.05, 0.05, 0.05, 1.0 } } };
        vkd.cmdBeginRenderPass(cmd, &.{
            .render_pass = self.pipeline.render_pass,
            .framebuffer = self.commands.framebuffers[self.current_image],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");
        // Viewport + scissor are DYNAMIC pipeline state (see pipeline.zig). Set
        // them from the current swapchain extent each frame so resize takes
        // effect immediately without pipeline recreation. If these were static
        // state, rendering would continue at the original window size forever.
        const vp = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain.extent.width),
            .height = @floatFromInt(self.swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent };
        vkd.cmdSetViewport(cmd, 0, 1, @ptrCast(&vp));
        vkd.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));
        // Bind the shared vertex buffer (unit quad) once for the entire frame.
        const offset: vk.DeviceSize = 0;
        vkd.cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffer), @ptrCast(&offset));
        // Bind the instance SSBO descriptor set for the entire frame.
        vkd.cmdBindDescriptorSets(
            cmd,
            .graphics,
            self.material_layouts[0],
            0,
            1,
            @ptrCast(&self.descriptor_set),
            0,
            null,
        );

        if (queue.count == 0) return;

        // Push VP matrix as a single push constant.
        const push = FramePushData{ .vp = self.current_vp };
        vkd.cmdPushConstants(
            cmd,
            self.material_layouts[0],
            .{ .vertex_bit = true },
            0,
            @sizeOf(FramePushData),
            &push,
        );

        // Draw each material range with its own pipeline.
        var prev_material: u16 = std.math.maxInt(u16);
        for (queue.ranges[0..queue.range_count]) |range| {
            std.debug.assert(range.material_id < max_materials);
            if (range.material_id != prev_material) {
                vkd.cmdBindPipeline(cmd, .graphics, self.material_pipelines[range.material_id]);
                prev_material = range.material_id;
            }
            vkd.cmdDraw(cmd, 6, range.instance_count, 0, range.first_instance);
        }
    }

    pub fn endFrame(self: *VulkanBackend) !void {
        if (self.is_stale) {
            // Swapchain stale - close ImGui frame without recording draws into
            // a (non-recording) Vulkan command buffer. Keeps ImGui's internal
            // NewFrame/EndFrame pairing balanced so the next non-stale tick
            // starts from a clean slate.
            zgui.endFrame();
            // No end timestamp was written; ensure the next beginFrame skips
            // readback for this slot to avoid reading stale query data.
            self.have_timestamp_prev[self.current_frame] = false;
            return;
        }
        const frame = self.current_frame;
        const vkd = self.device.vkd;
        const cmd = self.commands.buffers[frame];
        // Render ImGui draw data inside the render pass (after all game draws).
        zgui.backend.render(@ptrFromInt(@intFromEnum(cmd)));
        vkd.cmdEndRenderPass(cmd);
        if (self.timestamp_query_pool != .null_handle) {
            // Write the end timestamp at the last measurable stage inside the
            // render pass lifetime. Must come after cmdEndRenderPass.
            vkd.cmdWriteTimestamp(
                cmd,
                .{ .bottom_of_pipe_bit = true },
                self.timestamp_query_pool,
                @as(u32, @intCast(frame)) * 2 + 1,
            );
            self.have_timestamp_prev[frame] = true;
        }
        try vkd.endCommandBuffer(cmd);
        const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const sync = &self.commands.sync[frame];
        try vkd.queueSubmit(self.device.graphics_queue, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&sync.image_available),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmd),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&sync.render_finished),
        }}, sync.in_flight);
    }

    pub fn present(self: *VulkanBackend) !void {
        if (self.is_stale) return;
        const sync = &self.commands.sync[self.current_frame];
        // queuePresentKHR returns OutOfDateKHR / SuboptimalKHR when the
        // swapchain is stale (resize, display change). Catch + mark stale
        // + swallow; resize() clears the flag after recreating the swapchain.
        const present_result = self.device.vkd.queuePresentKHR(self.device.present_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&sync.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .p_image_indices = @ptrCast(&self.current_image),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.is_stale = true;
                return;
            },
            else => return err,
        };
        if (present_result == .suboptimal_khr) {
            self.is_stale = true;
            return;
        }
        self.current_frame = (self.current_frame + 1) % commands_mod.max_frames_in_flight;
    }

    /// Recreate swapchain and framebuffers for a new window size.
    /// Called after the window is resized. Waits for GPU idle first.
    pub fn resize(self: *VulkanBackend, width: u32, height: u32) !void {
        std.debug.assert(width > 0 and height > 0);
        try self.device.vkd.deviceWaitIdle(self.device.handle);
        // Stale flag cleared on successful recreation (end of this fn).
        self.is_stale = false;

        // Destroy old framebuffers (they depend on swapchain image views).
        for (self.commands.framebuffers) |fb| {
            self.device.vkd.destroyFramebuffer(self.device.handle, fb, null);
        }
        self.allocator.free(self.commands.framebuffers);

        // Destroy old swapchain (image views + VkSwapchainKHR).
        swapchain_mod.deinit(&self.swapchain, self.device.vkd, self.device.handle);

        // Create new swapchain at the new size.
        self.swapchain = try swapchain_mod.init(
            self.instance.vki,
            self.device.vkd,
            self.device.physical,
            self.device.handle,
            self.surface,
            self.device.families.graphics,
            self.device.families.present,
            width,
            height,
            self.allocator,
        );

        // Recreate framebuffers with the new swapchain image views.
        self.commands.framebuffers = try commands_mod.createFramebuffers(
            self.device.vkd,
            self.device.handle,
            &self.swapchain,
            &self.pipeline,
            self.allocator,
        );
    }

    // =========================================================================
    // SDL integration (macOS / cross-platform)
    // =========================================================================

    fn getSdlLoader() !vk.PfnGetInstanceProcAddr {
        const fn_ptr = c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.VkGetProcAddrNull;
        return @ptrCast(fn_ptr);
    }

    fn getSdlExtensions(allocator: std.mem.Allocator) ![][*:0]const u8 {
        var count: u32 = 0;
        const ptr = c.SDL_Vulkan_GetInstanceExtensions(&count) orelse return error.SdlExtensionsNull;
        const exts = try allocator.alloc([*:0]const u8, count);
        for (ptr[0..count], exts) |src, *dst| dst.* = src;
        return exts;
    }

    fn createSurface(window: anytype, instance: vk.Instance) !vk.SurfaceKHR {
        const c_window: *c.SDL_Window = @ptrCast(window);
        const c_instance: c.VkInstance = @ptrFromInt(@intFromEnum(instance));
        var raw_surface: c.VkSurfaceKHR = undefined;
        if (!c.SDL_Vulkan_CreateSurface(c_window, c_instance, null, &raw_surface)) {
            return error.SurfaceCreationFailed;
        }
        return @enumFromInt(@intFromPtr(raw_surface));
    }
};

// Force the compiler to check this struct against the interface definition
// the moment this file is parsed.
comptime {
    renderer_mod.assertRendererInterface(VulkanBackend);
}

// ============================================================================
// Dear ImGui helpers
// ============================================================================

/// Create a small descriptor pool for ImGui's font texture atlas.
fn createImguiDescriptorPool(vkd: vk.DeviceWrapper, device: vk.Device) !vk.DescriptorPool {
    const pool_size = vk.DescriptorPoolSize{
        .type = .combined_image_sampler,
        .descriptor_count = 1,
    };
    return vkd.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
}

/// Vulkan function loader shim for Dear ImGui (required because zgui uses
/// VK_NO_PROTOTYPES - Vulkan symbols are not statically linked).
/// user_data carries the VkInstance pointer; SDL provides the proc address.
fn imguiVkLoader(
    name: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    const raw = c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return null;
    // vkGetInstanceProcAddr signature: fn(VkInstance, name) -> PFN_vkVoidFunction.
    // We treat both the instance and the return value as opaque pointers.
    const get_proc: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(raw);
    return get_proc(user_data, name);
}

// ============================================================================
// Buffer helpers
// ============================================================================

/// Create a host-visible, host-coherent vertex buffer containing the unit quad.
fn createVertexBuffer(
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    physical: vk.PhysicalDevice,
) !struct { buffer: vk.Buffer, memory: vk.DeviceMemory } {
    const size: vk.DeviceSize = @sizeOf(@TypeOf(quad_verts));
    const buf = try vkd.createBuffer(device, &.{
        .size = size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer vkd.destroyBuffer(device, buf, null);

    const mem_req = vkd.getBufferMemoryRequirements(device, buf);
    const mem_type = try findMemoryType(
        vki,
        physical,
        mem_req.memory_type_bits,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    const mem = try vkd.allocateMemory(device, &.{
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type,
    }, null);
    errdefer vkd.freeMemory(device, mem, null);

    try vkd.bindBufferMemory(device, buf, mem, 0);
    const raw_ptr = (try vkd.mapMemory(device, mem, 0, size, .{})) orelse
        return error.MapMemoryReturnedNull;
    const typed_ptr: [*]f32 = @ptrCast(@alignCast(raw_ptr));
    @memcpy(typed_ptr[0..quad_verts.len], &quad_verts);
    vkd.unmapMemory(device, mem);

    return .{ .buffer = buf, .memory = mem };
}

/// Create SSBO for instance data, detecting the optimal upload path.
///
/// Tries DEVICE_LOCAL memory first (discrete GPU: fast DMA path via staging +
/// vkCmdCopyBuffer).  Falls back to HOST_VISIBLE (unified memory: Apple Silicon,
/// Intel iGPU) where vkCmdUpdateBuffer reads directly from the host pointer
/// without a staging copy, avoiding MoltenVK cache-coherency bugs
/// (MoltenVK issue #1846).
fn createInstanceBuffer(
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    physical: vk.PhysicalDevice,
    size: vk.DeviceSize,
) !struct {
    ssbo: vk.Buffer,
    ssbo_memory: vk.DeviceMemory,
    upload_method: UploadMethod,
    staging: vk.Buffer,
    staging_memory: vk.DeviceMemory,
    staging_ptr: [*]u8,
} {
    const ssbo = try vkd.createBuffer(device, &.{
        .size = size,
        .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer vkd.destroyBuffer(device, ssbo, null);

    const mem_req = vkd.getBufferMemoryRequirements(device, ssbo);

    if (findMemoryType(vki, physical, mem_req.memory_type_bits, .{ .device_local_bit = true })) |dev_local_idx| {
        // Discrete GPU: device-local SSBO + host-visible staging.
        const ssbo_mem = try vkd.allocateMemory(device, &.{
            .allocation_size = mem_req.size,
            .memory_type_index = dev_local_idx,
        }, null);
        errdefer vkd.freeMemory(device, ssbo_mem, null);
        try vkd.bindBufferMemory(device, ssbo, ssbo_mem, 0);

        const staging = try vkd.createBuffer(device, &.{
            .size = size,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        errdefer vkd.destroyBuffer(device, staging, null);

        const staging_mem_req = vkd.getBufferMemoryRequirements(device, staging);
        const staging_mem_type = try findMemoryType(
            vki,
            physical,
            staging_mem_req.memory_type_bits,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        const staging_mem = try vkd.allocateMemory(device, &.{
            .allocation_size = staging_mem_req.size,
            .memory_type_index = staging_mem_type,
        }, null);
        errdefer vkd.freeMemory(device, staging_mem, null);
        try vkd.bindBufferMemory(device, staging, staging_mem, 0);

        const raw_ptr = (try vkd.mapMemory(device, staging_mem, 0, size, .{})) orelse
            return error.MapMemoryReturnedNull;

        return .{
            .ssbo = ssbo,
            .ssbo_memory = ssbo_mem,
            .upload_method = .staging_copy,
            .staging = staging,
            .staging_memory = staging_mem,
            .staging_ptr = @ptrCast(@alignCast(raw_ptr)),
        };
    } else |_| {
        // Unified memory: no dedicated VRAM.  Use HOST_VISIBLE directly;
        // vkCmdUpdateBuffer reads from the host pointer each frame without
        // a staging memcpy or intermediate copy.
        const host_idx = try findMemoryType(
            vki,
            physical,
            mem_req.memory_type_bits,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        const ssbo_mem = try vkd.allocateMemory(device, &.{
            .allocation_size = mem_req.size,
            .memory_type_index = host_idx,
        }, null);
        errdefer vkd.freeMemory(device, ssbo_mem, null);
        try vkd.bindBufferMemory(device, ssbo, ssbo_mem, 0);

        return .{
            .ssbo = ssbo,
            .ssbo_memory = ssbo_mem,
            .upload_method = .update_buffer,
            .staging = .null_handle,
            .staging_memory = .null_handle,
            .staging_ptr = undefined,
        };
    }
}

/// Create descriptor set layout, pool, and set for the instance SSBO.
/// The SSBO is bound at set 0, binding 0 for all material pipelines.
fn createInstanceDescriptor(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    instance_buffer: vk.Buffer,
) !struct { layout: vk.DescriptorSetLayout, pool: vk.DescriptorPool, set: vk.DescriptorSet } {
    // Layout: one SSBO binding at set=0, binding=0.
    const binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
    };
    const layout = try vkd.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer vkd.destroyDescriptorSetLayout(device, layout, null);

    // Pool: one SSBO descriptor.
    const pool_size = vk.DescriptorPoolSize{
        .type = .storage_buffer,
        .descriptor_count = 1,
    };
    const pool = try vkd.createDescriptorPool(device, &.{
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer vkd.destroyDescriptorPool(device, pool, null);

    // Allocate the descriptor set.
    var set: vk.DescriptorSet = undefined;
    _ = try vkd.allocateDescriptorSets(device, &.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&layout),
    }, @ptrCast(&set));

    // Write the SSBO buffer info into the descriptor set.
    const buf_info = vk.DescriptorBufferInfo{
        .buffer = instance_buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    vkd.updateDescriptorSets(device, 1, &[_]vk.WriteDescriptorSet{.{
        .dst_set = set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&buf_info),
        .p_texel_buffer_view = undefined,
    }}, 0, null);

    return .{ .layout = layout, .pool = pool, .set = set };
}

/// Find the first memory type index satisfying both the type filter and required flags.
fn findMemoryType(
    vki: vk.InstanceWrapper,
    physical: vk.PhysicalDevice,
    type_filter: u32,
    required_flags: vk.MemoryPropertyFlags,
) !u32 {
    const props = vki.getPhysicalDeviceMemoryProperties(physical);
    const required_u32: u32 = @bitCast(required_flags);
    for (0..props.memory_type_count) |i| {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if (type_filter & bit == 0) continue;
        const mem_flags_u32: u32 = @bitCast(props.memory_types[i].property_flags);
        if (mem_flags_u32 & required_u32 == required_u32) return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}
