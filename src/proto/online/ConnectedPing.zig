const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectedPing = struct {
    timestamp: i64,

    pub fn init(timestamp: i64) ConnectedPing {
        return .{ .timestamp = timestamp };
    }

    pub fn deinit(self: *ConnectedPing, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectedPing, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();

        try stream.writeUint8(Packets.ConnectedPing);
        try stream.writeInt64(self.timestamp, .Big);

        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize ConnectedPing: {any}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectedPing {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();

        // Skip packet ID
        _ = try stream.readUint8();

        // Read timestamp
        const timestamp = try stream.readInt64(.Big);

        return ConnectedPing.init(timestamp);
    }
};

test "ConnectedPing" {
    const allocator = std.testing.allocator;

    var connected_ping = ConnectedPing.init(123456789);
    defer connected_ping.deinit(allocator);

    const serialized = try connected_ping.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try ConnectedPing.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connected_ping.timestamp, deserialized.timestamp);
    Logger.DEBUG("ConnectedPing test passed.", .{});
}
