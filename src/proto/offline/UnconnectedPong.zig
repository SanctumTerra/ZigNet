const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const UnconnectedPong = struct {
    stream: BinaryStream,
    timestamp: i64,
    guid: i64,
    message: []const u8,
    owns_stream: bool,

    pub fn init(timestamp: i64, guid: i64, message: []const u8, allocator: std.mem.Allocator) UnconnectedPong {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .timestamp = timestamp,
            .guid = guid,
            .message = message,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *UnconnectedPong, allocator: std.mem.Allocator) void {
        if (self.owns_stream) {
            allocator.free(self.message);
        }
        self.stream.deinit();
    }

    pub fn serialize(self: *UnconnectedPong) ![]const u8 {
        try self.stream.writeUint8(Packets.UnconnectedPong);
        try self.stream.writeInt64(self.timestamp, .Big);
        try self.stream.writeInt64(self.guid, .Big);
        try Magic.write(&self.stream);
        try self.stream.writeString16(self.message, .Big);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !UnconnectedPong {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        const timestamp = try stream.readInt64(.Big);
        const guid = try stream.readInt64(.Big);
        try Magic.read(&stream);
        const message = try stream.readString16(.Big);
        const owned_message = try allocator.dupe(u8, message);

        return .{
            .stream = stream,
            .timestamp = timestamp,
            .guid = guid,
            .message = owned_message,
            .owns_stream = true,
        };
    }
};

test "Unconnected Pong" {
    const allocator = std.heap.page_allocator;
    var pong = UnconnectedPong.init(123456789, 987654321, "Hello World!", allocator);

    const serialized = try pong.serialize();

    var deserialized = try UnconnectedPong.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    pong.deinit(allocator);

    try std.testing.expectEqual(pong.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(pong.guid, deserialized.guid);
    try std.testing.expectEqualStrings(pong.message, deserialized.message);
    Logger.DEBUG("UnconnectedPong pass.", .{});
}
