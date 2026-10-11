const std = @import("std");
const evt = @import("event.zig");
const srch = @import("search.zig");
const xit = @import("xit");
const hash = xit.hash;

// the thread search indexes: one per kind, inside the haxy moment, so events
// carry them and every host that consumes events builds them. a doc key is the
// thread's creation order key, which never changes. issues and patches list in
// that order too, so their list sets filter a query by intersection.

pub fn indexKey(comptime kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "word->issue-id-set",
        .patch => "word->patch-id-set",
        .discuss => "word->discussion-id-set",
        else => @compileError("no thread index for " ++ @tagName(kind)),
    };
}

// reindex the thread `key` names after `old_maybe` became `new`. an unchanged
// doc costs nothing: a status change or an edit that leaves the indexed fields
// alone returns here.
pub fn update(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_write),
    allocator: std.mem.Allocator,
    key: []const u8,
    old_maybe: anytype,
    new: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const old_text = if (old_maybe) |old| try text(aa, old) else "";
    const new_text = try text(aa, new);
    if (std.mem.eql(u8, old_text, new_text)) return;
    const index = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, indexKey(kind))));
    try srch.replace(DB, index, allocator, key, old_text, new_text);
}

// the doc keys matching `query_text`, in key order
pub fn query(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    comptime kind: evt.EventKind,
    haxy_moment: DB.HashMap(.read_only),
    aa: std.mem.Allocator,
    query_text: []const u8,
) !srch.Query(DB) {
    const cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, indexKey(kind))) orelse {
        // no index means no words match, which one empty term expresses
        var results: srch.Query(DB) = .{ .terms = .empty };
        try results.terms.append(aa, .{ .postings = &.{} });
        return results;
    };
    return srch.Query(DB).init(try DB.SortedMap(.read_only).init(cursor), aa, query_text);
}

pub const label_prefix = "label:";
pub const assignee_prefix = "assignee:";

// a thread search split into its filter terms and the words left for the index
pub const Filters = struct {
    labels: []const []const u8,
    assignees: []const []const u8,
    // the remaining terms joined by single spaces, "" when none
    words: []const u8,
};

// split `search` on whitespace into label and assignee terms and plain words.
// a prefix with no value is dropped.
pub fn parseFilters(aa: std.mem.Allocator, search: []const u8) !Filters {
    var labels: std.ArrayList([]const u8) = .empty;
    var assignees: std.ArrayList([]const u8) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeAny(u8, search, &std.ascii.whitespace);
    while (iter.next()) |term| {
        if (std.mem.startsWith(u8, term, label_prefix)) {
            if (term.len > label_prefix.len) try labels.append(aa, term[label_prefix.len..]);
        } else if (std.mem.startsWith(u8, term, assignee_prefix)) {
            if (term.len > assignee_prefix.len) try assignees.append(aa, term[assignee_prefix.len..]);
        } else try words.append(aa, term);
    }
    return .{ .labels = labels.items, .assignees = assignees.items, .words = try std.mem.join(aa, " ", words.items) };
}

// `search` with its `prefix` terms replaced by one for `value`, put first
pub fn withFilter(aa: std.mem.Allocator, search: []const u8, prefix: []const u8, value: []const u8) ![]const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    try terms.append(aa, try std.mem.concat(aa, u8, &.{ prefix, value }));
    var iter = std.mem.tokenizeAny(u8, search, &std.ascii.whitespace);
    while (iter.next()) |term| {
        if (!std.mem.startsWith(u8, term, prefix)) try terms.append(aa, term);
    }
    return std.mem.join(aa, " ", terms.items);
}

// the text a thread is indexed under, none once it is removed: the title and
// labels first, so the tokenizer's caps can only drop the tail of a long
// description.
fn text(aa: std.mem.Allocator, record: anytype) ![]const u8 {
    if (record.removed) return "";
    return std.mem.concat(aa, u8, &.{ record.event.title, " ", record.event.labels, " ", record.event.description });
}
