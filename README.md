# ZigNet

A high-performance RakNet implementation written in Zig, providing reliable UDP networking with automatic packet ordering, fragmentation, and connection management.

## Features

- 🚀 **High Performance**: Built with Zig for maximum performance and minimal overhead
- 🔗 **RakNet Protocol**: Full implementation of the RakNet networking protocol
- 🌐 **Cross-Platform**: Supports Windows, Linux, and macOS (x86_64 and ARM64)
- 🔄 **Reliable UDP**: Automatic packet acknowledgment, ordering, and retransmission
- 📦 **Packet Fragmentation**: Handles large packets automatically
- 🔌 **Easy Integration**: Simple callback-based API

## Quick Start

### Installation

Add ZigNet to your `build.zig.zon`:

```zig
.dependencies = .{
    .ZigNet = .{
        .url = "https://github.com/your-repo/ZigNet/archive/main.tar.gz",
        .hash = "...", // Add the hash here
    },
}
```

### Basic Server Example

```zig
const std = @import("std");
const ZigNet = @import("ZigNet");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create and configure server
    var server = try ZigNet.Server.init(.{
        .allocator = allocator,
    });
    defer server.deinit();

    // Set up callbacks
    server.setConnectCallback(onConnect, null);
    server.setDisconnectCallback(onDisconnect, null);

    // Start the server
    try server.start();
    
    ZigNet.Logger.INFO("Server started! Listening for connections...", .{});
    
    // Keep server running
    std.time.sleep(std.time.ns_per_s * 30);
}

fn onConnect(connection: *ZigNet.Connection, context: ?*anyopaque) void {
    _ = context;
    ZigNet.Logger.INFO("Client connected!", .{});
    
    // Set up packet handler for this connection
    connection.setGamePacketCallback(onGamePacket, null);
}

fn onDisconnect(connection: *ZigNet.Connection, context: ?*anyopaque) void {
    _ = context;
    ZigNet.Logger.INFO("Client disconnected!", .{});
}

fn onGamePacket(connection: *ZigNet.Connection, payload: []const u8, context: ?*anyopaque) void {
    _ = connection;
    _ = context;
    ZigNet.Logger.INFO("Received packet: {any}", .{payload});
    
    // Echo the packet back to the client
    // connection.send(payload);
}
```

## API Reference

### Server

The main server class that handles incoming connections and manages the networking.

```zig
const server = try ZigNet.Server.init(.{
    .allocator = allocator,
    // Add more options as needed
});
```

#### Methods

- `init(options: ServerOptions) !Server` - Create a new server instance
- `start() !void` - Start listening for connections
- `deinit() void` - Clean up server resources
- `setConnectCallback(callback: fn(*Connection, ?*anyopaque) void, context: ?*anyopaque) void` - Set connection callback
- `setDisconnectCallback(callback: fn(*Connection, ?*anyopaque) void, context: ?*anyopaque) void` - Set disconnection callback

### Connection

Represents a client connection to the server.

#### Methods

- `setGamePacketCallback(callback: fn(*Connection, []const u8, ?*anyopaque) void, context: ?*anyopaque) void` - Set packet handler
- `send(data: []const u8) !void` - Send data to the client

### Logger

Built-in logging system with different log levels.

```zig
ZigNet.Logger.INFO("Information message", .{});
ZigNet.Logger.ERROR("Error message", .{});
ZigNet.Logger.DEBUG("Debug message", .{});
```

## Building

### Build for Current Platform

```bash
zig build
```

### Run Tests

```bash
zig build test
```

## Protocol Support

ZigNet implements the complete RakNet protocol including:

- **Offline Protocol**: Connection discovery and handshake
  - UnconnectedPing/Pong
  - ConnectionRequest1/2
  - ConnectionReply1/2

- **Online Protocol**: Reliable data transmission
  - Frame-based packet system
  - Acknowledgments (ACK/NACK)
  - Automatic retransmission
  - Packet ordering and sequencing

## Requirements

- Zig 0.15.0-dev or later
- Supported platforms: Windows, Linux, macOS

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Based on the RakNet networking library protocol.