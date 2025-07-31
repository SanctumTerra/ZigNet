pub const ConnectionRequest1 = struct {
    /// Usually 11, sometimes still 10 :skull:
    protocol: u16,
    mtu_size: u16,

    pub fn init(protocol: u16, mtu_size: u16) ConnectionRequest1 {
        return .{ .protocol = protocol, .mtu_size = mtu_size };
    }

    pub fn deinit(self: *ConnectionRequest1, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectionRequest1, allocator: std.mem.Allocator) []const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        VarInt.write(&stream, Packets.OpenConnectionRequest1);
        Magic.write(&stream);
        stream.writeUint8(@as(u8, @intCast(self.protocol)));
        const current_size = @as(u16, @intCast(stream.payload.items.len));
        const padding_size = self.mtu_size - Server.UDP_HEADER_SIZE - current_size;
        const zeros = allocator.alloc(u8, padding_size) catch @panic("Failed to allocate padding");
        defer allocator.free(zeros);
        @memset(zeros, 0);
        stream.write(zeros);
        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection request 1: {}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) ConnectionRequest1 {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = VarInt.read(&stream);
        Magic.read(&stream);
        const protocol = stream.readUint8();
        var mtu_size = @as(u16, @intCast(stream.payload.items.len));
        if (mtu_size + Server.UDP_HEADER_SIZE <= Server.MAX_MTU_SIZE) {
            mtu_size = mtu_size + Server.UDP_HEADER_SIZE;
        } else {
            mtu_size = Server.MAX_MTU_SIZE;
        }
        return .{ .protocol = protocol, .mtu_size = mtu_size };
    }
};

test "ConnectionRequest1" {
    const allocator = std.heap.page_allocator;
    var connection_request1 = ConnectionRequest1.init(11, 1492);
    defer connection_request1.deinit(allocator);

    const serialized = connection_request1.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = ConnectionRequest1.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connection_request1.protocol, deserialized.protocol);
    try std.testing.expectEqual(connection_request1.mtu_size, deserialized.mtu_size);
    Logger.DEBUG("ConnectionRequest1 pass.", .{});
}

const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;
const VarInt = @import("BinaryStream").VarInt;
const Packets = @import("../Packets.zig").Packets;
const Server = @import("../../server/Server.zig");
const Logger = @import("../../misc/Logger.zig").Logger;
