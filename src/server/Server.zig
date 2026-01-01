const std = @import("std");
const Socket = @import("../socket/socket.zig").Socket;
const Logger = @import("../misc/Logger.zig").Logger;
const Proto = @import("../proto/root.zig");
const Packets = Proto.Packets;
const Connection = @import("./Connection.zig").Connection;
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const PERFORM_TIME_CHECKS = false;

pub const UDP_HEADER_SIZE = 28;
pub const MAX_MTU_SIZE = 1492;
pub const ConnectCallback = *const fn (connection: *Connection, context: ?*anyopaque) void;
pub const DisconnectCallback = *const fn (connection: *Connection, context: ?*anyopaque) void;

pub const Server = struct {
    const Self = @This();
    options: ServerOptions,
    socket: Socket,
    running: bool = false,
    connections: std.StringHashMap(Connection),
    connections_mutex: Mutex, // Add mutex for connections HashMap
    tick_thread: ?Thread,
    connect_callback: ?ConnectCallback,
    connect_context: ?*anyopaque,
    disconnect_callback: ?DisconnectCallback,
    disconnect_context: ?*anyopaque,

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
            .connections = std.StringHashMap(Connection).init(options.allocator),
            .connections_mutex = Mutex{},
            .tick_thread = null,
            .connect_callback = options.connect_callback,
            .connect_context = options.connect_context,
            .disconnect_callback = options.disconnect_callback,
            .disconnect_context = options.disconnect_context,
        };
        return server;
    }

    fn tickLoop(self: *Self) void {
        while (self.running) {
            const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;
            self.connections_mutex.lock();

            const buffer: [][]const u8 = &[_][]const u8{};
            var to_remove = std.ArrayList([]const u8).initBuffer(buffer);

            defer to_remove.deinit(self.options.allocator);

            {
                var itter = self.connections.iterator();
                while (itter.next()) |val| {
                    if (val.value_ptr.active) {
                        val.value_ptr.tick();
                    } else {
                        to_remove.append(self.options.allocator, val.key_ptr.*) catch {
                            Logger.ERROR("Failed to append to removal list", .{});
                            continue;
                        };
                    }
                }
            }

            for (to_remove.items) |key| {
                if (self.connections.getPtr(key)) |connection| {
                    connection.deinit();
                    if (self.connections.fetchRemove(key)) |removed| {
                        Logger.INFO("Disconnected connection with key: {s}", .{removed.key});
                        self.options.allocator.free(removed.key);
                    }
                }
            }

            self.connections_mutex.unlock();

            if (PERFORM_TIME_CHECKS and false) {
                const end_time = std.time.milliTimestamp();
                const elapsed = end_time - start_time;
                Logger.DEBUG("PERF: tickLoop took {d} ms", .{elapsed});
            }

            std.Thread.sleep(std.time.ns_per_s / @as(u64, self.options.tick_rate));
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

    pub fn getAddressAsKey(self: *Self, address: std.net.Address, buf: *[48]u8) []const u8 {
        _ = self;
        return std.fmt.bufPrint(buf, "{any}", .{address}) catch "";
    }

    pub fn packet_callback(data: []const u8, from_addr: std.net.Address, context: ?*anyopaque, allocator: std.mem.Allocator) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        const self = @as(*Self, @ptrCast(@alignCast(context)));
        defer allocator.free(data);

        var ID: u8 = data[0];
        if (ID & 0xF0 == 0x80) ID = 0x80;
        var key_buf: [48]u8 = undefined;
        const key = getAddressAsKey(self, from_addr, &key_buf);

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
                    Logger.INFO("New connection", .{});
                    const connection = Connection.init(self, from_addr, request.mtu_size, request.guid) catch |err| {
                        Logger.ERROR("Failed to create connection: {s}", .{@errorName(err)});
                        return;
                    };

                    const key_copy = self.options.allocator.dupe(u8, key) catch |err| {
                        Logger.ERROR("Failed to copy connection key: {s}", .{@errorName(err)});
                        return;
                    };

                    self.connections.put(key_copy, connection) catch |err| {
                        self.options.allocator.free(key_copy);
                        Logger.ERROR("Failed to add connection to list: {s}", .{@errorName(err)});
                        return;
                    };
                }
            },
            Packets.FrameSet => {
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();

                if (self.connections.getPtr(key)) |conn| {
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

                if (self.connections.getPtr(key)) |conn| {
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

                if (self.connections.getPtr(key)) |conn| {
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

        var key_buf: [48]u8 = undefined;
        const key = self.getAddressAsKey(address, &key_buf);
        Logger.INFO("Disconnecting connection with key: {s}", .{key});

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        if (self.connections.getPtr(key)) |connection| {
            connection.deinit();
            if (self.connections.fetchRemove(key)) |removed| {
                Logger.DEBUG("Connection disconnected successfully: {s}", .{removed.key});
                self.options.allocator.free(removed.key);
            }
        } else {
            Logger.WARN("Attempted to disconnect non-existent connection: {s}", .{key});
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

    /// Get a connection by address (thread-safe)
    pub fn getConnection(self: *Self, address: std.net.Address) ?*Connection {
        var key_buf: [48]u8 = undefined;
        const key = self.getAddressAsKey(address, &key_buf);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        return self.connections.getPtr(key);
    }

    /// Get all active connections (returns a copy for thread safety)
    pub fn getActiveConnections(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(*Connection) {
        var active_connections = std.ArrayList(*Connection).init(allocator);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.active) {
                try active_connections.append(entry.value_ptr);
            }
        }

        return active_connections;
    }

    pub fn deinit(self: *Self) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        self.running = false;
        if (self.tick_thread) |thread| {
            thread.join();
            self.tick_thread = null;
        }

        // Lock before accessing connections for final cleanup
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        defer self.socket.deinit();
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }

        // Use a separate loop to clear and free all keys to avoid iterator invalidation
        const buffer: [][]const u8 = &[_][]const u8{};
        var key_list = std.ArrayList([]const u8).initBuffer(buffer);
        defer key_list.deinit(self.options.allocator);

        {
            var key_it = self.connections.keyIterator();
            while (key_it.next()) |key_ptr| {
                key_list.append(self.options.allocator, key_ptr.*) catch {
                    Logger.ERROR("Failed to append to key list during cleanup", .{});
                    continue;
                };
            }
        }

        for (key_list.items) |key| {
            if (self.connections.fetchRemove(key)) |removed| {
                self.options.allocator.free(removed.key);
            }
        }

        self.connections.deinit();

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
};
