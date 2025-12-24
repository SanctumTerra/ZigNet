const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Frame = @import("../Frame.zig").Frame;
const std = @import("std");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const FrameSet = struct {
    sequence_number: u24,
    frames: []const Frame,

    pub fn serialize(self: *const FrameSet, stream: *BinaryStream) !void {
        try stream.writeUint8(Packets.FrameSet);
        try stream.writeUint24(self.sequence_number, .Little);

        for (self.frames) |frame| {
            try frame.write(stream);
        }
    }

    pub fn deserialize(stream: *BinaryStream, allocator: std.mem.Allocator) !FrameSet {
        _ = try stream.readUint8(); // Skip packet type
        const sequence_number = try stream.readUint24(.Little);

        var frames = std.ArrayList(Frame).initBuffer(&[_]Frame{});
        errdefer frames.deinit(allocator);

        const end_position = stream.payload.items.len;
        while (stream.offset < end_position) {
            const frame = try Frame.read(stream);
            try frames.append(allocator, frame);
        }

        return FrameSet{
            .sequence_number = sequence_number,
            .frames = try frames.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: FrameSet, allocator: std.mem.Allocator) void {
        // Frames don't own their payloads (they borrow from stream), just free the slice
        allocator.free(self.frames);
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
    const frameset = FrameSet{
        .sequence_number = 42,
        .frames = &frames,
    };

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    try frameset.serialize(&stream);

    // Reset stream offset for reading
    stream.offset = 0;
    var deserialized = try FrameSet.deserialize(&stream, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(frameset.sequence_number, deserialized.sequence_number);
    try std.testing.expectEqual(frameset.frames.len, deserialized.frames.len);
    try std.testing.expectEqual(frameset.frames[0].reliability, deserialized.frames[0].reliability);
    try std.testing.expectEqual(frameset.frames[0].reliable_frame_index, deserialized.frames[0].reliable_frame_index);
    try std.testing.expectEqualSlices(u8, frameset.frames[0].payload, deserialized.frames[0].payload);
    Logger.DEBUG("FrameSet pass.", .{});
}
