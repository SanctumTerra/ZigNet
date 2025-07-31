const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const net = std.net;

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
        const addr = switch (family) {
            2, 4 => blk: { // AF_INET
                const ipv4_bytes = @as(*const [4]u8, @ptrCast(raw_addr));
                break :blk net.Address.initIp4(ipv4_bytes.*, port);
            },
            6, 10 => blk: { // AF_INET6
                const ipv6_bytes = @as(*const [16]u8, @ptrCast(raw_addr));
                break :blk net.Address.initIp6(ipv6_bytes.*, port, 0, 0);
            },
            else => {
                std.log.err("Unsupported address family: {d}", .{family});
                return AddressError.InvalidAddressVersion;
            },
        };

        var buf: [48]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{}", .{addr}) catch |err| {
            std.log.err("Failed to format address: {s}", .{@errorName(err)});
            return err;
        };

        const ip_str = if (std.mem.lastIndexOf(u8, formatted, ":")) |colon_idx|
            formatted[0..colon_idx]
        else
            formatted;

        const version: u8 = if (family == 2 or family == 4) 4 else 6;
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
        var result: [16]u8 = undefined;

        // Handle :: shorthand by finding it and expanding
        const double_colon_pos = std.mem.indexOf(u8, address, "::");

        if (double_colon_pos != null) {
            // For simplicity, let's use std.net to parse IPv6
            const parsed = std.net.Address.parseIp6(address, 0) catch return AddressError.InvalidAddress;
            return parsed.in6.sa.addr;
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
        const version = stream.readUint8();

        return switch (version) {
            4 => {
                var ipv4_bytes: [4]u8 = undefined;
                for (0..4) |i| {
                    const byte = stream.readUint8();
                    ipv4_bytes[i] = ~byte & 0xff;
                }
                const port = stream.readUint16(.Big);
                const address_str = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ ipv4_bytes[0], ipv4_bytes[1], ipv4_bytes[2], ipv4_bytes[3] });
                return Address{
                    .version = version,
                    .port = port,
                    .address = address_str,
                };
            },

            6 => {
                _ = stream.readUint16(.Big); // Skip IPv6 header (23)
                const port = stream.readUint16(.Big);
                _ = stream.readUint32(.Big); // Skip padding

                var address_parts: [8]u16 = undefined;

                for (0..8) |i| {
                    const word = stream.readUint16(.Big);
                    address_parts[i] = word ^ 0xffff;
                }

                _ = stream.readUint32(.Big); // Skip final padding

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
