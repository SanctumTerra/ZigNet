pub const ConnectionRequest2 = struct {
    address: Address,
    mtu_size: u16,
    guid: i64,

    pub fn init(address: Address, mtu_size: u16, guid: i64) ConnectionRequest2 {
        return .{ .address = address, .mtu_size = mtu_size, .guid = guid };
    }

    pub fn serialize(self: *ConnectionRequest2, allocator: std.mem.Allocator) []const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        VarInt.write(&stream, Packets.OpenConnectionRequest2);
        Magic.write(&stream);
        const address_buffer = self.address.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize address: {}", .{err});
            return &[_]u8{};
        };
        stream.write(address_buffer);
        defer allocator.free(address_buffer);
        stream.writeUint16(self.mtu_size, .Big);
        stream.writeInt64(self.guid, .Big);
        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection request 1: {}", .{err});
            return &[_]u8{};
        };
    }

    /// DEALLOCATE THE ADDRESS AFTER USE
    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) ConnectionRequest2 {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = VarInt.read(&stream);
        Magic.read(&stream);
        const address = Address.read(&stream, allocator) catch {
            Logger.ERROR("Failed to deserialize address", .{});
            return .{ .address = Address.init(0, &[_]u8{}, 0), .mtu_size = 0, .guid = 0 };
        };
        const mtu_size = stream.readUint16(.Big);
        const guid = stream.readInt64(.Big);
        return .{ .address = address, .mtu_size = mtu_size, .guid = guid };
    }
};

const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const VarInt = @import("BinaryStream").VarInt;
const Magic = @import("../Magic.zig").Magic;
const Packets = @import("../Packets.zig").Packets;
const Server = @import("../../server/Server.zig").Server;
const Logger = @import("../../misc/Logger.zig").Logger;

test "ConnectionRequest2" {
    const allocator = std.heap.page_allocator;
    const test_address = Address.init(4, "127.0.0.1", 19132);
    var connection_request2 = ConnectionRequest2.init(test_address, 1492, 987654321);

    const serialized = connection_request2.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = ConnectionRequest2.deserialize(serialized, allocator);
    defer deserialized.address.deinit(allocator);

    try std.testing.expectEqual(connection_request2.mtu_size, deserialized.mtu_size);
    try std.testing.expectEqual(connection_request2.guid, deserialized.guid);
    try std.testing.expectEqual(connection_request2.address.version, deserialized.address.version);
    try std.testing.expectEqual(connection_request2.address.port, deserialized.address.port);
    try std.testing.expectEqualStrings(connection_request2.address.address, deserialized.address.address);
    Logger.DEBUG("ConnectionRequest2 pass.", .{});
}
