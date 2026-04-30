// Length-prefix message framing.
//
// Wire format:  [ u32 big-endian length ] [ payload bytes ]
//
// The 4-byte header encodes the payload length. The receiver reads the header
// first, validates the length against max_frame_bytes, then reads exactly that
// many bytes into the caller-supplied buffer.
//
// Design decisions referenced:
//   §5: Message framing — 4-byte length-prefix header + Protobuf payload

const std = @import("std");
const transport = @import("transport.zig");

pub const max_frame_bytes = transport.max_frame_bytes;

/// Header size in bytes (u32 big-endian).
pub const header_bytes: usize = 4;

pub const FrameError = error{
    /// Payload exceeds max_frame_bytes — peer is broken or malicious.
    FrameTooLarge,
    /// Caller-supplied buffer is smaller than the incoming payload.
    BufferTooSmall,
    /// Peer closed the connection cleanly.
    ConnectionClosed,
};

// ============================================================================
// Send
// ============================================================================

/// Send a length-prefixed frame over the transport.
/// payload must not exceed max_frame_bytes.
pub fn sendFrame(t: transport.Transport, payload: []const u8) !void {
    std.debug.assert(payload.len <= max_frame_bytes);
    var header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try t.send(&header);
    if (payload.len > 0) {
        try t.send(payload);
    }
}

// ============================================================================
// Receive
// ============================================================================

/// Receive one length-prefixed frame into buf.
/// Returns the payload slice (sub-slice of buf).
/// Returns FrameError.FrameTooLarge if the peer sends a length > max_frame_bytes.
/// Returns FrameError.BufferTooSmall if the frame fits in the protocol but not in buf.
/// Returns FrameError.ConnectionClosed if the peer closes cleanly.
pub fn recvFrame(t: transport.Transport, buf: []u8) ![]u8 {
    var header: [header_bytes]u8 = undefined;
    try recvExact(t, &header);

    const len = std.mem.readInt(u32, &header, .big);
    if (len > max_frame_bytes) return FrameError.FrameTooLarge;
    if (len > buf.len) return FrameError.BufferTooSmall;

    const payload = buf[0..len];
    if (len > 0) try recvExact(t, payload);
    return payload;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Read exactly buf.len bytes from the transport, looping on partial reads.
fn recvExact(t: transport.Transport, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try t.recv(buf[pos..]);
        if (n == 0) return FrameError.ConnectionClosed;
        pos += n;
    }
    std.debug.assert(pos == buf.len);
}

// ============================================================================
// Tests
// ============================================================================

const tcp = @import("tcp.zig");

test "framing: roundtrip empty payload" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    try sendFrame(sender.transport(), &.{});

    var buf: [256]u8 = undefined;
    const got = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "framing: roundtrip small payload" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    const payload = "blood rift";
    try sendFrame(sender.transport(), payload);

    var buf: [256]u8 = undefined;
    const got = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, payload, got);
}

test "framing: roundtrip multiple frames" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    try sendFrame(sender.transport(), "first");
    try sendFrame(sender.transport(), "second");

    var buf: [256]u8 = undefined;
    const a = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, "first", a);

    const b = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, "second", b);
}

test "framing: rejects oversized frame" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    // Write a header claiming a payload larger than max_frame_bytes.
    var bad_header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &bad_header, max_frame_bytes + 1, .big);
    try sender.stream.writeAll(&bad_header);

    var buf: [256]u8 = undefined;
    const result = recvFrame(receiver.transport(), &buf);
    try std.testing.expectError(FrameError.FrameTooLarge, result);
}
