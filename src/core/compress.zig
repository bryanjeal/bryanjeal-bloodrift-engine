// zstd compression wrapper for network payloads.
//
// Thin layer over the C libzstd API. The Zig 0.15.2 stdlib includes
// std.compress.zstd for decompression only; this module provides both
// compress and decompress by calling the C library directly.
//
// Uses zstd default compression level (3). Custom dictionary support
// is deferred to TD-097 phase 2, once simulator traffic data is
// available for training.

const std = @import("std");

// C API declarations — resolve at link time via libzstd.
// c_int is a Zig builtin (C ABI int type).
extern fn ZSTD_compress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize, compressionLevel: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) usize;
extern fn ZSTD_compressBound(srcSize: usize) usize;
extern fn ZSTD_getFrameContentSize(src: [*]const u8, srcSize: usize) u64;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;

/// Default compression level used by the zstd CLI.
pub const default_level: c_int = 3;

/// Maximum input size zstd accepts (from zstd.h: ZSTD_MAX_INPUT_SIZE).
pub const max_input_size: usize = 0x7E000000; // ~2 GiB, well above any frame.

/// Sentinel: ZSTD_CONTENTSIZE_UNKNOWN.
pub const content_size_unknown: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Sentinel: ZSTD_CONTENTSIZE_ERROR (corrupt or incomplete frame).
pub const content_size_error: u64 = 0xFFFF_FFFF_FFFF_FFFE;

pub const CompressError = error{
    ZstdCompressFailed,
    ZstdDecompressFailed,
    ZstdCorruptFrame,
};

/// Compress src into a caller-owned buffer allocated from `allocator`.
/// Caller must free the returned slice.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, level: c_int) CompressError![]u8 {
    std.debug.assert(src.len <= max_input_size);
    const dst_cap = ZSTD_compressBound(src.len);
    if (dst_cap == 0) return error.ZstdCompressFailed;
    const dst = allocator.alloc(u8, dst_cap) catch return error.ZstdCompressFailed;
    errdefer allocator.free(dst);
    const result = ZSTD_compress(dst.ptr, dst.len, src.ptr, src.len, level);
    if (ZSTD_isError(result) != 0) return error.ZstdCompressFailed;
    return allocator.realloc(dst, result) catch return error.ZstdCompressFailed;
}

/// Decompress a zstd frame into a caller-owned buffer allocated from `allocator`.
/// Caller must free the returned slice.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) CompressError![]u8 {
    const frame_size = ZSTD_getFrameContentSize(src.ptr, src.len);
    if (frame_size == content_size_error) return error.ZstdCorruptFrame;
    if (frame_size == content_size_unknown) return error.ZstdDecompressFailed;
    // ZSTD_getFrameContentSize returns an upper bound including potential
    // dictionary expansion; allocate that much.
    const dst_cap: usize = @intCast(frame_size);
    const dst = allocator.alloc(u8, dst_cap) catch return error.ZstdDecompressFailed;
    errdefer allocator.free(dst);
    const result = ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len);
    if (ZSTD_isError(result) != 0) return error.ZstdDecompressFailed;
    // result should match dst_cap for single-frame input.
    if (result != dst_cap) return error.ZstdDecompressFailed;
    return dst;
}

// ============================================================================
// Tests
// ============================================================================

test "compress: roundtrip small payload" {
    const input = "Blood Rift replication compression test payload";
    const compressed = try compress(std.testing.allocator, input, default_level);
    defer std.testing.allocator.free(compressed);
    const decompressed = try decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "compress: empty payload" {
    const input: []const u8 = &.{};
    const compressed = try compress(std.testing.allocator, input, default_level);
    defer std.testing.allocator.free(compressed);
    const decompressed = try decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(decompressed);
    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "compress: large payload (repeated pattern, highly compressible)" {
    var buf: [8192]u8 = undefined;
    // Simulate protobuf-like data: repeated small struct with some variation.
    for (0..buf.len / 8) |i| {
        const off = i * 8;
        std.mem.writeInt(u64, buf[off..][0..8], @intCast(i % 256), .little);
    }
    const compressed = try compress(std.testing.allocator, &buf, default_level);
    defer std.testing.allocator.free(compressed);
    // Should be significantly smaller than 8192 bytes.
    try std.testing.expect(compressed.len < 4096);
    const decompressed = try decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &buf, decompressed);
}

test "compress: rejects corrupt frame" {
    const corrupt: [8]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00 };
    const result = decompress(std.testing.allocator, &corrupt);
    try std.testing.expectError(error.ZstdCorruptFrame, result);
}

test "compress: high level reduces size further" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0xAB);
    const c3 = try compress(std.testing.allocator, &buf, 3);
    defer std.testing.allocator.free(c3);
    const c19 = try compress(std.testing.allocator, &buf, 19);
    defer std.testing.allocator.free(c19);
    // Level 19 should be at least as good as level 3 (usually better).
    try std.testing.expect(c19.len <= c3.len);
}
