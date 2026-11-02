//! The kernel's ALSA sequencer on `/dev/snd/seq`, spoken to directly through
//! its ioctls (ADR 0002): listing clients, Ports and subscriptions, and making
//! and undoing Links, as `aconnect` does through libasound; and hearing from
//! the System Announce port when any of them change (ADR 0004). The
//! structures below are the kernel's, from `<sound/asequencer.h>`; their
//! layouts are checked at compile time. What the listing means for the graph
//! is up to `alsa.zig`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Addr = @import("graph.zig").Addr;

/// A Port's capability bits (`SNDRV_SEQ_PORT_CAP_*`).
pub const Caps = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    sync_read: bool = false,
    sync_write: bool = false,
    duplex: bool = false,
    /// Others may subscribe to what it sends.
    subs_read: bool = false,
    /// Others may subscribe it to what they send.
    subs_write: bool = false,
    /// Only its own client may route it.
    no_export: bool = false,
    inactive: bool = false,
    ump_endpoint: bool = false,
    _: u22 = 0,
};

/// A Port's usage direction (`SNDRV_SEQ_PORT_DIR_*`): which way it carries
/// MIDI, a hint newer clients give. `aconnect` lists a Port as readable or
/// writable only if this allows it.
pub const PortDirection = enum(u8) {
    unknown = 0,
    input = 1,
    output = 2,
    bidirection = 3,
    _,

    pub fn allows(d: PortDirection, bit: PortDirection) bool {
        return d == .unknown or @backingInt(d) & @backingInt(bit) != 0;
    }
};

pub const Client = struct {
    id: u8,
    name: []const u8,
};

pub const Port = struct {
    addr: Addr,
    name: []const u8,
    caps: Caps,
    direction: PortDirection = .unknown,
};

/// A Link: `from` sends to `to`.
pub const Subscription = struct {
    from: Addr,
    to: Addr,
};

/// Every client and active Port, and every subscription from a readable Port,
/// in the order the kernel enumerates them (the order `aconnect` prints).
/// The listing client itself is never in it.
pub const Listing = struct {
    clients: []const Client = &.{},
    ports: []const Port = &.{},
    subscriptions: []const Subscription = &.{},

    pub const none: Listing = .{};

    pub fn clientName(l: Listing, id: u16) ?[]const u8 {
        for (l.clients) |c| if (c.id == id) return c.name;
        return null;
    }
};

/// An open sequencer client.
pub const Seq = struct {
    fd: linux.fd_t,
    /// Its client id.
    client: u8,

    /// Opens the sequencer non-blocking for reading and writing, as a client
    /// called `name`. Unavailable if there is no `/dev/snd/seq` or no
    /// permission to open it.
    pub fn open(name: []const u8) error{Unavailable}!Seq {
        const rc = linux.open("/dev/snd/seq", .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);

        // As libasound does; kernels older than 4.19 don't know it, which is fine.
        var pversion: i32 = protocol_version;
        _ = control(fd, ioc.user_pversion, &pversion);
        var id: i32 = undefined;
        if (control(fd, ioc.client_id, &id) != .SUCCESS) return error.Unavailable;
        var info: ClientInfo = std.mem.zeroes(ClientInfo);
        info.client = id;
        if (control(fd, ioc.get_client_info, &info) != .SUCCESS) return error.Unavailable;
        info.name = @splat(0);
        const n = @min(name.len, info.name.len - 1);
        @memcpy(info.name[0..n], name[0..n]);
        if (control(fd, ioc.set_client_info, &info) != .SUCCESS) return error.Unavailable;
        return .{ .fd = fd, .client = @intCast(id) };
    }

    /// Closing the client also removes its Ports and their Links.
    pub fn close(s: Seq) void {
        _ = linux.close(s.fd);
    }

    /// Everything allocated in `arena`.
    pub fn list(s: Seq, arena: Allocator) Allocator.Error!Listing {
        var clients: std.ArrayList(Client) = .empty;
        var ports: std.ArrayList(Port) = .empty;
        var subscriptions: std.ArrayList(Subscription) = .empty;

        var ci: ClientInfo = std.mem.zeroes(ClientInfo);
        ci.client = -1;
        while (control(s.fd, ioc.query_next_client, &ci) == .SUCCESS) {
            const id = std.math.cast(u8, ci.client) orelse break;
            if (id == s.client) continue;
            try clients.append(arena, .{ .id = id, .name = try arena.dupe(u8, std.mem.sliceTo(&ci.name, 0)) });

            var pi: PortInfo = std.mem.zeroes(PortInfo);
            // The kernel starts at the port after this one: 255 wraps to 0.
            pi.addr = .{ .client = id, .port = 255 };
            while (true) {
                // Without `inactive` asked for, the kernel skips inactive
                // Ports, as `aconnect` does without `-a`.
                pi.capability = .{};
                if (control(s.fd, ioc.query_next_port, &pi) != .SUCCESS) break;
                const addr: Addr = .{ .client = pi.addr.client, .port = pi.addr.port };
                try ports.append(arena, .{
                    .addr = addr,
                    .name = try arena.dupe(u8, std.mem.sliceTo(&pi.name, 0)),
                    .caps = pi.capability,
                    .direction = pi.direction,
                });
                if (pi.capability.read) {
                    var q: QuerySubs = std.mem.zeroes(QuerySubs);
                    q.root = pi.addr;
                    q.type = query_subs_read;
                    while (control(s.fd, ioc.query_subs, &q) == .SUCCESS) : (q.index += 1) {
                        try subscriptions.append(arena, .{ .from = addr, .to = .{ .client = q.addr.client, .port = q.addr.port } });
                    }
                }
                // Nothing comes after the last possible port; asking again would wrap.
                if (pi.addr.port == 255) break;
            }
        }
        return .{ .clients = clients.items, .ports = ports.items, .subscriptions = subscriptions.items };
    }

    /// Makes a Link as `aconnect` does: not exclusive, no queue, no time
    /// update. One that already exists counts as made. Null if made,
    /// otherwise what `aconnect` would have said, allocated in `arena`.
    pub fn connect(s: Seq, arena: Allocator, from: Addr, to: Addr) Allocator.Error!?[]const u8 {
        const e = s.subscribe(from, to);
        if (e == .SUCCESS) return null;
        return try std.fmt.allocPrint(arena, "Connection failed ({f})", .{Strerror{ .e = e }});
    }

    /// Undoes a Link; whether there was one to undo.
    pub fn disconnect(s: Seq, from: Addr, to: Addr) bool {
        var sub = subscription(from, to) orelse return false;
        return control(s.fd, ioc.unsubscribe_port, &sub) == .SUCCESS;
    }

    fn subscribe(s: Seq, from: Addr, to: Addr) linux.E {
        var sub = subscription(from, to) orelse return .INVAL;
        const e = control(s.fd, ioc.subscribe_port, &sub);
        // Busy is also what an exclusive or unopenable Port says, so only an
        // existing Link counts as made.
        if (e == .BUSY and control(s.fd, ioc.get_subscription, &sub) == .SUCCESS) return .SUCCESS;
        return e;
    }

    /// Has the System Announce port tell this client whenever a client or
    /// Port comes, goes or changes, or a Link is made or undone; `fd` is
    /// then readable, and `changed` says whether any of it matters. Through
    /// a Port of its own that only receives: no one can subscribe to it, and
    /// being no-export, the Midi-Bridge doesn't mirror it, so it is never a
    /// Device.
    pub fn listen(s: Seq) error{Unavailable}!void {
        const port = s.createPort("announce", .{ .write = true, .no_export = true }) catch return error.Unavailable;
        var sub: PortSubscribe = std.mem.zeroes(PortSubscribe);
        sub.sender = .{ .client = system_client, .port = system_announce };
        sub.dest = .{ .client = s.client, .port = @intCast(port.port) };
        if (control(s.fd, ioc.subscribe_port, &sub) != .SUCCESS) return error.Unavailable;
    }

    /// Reads every event waiting, and says whether any of them changes the
    /// graph: whether it has to be listed again. Events lost to a full
    /// queue count as a change.
    pub fn changed(s: Seq) bool {
        return s.changedAbout(null);
    }

    /// As `changed`, but if `about` is given, only changes about that
    /// client count: for tests, which share the sequencer with whatever
    /// else runs.
    fn changedAbout(s: Seq, about: ?u8) bool {
        // Room for any event the kernel would hand over: it keeps one that
        // doesn't fit for the next read, which would then never come.
        var buf: [64 * 1024]u8 = undefined;
        var any = false;
        while (true) {
            const rc = linux.read(s.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return any;
                    if (changes(buf[0..rc], s.client, about)) any = true;
                },
                // Its queue overflowed and was emptied.
                .NOSPC => any = true,
                else => return any,
            }
        }
    }

    /// Creates a Port on this client: the one `listen` receives on, or in
    /// tests, one standing in for a Device.
    pub fn createPort(s: Seq, name: []const u8, caps: Caps) error{CreatePortFailed}!Addr {
        var pi: PortInfo = std.mem.zeroes(PortInfo);
        pi.addr.client = s.client;
        @memcpy(pi.name[0..name.len], name);
        pi.capability = caps;
        pi.type = port_type_midi_generic | port_type_application;
        if (control(s.fd, ioc.create_port, &pi) != .SUCCESS) return error.CreatePortFailed;
        return .{ .client = pi.addr.client, .port = pi.addr.port };
    }

    /// Deletes a Port of this client. Only for tests, standing in for a
    /// Device unplugged.
    pub fn deletePort(s: Seq, addr: Addr) !void {
        var pi: PortInfo = std.mem.zeroes(PortInfo);
        pi.addr = .{ .client = s.client, .port = @intCast(addr.port) };
        if (control(s.fd, ioc.delete_port, &pi) != .SUCCESS) return error.DeletePortFailed;
    }
};

/// The events one read gave, in order. Each is a `snd_seq_event`; a
/// variable-length one is followed by its data, padded to a whole number of
/// events. One cut short ends them.
const Events = struct {
    rest: []const u8,

    fn next(e: *Events) ?Event {
        if (e.rest.len < @sizeOf(Event)) return null;
        const ev = std.mem.bytesToValue(Event, e.rest[0..@sizeOf(Event)]);
        e.rest = e.rest[@sizeOf(Event)..];
        if (ev.flags & event_length_mask == event_length_variable) {
            const len: usize = ev.data.ext_len & ~ext_mask;
            const padded = (len + @sizeOf(Event) - 1) / @sizeOf(Event) * @sizeOf(Event);
            if (padded > e.rest.len) {
                e.rest = "";
                return null;
            }
            e.rest = e.rest[padded..];
        }
        return ev;
    }
};

/// Whether any of the events read into `bytes` changes the graph as
/// `client` lists it: a client or Port starting, exiting or changing, or a
/// Link made or undone. Those about `client` itself don't, since it is
/// never in its own listing. If `about` is given, only those about that
/// client count.
fn changes(bytes: []const u8, client: u8, about: ?u8) bool {
    var events: Events = .{ .rest = bytes };
    var any = false;
    while (events.next()) |ev| {
        const who = subjects(ev) orelse continue;
        if (who[0] == client or who[1] == client) continue;
        if (about) |a| if (who[0] != a and who[1] != a) continue;
        any = true;
    }
    return any;
}

/// The clients an announce event is about: a client's or Port's, twice,
/// or a Link's two ends. Null for any other event.
fn subjects(ev: Event) ?[2]u8 {
    return switch (ev.type) {
        event_client_start, event_client_exit, event_client_change, event_port_start, event_port_exit, event_port_change => @splat(ev.data.addr.client),
        event_port_subscribed, event_port_unsubscribed => .{ ev.data.connect.sender.client, ev.data.connect.dest.client },
        else => null,
    };
}

fn subscription(from: Addr, to: Addr) ?PortSubscribe {
    var sub: PortSubscribe = std.mem.zeroes(PortSubscribe);
    sub.sender = .{ .client = std.math.cast(u8, from.client) orelse return null, .port = std.math.cast(u8, from.port) orelse return null };
    sub.dest = .{ .client = std.math.cast(u8, to.client) orelse return null, .port = std.math.cast(u8, to.port) orelse return null };
    return sub;
}

fn control(fd: linux.fd_t, request: u32, arg: anytype) linux.E {
    return linux.errno(linux.ioctl(fd, request, @intFromPtr(arg)));
}

/// An errno as glibc's `strerror` says it, which is what `aconnect` printed.
const Strerror = struct {
    e: linux.E,

    pub fn format(s: Strerror, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (s.e) {
            .PERM => "Operation not permitted",
            .NOENT => "No such file or directory",
            .SRCH => "No such process",
            .INTR => "Interrupted system call",
            .IO => "Input/output error",
            .NXIO => "No such device or address",
            .AGAIN => "Resource temporarily unavailable",
            .NOMEM => "Cannot allocate memory",
            .ACCES => "Permission denied",
            .FAULT => "Bad address",
            .BUSY => "Device or resource busy",
            .EXIST => "File exists",
            .NODEV => "No such device",
            .INVAL => "Invalid argument",
            .NOSPC => "No space left on device",
            .NOTTY => "Inappropriate ioctl for device",
            .NOSYS => "Function not implemented",
            else => return w.print("Unknown error {d}", .{@backingInt(s.e)}),
        });
    }
};

// The kernel's structures and constants, from `<sound/asequencer.h>`.

/// `SNDRV_SEQ_VERSION`: 1.0.5.
const protocol_version: i32 = 0x10005;
const query_subs_read: i32 = 0;
const port_type_midi_generic: u32 = 1 << 1;
const port_type_application: u32 = 1 << 20;
const system_client: u8 = 0;
const system_announce: u8 = 1;

const event_client_start: u8 = 60;
const event_client_exit: u8 = 61;
const event_client_change: u8 = 62;
const event_port_start: u8 = 63;
const event_port_exit: u8 = 64;
const event_port_change: u8 = 65;
const event_port_subscribed: u8 = 66;
const event_port_unsubscribed: u8 = 67;
const event_sysex: u8 = 130;
const event_length_variable: u8 = 1 << 2;
const event_length_mask: u8 = 3 << 2;
/// The flag bits of a variable-length event's `len`.
const ext_mask: u32 = 0xc0000000;

const KAddr = extern struct {
    client: u8,
    port: u8,
};

const ClientInfo = extern struct {
    client: i32,
    type: i32,
    name: [64]u8,
    filter: u32,
    multicast_filter: [8]u8,
    event_filter: [32]u8,
    num_ports: i32,
    event_lost: i32,
    card: i32,
    pid: i32,
    midi_version: u32,
    group_filter: u32,
    reserved: [48]u8,
};

const PortInfo = extern struct {
    addr: KAddr,
    name: [64]u8,
    capability: Caps,
    type: u32,
    midi_channels: i32,
    midi_voices: i32,
    synth_voices: i32,
    read_use: i32,
    write_use: i32,
    kernel: ?*anyopaque,
    flags: u32,
    time_queue: u8,
    direction: PortDirection,
    ump_group: u8,
    reserved: [57]u8,
};

const QuerySubs = extern struct {
    root: KAddr,
    type: i32,
    index: i32,
    num_subs: i32,
    addr: KAddr,
    queue: u8,
    flags: u32,
    reserved: [64]u8,
};

const PortSubscribe = extern struct {
    sender: KAddr,
    dest: KAddr,
    voices: u32,
    flags: u32,
    queue: u8,
    pad: [3]u8,
    reserved: [64]u8,
};

const Connect = extern struct {
    sender: KAddr,
    dest: KAddr,
};

/// `snd_seq_event`, as a legacy MIDI 1.0 client reads it.
const Event = extern struct {
    type: u8,
    flags: u8,
    tag: u8,
    queue: u8,
    time: [2]u32,
    source: KAddr,
    dest: KAddr,
    data: extern union {
        /// The client or Port a client or Port event is about.
        addr: KAddr,
        /// The Link a subscription event is about.
        connect: Connect,
        /// A variable-length event's data length, with flags in its top bits.
        ext_len: u32,
        raw: [3]u32,
    },
};

const ioc = struct {
    const IOR = linux.IOCTL.IOR;
    const IOW = linux.IOCTL.IOW;
    const IOWR = linux.IOCTL.IOWR;

    const client_id = IOR('S', 0x01, i32);
    const user_pversion = IOW('S', 0x04, i32);
    const get_client_info = IOWR('S', 0x10, ClientInfo);
    const set_client_info = IOW('S', 0x11, ClientInfo);
    const create_port = IOWR('S', 0x20, PortInfo);
    const delete_port = IOW('S', 0x21, PortInfo);
    const subscribe_port = IOW('S', 0x30, PortSubscribe);
    const unsubscribe_port = IOW('S', 0x31, PortSubscribe);
    const query_subs = IOWR('S', 0x4f, QuerySubs);
    const get_subscription = IOWR('S', 0x50, PortSubscribe);
    const query_next_client = IOWR('S', 0x51, ClientInfo);
    const query_next_port = IOWR('S', 0x52, PortInfo);
};

// Sizes, offsets and ioctl numbers as the kernel header gives them, built
// with `zig cc` for x86_64 and aarch64 (64-bit) and for x86 and arm
// (32-bit). Only `snd_seq_port_info` differs, by its pointer.
comptime {
    if (builtin.os.tag != .linux) @compileError("the ALSA sequencer is Linux only");
    const p64 = switch (@sizeOf(usize)) {
        8 => true,
        4 => false,
        else => @compileError("sequencer layouts are checked for 32- and 64-bit targets only"),
    };
    expectLayout(KAddr, 2, .{ .client = 0, .port = 1 });
    expectLayout(ClientInfo, 188, .{ .client = 0, .type = 4, .name = 8, .filter = 72, .num_ports = 116, .midi_version = 132, .reserved = 140 });
    if (p64) {
        expectLayout(PortInfo, 168, .{ .addr = 0, .name = 2, .capability = 68, .type = 72, .kernel = 96, .flags = 104, .direction = 109, .reserved = 111 });
    } else {
        expectLayout(PortInfo, 164, .{ .addr = 0, .name = 2, .capability = 68, .type = 72, .kernel = 96, .flags = 100, .direction = 105, .reserved = 107 });
    }
    expectLayout(QuerySubs, 88, .{ .root = 0, .type = 4, .index = 8, .num_subs = 12, .addr = 16, .queue = 18, .flags = 20, .reserved = 24 });
    expectLayout(PortSubscribe, 80, .{ .sender = 0, .dest = 2, .voices = 4, .flags = 8, .queue = 12, .reserved = 16 });
    expectLayout(Event, 28, .{ .type = 0, .flags = 1, .tag = 2, .queue = 3, .time = 4, .source = 12, .dest = 14, .data = 16 });

    expectRequest(ioc.client_id, 0x80045301);
    expectRequest(ioc.user_pversion, 0x40045304);
    expectRequest(ioc.get_client_info, 0xc0bc5310);
    expectRequest(ioc.set_client_info, 0x40bc5311);
    expectRequest(ioc.create_port, if (p64) 0xc0a85320 else 0xc0a45320);
    expectRequest(ioc.delete_port, if (p64) 0x40a85321 else 0x40a45321);
    expectRequest(ioc.subscribe_port, 0x40505330);
    expectRequest(ioc.unsubscribe_port, 0x40505331);
    expectRequest(ioc.query_subs, 0xc058534f);
    expectRequest(ioc.get_subscription, 0xc0505350);
    expectRequest(ioc.query_next_client, 0xc0bc5351);
    expectRequest(ioc.query_next_port, if (p64) 0xc0a85352 else 0xc0a45352);
}

fn expectLayout(comptime T: type, comptime size: usize, comptime offsets: anytype) void {
    if (@sizeOf(T) != size) @compileError(std.fmt.comptimePrint("{s} is {d} bytes, not {d}", .{ @typeName(T), @sizeOf(T), size }));
    for (std.meta.fieldNames(@TypeOf(offsets))) |field| {
        const want = @field(offsets, field);
        const got = @offsetOf(T, field);
        if (got != want) @compileError(std.fmt.comptimePrint("{s}.{s} is at {d}, not {d}", .{ @typeName(T), field, got, want }));
    }
}

fn expectRequest(comptime got: u32, comptime want: u32) void {
    if (got != want) @compileError(std.fmt.comptimePrint("ioctl 0x{x}, not 0x{x}", .{ got, want }));
}

const testing = std.testing;

test "strerror as glibc says it, or Unknown error" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Operation not permitted", try std.fmt.bufPrint(&buf, "{f}", .{Strerror{ .e = .PERM }}));
    try testing.expectEqualStrings("Unknown error 200", try std.fmt.bufPrint(&buf, "{f}", .{Strerror{ .e = @fromBackingInt(@intCast(200)) }}));
}

test "direction: unknown allows either way" {
    try testing.expect(PortDirection.unknown.allows(.input));
    try testing.expect(PortDirection.unknown.allows(.output));
    try testing.expect(PortDirection.bidirection.allows(.input));
    try testing.expect(PortDirection.input.allows(.input));
    try testing.expect(!PortDirection.input.allows(.output));
    try testing.expect(!PortDirection.output.allows(.input));
}

test "Addrs beyond what the kernel can address are invalid" {
    try testing.expectEqual(null, subscription(.{ .client = 256, .port = 0 }, .{ .client = 1, .port = 0 }));
    try testing.expectEqual(null, subscription(.{ .client = 1, .port = 0 }, .{ .client = 1, .port = 300 }));
    try testing.expect(subscription(.{ .client = 255, .port = 255 }, .{ .client = 0, .port = 0 }) != null);
}

/// The sequencer as aroute opens it, or a skip where there is none (CI).
fn openOrSkip(name: []const u8) !Seq {
    return Seq.open(name) catch return error.SkipZigTest;
}

const all_caps: Caps = .{ .read = true, .write = true, .subs_read = true, .subs_write = true };

// Against the real kernel: a test client stands in for a Device with two
// Ports, while another client, as aroute, lists and wires them.
test "kernel: the listing has the Device's Ports, and not the listing client" {
    const device = try openOrSkip("aroute test device");
    defer device.close();
    const a = try device.createPort("test port A", all_caps);
    const b = try device.createPort("test port B", .{ .write = true, .subs_write = true });
    const s = try openOrSkip("aroute");
    defer s.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const l = try s.list(arena_state.allocator());
    try testing.expectEqualStrings("aroute test device", l.clientName(device.client).?);
    try testing.expectEqual(null, l.clientName(s.client));
    for (l.ports) |p| try testing.expect(p.addr.client != s.client);

    var found: u8 = 0;
    for (l.ports) |p| {
        if (std.meta.eql(p.addr, a)) {
            try testing.expectEqualStrings("test port A", p.name);
            try testing.expectEqual(all_caps, p.caps);
            found += 1;
        } else if (std.meta.eql(p.addr, b)) {
            try testing.expectEqualStrings("test port B", p.name);
            try testing.expectEqual(Caps{ .write = true, .subs_write = true }, p.caps);
            found += 1;
        }
    }
    try testing.expectEqual(2, found);
    // System comes first, as in `aconnect`.
    try testing.expectEqual(0, l.clients[0].id);
}

test "kernel: connect, connect again, disconnect, disconnect again" {
    const device = try openOrSkip("aroute test device");
    defer device.close();
    const a = try device.createPort("test port A", all_caps);
    const b = try device.createPort("test port B", all_caps);
    const s = try openOrSkip("aroute");
    defer s.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const linked = struct {
        fn linked(seq: Seq, ar: Allocator, from: Addr, to: Addr) !bool {
            for ((try seq.list(ar)).subscriptions) |sub| {
                if (std.meta.eql(sub, Subscription{ .from = from, .to = to })) return true;
            }
            return false;
        }
    }.linked;

    try testing.expect(!try linked(s, arena, a, b));
    try testing.expectEqual(null, try s.connect(arena, a, b));
    try testing.expect(try linked(s, arena, a, b));
    try testing.expect(!try linked(s, arena, b, a));
    // Already made counts as made.
    try testing.expectEqual(null, try s.connect(arena, a, b));

    try testing.expect(s.disconnect(a, b));
    try testing.expect(!try linked(s, arena, a, b));
    try testing.expect(!s.disconnect(a, b));
}

test "kernel: a Link that can't be made says why, as aconnect did" {
    const device = try openOrSkip("aroute test device");
    defer device.close();
    const a = try device.createPort("test port A", all_caps);
    const read_only = try device.createPort("test port R", .{ .read = true, .subs_read = true });
    const s = try openOrSkip("aroute");
    defer s.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Connection failed (Operation not permitted)", (try s.connect(arena, a, read_only)).?);
    // No such Port.
    const gone: Addr = .{ .client = device.client, .port = 200 };
    try testing.expectEqualStrings("Connection failed (Invalid argument)", (try s.connect(arena, a, gone)).?);
    try testing.expectEqualStrings("Connection failed (Invalid argument)", (try s.connect(arena, a, .{ .client = 999, .port = 0 })).?);
    try testing.expect(!s.disconnect(a, .{ .client = 999, .port = 0 }));
    try testing.expectError(error.OutOfMemory, s.connect(testing.failing_allocator, a, read_only));
}

/// An event as the kernel hands it over, `data` its first bytes.
fn event(@"type": u8, data: []const u8) Event {
    var ev: Event = std.mem.zeroes(Event);
    ev.type = @"type";
    ev.source = .{ .client = system_client, .port = system_announce };
    @memcpy(std.mem.asBytes(&ev.data)[0..data.len], data);
    return ev;
}

/// A variable-length event of `len` bytes, its top flag bits as given.
fn variable(@"type": u8, len: u32) Event {
    var ev = event(@"type", &.{});
    ev.flags = event_length_variable;
    ev.data.ext_len = len;
    return ev;
}

/// `events` and the data after them, as one read would give them.
fn bytesOf(arena: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(arena, u8, parts);
}

test "changes: announce events change the graph; others don't" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const me: u8 = 129;

    // Client 130 Port 0, and a Link from 130:0 to 20:0.
    for ([_]Event{
        event(event_client_start, &.{ 130, 0 }),
        event(event_client_exit, &.{ 130, 0 }),
        event(event_client_change, &.{ 130, 0 }),
        event(event_port_start, &.{ 130, 0 }),
        event(event_port_exit, &.{ 130, 0 }),
        event(event_port_change, &.{ 130, 0 }),
        event(event_port_subscribed, &.{ 130, 0, 20, 0 }),
        event(event_port_unsubscribed, &.{ 130, 0, 20, 0 }),
    }) |ev| try testing.expect(changes(std.mem.asBytes(&ev), me, null));

    // A note-on, and aroute's own client, Port and Links.
    for ([_]Event{
        event(6, &.{ 0, 60, 100 }),
        event(event_client_change, &.{ me, 0 }),
        event(event_port_start, &.{ me, 0 }),
        event(event_port_subscribed, &.{ 0, 1, me, 0 }),
        event(event_port_unsubscribed, &.{ me, 0, 20, 0 }),
    }) |ev| try testing.expect(!changes(std.mem.asBytes(&ev), me, null));

    try testing.expect(!changes("", me, null));
    // A note-on, then a Port starting.
    const note = event(6, &.{ 0, 60, 100 });
    const start = event(event_port_start, &.{ 130, 0 });
    try testing.expect(changes(try bytesOf(arena, &.{ std.mem.asBytes(&note), std.mem.asBytes(&start) }), me, null));
    // Cut short: the second event isn't whole.
    try testing.expect(!changes(try bytesOf(arena, &.{ std.mem.asBytes(&note), std.mem.asBytes(&start)[0..20] }), me, null));
}

test "changes: a variable-length event is stepped over, data and padding" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const me: u8 = 129;
    const start = event(event_port_start, &.{ 130, 0 });
    const note = event(6, &.{ 0, 60, 100 });

    // SysEx whose data reads as a Port starting: it must not be taken for one.
    const sysex = variable(event_sysex, @sizeOf(Event));
    try testing.expect(!changes(try bytesOf(arena, &.{ std.mem.asBytes(&sysex), std.mem.asBytes(&start), std.mem.asBytes(&note) }), me, null));

    // 5 bytes of data, padded to a whole event, then a Link undone.
    const unsub = event(event_port_unsubscribed, &.{ 130, 0, 20, 0 });
    const short = variable(event_sysex, 5);
    const data: [28]u8 = .{ 0xf0, 0x7e, 0x7f, 0x06, 0xf7 } ++ @as([23]u8, @splat(0));
    try testing.expect(changes(try bytesOf(arena, &.{ std.mem.asBytes(&short), &data, std.mem.asBytes(&unsub) }), me, null));
    // With the length's flag bits set, the same.
    const flagged = variable(event_sysex, 5 | 0x80000000);
    try testing.expect(changes(try bytesOf(arena, &.{ std.mem.asBytes(&flagged), &data, std.mem.asBytes(&unsub) }), me, null));

    // A Port starting, then SysEx cut short: what came before still counts.
    try testing.expect(changes(try bytesOf(arena, &.{ std.mem.asBytes(&start), std.mem.asBytes(&short), data[0..10] }), me, null));
}

test "changes: only those about a client, if asked" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const me: u8 = 129;
    const start = event(event_port_start, &.{ 130, 0 });
    const link = event(event_port_subscribed, &.{ 131, 0, 130, 0 });
    try testing.expect(changes(std.mem.asBytes(&start), me, 130));
    try testing.expect(!changes(std.mem.asBytes(&start), me, 131));
    try testing.expect(changes(std.mem.asBytes(&link), me, 130));
    try testing.expect(changes(std.mem.asBytes(&link), me, 131));
    try testing.expect(!changes(try bytesOf(arena, &.{ std.mem.asBytes(&start), std.mem.asBytes(&link) }), me, 132));
}

/// Sends `ev` to `to`, straight from `from`'s client, with `data` after it.
fn send(from: Seq, to: Addr, ev: Event, data: []const u8) !void {
    var e = ev;
    e.source = .{ .client = from.client, .port = 0 };
    e.dest = .{ .client = @intCast(to.client), .port = @intCast(to.port) };
    e.queue = queue_direct;
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..@sizeOf(Event)], std.mem.asBytes(&e));
    @memcpy(buf[@sizeOf(Event)..][0..data.len], data);
    const n = @sizeOf(Event) + data.len;
    if (linux.errno(linux.write(from.fd, &buf, n)) != .SUCCESS) return error.SendFailed;
}

const queue_direct: u8 = 253;

/// The Port `listen` made on `s`, as `other` lists it.
fn announcePort(s: Seq, other: Seq, arena: Allocator) !Port {
    for ((try other.list(arena)).ports) |p| if (p.addr.client == s.client) return p;
    return error.NoAnnouncePort;
}

// The sequencer is shared with whatever else runs, other tests included, so
// these count only the changes about their own test client.
test "kernel: what the announce port says arrives as graph changes" {
    const s = try openOrSkip("aroute");
    defer s.close();
    try s.listen();
    // The kernel tells of the Link from 0:1 to aroute's Port; being
    // aroute's own, it isn't a change.
    var buf: [4096]u8 = undefined;
    const rc = linux.read(s.fd, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
    var events: Events = .{ .rest = buf[0..rc] };
    const own = while (events.next()) |ev| {
        if (ev.type == event_port_subscribed and ev.data.connect.dest.client == s.client) break ev;
    } else return error.NoOwnSubscription;
    try testing.expectEqual(KAddr{ .client = system_client, .port = system_announce }, own.data.connect.sender);
    try testing.expect(!changes(std.mem.asBytes(&own), s.client, null));

    const device = try openOrSkip("aroute test device");
    try testing.expect(s.changedAbout(device.client));
    const a = try device.createPort("test port A", all_caps);
    try testing.expect(s.changedAbout(device.client));
    const b = try device.createPort("test port B", all_caps);
    try testing.expect(s.changedAbout(device.client));
    try testing.expect(!s.changedAbout(device.client));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, try s.connect(arena, a, b));
    try testing.expect(s.changedAbout(device.client));
    try testing.expect(s.disconnect(a, b));
    try testing.expect(s.changedAbout(device.client));
    try device.deletePort(b);
    try testing.expect(s.changedAbout(device.client));
    try testing.expect(!s.changedAbout(device.client));

    // SysEx sent straight to aroute's Port is read past, and nothing else.
    const port = (try announcePort(s, device, arena)).addr;
    try send(device, port, variable(event_sysex, 5), &.{ 0xf0, 0x7e, 0x7f, 0x06, 0xf7 });
    try testing.expect(!s.changedAbout(device.client));
    try send(device, port, variable(event_sysex, 5), &.{ 0xf0, 0x7e, 0x7f, 0x06, 0xf7 });
    try device.deletePort(a);
    try testing.expect(s.changedAbout(device.client));

    device.close();
    try testing.expect(s.changedAbout(device.client));
    try testing.expect(!s.changedAbout(device.client));
}

test "kernel: aroute's announce Port is no one's to wire" {
    const s = try openOrSkip("aroute");
    defer s.close();
    try s.listen();
    const other = try openOrSkip("aroute test device");
    defer other.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Not in aroute's own listing.
    for ((try s.list(arena)).ports) |p| try testing.expect(p.addr.client != s.client);
    // Another client sees it, but it only receives, and is no-export.
    const port = try announcePort(s, other, arena);
    try testing.expectEqual(Caps{ .write = true, .no_export = true }, port.caps);
    const a = try other.createPort("test port A", all_caps);
    try testing.expect((try other.connect(arena, a, port.addr)) != null);
}

test "kernel: events lost to a full queue count as a change" {
    const s = try openOrSkip("aroute");
    defer s.close();
    try s.listen();
    const device = try openOrSkip("aroute test device");
    defer device.close();
    _ = try device.createPort("test port A", all_caps);
    try testing.expect(s.changedAbout(device.client));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const port = (try announcePort(s, device, arena_state.allocator())).addr;
    // Note-ons, more than aroute's queue holds, none of them a change.
    for (0..1000) |_| send(device, port, event(6, &.{ 0, 60, 100 }), &.{}) catch {};
    try testing.expect(s.changedAbout(device.client));
    try testing.expect(!s.changedAbout(device.client));
}
