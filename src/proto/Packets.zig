pub const Packets = struct {
    pub const FrameSet = 0x80;
    pub const Nack = 0xa0;
    pub const Ack = 0xc0;
    pub const ConnectedPing = 0x00;
    pub const UnconnectedPing = 0x01;
    pub const ConnectedPong = 0x03;
    pub const OpenConnectionRequest1 = 0x05;
    pub const OpenConnectionReply1 = 0x06;
    pub const OpenConnectionRequest2 = 0x07;
    pub const OpenConnectionReply2 = 0x08;
    pub const ConnectionRequest = 0x09;
    pub const ConnectionRequestAccepted = 0x10;
    pub const NewIncomingConnection = 0x13;
    pub const UnconnectedPong = 0x1c;
    pub const DisconnectNotification = 0x15;
};
