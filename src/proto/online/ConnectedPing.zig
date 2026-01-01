const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectedPing = struct {
    stream: BinaryStream,
    timestamp: i64,
    owns_stream: bool,

    pub fn init(timestamp: i64, allocator: std.mem.Allocator) ConnectedPing {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .timestamp = timestamp,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectedPing) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectedPing) ![]const u8 {
        try self.stream.writeUint8(Packets.ConnectedPing);
        try self.stream.writeInt64(self.timestamp, .Big);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectedPing {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .timestamp = timestamp,
            .owns_stream = true,
        };
    }
};

test "ConnectedPing" {
    const allocator = std.testing.allocator;

    var connected_ping = ConnectedPing.init(123456789, allocator);

    const serialized = try connected_ping.serialize();

    var deserialized = try ConnectedPing.deserialize(serialized, allocator);
    defer deserialized.deinit();
    connected_ping.deinit();

    try std.testing.expectEqual(connected_ping.timestamp, deserialized.timestamp);
    Logger.DEBUG("ConnectedPing test passed.", .{});
}
