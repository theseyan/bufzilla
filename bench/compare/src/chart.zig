//! Turns comparison results into the README's chart (SVG, in light and dark versions) and tables.
//!
//!     zig build run -Doptimize=ReleaseFast -- --csv > results.csv
//!     zig build chart -- results.csv <output dir> [--machine=<text>] [--mark=<library>]
//!
//! Writes `bench-light.svg` and `bench-dark.svg` to the output directory and prints the markdown
//! tables to stdout. Both come from the same results, so the chart and the tables always agree.
//! `--machine` names the machine in the chart's footer; `--mark` adds a footnote mark (¹) to a
//! library's name, for a library the README explains in a note.
//!
//! The chart shows time per operation (lower is better), one small panel per dataset and operation,
//! each with its own scale. bufzilla's bars are highlighted and labeled with its time; the others are
//! gray and labeled with how many times longer they take.

const std = @import("std");
const data = @import("data.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const reference = "bufzilla";

const Op = enum {
    encode,
    decode,
    access,

    fn title(op: Op) []const u8 {
        return switch (op) {
            .encode => "Encode",
            .decode => "Decode (all values)",
            .access => "Read one field",
        };
    }
};

const ops = [_]Op{ .encode, .decode, .access };

/// How a dataset is named in the chart and the tables.
fn heading(kind: data.Kind) struct { title: []const u8, details: []const u8 } {
    return switch (kind) {
        .person => .{ .title = "One record", .details = "strings, integers, a float, a nested object and arrays" },
        .people => .{ .title = "1000 records", .details = "" },
        .embedding => .{ .title = "A 768-float vector embedding", .details = "" },
    };
}

const Result = struct {
    kind: data.Kind,
    library: []const u8,
    format: []const u8,
    size: u64,
    op: Op,
    median_ns: f64,
};

const Results = struct {
    rows: []const Result,
    /// In order of first appearance; the reference library comes first.
    libraries: []const []const u8,
    /// In order of first appearance.
    kinds: []const data.Kind,

    fn find(r: Results, kind: data.Kind, library: []const u8) ?Result {
        for (r.rows) |row| {
            if (row.kind == kind and std.mem.eql(u8, row.library, library)) return row;
        }
        return null;
    }

    fn time(r: Results, kind: data.Kind, library: []const u8, op: Op) ?f64 {
        for (r.rows) |row| {
            if (row.kind == kind and row.op == op and std.mem.eql(u8, row.library, library)) return row.median_ns;
        }
        return null;
    }

    /// The slowest time in a panel, which sets the panel's scale.
    fn slowest(r: Results, kind: data.Kind, op: Op) f64 {
        var max: f64 = 0;
        for (r.rows) |row| {
            if (row.kind == kind and row.op == op) max = @max(max, row.median_ns);
        }
        return max;
    }
};

/// Parses the output of `bufzilla-compare --csv`.
fn parse(arena: Allocator, csv: []const u8) !Results {
    var rows: std.ArrayList(Result) = .empty;
    var libraries: std.ArrayList([]const u8) = .empty;
    var kinds: std.ArrayList(data.Kind) = .empty;

    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    const header = lines.next() orelse return error.EmptyResults;
    if (!std.mem.startsWith(u8, header, "dataset,library,format,size,operation,median_ns")) return error.NotComparisonResults;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields: [6][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, ',');
        for (&fields) |*field| field.* = it.next() orelse return error.MalformedLine;
        const row: Result = .{
            .kind = std.meta.stringToEnum(data.Kind, fields[0]) orelse return error.UnknownDataset,
            .library = fields[1],
            .format = fields[2],
            .size = try std.fmt.parseInt(u64, fields[3], 10),
            .op = std.meta.stringToEnum(Op, fields[4]) orelse return error.UnknownOperation,
            .median_ns = try std.fmt.parseFloat(f64, fields[5]),
        };
        try rows.append(arena, row);
        for (libraries.items) |l| {
            if (std.mem.eql(u8, l, row.library)) break;
        } else try libraries.append(arena, row.library);
        if (std.mem.findScalar(data.Kind, kinds.items, row.kind) == null) try kinds.append(arena, row.kind);
    }
    if (libraries.items.len == 0 or !std.mem.eql(u8, libraries.items[0], reference)) return error.ReferenceNotFirst;
    return .{ .rows = rows.items, .libraries = libraries.items, .kinds = kinds.items };
}

// =============================================================================
// Number formatting, shared by the chart and the tables
// =============================================================================

fn formatTime(buf: []u8, ns: f64) []const u8 {
    return if (ns < 1_000)
        std.fmt.bufPrint(buf, "{d:.0} ns", .{ns}) catch unreachable
    else if (ns < 10_000)
        std.fmt.bufPrint(buf, "{d:.2} µs", .{ns / 1_000}) catch unreachable
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buf, "{d:.1} µs", .{ns / 1_000}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000}) catch unreachable;
}

/// How many times longer than the reference: two significant digits, whole numbers from 10.
fn formatRatio(buf: []u8, ratio: f64) []const u8 {
    return if (ratio < 1)
        std.fmt.bufPrint(buf, "{d:.2}×", .{ratio}) catch unreachable
    else if (ratio < 10)
        std.fmt.bufPrint(buf, "{d:.1}×", .{ratio}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.0}×", .{ratio}) catch unreachable;
}

/// Bytes with thousands separators: "204,407 B".
fn formatSize(buf: []u8, bytes: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{bytes}) catch unreachable;
    var n: usize = 0;
    for (plain, 0..) |c, i| {
        if (i > 0 and (plain.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    @memcpy(buf[n..][0..2], " B");
    return buf[0 .. n + 2];
}

// =============================================================================
// Markdown tables
// =============================================================================

fn writeTables(w: *Io.Writer, r: Results, mark: ?[]const u8) !void {
    for (r.kinds, 0..) |kind, k| {
        const h = heading(kind);
        if (k > 0) try w.writeAll("\n");
        try w.print("**{s}**", .{h.title});
        if (h.details.len > 0) try w.print(" ({s})", .{h.details});
        try w.print("\n\n| Library | Format | Size | Encode | Decode (all values) | Read `{s}` |\n|---|---|---:|---:|---:|---:|\n", .{kind.accessPath()});
        for (r.libraries) |library| {
            const any = r.find(kind, library) orelse continue;
            var size_buf: [32]u8 = undefined;
            const marked = if (mark != null and std.mem.eql(u8, mark.?, library)) "¹" else "";
            try w.print("| {s}{s} | {s} | {s} |", .{ library, marked, any.format, formatSize(&size_buf, any.size) });
            for (ops) |op| {
                const t = r.time(kind, library, op) orelse {
                    try w.writeAll(" - |");
                    continue;
                };
                var time_buf: [32]u8 = undefined;
                try w.print(" {s}", .{formatTime(&time_buf, t)});
                if (!std.mem.eql(u8, library, reference)) {
                    if (r.time(kind, reference, op)) |ref| {
                        var ratio_buf: [32]u8 = undefined;
                        try w.print(" ({s})", .{formatRatio(&ratio_buf, t / ref)});
                    }
                }
                try w.writeAll(" |");
            }
            try w.writeAll("\n");
        }
    }
}

// =============================================================================
// Chart
// =============================================================================

/// Colors for one color scheme. The accent and the gray were checked for contrast against the
/// surface (at least 3:1) and for distinctness under color vision deficiencies.
const Theme = struct {
    surface: []const u8,
    border: []const u8,
    primary: []const u8,
    secondary: []const u8,
    muted: []const u8,
    baseline: []const u8,
    accent: []const u8,
    other: []const u8,
};

const light: Theme = .{
    .surface = "#fcfcfb",
    .border = "#e1e0d9",
    .primary = "#0b0b0b",
    .secondary = "#52514e",
    .muted = "#898781",
    .baseline = "#c3c2b7",
    .accent = "#2a78d6",
    .other = "#93928c",
};

const dark: Theme = .{
    .surface = "#1a1a19",
    .border = "#2c2c2a",
    .primary = "#f0efec",
    .secondary = "#c3c2b7",
    .muted = "#898781",
    .baseline = "#383835",
    .accent = "#3987e5",
    .other = "#6f6e69",
};

// Layout, in SVG user units. 900 wide, so that GitHub shows the chart at about its natural size.
const width = 900;
const pad = 28;
const label_width = 108;
const panel_gap = 24;
const panel_width = (width - 2 * pad - label_width - 2 * panel_gap) / 3;
/// Bars stop short of the panel's right edge, leaving room for the label at the bar's end.
const bar_max = panel_width - 60;
const row_height = 24;
const bar_thickness = 14;
const corner = 4;
const group_header = 40;
const group_gap = 18;
/// Where the panels start, below the header.
const grid_top = 140;

fn panelX(column: usize) f64 {
    return pad + label_width + @as(f64, @floatFromInt(column)) * (panel_width + panel_gap);
}

/// Escapes text for SVG.
fn escaped(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// A bar growing right from `x`: square at the baseline, rounded at the data end.
fn bar(w: *Io.Writer, x: f64, y: f64, len: f64, color: []const u8) !void {
    const r = @min(corner, len / 2);
    try w.print(
        "<path d=\"M{d:.1} {d:.1}H{d:.1}A{d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}V{d:.1}A{d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}H{d:.1}Z\" fill=\"{s}\"/>\n",
        .{ x, y, x + len - r, r, r, x + len, y + r, y + bar_thickness - r, r, r, x + len - r, y + bar_thickness, x, color },
    );
}

fn chartHeight(r: Results) f64 {
    const groups: f64 = @floatFromInt(r.kinds.len);
    const rows: f64 = @floatFromInt(r.libraries.len);
    return grid_top + groups * (group_header + rows * row_height) + (groups - 1) * group_gap + 64;
}

fn writeChart(w: *Io.Writer, r: Results, theme: Theme, machine: ?[]const u8, mark: ?[]const u8) !void {
    const height = chartHeight(r);
    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d:.0}" viewBox="0 0 {d} {d:.0}" role="img" aria-labelledby="title desc">
        \\<title id="title">bufzilla vs. other Zig serialization libraries: time per operation</title>
        \\<desc id="desc">Time to encode, decode every value, and read one field, for one record, 1000 records and a 768-float vector. Lower is better. The same numbers are in the tables below the chart.</desc>
        \\<style>
        \\text {{ font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; fill: {s}; }}
        \\.title {{ font-size: 20px; font-weight: 600; fill: {s}; }}
        \\.sub {{ font-size: 13px; }}
        \\.col {{ font-size: 13px; font-weight: 600; fill: {s}; }}
        \\.group {{ font-size: 14px; font-weight: 600; fill: {s}; }}
        \\.note {{ font-size: 12px; fill: {s}; }}
        \\.lib {{ font-size: 13px; }}
        \\.ref {{ font-weight: 600; fill: {s}; }}
        \\.val {{ font-size: 12px; }}
        \\</style>
        \\<rect x="0.5" y="0.5" width="{d}" height="{d:.0}" rx="12" fill="{s}" stroke="{s}"/>
        \\
    , .{
        width,           height,        width,         height,
        theme.secondary, theme.primary, theme.primary, theme.primary,
        theme.muted,     theme.primary, width - 1,     height - 1,
        theme.surface,   theme.border,
    });

    // Header: title, how to read the chart, and the key.
    try w.print("<text class=\"title\" x=\"{d}\" y=\"46\">bufzilla vs. other Zig serialization libraries</text>\n", .{pad});
    try w.print("<text class=\"sub\" x=\"{d}\" y=\"70\">Time per operation, lower is better. bufzilla's bars show its time; the others, how many times longer they take.</text>\n", .{pad});
    try w.print("<rect x=\"{d}\" y=\"86\" width=\"12\" height=\"12\" rx=\"3\" fill=\"{s}\"/><text class=\"lib\" x=\"{d}\" y=\"92\" dy=\"0.35em\">bufzilla</text>\n", .{ pad, theme.accent, pad + 18 });
    try w.print("<rect x=\"{d}\" y=\"86\" width=\"12\" height=\"12\" rx=\"3\" fill=\"{s}\"/><text class=\"lib\" x=\"{d}\" y=\"92\" dy=\"0.35em\">other libraries</text>\n", .{ pad + 96, theme.other, pad + 114 });

    // Column headings, once for all groups.
    for (ops, 0..) |op, c| {
        try w.print("<text class=\"col\" x=\"{d:.1}\" y=\"{d}\">{s}</text>\n", .{ panelX(c), grid_top - 8, op.title() });
    }

    var y: f64 = grid_top;
    for (r.kinds) |kind| {
        const h = heading(kind);
        try w.print("<text class=\"group\" x=\"{d}\" y=\"{d:.1}\">{s}</text>\n", .{ pad, y + 26, h.title });
        try w.print("<text class=\"note\" x=\"{d:.1}\" y=\"{d:.1}\">reads <tspan font-family=\"ui-monospace, SFMono-Regular, Menlo, monospace\">", .{ panelX(2), y + 26 });
        try escaped(w, kind.accessPath());
        try w.writeAll("</tspan></text>\n");
        y += group_header;

        const rows_top = y;
        for (r.libraries) |library| {
            const is_ref = std.mem.eql(u8, library, reference);
            const center = y + row_height / 2.0;
            const marked = if (mark != null and std.mem.eql(u8, mark.?, library)) "¹" else "";
            try w.print("<text class=\"lib{s}\" x=\"{d}\" y=\"{d:.1}\" dy=\"0.35em\">", .{ if (is_ref) " ref" else "", pad, center });
            try escaped(w, library);
            try w.print("{s}</text>\n", .{marked});

            for (ops, 0..) |op, c| {
                const x = panelX(c);
                const t = r.time(kind, library, op) orelse {
                    try w.print("<text class=\"val\" x=\"{d:.1}\" y=\"{d:.1}\" dy=\"0.35em\" fill=\"{s}\">–</text>\n", .{ x + 6, center, theme.muted });
                    continue;
                };
                // A bar too short to see still gets a sliver, so that every value has a mark.
                const len = @max(2, t / r.slowest(kind, op) * bar_max);
                try bar(w, x, center - bar_thickness / 2.0, len, if (is_ref) theme.accent else theme.other);
                var buf: [32]u8 = undefined;
                const label = if (is_ref)
                    formatTime(&buf, t)
                else if (r.time(kind, reference, op)) |ref|
                    formatRatio(&buf, t / ref)
                else
                    formatTime(&buf, t);
                try w.print("<text class=\"val{s}\" x=\"{d:.1}\" y=\"{d:.1}\" dy=\"0.35em\">{s}</text>\n", .{ if (is_ref) " ref" else "", x + len + 6, center, label });
            }
            y += row_height;
        }
        // One baseline per panel.
        for (0..3) |c| {
            try w.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\"/>\n", .{ panelX(c) - 0.5, rows_top, panelX(c) - 0.5, y, theme.baseline });
        }
        y += group_gap;
    }

    // Footer: where the numbers come from.
    try w.print("<text class=\"note\" x=\"{d}\" y=\"{d:.1}\">", .{ pad, height - 26 });
    if (machine) |m| {
        try escaped(w, m);
        try w.writeAll(" · ");
    }
    try w.writeAll("ReleaseFast · median of 15 samples · bench/compare");
    if (mark != null) try w.writeAll(" · ¹ see the notes below the tables");
    try w.writeAll("</text>\n</svg>\n");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var machine: ?[]const u8 = null;
    var mark: ?[]const u8 = null;
    for (args[@min(args.len, 1)..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--machine=")) {
            machine = arg["--machine=".len..];
        } else if (std.mem.startsWith(u8, arg, "--mark=")) {
            mark = arg["--mark=".len..];
        } else if (count < positional.len) {
            positional[count] = arg;
            count += 1;
        } else return error.TooManyArguments;
    }
    if (count != 2) {
        std.debug.print("usage: chart <results.csv> <output dir> [--machine=<text>] [--mark=<library>]\n", .{});
        return error.InvalidArguments;
    }

    const cwd = Io.Dir.cwd();
    const csv = try cwd.readFileAlloc(io, positional[0], arena, .limited(1 << 20));
    const results = try parse(arena, csv);

    try cwd.createDirPath(io, positional[1]);
    var out_dir = try cwd.openDir(io, positional[1], .{});
    defer out_dir.close(io);
    inline for (.{ .{ "bench-light.svg", light }, .{ "bench-dark.svg", dark } }) |variant| {
        var svg: Io.Writer.Allocating = .init(arena);
        try writeChart(&svg.writer, results, variant[1], machine, mark);
        try out_dir.writeFile(io, .{ .sub_path = variant[0], .data = svg.written() });
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    try writeTables(&stdout.interface, results, mark);
    try stdout.interface.flush();
}
