pub const AdvertisementType = enum { MCPE, MCEE };
const std = @import("std");
const Logger = @import("../misc/Logger.zig").Logger;

pub const Advertisement = struct {
    game_type: AdvertisementType,
    level_name: []const u8,
    protocol: u16,
    version: []const u8,
    player_count: u16,
    max_players: u16,
    guid: i64,
    name: []const u8,
    gamemode: []const u8,

    pub fn init(game_type: AdvertisementType, level_name: []const u8, protocol: u16, version: []const u8, player_count: u16, max_players: u16, guid: i64, name: []const u8, gamemode: []const u8) Advertisement {
        return .{ .game_type = game_type, .level_name = level_name, .protocol = protocol, .version = version, .player_count = player_count, .max_players = max_players, .guid = guid, .name = name, .gamemode = gamemode };
    }

    pub fn deinit(self: *Advertisement) void {
        self.game_type = .MCPE;
        self.level_name = "";
        self.protocol = 0;
        self.version = "";
        self.player_count = 0;
        self.max_players = 0;
        self.guid = 0;
        self.name = "";
        self.gamemode = "";
    }

    pub fn toString(self: Advertisement, allocator: std.mem.Allocator) []const u8 {
        const type_str = switch (self.game_type) {
            .MCPE => "MCPE",
            .MCEE => "MCEE",
        };

        const result = std.fmt.allocPrint(allocator, "{s};{s};{d};{s};{d};{d};{d};{s};{s};", .{
            type_str,
            self.level_name,
            self.protocol,
            self.version,
            self.player_count,
            self.max_players,
            self.guid,
            self.name,
            self.gamemode,
        }) catch {
            Logger.ERROR("Failed to print advertisement", .{});
            return "";
        };
        return result;
    }
};
