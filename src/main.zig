const network = @import("network");

const std = @import("std");
const Server = @import("Raknet").Server;
const Logger = @import("Raknet").Logger;
const Connection = @import("Raknet").Connection;

const Client = @import("Raknet").Client;

/// This is a test file or an example of  usage
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    // var server = try Server.init(.{
    //     .allocator = allocator,
    // });
    // server.setConnectCallback(onConnect, null);
    // server.setDisconnectCallback(onDisconnect, null);
    // try server.start();
    // std.Thread.sleep(std.time.ns_per_s * 30);
    // server.deinit();

    // const leaks = gpa.detectLeaks();
    // if (leaks) {
    //     Logger.ERROR("Leaks detected", .{});
    // } else {
    //     Logger.INFO("No leaks detected", .{});
    // }

    var client = try Client.init(.{
        .allocator = allocator,
    });

    defer client.deinit();
    try client.connect();

    while (client.status != .Disconnected) {
        std.Thread.sleep(std.time.ns_per_s);
    }
    const leaks = gpa.detectLeaks();
    if (leaks) {
        Logger.ERROR("Leaks detected", .{});
    } else {
        Logger.INFO("No leaks detected", .{});
    }
}

fn onConnect(connection: *Connection, context: ?*anyopaque) void {
    _ = context;
    Logger.INFO("Client connected", .{});
    connection.setGamePacketCallback(onGamePacket, null);
}
fn onDisconnect(connection: *Connection, context: ?*anyopaque) void {
    _ = context;
    Logger.INFO("Client disconnected", .{});
    connection.setGamePacketCallback(onGamePacket, null);
}
fn onGamePacket(connection: *Connection, payload: []const u8, context: ?*anyopaque) void {
    _ = connection;
    _ = context;
    Logger.INFO("Payload received: {any}", .{payload});
}
