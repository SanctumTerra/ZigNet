const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequestAccepted = struct {
    address: Address,
    system_index: u16,
    /// System Address that will be written 10 times.
    addresses: Address, // Only the first of the 10 deserialized addresses is stored here.
    request_timestamp: i64,
    timestamp: i64,

    pub fn init(address: Address, system_index: u16, addresses: Address, request_timestamp: i64, timestamp: i64) ConnectionRequestAccepted {
        return .{
            .address = address,
            .system_index = system_index,
            .addresses = addresses,
            .request_timestamp = request_timestamp,
            .timestamp = timestamp,
        };
    }

    pub fn serialize(self: *const ConnectionRequestAccepted, allocator: std.mem.Allocator) ![]const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();

        try VarInt.write(&stream, Packets.ConnectionRequestAccepted);

        const address_buffer = self.address.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize client address: {any}", .{err});
            return &[_]u8{};
        };
        defer allocator.free(address_buffer);
        try stream.write(address_buffer);
        try stream.writeUint16(self.system_index, .Big);

        const internal_address_buffer = self.addresses.write(allocator) catch |err| {
            Logger.ERROR("Failed to serialize internal system address: {any}", .{err});
            return &[_]u8{};
        };
        defer allocator.free(internal_address_buffer);

        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            try stream.write(internal_address_buffer);
        }

        try stream.writeInt64(self.request_timestamp, .Big);
        try stream.writeInt64(self.timestamp, .Big);

        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize ConnectionRequestAccepted: {any}", .{err});
            return &[_]u8{};
        };
    }

    /// DEALLOCATE THE RETURNED ADDRESS AND THE NESTED .addresses FIELD AFTER USE
    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequestAccepted {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();

        _ = try VarInt.read(&stream); // Skip Packet ID

        const client_address = Address.read(&stream, allocator) catch |err| {
            Logger.ERROR("Failed to deserialize client address: {any}", .{err});
            return err;
        };

        const system_idx = try stream.readUint16(.Big);

        // HACK: Some MCBE implementations send 10 addresses, some send 20.
        // Calculate how many bytes remain for addresses by subtracting timestamp size (16 bytes)
        const timestamps_size: usize = 16; // 2x i64
        const remaining_for_addresses = data.len - stream.offset - timestamps_size;

        // Read addresses until we've consumed the expected bytes
        var first_system_address: ?Address = null;
        var address_count: usize = 0;
        const addresses_start = stream.offset;

        while (address_count < 20 and (stream.offset - addresses_start) < remaining_for_addresses) : (address_count += 1) {
            const addr = Address.read(&stream, allocator) catch |err| {
                // Real error - cleanup and return
                if (first_system_address) |fsa| {
                    fsa.deinit(allocator);
                }
                client_address.deinit(allocator);
                return err;
            };

            if (address_count == 0) {
                first_system_address = addr; // Keep the first address
            } else {
                addr.deinit(allocator); // Discard the rest
            }
        }

        // If no addresses were read, create a dummy one
        const system_address = first_system_address orelse blk: {
            const dummy_str = try allocator.dupe(u8, "0.0.0.0");
            break :blk Address.init(4, dummy_str, 0);
        };

        const req_timestamp = try stream.readInt64(.Big);
        const server_timestamp = try stream.readInt64(.Big);

        return ConnectionRequestAccepted.init(
            client_address,
            system_idx,
            system_address,
            req_timestamp,
            server_timestamp,
        );
    }
};

const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const VarInt = @import("BinaryStream").VarInt;

test "ConnectionRequestAccepted" {
    const allocator = std.heap.page_allocator;
    const client_address = Address.init(4, "127.0.0.1", 19132);
    const system_address = Address.init(4, "192.168.1.1", 19133);

    var connection_request_accepted = ConnectionRequestAccepted.init(client_address, 0, system_address, 123456789, 987654321);

    const serialized = try connection_request_accepted.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try ConnectionRequestAccepted.deserialize(serialized, allocator);
    defer deserialized.address.deinit(allocator);
    defer deserialized.addresses.deinit(allocator);

    try std.testing.expectEqual(connection_request_accepted.system_index, deserialized.system_index);
    try std.testing.expectEqual(connection_request_accepted.request_timestamp, deserialized.request_timestamp);
    try std.testing.expectEqual(connection_request_accepted.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(connection_request_accepted.address.version, deserialized.address.version);
    try std.testing.expectEqual(connection_request_accepted.address.port, deserialized.address.port);
    try std.testing.expectEqualStrings(connection_request_accepted.address.address, deserialized.address.address);
    try std.testing.expectEqual(connection_request_accepted.addresses.version, deserialized.addresses.version);
    try std.testing.expectEqual(connection_request_accepted.addresses.port, deserialized.addresses.port);
    try std.testing.expectEqualStrings(connection_request_accepted.addresses.address, deserialized.addresses.address);
    Logger.DEBUG("ConnectionRequestAccepted pass.", .{});
}
