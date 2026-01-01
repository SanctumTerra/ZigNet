const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Address = @import("../Address.zig").Address;
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;

pub const NewIncomingConnection = struct {
    stream: BinaryStream,
    address: Address,
    internal_address: Address,
    incoming_timestamp: i64,
    server_timestamp: i64,
    owns_stream: bool,

    pub fn init(address: Address, internal_address: Address, incoming_timestamp: i64, server_timestamp: i64, allocator: std.mem.Allocator) NewIncomingConnection {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .address = address,
            .internal_address = internal_address,
            .incoming_timestamp = incoming_timestamp,
            .server_timestamp = server_timestamp,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *NewIncomingConnection, allocator: std.mem.Allocator) void {
        if (self.owns_stream) {
            self.address.deinit(allocator);
            self.internal_address.deinit(allocator);
        }
        self.stream.deinit();
    }

    pub fn serialize(self: *NewIncomingConnection, allocator: std.mem.Allocator) ![]const u8 {
        try self.stream.writeUint8(Packets.NewIncomingConnection);

        const address_buffer = try self.address.write(allocator);
        defer allocator.free(address_buffer);
        try self.stream.write(address_buffer);

        const internal_address_buffer = try self.internal_address.write(allocator);
        defer allocator.free(internal_address_buffer);

        for (0..10) |_| {
            try self.stream.write(internal_address_buffer);
        }

        try self.stream.writeInt64(self.incoming_timestamp, .Big);
        try self.stream.writeInt64(self.server_timestamp, .Big);

        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !NewIncomingConnection {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try stream.readUint8();

        const address = try Address.read(&stream, allocator);
        errdefer address.deinit(allocator);

        var internal_address: ?Address = null;
        var address_count: usize = 0;
        var last_valid_pos: usize = stream.offset;

        while (address_count < 20) : (address_count += 1) {
            last_valid_pos = stream.offset;
            const addr = Address.read(&stream, allocator) catch |err| {
                if (err == error.InvalidAddressVersion) {
                    stream.offset = last_valid_pos;
                    break;
                }
                if (internal_address) |ia| {
                    ia.deinit(allocator);
                }
                address.deinit(allocator);
                return err;
            };

            if (internal_address) |ia| {
                ia.deinit(allocator);
            }
            internal_address = addr;
        }

        const final_internal_address = internal_address orelse blk: {
            const dummy_str = try allocator.dupe(u8, "0.0.0.0");
            break :blk Address.init(4, dummy_str, 0);
        };

        const incoming_timestamp = try stream.readInt64(.Big);
        const server_timestamp = try stream.readInt64(.Big);

        return .{
            .stream = stream,
            .address = address,
            .internal_address = final_internal_address,
            .incoming_timestamp = incoming_timestamp,
            .server_timestamp = server_timestamp,
            .owns_stream = true,
        };
    }
};

test "NewIncomingConnection" {
    const allocator = std.testing.allocator;

    const address_str = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(address_str);
    const internal_address_str = try allocator.dupe(u8, "192.168.1.100");
    defer allocator.free(internal_address_str);

    const address = Address.init(4, address_str, 19132);
    const internal_address = Address.init(4, internal_address_str, 19132);

    var nic = NewIncomingConnection.init(address, internal_address, 123456789, 987654321, allocator);

    const serialized = try nic.serialize(allocator);

    var deserialized = try NewIncomingConnection.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    nic.deinit(allocator);

    try std.testing.expectEqual(nic.incoming_timestamp, deserialized.incoming_timestamp);
    try std.testing.expectEqual(nic.server_timestamp, deserialized.server_timestamp);
    Logger.DEBUG("NewIncomingConnection test passed.", .{});
}
