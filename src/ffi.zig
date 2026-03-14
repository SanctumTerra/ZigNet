const std = @import("std");
const Srv = @import("server/Server.zig");
const Server = Srv.Server;
const ConnectCallback = Srv.ConnectCallback;
const DisconnectCallback = Srv.DisconnectCallback;
const Connection = @import("server/Connection.zig").Connection;
const Priority = @import("server/Connection.zig").Priority;

export fn zignet_server_create() ?*Server {
    return zignet_server_create_on_port(19132);
}

export fn zignet_server_create_on_port(port: u16) ?*Server {
    const allocator = std.heap.page_allocator;
    const server = allocator.create(Server) catch return null;
    server.* = Server.init(.{ .allocator = allocator, .port = port }) catch {
        allocator.destroy(server);
        return null;
    };
    return server;
}

export fn zignet_server_start(server: *Server) bool {
    server.start() catch return false;
    return true;
}

export fn zignet_server_deinit(server: *Server) void {
    server.deinit();
    std.heap.page_allocator.destroy(server);
}

export fn zignet_server_set_connect_callback(
    server: *Server,
    cb: ?ConnectCallback,
    ctx: ?*anyopaque,
) void {
    server.setConnectCallback(cb, ctx);
}

export fn zignet_server_set_disconnect_callback(
    server: *Server,
    cb: ?DisconnectCallback,
    ctx: ?*anyopaque,
) void {
    server.setDisconnectCallback(cb, ctx);
}

const MAX_CONNECTIONS = 512;

var reg_guids: [MAX_CONNECTIONS]i64 = undefined;
var reg_ptrs: [MAX_CONNECTIONS]*Connection = undefined;
var reg_count: usize = 0;
var reg_mutex: std.Thread.Mutex = .{};

fn regFind(guid: i64) ?*Connection {
    for (reg_guids[0..reg_count], 0..) |g, i| {
        if (g == guid) return reg_ptrs[i];
    }
    return null;
}

fn regAdd(conn: *Connection) void {
    reg_mutex.lock();
    defer reg_mutex.unlock();
    if (reg_count < MAX_CONNECTIONS) {
        reg_guids[reg_count] = conn.guid;
        reg_ptrs[reg_count] = conn;
        reg_count += 1;
    }
}

fn regRemove(conn: *Connection) void {
    reg_mutex.lock();
    defer reg_mutex.unlock();
    for (reg_guids[0..reg_count], 0..) |g, i| {
        if (g == conn.guid) {
            reg_count -= 1;
            reg_guids[i] = reg_guids[reg_count];
            reg_ptrs[i] = reg_ptrs[reg_count];
            return;
        }
    }
}

export fn zignet_get_connection_count() u32 {
    reg_mutex.lock();
    defer reg_mutex.unlock();
    return @intCast(reg_count);
}

export fn zignet_send_packet(guid: i64, data: [*]const u8, len: u32) bool {
    reg_mutex.lock();
    const conn = regFind(guid) orelse {
        reg_mutex.unlock();
        return false;
    };
    reg_mutex.unlock();
    conn.sendReliableMessage(data[0..len], Priority.Normal);
    return true;
}

export fn zignet_broadcast(data: [*]const u8, len: u32) void {
    reg_mutex.lock();
    const count = reg_count;
    var ptrs: [MAX_CONNECTIONS]*Connection = undefined;
    @memcpy(ptrs[0..count], reg_ptrs[0..count]);
    reg_mutex.unlock();
    for (ptrs[0..count]) |conn| {
        conn.sendReliableMessage(data[0..len], Priority.Normal);
    }
}

export fn zignet_disconnect(server: *Server, guid: i64) bool {
    reg_mutex.lock();
    const conn = regFind(guid) orelse {
        reg_mutex.unlock();
        return false;
    };
    const addr = conn.address;
    reg_mutex.unlock();
    server.disconnect(addr);
    return true;
}

const QUEUE_SIZE = 256;

var connect_queue: [QUEUE_SIZE]i64 = undefined;
var connect_head: usize = 0;
var connect_tail: usize = 0;
var connect_mutex: std.Thread.Mutex = .{};

var disconnect_queue: [QUEUE_SIZE]i64 = undefined;
var disconnect_head: usize = 0;
var disconnect_tail: usize = 0;
var disconnect_mutex: std.Thread.Mutex = .{};

const MAX_PACKET_SIZE = 4096;
const PACKET_QUEUE_SIZE = 256;

const PacketEntry = struct {
    guid: i64,
    len: u32,
    data: [MAX_PACKET_SIZE]u8,
};

var packet_queue: [PACKET_QUEUE_SIZE]PacketEntry = undefined;
var packet_head: usize = 0;
var packet_tail: usize = 0;
var packet_mutex: std.Thread.Mutex = .{};

fn onGamePacket(conn: *Connection, payload: []const u8, _ctx: ?*anyopaque) void {
    _ = _ctx;
    packet_mutex.lock();
    defer packet_mutex.unlock();
    const next = (packet_tail + 1) % PACKET_QUEUE_SIZE;
    if (next == packet_head) return;
    const entry = &packet_queue[packet_tail];
    entry.guid = conn.guid;
    const copy_len = @min(payload.len, MAX_PACKET_SIZE);
    @memcpy(entry.data[0..copy_len], payload[0..copy_len]);
    entry.len = @intCast(copy_len);
    packet_tail = next;
}

fn onConnectPush(conn: *Connection, _ctx: ?*anyopaque) void {
    _ = _ctx;
    conn.setGamePacketCallback(onGamePacket, null);
    regAdd(conn);
    connect_mutex.lock();
    defer connect_mutex.unlock();
    const next = (connect_tail + 1) % QUEUE_SIZE;
    if (next != connect_head) {
        connect_queue[connect_tail] = conn.guid;
        connect_tail = next;
    }
}

fn onDisconnectPush(conn: *Connection, _ctx: ?*anyopaque) void {
    _ = _ctx;
    regRemove(conn);
    disconnect_mutex.lock();
    defer disconnect_mutex.unlock();
    const next = (disconnect_tail + 1) % QUEUE_SIZE;
    if (next != disconnect_head) {
        disconnect_queue[disconnect_tail] = conn.guid;
        disconnect_tail = next;
    }
}

export fn zignet_server_enable_event_queue(server: *Server) void {
    server.setConnectCallback(onConnectPush, null);
    server.setDisconnectCallback(onDisconnectPush, null);
}

export fn zignet_poll_connect(guid_out: *i64) bool {
    connect_mutex.lock();
    defer connect_mutex.unlock();
    if (connect_head == connect_tail) return false;
    guid_out.* = connect_queue[connect_head];
    connect_head = (connect_head + 1) % QUEUE_SIZE;
    return true;
}

export fn zignet_poll_disconnect(guid_out: *i64) bool {
    disconnect_mutex.lock();
    defer disconnect_mutex.unlock();
    if (disconnect_head == disconnect_tail) return false;
    guid_out.* = disconnect_queue[disconnect_head];
    disconnect_head = (disconnect_head + 1) % QUEUE_SIZE;
    return true;
}

export fn zignet_poll_game_packet(guid_out: *i64, buf: [*]u8, buf_len: u32, len_out: *u32) bool {
    packet_mutex.lock();
    defer packet_mutex.unlock();
    if (packet_head == packet_tail) return false;
    const entry = &packet_queue[packet_head];
    guid_out.* = entry.guid;
    const copy_len = @min(entry.len, buf_len);
    @memcpy(buf[0..copy_len], entry.data[0..copy_len]);
    len_out.* = entry.len;
    packet_head = (packet_head + 1) % PACKET_QUEUE_SIZE;
    return true;
}
