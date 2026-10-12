const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

target_id: [evt.event_id_size * 2]u8,

// what the db stores: the event's data plus the commit-derived fields. the file
// itself is the one entry in the event commit's tree, so its name and blob come
// from there rather than from the payload.
pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_order: u64 = 0,
    updated_order: u64 = 0,
    name: []const u8,
    blob_oid: []const u8,
};

const Self = @This();

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .target_wins;
pub const record_map_key = "event-id->attachment";
pub const all_id_set_key = "attachment-id-set";

// the index a target event's view reads
pub const target_id_to_attachment_id_set_key = "target-id->attachment-id-set";

pub const max_size: usize = 10 * 1024 * 1024;
pub const name_max_len = 255;

// the name is the tree entry's name, so it must be a legal path component
pub fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| {
        if (ch == '/' or ch == '\\' or std.ascii.isControl(ch)) return false;
    }
    return true;
}

fn targetExists(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: anytype,
    target_id: *const [evt.event_id_size]u8,
) !bool {
    const kinds_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.event_index_key)) orelse return false;
    const kinds = try DB.HashMap(.read_only).init(kinds_cursor);
    return try kinds.getCursor(hash.hashInt(hash_kind, target_id)) != null;
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
    const attachment_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_attachment_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key));
    const event_id_to_attachment = try DB.HashMap(.read_write).init(event_id_to_attachment_cursor);

    const target_id_to_attachment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, target_id_to_attachment_id_set_key));
    const target_id_to_attachment_id_set = try DB.HashMap(.read_write).init(target_id_to_attachment_id_set_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_attachment.getCursor(attachment_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_attachment = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_attachment);
    }

    var record_to_write = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_record_maybe);

    const target_id = try evt.parseEventId(&record_to_write.event.target_id);
    if (!try targetExists(DB, hash_kind, haxy_moment, &target_id)) return error.TargetNotFound;
    if (!nameValid(record_to_write.name)) return error.InvalidAttachment;

    if (existing_record_maybe) |existing_record| {
        // the file never changes, so an update preserves everything the original
        // commit determined
        record_to_write.created_order = existing_record.created_order;
        record_to_write.author_email = existing_record.author_email;
        record_to_write.name = existing_record.name;
        record_to_write.blob_oid = existing_record.blob_oid;

        // an attachment cannot move to another target
        if (!std.mem.eql(u8, &existing_record.event.target_id, &record_to_write.event.target_id)) return error.TargetChanged;
    }

    const attachment_cursor = try event_id_to_attachment.putCursor(attachment_key);
    const attachment = try DB.HashMap(.read_write).init(attachment_cursor);
    try evt.upsert(Record, DB, hash_kind, attachment, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .attach, existing_record_maybe, record_to_write);

    if (existing_cursor_maybe == null) {
        const attachment_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key));
        const attachment_id_set = try DB.SortedSet(.read_write).init(attachment_id_set_cursor);
        try attachment_id_set.put(&evt.orderKeyDesc(record_to_write.created_order, event_id));
    }

    // removed attachments stay in the target's set; the views skip them
    const target_attachments_cursor = try target_id_to_attachment_id_set.putCursor(hash.hashInt(hash_kind, &target_id));
    const target_attachments = try DB.SortedSet(.read_write).init(target_attachments_cursor);
    try target_attachments.put(&evt.orderKey(record_to_write.created_order, event_id));
}

// attach `blob` to a target event and return the event id. `repo` must be
// writable.
pub fn create(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    target_kind: evt.EventKind,
    target_id: *const [evt.event_id_size * 2]u8,
    blob: evt.Blob,
    author: evt.CommitAuthor,
) ![evt.event_id_size * 2]u8 {
    if (!nameValid(blob.name)) return error.InvalidFields;
    if (blob.size == 0 or blob.size > max_size) return error.InvalidFields;

    const target_id_bytes = evt.parseEventId(target_id) catch return error.InvalidFields;
    if (!try evt.threadHolds(repo_kind, repo_opts, io, allocator, repo, target_kind, &target_id_bytes, null)) return error.TargetNotFound;

    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const event_id = std.fmt.bytesToHex(id_bytes, .lower);
    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = event_id,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .tree_entries = &.{.{ .blob = blob }},
        .event = .{ .attach = .{ .target_id = target_id.* } },
    }});
    return event_id;
}

// read an attachment by event id, or null if the id isn't a known attachment.
// field byte slices are allocated in `arena`.
pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    attachment_id: []const u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, attachment_id)) orelse return null;
    const record_map = try DB.HashMap(.read_only).init(record_cursor);
    return try evt.read(Record, DB, hash_kind, arena, record_map);
}
