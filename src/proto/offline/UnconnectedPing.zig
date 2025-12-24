const Packets = @import("../Packets.zig").Packets;

pub const UnconnectedPing = struct {
    timestamp: i64,
    guid: i64,

    pub fn init(timestamp: i64, guid: i64) UnconnectedPing {
        return .{ .timestamp = timestamp, .guid = guid };
    }

    pub fn deinit(self: *UnconnectedPing) void {
        self.timestamp = 0;
        self.guid = 0;
    }

    pub fn serialize(self: *UnconnectedPing, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        try stream.writeUint8(Packets.UnconnectedPing);
        try stream.writeInt64(self.timestamp, .Big);
        try Magic.write(&stream);
        try stream.writeInt64(self.guid, .Big);
        const payload = try stream.getBufferOwned(allocator);
        return payload;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !UnconnectedPing {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);
        try Magic.read(&stream);
        const guid = try stream.readInt64(.Big);
        return .{ .timestamp = timestamp, .guid = guid };
    }
};

const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const VarInt = @import("BinaryStream").VarInt;
const Magic = @import("../Magic.zig").Magic;
const Logger = @import("../../misc/Logger.zig").Logger;

test "Unconnected Ping" {
    const allocator = std.heap.page_allocator;
    var ping = UnconnectedPing.init(123456789, 987654321);
    defer ping.deinit();

    const serialized = try ping.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try UnconnectedPing.deserialize(serialized, allocator);
    defer deserialized.deinit();

    try std.testing.expectEqual(ping.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(ping.guid, deserialized.guid);
    Logger.DEBUG("UnconnectedPing pass.", .{});
}
