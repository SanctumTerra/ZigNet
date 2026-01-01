const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;

/// Global variable to track if the server has security enabled (for libcat usage)
pub var server_has_security: bool = false;

pub const ConnectionReply1 = struct {
    stream: BinaryStream,
    guid: i64,
    hasSecurity: bool,
    mtu_size: u16,
    has_cookie: bool = false,
    cookie: ?u32 = null,
    server_public_key: ?[294]u8 = null,
    owns_stream: bool,

    pub fn init(guid: i64, hasSecurity: bool, mtu_size: u16, allocator: std.mem.Allocator) ConnectionReply1 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .guid = guid,
            .hasSecurity = hasSecurity,
            .mtu_size = mtu_size,
            .owns_stream = false,
        };
    }

    pub fn initWithSecurity(guid: i64, mtu_size: u16, has_cookie: bool, cookie: u32, server_public_key: ?[294]u8, allocator: std.mem.Allocator) ConnectionReply1 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .guid = guid,
            .hasSecurity = true,
            .mtu_size = mtu_size,
            .has_cookie = has_cookie,
            .cookie = cookie,
            .server_public_key = server_public_key,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionReply1) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionReply1) ![]const u8 {
        try self.stream.writeUint8(Packets.OpenConnectionReply1);
        try Magic.write(&self.stream);
        try self.stream.writeInt64(self.guid, .Big);
        try self.stream.writeBool(self.hasSecurity);
        try self.stream.writeUint16(self.mtu_size, .Big);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionReply1 {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        try Magic.read(&stream);
        const guid = try stream.readInt64(.Big);
        const hasSecurity = try stream.readBool();

        server_has_security = hasSecurity;

        var result = ConnectionReply1{
            .stream = stream,
            .guid = guid,
            .hasSecurity = hasSecurity,
            .mtu_size = 0,
            .owns_stream = true,
        };

        if (hasSecurity) {
            const remaining = stream.payload.items.len - stream.offset;

            if (remaining >= 1 + 4 + 294 + 2) {
                result.has_cookie = try stream.readBool();
                result.cookie = try stream.readUint32(.Big);
                var public_key: [294]u8 = undefined;
                const key_data = stream.read(294);
                @memcpy(&public_key, key_data);
                result.server_public_key = public_key;
            } else if (remaining >= 4 + 2) {
                result.cookie = try stream.readUint32(.Big);
            }
        }

        result.mtu_size = try stream.readUint16(.Big);
        return result;
    }
};

test "ConnectionReply1" {
    const allocator = std.heap.page_allocator;
    var connection_reply1 = ConnectionReply1.init(123456789, true, 1492, allocator);

    const serialized = try connection_reply1.serialize();

    var deserialized = try ConnectionReply1.deserialize(serialized, allocator);
    defer deserialized.deinit();
    connection_reply1.deinit();

    try std.testing.expectEqual(connection_reply1.guid, deserialized.guid);
    try std.testing.expectEqual(connection_reply1.hasSecurity, deserialized.hasSecurity);
    try std.testing.expectEqual(connection_reply1.mtu_size, deserialized.mtu_size);
}
