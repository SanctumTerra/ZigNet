const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;

pub const AddressError = error{
    InvalidAddressVersion,
    InvalidAddress,
};

pub const Address = struct {
    version: u8,
    address: []const u8,
    port: u16,

    pub fn init(version: u8, address: []const u8, port: u16) Address {
        return .{ .version = version, .address = address, .port = port };
    }

    pub fn initFromRawBuiltin(raw_addr: *const anyopaque, port: u16, family: u8, allocator: std.mem.Allocator) !Address {
        var buf: [48]u8 = undefined;
        var ip_str: []const u8 = undefined;
        var version: u8 = undefined;

        switch (family) {
            2, 4 => { // AF_INET
                const ipv4_bytes = @as(*const [4]u8, @ptrCast(raw_addr));
                ip_str = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
                    ipv4_bytes[0],
                    ipv4_bytes[1],
                    ipv4_bytes[2],
                    ipv4_bytes[3],
                }) catch return AddressError.InvalidAddress;
                version = 4;
            },
            6, 10 => { // AF_INET6
                const ipv6_bytes = @as(*const [16]u8, @ptrCast(raw_addr));
                // Format as IPv6 hex groups
                ip_str = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                    ipv6_bytes[0],
                    ipv6_bytes[1],
                    ipv6_bytes[2],
                    ipv6_bytes[3],
                    ipv6_bytes[4],
                    ipv6_bytes[5],
                    ipv6_bytes[6],
                    ipv6_bytes[7],
                    ipv6_bytes[8],
                    ipv6_bytes[9],
                    ipv6_bytes[10],
                    ipv6_bytes[11],
                    ipv6_bytes[12],
                    ipv6_bytes[13],
                    ipv6_bytes[14],
                    ipv6_bytes[15],
                }) catch return AddressError.InvalidAddress;
                version = 6;
            },
            else => {
                std.log.err("Unsupported address family: {d}", .{family});
                return AddressError.InvalidAddressVersion;
            },
        }

        const owned_address = try allocator.dupe(u8, ip_str);
        return init(version, owned_address, port);
    }

    fn parseIPv4(address: []const u8) ![4]u8 {
        var parts = std.mem.splitAny(u8, address, ".");
        var bytes: [4]u8 = undefined;
        var i: usize = 0;

        while (parts.next()) |part| {
            if (i >= 4) return AddressError.InvalidAddress;
            bytes[i] = std.fmt.parseInt(u8, part, 10) catch return AddressError.InvalidAddress;
            i += 1;
        }

        if (i != 4) return AddressError.InvalidAddress;
        return bytes;
    }

    fn parseIPv6(address: []const u8) ![16]u8 {
        var result: [16]u8 = [_]u8{0} ** 16;

        // Handle :: shorthand by finding it and expanding
        const double_colon_pos = std.mem.indexOf(u8, address, "::");

        if (double_colon_pos) |dc_pos| {
            // Split into before and after ::
            const before = address[0..dc_pos];
            const after = if (dc_pos + 2 < address.len) address[dc_pos + 2 ..] else "";

            // Count parts before ::
            var before_count: usize = 0;
            if (before.len > 0) {
                var before_parts = std.mem.splitAny(u8, before, ":");
                while (before_parts.next()) |part| {
                    if (part.len == 0) continue;
                    const value = std.fmt.parseInt(u16, part, 16) catch return AddressError.InvalidAddress;
                    std.mem.writeInt(u16, result[before_count * 2 ..][0..2], value, .big);
                    before_count += 1;
                }
            }

            // Count parts after ::
            var after_count: usize = 0;
            var after_values: [8]u16 = undefined;
            if (after.len > 0) {
                var after_parts = std.mem.splitAny(u8, after, ":");
                while (after_parts.next()) |part| {
                    if (part.len == 0) continue;
                    const value = std.fmt.parseInt(u16, part, 16) catch return AddressError.InvalidAddress;
                    after_values[after_count] = value;
                    after_count += 1;
                }
            }

            // Write after values at the end
            const after_start = 8 - after_count;
            for (0..after_count) |i| {
                std.mem.writeInt(u16, result[(after_start + i) * 2 ..][0..2], after_values[i], .big);
            }

            return result;
        } else {
            // Parse full IPv6 address
            var parts = std.mem.splitAny(u8, address, ":");
            var i: usize = 0;

            while (parts.next()) |part| {
                if (i >= 8) return AddressError.InvalidAddress;
                const value = std.fmt.parseInt(u16, part, 16) catch return AddressError.InvalidAddress;
                std.mem.writeInt(u16, result[i * 2 ..][0..2], value, .big);
                i += 1;
            }

            if (i != 8) return AddressError.InvalidAddress;
            return result;
        }
    }

    pub fn write(self: Address, allocator: std.mem.Allocator) ![]u8 {
        var buffer_size: usize = undefined;
        if (self.version == 4) {
            buffer_size = 1 + 4 + 2; // version + 4 IPv4 bytes + port
        } else if (self.version == 6) {
            buffer_size = 1 + 2 + 2 + 4 + 16 + 4; // version + header + port + padding + 16 IPv6 bytes + padding
        } else {
            return AddressError.InvalidAddressVersion;
        }

        var buffer = try allocator.alloc(u8, buffer_size);
        var pos: usize = 0;

        buffer[pos] = self.version;
        pos += 1;

        switch (self.version) {
            4 => {
                const ipv4_bytes = try parseIPv4(self.address);
                for (ipv4_bytes) |byte| {
                    buffer[pos] = (~byte) & 0xff;
                    pos += 1;
                }
                std.mem.writeInt(u16, buffer[pos..][0..2], self.port, .big);
            },

            6 => {
                std.mem.writeInt(u16, buffer[pos..][0..2], 23, .big);
                pos += 2;
                std.mem.writeInt(u16, buffer[pos..][0..2], self.port, .big);
                pos += 2;
                std.mem.writeInt(u32, buffer[pos..][0..4], 0, .big);
                pos += 4;

                const ipv6_bytes = try parseIPv6(self.address);
                for (0..8) |i| {
                    const word = std.mem.readInt(u16, ipv6_bytes[i * 2 ..][0..2], .big);
                    std.mem.writeInt(u16, buffer[pos..][0..2], word ^ 0xffff, .big);
                    pos += 2;
                }
                std.mem.writeInt(u32, buffer[pos..][0..4], 0, .big);
            },
            else => return AddressError.InvalidAddressVersion,
        }
        return buffer;
    }

    pub fn read(stream: *BinaryStream, allocator: std.mem.Allocator) !Address {
        const version = try stream.readUint8();
        return switch (version) {
            4 => {
                var ipv4_bytes: [4]u8 = undefined;
                for (0..4) |i| {
                    const byte = try stream.readUint8();
                    ipv4_bytes[i] = ~byte & 0xff;
                }
                const port = try stream.readUint16(.Big);
                const address_str = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ ipv4_bytes[0], ipv4_bytes[1], ipv4_bytes[2], ipv4_bytes[3] });
                return Address{
                    .version = version,
                    .port = port,
                    .address = address_str,
                };
            },

            6 => {
                _ = try stream.readUint16(.Big); // Skip IPv6 header (23)
                const port = try stream.readUint16(.Big);
                _ = try stream.readUint32(.Big); // Skip padding

                var address_parts: [8]u16 = undefined;

                for (0..8) |i| {
                    const word = try stream.readUint16(.Big);
                    address_parts[i] = word ^ 0xffff;
                }

                _ = try stream.readUint32(.Big); // Skip final padding

                const address_str = try std.fmt.allocPrint(allocator, "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}", .{
                    address_parts[0], address_parts[1], address_parts[2], address_parts[3],
                    address_parts[4], address_parts[5], address_parts[6], address_parts[7],
                });

                return Address{
                    .version = version,
                    .port = port,
                    .address = address_str,
                };
            },

            else => {
                std.log.err("Invalid IP version: {d}", .{version});
                return AddressError.InvalidAddressVersion;
            },
        };
    }

    pub fn deinit(self: Address, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};
