const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const hash = xit.hash;

// the repo's owner, whose user repo holds the subscriber index
owner_id: [evt.event_id_size * 2]u8,
// the thread and its repo
repo_id: [evt.event_id_size * 2]u8,
thread_id: [evt.event_id_size * 2]u8,
mode: Mode,

pub const Mode = enum {
    // always notified
    subscribe,
    // never notified
    mute,
};

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->notify";
pub const all_id_set_key = "notify-id-set";

// the id of the one record a user can hold on a thread
pub fn idOf(repo_id: *const [evt.event_id_size]u8, thread_id: *const [evt.event_id_size]u8) [evt.event_id_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // the kind name keeps derived ids of different kinds apart
    hasher.update(@tagName(evt.EventKind.notify));
    hasher.update(repo_id);
    hasher.update(thread_id);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..evt.event_id_size].*;
}

// only what the event says about itself is checked. a record naming a missing
// repo or thread is inert.
fn validate(event_id: *const [evt.event_id_size]u8, record: Record) !void {
    _ = try evt.parseEventId(&record.event.owner_id);
    const repo_id = try evt.parseEventId(&record.event.repo_id);
    const thread_id = try evt.parseEventId(&record.event.thread_id);
    if (!std.mem.eql(u8, event_id, &idOf(&repo_id, &thread_id))) return error.InvalidNotifyId;
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    _: ?[]const u8,
) !void {
    const notify_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(notify_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!record.removed) try validate(event_id, record);

    if (existing_maybe) |existing| {
        // updates preserve the original creation metadata
        record.created_order = existing.created_order;
    }

    const notify_cursor = try records.putCursor(notify_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(notify_cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .notify, existing_maybe, record);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&evt.orderKeyDesc(record.created_order, event_id));
    }
}

// the user's mode for the thread, or null without a record
pub fn readMode(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    repo_id: *const [evt.event_id_size]u8,
    thread_id: *const [evt.event_id_size]u8,
) !?Mode {
    const record = (try evt.readRecordSubset(Self, struct { removed: bool, event: struct { mode: Mode } }, DB, hash_kind, haxy_moment, arena, &idOf(repo_id, thread_id))) orelse return null;
    return if (record.removed) null else record.event.mode;
}
