const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const UnconnectedPing = struct {
    stream: BinaryStream,
    timestamp: i64,
    guid: i64,
    owns_stream: bool,

    pub fn init(timestamp: i64, guid: i64, allocator: std.mem.Allocator) UnconnectedPing {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .timestamp = timestamp,
            .guid = guid,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *UnconnectedPing) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *UnconnectedPing) ![]const u8 {
        try self.stream.writeUint8(Packets.UnconnectedPing);
        try self.stream.writeInt64(self.timestamp, .Big);
        try Magic.write(&self.stream);
        try self.stream.writeInt64(self.guid, .Big);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !UnconnectedPing {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);
        try Magic.read(&stream);
        const guid = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .timestamp = timestamp,
            .guid = guid,
            .owns_stream = true,
        };
    }
};

test "Unconnected Ping" {
    const allocator = std.heap.page_allocator;
    var ping = UnconnectedPing.init(123456789, 987654321, allocator);

    const serialized = try ping.serialize();

    var deserialized = try UnconnectedPing.deserialize(serialized, allocator);
    defer deserialized.deinit();
    ping.deinit();

    try std.testing.expectEqual(ping.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(ping.guid, deserialized.guid);
    Logger.DEBUG("UnconnectedPing pass.", .{});
}
