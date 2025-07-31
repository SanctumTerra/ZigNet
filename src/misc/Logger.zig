/// A list of colors for the terminal
pub const Colors = struct {
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const RESET = "\x1b[0m";
    pub const GRAY = "\x1b[90m";
    pub const YELLOW = "\x1b[93m";
    pub const BLUE = "\x1b[94m";
    pub const MAGENTA = "\x1b[95m";
    pub const CYAN = "\x1b[96m";
    pub const WHITE = "\x1b[97m";
    pub const BLACK = "\x1b[98m";
    pub const GOLD = "\x1b[99m";
    pub const SILVER = "\x1b[100m";
    pub const BRIGHT_RED = "\x1b[101m";
    pub const BRIGHT_GREEN = "\x1b[102m";
    pub const BRIGHT_YELLOW = "\x1b[103m";
    pub const BRIGHT_BLUE = "\x1b[104m";
    pub const BRIGHT_MAGENTA = "\x1b[105m";
    pub const BRIGHT_CYAN = "\x1b[106m";
    pub const PINK = "\x1b[107m";
    pub const LIME = "\x1b[108m";
    pub const PURPLE = "\x1b[109m";
    pub const BOLD = "\x1b[1m";
    pub const UNDERLINE = "\x1b[4m";
    pub const REVERSED = "\x1b[7m";
    pub const HIDDEN = "\x1b[8m";
    pub const STRIKETHROUGH = "\x1b[9m";
    pub const ITALIC = "\x1b[3m";
    pub const BOLD_ITALIC = "\x1b[1;3m";
    pub const BOLD_UNDERLINE = "\x1b[1;4m";
    pub const BOLD_REVERSED = "\x1b[1;7m";
    pub const BOLD_HIDDEN = "\x1b[1;8m";
    pub const BOLD_STRIKETHROUGH = "\x1b[1;9m";
    pub const BOLD_ITALIC_UNDERLINE = "\x1b[1;3;4m";
    pub const BOLD_ITALIC_REVERSED = "\x1b[1;3;7m";
    pub const BOLD_ITALIC_HIDDEN = "\x1b[1;3;8m";
    pub const BOLD_ITALIC_STRIKETHROUGH = "\x1b[1;3;9m";
    pub const BOLD_UNDERLINE_REVERSED = "\x1b[1;4;7m";
    pub const BOLD_UNDERLINE_HIDDEN = "\x1b[1;4;8m";
    pub const BOLD_UNDERLINE_STRIKETHROUGH = "\x1b[1;4;9m";
    pub const BOLD_REVERSED_HIDDEN = "\x1b[1;7;8m";
    pub const BOLD_REVERSED_STRIKETHROUGH = "\x1b[1;7;9m";
};

const std = @import("std");

pub const DebugLevel = enum {
    None,
    Info,
    Debug,
    Memory,
};

var current_debug_level: DebugLevel = .None;

pub const Logger = struct {
    pub fn setDebugLevel(level: DebugLevel) void {
        current_debug_level = level;
    }

    pub fn INFO(comptime fmt: []const u8, args: anytype) void {
        const timestamp = std.time.timestamp();
        const localTime = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };

        const daySeconds = localTime.getDaySeconds();
        const hour = daySeconds.getHoursIntoDay();
        const minute = daySeconds.getMinutesIntoHour();
        const second = daySeconds.getSecondsIntoMinute();

        // format: <15:20:08.916> INFO: message
        std.debug.print("{s}<{d:0>2}:{d:0>2}:{d:0>2}> {s}INFO:{s} " ++ fmt ++ "\n", .{ Colors.GRAY, hour, minute, second, Colors.GREEN, Colors.RESET } ++ args);
    }

    pub fn ERROR(comptime fmt: []const u8, args: anytype) void {
        const timestamp = std.time.timestamp();
        const localTime = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };

        const daySeconds = localTime.getDaySeconds();
        const hour = daySeconds.getHoursIntoDay();
        const minute = daySeconds.getMinutesIntoHour();
        const second = daySeconds.getSecondsIntoMinute();

        // format: <15:20:08.916> ERROR: message
        std.debug.print("{s}<{d:0>2}:{d:0>2}:{d:0>2}> {s}ERROR:{s} " ++ fmt ++ "\n", .{ Colors.GRAY, hour, minute, second, Colors.RED, Colors.RESET } ++ args);
    }

    pub fn WARN(comptime fmt: []const u8, args: anytype) void {
        const timestamp = std.time.timestamp();
        const localTime = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };

        const daySeconds = localTime.getDaySeconds();
        const hour = daySeconds.getHoursIntoDay();
        const minute = daySeconds.getMinutesIntoHour();
        const second = daySeconds.getSecondsIntoMinute();

        // format: <15:20:08.916> WARN: message
        std.debug.print("{s}<{d:0>2}:{d:0>2}:{d:0>2}> {s}WARN:{s} " ++ fmt ++ "\n", .{ Colors.GRAY, hour, minute, second, Colors.YELLOW, Colors.RESET } ++ args);
    }

    pub fn DEBUG(comptime fmt: []const u8, args: anytype) void {
        const timestamp = std.time.timestamp();
        const localTime = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };

        const daySeconds = localTime.getDaySeconds();
        const hour = daySeconds.getHoursIntoDay();
        const minute = daySeconds.getMinutesIntoHour();
        const second = daySeconds.getSecondsIntoMinute();

        // format: <15:20:08.916> DEBUG: message
        std.debug.print("{s}<{d:0>2}:{d:0>2}:{d:0>2}> {s}DEBUG:{s} " ++ fmt ++ "\n", .{ Colors.GRAY, hour, minute, second, Colors.BLUE, Colors.RESET } ++ args);
    }

    /// Writes formatted time (HH:MM:SS.mmm) into the provided buffer.
    /// Returns a slice of the buffer containing the formatted time.
    /// No memory is allocated.
    pub fn writeTimeToBuffer(buffer: []u8) ![]const u8 {
        const timestamp_s = std.time.timestamp();
        const timestamp_ns = std.time.nanoTimestamp();

        const seconds_in_day = @mod(timestamp_s, 86400);

        const hours = @divFloor(seconds_in_day, 3600);
        const minutes = @divFloor(@mod(seconds_in_day, 3600), 60);
        const seconds = @mod(seconds_in_day, 60);

        // Get milliseconds by taking remainder of nanoseconds divided by seconds
        const milliseconds = @divFloor(@mod(timestamp_ns, 1_000_000_000), 1_000_000);

        const h = @as(u8, @intCast(@abs(hours)));
        const m = @as(u8, @intCast(@abs(minutes)));
        const s = @as(u8, @intCast(@abs(seconds)));
        const ms = @as(u16, @intCast(@abs(milliseconds)));

        return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ h, m, s, ms });
    }

    /// Writes formatted date (YYYY-MM-DD) into the provided buffer.
    /// Returns a slice of the buffer containing the formatted date.
    /// No memory is allocated.
    pub fn writeDateToBuffer(buffer: []u8) ![]const u8 {
        const t = std.time.timestamp();
        const d = @divFloor(t, 86400);
        var y: i32 = 1970;
        var r = d;
        while (true) {
            const is_leap_year = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or (@mod(y, 400) == 0);
            const dy: i32 = if (is_leap_year) 366 else 365;
            if (r >= dy) {
                r -= dy;
                y += 1;
            } else break;
        }
        const m = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var mo: i32 = 1;
        var da = r + 1;
        for (m, 0..) |dm, i| {
            var days: i32 = dm;
            const feb_is_leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or (@mod(y, 400) == 0);
            if (i == 1 and feb_is_leap) days = 29;
            if (da <= days) break;
            da -= days;
            mo += 1;
        }
        const unsigned_y = @as(u32, @intCast(@abs(y)));
        const unsigned_mo = @as(u8, @intCast(@abs(mo)));
        const unsigned_da = @as(u8, @intCast(@abs(da)));

        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ unsigned_y, unsigned_mo, unsigned_da });
    }
};
