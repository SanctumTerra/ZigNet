const BinaryStream = @import("BinaryStream").BinaryStream;

pub const MagicBytes: [16]u8 = [16]u8{
    0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
    0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
};

pub const Magic = struct {
    pub fn read(stream: *BinaryStream) !void {
        stream.offset += 16; // Skip 16 bytes
    }

    pub fn write(stream: *BinaryStream) !void {
        try stream.write(&MagicBytes);
    }
};
