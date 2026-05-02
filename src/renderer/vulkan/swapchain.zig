// Vulkan swapchain, image views.
//
// Owns: VkSwapchainKHR, image view array (heap-allocated).
// Callers must call deinit() to release resources.

const std = @import("std");
const vk = @import("vulkan");

// ============================================================================
// Types
// ============================================================================

pub const SwapchainState = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,
    image_views: []vk.ImageView,
    allocator: std.mem.Allocator,
};

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init(
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    physical: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    graphics_family: u32,
    present_family: u32,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,
) !SwapchainState {
    const caps = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface);
    const format = try chooseFormat(vki, physical, surface, allocator);
    const present_mode = try choosePresentMode(vki, physical, surface, allocator);
    const extent = chooseExtent(caps, width, height);
    const handle = try createSwapchain(
        vkd,
        device,
        surface,
        caps,
        format,
        present_mode,
        extent,
        graphics_family,
        present_family,
    );
    errdefer vkd.destroySwapchainKHR(device, handle, null);
    const image_views = try createImageViews(vkd, device, handle, format.format, allocator);
    return .{
        .handle = handle,
        .format = format.format,
        .extent = extent,
        .image_views = image_views,
        .allocator = allocator,
    };
}

pub fn deinit(state: *SwapchainState, vkd: vk.DeviceWrapper, device: vk.Device) void {
    for (state.image_views) |view| vkd.destroyImageView(device, view, null);
    state.allocator.free(state.image_views);
    vkd.destroySwapchainKHR(device, state.handle, null);
    state.* = undefined;
}

// ============================================================================
// Format, present mode, extent selection
// ============================================================================

fn chooseFormat(
    vki: vk.InstanceWrapper,
    physical: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.SurfaceFormatKHR {
    const formats = try vki.getPhysicalDeviceSurfaceFormatsAllocKHR(physical, surface, allocator);
    defer allocator.free(formats);
    std.debug.assert(formats.len > 0);
    for (formats) |f| {
        if (f.format == .b8g8r8a8_srgb and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

fn choosePresentMode(
    vki: vk.InstanceWrapper,
    physical: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.PresentModeKHR {
    const modes = try vki.getPhysicalDeviceSurfacePresentModesAllocKHR(physical, surface, allocator);
    defer allocator.free(modes);
    // Preference order: MAILBOX (no vsync, no tearing) > IMMEDIATE (no vsync,
    // may tear) > FIFO (vsync locked).  Older MoltenVK versions on Intel Macs
    // often lack MAILBOX but do expose IMMEDIATE.
    for (modes) |m| {
        if (m == .mailbox_khr) return m;
    }
    for (modes) |m| {
        if (m == .immediate_khr) return m;
    }
    return .fifo_khr; // guaranteed to be present
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, width: u32, height: u32) vk.Extent2D {
    // If currentExtent is set, the swapchain must match it exactly.
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

// ============================================================================
// Swapchain and image view creation
// ============================================================================

fn createSwapchain(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    caps: vk.SurfaceCapabilitiesKHR,
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    graphics_family: u32,
    present_family: u32,
) !vk.SwapchainKHR {
    const image_count = @min(caps.min_image_count + 1, if (caps.max_image_count > 0) caps.max_image_count else std.math.maxInt(u32));
    const same = graphics_family == present_family;
    const families = [_]u32{ graphics_family, present_family };
    return vkd.createSwapchainKHR(device, &.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = if (same) .exclusive else .concurrent,
        .queue_family_index_count = if (same) 0 else 2,
        .p_queue_family_indices = if (same) null else &families,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
    }, null);
}

fn createImageViews(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    allocator: std.mem.Allocator,
) ![]vk.ImageView {
    const images = try vkd.getSwapchainImagesAllocKHR(device, swapchain, allocator);
    defer allocator.free(images);
    const views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(views);
    var created: usize = 0;
    errdefer for (views[0..created]) |v| vkd.destroyImageView(device, v, null);
    for (images, views) |img, *view| {
        view.* = try vkd.createImageView(device, &.{
            .image = img,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        created += 1;
    }
    return views;
}
