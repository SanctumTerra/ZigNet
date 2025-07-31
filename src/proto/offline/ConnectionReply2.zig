const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const Server = @import("../../server/Server.zig");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionReply2 = struct {
    guid: i64,
    address: Address,
    mtu: u16,
    encryption_enabled: bool,

    pub fn init(guid: i64, address: Address, mtu: u16, encryption_enabled: bool) ConnectionReply2 {
        return .{ .guid = guid, .address = address, .mtu = mtu, .encryption_enabled = encryption_enabled };
    }

    pub fn serialize(self: *ConnectionReply2, allocator: std.mem.Allocator) []const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        VarInt.write(&stream, Packets.OpenConnectionReply2);
        Magic.write(&stream);
        stream.writeInt64(self.guid, .Big);
        const address_buffer = self.address.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize address: {}", .{err});
            return &[_]u8{};
        };
        stream.write(address_buffer);
        defer allocator.free(address_buffer);
        stream.writeUint16(self.mtu, .Big);
        stream.writeBool(self.encryption_enabled);
        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection reply 2: {}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) ConnectionReply2 {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = VarInt.read(&stream);
        Magic.read(&stream);
        const guid = stream.readInt64(.Big);
        const address = Address.read(&stream, allocator) catch {
            Logger.ERROR("Failed to deserialize address", .{});
            return .{ .guid = 0, .address = Address.init(0, &[_]u8{}, 0), .mtu = 0, .encryption_enabled = false };
        };
        const mtu = stream.readUint16(.Big);
        const encryption_enabled = stream.readBool();
        return .{ .guid = guid, .address = address, .mtu = mtu, .encryption_enabled = encryption_enabled };
    }
};

const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const Magic = @import("../Magic.zig").Magic;
const VarInt = @import("BinaryStream").VarInt;

test "ConnectionReply2" {
    const allocator = std.heap.page_allocator;
    const test_address = Address.init(4, "192.168.1.1", 19132);
    var connection_reply2 = ConnectionReply2.init(987654321, test_address, 1492, false);

    const serialized = connection_reply2.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = ConnectionReply2.deserialize(serialized, allocator);
    defer deserialized.address.deinit(allocator);

    try std.testing.expectEqual(connection_reply2.guid, deserialized.guid);
    try std.testing.expectEqual(connection_reply2.mtu, deserialized.mtu);
    try std.testing.expectEqual(connection_reply2.encryption_enabled, deserialized.encryption_enabled);
    try std.testing.expectEqual(connection_reply2.address.version, deserialized.address.version);
    try std.testing.expectEqual(connection_reply2.address.port, deserialized.address.port);
    try std.testing.expectEqualStrings(connection_reply2.address.address, deserialized.address.address);
    Logger.DEBUG("ConnectionReply2 pass.", .{});
}
