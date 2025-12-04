const std = @import("std");
const Socket = @import("../socket/socket.zig").Socket;
const Logger = @import("../misc/Logger.zig").Logger;

const Address = @import("../proto/Address.zig").Address;
const Proto = @import("../proto/root.zig");
const Frame = Proto.Frame;
const Reliability = Proto.Reliability;

const Packets = @import("../proto/Packets.zig").Packets;
const OpenConnectionRequest1 = @import("../proto/offline/ConnectionRequest1.zig").ConnectionRequest1;
const OpenConnectionRequest2 = @import("../proto/offline/ConnectionRequest2.zig").ConnectionRequest2;
const ConnectionReply2 = @import("../proto/offline/ConnectionReply2.zig").ConnectionReply2;
const ConnectionRequest = @import("../proto/online/ConnectionRequest.zig").ConnectionRequest;
const NewIncomingConnection = @import("../proto/online/NewIncomingConnection.zig").NewIncomingConnection;
const ConnectionRequestAccepted = @import("../proto/online/ConnectionRequestAccepted.zig").ConnectionRequestAccepted;
const ConnectedPing = @import("../proto/online/ConnectedPing.zig").ConnectedPing;
const ConnectedPong = @import("../proto/online/ConnectedPong.zig").ConnectedPong;

const MAX_ACTIVE_FRAGMENTATIONS = 128;
const MAX_ORDERING_QUEUE_SIZE = 128;

pub const GamePacketCallback = *const fn (connection: *Client, payload: []const u8, context: ?*anyopaque) void;
pub const ConnectionCallback = *const fn (connection: *Client, context: ?*anyopaque) void;
pub const DisconnectionCallback = *const fn (connection: *Client, context: ?*anyopaque) void;

pub const Client = struct {
    pub const Self = @This();
    tick_thread: ?std.Thread,
    options: ClientOptions,
    socket: Socket,
    status: Status = .Disconnected,
    comm_data: CommData,
    last_receive: i64,

    game_callback: ?GamePacketCallback = null,
    connection_callback: ?ConnectionCallback = null,

    game_callback_ctx: ?*anyopaque = null,
    connection_callback_ctx: ?*anyopaque = null,

    disconnection_callback: ?DisconnectionCallback = null,
    disconnection_callback_ctx: ?*anyopaque = null,

    pub fn init(options: ClientOptions) !Client {
        var input_ordering_queue = std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)).init(options.allocator);
        var i: u32 = 0;
        while (i < MAX_ACTIVE_FRAGMENTATIONS) : (i += 1) {
            try input_ordering_queue.put(i, std.AutoHashMap(u32, Frame).init(options.allocator));
        }

        var self = Client{
            .options = options,
            .socket = try Socket.init(options.allocator, "0.0.0.0", 0),
            .tick_thread = null,
            .comm_data = .{
                .received_sequences = std.AutoHashMap(u24, void).init(options.allocator),
                .lost_sequences = std.AutoHashMap(u24, void).init(options.allocator),
                .input_order_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .input_highest_sequence_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .input_ordering_queue = input_ordering_queue,
                .output_reliable_index = 0,
                .output_sequence = 0,
                .output_frame_queue = try std.ArrayList(Frame).initCapacity(options.allocator, 0),
                .output_backup = std.AutoHashMap(u24, []Frame).init(options.allocator),
                .output_order_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .output_sequence_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .output_split_index = 0,
                .fragments_queue = std.AutoHashMap(u16, std.AutoHashMap(u16, Frame)).init(options.allocator),
            },
            .last_receive = std.time.milliTimestamp(),
        };

        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
        self.options.guid = prng.random().int(i64);
        return self;
    }

    pub fn connect(self: *Client) !void {
        try self.socket.listen();
        self.socket.setCallback(Client._on, self);
        self.status = .Connecting;

        self.tick_thread = try std.Thread.spawn(.{}, tickLoop, .{self});
        var request = OpenConnectionRequest1.init(11, self.options.mtu_size);
        defer request.deinit(self.options.allocator);
        const payload = try request.serialize(self.options.allocator);
        defer self.options.allocator.free(payload);
        try self.send(payload);
        // std.debug.print("Client sent OpenConnectionRequest1 to {s}:{d}\n", .{ self.options.address, self.options.port });
    }

    pub fn setGamePacketCallback(self: *Client, callback: ?GamePacketCallback, context: ?*anyopaque) void {
        self.game_callback = callback;
        self.game_callback_ctx = context;
    }

    pub fn setConnectionCallback(self: *Client, callback: ?ConnectionCallback, context: ?*anyopaque) void {
        self.connection_callback = callback;
        self.connection_callback_ctx = context;
    }

    pub fn setDisconnectionCallback(self: *Client, callback: ?DisconnectionCallback, context: ?*anyopaque) void {
        self.disconnection_callback = callback;
        self.disconnection_callback_ctx = context;
    }

    fn tickLoop(self: *Self) void {
        // std.debug.print("Client tick loop started.\n", .{});

        while (self.status != .Disconnected) {
            self.tick();
            std.Thread.sleep(std.time.ns_per_s / self.options.tick_rate);
        }
    }

    pub fn onReceive(
        self: *Client,
        payload: []u8,
        from_addr: std.net.Address,
        allocator: std.mem.Allocator,
    ) !void {
        _ = from_addr;
        defer allocator.free(payload);
        var ID: u8 = payload[0];
        if (ID & 0xF0 == 0x80) ID = 0x80;

        self.last_receive = std.time.milliTimestamp();

        switch (ID) {
            Packets.OpenConnectionReply1 => {
                // self.status = .Disconnected;
                const address = Address.init(4, self.options.address, self.options.port);

                var r2 = OpenConnectionRequest2.init(address, self.options.mtu_size, self.options.guid);

                const ser = try r2.serialize(allocator);
                defer allocator.free(ser);

                try self.send(ser);
                // defer address.deinit(allocator);
                // std.debug.print("Client sent OpenConnectionRequest2 to {s}:{d}\n", .{ self.options.address, self.options.port });
            },
            Packets.OpenConnectionReply2 => {
                const reply = try ConnectionReply2.deserialize(payload, allocator);
                defer {
                    reply.address.deinit(allocator);
                }
                // std.debug.print("Received connection reply 2: {any}\n", .{reply});
                var request = ConnectionRequest.init(
                    self.options.guid,
                    reply.mtu,
                    false,
                );
                const serialized = try request.serialize(allocator);
                defer allocator.free(serialized);

                var frame = frameIn(serialized, allocator);
                self.sendFrame(&frame, .Immediate);
                frame.deinit(allocator);

                // std.debug.print("Client connected to {s}:{d}\n", .{ self.options.address, self.options.port });
            },
            Packets.FrameSet => {
                try self.onFrameSet(payload);
            },
            Packets.Ack => {
                try self.handleAck(payload);
            },
            Packets.Nack => {
                try self.handleNack(payload);
            },
            else => {},
        }

        // std.debug.print("Client received packet with ID: {d}\n", .{ID});
    }

    pub fn send(self: *Client, payload: []const u8) !void {
        try self.socket.sendTo(payload, self.options.address, self.options.port);
    }

    pub fn deinit(self: *Client) void {
        // Ensure thread stops before cleanup
        self.status = .Disconnected;
        if (self.tick_thread) |thread| {
            thread.join();
        }

        self.comm_data.deinit(self.options.allocator);
        self.socket.deinit();
    }

    pub fn _on(
        payload: []u8,
        from_addr: std.net.Address,
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
    ) void {
        const self = @as(*Self, @ptrCast(@alignCast(context)));
        self.onReceive(payload, from_addr, allocator) catch |err| {
            std.debug.print("Error in client onReceive: {any}\n", .{err});
        };
    }

    pub fn onFrameSet(self: *Self, buffer: []const u8) !void {
        if (self.status == .Disconnected) return;

        self.last_receive = std.time.milliTimestamp();

        const frameSet = try Proto.FrameSet.deserialize(buffer, self.options.allocator);
        const sequence = frameSet.sequence_number;

        const is_duplicate = (self.comm_data.last_input_sequence != -1 and sequence <= @as(u24, @intCast(@max(0, self.comm_data.last_input_sequence)))) or self.comm_data.received_sequences.contains(sequence);
        if (is_duplicate) {
            defer frameSet.deinit(self.options.allocator);
            return;
        }

        self.comm_data.received_sequences.put(sequence, {}) catch {
            return;
        };
        _ = self.comm_data.lost_sequences.remove(sequence);
        const last_seq = @as(u24, @intCast(@max(0, self.comm_data.last_input_sequence)));
        if (sequence > last_seq + 1) {
            var i: u24 = last_seq + 1;
            while (i < sequence) : (i += 1) {
                self.comm_data.lost_sequences.put(i, {}) catch continue;
            }
        }
        self.comm_data.last_input_sequence = @as(i32, @intCast(sequence));
        for (frameSet.frames) |frame| {
            try self.handleFrame(frame);
        }

        defer frameSet.deinit(self.options.allocator);
    }

    pub fn handleFrame(self: *Client, frame: Frame) !void {
        if (self.status == .Disconnected) return;

        if (frame.payload.len == 0) {
            Logger.WARN("Frame has empty payload - skipping in handleFrame", .{});
            frame.deinit(self.options.allocator);
            return;
        }

        if (frame.isSplit()) {
            try self.handleSplitFrame(frame);
        } else if (frame.isSequenced()) {
            self.handleSequencedFrame(frame);
        } else if (frame.isOrdered()) {
            self.handleOrderedFrame(frame);
        } else {
            self.handlePacket(frame.payload) catch |err| {
                Logger.ERROR("Error handling packet: {any}", .{err});
            };
        }
    }

    pub fn handleOrderedFrame(self: *Client, frame: Frame) void {
        if (self.status == .Disconnected) return;

        const channel = frame.order_channel orelse {
            Logger.ERROR("Ordered frame missing order_channel", .{});
            return;
        };
        const frame_index = frame.ordered_frame_index orelse {
            Logger.ERROR("Ordered frame missing ordered_frame_index", .{});
            return;
        };

        if (frame.ordered_frame_index == self.comm_data.input_order_index[channel]) {
            self.comm_data.input_highest_sequence_index[channel] = @as(u32, @intCast(0));
            self.comm_data.input_order_index[channel] = frame_index + 1;
            self.handlePacket(frame.payload) catch |err| {
                Logger.ERROR("Error handling ordered packet: {any}", .{err});
            };
            var index = self.comm_data.input_order_index[channel];
            var outOfOrderQueue = self.comm_data.input_ordering_queue.getPtr(channel);
            if (outOfOrderQueue == null) {
                Logger.ERROR("Failed to get ordering queue for channel {d}", .{channel});
                return;
            }
            while (outOfOrderQueue.?.contains(index)) : (index += 1) {
                if (outOfOrderQueue.?.get(index)) |ordered_frame| {
                    self.handlePacket(ordered_frame.payload) catch |err| {
                        Logger.ERROR("Error handling ordered queued packet: {any}", .{err});
                    };
                    ordered_frame.deinit(self.options.allocator);
                    _ = outOfOrderQueue.?.remove(index);
                }
            }
            self.comm_data.input_order_index[channel] = index;
        } else if (frame_index > self.comm_data.input_order_index[channel]) {
            const unordered = self.comm_data.input_ordering_queue.getPtr(channel);
            if (unordered) |map| {
                const payload_copy = self.options.allocator.dupe(u8, frame.payload) catch return;
                const frame_copy = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload_copy, frame.split_frame_index, frame.split_id, frame.split_size, self.options.allocator);
                map.put(frame_index, frame_copy) catch {
                    Logger.ERROR("Failed to put out-of-order frame into order queue", .{});
                    frame_copy.deinit(self.options.allocator);
                    return;
                };
            }
        } else {
            self.handlePacket(frame.payload) catch |err| {
                Logger.ERROR("Error handling out-of-order packet: {any}", .{err});
            };
        }
    }

    pub fn handleSequencedFrame(self: *Self, frame: Frame) void {
        const channel = frame.order_channel orelse 0;
        if (channel >= MAX_ACTIVE_FRAGMENTATIONS) {
            Logger.ERROR("Invalid channel: {d}", .{channel});
            return;
        }
        const frame_index = frame.sequence_frame_index orelse {
            Logger.ERROR("Sequenced frame missing sequence_frame_index", .{});
            return;
        };
        const order_index = frame.ordered_frame_index orelse {
            Logger.ERROR("Sequenced frame missing ordered_frame_index", .{});
            return;
        };
        const current_highest = self.comm_data.input_highest_sequence_index[channel];
        if (frame_index >= current_highest and order_index >= self.comm_data.input_order_index[channel]) {
            self.comm_data.input_highest_sequence_index[channel] = frame_index + 1;
            self.handlePacket(frame.payload) catch |err| {
                Logger.ERROR("Error handling sequenced packet: {any}", .{err});
            };
        }
    }

    pub fn handleSplitFrame(self: *Self, frame: Frame) !void {
        Logger.INFO("Split frame received", .{});
        const split_id = frame.split_id orelse {
            Logger.ERROR("Split frame missing split_id", .{});
            return;
        };

        const split_index = frame.split_frame_index orelse {
            Logger.ERROR("Split frame missing split_frame_index", .{});
            return;
        };

        const split_size = frame.split_size orelse {
            Logger.ERROR("Split frame missing split_size", .{});
            return;
        };

        const allocator = self.options.allocator;

        // Check if we already have the fragment id
        if (self.comm_data.fragments_queue.getPtr(split_id)) |fragment| {
            const payload_copy = allocator.dupe(u8, frame.payload) catch {
                Logger.ERROR("Failed to duplicate payload for split frame", .{});
                return;
            };
            const frame_copy = Frame.init(
                frame.reliable_frame_index,
                frame.sequence_frame_index,
                frame.ordered_frame_index,
                frame.order_channel,
                frame.reliability,
                payload_copy,
                frame.split_frame_index,
                frame.split_id,
                frame.split_size,
                allocator,
            );

            fragment.put(@as(u16, @intCast(split_index)), frame_copy) catch {
                Logger.ERROR("Failed to put split frame", .{});
                frame_copy.deinit(allocator);
                return;
            };

            // Check if we have all the fragments
            if (fragment.count() == split_size) {
                var total_length: usize = 0;
                var i: u16 = 0;
                while (i < split_size) : (i += 1) {
                    if (fragment.get(i)) |f| {
                        total_length += f.payload.len;
                    } else {
                        Logger.ERROR("Missing fragment at index {d} for split_id {d}", .{ i, split_id });
                        if (fragment.get(@as(u16, @intCast(split_index)))) |added_frame| {
                            added_frame.deinit(allocator);
                            _ = fragment.remove(@as(u16, @intCast(split_index)));
                        }
                        return;
                    }
                }

                const combined_payload = allocator.alloc(u8, total_length) catch {
                    Logger.ERROR("Failed to allocate combined payload", .{});
                    return;
                };

                var offset: usize = 0;
                i = 0;
                while (i < split_size) : (i += 1) {
                    if (fragment.get(i)) |f| {
                        @memcpy(combined_payload[offset .. offset + f.payload.len], f.payload);
                        offset += f.payload.len;
                        f.deinit(allocator);
                    }
                }

                // Remove the fragment from the queue
                var iter = fragment.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }
                fragment.deinit();
                _ = self.comm_data.fragments_queue.remove(split_id);

                // Handle the combined frame
                const combined_frame = Frame.init(
                    frame.reliable_frame_index,
                    frame.sequence_frame_index,
                    frame.ordered_frame_index,
                    frame.order_channel,
                    frame.reliability,
                    combined_payload,
                    null,
                    null,
                    null,
                    allocator,
                );

                if (combined_frame.isSequenced()) {
                    self.handleSequencedFrame(combined_frame);
                } else if (combined_frame.isOrdered()) {
                    self.handleOrderedFrame(combined_frame);
                } else {
                    self.handlePacket(combined_frame.payload) catch |err| {
                        Logger.ERROR("Error handling combined packet: {any}", .{err});
                    };
                }
                combined_frame.deinit(allocator);
            }
        } else {
            // Add the fragment id to the queue
            var new_fragment = std.AutoHashMap(u16, Frame).init(allocator);

            const payload_copy = allocator.dupe(u8, frame.payload) catch {
                Logger.ERROR("Failed to duplicate payload for new split frame", .{});
                return;
            };
            const frame_copy = Frame.init(
                frame.reliable_frame_index,
                frame.sequence_frame_index,
                frame.ordered_frame_index,
                frame.order_channel,
                frame.reliability,
                payload_copy,
                frame.split_frame_index,
                frame.split_id,
                frame.split_size,
                allocator,
            );

            new_fragment.put(@as(u16, @intCast(split_index)), frame_copy) catch {
                Logger.ERROR("Failed to put new split frame", .{});
                frame_copy.deinit(allocator);
                new_fragment.deinit();
                return;
            };
            self.comm_data.fragments_queue.put(split_id, new_fragment) catch {
                Logger.ERROR("Failed to put new fragment queue", .{});
                frame_copy.deinit(allocator);
                new_fragment.deinit();
                return;
            };
        }
    }

    pub fn handlePacket(self: *Self, payload: []const u8) !void {
        const ID = payload[0];
        // Logger.INFO("Handling inner packet with ID: {d}", .{ID});

        const allocator = self.options.allocator;

        switch (ID) {
            Proto.Packets.ConnectionRequestAccepted => {
                const pak = try ConnectionRequestAccepted.deserialize(payload, allocator);
                defer {
                    pak.address.deinit(allocator);
                    pak.addresses.deinit(allocator);
                }

                var nic = NewIncomingConnection.init(
                    Address.init(4, self.options.address, self.options.port),
                    Address.init(4, "0.0.0.0", 0),
                    std.time.milliTimestamp(),
                    pak.timestamp,
                );
                const serialized = try nic.serialize(allocator);
                defer allocator.free(serialized);

                var frame = Client.frameIn(serialized, allocator);
                self.sendFrame(&frame, .Immediate);
                frame.deinit(allocator);
                self.status = .Connected;

                if (self.connection_callback) |callback| {
                    callback(self, self.connection_callback_ctx);
                }
            },
            Proto.Packets.DisconnectNotification => {
                self.status = .Disconnected;
                if (self.disconnection_callback) |callback| {
                    callback(self, self.disconnection_callback_ctx);
                } else {
                    std.debug.print("Client disconnected by server\n", .{});
                }
                std.debug.print("Client disconnected by server\n", .{});
            },
            254 => {
                if (self.game_callback) |callback| {
                    callback(self, payload, self.game_callback_ctx);
                } else {
                    std.debug.print("Received game packet (ID 254) but no callback is set\n", .{});
                }

                // Game packet - could add callback here
                std.debug.print("Received game packet (ID 254)\n", .{});
            },
            Packets.ConnectedPing => {
                const ping = try ConnectedPing.deserialize(payload, self.options.allocator);
                var pong = ConnectedPong.init(std.time.milliTimestamp(), ping.timestamp);
                const ser = try pong.serialize(self.options.allocator);
                defer self.options.allocator.free(ser);
                var frame = Client.frameIn(ser, self.options.allocator);
                self.sendFrame(&frame, .Immediate);
                frame.deinit(allocator);
            },
            else => {
                Logger.WARN("Unhandeled inner packet {d}", .{ID});
            },
        }
    }

    pub fn handleAck(self: *Self, payload: []const u8) !void {
        if (self.status == .Disconnected) return;

        var ack = try Proto.Ack.deserialize(payload, self.options.allocator);
        defer ack.deinit();

        for (ack.sequences) |seq| {
            if (self.comm_data.output_backup.contains(@as(u24, @intCast(seq)))) {
                if (self.comm_data.output_backup.get(@as(u24, @intCast(seq)))) |iframes| {
                    for (iframes) |*frame| {
                        frame.deinit(self.options.allocator);
                    }
                    self.options.allocator.free(iframes);
                    _ = self.comm_data.output_backup.remove(@as(u24, @intCast(seq)));
                }
            }
        }
    }

    pub fn handleNack(self: *Self, payload: []const u8) !void {
        if (self.status == .Disconnected) return;

        var nack = try Proto.Ack.deserialize(payload, self.options.allocator);
        defer nack.deinit();

        for (nack.sequences) |seq| {
            const frames = self.comm_data.output_backup.get(@as(u24, @intCast(seq)));
            if (frames) |f| {
                var frameset = Proto.FrameSet{
                    .sequence_number = @as(u24, @intCast(seq)),
                    .frames = f,
                };
                defer frameset.deinit(self.options.allocator);
                const serialized = try frameset.serialize(self.options.allocator);
                defer self.options.allocator.free(serialized);
                try self.socket.sendTo(serialized, self.options.address, self.options.port);
            }
        }
    }

    pub fn sendReliableMessage(self: *Client, msg: []const u8, priority: Priority) void {
        var frame = Client.frameIn(msg, self.options.allocator);
        defer frame.deinit(self.options.allocator);
        frame.reliability = Reliability.ReliableOrdered;
        self.sendFrame(&frame, priority);
    }

    pub fn frameIn(msg: []const u8, allocator: std.mem.Allocator) Frame {
        const payload_copy = allocator.dupe(u8, msg) catch |err| {
            Logger.ERROR("Failed to duplicate payload: {any}", .{err});
            return Frame.init(null, null, null, 0, Reliability.ReliableOrdered, &[_]u8{}, null, null, null, allocator);
        };
        return Frame.init(null, null, null, 0, Reliability.ReliableOrdered, payload_copy, null, null, null, allocator);
    }

    pub fn sendFrame(self: *Client, frame: *Frame, priority: Priority) void {
        const channel_index = frame.order_channel orelse 0;
        const channel = @as(usize, channel_index);
        var mutable_frame = frame.*;

        if (mutable_frame.isSequenced()) {
            mutable_frame.ordered_frame_index = self.comm_data.output_order_index[channel];
            mutable_frame.sequence_frame_index = self.comm_data.output_sequence_index[channel];
            self.comm_data.output_sequence_index[channel] += 1;
        } else if (mutable_frame.isOrdered()) {
            mutable_frame.ordered_frame_index = self.comm_data.output_order_index[channel];
            self.comm_data.output_order_index[channel] += 1;
            self.comm_data.output_sequence_index[channel] = 0;
        }

        const payload_size = mutable_frame.payload.len;
        const max_size = self.options.mtu_size - 36;
        if (payload_size <= max_size) {
            if (mutable_frame.isReliable()) {
                mutable_frame.reliable_frame_index = self.comm_data.output_reliable_index;
                self.comm_data.output_reliable_index += 1;
            }
            self.queueFrame(mutable_frame, priority);
            frame.payload = &[_]u8{};
            return;
        } else {
            const split_size: usize = (payload_size + max_size - 1) / max_size;
            frame.payload = &[_]u8{};
            defer mutable_frame.deinit(self.options.allocator);
            self.handleLargePayload(mutable_frame, max_size, split_size, priority);
        }
    }

    pub fn handleLargePayload(self: *Client, frame: Frame, max_size: usize, split_size: usize, priority: Priority) void {
        const allocator = self.options.allocator;
        const split_id = self.comm_data.output_split_index & 0xFFFF;
        self.comm_data.output_split_index = (self.comm_data.output_split_index +% 1);

        var i: usize = 0;
        while (i < frame.payload.len) : (i += 1) {
            const index = i * max_size;
            const end_index = @min(i + max_size, frame.payload.len);
            const fragment_payload = frame.payload[index..end_index];

            const payload_copy = allocator.dupe(u8, fragment_payload) catch {
                Logger.ERROR("Failed to duplicate fragment payload", .{});
                return;
            };

            var new_frame = Frame.init(
                frame.reliable_frame_index,
                frame.sequence_frame_index,
                frame.ordered_frame_index,
                frame.order_channel,
                frame.reliability,
                payload_copy,
                @as(u32, @intCast(index / max_size)),
                split_id,
                @as(u32, @intCast(split_size)),
                allocator,
            );

            if (index != 0 and new_frame.isReliable()) {
                new_frame.reliable_frame_index = self.comm_data.output_reliable_index;
                self.comm_data.output_reliable_index += 1;
            }
            // else if (index == 0 and new_frame.isReliable()) {
            // new_frame.reliable_frame_index = frame.reliable_frame_index;
            // }

            self.queueFrame(new_frame, priority);
            // index += max_size;
        }
    }

    pub fn queueFrame(self: *Client, frame: Frame, priority: Priority) void {
        self.comm_data.output_frame_queue.append(self.options.allocator, frame) catch {
            Logger.ERROR("Failed to queue frame", .{});
            defer frame.deinit(self.options.allocator);
            return;
        };

        const should_send_immediately = priority == Priority.Immediate;
        const queue_len = self.comm_data.output_frame_queue.items.len;
        if (should_send_immediately) {
            self.sendQueue(queue_len);
        }
    }

    pub fn sendQueue(self: *Client, amount: usize) void {
        if (self.comm_data.output_frame_queue.items.len == 0) return;
        const allocator = self.options.allocator;
        const count = @min(amount, self.comm_data.output_frame_queue.items.len);
        const frames = self.comm_data.output_frame_queue.items[0..count];

        const backup = allocator.alloc(Frame, count) catch |err| {
            Logger.ERROR("Backup alloc failed: {any}", .{err});
            self.cleanupOutputQueueFrames(count);
            return;
        };

        for (frames, 0..) |frame, i| {
            const payload = if (frame.payload.len > 0)
                allocator.dupe(u8, frame.payload) catch &[_]u8{}
            else
                &[_]u8{};
            backup[i] = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload, frame.split_frame_index, frame.split_id, frame.split_size, allocator);
        }

        const sequence = @as(u24, @truncate(self.comm_data.output_sequence));
        self.comm_data.output_sequence += 1;

        var frameset = Proto.FrameSet{ .sequence_number = sequence, .frames = backup };
        const serialized = frameset.serialize(allocator) catch |err| {
            Logger.ERROR("Failed to serialize frameset: {any}", .{err});
            return;
        };

        if (self.comm_data.output_backup.contains(sequence)) {
            if (self.comm_data.output_backup.get(sequence)) |iframes| {
                for (iframes) |*frame| {
                    frame.deinit(allocator);
                }
                allocator.free(iframes);
            }
        }

        self.comm_data.output_backup.put(sequence, backup) catch |err| {
            Logger.WARN("Backup store failed, sending without reliability: {any}", .{err});
            for (backup) |*frame| {
                frame.deinit(allocator);
            }
            allocator.free(backup);
        };

        self.cleanupOutputQueueFrames(count);
        self.socket.sendTo(serialized, self.options.address, self.options.port) catch |err| {
            Logger.ERROR("Failed to send frameset: {any}", .{err});
        };
        defer allocator.free(serialized);
    }

    fn cleanupOutputQueueFrames(self: *Client, amount: usize) void {
        const queue = &self.comm_data.output_frame_queue;
        const to_remove = @min(amount, queue.items.len);
        if (to_remove == 0) return;
        for (queue.items[0..to_remove]) |*frame| {
            frame.deinit(self.options.allocator);
        }
        queue.replaceRange(self.options.allocator, 0, to_remove, &[_]Frame{}) catch |err| {
            Logger.ERROR("Failed to cleanup output queue frames: {any}", .{err});
            return;
        };
    }

    pub fn tick(self: *Client) void {
        if (self.status == .Disconnected) return;

        if (self.last_receive + 15000 < std.time.milliTimestamp()) {
            Logger.WARN("Client has not received any packets in 15000ms", .{});
            self.status = .Disconnected;
            return;
        }

        const allocator = self.options.allocator;
        const queue_len = self.comm_data.output_frame_queue.items.len;
        if (queue_len > 0) {
            self.sendQueue(queue_len);
        }
        if (self.comm_data.received_sequences.count() > 0) {
            var sequences_list = std.ArrayList(u32).initBuffer(&[_]u32{});
            defer sequences_list.deinit(allocator);
            var iter = self.comm_data.received_sequences.keyIterator();
            while (iter.next()) |key| {
                sequences_list.append(allocator, key.*) catch continue;
            }
            self.comm_data.received_sequences.clearRetainingCapacity();
            if (sequences_list.items.len == 0) return;
            var ack = Proto.Ack.init(sequences_list.items, allocator) catch return;
            defer ack.deinit();

            const serialized = try ack.serialize(allocator);
            defer allocator.free(serialized);
            self.socket.sendTo(serialized, self.options.address, self.options.port) catch |err| {
                Logger.ERROR("Failed to send ack: {any}", .{err});
            };
        }
        if (self.comm_data.lost_sequences.count() > 0) {
            var sequences_list = std.ArrayList(u32).initBuffer(&[_]u32{});
            defer sequences_list.deinit(allocator);
            var iter = self.comm_data.lost_sequences.keyIterator();
            while (iter.next()) |key| {
                sequences_list.append(allocator, key.*) catch continue;
            }
            self.comm_data.lost_sequences.clearRetainingCapacity();
            if (sequences_list.items.len == 0) return;
            var nack = Proto.Ack.init(sequences_list.items, allocator) catch return;
            defer nack.deinit();
            const serialized = try nack.serialize(allocator);
            defer allocator.free(serialized);
            var mutable_serialized = allocator.dupe(u8, serialized) catch |err| {
                Logger.ERROR("Failed to allocate memory for nack packet: {any}", .{err});
                return;
            };
            defer allocator.free(mutable_serialized);
            mutable_serialized[0] = Proto.Packets.Nack;
            self.socket.sendTo(mutable_serialized, self.options.address, self.options.port) catch |err| {
                Logger.ERROR("Failed to send nack: {any}", .{err});
            };
        }
    }
};

pub const ClientOptions = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    address: []const u8 = "127.0.0.1",
    port: u16 = 19132,
    mtu_size: u16 = 1492,
    guid: i64 = 0,
    tick_rate: u64 = 20,
};

pub const Status = enum {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
};

pub const CommData = struct {
    last_input_sequence: i32 = -1,
    received_sequences: std.AutoHashMap(u24, void),
    lost_sequences: std.AutoHashMap(u24, void),
    input_order_index: [MAX_ACTIVE_FRAGMENTATIONS]u32,
    input_highest_sequence_index: [MAX_ACTIVE_FRAGMENTATIONS]u32,
    input_ordering_queue: std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)),

    output_reliable_index: u32,
    output_sequence: u32,
    output_frame_queue: std.ArrayList(Frame),
    output_backup: std.AutoHashMap(u24, []Frame),
    output_order_index: [MAX_ACTIVE_FRAGMENTATIONS]u32,
    output_sequence_index: [MAX_ACTIVE_FRAGMENTATIONS]u32,
    output_split_index: u16,

    fragments_queue: std.AutoHashMap(u16, std.AutoHashMap(u16, Frame)),

    pub fn deinit(self: *CommData, allocator: std.mem.Allocator) void {
        self.received_sequences.clearAndFree();
        self.lost_sequences.clearAndFree();

        self.received_sequences.deinit();
        self.lost_sequences.deinit();

        for (self.output_frame_queue.items) |*frame| {
            frame.deinit(allocator);
        }
        self.output_frame_queue.clearAndFree(allocator);
        self.output_frame_queue.deinit(allocator);

        var outer_iterator = self.input_ordering_queue.iterator();
        while (outer_iterator.next()) |outer_entry| {
            var inner_iterator = outer_entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                inner_entry.value_ptr.deinit(allocator);
            }
            outer_entry.value_ptr.deinit();
        }
        self.input_ordering_queue.deinit();

        var backup_iter = self.output_backup.iterator();
        while (backup_iter.next()) |entry| {
            const frames = entry.value_ptr.*;
            for (frames) |*frame| {
                frame.deinit(allocator);
            }
            allocator.free(frames);
        }
        self.output_backup.deinit();

        var fragments_iter = self.fragments_queue.iterator();
        while (fragments_iter.next()) |outer_entry| {
            var inner_fragments_iter = outer_entry.value_ptr.iterator();
            while (inner_fragments_iter.next()) |inner_entry| {
                inner_entry.value_ptr.deinit(allocator);
            }
            outer_entry.value_ptr.deinit();
        }
        self.fragments_queue.deinit();
    }
};

pub const Priority = enum(u8) {
    Immediate = 0,
    Normal = 1,
};
