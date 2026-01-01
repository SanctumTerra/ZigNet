const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const Magic = @import("../Magic.zig").Magic;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionReply2 = struct {
    stream: BinaryStream,
    guid: i64,
    address: Address,
    mtu: u16,
    encryption_enabled: bool,
    owns_stream: bool,

    pub fn init(guid: i64, address: Address, mtu: u16, encryption_enabled: bool, allocator: std.mem.Allocator) ConnectionReply2 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .guid = guid,
            .address = address,
            .mtu = mtu,
            .encryption_enabled = encryption_enabled,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionReply2, allocator: std.mem.Allocator) void {
        if (self.owns_stream) {
            self.address.deinit(allocator);
        }
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionReply2, allocator: std.mem.Allocator) ![]const u8 {
        try self.stream.writeUint8(Packets.OpenConnectionReply2);
        try Magic.write(&self.stream);
        try self.stream.writeInt64(self.guid, .Big);
        const address_buffer = try self.address.write(allocator);
        defer allocator.free(address_buffer);
        try self.stream.write(address_buffer);
        try self.stream.writeUint16(self.mtu, .Big);
        try self.stream.writeBool(self.encryption_enabled);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionReply2 {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();
        try Magic.read(&stream);
        const guid = try stream.readInt64(.Big);
        const address = try Address.read(&stream, allocator);
        const mtu = try stream.readUint16(.Big);
        const encryption_enabled = try stream.readBool();

        return .{
            .stream = stream,
            .guid = guid,
            .address = address,
            .mtu = mtu,
            .encryption_enabled = encryption_enabled,
            .owns_stream = true,
        };
    }
};

test "ConnectionReply2" {
    const allocator = std.testing.allocator;
    const test_address = Address.init(4, "1.1.1.1", 19132);
    var connection_reply2 = ConnectionReply2.init(987654321, test_address, 1492, false, allocator);

    const serialized = try connection_reply2.serialize(allocator);

    var deserialized = try ConnectionReply2.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    connection_reply2.deinit(allocator);

    try std.testing.expectEqual(connection_reply2.guid, deserialized.guid);
    try std.testing.expectEqual(connection_reply2.mtu, deserialized.mtu);
    try std.testing.expectEqual(connection_reply2.encryption_enabled, deserialized.encryption_enabled);
    Logger.DEBUG("ConnectionReply2 pass.", .{});
}
