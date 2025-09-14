const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectedPong = struct {
    timestamp: i64,
    pong_timestamp: i64,

    pub fn init(timestamp: i64, pong_timestamp: i64) ConnectedPong {
        return .{ .timestamp = timestamp, .pong_timestamp = pong_timestamp };
    }

    pub fn deinit(self: *ConnectedPong, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectedPong, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();

        try stream.writeUint8(Packets.ConnectedPong);
        try stream.writeInt64(self.timestamp, .Big);
        try stream.writeInt64(self.pong_timestamp, .Big);

        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize ConnectedPong: {any}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectedPong {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();

        // Skip packet ID
        _ = try stream.readUint8();

        // Read timestamps
        const timestamp = try stream.readInt64(.Big);
        const pong_timestamp = try stream.readInt64(.Big);

        return ConnectedPong.init(timestamp, pong_timestamp);
    }
};

test "ConnectedPong" {
    const allocator = std.testing.allocator;

    var connected_pong = ConnectedPong.init(123456789, 987654321);
    defer connected_pong.deinit(allocator);

    const serialized = try connected_pong.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try ConnectedPong.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connected_pong.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(connected_pong.pong_timestamp, deserialized.pong_timestamp);
    Logger.DEBUG("ConnectedPong test passed.", .{});
}
