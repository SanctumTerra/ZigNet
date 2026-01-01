const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const Magic = @import("../Magic.zig").Magic;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequest2 = struct {
    stream: BinaryStream,
    address: Address,
    mtu_size: u16,
    guid: i64,
    cookie: ?u32 = null,
    client_supports_security: bool = false,
    owns_stream: bool,

    pub fn init(address: Address, mtu_size: u16, guid: i64, allocator: std.mem.Allocator) ConnectionRequest2 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .address = address,
            .mtu_size = mtu_size,
            .guid = guid,
            .owns_stream = false,
        };
    }

    pub fn initWithSecurity(address: Address, mtu_size: u16, guid: i64, cookie: u32, client_supports_security: bool, allocator: std.mem.Allocator) ConnectionRequest2 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .address = address,
            .mtu_size = mtu_size,
            .guid = guid,
            .cookie = cookie,
            .client_supports_security = client_supports_security,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionRequest2, allocator: std.mem.Allocator) void {
        if (self.owns_stream) {
            self.address.deinit(allocator);
        }
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionRequest2, allocator: std.mem.Allocator) ![]const u8 {
        try self.stream.writeUint8(Packets.OpenConnectionRequest2);
        try Magic.write(&self.stream);

        if (self.cookie) |cookie| {
            try self.stream.writeUint32(cookie, .Big);
            try self.stream.writeBool(self.client_supports_security);
        }

        const address_buffer = try self.address.write(allocator);
        defer allocator.free(address_buffer);
        try self.stream.write(address_buffer);

        try self.stream.writeUint16(self.mtu_size, .Big);
        try self.stream.writeInt64(self.guid, .Big);

        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequest2 {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        try Magic.read(&stream);
        const address = try Address.read(&stream, allocator);
        const mtu_size = try stream.readUint16(.Big);
        const guid = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .address = address,
            .mtu_size = mtu_size,
            .guid = guid,
            .owns_stream = true,
        };
    }
};

test "ConnectionRequest2" {
    const allocator = std.heap.page_allocator;
    const test_address = Address.init(4, "127.0.0.1", 19132);
    var connection_request2 = ConnectionRequest2.init(test_address, 1492, 987654321, allocator);

    const serialized = try connection_request2.serialize(allocator);

    var deserialized = try ConnectionRequest2.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    connection_request2.deinit(allocator);

    try std.testing.expectEqual(connection_request2.mtu_size, deserialized.mtu_size);
    try std.testing.expectEqual(connection_request2.guid, deserialized.guid);
    Logger.DEBUG("ConnectionRequest2 pass.", .{});
}
