const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequest = struct {
    stream: BinaryStream,
    guid: i64,
    timestamp: i64,
    use_security: bool,
    owns_stream: bool,

    pub fn init(guid: i64, timestamp: i64, use_security: bool, allocator: std.mem.Allocator) ConnectionRequest {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .guid = guid,
            .timestamp = timestamp,
            .use_security = use_security,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionRequest) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionRequest) ![]const u8 {
        try self.stream.writeUint8(Packets.ConnectionRequest);
        try self.stream.writeInt64(self.guid, .Big);
        try self.stream.writeInt64(self.timestamp, .Big);
        try self.stream.writeBool(self.use_security);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequest {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        const guid = try stream.readInt64(.Big);
        const timestamp = try stream.readInt64(.Big);
        const use_security = try stream.readBool();

        return .{
            .stream = stream,
            .guid = guid,
            .timestamp = timestamp,
            .use_security = use_security,
            .owns_stream = true,
        };
    }
};

test "ConnectionRequest" {
    const allocator = std.heap.page_allocator;
    var connection_request = ConnectionRequest.init(123456789, 987654321, true, allocator);

    const serialized = try connection_request.serialize();

    var deserialized = try ConnectionRequest.deserialize(serialized, allocator);
    defer deserialized.deinit();
    connection_request.deinit();

    try std.testing.expectEqual(connection_request.guid, deserialized.guid);
    try std.testing.expectEqual(connection_request.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(connection_request.use_security, deserialized.use_security);
    Logger.DEBUG("ConnectionRequest pass.", .{});
}
