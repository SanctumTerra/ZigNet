const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

const Address = @import("../../proto/Address.zig").Address;

pub const NewIncomingConnection = struct {
    address: Address,
    internal_address: Address,
    incoming_timestamp: i64,
    server_timestamp: i64,

    pub fn init(address: Address, internal_address: Address, incoming_timestamp: i64, server_timestamp: i64) NewIncomingConnection {
        return .{ .address = address, .internal_address = internal_address, .incoming_timestamp = incoming_timestamp, .server_timestamp = server_timestamp };
    }

    pub fn deinit(self: *NewIncomingConnection, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *NewIncomingConnection, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        try stream.writeUint8(Packets.NewIncomingConnection);

        const address_buffer = self.address.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize client address: {}", .{err});
            return &[_]u8{};
        };
        defer allocator.free(address_buffer);
        try stream.write(address_buffer);

        const internal_address_buffer = self.internal_address.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize internal system address: {}", .{err});
            return &[_]u8{};
        };
        defer allocator.free(internal_address_buffer);

        for (0..20) |i| {
            _ = i;
            try stream.write(internal_address_buffer);
        }

        try stream.writeInt64(self.incoming_timestamp, .Big);
        try stream.writeInt64(self.server_timestamp, .Big);

        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection request: {any}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !NewIncomingConnection {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();

        // Skip packet ID
        _ = try stream.readUint8();

        // Read client address
        const address = try Address.read(&stream, allocator);

        // Read internal addresses (20 times, but we only need the first one)
        const internal_address = try Address.read(&stream, allocator);

        // Skip the remaining 19 internal addresses
        for (1..20) |_| {
            _ = try Address.read(&stream, allocator);
        }

        // Read timestamps
        const incoming_timestamp = try stream.readInt64(.Big);
        const server_timestamp = try stream.readInt64(.Big);

        return NewIncomingConnection.init(address, internal_address, incoming_timestamp, server_timestamp);
    }
};

test "NewIncomingConnection" {
    const allocator = std.testing.allocator;

    // Create test addresses with proper string allocation
    const address_str = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(address_str);
    const internal_address_str = try allocator.dupe(u8, "192.168.1.100");
    defer allocator.free(internal_address_str);

    const address = Address.init(4, address_str, 19132);
    const internal_address = Address.init(4, internal_address_str, 19132);

    var new_incoming_connection = NewIncomingConnection.init(address, internal_address, 123456789, 987654321);
    defer new_incoming_connection.deinit(allocator);

    const serialized = try new_incoming_connection.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try NewIncomingConnection.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    defer deserialized.address.deinit(allocator);
    defer deserialized.internal_address.deinit(allocator);

    try std.testing.expectEqual(new_incoming_connection.address.version, deserialized.address.version);
    try std.testing.expectEqual(new_incoming_connection.address.port, deserialized.address.port);
    try std.testing.expectEqualStrings(new_incoming_connection.address.address, deserialized.address.address);
    try std.testing.expectEqual(new_incoming_connection.internal_address.version, deserialized.internal_address.version);
    try std.testing.expectEqual(new_incoming_connection.internal_address.port, deserialized.internal_address.port);
    try std.testing.expectEqualStrings(new_incoming_connection.internal_address.address, deserialized.internal_address.address);
    try std.testing.expectEqual(new_incoming_connection.incoming_timestamp, deserialized.incoming_timestamp);
    try std.testing.expectEqual(new_incoming_connection.server_timestamp, deserialized.server_timestamp);
    Logger.DEBUG("NewIncomingConnection test passed.", .{});
}
