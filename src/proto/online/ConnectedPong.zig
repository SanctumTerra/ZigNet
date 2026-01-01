const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectedPong = struct {
    stream: BinaryStream,
    timestamp: i64,
    pong_timestamp: i64,
    owns_stream: bool,

    pub fn init(timestamp: i64, pong_timestamp: i64, allocator: std.mem.Allocator) ConnectedPong {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .timestamp = timestamp,
            .pong_timestamp = pong_timestamp,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectedPong) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectedPong) ![]const u8 {
        try self.stream.writeUint8(Packets.ConnectedPong);
        try self.stream.writeInt64(self.timestamp, .Big);
        try self.stream.writeInt64(self.pong_timestamp, .Big);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectedPong {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);
        const pong_timestamp = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .timestamp = timestamp,
            .pong_timestamp = pong_timestamp,
            .owns_stream = true,
        };
    }
};

test "ConnectedPong" {
    const allocator = std.testing.allocator;

    var connected_pong = ConnectedPong.init(123456789, 987654321, allocator);

    const serialized = try connected_pong.serialize();

    var deserialized = try ConnectedPong.deserialize(serialized, allocator);
    defer deserialized.deinit();
    connected_pong.deinit();

    try std.testing.expectEqual(connected_pong.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(connected_pong.pong_timestamp, deserialized.pong_timestamp);
    Logger.DEBUG("ConnectedPong test passed.", .{});
}
