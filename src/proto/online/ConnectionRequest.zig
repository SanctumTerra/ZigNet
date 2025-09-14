const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequest = struct {
    guid: i64,
    timestamp: i64,
    use_security: bool,

    pub fn init(guid: i64, timestamp: i64, use_security: bool) ConnectionRequest {
        return .{ .guid = guid, .timestamp = timestamp, .use_security = use_security };
    }

    pub fn deinit(self: *ConnectionRequest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectionRequest, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        try stream.writeUint8(Packets.ConnectionRequest);
        try stream.writeInt64(self.guid, .Big);
        try stream.writeInt64(self.timestamp, .Big);
        try stream.writeBool(self.use_security);

        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection request: {any}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequest {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = try stream.readUint8();
        const guid = try stream.readInt64(.Big);
        const timestamp = try stream.readInt64(.Big);
        const use_security = try stream.readBool();

        return .{ .guid = guid, .timestamp = timestamp, .use_security = use_security };
    }
};

test "ConnectionRequest" {
    const allocator = std.heap.page_allocator;
    var connection_request = ConnectionRequest.init(123456789, 987654321, true);
    defer connection_request.deinit(allocator);

    const serialized = try connection_request.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try ConnectionRequest.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connection_request.guid, deserialized.guid);
    try std.testing.expectEqual(connection_request.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(connection_request.use_security, deserialized.use_security);
    Logger.DEBUG("ConnectionRequest pass.", .{});
}
