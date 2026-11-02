//! The system the old `aconnect -i`, `-o` and `-l` fixtures listed, as the
//! sequencer lists it: a real run with three userspace clients standing in
//! for USB devices, WORLDE (one port), Clipper (two) and "Keys 'n' Pads"
//! (one port plus a read-only Sync port), next to System, Midi Through and
//! PipeWire's own clients.

const seq = @import("../seq.zig");
const Addr = @import("../graph.zig").Addr;

const rw: seq.Caps = .{ .read = true, .write = true, .subs_read = true, .subs_write = true };

fn at(client: u16, port: u16) Addr {
    return .{ .client = client, .port = port };
}

pub const listing: seq.Listing = .{
    .clients = &.{
        .{ .id = 0, .name = "System" },
        .{ .id = 14, .name = "Midi Through" },
        .{ .id = 128, .name = "WORLDE" },
        .{ .id = 129, .name = "Clipper" },
        .{ .id = 130, .name = "Keys 'n' Pads" },
        .{ .id = 144, .name = "PipeWire-System" },
        .{ .id = 145, .name = "PipeWire-RT-Event" },
    },
    .ports = &.{
        .{ .addr = at(0, 0), .name = "Timer", .caps = .{ .read = true, .write = true, .subs_read = true } },
        .{ .addr = at(0, 1), .name = "Announce", .caps = .{ .read = true, .subs_read = true } },
        .{ .addr = at(14, 0), .name = "Midi Through Port-0", .caps = rw },
        .{ .addr = at(128, 0), .name = "WORLDE MIDI 1", .caps = rw },
        .{ .addr = at(129, 0), .name = "Clipper MIDI 1", .caps = rw },
        .{ .addr = at(129, 1), .name = "Clipper MIDI 2", .caps = rw },
        .{ .addr = at(130, 0), .name = "Keys MIDI 1", .caps = rw },
        .{ .addr = at(130, 1), .name = "Keys Sync", .caps = .{ .read = true, .subs_read = true } },
        // PipeWire wires its own Ports, so others can't subscribe them.
        .{ .addr = at(144, 0), .name = "input", .caps = .{ .write = true } },
        .{ .addr = at(145, 0), .name = "input", .caps = .{ .read = true, .write = true } },
    },
    .subscriptions = &.{
        .{ .from = at(0, 0), .to = at(144, 0) },
        .{ .from = at(0, 1), .to = at(144, 0) },
        .{ .from = at(14, 0), .to = at(145, 0) },
        .{ .from = at(128, 0), .to = at(129, 1) },
        .{ .from = at(128, 0), .to = at(145, 0) },
        .{ .from = at(129, 0), .to = at(145, 0) },
        .{ .from = at(129, 1), .to = at(145, 0) },
        .{ .from = at(130, 0), .to = at(14, 0) },
        .{ .from = at(130, 0), .to = at(145, 0) },
        .{ .from = at(130, 1), .to = at(128, 0) },
        .{ .from = at(130, 1), .to = at(145, 0) },
        .{ .from = at(145, 0), .to = at(14, 0) },
        .{ .from = at(145, 0), .to = at(128, 0) },
        .{ .from = at(145, 0), .to = at(129, 0) },
        .{ .from = at(145, 0), .to = at(129, 1) },
        .{ .from = at(145, 0), .to = at(130, 0) },
    },
};
