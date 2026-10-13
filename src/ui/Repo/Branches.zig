const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const Comment = @import("./Comment.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// the repo's protected branches, which only its owners see
identity: []const u8,
names: []const []const u8,

const Self = @This();

pub const Action = enum { protect, unprotect };

pub fn init(arena: *std.heap.ArenaAllocator, identity: []const u8, repo: evt.Repo) !Self {
    const aa = arena.allocator();
    return .{
        .identity = try aa.dupe(u8, identity),
        .names = try repo.protectedBranchNames(aa),
    };
}

// protect or unprotect `branch` in the repo `identity` names as `actor`, one
// of its owners. returns why a protect wrote nothing, or null once written
pub fn perform(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    actor: ui.Actor,
    identity: []const u8,
    action: Action,
    branch: []const u8,
) !?ui.Session.FormFeedback.BranchesFailure {
    const owner_id = actor.repo_user_id orelse return error.NotFound;
    const parsed = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const repo_id = blk: {
        var user_repo = (try evt.openUserRepo(io, allocator, users_dir, &owner_id)) orelse return error.NotFound;
        defer user_repo.deinit(io, allocator);
        const moment = (try evt.userMoment(&user_repo)) orelse return error.NotFound;
        const found = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, parsed.name)) orelse return error.NotFound;
        break :blk found.event_id;
    };

    // only an existing branch can be protected, and its row links to it, so
    // its encoded name must fit in a route
    if (action == .protect) {
        if ((try ui.urlEncodeRef(arena.allocator(), branch)).len > ui.RoutablePage.ref_route_max_len) return .too_long;
        const path = try evt.repoPath(allocator, users_dir, &owner_id, &repo_id);
        defer allocator.free(path);
        const source = ui.RepoSource{ .path = path, .repo_kind = .xit };
        if (!try source.hasBranch(io, allocator, branch)) return .not_found;
    }
    evt.protectBranch(io, allocator, users_dir, &owner_id, &repo_id, branch, action == .protect, actor.author) catch |err| {
        if (ui.Session.FormFeedback.BranchesFailure.fromError(err)) |failure| return failure;
        return err;
    };
    return null;
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const add_index = 0;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const aa = session.page_arena.allocator();
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoBranchesRoute(data.identity) orelse return error.RouteTooLong;
        const url = try route.toUrl(session.page_arena);

        {
            // the gap leaves a blank line between the text and the input
            var add = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert, .gap = 1 });
            errdefer add.deinit(allocator);
            add.getFocus().kind = .{ .custom = try aa.print("form:{s}/protect", .{url}) };
            {
                var about = try ui.widget.RichText.init(allocator, &.{
                    .{ .text = "protected branches can't be deleted or force pushed." },
                });
                errdefer about.deinit(allocator);
                try add.children.put(allocator, about.getFocus().id, .{ .widget = .{ .rich_text = about }, .rect = null, .min_size = null });
            }
            var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " add a protected branch " }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            if (session.formFeedback(.repo_branches)) |saved| try name.setContent(allocator, saved.name);
            add.getFocus().child_id = name.getFocus().id;
            try add.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            try box.children.put(allocator, add.getFocus().id, .{ .widget = .{ .box = add }, .rect = null, .min_size = .{ .width = null, .height = 5 } });
        }

        // the branch rows follow the add row in the same box
        for (data.names) |branch| {
            const encoded = try ui.urlEncodeRef(aa, branch);
            var row_route = route;
            row_route.repo_branches.branch = ui.RoutablePage.Array(ui.RoutablePage.ref_route_max_len).from(encoded) orelse return error.RouteTooLong;
            const row_url = try row_route.toUrl(session.page_arena);

            var row_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer row_box.deinit(allocator);
            row_box.getFocus().kind = .{ .custom = try aa.print("form:{s}", .{row_url}) };
            {
                const files_route = ui.RoutablePage.repoFilesRoute(data.identity, .branch, encoded, "", 0) orelse return error.RouteTooLong;
                var name = try Comment.linkBox(allocator, session, branch, files_route);
                errdefer name.deinit(allocator);
                try row_box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_box = name }, .rect = null, .min_size = null });
            }
            {
                var remove = try wgt.TextBox.init(allocator, "✕", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer remove.deinit(allocator);
                remove.getFocus().mode = .all;
                remove.getFocus().kind = .{ .custom = try aa.print("submit:{s}/unprotect", .{row_url}) };
                try row_box.children.put(allocator, remove.getFocus().id, .{ .widget = .{ .text_box = remove }, .rect = null, .min_size = .{ .width = 3, .height = null } });
            }
            row_box.getFocus().child_id = row_box.children.keys()[0];
            try box.children.put(allocator, row_box.getFocus().id, .{ .widget = .{ .box = row_box }, .rect = null, .min_size = null });
        }

        box.getFocus().child_id = box.children.keys()[add_index];
        var center = try ui.widget.Center.init(allocator, .{ .box = box });
        errdefer center.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
            .data = data,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.center.child.box;
    }

    fn addBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[add_index].widget.box;
    }

    fn nameInput(self: *View) *wgt.TextInput {
        return &self.addBox().children.values()[1].widget.text_input;
    }

    fn addActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.addBox().getFocus().id;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.labelAddInput(root_focus);
        // the window's height as a minimum centers rows that fit
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    // label the add input for this frame and register it for the web form
    // handling
    fn labelAddInput(self: *View, root_focus: *Focus) !void {
        const name = self.nameInput();
        const failure = if (self.session.formFeedback(.repo_branches)) |saved| saved.failure else null;
        name.options.top_label.text = if (failure) |value| switch (value) {
            .not_found => " add a protected branch (not found) ",
            .already_added => " add a protected branch (already added) ",
            .too_many => " add a protected branch (too many branches) ",
            .too_long => " add a protected branch (name too long) ",
        } else " add a protected branch ";
        name.options.bottom_label.text = if (root_focus.grandchild_id == name.getFocus().id) " press enter " else "";
        try self.session.text_inputs.put(self.session.arena.allocator(), name.getFocus().id, name);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the add row keeps every key but the vertical ones, which move between rows
        if (self.addActive() and inp.vertDirection(key) == .none) {
            if (key == .enter) {
                const name = try self.nameInput().text(allocator);
                defer allocator.free(name);
                try self.act(allocator, .protect, name);
            } else try self.nameInput().input(allocator, key, root_focus);
            return;
        }

        const rows = self.contentBox();
        const current = rows.children.getIndex(rows.getFocus().child_id orelse return) orelse return;
        if (inp.rowDelta(key, @intCast(rows.children.count()))) |delta| {
            ui.widget.moveRowFocus(rows, &self.scroll, root_focus, delta);
            return;
        }
        switch (key) {
            .arrow_left, .arrow_right => _ = ui.widget.moveInSelectedRow(rows, root_focus, key == .arrow_right),
            else => {
                // the add row sits above the rows, and a row's name is a link the host follows
                if (current <= add_index) return;
                const row_box = &rows.children.values()[current].widget.box;
                const button_id = row_box.getFocus().child_id orelse return;
                if (row_box.children.getIndex(button_id) != 1 or !inp.activated(root_focus, button_id, key)) return;
                try self.act(allocator, .unprotect, self.data.names[current - add_index - 1]);
            },
        }
    }

    // the terminal performs the action itself; the web posts the form instead
    fn act(self: *View, allocator: std.mem.Allocator, action: Action, branch: []const u8) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const actor = (try self.session.authorize(self.data.identity, .owner, null)) orelse return;
        if (try perform(io, allocator, users_dir, actor, self.data.identity, action, branch)) |failure| {
            self.session.data.form_feedback = .{ .repo_branches = .{ .failure = failure, .name = try self.session.arena.allocator().dupe(u8, branch) } };
            return;
        }
        try self.session.navigate(ui.RoutablePage.repoBranchesRoute(self.data.identity) orelse return error.RouteTooLong);
    }

    pub fn clearGrid(self: *View) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.scroll.getFocus();
    }

    // up leaves the view from the add row
    pub fn atTop(self: *View) bool {
        return self.addActive();
    }
};
