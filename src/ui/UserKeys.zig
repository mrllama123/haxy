const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const inp = @import("./input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// the logged-in user's ssh keys, one authorized_keys line each
keys: []const []const u8 = &.{},

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session, user_id: *const [evt.event_id_size]u8) !Self {
    const moment = session.haxy_moment orelse return .{};
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, user_id)) orelse return .{};
    var keys: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, user.event.ssh_keys, '\n');
    while (lines.next()) |line| {
        if (evt.User.fingerprintOfKey(line) == null) continue;
        try keys.append(arena.allocator(), line);
    }
    return .{ .keys = keys.items };
}

// a key's comment, or its type when it has none
fn keyLabel(key: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, key, " \t");
    const key_type = tokens.next() orelse return "";
    _ = tokens.next();
    const comment = std.mem.trim(u8, tokens.rest(), " \t");
    return if (comment.len > 0) comment else key_type;
}

const add_label = " add ssh key ";
const input_width = 60;

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const add_index = 0;

    // `route` is the ssh keys route, which the forms post under
    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, route: ui.RoutablePage) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const aa = session.page_arena.allocator();
        const url = try route.toUrl(session.page_arena);

        {
            var add = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer add.deinit(allocator);
            add.getFocus().kind = .{ .custom = try aa.print("form:{s}/addkey", .{url}) };
            var key = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = add_label }, .name = "key", .visible_width = input_width, .round_corners = true, .render_content = session.is_terminal });
            errdefer key.deinit(allocator);
            key.getFocus().mode = .all;
            if (session.formFeedback(.user_keys)) |saved| try key.setContent(allocator, saved.key);
            add.getFocus().child_id = key.getFocus().id;
            try add.children.put(allocator, key.getFocus().id, .{ .widget = .{ .text_input = key }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            try box.children.put(allocator, add.getFocus().id, .{ .widget = .{ .box = add }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        // one row per key, whose form posts the key to remove
        for (data.keys) |key| {
            var row = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer row.deinit(allocator);
            row.getFocus().kind = .{ .custom = try aa.print("form:{s}/removekey", .{url}) };
            {
                var text_input = try wgt.TextInput.init(allocator, .{
                    .top_label = .{ .text = try aa.print(" {s} ", .{keyLabel(key)}) },
                    .name = "key",
                    .visible_width = input_width,
                    .round_corners = true,
                    .read_only = true,
                    .render_content = session.is_terminal,
                });
                errdefer text_input.deinit(allocator);
                text_input.getFocus().mode = .all;
                try text_input.setContent(allocator, key);
                // show the start of the key, as the web's input does
                text_input.cursor = 0;
                try row.children.put(allocator, text_input.getFocus().id, .{ .widget = .{ .text_input = text_input }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            }
            {
                var remove = try wgt.TextBox.init(allocator, "✕", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer remove.deinit(allocator);
                remove.getFocus().mode = .all;
                remove.getFocus().kind = .{ .custom = "submit" };
                try row.children.put(allocator, remove.getFocus().id, .{ .widget = .{ .text_box = remove }, .rect = null, .min_size = .{ .width = 3, .height = null } });
            }
            row.getFocus().child_id = row.children.keys()[0];
            try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
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

    fn addInput(self: *View) *wgt.TextInput {
        return &self.addBox().children.values()[0].widget.text_input;
    }

    fn addActive(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.addBox().getFocus().id;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const add = self.addInput();
        const failure = if (self.session.formFeedback(.user_keys)) |saved| saved.failure else null;
        add.options.top_label.text = if (failure) |value| switch (value) {
            .invalid => " add ssh key (invalid) ",
            .unsupported => " add ssh key (unsupported type) ",
            .already_added => " add ssh key (already added) ",
        } else add_label;
        add.options.bottom_label.text = if (root_focus.grandchild_id == add.getFocus().id) " press enter " else "";
        // the web form handling finds the inputs by focus id
        const inputs_arena = self.session.arena.allocator();
        for (self.contentBox().children.values()) |*child| {
            const text_input = &child.widget.box.children.values()[0].widget.text_input;
            try self.session.text_inputs.put(inputs_arena, text_input.getFocus().id, text_input);
        }
        // the window's height as a minimum centers rows that fit
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // the add row keeps every key but the vertical ones, which move between rows
        if (self.addActive() and inp.vertDirection(key) == .none) {
            if (key == .enter) {
                const text = try self.addInput().text(allocator);
                defer allocator.free(text);
                try self.act(allocator, .add, text);
            } else try self.addInput().input(allocator, key, root_focus);
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
                // the add row sits above the key rows
                if (current == add_index) return;
                const row = &rows.children.values()[current].widget.box;
                const remove_id = row.children.keys()[1];
                if (row.getFocus().child_id != remove_id or !inp.activated(root_focus, remove_id, key)) return;
                try self.act(allocator, .remove, self.data.keys[current - 1]);
            },
        }
    }

    // the terminal changes the keys itself; the web posts the form instead
    fn act(self: *View, allocator: std.mem.Allocator, action: evt.KeyAction, key: []const u8) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const admin_repo = self.session.admin_repo orelse return;
        const user_id = self.session.userId() orelse return;
        evt.changeUserKey(io, allocator, users_dir, admin_repo, &user_id, action, key) catch |err| switch (err) {
            // the account was removed under them
            error.NotFound => return ui.UserNotifications.logOut(self.session),
            else => {
                const failure = ui.Session.FormFeedback.KeyFailure.fromError(err) orelse return err;
                self.session.data.form_feedback = .{ .user_keys = .{ .failure = failure, .key = try self.session.arena.allocator().dupe(u8, key) } };
                return;
            },
        };
        // reload the page with the keys as they are now
        self.session.haxy_moment = try evt.currentMoment(evt.admin_repo_opts, admin_repo);
        try self.session.navigate(self.session.data.current_page);
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
