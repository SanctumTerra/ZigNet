const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequestAccepted = struct {
    stream: BinaryStream,
    address: Address,
    system_index: u16,
    addresses: Address,
    request_timestamp: i64,
    timestamp: i64,
    owns_stream: bool,

    pub fn init(address: Address, system_index: u16, addresses: Address, request_timestamp: i64, timestamp: i64, allocator: std.mem.Allocator) ConnectionRequestAccepted {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .address = address,
            .system_index = system_index,
            .addresses = addresses,
            .request_timestamp = request_timestamp,
            .timestamp = timestamp,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionRequestAccepted, allocator: std.mem.Allocator) void {
        if (self.owns_stream) {
            self.address.deinit(allocator);
            self.addresses.deinit(allocator);
        }
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionRequestAccepted, allocator: std.mem.Allocator) ![]const u8 {
        try self.stream.writeUint8(Packets.ConnectionRequestAccepted);

        const address_buffer = try self.address.write(allocator);
        defer allocator.free(address_buffer);
        try self.stream.write(address_buffer);
        try self.stream.writeUint16(self.system_index, .Big);

        const internal_address_buffer = try self.addresses.write(allocator);
        defer allocator.free(internal_address_buffer);

        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            try self.stream.write(internal_address_buffer);
        }

        try self.stream.writeInt64(self.request_timestamp, .Big);
        try self.stream.writeInt64(self.timestamp, .Big);

        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequestAccepted {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();

        const client_address = try Address.read(&stream, allocator);
        errdefer client_address.deinit(allocator);

        const system_idx = try stream.readUint16(.Big);

        const timestamps_size: usize = 16;
        const remaining_for_addresses = data.len - stream.offset - timestamps_size;

        var first_system_address: ?Address = null;
        const addresses_start = stream.offset;

        if (remaining_for_addresses > 0) {
            first_system_address = Address.read(&stream, allocator) catch |err| {
                client_address.deinit(allocator);
                return err;
            };
            stream.offset = addresses_start + remaining_for_addresses;
        }

        const system_address = first_system_address orelse blk: {
            const dummy_str = try allocator.dupe(u8, "0.0.0.0");
            break :blk Address.init(4, dummy_str, 0);
        };

        const req_timestamp = try stream.readInt64(.Big);
        const server_timestamp = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .address = client_address,
            .system_index = system_idx,
            .addresses = system_address,
            .request_timestamp = req_timestamp,
            .timestamp = server_timestamp,
            .owns_stream = true,
        };
    }
};

test "ConnectionRequestAccepted" {
    const allocator = std.heap.page_allocator;
    const client_address = Address.init(4, "127.0.0.1", 19132);
    const system_address = Address.init(4, "192.168.1.1", 19133);

    var cra = ConnectionRequestAccepted.init(client_address, 0, system_address, 123456789, 987654321, allocator);

    const serialized = try cra.serialize(allocator);

    var deserialized = try ConnectionRequestAccepted.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    cra.deinit(allocator);

    try std.testing.expectEqual(cra.system_index, deserialized.system_index);
    try std.testing.expectEqual(cra.request_timestamp, deserialized.request_timestamp);
    try std.testing.expectEqual(cra.timestamp, deserialized.timestamp);
    Logger.DEBUG("ConnectionRequestAccepted pass.", .{});
}
