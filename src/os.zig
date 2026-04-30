// Cross-platform OS abstractions for Blood Rift engine.
//
// All platform-specific socket and I/O operations live here.
// Comptime-dispatched — zero runtime cost per platform.
//
// Pattern follows Ghostty's src/os/ package: one module wrapping
// platform differences behind a unified API.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Socket I/O
// ============================================================================

/// Send all bytes over a socket. Blocks until complete.
/// On Windows: uses ws2_32.send() (ReadFile/WriteFile fail on SOCKET handles).
/// On POSIX: uses std.net.Stream.write() in a manual loop.  Stream.writeAll() is
/// deprecated in Zig 0.15 and creates a temporary Writer per call, which can lose
/// error state on large payloads.  The manual loop reuses the same Stream handle.
pub fn socketSendAll(handle: std.net.Stream.Handle, bytes: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var sent: usize = 0;
        while (sent < bytes.len) {
            const len: i32 = @intCast(@min(bytes.len - sent, std.math.maxInt(i32)));
            const rc = ws2.send(handle, @ptrCast(bytes.ptr + sent), len, 0);
            if (rc > 0) {
                sent += @intCast(rc);
                continue;
            }
            return switch (ws2.WSAGetLastError()) {
                .WSAEWOULDBLOCK => error.WouldBlock,
                .WSAETIMEDOUT => error.WouldBlock,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAECONNABORTED => error.ConnectionResetByPeer,
                else => error.BrokenPipe,
            };
        }
    } else {
        const stream = std.net.Stream{ .handle = handle };
        var index: usize = 0;
        while (index < bytes.len) {
            index += try stream.write(bytes[index..]);
        }
    }
}

/// Receive bytes from a socket. Returns number of bytes read, or 0 on close.
/// On Windows: uses ws2_32.recv() with proper WSA error translation.
/// On POSIX: uses std.net.Stream.read() (deprecated but functional for sockets).
pub fn socketRecv(handle: std.net.Stream.Handle, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        const rc = ws2.recv(handle, @ptrCast(buf.ptr), len, 0);
        if (rc > 0) return @intCast(rc);
        if (rc == 0) return 0;
        return switch (ws2.WSAGetLastError()) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAETIMEDOUT => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAECONNABORTED => error.ConnectionResetByPeer,
            else => error.ConnectionResetByPeer,
        };
    } else {
        const stream = std.net.Stream{ .handle = handle };
        return stream.read(buf);
    }
}

/// Set SO_RCVTIMEO on a socket handle.
/// On Windows: takes a DWORD (milliseconds).
/// On POSIX: takes a timeval struct.
pub fn setSockRecvTimeout(handle: std.net.Stream.Handle, timeout_ms: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const ms: std.os.windows.DWORD = timeout_ms;
        const sol_socket: i32 = 0xFFFF;
        const so_rcv_time_out: i32 = 0x1006;
        const optval: ?[*]const u8 = @ptrCast(&ms);
        const optlen: i32 = @sizeOf(@TypeOf(ms));
        const rc = ws2.setsockopt(handle, sol_socket, so_rcv_time_out, optval, optlen);
        if (rc != 0) return error.SetSockOptFailed;
    } else {
        const usec: i32 = @intCast((timeout_ms % 1000) * 1000);
        const sec: i32 = @intCast(timeout_ms / 1000);
        const tv = std.posix.timeval{ .sec = sec, .usec = usec };
        try std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        );
    }
}

/// Close a raw socket handle.
/// On Windows: uses closesocket().
/// On POSIX: uses close().
pub fn closeSocket(handle: std.net.Stream.Handle) void {
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(handle);
    } else {
        _ = std.c.close(handle);
    }
}

// ============================================================================
// Test utilities
// ============================================================================

/// Create a connected socket pair for tests.
/// On Windows: TCP loopback via std.net (proper handle types for ReadFile/WriteFile).
/// On POSIX: socketpair(AF_UNIX).
pub fn makeSocketPair() !struct { std.net.Stream.Handle, std.net.Stream.Handle } {
    if (comptime builtin.os.tag == .windows) {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var server = try addr.listen(.{ .reuse_address = true });
        defer server.deinit();

        const client_stream = try std.net.tcpConnectToAddress(server.listen_address);
        const conn = try server.accept();

        return .{ client_stream.handle, conn.stream.handle };
    } else {
        var sv: [2]std.c.fd_t = undefined;
        const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
        if (rc != 0) return error.SocketpairFailed;
        return .{ sv[0], sv[1] };
    }
}
