const std = @import("std");
const Packets = @import("../Packets.zig").Packets;
const Logger = @import("../../misc/Logger.zig").Logger;
const BinaryStream = @import("BinaryStream").BinaryStream;

pub const Ack = struct {
    sequences: []u32,
    allocator: std.mem.Allocator,

    pub fn init(sequences: []const u32, allocator: std.mem.Allocator) !Ack {
        const seq = try allocator.alloc(u32, sequences.len);
        @memcpy(seq, sequences);
        return Ack{
            .sequences = seq,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ack) void {
        self.allocator.free(self.sequences);
    }

    /// DEALLOCATE THE RETURNED STRUCT AFTER USE
    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) Ack {
        var stream = BinaryStream.init(allocator, data, 0);
        defer stream.deinit();

        _ = stream.readUint8(); // Read packet ID (UInt8, not VarInt)
        const record_count = stream.readUint16(.Big);

        var sequences = std.ArrayList(u32).init(allocator);
        defer sequences.deinit();

        var index: usize = 0;
        while (index < record_count) : (index += 1) {
            const range = stream.readBool(); // False for range, True for no range
            if (range) {
                const value = stream.readUint24(.Little);
                sequences.append(value) catch |err| {
                    Logger.ERROR("Failed to append sequence value: {}", .{err});
                    continue;
                };
            } else {
                const start = stream.readUint24(.Little);
                const end = stream.readUint24(.Little);
                var seq_index = start;
                while (seq_index <= end) : (seq_index += 1) {
                    sequences.append(seq_index) catch |err| {
                        Logger.ERROR("Failed to append sequence range value: {}", .{err});
                        break;
                    };
                }
            }
        }

        return Ack.init(sequences.items, allocator) catch |err| {
            Logger.ERROR("Failed to initialize Ack: {}", .{err});
            return Ack{
                .sequences = &[_]u32{},
                .allocator = allocator,
            };
        };
    }

    pub fn serialize(self: *const Ack, allocator: std.mem.Allocator) []const u8 {
        var main_buffer = std.ArrayList(u8).init(allocator);
        defer main_buffer.deinit();

        // Write packet ID
        main_buffer.append(Packets.Ack) catch return &[_]u8{};

        var stream = std.ArrayList(u8).init(allocator);
        defer stream.deinit();

        const count = self.sequences.len;
        var records: u16 = 0;

        if (count > 0) {
            // Sort sequences first to match expected behavior
            var sorted_sequences = std.ArrayList(u32).init(allocator);
            defer sorted_sequences.deinit();

            sorted_sequences.appendSlice(self.sequences) catch return &[_]u8{};
            std.mem.sort(u32, sorted_sequences.items, {}, comptime std.sort.asc(u32));

            var cursor: usize = 0;
            var start = sorted_sequences.items[0];
            var last = sorted_sequences.items[0];

            while (cursor < count) {
                const current = sorted_sequences.items[cursor];
                cursor += 1;

                // Safe diff calculation
                const diff = if (current >= last) current - last else 0;

                if (diff == 1) {
                    last = current;
                } else if (diff > 1) {
                    if (start == last) {
                        stream.append(1) catch return &[_]u8{}; // true - single
                        // Write as little endian u24
                        stream.append(@as(u8, @truncate(start))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(start >> 8))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(start >> 16))) catch return &[_]u8{};
                        start = current;
                        last = current;
                    } else {
                        stream.append(0) catch return &[_]u8{}; // false - range
                        // Write start as little endian u24
                        stream.append(@as(u8, @truncate(start))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(start >> 8))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(start >> 16))) catch return &[_]u8{};
                        // Write end as little endian u24
                        stream.append(@as(u8, @truncate(last))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(last >> 8))) catch return &[_]u8{};
                        stream.append(@as(u8, @truncate(last >> 16))) catch return &[_]u8{};
                        start = current;
                        last = current;
                    }
                    records += 1;
                }
            }

            // Last iteration
            if (start == last) {
                stream.append(1) catch return &[_]u8{}; // true - single
                // Write as little endian u24
                stream.append(@as(u8, @truncate(start))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(start >> 8))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(start >> 16))) catch return &[_]u8{};
            } else {
                stream.append(0) catch return &[_]u8{}; // false - range
                // Write start as little endian u24
                stream.append(@as(u8, @truncate(start))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(start >> 8))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(start >> 16))) catch return &[_]u8{};
                // Write end as little endian u24
                stream.append(@as(u8, @truncate(last))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(last >> 8))) catch return &[_]u8{};
                stream.append(@as(u8, @truncate(last >> 16))) catch return &[_]u8{};
            }
            records += 1;

            // Write record count in big endian (UShort)
            main_buffer.append(@as(u8, @truncate(records >> 8))) catch return &[_]u8{};
            main_buffer.append(@as(u8, @truncate(records))) catch return &[_]u8{};

            // Write stream buffer
            main_buffer.appendSlice(stream.items) catch return &[_]u8{};
        } else {
            // Write 0 records
            main_buffer.append(0) catch return &[_]u8{};
            main_buffer.append(0) catch return &[_]u8{};
        }

        return main_buffer.toOwnedSlice() catch &[_]u8{};
    }
};

test "Ack" {
    const allocator = std.heap.page_allocator;
    const test_sequences = [_]u32{ 1, 2, 3, 5, 6, 10 };

    var ack = try Ack.init(&test_sequences, allocator);
    defer ack.deinit();

    const serialized = ack.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = Ack.deserialize(serialized, allocator);
    defer deserialized.deinit();

    try std.testing.expectEqual(ack.sequences.len, deserialized.sequences.len);
    for (ack.sequences, deserialized.sequences) |original, deserialized_seq| {
        try std.testing.expectEqual(original, deserialized_seq);
    }
    Logger.DEBUG("Ack pass.", .{});
}
