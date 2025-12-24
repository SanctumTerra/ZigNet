const std = @import("std");
const Packets = @import("../Packets.zig").Packets;

/// Global variable to track if the server has security enabled (for libcat usage)
pub var server_has_security: bool = false;

pub const ConnectionReply1 = struct {
    guid: i64,
    hasSecurity: bool,
    mtu_size: u16,
    // Security fields (only present if hasSecurity is true)
    has_cookie: bool = false,
    cookie: ?u32 = null,
    server_public_key: ?[294]u8 = null,

    pub fn init(guid: i64, hasSecurity: bool, mtu_size: u16) ConnectionReply1 {
        return .{ .guid = guid, .hasSecurity = hasSecurity, .mtu_size = mtu_size };
    }

    pub fn initWithSecurity(guid: i64, mtu_size: u16, has_cookie: bool, cookie: u32, server_public_key: ?[294]u8) ConnectionReply1 {
        return .{
            .guid = guid,
            .hasSecurity = true,
            .mtu_size = mtu_size,
            .has_cookie = has_cookie,
            .cookie = cookie,
            .server_public_key = server_public_key,
        };
    }

    pub fn deinit(self: *ConnectionReply1, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectionReply1, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        try stream.writeUint8(Packets.OpenConnectionReply1);
        try Magic.write(&stream);
        try stream.writeInt64(self.guid, .Big);
        try stream.writeBool(self.hasSecurity);
        try stream.writeUint16(self.mtu_size, .Big);
        return stream.getBufferOwned(allocator);
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionReply1 {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
<<<<<<< HEAD
        _ = try stream.readUint8(); // packet ID
=======
        _ = try stream.readUint8();
>>>>>>> 999b32431d1aef5e74efbcee2789801dbb6104c8
        try Magic.read(&stream);
        const guid = try stream.readInt64(.Big);
        const hasSecurity = try stream.readBool();

        // Update global security flag
        server_has_security = hasSecurity;

        var result = ConnectionReply1{
            .guid = guid,
            .hasSecurity = hasSecurity,
            .mtu_size = 0, // Will be set after reading security fields
        };

        if (hasSecurity) {
            // Security fields come BEFORE mtu_size
            const remaining = stream.payload.items.len - stream.offset;

            if (remaining >= 1 + 4 + 294 + 2) {
                // ServerHasSecurity & Libcat format:
                // has_cookie (bool), cookie (u32 BE), server_public_key (u8[294]), then mtu_size
                result.has_cookie = try stream.readBool();
                result.cookie = try stream.readUint32(.Big);
                var public_key: [294]u8 = undefined;
                const key_data = stream.read(294);
                @memcpy(&public_key, key_data);
                result.server_public_key = public_key;
            } else if (remaining >= 4 + 2) {
                // ServerHasSecurity & Nothing format:
                // cookie (u32 BE) only, then mtu_size
                result.cookie = try stream.readUint32(.Big);
            }
        }

        // mtu_size comes AFTER security fields
        result.mtu_size = try stream.readUint16(.Big);

        return result;
    }
};

const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;

test "ConnectionReply1" {
    const allocator = std.heap.page_allocator;
    var connection_reply1 = ConnectionReply1.init(123456789, true, 1492);

    const serialized = try connection_reply1.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try ConnectionReply1.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connection_reply1.guid, deserialized.guid);
    try std.testing.expectEqual(connection_reply1.hasSecurity, deserialized.hasSecurity);
    try std.testing.expectEqual(connection_reply1.mtu_size, deserialized.mtu_size);
}
