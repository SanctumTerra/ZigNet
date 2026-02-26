const std = @import("std");
const Socket = @import("../socket/socket.zig").Socket;
const Logger = @import("../misc/Logger.zig").Logger;
const Proto = @import("../proto/root.zig");
const Packets = Proto.Packets;
const Connection = @import("./Connection.zig").Connection;
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const PERFORM_TIME_CHECKS = false;

pub const UDP_HEADER_SIZE = 28;
pub const MAX_MTU_SIZE = 1492;
pub const ConnectCallback = *const fn (connection: *Connection, context: ?*anyopaque) void;
pub const DisconnectCallback = *const fn (connection: *Connection, context: ?*anyopaque) void;
pub const TickCallback = *const fn (context: ?*anyopaque) void;

pub const Server = struct {
    const Self = @This();
    options: ServerOptions,
    socket: Socket,
    running: bool = false,
    connections: std.AutoHashMap(i64, *Connection),
    connections_mutex: Mutex,
    tick_thread: ?Thread,
    connect_callback: ?ConnectCallback,
    connect_context: ?*anyopaque,
    disconnect_callback: ?DisconnectCallback,
    disconnect_context: ?*anyopaque,
    tick_callback: ?TickCallback,
    tick_context: ?*anyopaque,

    /// Fast hash for address -> i64 key (no allocation)
    /// IPv4: packs ip (4 bytes) + port (2 bytes) into lower 48 bits
    /// IPv6: uses FNV-1a hash of the 16-byte address + port
    pub inline fn addressToKey(address: std.net.Address) i64 {
        return switch (address.any.family) {
            std.posix.AF.INET => blk: {
                const ip = address.in.sa.addr;
                const port = address.in.sa.port;
                break :blk @as(i64, ip) | (@as(i64, port) << 32);
            },
            std.posix.AF.INET6 => blk: {
                // FNV-1a hash for IPv6
                var hash: u64 = 0xcbf29ce484222325;
                for (address.in6.sa.addr) |byte| {
                    hash ^= byte;
                    hash *%= 0x100000001b3;
                }
                hash ^= address.in6.sa.port;
                hash *%= 0x100000001b3;
                break :blk @bitCast(hash);
            },
            else => 0,
        };
    }

    /// Please provide a proper allocator.
    ///
    /// It uses std.heap.page_allocator by default but Arena or DebugAllocator is preffered.
    pub fn init(options: ServerOptions) !Server {
        const server = Server{
            .options = options,
            .socket = try Socket.init(
                options.allocator,
                options.address,
                options.port,
            ),
            .connections = std.AutoHashMap(i64, *Connection).init(options.allocator),
            .connections_mutex = Mutex{},
            .tick_thread = null,
            .connect_callback = options.connect_callback,
            .connect_context = options.connect_context,
            .disconnect_callback = options.disconnect_callback,
            .disconnect_context = options.disconnect_context,
            .tick_callback = options.tick_callback,
            .tick_context = options.tick_context,
        };
        return server;
    }

    fn tickLoop(self: *Self) void {
        const tick_interval_ns: u64 = std.time.ns_per_s / @as(u64, self.options.tick_rate);

        while (self.running) {
            const tick_start = std.time.nanoTimestamp();

            self.connections_mutex.lock();

            var to_remove: [64]i64 = undefined;
            var remove_count: usize = 0;

            {
                var itter = self.connections.iterator();
                while (itter.next()) |val| {
                    const conn = val.value_ptr.*;
                    if (conn.active) {
                        conn.tick();
                    } else if (remove_count < to_remove.len) {
                        to_remove[remove_count] = val.key_ptr.*;
                        remove_count += 1;
                    }
                }
            }

            for (to_remove[0..remove_count]) |key| {
                if (self.connections.fetchRemove(key)) |entry| {
                    var conn = entry.value;
                    conn.deinit();
                    self.options.allocator.destroy(conn);
                    Logger.INFO("Disconnected connection with key: {d}", .{key});
                }
            }

            self.connections_mutex.unlock();

            if (self.tick_callback) |cb| cb(self.tick_context);

            const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - tick_start));
            if (elapsed_ns < tick_interval_ns) {
                std.Thread.sleep(tick_interval_ns - elapsed_ns);
            }
        }
    }

    pub fn start(self: *Self) !void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        Logger.INFO("Starting server on {s}:{d}", .{ self.options.address, self.options.port });
        self.running = true;
        self.tick_thread = std.Thread.spawn(.{}, tickLoop, .{self}) catch |err| {
            Logger.ERROR("Failed to spawn maintenance thread: {s}", .{@errorName(err)});
            return;
        };
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
        self.options.advertisement.guid = prng.random().int(i64);
        self.socket.setCallback(packet_callback, self);
        self.socket.listen() catch |err| {
            std.debug.print("Error: {any}", .{err});
            return err;
        };

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: server start took {d} ms", .{elapsed});
        }
    }

    pub fn packet_callback(data: []const u8, from_addr: std.net.Address, context: ?*anyopaque, allocator: std.mem.Allocator) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        const self = @as(*Self, @ptrCast(@alignCast(context)));
        defer allocator.free(data);

        var ID: u8 = data[0];
        if (ID & 0xF0 == 0x80) ID = 0x80;
        const key = addressToKey(from_addr);

        switch (ID) {
            Packets.UnconnectedPing => {
                const string = self.options.advertisement.toString(self.options.allocator);
                defer self.options.allocator.free(string);
                var pong = Proto.UnconnectedPong.init(
                    std.time.milliTimestamp(),
                    self.options.advertisement.guid,
                    string,
                    self.options.allocator,
                );
                defer pong.deinit(allocator);
                const pong_data = pong.serialize() catch |err| {
                    Logger.ERROR("Failed to serialize unconnected pong: {s}", .{@errorName(err)});
                    return;
                };
                self.send(pong_data, from_addr);
            },
            Packets.OpenConnectionRequest1 => {
                var reply = Proto.ConnectionReply1.init(
                    self.options.advertisement.guid,
                    false,
                    1492,
                    self.options.allocator,
                );
                defer reply.deinit();
                const reply_data = reply.serialize() catch |err| {
                    Logger.ERROR("Failed to serialize connection reply 1: {s}", .{@errorName(err)});
                    return;
                };
                self.send(reply_data, from_addr);
            },
            Packets.OpenConnectionRequest2 => {
                var request = Proto.ConnectionRequest2.deserialize(data, self.options.allocator) catch |err| {
                    Logger.ERROR("Failed to deserialize connection request 2: {s}", .{@errorName(err)});
                    return;
                };
                defer request.deinit(allocator);

                const address = Proto.Address.init(4, "0.0.0.0", 0);

                var reply = Proto.ConnectionReply2.init(
                    self.options.advertisement.guid,
                    address,
                    request.mtu_size,
                    false,
                    self.options.allocator,
                );
                defer reply.deinit(allocator);
                const reply_data = reply.serialize(self.options.allocator) catch |err| {
                    Logger.ERROR("Failed to serialize connection reply 2: {s}", .{@errorName(err)});
                    return;
                };

                self.send(reply_data, from_addr);

                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                if (self.connections.contains(key)) {
                    Logger.INFO("Connection already exists", .{});
                } else {
                    // Logger.INFO("New connection", .{});
                    const conn = self.options.allocator.create(Connection) catch |err| {
                        Logger.ERROR("Failed to allocate connection: {s}", .{@errorName(err)});
                        return;
                    };
                    conn.* = Connection.init(self, from_addr, request.mtu_size, request.guid) catch |err| {
                        Logger.ERROR("Failed to create connection: {s}", .{@errorName(err)});
                        self.options.allocator.destroy(conn);
                        return;
                    };

                    self.connections.put(key, conn) catch |err| {
                        Logger.ERROR("Failed to add connection to list: {s}", .{@errorName(err)});
                        conn.deinit();
                        self.options.allocator.destroy(conn);
                        return;
                    };
                }
            },
            Packets.FrameSet => {
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                if (self.connections.get(key)) |conn| {
                    if (!conn.active) return;
                    conn.onFrameSet(data) catch |err| {
                        Logger.ERROR("Failed to handle frame set: {s}", .{@errorName(err)});
                        return;
                    };
                }
            },
            Packets.Ack => {
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                if (self.connections.get(key)) |conn| {
                    if (!conn.active) return;
                    conn.handleAck(data) catch |err| {
                        Logger.ERROR("Failed to handle frame set: {s}", .{@errorName(err)});
                        return;
                    };
                }
            },
            Packets.Nack => {
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                if (self.connections.get(key)) |conn| {
                    if (!conn.active) return;
                    conn.handleNack(data) catch |err| {
                        Logger.ERROR("Failed to handle frame set: {s}", .{@errorName(err)});
                        return;
                    };
                }
            },
            else => {
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                Logger.WARN("Unknown ID {d}", .{ID});
                if (self.connections.contains(key)) {
                    Logger.DEBUG("Connection already exists", .{});
                }
            },
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: packet_callback took {d} ms", .{elapsed});
        }
    }

    pub fn send(self: *Self, data: []const u8, to_addr: std.net.Address) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;
        self.socket.send(data, to_addr) catch |err| {
            Logger.ERROR("Failed to send: {s}", .{@errorName(err)});
            return;
        };

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: send took {d} ms", .{elapsed});
        }
    }

    pub fn disconnect(self: *Self, address: std.net.Address) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        const key = addressToKey(address);
        Logger.INFO("Disconnecting connection with key: {d}", .{key});

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        if (self.connections.fetchRemove(key)) |entry| {
            var conn = entry.value;
            conn.deinit();
            self.options.allocator.destroy(conn);
            Logger.DEBUG("Connection disconnected successfully: {d}", .{key});
        } else {
            Logger.WARN("Attempted to disconnect non-existent connection: {d}", .{key});
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: disconnect took {d} ms", .{elapsed});
        }
    }

    /// Set server connect callback
    pub fn setConnectCallback(self: *Self, callback: ?ConnectCallback, context: ?*anyopaque) void {
        self.connect_callback = callback;
        self.connect_context = context;
    }

    /// Set server disconnect callback
    pub fn setDisconnectCallback(self: *Self, callback: ?DisconnectCallback, context: ?*anyopaque) void {
        self.disconnect_callback = callback;
        self.disconnect_context = context;
    }

    pub fn setTickCallback(self: *Self, callback: ?TickCallback, context: ?*anyopaque) void {
        self.tick_callback = callback;
        self.tick_context = context;
    }

    /// Get a connection by address (thread-safe)
    pub fn getConnection(self: *Self, address: std.net.Address) ?*Connection {
        const key = addressToKey(address);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        return self.connections.get(key);
    }

    /// Get all active connections (returns a copy for thread safety)
    pub fn getActiveConnections(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(*Connection) {
        var active_connections = std.ArrayList(*Connection).initBuffer(&[_]*Connection{});

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        var iterator = self.connections.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.*.active) {
                try active_connections.append(allocator, entry.*);
            }
        }

        return active_connections;
    }

    pub fn deinit(self: *Self) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        self.running = false;

        // Stop the socket first to prevent new connections
        self.socket.stop();

        // Now stop the tick thread
        if (self.tick_thread) |thread| {
            thread.join();
            self.tick_thread = null;
        }

        // Lock before accessing connections for final cleanup
        self.connections_mutex.lock();

        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            entry.*.deinit();
            self.options.allocator.destroy(entry.*);
        }

        self.connections.deinit();
        self.connections_mutex.unlock();

        // Finish socket cleanup
        self.socket.deinit();

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: deinit took {d} ms", .{elapsed});
        }
    }
};

pub const ServerOptions = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    tick_rate: u16 = 20,
    advertisement: Proto.Advertisement = Proto.Advertisement.init(
        .MCPE,
        "Conduit Server",
        800,
        "1.21.80",
        0,
        10,
        0,
        "Conduit Server",
        "Survival",
    ),
    // Server callbacks
    connect_callback: ?ConnectCallback = null,
    connect_context: ?*anyopaque = null,
    disconnect_callback: ?DisconnectCallback = null,
    disconnect_context: ?*anyopaque = null,
    tick_callback: ?TickCallback = null,
    tick_context: ?*anyopaque = null,
};

test "addressToKey IPv4 produces unique keys" {
    const addr1 = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 19132);
    const addr2 = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 19133);
    const addr3 = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 19132);

    const key1 = Server.addressToKey(addr1);
    const key2 = Server.addressToKey(addr2);
    const key3 = Server.addressToKey(addr3);

    // Same IP different port -> different key
    try std.testing.expect(key1 != key2);
    // Different IP same port -> different key
    try std.testing.expect(key1 != key3);
    // Same address -> same key
    try std.testing.expectEqual(key1, Server.addressToKey(addr1));
}

test "addressToKey IPv6 produces unique keys" {
    const addr1 = std.net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 19132, 0, 0);
    const addr2 = std.net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 19133, 0, 0);
    const addr3 = std.net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }, 19132, 0, 0);

    const key1 = Server.addressToKey(addr1);
    const key2 = Server.addressToKey(addr2);
    const key3 = Server.addressToKey(addr3);

    try std.testing.expect(key1 != key2);
    try std.testing.expect(key1 != key3);
    try std.testing.expectEqual(key1, Server.addressToKey(addr1));
}

test "Server init and deinit" {
    const allocator = std.testing.allocator;
    var server = try Server.init(.{
        .allocator = allocator,
        .port = 0, // Use ephemeral port for testing
    });
    defer server.deinit();

    try std.testing.expect(!server.running);
    try std.testing.expectEqual(@as(usize, 0), server.connections.count());
}
