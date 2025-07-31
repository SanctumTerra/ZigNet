const BinaryStream = @import("BinaryStream").BinaryStream;
const Packets = @import("../Packets.zig").Packets;
const Frame = @import("../Frame.zig").Frame;
const std = @import("std");
const Logger = @import("../../misc/Logger.zig").Logger;

pub const FrameSet = struct {
    sequence_number: u24,
    frames: []const Frame,

    pub fn serialize(self: *const FrameSet, allocator: std.mem.Allocator) ![]u8 {
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();

        stream.writeUint8(Packets.FrameSet);
        stream.writeUint24(self.sequence_number, .Little);

        for (self.frames) |frame| {
            frame.write(&stream);
        }

        return stream.getBufferOwned(allocator);
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !FrameSet {
        var stream = BinaryStream.init(allocator, data, null);
        defer stream.deinit();

        _ = stream.readUint8(); // Skip packet type
        const sequence_number = stream.readUint24(.Little);

        var frames = std.ArrayList(Frame).init(allocator);
        errdefer {
            for (frames.items) |frame| frame.deinit(allocator);
            frames.deinit();
        }
        const end_position = stream.payload.items.len;
        while (stream.offset < end_position) {
            const frame = Frame.read(&stream, allocator);
            try frames.append(frame);
        }

        return FrameSet{
            .sequence_number = sequence_number,
            .frames = try frames.toOwnedSlice(),
        };
    }

    pub fn deinit(self: FrameSet, allocator: std.mem.Allocator) void {
        for (self.frames) |frame| {
            frame.deinit(allocator);
        }
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

    const serialized = try frameset.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try FrameSet.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(frameset.sequence_number, deserialized.sequence_number);
    try std.testing.expectEqual(frameset.frames.len, deserialized.frames.len);
    try std.testing.expectEqual(frameset.frames[0].reliability, deserialized.frames[0].reliability);
    try std.testing.expectEqual(frameset.frames[0].reliable_frame_index, deserialized.frames[0].reliable_frame_index);
    try std.testing.expectEqualSlices(u8, frameset.frames[0].payload, deserialized.frames[0].payload);
    Logger.DEBUG("FrameSet pass.", .{});
}
