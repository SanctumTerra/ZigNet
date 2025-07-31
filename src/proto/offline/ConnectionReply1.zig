const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const Server = @import("../../server/Server.zig");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const ConnectionReply1 = struct {
    guid: i64,
    hasSecurity: bool,
    mtu_size: u16,

    pub fn init(guid: i64, hasSecurity: bool, mtu_size: u16) ConnectionReply1 {
        return .{ .guid = guid, .hasSecurity = hasSecurity, .mtu_size = mtu_size };
    }

    pub fn deinit(self: *ConnectionReply1, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn serialize(self: *ConnectionReply1, allocator: std.mem.Allocator) []const u8 {
        const buffer = &[_]u8{};
        var stream = BinaryStream.init(allocator, buffer, 0);
        defer stream.deinit();
        VarInt.write(&stream, Packets.OpenConnectionReply1);
        Magic.write(&stream);
        stream.writeInt64(self.guid, .Big);
        stream.writeBool(self.hasSecurity);
        stream.writeUint16(self.mtu_size, .Big);
        return stream.getBufferOwned(allocator) catch |err| {
            Logger.ERROR("Failed to serialize connection reply 1: {}", .{err});
            return &[_]u8{};
        };
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) ConnectionReply1 {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();
        _ = VarInt.read(&stream);
        Magic.read(&stream);
        const guid = stream.readInt64(.Big);
        const hasSecurity = stream.readBool();
        const mtu_size = stream.readUint16(.Big);
        return .{ .guid = guid, .hasSecurity = hasSecurity, .mtu_size = mtu_size };
    }
};

const BinaryStream = @import("BinaryStream").BinaryStream;
const Magic = @import("../Magic.zig").Magic;
const VarInt = @import("BinaryStream").VarInt;

test "ConnectionReply1" {
    const allocator = std.heap.page_allocator;
    var connection_reply1 = ConnectionReply1.init(123456789, true, 1492);

    const serialized = connection_reply1.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = ConnectionReply1.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(connection_reply1.guid, deserialized.guid);
    try std.testing.expectEqual(connection_reply1.hasSecurity, deserialized.hasSecurity);
    try std.testing.expectEqual(connection_reply1.mtu_size, deserialized.mtu_size);
    Logger.DEBUG("ConnectionReply1 pass.", .{});
}
