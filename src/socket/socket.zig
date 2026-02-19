const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

pub const SocketError = error{
    WinsockInitFailed,
    SocketCreationFailed,
    BindFailed,
    SendFailed,
    AlreadyListening,
    NotListening,
    ThreadSpawnFailed,
    AddressParseError,
    SocketClosed,
    OutOfMemory,
} || std.net.Address.ListenError || std.posix.SocketError || std.posix.BindError || std.posix.SendToError;

pub const CallbackFn = *const fn (
    data: []u8,
    from_addr: std.net.Address,
    context: ?*anyopaque,
    allocator: Allocator,
) void;

const SocketHandle = if (builtin.os.tag == .windows)
    std.os.windows.ws2_32.SOCKET
else
    posix.socket_t;

// Configuration constants
const Config = struct {
    const BUFFER_SIZE = 8192;
    const MAX_PACKETS_PER_BATCH = 128;
    // Sleep times for different states
    const BASE_SLEEP_NS = 10_000; // 0.01ms - responsive
    const IDLE_SLEEP_NS = 500_000; // 0.5ms - light idle
    const MAX_IDLE_SLEEP_NS = 2_000_000; // 2ms - max idle
    const IDLE_THRESHOLD = 20;
    const DEEP_IDLE_THRESHOLD = 200;
    const MAX_CONSECUTIVE_ERRORS = 15;
    const SOCKET_RECV_TIMEOUT_MS = 10;
};

const PacketBuffer = struct {
    data: [Config.BUFFER_SIZE]u8,
    used: bool,
};

const BufferPool = struct {
    buffers: []PacketBuffer,
    mutex: Mutex,
    allocator: Allocator,

    fn init(allocator: Allocator, pool_size: usize) !BufferPool {
        const buffers = try allocator.alloc(PacketBuffer, pool_size);
        for (buffers) |*buffer| {
            buffer.used = false;
        }

        return BufferPool{
            .buffers = buffers,
            .mutex = Mutex{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *BufferPool) void {
        self.allocator.free(self.buffers);
    }

    fn acquire(self: *BufferPool) ?*PacketBuffer {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.buffers) |*buffer| {
            if (!buffer.used) {
                buffer.used = true;
                return buffer;
            }
        }
        return null;
    }

    fn release(self: *BufferPool, buffer: *PacketBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        buffer.used = false;
    }
};

pub const Socket = struct {
    const Self = @This();

    // Core socket data
    allocator: Allocator,
    bind_address: std.net.Address,
    socket_handle: SocketHandle,

    // Threading
    thread: ?Thread,
    should_stop: Atomic(bool),
    is_listening: Atomic(bool),

    // Callback system
    callback: ?CallbackFn,
    context: ?*anyopaque,
    callback_mutex: Mutex,

    // Buffer management
    buffer_pool: BufferPool,

    // Error handling
    consecutive_errors: Atomic(u32),

    // Platform-specific
    winsock_initialized: if (builtin.os.tag == .windows) bool else void,

    pub fn init(allocator: Allocator, host: []const u8, port: u16) SocketError!Self {
        const bind_address = parseAddress(host, port) catch |err| {
            std.log.err("Failed to parse address {s}:{d}: {any}", .{ host, port, err });
            return SocketError.AddressParseError;
        };

        var buffer_pool = BufferPool.init(allocator, 64) catch {
            return SocketError.OutOfMemory;
        };

        var self = Self{
            .allocator = allocator,
            .bind_address = bind_address,
            .socket_handle = if (builtin.os.tag == .windows)
                std.os.windows.ws2_32.INVALID_SOCKET
            else
                undefined,
            .thread = null,
            .should_stop = Atomic(bool).init(false),
            .is_listening = Atomic(bool).init(false),
            .callback = null,
            .context = null,
            .callback_mutex = Mutex{},
            .buffer_pool = buffer_pool,
            .consecutive_errors = Atomic(u32).init(0),
            .winsock_initialized = if (builtin.os.tag == .windows) false else {},
        };

        self.createSocket() catch |err| {
            buffer_pool.deinit();
            return err;
        };

        return self;
    }

    fn parseAddress(host: []const u8, port: u16) !std.net.Address {
        if (std.mem.eql(u8, host, "0.0.0.0") or host.len == 0) {
            return std.net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, port);
        }
        return std.net.Address.parseIp4(host, port);
    }

    fn createSocket(self: *Self) SocketError!void {
        if (builtin.os.tag == .windows) {
            try self.initWinsock();
            try self.createWindowsSocket();
        } else {
            try self.createUnixSocket();
        }
    }

    fn createWindowsSocket(self: *Self) SocketError!void {
        const sock = std.os.windows.ws2_32.socket(
            std.os.windows.ws2_32.AF.INET,
            std.os.windows.ws2_32.SOCK.DGRAM,
            std.os.windows.ws2_32.IPPROTO.UDP,
        );

        if (sock == std.os.windows.ws2_32.INVALID_SOCKET) {
            self.cleanupWinsock();
            return SocketError.SocketCreationFailed;
        }

        // Set socket options for better performance
        self.setWindowsSocketOptions(sock) catch {
            _ = std.os.windows.ws2_32.closesocket(sock);
            self.cleanupWinsock();
            return SocketError.SocketCreationFailed;
        };

        self.socket_handle = sock;
    }

    fn setWindowsSocketOptions(_: *Self, sock: SocketHandle) !void {
        // Non-blocking mode
        var mode: c_ulong = 1;
        if (std.os.windows.ws2_32.ioctlsocket(sock, std.os.windows.ws2_32.FIONBIO, &mode) != 0) {
            return error.SocketCreationFailed;
        }

        // Increase receive buffer size
        const recv_buf_size: c_int = 4 * 1024 * 1024; // 4MB for better performance
        _ = std.os.windows.ws2_32.setsockopt(
            sock,
            0x0000ffff, // SOL_SOCKET
            0x1002, // SO_RCVBUF
            @ptrCast(&recv_buf_size),
            @sizeOf(c_int),
        );

        // Set receive timeout
        const timeout_ms: c_int = Config.SOCKET_RECV_TIMEOUT_MS;
        _ = std.os.windows.ws2_32.setsockopt(
            sock,
            0x0000ffff, // SOL_SOCKET
            0x1006, // SO_RCVTIMEO
            @ptrCast(&timeout_ms),
            @sizeOf(c_int),
        );

        // Add send buffer size
        const send_buf_size: c_int = 4 * 1024 * 1024; // 4MB
        _ = std.os.windows.ws2_32.setsockopt(
            sock,
            0x0000ffff, // SOL_SOCKET
            0x1001, // SO_SNDBUF
            @ptrCast(&send_buf_size),
            @sizeOf(c_int),
        );
    }

    fn createUnixSocket(self: *Self) SocketError!void {
        const sock = posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC,
            0,
        ) catch |err| {
            std.log.err("Failed to create socket: {any}", .{err});
            return err;
        };

        self.setUnixSocketOptions(sock) catch {
            _ = posix.close(sock);
            return SocketError.SocketCreationFailed;
        };

        self.socket_handle = sock;
    }

    fn setUnixSocketOptions(_: *Self, sock: SocketHandle) !void {
        // Enable address reuse
        const enable: c_int = 1;
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch {};

        // Increase receive buffer size
        const recv_buf_size: c_int = 4 * 1024 * 1024; // 4MB
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&recv_buf_size)) catch {};

        // Set receive timeout
        const timeout = std.os.linux.timeval{
            .sec = 0,
            .usec = Config.SOCKET_RECV_TIMEOUT_MS * 1000,
        };
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Increase send buffer size
        const send_buf_size: c_int = 4 * 1024 * 1024; // 4MB
        _ = posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&send_buf_size)) catch {};

        // Make sure non-blocking is set
        const flags = posix.fcntl(sock, posix.F.GETFL, 0) catch return;
        _ = posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK) catch return;
    }

    fn initWinsock(self: *Self) SocketError!void {
        if (builtin.os.tag != .windows or self.winsock_initialized) return;

        var wsadata = std.mem.zeroes(std.os.windows.ws2_32.WSADATA);
        if (std.os.windows.ws2_32.WSAStartup(0x0202, &wsadata) != 0) {
            return SocketError.WinsockInitFailed;
        }
        self.winsock_initialized = true;
    }

    fn cleanupWinsock(self: *Self) void {
        if (builtin.os.tag != .windows or !self.winsock_initialized) return;
        _ = std.os.windows.ws2_32.WSACleanup();
        self.winsock_initialized = false;
    }

    pub fn listen(self: *Self) SocketError!void {
        if (self.is_listening.load(.acquire)) {
            return SocketError.AlreadyListening;
        }

        try self.bindSocket();

        self.should_stop.store(false, .release);
        self.consecutive_errors.store(0, .release);

        self.thread = Thread.spawn(.{}, receiveLoop, .{self}) catch |err| {
            std.log.err("Failed to spawn receive thread: {any}", .{err});
            return SocketError.ThreadSpawnFailed;
        };

        self.is_listening.store(true, .release);
        // std.log.info("Socket listening on {any}", .{self.bind_address});
    }

    fn bindSocket(self: *Self) SocketError!void {
        if (builtin.os.tag == .windows) {
            const result = std.os.windows.ws2_32.bind(
                self.socket_handle,
                @ptrCast(&self.bind_address.in),
                @sizeOf(@TypeOf(self.bind_address.in)),
            );
            if (result == std.os.windows.ws2_32.SOCKET_ERROR) {
                return SocketError.BindFailed;
            }
        } else {
            posix.bind(
                self.socket_handle,
                &self.bind_address.any,
                self.bind_address.getOsSockLen(),
            ) catch |err| {
                std.log.err("Socket bind failed: {any}", .{err});
                return err;
            };
        }
    }

    // Improved receive loop with CPU-efficient adaptive sleeping
    fn receiveLoop(self: *Self) void {
        var packets_processed: u32 = 0;
        var consecutive_no_data: u32 = 0;
        var current_sleep_ns: u64 = Config.BASE_SLEEP_NS;

        while (!self.should_stop.load(.acquire)) {
            packets_processed = 0;
            var buffer_shortage = false;

            // Process multiple packets in a batch
            while (packets_processed < Config.MAX_PACKETS_PER_BATCH) {
                const buffer = self.buffer_pool.acquire() orelse {
                    buffer_shortage = true;
                    break;
                };
                defer self.buffer_pool.release(buffer);

                const result = self.receivePacket(buffer.data[0..]);

                switch (result) {
                    .success => |packet_info| {
                        self.consecutive_errors.store(0, .release);
                        consecutive_no_data = 0;
                        // Reset sleep time when data arrives - be responsive
                        current_sleep_ns = Config.BASE_SLEEP_NS;

                        if (packet_info) |info| {
                            self.handlePacket(info.data, info.from_addr);
                            packets_processed += 1;
                        }
                    },
                    .would_block => {
                        consecutive_no_data += 1;
                        // Gradually increase sleep time as we detect inactivity
                        if (consecutive_no_data > Config.DEEP_IDLE_THRESHOLD) {
                            // Cap the maximum sleep time to avoid becoming too unresponsive
                            current_sleep_ns = @min(Config.MAX_IDLE_SLEEP_NS, current_sleep_ns + (current_sleep_ns / 8) // Increase by 12.5% (was 25%)
                            );
                        } else if (consecutive_no_data > Config.IDLE_THRESHOLD) {
                            // Medium idle - slowly increase sleep time
                            current_sleep_ns = @min(Config.IDLE_SLEEP_NS, current_sleep_ns + 5_000 // Increase by 0.005ms (was 0.01ms)
                            );
                        }
                        break; // No more data available
                    },
                    .error_recoverable => |err| {
                        self.handleRecoverableError(err);
                        break;
                    },
                    .error_fatal => |err| {
                        std.log.err("Fatal socket error: {any}", .{err});
                        return;
                    },
                }
            }

            // Adaptive sleep strategy based on system activity
            if (buffer_shortage) {
                // Sleep briefly to let buffers free up
                std.Thread.sleep(current_sleep_ns / 2);
            } else if (packets_processed == 0) {
                // No packets processed, use adaptive sleep
                std.Thread.sleep(current_sleep_ns);
            }
            // When packets were processed, loop immediately without sleeping
        }
    }

    // More efficient packet handling with better memory management
    fn handlePacket(self: *Self, data: []const u8, from_addr: std.net.Address) void {
        self.callback_mutex.lock();
        const callback = self.callback;
        const context = self.context;
        self.callback_mutex.unlock();

        if (callback) |cb| {
            // Create a copy of the data that will be freed by the callback
            const data_copy = self.allocator.dupe(u8, data) catch |err| {
                std.log.err("Failed to copy packet data: {any}", .{err});
                return;
            };

            // Call the callback - the callback MUST free the data_copy when done
            cb(data_copy, from_addr, context, self.allocator);
        }
    }

    fn handleRecoverableError(self: *Self, err: anyerror) void {
        const error_count = self.consecutive_errors.fetchAdd(1, .acq_rel) + 1;

        // Only log errors for the first few occurrences to avoid spamming
        if (error_count <= 3) {
            std.log.warn("Socket error ({any}): {any}", .{ error_count, err });
        } else if (error_count == 5 or error_count % 100 == 0) {
            // Only log periodically after many errors
            std.log.err("Network errors continuing (count: {d}), client likely disconnected", .{error_count});
            std.Thread.sleep(Config.IDLE_SLEEP_NS); // Longer backoff
        } else {
            // Just back off without logging
            std.Thread.sleep(Config.BASE_SLEEP_NS * 5);
        }
    }

    const ReceiveResult = union(enum) {
        success: ?PacketInfo,
        would_block: void,
        error_recoverable: anyerror,
        error_fatal: anyerror,
    };

    const PacketInfo = struct {
        data: []const u8,
        from_addr: std.net.Address,
    };

    fn receivePacket(self: *Self, buffer: []u8) ReceiveResult {
        if (builtin.os.tag == .windows) {
            return self.receivePacketWindows(buffer);
        } else {
            return self.receivePacketUnix(buffer);
        }
    }

    fn receivePacketWindows(self: *Self, buffer: []u8) ReceiveResult {
        var from_addr: @TypeOf(self.bind_address.in) = undefined;
        var addr_len: c_int = @sizeOf(@TypeOf(from_addr));

        const result = std.os.windows.ws2_32.recvfrom(
            self.socket_handle,
            buffer.ptr,
            @intCast(buffer.len),
            0,
            @ptrCast(&from_addr),
            &addr_len,
        );

        if (result == std.os.windows.ws2_32.SOCKET_ERROR) {
            const err = std.os.windows.ws2_32.WSAGetLastError();
            return switch (err) {
                std.os.windows.ws2_32.WinsockError.WSAEWOULDBLOCK => .would_block,
                std.os.windows.ws2_32.WinsockError.WSAECONNRESET,
                std.os.windows.ws2_32.WinsockError.WSAENETDOWN,
                std.os.windows.ws2_32.WinsockError.WSAENETUNREACH,
                => .{ .error_recoverable = error.NetworkError },
                std.os.windows.ws2_32.WinsockError.WSAEBADF,
                std.os.windows.ws2_32.WinsockError.WSAENOTSOCK,
                => .{ .error_fatal = error.SocketClosed },
                else => .{ .error_recoverable = error.ReceiveFailed },
            };
        }

        if (result == 0) return .{ .success = null };

        return .{
            .success = PacketInfo{
                .data = buffer[0..@intCast(result)],
                .from_addr = std.net.Address{ .in = from_addr },
            },
        };
    }

    fn receivePacketUnix(self: *Self, buffer: []u8) ReceiveResult {
        var from_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(from_addr));

        const bytes_received = posix.recvfrom(
            self.socket_handle,
            buffer,
            0,
            &from_addr,
            &addr_len,
        ) catch |err| {
            return switch (err) {
                error.WouldBlock => .would_block,
                error.ConnectionRefused, error.NetworkSubsystemFailed => .{ .error_recoverable = err },
                error.SocketNotConnected => .{ .error_fatal = err },
                else => .{ .error_recoverable = err },
            };
        };

        if (bytes_received == 0) return .{ .success = null };

        return .{
            .success = PacketInfo{
                .data = buffer[0..bytes_received],
                .from_addr = std.net.Address{ .any = from_addr },
            },
        };
    }

    pub fn stop(self: *Self) void {
        if (!self.is_listening.load(.acquire)) return;

        self.should_stop.store(true, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.is_listening.store(false, .release);
        std.log.info("Socket stopped listening", .{});
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (builtin.os.tag == .windows) {
            if (self.socket_handle != std.os.windows.ws2_32.INVALID_SOCKET) {
                _ = std.os.windows.ws2_32.closesocket(self.socket_handle);
            }
            self.cleanupWinsock();
        } else {
            _ = posix.close(self.socket_handle);
        }

        self.buffer_pool.deinit();
    }

    pub fn setCallback(self: *Self, callback: CallbackFn, context: ?*anyopaque) void {
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();
        self.callback = callback;
        self.context = context;
    }

    pub fn send(self: *Self, data: []const u8, to_addr: std.net.Address) SocketError!void {
        if (builtin.os.tag == .windows) {
            const result = std.os.windows.ws2_32.sendto(
                self.socket_handle,
                data.ptr,
                @intCast(data.len),
                0,
                @ptrCast(&to_addr.in),
                @sizeOf(@TypeOf(to_addr.in)),
            );

            if (result == std.os.windows.ws2_32.SOCKET_ERROR) {
                return SocketError.SendFailed;
            }
        } else {
            _ = posix.sendto(
                self.socket_handle,
                data,
                0,
                &to_addr.any,
                to_addr.getOsSockLen(),
            ) catch |err| {
                std.log.err("sendto failed: {any}", .{err});
                return err;
            };
        }
    }

    pub fn sendTo(self: *Self, data: []const u8, host: []const u8, port: u16) SocketError!void {
        const addr = parseAddress(host, port) catch |err| {
            std.log.err("Failed to parse destination address {s}:{d}: {any}", .{ host, port, err });
            return SocketError.AddressParseError;
        };
        try self.send(data, addr);
    }

    pub fn getLocalAddress(self: *Self) SocketError!std.net.Address {
        if (builtin.os.tag == .windows) {
            var addr: @TypeOf(self.bind_address.in) = undefined;
            var addr_len: c_int = @sizeOf(@TypeOf(addr));

            if (std.os.windows.ws2_32.getsockname(
                self.socket_handle,
                @ptrCast(&addr),
                &addr_len,
            ) == std.os.windows.ws2_32.SOCKET_ERROR) {
                return SocketError.SocketCreationFailed;
            }

            return std.net.Address{ .in = addr };
        } else {
            var addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr));

            posix.getsockname(self.socket_handle, &addr, &addr_len) catch {
                return SocketError.SocketCreationFailed;
            };

            return std.net.Address{ .any = addr };
        }
    }

    pub fn isListening(self: *Self) bool {
        return self.is_listening.load(.acquire);
    }
};
