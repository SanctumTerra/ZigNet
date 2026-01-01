const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;
const Int8 = @import("BinaryStream").Int8;
const Packets = @import("../Packets.zig").Packets;
const Server = @import("../../server/Server.zig");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionRequest1 = struct {
    stream: BinaryStream,
    protocol: u16,
    mtu_size: u16,
    owns_stream: bool,

    pub fn init(protocol: u16, mtu_size: u16, allocator: std.mem.Allocator) ConnectionRequest1 {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .protocol = protocol,
            .mtu_size = mtu_size,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *ConnectionRequest1) void {
        self.stream.deinit();
    }

    pub fn serialize(self: *ConnectionRequest1, allocator: std.mem.Allocator) ![]const u8 {
        try Int8.write(&self.stream, Packets.OpenConnectionRequest1);
        try Magic.write(&self.stream);
        try self.stream.writeUint8(@as(u8, @intCast(self.protocol)));
        const current_size = @as(u16, @intCast(self.stream.payload.items.len));
        const padding_size = self.mtu_size - Server.UDP_HEADER_SIZE - current_size;
        const zeros = try allocator.alloc(u8, padding_size);
        defer allocator.free(zeros);
        @memset(zeros, 0);
        try self.stream.write(zeros);
        return self.stream.payload.items;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ConnectionRequest1 {
        var stream = BinaryStream.init(allocator, data, null);
        errdefer stream.deinit();

        _ = try Int8.read(&stream);
        try Magic.read(&stream);
        const protocol = try stream.readUint8();
        var mtu_size = @as(u16, @intCast(stream.payload.items.len));
        if (mtu_size + Server.UDP_HEADER_SIZE <= Server.MAX_MTU_SIZE) {
            mtu_size = mtu_size + Server.UDP_HEADER_SIZE;
        } else {
            mtu_size = Server.MAX_MTU_SIZE;
        }

        return .{
            .stream = stream,
            .protocol = protocol,
            .mtu_size = mtu_size,
            .owns_stream = true,
        };
    }
};

test "ConnectionRequest1" {
    const allocator = std.heap.page_allocator;
    var connection_request1 = ConnectionRequest1.init(11, 1492, allocator);

    const serialized = try connection_request1.serialize(allocator);

    var deserialized = try ConnectionRequest1.deserialize(serialized, allocator);
    defer deserialized.deinit();
    connection_request1.deinit();

    try std.testing.expectEqual(connection_request1.protocol, deserialized.protocol);
    try std.testing.expectEqual(connection_request1.mtu_size, deserialized.mtu_size);
    Logger.DEBUG("ConnectionRequest1 pass.", .{});
}
