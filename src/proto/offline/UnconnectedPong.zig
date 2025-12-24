const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const UnconnectedPong = struct {
    timestamp: i64,
    guid: i64,
    message: []u8,

    pub fn init(allocator: std.mem.Allocator, timestamp: i64, guid: i64, message: []const u8) !UnconnectedPong {
        const owned_message = try allocator.dupe(u8, message);
        return .{ .timestamp = timestamp, .guid = guid, .message = owned_message };
    }

    pub fn deinit(self: *UnconnectedPong, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.timestamp = 0;
        self.guid = 0;
        self.message = &[_]u8{};
    }

    pub fn serialize(
        self: *UnconnectedPong,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        try stream.writeUint8(Packets.UnconnectedPong);
        try stream.writeInt64(self.timestamp, .Big);
        try stream.writeInt64(self.guid, .Big);
        try Magic.write(&stream);
        try stream.writeString16(self.message, .Big);
        const payload = try stream.getBufferOwned(allocator);
        return payload;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !UnconnectedPong {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);
        const guid = try stream.readInt64(.Big);
        try Magic.read(&stream);
        const message = try stream.readString16(.Big);
        const owned_message = try allocator.dupe(u8, message);
        return .{ .timestamp = timestamp, .guid = guid, .message = owned_message };
    }
};

test "Unconnected Pong" {
    const allocator = std.heap.page_allocator;
    var pong = try UnconnectedPong.init(allocator, 123456789, 987654321, "Hello World!");
    defer pong.deinit(allocator);

    const serialized = try pong.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try UnconnectedPong.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(pong.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(pong.guid, deserialized.guid);
    try std.testing.expectEqualStrings(pong.message, deserialized.message);
    Logger.DEBUG("UnconnectedPong pass.", .{});
}

const BinaryStream = @import("BinaryStream").BinaryStream;
const VarInt = @import("BinaryStream").VarInt;
const Magic = @import("../Magic.zig").Magic;
