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
    try client.connect();

    client.setConnectionCallback(
        onConnect,
        null,
    );
    client.setGamePacketCallback(
        onGamePacket,
        null,
    );
    client.setDisconnectionCallback(
        onDisconnect,
        null,
    );

    const time_start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - time_start < 5000 and client.status != .Disconnected) {
        std.Thread.sleep(std.time.ns_per_s);
    }
    std.Thread.sleep(std.time.ns_per_s);
    client.status = .Disconnected;
    client.deinit();

    const leaks = gpa.detectLeaks();
    if (leaks) {
        Logger.ERROR("Leaks detected", .{});
    } else {
        Logger.INFO("No leaks detected", .{});
    }
}

fn onConnect(connection: *Client, context: ?*anyopaque) void {
    _ = context;
    Logger.INFO("Connection connected", .{});
    connection.setGamePacketCallback(onGamePacket, null);
}

fn onDisconnect(connection: *Client, context: ?*anyopaque) void {
    _ = context;
    _ = connection;
    Logger.INFO("Connection disconnected", .{});
}

fn onGamePacket(connection: *Client, payload: []const u8, context: ?*anyopaque) void {
    _ = connection;
    _ = context;
    Logger.INFO("Payload received: {any}", .{payload});
}
