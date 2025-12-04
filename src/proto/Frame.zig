const std = @import("std");
pub const BinaryStream = @import("BinaryStream").BinaryStream;

pub const Reliability = enum(u3) { Unreliable, UnreliableSequenced, Reliable, ReliableOrdered, ReliableSequenced, UnreliableWithAckReceipt, ReliableWithAckReceipt, ReliableOrderedWithAckReceipt };
const Flags = enum(u8) { Split = 0x10, Valid = 0x80, Ack = 0x40, Nack = 0x20 };

pub const Frame = struct {
    reliable_frame_index: ?u32,
    sequence_frame_index: ?u32,
    ordered_frame_index: ?u32,
    order_channel: ?u8,
    reliability: Reliability,
    payload: []const u8,
    split_frame_index: ?u32,
    split_id: ?u16,
    split_size: ?u32,
    allocator: ?std.mem.Allocator,

    pub fn init(reliable_frame_index: ?u32, sequence_frame_index: ?u32, ordered_frame_index: ?u32, order_channel: ?u8, reliability: Reliability, payload: []const u8, split_frame_index: ?u32, split_id: ?u16, split_size: ?u32, allocator: ?std.mem.Allocator) Frame {
        return .{
            .reliable_frame_index = reliable_frame_index,
            .sequence_frame_index = sequence_frame_index,
            .ordered_frame_index = ordered_frame_index,
            .order_channel = order_channel,
            .reliability = reliability,
            .payload = payload,
            .split_frame_index = split_frame_index,
            .split_id = split_id,
            .split_size = split_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Frame, allocator: std.mem.Allocator) void {
        if (self.payload.len == 0) return;
        allocator.free(self.payload);
    }

    pub fn read(stream: *BinaryStream, allocator: std.mem.Allocator) !Frame {
        const flags = try stream.readUint8();
        const reliability: Reliability = @as(Reliability, @enumFromInt((flags & 224) >> 5));
        const length = try stream.readUint16(.Big);
        const payload_length = (length + 7) / 8;
        const split = (flags & @intFromEnum(Flags.Split)) != 0;

        if (payload_length + stream.offset > stream.payload.items.len) {
            std.debug.print("Frame length exceeds stream length: {d} > {d}\n", .{ payload_length + stream.offset, stream.payload.items.len });
            @panic("Frame length exceeds stream length");
        }

        var reliable_frame_index: ?u32 = null;
        var sequence_frame_index: ?u32 = null;
        var ordered_frame_index: ?u32 = null;
        var order_channel: ?u8 = null;
        var split_frame_index: ?u32 = null;
        var split_id: ?u16 = null;
        var split_size: ?u32 = null;

        switch (reliability) {
            .Reliable, .ReliableOrdered, .ReliableSequenced, .ReliableWithAckReceipt, .ReliableOrderedWithAckReceipt => {
                reliable_frame_index = try stream.readUint24(.Little);
            },
            else => {},
        }

        switch (reliability) {
            .UnreliableSequenced, .ReliableSequenced => {
                sequence_frame_index = try stream.readUint24(.Little);
            },
            else => {},
        }

        switch (reliability) {
            .ReliableOrdered, .ReliableOrderedWithAckReceipt => {
                ordered_frame_index = try stream.readUint24(.Little);
                order_channel = try stream.readUint8();
            },
            else => {},
        }

        if (split) {
            split_size = try stream.readUint32(.Big);
            split_id = try stream.readUint16(.Big);
            split_frame_index = try stream.readUint32(.Big);
        }

        const temp_payload = stream.read(payload_length);

        const owned_payload = allocator.dupe(u8, temp_payload) catch @panic("Failed to duplicate payload");
        return Frame.init(reliable_frame_index, sequence_frame_index, ordered_frame_index, order_channel, reliability, owned_payload, split_frame_index, split_id, split_size, allocator);
    }

    pub fn write(self: *const Frame, stream: *BinaryStream) !void {
        const flags: u8 = ((@as(u8, @intFromEnum(self.reliability)) << 5) & 0xe0) |
            if (self.isSplit()) @intFromEnum(Flags.Split) else 0;
        try stream.writeUint8(flags);
        const length_in_bits = @as(u16, @intCast(self.payload.len)) * 8;
        try stream.writeUint16(length_in_bits, .Big);

        if (self.isReliable()) {
            try stream.writeUint24(@as(u24, @truncate(self.reliable_frame_index.?)), .Little);
        }
        if (self.isSequenced()) {
            try stream.writeUint24(@as(u24, @truncate(self.sequence_frame_index.?)), .Little);
        }
        if (self.isOrdered()) {
            try stream.writeUint24(@as(u24, @truncate(self.ordered_frame_index.?)), .Little);
            try stream.writeUint8(self.order_channel.?);
        }
        if (self.isSplit()) {
            try stream.writeUint32(self.split_size.?, .Big);
            try stream.writeUint16(self.split_id.?, .Big);
            try stream.writeUint32(self.split_frame_index.?, .Big);
        }
        try stream.write(self.payload);
    }

    pub fn isSplit(self: *const Frame) bool {
        return self.split_size != null and self.split_size.? > 0;
    }

    pub fn isReliable(self: *const Frame) bool {
        return switch (self.reliability) {
            .Reliable, .ReliableOrdered, .ReliableSequenced, .ReliableWithAckReceipt, .ReliableOrderedWithAckReceipt => true,
            else => false,
        };
    }

    pub fn isSequenced(self: *const Frame) bool {
        return switch (self.reliability) {
            .ReliableSequenced, .UnreliableSequenced => true,
            else => false,
        };
    }

    pub fn isOrdered(self: *const Frame) bool {
        return switch (self.reliability) {
            .UnreliableSequenced, .ReliableOrdered, .ReliableSequenced, .ReliableOrderedWithAckReceipt => true,
            else => false,
        };
    }

    pub fn isOrderExclusive(self: *const Frame) bool {
        return switch (self.reliability) {
            .ReliableOrdered, .ReliableOrderedWithAckReceipt => true,
            else => false,
        };
    }

    pub fn getByteLength(self: *const Frame) usize {
        return 3 +
            self.payload.len +
            (if (self.isReliable()) @as(usize, 3) else 0) +
            (if (self.isSequenced()) @as(usize, 3) else 0) +
            (if (self.isOrdered()) @as(usize, 4) else 0) +
            (if (self.isSplit()) @as(usize, 10) else 0);
    }
};
