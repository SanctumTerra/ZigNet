const std = @import("std");
const Raknet = @import("Raknet");
const Server = Raknet.Server;
const Client = Raknet.Client;
const Connection = Raknet.Connection;
const Logger = Raknet.Logger;

const SERVER = true; // true = run server, false = run client

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.detectLeaks()) {
            Logger.ERROR("Leaks detected", .{});
        } else {
            Logger.INFO("No leaks detected", .{});
        }
    }

    if (SERVER) {
        try runServer(allocator);
    } else {
        try runClient(allocator);
    }
}

fn runServer(allocator: std.mem.Allocator) !void {
    Logger.INFO("Running ZigNet Server", .{});
    var server = try Server.init(.{
        .allocator = allocator,
    });
    defer server.deinit();

    server.setConnectCallback(onServerConnect, null);
    server.setDisconnectCallback(onServerDisconnect, null);
    try server.start();

    std.Thread.sleep(std.time.ns_per_s * 30);
}

fn runClient(allocator: std.mem.Allocator) !void {
    Logger.INFO("Running ZigNet Client", .{});
    var client = try Client.init(.{
        .allocator = allocator,
        .address = "127.0.0.1",
        .port = 19132,
    });
    defer client.deinit();

    connect_start_time = std.time.milliTimestamp();
    client.setConnectionCallback(onClientConnect, null);
    client.setGamePacketCallback(onGamePacket, null);
    client.setDisconnectionCallback(onClientDisconnect, null);
    try client.connect();

    const time_start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - time_start < 5000 and client.status != .Disconnected) {
        std.Thread.sleep(std.time.ns_per_s);
    }
    std.Thread.sleep(std.time.ns_per_s);
    client.status = .Disconnected;
}

var connect_start_time: i64 = 0;

fn onServerConnect(connection: *Connection, context: ?*anyopaque) void {
    _ = context;
    Logger.INFO("Server: Client connected from {any}", .{connection.address});
}

fn onServerDisconnect(connection: *Connection, context: ?*anyopaque) void {
    _ = context;
    Logger.INFO("Server: Client disconnected from {any}", .{connection.address});
}

fn onClientConnect(client: *Client, context: ?*anyopaque) void {
    _ = context;
    const elapsed = std.time.milliTimestamp() - connect_start_time;
    Logger.INFO("Client: Connected in {d}ms", .{elapsed});
    client.setGamePacketCallback(onGamePacket, null);
}

fn onClientDisconnect(client: *Client, context: ?*anyopaque) void {
    _ = context;
    _ = client;
    Logger.INFO("Client: Disconnected", .{});
}

fn onGamePacket(client: *Client, payload: []const u8, context: ?*anyopaque) void {
    _ = client;
    _ = context;
    Logger.INFO("Payload received: {any}", .{payload});
}
