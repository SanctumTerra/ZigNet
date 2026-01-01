const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Frame = @import("../Frame.zig").Frame;
const std = @import("std");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const FrameSet = struct {
    stream: BinaryStream,
    sequence_number: u24,
    frames: []const Frame,
    owns_frames: bool,

    pub fn init(sequence_number: u24, frames: []const Frame, allocator: std.mem.Allocator) FrameSet {
        return .{
            .stream = BinaryStream.init(allocator, null, null),
            .sequence_number = sequence_number,
            .frames = frames,
            .owns_frames = false,
        };
    }

    pub fn serialize(self: *FrameSet) ![]u8 {
        try self.stream.writeUint8(Packets.FrameSet);
        try self.stream.writeUint24(self.sequence_number, .Little);

        for (self.frames) |frame| {
            try frame.write(&self.stream);
        }

        return self.stream.payload.items;
    }

    pub fn deserialize(buffer: []const u8, allocator: std.mem.Allocator) !FrameSet {
        var stream = BinaryStream.init(allocator, buffer, null);
        errdefer stream.deinit();

        _ = try stream.readUint8(); // Skip packet type
        const sequence_number = try stream.readUint24(.Little);

        var frames = std.ArrayList(Frame).initBuffer(&[_]Frame{});
        errdefer frames.deinit(allocator);

        const end_position = stream.payload.items.len;
        while (stream.offset < end_position) {
            const frame = try Frame.read(&stream);
            try frames.append(allocator, frame);
        }

        return FrameSet{
            .stream = stream,
            .sequence_number = sequence_number,
            .frames = try frames.toOwnedSlice(allocator),
            .owns_frames = true,
        };
    }

    pub fn deinit(self: *FrameSet, allocator: std.mem.Allocator) void {
        if (self.owns_frames) {
            allocator.free(self.frames);
        }
        self.stream.deinit();
    }
};

test "FrameSet" {
    const allocator = std.heap.page_allocator;

    // Create test payload
    const test_payload = try allocator.dupe(u8, "Hello, World!");
    defer allocator.free(test_payload);

    // Create a simple reliable frame
    const frame = Frame.init(1, // reliable_frame_index
        null, // sequence_frame_index
        null, // ordered_frame_index
        null, // order_channel
        .Reliable, // reliability
        test_payload, null, // split_frame_index
        null, // split_id
        null, // split_size
        allocator);

    const frames = [_]Frame{frame};
    var frameset = FrameSet.init(42, &frames, allocator);

    const serialized = try frameset.serialize();

    var deserialized = try FrameSet.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);
    frameset.deinit(allocator);

    try std.testing.expectEqual(@as(u24, 42), deserialized.sequence_number);
    try std.testing.expectEqual(frames.len, deserialized.frames.len);
    try std.testing.expectEqual(frames[0].reliability, deserialized.frames[0].reliability);
    try std.testing.expectEqual(frames[0].reliable_frame_index, deserialized.frames[0].reliable_frame_index);
    try std.testing.expectEqualSlices(u8, frames[0].payload, deserialized.frames[0].payload);
    Logger.DEBUG("FrameSet pass.", .{});
}
