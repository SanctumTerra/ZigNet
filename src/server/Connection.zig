const std = @import("std");
const Server = @import("./Server.zig").Server;
const Proto = @import("../proto/root.zig");
const Frame = Proto.Frame;
const Reliability = Proto.Reliability;
const Logger = @import("../misc/Logger.zig").Logger;
const MAX_ACTIVE_FRAGMENTATIONS = 32;
const MAX_ORDERING_QUEUE_SIZE = 64;

const PERFORM_TIME_CHECKS = false;

// Game packet callback for Connection (packet ID 254)
pub const GamePacketCallback = *const fn (connection: *Connection, payload: []const u8, context: ?*anyopaque) void;

pub const Connection = struct {
    const Self = @This();
    server: *Server,
    address: std.net.Address,
    mtu_size: u16,
    guid: i64,
    connected: bool,
    active: bool,
    comm_data: CommData,
    last_receive: i64,
    game_packet_callback: ?GamePacketCallback,
    game_packet_context: ?*anyopaque,
    tickCounter: u64 = 0,
    last_ping_time: i64 = 0,
    ping_interval: i64 = 5000,

    pub fn init(server: *Server, address: std.net.Address, mtu_size: u16, guid: i64) !Self {
        var input_ordering_queue = std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)).init(server.options.allocator);
        var i: u32 = 0;
        while (i < MAX_ACTIVE_FRAGMENTATIONS) : (i += 1) {
            try input_ordering_queue.put(i, std.AutoHashMap(u32, Frame).init(server.options.allocator));
        }
        return Self{
            .server = server,
            .address = address,
            .mtu_size = mtu_size,
            .guid = guid,
            .connected = false,
            .active = true,
            .comm_data = .{
                .received_sequences = std.AutoHashMap(u24, void).init(server.options.allocator),
                .lost_sequences = std.AutoHashMap(u24, void).init(server.options.allocator),
                .input_order_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .input_highest_sequence_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .input_ordering_queue = input_ordering_queue,
                .output_reliable_index = 0,
                .output_sequence = 0,
                .output_frame_queue = std.ArrayList(Frame).initBuffer(&[_]Frame{}),
                .output_backup = std.AutoHashMap(u24, []Frame).init(server.options.allocator),
                .output_order_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .output_sequence_index = [_]u32{0} ** MAX_ACTIVE_FRAGMENTATIONS,
                .output_split_index = 0,
                .fragments_queue = std.AutoHashMap(u16, std.AutoHashMap(u16, Frame)).init(server.options.allocator),
            },
            .last_receive = std.time.milliTimestamp(),
            .game_packet_callback = null,
            .game_packet_context = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // _ = self;
        self.comm_data.deinit(self.server.options.allocator);
    }

    pub fn handlePacket(self: *Self, payload: []const u8) !void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;
        const ID = payload[0];
        // Logger.INFO("Received Packet {d}", .{ID});
        const allocator = self.server.options.allocator;

        // TODO! ConnectedPing / Pong
        switch (ID) {
            Proto.Packets.ConnectionRequest => {
                const request = try Proto.ConnectionRequest.deserialize(payload, allocator);
                // Logger.INFO("Packet {any}", .{request});
                const empty_address = Proto.Address.init(4, "0.0.0.0", 0);
                var accepted = Proto.ConnectionRequestAccepted.init(empty_address, 0, empty_address, request.timestamp, std.time.milliTimestamp());
                const serialized = try accepted.serialize(allocator);
                defer allocator.free(serialized);
                const frame = frameIn(serialized, allocator);
                self.sendFrame(frame, .Immediate);
            },
            Proto.Packets.NewIncomingConnection => {
                self.connected = true;
                // Trigger server connect callback
                if (self.server.connect_callback) |callback| {
                    callback(self, self.server.connect_context);
                }
            },
            Proto.Packets.DisconnectNotification => {
                self.connected = false;
                self.active = false;
                // Trigger server disconnect callback
                if (self.server.disconnect_callback) |callback| {
                    callback(self, self.server.disconnect_context);
                }
                // self.server.disconnect(self.address);
                // defer self.server.options.allocator.free(self.address);
            },
            254 => {
                // Game packet - trigger connection game packet callback
                if (self.game_packet_callback) |callback| {
                    callback(self, payload, self.game_packet_context);
                } else {
                    Logger.WARN("Received game packet (254) but no callback set", .{});
                }
            },
            Proto.Packets.ConnectedPing => {
                const ping = Proto.ConnectedPing.deserialize(payload, allocator) catch |err| {
                    Logger.ERROR("Failed to deserialize ConnectedPing: {any}", .{err});
                    return;
                };
                const current_time = std.time.milliTimestamp();
                var pong = Proto.ConnectedPong.init(ping.timestamp, current_time);
                defer pong.deinit(allocator);

                const serialized = pong.serialize(allocator) catch |err| {
                    Logger.ERROR("Failed to serialize ConnectedPong: {any}", .{err});
                    return;
                };
                defer allocator.free(serialized);

                const frame = frameIn(serialized, allocator);
                self.sendFrame(frame, .Immediate);
                Logger.DEBUG("Responded to ConnectedPing with ConnectedPong", .{});
            },
            Proto.Packets.ConnectedPong => {
                const pong = Proto.ConnectedPong.deserialize(payload, allocator) catch |err| {
                    Logger.ERROR("Failed to deserialize ConnectedPong: {any}", .{err});
                    return;
                };
                const current_time = std.time.milliTimestamp();
                const rtt = current_time - pong.timestamp; // Round trip time
                Logger.DEBUG("Received ConnectedPong - RTT: {d}ms", .{rtt});
                // Here you could store RTT statistics if needed
            },
            else => {
                Logger.WARN("Unhandeled Packet {d}", .{ID});
            },
        }
        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handlePacket took {d} ms", .{elapsed});
        }
    }

    pub fn tick(self: *Connection) void {
        if (!self.active) return;
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        if (self.last_receive + 15000 < std.time.milliTimestamp()) {
            Logger.WARN("Connection {any} has not received any packets in 15000ms", .{self.address});
            self.active = false;
            // Trigger server disconnect callback for timeout
            if (self.server.disconnect_callback) |callback| {
                callback(self, self.server.disconnect_context);
            }
            return;
        }

        const allocator = self.server.options.allocator;
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
            if (sequences_list.items.len == 0) return; // Should not really happen.
            var ack = Proto.Ack.init(sequences_list.items, allocator) catch return;
            defer ack.deinit();

            // Logger.DEBUG("> Sending acks with size {d}", .{sequences_list.items.len});

            const serialized = try ack.serialize(allocator);
            defer allocator.free(serialized);
            self.send(serialized);
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
            // Logger.DEBUG("> Sending nacks with size {d}", .{sequences_list.items.len});
            const serialized = try nack.serialize(allocator);
            defer allocator.free(serialized);
            var mutable_serialized = allocator.dupe(u8, serialized) catch |err| {
                Logger.ERROR("Failed to allocate memory for nack packet: {any}", .{err});
                return;
            };
            defer allocator.free(mutable_serialized);
            mutable_serialized[0] = Proto.Packets.Nack;
            self.send(mutable_serialized);
        }

        if (self.tickCounter / 50 == 0) {}

        // Send ping every ping_interval milliseconds if connected
        if (self.connected) {
            const current_time = std.time.milliTimestamp();
            if (current_time - self.last_ping_time >= self.ping_interval) {
                self.sendPing();
                self.last_ping_time = current_time;
            }
        }

        self.tickCounter += 1;

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: tick took {d} ms", .{elapsed});
        }
    }

    pub fn handleAck(self: *Self, payload: []const u8) !void {
        if (!self.active) return;
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        var ack = try Proto.Ack.deserialize(payload, self.server.options.allocator);
        defer ack.deinit();

        for (ack.sequences) |seq| {
            if (self.comm_data.output_backup.contains(@as(u24, @intCast(seq)))) {
                if (self.comm_data.output_backup.get(@as(u24, @intCast(seq)))) |iframes| {
                    for (iframes) |*frame| {
                        defer frame.deinit(self.server.options.allocator);
                    }
                    self.server.options.allocator.free(iframes);
                    _ = self.comm_data.output_backup.remove(@as(u24, @intCast(seq)));
                }
            }
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handleAck took {d} ms", .{elapsed});
        }
    }

    pub fn handleNack(self: *Self, payload: []const u8) !void {
        if (!self.active) return;
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        // Ack and Nack are same just different ids we do not check ids when deserializing so we can do this! :D
        var nack = try Proto.Ack.deserialize(payload, self.server.options.allocator);
        defer nack.deinit();
        for (nack.sequences) |seq| {
            const frames = self.comm_data.output_backup.get(@as(u24, @intCast(seq)));
            if (frames) |f| {
                var frameset = Proto.FrameSet{
                    .frames = f,
                    .sequence_number = @as(u24, @intCast(seq)),
                };
                const serialized = try frameset.serialize(self.server.options.allocator);
                defer self.server.options.allocator.free(serialized);
                self.send(serialized);
            }
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handleNack took {d} ms", .{elapsed});
        }
    }

    pub fn onFrameSet(self: *Self, buffer: []const u8) !void {
        if (!self.active) return;

        self.last_receive = std.time.milliTimestamp();
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        const frameSet = try Proto.FrameSet.deserialize(buffer, self.server.options.allocator);
        const sequence = frameSet.sequence_number;
        // Logger.DEBUG("Frameset {d}", .{frameSet.sequence_number});

        const is_duplicate = (self.comm_data.last_input_sequence != -1 and sequence <= @as(u24, @intCast(@max(0, self.comm_data.last_input_sequence)))) or self.comm_data.received_sequences.contains(sequence);
        // Logger.DEBUG("Frameset Duplicate? {}", .{is_duplicate});
        if (is_duplicate) {
            defer frameSet.deinit(self.server.options.allocator);
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
                self.comm_data.lost_sequences.put(i, {}) catch {};
            }
        }
        self.comm_data.last_input_sequence = @as(i32, @intCast(sequence));
        for (frameSet.frames) |frame| {
            try self.handleFrame(frame);
        }

        defer frameSet.deinit(self.server.options.allocator);
        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: onFrameSet took {d} ms", .{elapsed});
        }
    }

    pub fn handleFrame(self: *Connection, frame: Frame) !void {
        if (!self.active) return;
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        if (frame.payload.len == 0) {
            Logger.WARN("Frame has empty payload - skipping in handleFrame", .{});
            frame.deinit(self.server.options.allocator);
            return;
        }

        if (frame.isSplit()) {
            try self.handleSplitFrame(frame);
        } else if (frame.isSequenced()) {
            self.handleSequencedFrame(frame);
        } else if (frame.isOrdered()) {
            self.handleOrderedFrame(frame);
        } else {
            self.handlePacket(frame.payload) catch {
                Logger.ERROR("Failed to handle packet", .{});
                return;
            };
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handleFrame took {d} ms", .{elapsed});
        }
    }

    pub fn handleOrderedFrame(self: *Connection, frame: Frame) void {
        if (!self.active) return;
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        Logger.DEBUG("Ordered Frame!", .{});
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
            self.handlePacket(frame.payload) catch {
                Logger.ERROR("Failed to handle packet", .{});
                return;
            };
            var index = self.comm_data.input_order_index[channel];
            var outOfOrderQueue = self.comm_data.input_ordering_queue.getPtr(channel);
            if (outOfOrderQueue == null) {
                Logger.ERROR("OutOfOrderQueue is null", .{});
                return;
            }
            while (outOfOrderQueue.?.contains(index)) : (index += 1) {
                const iframe = outOfOrderQueue.?.get(index);
                if (iframe == null) break;
                if (iframe) |iiframe| { // compiler is a cry baby
                    self.handlePacket(iiframe.payload) catch |err| {
                        Logger.ERROR("Failed to handle packet: {any}", .{err});
                        return;
                    };
                }
                _ = outOfOrderQueue.?.remove(index);
            }
            self.comm_data.input_order_index[channel] = index;
        } else if (frame_index > self.comm_data.input_order_index[channel]) {
            const unordered = self.comm_data.input_ordering_queue.getPtr(channel);
            if (unordered) |map| {
                map.put(frame_index, frame) catch |err| {
                    Logger.ERROR("Failed to put frame in ordering queue: {any}", .{err});
                    return;
                };
            }
        } else {
            self.handlePacket(frame.payload) catch {
                Logger.ERROR("Failed to handle packet", .{});
                return;
            };
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handleOrderedFrame took {d} ms", .{elapsed});
        }
    }

    pub fn handleSequencedFrame(self: *Self, frame: Frame) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

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
            // Don't duplicate payload, just pass the original
            self.handlePacket(frame.payload) catch |err| {
                Logger.ERROR("Failed to handle packet: {any}", .{err});
                return;
            };
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: handleSequencedFrame took {d} ms", .{elapsed});
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

        const allocator = self.server.options.allocator;

        // Check if we already have the fragment id
        if (self.comm_data.fragments_queue.getPtr(split_id)) |fragment| {
            // Create a copy of the frame with duplicated payload to avoid use-after-free
            const payload_copy = allocator.dupe(u8, frame.payload) catch {
                Logger.ERROR("Failed to duplicate frame payload", .{});
                return;
            };
            const frame_copy = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload_copy, frame.split_frame_index, frame.split_id, frame.split_size, allocator);

            // Set the split frame to the fragment
            fragment.put(@as(u16, @intCast(split_index)), frame_copy) catch {
                Logger.ERROR("Failed to put frame in fragment queue", .{});
                allocator.free(payload_copy);
                return;
            };

            // Check if we have all the fragments
            if (fragment.count() == split_size) {
                var stream = Proto.BinaryStream.init(allocator, null, null);
                defer stream.deinit();

                // Loop through the fragments and write them to the stream
                var index: u32 = 0;
                while (index < split_size) : (index += 1) {
                    // Get the split frame from the fragment
                    const sframe = fragment.get(@as(u16, @intCast(index))) orelse {
                        Logger.ERROR("Missing fragment at index {d}", .{index});
                        return;
                    };
                    // Write the payload to the stream
                    try stream.write(sframe.payload);
                }

                // Get the reconstructed payload
                const reconstructed_payload = stream.getBufferOwned(allocator) catch {
                    Logger.ERROR("Failed to get reconstructed payload", .{});
                    return;
                };

                // Construct the new frame with values from the original frame
                const nframe = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, reconstructed_payload, null, // split_frame_index - not split anymore
                    null, // split_id - not split anymore
                    null, // split_size - not split anymore
                    allocator);

                // Clean up the fragments before removing from queue
                var frag_iter = fragment.iterator();
                while (frag_iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }
                fragment.deinit();

                // Delete the fragment id from the queue
                _ = self.comm_data.fragments_queue.remove(split_id);

                // Process the reconstructed frame directly instead of calling handleFrame recursively
                if (nframe.isSequenced()) {
                    self.handleSequencedFrame(nframe);
                } else if (nframe.isOrdered()) {
                    self.handleOrderedFrame(nframe);
                } else {
                    self.handlePacket(nframe.payload) catch {
                        Logger.ERROR("Failed to handle reconstructed packet", .{});
                    };
                }

                // Clean up the reconstructed frame
                nframe.deinit(allocator);
            }
        } else {
            // Add the fragment id to the queue
            var new_fragment = std.AutoHashMap(u16, Frame).init(allocator);

            // Create a copy of the frame with duplicated payload to avoid use-after-free
            const payload_copy = allocator.dupe(u8, frame.payload) catch {
                Logger.ERROR("Failed to duplicate frame payload", .{});
                return;
            };
            const frame_copy = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload_copy, frame.split_frame_index, frame.split_id, frame.split_size, allocator);

            new_fragment.put(@as(u16, @intCast(split_index)), frame_copy) catch {
                Logger.ERROR("Failed to create new fragment queue", .{});
                allocator.free(payload_copy);
                return;
            };
            self.comm_data.fragments_queue.put(split_id, new_fragment) catch {
                Logger.ERROR("Failed to add fragment to queue", .{});
                // Clean up the frame we just added
                var iter = new_fragment.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }
                new_fragment.deinit();
                return;
            };
        }
    }

    pub fn frameIn(msg: []const u8, allocator: std.mem.Allocator) Frame {
        const payload_copy = allocator.dupe(u8, msg) catch |err| {
            Logger.ERROR("Failed to duplicate payload: {any}", .{err});
            return Frame.init(null, null, null, 0, Reliability.ReliableOrdered, &[_]u8{}, null, null, null, allocator);
        };
        return Frame.init(null, null, null, 0, Reliability.ReliableOrdered, payload_copy, null, null, null, allocator);
    }

    pub fn sendFrame(self: *Connection, frame: Frame, priority: Priority) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        const channel_index = frame.order_channel orelse 0;
        const channel = @as(usize, channel_index);
        var mutable_frame = frame;

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
        const max_size = self.mtu_size - 36;
        if (payload_size <= max_size) {
            if (mutable_frame.isReliable()) {
                mutable_frame.reliable_frame_index = self.comm_data.output_reliable_index;
                self.comm_data.output_reliable_index += 1;
            }
            self.queueFrame(mutable_frame, priority);

            if (PERFORM_TIME_CHECKS) {
                const end_time = std.time.milliTimestamp();
                const elapsed = end_time - start_time;
                Logger.DEBUG("PERF: sendFrame took {d} ms", .{elapsed});
            }

            return;
        } else {
            if (PERFORM_TIME_CHECKS) {
                const end_time = std.time.milliTimestamp();
                const elapsed = end_time - start_time;
                Logger.DEBUG("PERF: sendFrame (large payload path) took {d} ms", .{elapsed});
            }

            const split_size = (payload_size + max_size - 1) / max_size;
            self.handleLargePayload(&mutable_frame, max_size, split_size, priority);
        }
    }

    pub fn handleLargePayload(self: *Connection, frame: *Frame, max_size: usize, split_size: usize, priority: Priority) void {
        const allocator = self.server.options.allocator;
        const split_id = self.comm_data.output_split_index;
        self.comm_data.output_split_index = (self.comm_data.output_split_index +% 1);

        var index: usize = 0;
        while (index < frame.payload.len) {
            const end_index = @min(index + max_size, frame.payload.len);
            const fragment_payload = frame.payload[index..end_index];

            // Create a copy of the fragment payload
            const payload_copy = allocator.dupe(u8, fragment_payload) catch {
                Logger.ERROR("Failed to duplicate fragment payload", .{});
                return;
            };

            var new_frame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload_copy, @as(u32, @intCast(index / max_size)), // split_frame_index
                split_id, // split_id
                @as(u32, @intCast(split_size)), // split_size
                allocator);

            // Set reliable index for fragments after the first one
            if (index != 0 and new_frame.isReliable()) {
                new_frame.reliable_frame_index = self.comm_data.output_reliable_index;
                self.comm_data.output_reliable_index += 1;
            } else if (index == 0 and new_frame.isReliable()) {
                new_frame.reliable_frame_index = self.comm_data.output_reliable_index;
                self.comm_data.output_reliable_index += 1;
            }

            self.queueFrame(new_frame, priority);
            index += max_size;
        }
    }

    pub fn queueFrame(self: *Connection, frame: Frame, priority: Priority) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        self.comm_data.output_frame_queue.append(self.server.options.allocator, frame) catch {
            Logger.ERROR("Failed to queue frame", .{});
            defer frame.deinit(self.server.options.allocator);
            return;
        };
        const should_send_immediately = priority == Priority.Immediate;
        const queue_len = self.comm_data.output_frame_queue.items.len;
        if (should_send_immediately) {
            self.sendQueue(queue_len);
        }

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: queueFrame took {d} ms", .{elapsed});
        }
    }

    pub fn sendQueue(self: *Connection, amount: usize) void {
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;

        if (self.comm_data.output_frame_queue.items.len == 0) return;
        const allocator = self.server.options.allocator;
        const count = @min(amount, self.comm_data.output_frame_queue.items.len);
        const frames = self.comm_data.output_frame_queue.items[0..count];

        const backup = allocator.alloc(Frame, count) catch |err| {
            Logger.ERROR("Backup alloc failed: {any}", .{err});
            self.cleanupOutputQueueFrames(count);
            return;
        };

        for (frames, 0..) |frame, i| {
            const payload = if (frame.payload.len > 0)
                allocator.dupe(u8, frame.payload) catch {
                    for (0..i) |j| {
                        backup[j].deinit(allocator);
                    }
                    allocator.free(backup);
                    self.cleanupOutputQueueFrames(count);
                    Logger.ERROR("Payload dupe failed at frame {any}", .{i});
                    return;
                }
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
                    defer frame.deinit(allocator);
                }
                allocator.free(iframes);
                _ = self.comm_data.output_backup.remove(sequence);
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
        self.send(serialized);
        defer allocator.free(serialized);

        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: sendQueue took {d} ms", .{elapsed});
        }
    }

    fn cleanupOutputQueueFrames(self: *Connection, amount: usize) void {
        const queue = &self.comm_data.output_frame_queue;
        const to_remove = @min(amount, queue.items.len);
        if (to_remove == 0) return;
        for (queue.items[0..to_remove]) |*frame| {
            frame.deinit(self.server.options.allocator);
        }
        queue.replaceRange(self.server.options.allocator, 0, to_remove, &[_]Frame{}) catch |err| {
            Logger.ERROR("Failed to cleanup output queue frames: {any}", .{err});
            return;
        };
    }

    pub fn send(self: *Connection, data: []const u8) void {
        // Logger.INFO("Sending data to {any}", .{self.address});
        const start_time = if (PERFORM_TIME_CHECKS) std.time.milliTimestamp() else 0;
        self.server.send(data, self.address);
        if (PERFORM_TIME_CHECKS) {
            const end_time = std.time.milliTimestamp();
            const elapsed = end_time - start_time;
            Logger.DEBUG("PERF: send took {d} ms", .{elapsed});
        }
    }

    /// Set game packet callback (for packet ID 254)
    pub fn setGamePacketCallback(self: *Connection, callback: ?GamePacketCallback, context: ?*anyopaque) void {
        self.game_packet_callback = callback;
        self.game_packet_context = context;
    }

    pub fn getAddress(self: *const Connection) std.net.Address {
        return self.address;
    }

    pub fn isConnected(self: *const Connection) bool {
        return self.connected;
    }

    pub fn isActive(self: *const Connection) bool {
        return self.active;
    }

    /// Send a ConnectedPing packet to the client
    pub fn sendPing(self: *Connection) void {
        const allocator = self.server.options.allocator;
        const timestamp = std.time.milliTimestamp();

        var ping = Proto.ConnectedPing.init(timestamp);
        defer ping.deinit(allocator);

        const serialized = ping.serialize(allocator) catch |err| {
            Logger.ERROR("Failed to serialize ConnectedPing: {any}", .{err});
            return;
        };
        defer allocator.free(serialized);

        const frame = frameIn(serialized, allocator);
        self.sendFrame(frame, .Normal);

        Logger.DEBUG("Sent ConnectedPing with timestamp: {d}", .{timestamp});
    }
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
