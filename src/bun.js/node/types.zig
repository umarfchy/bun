const std = @import("std");
const builtin = @import("builtin");
const bun = @import("root").bun;
const meta = bun.meta;
const windows = bun.windows;
const heap_allocator = bun.default_allocator;
const is_bindgen: bool = false;
const kernel32 = windows.kernel32;
const logger = bun.logger;
const posix = std.posix;
const path_handler = bun.path;
const strings = bun.strings;
const string = bun.string;

const C = bun.C;
const L = strings.literal;
const Environment = bun.Environment;
const Fs = @import("../../fs.zig");
const IdentityContext = @import("../../identity_context.zig").IdentityContext;
const JSC = bun.JSC;
const Mode = bun.Mode;
const Shimmer = @import("../bindings/shimmer.zig").Shimmer;
const Syscall = bun.sys;
const URL = @import("../../url.zig").URL;
const Value = std.json.Value;

pub const Path = @import("./path.zig");

fn typeBaseNameT(comptime T: type) []const u8 {
    return meta.typeBaseName(@typeName(T));
}

pub const Buffer = JSC.MarkedArrayBuffer;

/// On windows, this is what libuv expects
/// On unix it is what the utimens api expects
pub const TimeLike = if (Environment.isWindows) f64 else std.posix.timespec;

pub const Flavor = enum {
    sync,
    promise,
    callback,

    pub fn Wrap(comptime this: Flavor, comptime T: type) type {
        return comptime brk: {
            switch (this) {
                .sync => break :brk T,
                // .callback => {
                //     const Callback = CallbackTask(Type);
                // },
                else => @compileError("Not implemented yet"),
            }
        };
    }
};

/// Node.js expects the error to include contextual information
/// - "syscall"
/// - "path"
/// - "errno"
pub fn Maybe(comptime ReturnTypeT: type, comptime ErrorTypeT: type) type {
    const hasRetry = @hasDecl(ErrorTypeT, "retry");
    const hasTodo = @hasDecl(ErrorTypeT, "todo");

    return union(Tag) {
        pub const ErrorType = ErrorTypeT;
        pub const ReturnType = ReturnTypeT;

        err: ErrorType,
        result: ReturnType,

        pub const Tag = enum { err, result };

        pub const retry: @This() = if (hasRetry) .{ .err = ErrorType.retry } else .{ .err = ErrorType{} };

        pub const success: @This() = @This(){
            .result = std.mem.zeroes(ReturnType),
        };

        pub fn assert(this: @This()) ReturnType {
            switch (this) {
                .err => |err| {
                    bun.Output.panic("Unexpected error\n{}", .{err});
                },
                .result => |result| return result,
            }
        }

        pub inline fn todo() @This() {
            if (Environment.allow_assert) {
                if (comptime ReturnType == void) {
                    @panic("TODO called!");
                }
                @panic(comptime "TODO: Maybe(" ++ typeBaseNameT(ReturnType) ++ ")");
            }
            if (hasTodo) {
                return .{ .err = ErrorType.todo() };
            }
            return .{ .err = ErrorType{} };
        }

        pub fn unwrap(this: @This()) !ReturnType {
            return switch (this) {
                .result => |r| r,
                .err => |e| bun.errnoToZigErr(e.errno),
            };
        }

        pub inline fn initErr(e: ErrorType) Maybe(ReturnType, ErrorType) {
            return .{ .err = e };
        }

        pub inline fn initErrWithP(e: C.SystemErrno, syscall: Syscall.Tag, path: anytype) Maybe(ReturnType, ErrorType) {
            return .{ .err = .{
                .errno = @intFromEnum(e),
                .syscall = syscall,
                .path = path,
            } };
        }

        pub inline fn asErr(this: *const @This()) ?ErrorType {
            if (this.* == .err) return this.err;
            return null;
        }

        pub inline fn initResult(result: ReturnType) Maybe(ReturnType, ErrorType) {
            return .{ .result = result };
        }

        pub fn toJS(this: @This(), globalObject: *JSC.JSGlobalObject) JSC.JSValue {
            return switch (this) {
                .result => |r| switch (ReturnType) {
                    JSC.JSValue => r,

                    void => .undefined,
                    bool => JSC.JSValue.jsBoolean(r),

                    JSC.ArrayBuffer => r.toJS(globalObject, null),
                    []u8 => JSC.ArrayBuffer.fromBytes(r, .ArrayBuffer).toJS(globalObject, null),

                    else => switch (@typeInfo(ReturnType)) {
                        .Int, .Float, .ComptimeInt, .ComptimeFloat => JSC.JSValue.jsNumber(r),
                        .Struct, .Enum, .Opaque, .Union => r.toJS(globalObject),
                        .Pointer => {
                            if (bun.trait.isZigString(ReturnType))
                                JSC.ZigString.init(bun.asByteSlice(r)).withEncoding().toJS(globalObject);

                            return r.toJS(globalObject);
                        },
                    },
                },
                .err => |e| e.toJSC(globalObject),
            };
        }

        pub fn toArrayBuffer(this: @This(), globalObject: *JSC.JSGlobalObject) JSC.JSValue {
            return switch (this) {
                .result => |r| JSC.ArrayBuffer.fromBytes(r, .ArrayBuffer).toJS(globalObject, null),
                .err => |e| e.toJSC(globalObject),
            };
        }

        pub inline fn getErrno(this: @This()) posix.E {
            return switch (this) {
                .result => posix.E.SUCCESS,
                .err => |e| @enumFromInt(e.errno),
            };
        }

        pub inline fn errnoSys(rc: anytype, syscall: Syscall.Tag) ?@This() {
            if (comptime Environment.isWindows) {
                if (comptime @TypeOf(rc) == std.os.windows.NTSTATUS) {} else {
                    if (rc != 0) return null;
                }
            }
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    // always truncate
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                    },
                },
            };
        }

        pub inline fn errno(err: anytype, syscall: Syscall.Tag) @This() {
            return @This(){
                // always truncate
                .err = .{
                    .errno = translateToErrInt(err),
                    .syscall = syscall,
                },
            };
        }

        pub inline fn errnoSysFd(rc: anytype, syscall: Syscall.Tag, fd: bun.FileDescriptor) ?@This() {
            if (comptime Environment.isWindows) {
                if (comptime @TypeOf(rc) == std.os.windows.NTSTATUS) {} else {
                    if (rc != 0) return null;
                }
            }
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    // Always truncate
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .fd = fd,
                    },
                },
            };
        }

        pub inline fn errnoSysP(rc: anytype, syscall: Syscall.Tag, path: anytype) ?@This() {
            if (bun.meta.Item(@TypeOf(path)) == u16) {
                @compileError("Do not pass WString path to errnoSysP, it needs the path encoded as utf8");
            }
            if (comptime Environment.isWindows) {
                if (comptime @TypeOf(rc) == std.os.windows.NTSTATUS) {} else {
                    if (rc != 0) return null;
                }
            }
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |e| @This(){
                    // Always truncate
                    .err = .{
                        .errno = translateToErrInt(e),
                        .syscall = syscall,
                        .path = bun.asByteSlice(path),
                    },
                },
            };
        }
    };
}

fn translateToErrInt(err: anytype) bun.sys.Error.Int {
    return switch (@TypeOf(err)) {
        bun.windows.NTSTATUS => @intFromEnum(bun.windows.translateNTStatusToErrno(err)),
        else => @truncate(@intFromEnum(err)),
    };
}

pub const BlobOrStringOrBuffer = union(enum) {
    blob: JSC.WebCore.Blob,
    string_or_buffer: StringOrBuffer,

    pub fn deinit(this: *const BlobOrStringOrBuffer) void {
        switch (this.*) {
            .blob => |blob| {
                if (blob.store) |store| {
                    store.deref();
                }
            },
            .string_or_buffer => |*str| {
                str.deinit();
            },
        }
    }

    pub fn slice(this: *const BlobOrStringOrBuffer) []const u8 {
        return switch (this.*) {
            .blob => |*blob| blob.sharedView(),
            .string_or_buffer => |*str| str.slice(),
        };
    }

    pub fn fromJS(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue) ?BlobOrStringOrBuffer {
        if (value.as(JSC.WebCore.Blob)) |blob| {
            if (blob.store) |store| {
                store.ref();
            }
            return .{ .blob = blob.* };
        }
        return .{ .string_or_buffer = StringOrBuffer.fromJS(global, allocator, value) orelse return null };
    }

    pub fn fromJSWithEncodingValue(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding_value: JSC.JSValue) ?BlobOrStringOrBuffer {
        return fromJSWithEncodingValueMaybeAsync(global, allocator, value, encoding_value, false);
    }

    pub fn fromJSWithEncodingValueMaybeAsync(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding_value: JSC.JSValue, is_async: bool) ?BlobOrStringOrBuffer {
        if (value.as(JSC.WebCore.Blob)) |blob| {
            if (blob.store) |store| {
                store.ref();
            }
            return .{ .blob = blob.* };
        }
        return .{ .string_or_buffer = StringOrBuffer.fromJSWithEncodingValueMaybeAsync(global, allocator, value, encoding_value, is_async) orelse return null };
    }
};

pub const StringOrBuffer = union(enum) {
    string: bun.SliceWithUnderlyingString,
    threadsafe_string: bun.SliceWithUnderlyingString,
    encoded_slice: JSC.ZigString.Slice,
    buffer: Buffer,

    pub const empty = StringOrBuffer{ .encoded_slice = JSC.ZigString.Slice.empty };

    pub fn toThreadSafe(this: *@This()) void {
        switch (this.*) {
            .string => {
                this.string.toThreadSafe();
                this.* = .{
                    .threadsafe_string = this.string,
                };
            },
            .threadsafe_string => {},
            .encoded_slice => {},
            .buffer => {},
        }
    }

    pub fn fromJSToOwnedSlice(globalObject: *JSC.JSGlobalObject, value: JSC.JSValue, allocator: std.mem.Allocator) ![]u8 {
        if (value.asArrayBuffer(globalObject)) |array_buffer| {
            defer globalObject.vm().reportExtraMemory(array_buffer.len);

            return try allocator.dupe(u8, array_buffer.byteSlice());
        }

        const str = bun.String.tryFromJS(value, globalObject) orelse return error.JSError;
        defer str.deref();

        const result = try str.toOwnedSlice(allocator);
        defer globalObject.vm().reportExtraMemory(result.len);
        return result;
    }

    pub fn toJS(this: *StringOrBuffer, ctx: JSC.C.JSContextRef) JSC.JSValue {
        return switch (this.*) {
            inline .threadsafe_string, .string => |*str| {
                defer {
                    str.deinit();
                    str.* = .{};
                }

                return str.toJS(ctx);
            },
            .encoded_slice => {
                defer {
                    this.encoded_slice.deinit();
                    this.encoded_slice = .{};
                }

                const str = bun.String.createUTF8(this.encoded_slice.slice());
                defer str.deref();
                return str.toJS(ctx);
            },
            .buffer => {
                if (this.buffer.buffer.value != .zero) {
                    return this.buffer.buffer.value;
                }

                return this.buffer.toNodeBuffer(ctx);
            },
        };
    }

    pub fn slice(this: *const StringOrBuffer) []const u8 {
        return switch (this.*) {
            inline else => |*str| str.slice(),
        };
    }

    pub fn deinit(this: *const StringOrBuffer) void {
        switch (this.*) {
            inline .threadsafe_string, .string => |*str| {
                str.deinit();
            },
            .encoded_slice => |*encoded| {
                encoded.deinit();
            },
            else => {},
        }
    }

    pub fn deinitAndUnprotect(this: *const StringOrBuffer) void {
        switch (this.*) {
            inline .threadsafe_string, .string => |*str| {
                str.deinit();
            },
            .buffer => |buffer| {
                buffer.buffer.value.unprotect();
            },
            .encoded_slice => |*encoded| {
                encoded.deinit();
            },
        }
    }

    pub fn fromJSMaybeAsync(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, is_async: bool) ?StringOrBuffer {
        return switch (value.jsType()) {
            JSC.JSValue.JSType.String, JSC.JSValue.JSType.StringObject, JSC.JSValue.JSType.DerivedStringObject, JSC.JSValue.JSType.Object => {
                const str = bun.String.tryFromJS(value, global) orelse return null;

                if (is_async) {
                    defer str.deref();
                    var possible_clone = str;
                    var sliced = possible_clone.toThreadSafeSlice(allocator);
                    sliced.reportExtraMemory(global.vm());

                    if (sliced.underlying.isEmpty()) {
                        return StringOrBuffer{ .encoded_slice = sliced.utf8 };
                    }

                    return StringOrBuffer{ .threadsafe_string = sliced };
                } else {
                    return StringOrBuffer{ .string = str.toSlice(allocator) };
                }
            },

            .ArrayBuffer,
            .Int8Array,
            .Uint8Array,
            .Uint8ClampedArray,
            .Int16Array,
            .Uint16Array,
            .Int32Array,
            .Uint32Array,
            .Float32Array,
            .Float64Array,
            .BigInt64Array,
            .BigUint64Array,
            .DataView,
            => StringOrBuffer{
                .buffer = Buffer.fromArrayBuffer(global, value),
            },
            else => null,
        };
    }

    pub fn fromJS(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue) ?StringOrBuffer {
        return fromJSMaybeAsync(global, allocator, value, false);
    }

    pub fn fromJSWithEncoding(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding: Encoding) ?StringOrBuffer {
        return fromJSWithEncodingMaybeAsync(global, allocator, value, encoding, false);
    }

    pub fn fromJSWithEncodingMaybeAsync(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding: Encoding, is_async: bool) ?StringOrBuffer {
        if (value.isCell() and value.jsType().isTypedArray()) {
            return StringOrBuffer{
                .buffer = Buffer.fromTypedArray(global, value),
            };
        }

        if (encoding == .utf8) {
            return fromJSMaybeAsync(global, allocator, value, is_async);
        }

        var str = bun.String.tryFromJS(value, global) orelse return null;
        defer str.deref();
        if (str.isEmpty()) {
            return fromJSMaybeAsync(global, allocator, value, is_async);
        }

        const out = str.encode(encoding);
        defer global.vm().reportExtraMemory(out.len);

        return .{
            .encoded_slice = JSC.ZigString.Slice.init(bun.default_allocator, out),
        };
    }

    pub fn fromJSWithEncodingValue(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding_value: JSC.JSValue) ?StringOrBuffer {
        const encoding: Encoding = brk: {
            if (!encoding_value.isCell())
                break :brk .utf8;
            break :brk Encoding.fromJS(encoding_value, global) orelse .utf8;
        };

        return fromJSWithEncoding(global, allocator, value, encoding);
    }

    pub fn fromJSWithEncodingValueMaybeAsync(global: *JSC.JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, encoding_value: JSC.JSValue, maybe_async: bool) ?StringOrBuffer {
        const encoding: Encoding = brk: {
            if (!encoding_value.isCell())
                break :brk .utf8;
            break :brk Encoding.fromJS(encoding_value, global) orelse .utf8;
        };
        return fromJSWithEncodingMaybeAsync(global, allocator, value, encoding, maybe_async);
    }
};

pub const ErrorCode = @import("./nodejs_error_code.zig").Code;

// We can't really use Zig's error handling for syscalls because Node.js expects the "real" errno to be returned
// and various issues with std.posix that make it too unstable for arbitrary user input (e.g. how .BADF is marked as unreachable)

/// https://github.com/nodejs/node/blob/master/lib/buffer.js#L587
pub const Encoding = enum(u8) {
    utf8,
    ucs2,
    utf16le,
    latin1,
    ascii,
    base64,
    base64url,
    hex,

    /// Refer to the buffer's encoding
    buffer,

    pub const map = bun.ComptimeStringMap(Encoding, .{
        .{ "utf-8", Encoding.utf8 },
        .{ "utf8", Encoding.utf8 },
        .{ "ucs-2", Encoding.utf16le },
        .{ "ucs2", Encoding.utf16le },
        .{ "utf16-le", Encoding.utf16le },
        .{ "utf16le", Encoding.utf16le },
        .{ "binary", Encoding.latin1 },
        .{ "latin1", Encoding.latin1 },
        .{ "ascii", Encoding.ascii },
        .{ "base64", Encoding.base64 },
        .{ "hex", Encoding.hex },
        .{ "buffer", Encoding.buffer },
        .{ "base64url", Encoding.base64url },
    });

    pub fn isBinaryToText(this: Encoding) bool {
        return switch (this) {
            .hex, .base64, .base64url => true,
            else => false,
        };
    }

    /// Caller must verify the value is a string
    pub fn fromJS(value: JSC.JSValue, global: *JSC.JSGlobalObject) ?Encoding {
        return map.fromJSCaseInsensitive(global, value);
    }

    /// Caller must verify the value is a string
    pub fn from(slice: []const u8) ?Encoding {
        return strings.inMapCaseInsensitive(slice, map);
    }

    pub fn encodeWithSize(encoding: Encoding, globalObject: *JSC.JSGlobalObject, comptime size: usize, input: *const [size]u8) JSC.JSValue {
        switch (encoding) {
            .base64 => {
                var buf: [std.base64.standard.Encoder.calcSize(size)]u8 = undefined;
                const len = bun.base64.encode(&buf, input);
                return JSC.ZigString.init(buf[0..len]).toJS(globalObject);
            },
            .base64url => {
                var buf: [std.base64.url_safe_no_pad.Encoder.calcSize(size)]u8 = undefined;
                const encoded = std.base64.url_safe_no_pad.Encoder.encode(&buf, input);

                return JSC.ZigString.init(buf[0..encoded.len]).toJS(globalObject);
            },
            .hex => {
                var buf: [size * 4]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "{}", .{std.fmt.fmtSliceHexLower(input)}) catch bun.outOfMemory();
                const result = JSC.ZigString.init(out).toJS(globalObject);
                return result;
            },
            .buffer => {
                return JSC.ArrayBuffer.createBuffer(globalObject, input);
            },
            inline else => |enc| {
                const res = JSC.WebCore.Encoder.toString(input.ptr, size, globalObject, enc);
                if (res.isError()) {
                    globalObject.throwValue(res);
                    return .zero;
                }

                return res;
            },
        }
    }

    pub fn encodeWithMaxSize(encoding: Encoding, globalObject: *JSC.JSGlobalObject, comptime max_size: usize, input: []const u8) JSC.JSValue {
        switch (encoding) {
            .base64 => {
                var base64_buf: [std.base64.standard.Encoder.calcSize(max_size * 4)]u8 = undefined;
                const encoded_len = bun.base64.encode(&base64_buf, input);
                const encoded, const bytes = bun.String.createUninitialized(.latin1, encoded_len);
                defer encoded.deref();
                @memcpy(@constCast(bytes), base64_buf[0..encoded_len]);
                return encoded.toJS(globalObject);
            },
            .base64url => {
                var buf: [std.base64.url_safe_no_pad.Encoder.calcSize(max_size * 4)]u8 = undefined;
                const encoded = std.base64.url_safe_no_pad.Encoder.encode(&buf, input);

                return JSC.ZigString.init(buf[0..encoded.len]).toJS(globalObject);
            },
            .hex => {
                var buf: [max_size * 4]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "{}", .{std.fmt.fmtSliceHexLower(input)}) catch bun.outOfMemory();
                const result = JSC.ZigString.init(out).toJS(globalObject);
                return result;
            },
            .buffer => {
                return JSC.ArrayBuffer.createBuffer(globalObject, input);
            },
            inline else => |enc| {
                const res = JSC.WebCore.Encoder.toString(input.ptr, input.len, globalObject, enc);
                if (res.isError()) {
                    globalObject.throwValue(res);
                    return .zero;
                }

                return res;
            },
        }
    }
};

const PathOrBuffer = union(Tag) {
    path: bun.PathString,
    buffer: Buffer,

    pub const Tag = enum { path, buffer };

    pub inline fn slice(this: PathOrBuffer) []const u8 {
        return this.path.slice();
    }
};

pub fn CallbackTask(comptime Result: type) type {
    return struct {
        callback: JSC.C.JSObjectRef,
        option: Option,
        success: bool = false,

        pub const Option = union {
            err: JSC.SystemError,
            result: Result,
        };
    };
}

pub const PathLike = union(enum) {
    string: bun.PathString,
    buffer: Buffer,
    slice_with_underlying_string: bun.SliceWithUnderlyingString,
    threadsafe_string: bun.SliceWithUnderlyingString,
    encoded_slice: JSC.ZigString.Slice,

    pub fn estimatedSize(this: *const PathLike) usize {
        return switch (this.*) {
            .string => this.string.estimatedSize(),
            .buffer => this.buffer.slice().len,
            .threadsafe_string, .slice_with_underlying_string => 0,
            .encoded_slice => this.encoded_slice.slice().len,
        };
    }

    pub fn deinit(this: *const PathLike) void {
        switch (this.*) {
            .string, .buffer => {},
            inline else => |*str| {
                str.deinit();
            },
        }
    }

    pub fn toThreadSafe(this: *PathLike) void {
        switch (this.*) {
            .slice_with_underlying_string => {
                this.slice_with_underlying_string.toThreadSafe();
                this.* = .{
                    .threadsafe_string = this.slice_with_underlying_string,
                };
            },
            .buffer => {
                this.buffer.buffer.value.protect();
            },
            else => {},
        }
    }

    pub fn deinitAndUnprotect(this: *const PathLike) void {
        switch (this.*) {
            inline .encoded_slice, .threadsafe_string, .slice_with_underlying_string => |*val| {
                val.deinit();
            },
            .buffer => |val| {
                val.buffer.value.unprotect();
            },
            else => {},
        }
    }

    pub inline fn slice(this: PathLike) string {
        return switch (this) {
            inline else => |*str| str.slice(),
        };
    }

    pub fn sliceZWithForceCopy(this: PathLike, buf: *bun.PathBuffer, comptime force: bool) if (force) [:0]u8 else [:0]const u8 {
        const sliced = this.slice();

        if (Environment.isWindows) {
            if (std.fs.path.isAbsolute(sliced)) {
                return path_handler.PosixToWinNormalizer.resolveCWDWithExternalBufZ(buf, sliced) catch @panic("Error while resolving path.");
            }
        }

        if (sliced.len == 0) {
            if (comptime !force) return "";

            buf[0] = 0;
            return buf[0..0 :0];
        }

        if (comptime !force) {
            if (sliced[sliced.len - 1] == 0) {
                return sliced[0 .. sliced.len - 1 :0];
            }
        }

        @memcpy(buf[0..sliced.len], sliced);
        buf[sliced.len] = 0;
        return buf[0..sliced.len :0];
    }

    pub inline fn sliceZ(this: PathLike, buf: *bun.PathBuffer) [:0]const u8 {
        return sliceZWithForceCopy(this, buf, false);
    }

    pub inline fn sliceW(this: PathLike, buf: *bun.PathBuffer) [:0]const u16 {
        return strings.toWPath(@alignCast(std.mem.bytesAsSlice(u16, buf)), this.slice());
    }

    pub inline fn osPath(this: PathLike, buf: *bun.PathBuffer) bun.OSPathSliceZ {
        if (comptime Environment.isWindows) {
            return sliceW(this, buf);
        }

        return sliceZWithForceCopy(this, buf, false);
    }

    pub fn toJS(this: *const PathLike, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        return switch (this.*) {
            .string => this.string.toJS(globalObject, null),
            .buffer => this.buffer.toJS(globalObject),
            inline .threadsafe_string, .slice_with_underlying_string => |*str| str.toJS(globalObject),
            .encoded_slice => |encoded| {
                if (this.encoded_slice.allocator.get()) |allocator| {
                    // Is this a globally-allocated slice?
                    if (allocator.vtable == bun.default_allocator.vtable) {}
                }

                const str = bun.String.createUTF8(encoded.slice());
                defer str.deref();
                return str.toJS(globalObject);
            },
            else => unreachable,
        };
    }

    pub fn fromJS(ctx: JSC.C.JSContextRef, arguments: *ArgumentsSlice, exception: JSC.C.ExceptionRef) ?PathLike {
        return fromJSWithAllocator(ctx, arguments, bun.default_allocator, exception);
    }
    pub fn fromJSWithAllocator(ctx: JSC.C.JSContextRef, arguments: *ArgumentsSlice, allocator: std.mem.Allocator, exception: JSC.C.ExceptionRef) ?PathLike {
        const arg = arguments.next() orelse return null;
        switch (arg.jsType()) {
            JSC.JSValue.JSType.Uint8Array,
            JSC.JSValue.JSType.DataView,
            => {
                const buffer = Buffer.fromTypedArray(ctx, arg);
                if (exception.* != null) return null;
                if (!Valid.pathBuffer(buffer, ctx, exception)) return null;

                arguments.protectEat();
                return PathLike{ .buffer = buffer };
            },

            JSC.JSValue.JSType.ArrayBuffer => {
                const buffer = Buffer.fromArrayBuffer(ctx, arg);
                if (exception.* != null) return null;
                if (!Valid.pathBuffer(buffer, ctx, exception)) return null;

                arguments.protectEat();

                return PathLike{ .buffer = buffer };
            },

            JSC.JSValue.JSType.String,
            JSC.JSValue.JSType.StringObject,
            JSC.JSValue.JSType.DerivedStringObject,
            => {
                var str = arg.toBunString(ctx);
                defer str.deref();

                arguments.eat();

                if (!Valid.pathStringLength(str.length(), ctx, exception)) {
                    return null;
                }

                if (arguments.will_be_async) {
                    var sliced = str.toThreadSafeSlice(allocator);
                    sliced.reportExtraMemory(ctx.vm());

                    if (sliced.underlying.isEmpty()) {
                        return PathLike{ .encoded_slice = sliced.utf8 };
                    }

                    return PathLike{ .threadsafe_string = sliced };
                } else {
                    var sliced = str.toSlice(allocator);

                    // Costs nothing to keep both around.
                    if (sliced.isWTFAllocated()) {
                        str.ref();
                        return PathLike{ .slice_with_underlying_string = sliced };
                    }

                    sliced.reportExtraMemory(ctx.vm());

                    // It is expensive to keep both around.
                    return PathLike{ .encoded_slice = sliced.utf8 };
                }
            },
            else => {
                if (arg.as(JSC.DOMURL)) |domurl| {
                    var str: bun.String = domurl.fileSystemPath();
                    defer str.deref();
                    if (str.isEmpty()) {
                        JSC.throwInvalidArguments("URL must be a non-empty \"file:\" path", .{}, ctx, exception);
                        return null;
                    }
                    arguments.eat();

                    if (!Valid.pathStringLength(str.length(), ctx, exception)) {
                        return null;
                    }

                    if (arguments.will_be_async) {
                        var sliced = str.toThreadSafeSlice(allocator);
                        sliced.reportExtraMemory(ctx.vm());

                        if (sliced.underlying.isEmpty()) {
                            return PathLike{ .encoded_slice = sliced.utf8 };
                        }

                        return PathLike{ .threadsafe_string = sliced };
                    } else {
                        var sliced = str.toSlice(allocator);

                        // Costs nothing to keep both around.
                        if (sliced.isWTFAllocated()) {
                            str.ref();
                            return PathLike{ .slice_with_underlying_string = sliced };
                        }

                        sliced.reportExtraMemory(ctx.vm());

                        // It is expensive to keep both around.
                        return PathLike{ .encoded_slice = sliced.utf8 };
                    }
                }

                return null;
            },
        }
    }
};

pub const Valid = struct {
    pub fn fileDescriptor(fd: i64, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        if (fd < 0) {
            JSC.throwInvalidArguments("Invalid file descriptor, must not be negative number", .{}, ctx, exception);
            return false;
        }

        return true;
    }

    pub fn pathSlice(zig_str: JSC.ZigString.Slice, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        switch (zig_str.len) {
            0...bun.MAX_PATH_BYTES => return true,
            else => {
                // TODO: should this be an EINVAL?
                var system_error = bun.sys.Error.fromCode(.NAMETOOLONG, .open).withPath(zig_str.slice()).toSystemError();
                system_error.syscall = bun.String.dead;
                exception.* = system_error.toErrorInstance(ctx).asObjectRef();
                return false;
            },
        }

        unreachable;
    }

    pub fn pathStringLength(len: usize, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        switch (len) {
            0...bun.MAX_PATH_BYTES => return true,
            else => {
                // TODO: should this be an EINVAL?
                var system_error = bun.sys.Error.fromCode(.NAMETOOLONG, .open).toSystemError();
                system_error.syscall = bun.String.dead;
                exception.* = system_error.toErrorInstance(ctx).asObjectRef();
                return false;
            },
        }

        unreachable;
    }

    pub fn pathString(zig_str: JSC.ZigString, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        return pathStringLength(zig_str.len, ctx, exception);
    }

    pub fn pathBuffer(buffer: Buffer, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        const slice = buffer.slice();
        switch (slice.len) {
            0 => {
                JSC.throwInvalidArguments("Invalid path buffer: can't be empty", .{}, ctx, exception);
                return false;
            },

            else => {
                var system_error = bun.sys.Error.fromCode(.NAMETOOLONG, .open).toSystemError();
                system_error.syscall = bun.String.dead;
                exception.* = system_error.toErrorInstance(ctx).asObjectRef();
                return false;
            },
            1...bun.MAX_PATH_BYTES => return true,
        }

        unreachable;
    }
};

pub const VectorArrayBuffer = struct {
    value: JSC.JSValue,
    buffers: std.ArrayList(bun.PlatformIOVec),

    pub fn toJS(this: VectorArrayBuffer, _: *JSC.JSGlobalObject) JSC.JSValue {
        return this.value;
    }

    pub fn fromJS(globalObject: *JSC.JSGlobalObject, val: JSC.JSValue, exception: JSC.C.ExceptionRef, allocator: std.mem.Allocator) ?VectorArrayBuffer {
        if (!val.jsType().isArrayLike()) {
            JSC.throwInvalidArguments("Expected ArrayBufferView[]", .{}, globalObject, exception);
            return null;
        }

        var bufferlist = std.ArrayList(bun.PlatformIOVec).init(allocator);
        var i: usize = 0;
        const len = val.getLength(globalObject);
        bufferlist.ensureTotalCapacityPrecise(len) catch @panic("Failed to allocate memory for ArrayBuffer[]");

        while (i < len) {
            const element = val.getIndex(globalObject, @as(u32, @truncate(i)));

            if (!element.isCell()) {
                JSC.throwInvalidArguments("Expected ArrayBufferView[]", .{}, globalObject, exception);
                return null;
            }

            const array_buffer = element.asArrayBuffer(globalObject) orelse {
                JSC.throwInvalidArguments("Expected ArrayBufferView[]", .{}, globalObject, exception);
                return null;
            };

            const buf = array_buffer.byteSlice();
            bufferlist.append(bun.platformIOVecCreate(buf)) catch @panic("Failed to allocate memory for ArrayBuffer[]");
            i += 1;
        }

        return VectorArrayBuffer{ .value = val, .buffers = bufferlist };
    }
};

pub const ArgumentsSlice = struct {
    remaining: []const JSC.JSValue,
    vm: *JSC.VirtualMachine,
    arena: bun.ArenaAllocator = bun.ArenaAllocator.init(bun.default_allocator),
    all: []const JSC.JSValue,
    threw: bool = false,
    protected: std.bit_set.IntegerBitSet(32) = std.bit_set.IntegerBitSet(32).initEmpty(),
    will_be_async: bool = false,

    pub fn unprotect(this: *ArgumentsSlice) void {
        var iter = this.protected.iterator(.{});
        const ctx = this.vm.global;
        while (iter.next()) |i| {
            JSC.C.JSValueUnprotect(ctx, this.all[i].asObjectRef());
        }
        this.protected = std.bit_set.IntegerBitSet(32).initEmpty();
    }

    pub fn deinit(this: *ArgumentsSlice) void {
        this.unprotect();
        this.arena.deinit();
    }

    pub fn protectEat(this: *ArgumentsSlice) void {
        if (this.remaining.len == 0) return;
        const index = this.all.len - this.remaining.len;
        this.protected.set(index);
        JSC.C.JSValueProtect(this.vm.global, this.all[index].asObjectRef());
        this.eat();
    }

    pub fn protectEatNext(this: *ArgumentsSlice) ?JSC.JSValue {
        if (this.remaining.len == 0) return null;
        return this.nextEat();
    }

    pub fn from(vm: *JSC.VirtualMachine, arguments: []const JSC.JSValueRef) ArgumentsSlice {
        return init(vm, @as([*]const JSC.JSValue, @ptrCast(arguments.ptr))[0..arguments.len]);
    }
    pub fn init(vm: *JSC.VirtualMachine, arguments: []const JSC.JSValue) ArgumentsSlice {
        return ArgumentsSlice{
            .remaining = arguments,
            .vm = vm,
            .all = arguments,
            .arena = bun.ArenaAllocator.init(vm.allocator),
        };
    }

    pub fn initAsync(vm: *JSC.VirtualMachine, arguments: []const JSC.JSValue) ArgumentsSlice {
        return ArgumentsSlice{
            .remaining = bun.default_allocator.dupe(JSC.JSValue, arguments),
            .vm = vm,
            .all = arguments,
            .arena = bun.ArenaAllocator.init(bun.default_allocator),
        };
    }

    pub inline fn len(this: *const ArgumentsSlice) u16 {
        return @as(u16, @truncate(this.remaining.len));
    }
    pub fn eat(this: *ArgumentsSlice) void {
        if (this.remaining.len == 0) {
            return;
        }

        this.remaining = this.remaining[1..];
    }

    pub fn next(this: *ArgumentsSlice) ?JSC.JSValue {
        if (this.remaining.len == 0) {
            return null;
        }

        return this.remaining[0];
    }

    pub fn nextEat(this: *ArgumentsSlice) ?JSC.JSValue {
        if (this.remaining.len == 0) {
            return null;
        }
        defer this.eat();
        return this.remaining[0];
    }
};

pub fn fileDescriptorFromJS(ctx: JSC.C.JSContextRef, value: JSC.JSValue, exception: JSC.C.ExceptionRef) ?bun.FileDescriptor {
    return if (bun.FDImpl.fromJSValidated(value, ctx, exception) catch null) |fd|
        fd.encode()
    else
        null;
}

// Node.js docs:
// > Values can be either numbers representing Unix epoch time in seconds, Dates, or a numeric string like '123456789.0'.
// > If the value can not be converted to a number, or is NaN, Infinity, or -Infinity, an Error will be thrown.
pub fn timeLikeFromJS(globalObject: *JSC.JSGlobalObject, value: JSC.JSValue, _: JSC.C.ExceptionRef) ?TimeLike {
    if (value.jsType() == .JSDate) {
        const milliseconds = value.getUnixTimestamp();
        if (!std.math.isFinite(milliseconds)) {
            return null;
        }

        if (comptime Environment.isWindows) {
            return milliseconds / 1000.0;
        }

        return TimeLike{
            .tv_sec = @intFromFloat(@divFloor(milliseconds, std.time.ms_per_s)),
            .tv_nsec = @intFromFloat(@mod(milliseconds, std.time.ms_per_s) * std.time.ns_per_ms),
        };
    }

    if (!value.isNumber() and !value.isString()) {
        return null;
    }

    const seconds = value.coerce(f64, globalObject);
    if (!std.math.isFinite(seconds)) {
        return null;
    }

    if (comptime Environment.isWindows) {
        return seconds;
    }

    return TimeLike{
        .tv_sec = @intFromFloat(seconds),
        .tv_nsec = @intFromFloat(@mod(seconds, 1.0) * std.time.ns_per_s),
    };
}

pub fn modeFromJS(ctx: JSC.C.JSContextRef, value: JSC.JSValue, exception: JSC.C.ExceptionRef) ?Mode {
    const mode_int = if (value.isNumber())
        @as(Mode, @truncate(value.to(Mode)))
    else brk: {
        if (value.isUndefinedOrNull()) return null;

        //        An easier method of constructing the mode is to use a sequence of
        //        three octal digits (e.g. 765). The left-most digit (7 in the example),
        //        specifies the permissions for the file owner. The middle digit (6 in
        //        the example), specifies permissions for the group. The right-most
        //        digit (5 in the example), specifies the permissions for others.

        var zig_str = JSC.ZigString.Empty;
        value.toZigString(&zig_str, ctx.ptr());
        var slice = zig_str.slice();
        if (strings.hasPrefix(slice, "0o")) {
            slice = slice[2..];
        }

        break :brk std.fmt.parseInt(Mode, slice, 8) catch {
            JSC.throwInvalidArguments("Invalid mode string: must be an octal number", .{}, ctx, exception);
            return null;
        };
    };

    if (mode_int < 0) {
        JSC.throwInvalidArguments("Invalid mode: must be greater than or equal to 0.", .{}, ctx, exception);
        return null;
    }

    return mode_int & 0o777;
}

pub const PathOrFileDescriptor = union(Tag) {
    fd: bun.FileDescriptor,
    path: PathLike,

    pub const Tag = enum { fd, path };
    pub const SerializeTag = enum(u8) { fd, path };

    /// This will unref() the path string if it is a PathLike.
    /// Does nothing for file descriptors, **does not** close file descriptors.
    pub fn deinit(this: PathOrFileDescriptor) void {
        if (this == .path) {
            this.path.deinit();
        }
    }

    pub fn estimatedSize(this: *const PathOrFileDescriptor) usize {
        return switch (this.*) {
            .path => this.path.estimatedSize(),
            .fd => 0,
        };
    }

    pub fn toThreadSafe(this: *PathOrFileDescriptor) void {
        if (this.* == .path) {
            this.path.toThreadSafe();
        }
    }

    pub fn deinitAndUnprotect(this: PathOrFileDescriptor) void {
        if (this == .path) {
            this.path.deinitAndUnprotect();
        }
    }

    pub fn hash(this: JSC.Node.PathOrFileDescriptor) u64 {
        return switch (this) {
            .path => bun.hash(this.path.slice()),
            .fd => bun.hash(std.mem.asBytes(&this.fd)),
        };
    }

    pub fn format(this: JSC.Node.PathOrFileDescriptor, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0 and fmt[0] != 's') {
            @compileError("Unsupported format argument: '" ++ fmt ++ "'.");
        }
        switch (this) {
            .path => |p| try writer.writeAll(p.slice()),
            .fd => |fd| try writer.print("{}", .{fd}),
        }
    }

    pub fn fromJS(ctx: JSC.C.JSContextRef, arguments: *ArgumentsSlice, allocator: std.mem.Allocator, exception: JSC.C.ExceptionRef) ?JSC.Node.PathOrFileDescriptor {
        const first = arguments.next() orelse return null;

        if (bun.FDImpl.fromJSValidated(first, ctx, exception) catch return null) |fd| {
            arguments.eat();
            return JSC.Node.PathOrFileDescriptor{ .fd = fd.encode() };
        }

        return JSC.Node.PathOrFileDescriptor{
            .path = PathLike.fromJSWithAllocator(ctx, arguments, allocator, exception) orelse return null,
        };
    }

    pub fn toJS(this: JSC.Node.PathOrFileDescriptor, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        return switch (this) {
            .path => |path| path.toJS(ctx, exception),
            .fd => |fd| bun.FDImpl.decode(fd).toJS(),
        };
    }
};

pub const FileSystemFlags = enum(Mode) {
    /// Open file for appending. The file is created if it does not exist.
    a = bun.O.APPEND | bun.O.WRONLY | bun.O.CREAT,
    /// Like 'a' but fails if the path exists.
    // @"ax" = bun.O.APPEND | bun.O.EXCL,
    /// Open file for reading and appending. The file is created if it does not exist.
    // @"a+" = bun.O.APPEND | bun.O.RDWR,
    /// Like 'a+' but fails if the path exists.
    // @"ax+" = bun.O.APPEND | bun.O.RDWR | bun.O.EXCL,
    /// Open file for appending in synchronous mode. The file is created if it does not exist.
    // @"as" = bun.O.APPEND,
    /// Open file for reading and appending in synchronous mode. The file is created if it does not exist.
    // @"as+" = bun.O.APPEND | bun.O.RDWR,
    /// Open file for reading. An exception occurs if the file does not exist.
    r = bun.O.RDONLY,
    /// Open file for reading and writing. An exception occurs if the file does not exist.
    // @"r+" = bun.O.RDWR,
    /// Open file for reading and writing in synchronous mode. Instructs the operating system to bypass the local file system cache.
    /// This is primarily useful for opening files on NFS mounts as it allows skipping the potentially stale local cache. It has a very real impact on I/O performance so using this flag is not recommended unless it is needed.
    /// This doesn't turn fs.open() or fsPromises.open() into a synchronous blocking call. If synchronous operation is desired, something like fs.openSync() should be used.
    // @"rs+" = bun.O.RDWR,
    /// Open file for writing. The file is created (if it does not exist) or truncated (if it exists).
    w = bun.O.WRONLY | bun.O.CREAT,
    /// Like 'w' but fails if the path exists.
    // @"wx" = bun.O.WRONLY | bun.O.TRUNC,
    // ///  Open file for reading and writing. The file is created (if it does not exist) or truncated (if it exists).
    // @"w+" = bun.O.RDWR | bun.O.CREAT,
    // ///  Like 'w+' but fails if the path exists.
    // @"wx+" = bun.O.RDWR | bun.O.EXCL,

    _,

    const O_RDONLY: Mode = bun.O.RDONLY;
    const O_RDWR: Mode = bun.O.RDWR;
    const O_APPEND: Mode = bun.O.APPEND;
    const O_CREAT: Mode = bun.O.CREAT;
    const O_WRONLY: Mode = bun.O.WRONLY;
    const O_EXCL: Mode = bun.O.EXCL;
    const O_SYNC: Mode = 0;
    const O_TRUNC: Mode = bun.O.TRUNC;

    const map = bun.ComptimeStringMap(Mode, .{
        .{ "r", O_RDONLY },
        .{ "rs", O_RDONLY | O_SYNC },
        .{ "sr", O_RDONLY | O_SYNC },
        .{ "r+", O_RDWR },
        .{ "rs+", O_RDWR | O_SYNC },
        .{ "sr+", O_RDWR | O_SYNC },

        .{ "R", O_RDONLY },
        .{ "RS", O_RDONLY | O_SYNC },
        .{ "SR", O_RDONLY | O_SYNC },
        .{ "R+", O_RDWR },
        .{ "RS+", O_RDWR | O_SYNC },
        .{ "SR+", O_RDWR | O_SYNC },

        .{ "w", O_TRUNC | O_CREAT | O_WRONLY },
        .{ "wx", O_TRUNC | O_CREAT | O_WRONLY | O_EXCL },
        .{ "xw", O_TRUNC | O_CREAT | O_WRONLY | O_EXCL },

        .{ "W", O_TRUNC | O_CREAT | O_WRONLY },
        .{ "WX", O_TRUNC | O_CREAT | O_WRONLY | O_EXCL },
        .{ "XW", O_TRUNC | O_CREAT | O_WRONLY | O_EXCL },

        .{ "w+", O_TRUNC | O_CREAT | O_RDWR },
        .{ "wx+", O_TRUNC | O_CREAT | O_RDWR | O_EXCL },
        .{ "xw+", O_TRUNC | O_CREAT | O_RDWR | O_EXCL },

        .{ "W+", O_TRUNC | O_CREAT | O_RDWR },
        .{ "WX+", O_TRUNC | O_CREAT | O_RDWR | O_EXCL },
        .{ "XW+", O_TRUNC | O_CREAT | O_RDWR | O_EXCL },

        .{ "a", O_APPEND | O_CREAT | O_WRONLY },
        .{ "ax", O_APPEND | O_CREAT | O_WRONLY | O_EXCL },
        .{ "xa", O_APPEND | O_CREAT | O_WRONLY | O_EXCL },
        .{ "as", O_APPEND | O_CREAT | O_WRONLY | O_SYNC },
        .{ "sa", O_APPEND | O_CREAT | O_WRONLY | O_SYNC },

        .{ "A", O_APPEND | O_CREAT | O_WRONLY },
        .{ "AX", O_APPEND | O_CREAT | O_WRONLY | O_EXCL },
        .{ "XA", O_APPEND | O_CREAT | O_WRONLY | O_EXCL },
        .{ "AS", O_APPEND | O_CREAT | O_WRONLY | O_SYNC },
        .{ "SA", O_APPEND | O_CREAT | O_WRONLY | O_SYNC },

        .{ "a+", O_APPEND | O_CREAT | O_RDWR },
        .{ "ax+", O_APPEND | O_CREAT | O_RDWR | O_EXCL },
        .{ "xa+", O_APPEND | O_CREAT | O_RDWR | O_EXCL },
        .{ "as+", O_APPEND | O_CREAT | O_RDWR | O_SYNC },
        .{ "sa+", O_APPEND | O_CREAT | O_RDWR | O_SYNC },

        .{ "A+", O_APPEND | O_CREAT | O_RDWR },
        .{ "AX+", O_APPEND | O_CREAT | O_RDWR | O_EXCL },
        .{ "XA+", O_APPEND | O_CREAT | O_RDWR | O_EXCL },
        .{ "AS+", O_APPEND | O_CREAT | O_RDWR | O_SYNC },
        .{ "SA+", O_APPEND | O_CREAT | O_RDWR | O_SYNC },
    });

    pub fn fromJS(ctx: JSC.C.JSContextRef, val: JSC.JSValue, exception: JSC.C.ExceptionRef) ?FileSystemFlags {
        if (val.isNumber()) {
            const number = val.coerce(i32, ctx);
            return @as(FileSystemFlags, @enumFromInt(@as(Mode, @intCast(@max(number, 0)))));
        }

        const jsType = val.jsType();
        if (jsType.isStringLike()) {
            const str = val.getZigString(ctx);
            if (str.isEmpty()) {
                JSC.throwInvalidArguments(
                    "Expected flags to be a non-empty string. Learn more at https://nodejs.org/api/fs.html#fs_file_system_flags",
                    .{},
                    ctx,
                    exception,
                );
                return null;
            }
            // it's definitely wrong when the string is super long
            else if (str.len > 12) {
                JSC.throwInvalidArguments(
                    "Invalid flag '{any}'. Learn more at https://nodejs.org/api/fs.html#fs_file_system_flags",
                    .{str},
                    ctx,
                    exception,
                );
                return null;
            }

            const flags = brk: {
                switch (str.is16Bit()) {
                    inline else => |is_16bit| {
                        const chars = if (is_16bit) str.utf16SliceAligned() else str.slice();

                        if (std.ascii.isDigit(@as(u8, @truncate(chars[0])))) {
                            // node allows "0o644" as a string :(
                            if (is_16bit) {
                                const slice = str.toSlice(bun.default_allocator);
                                defer slice.deinit();

                                break :brk std.fmt.parseInt(Mode, slice.slice(), 10) catch null;
                            } else {
                                break :brk std.fmt.parseInt(Mode, chars, 10) catch null;
                            }
                        }
                    },
                }

                break :brk map.getWithEql(str, JSC.ZigString.eqlComptime);
            } orelse {
                JSC.throwInvalidArguments(
                    "Invalid flag '{any}'. Learn more at https://nodejs.org/api/fs.html#fs_file_system_flags",
                    .{str},
                    ctx,
                    exception,
                );
                return null;
            };

            return @as(FileSystemFlags, @enumFromInt(@as(Mode, @intCast(flags))));
        }

        return null;
    }
};

/// Stats and BigIntStats classes from node:fs
pub fn StatType(comptime Big: bool) type {
    const Int = if (Big) i64 else i32;
    const Float = if (Big) i64 else f64;
    const Timestamp = if (Big) u64 else u0;

    const Date = packed struct {
        value: Float,
        pub inline fn toJS(this: @This(), globalObject: *JSC.JSGlobalObject) JSC.JSValue {
            const milliseconds = JSC.JSValue.jsNumber(this.value);
            const array: [1]JSC.C.JSValueRef = .{milliseconds.asObjectRef()};
            return JSC.JSValue.c(JSC.C.JSObjectMakeDate(globalObject, 1, &array, null));
        }
    };

    return extern struct {
        pub usingnamespace if (Big) JSC.Codegen.JSBigIntStats else JSC.Codegen.JSStats;

        // Stats stores these as i32, but BigIntStats stores all of these as i64
        // On windows, these two need to be u64 as the numbers are often very large.
        dev: if (Environment.isWindows) u64 else Int,
        ino: if (Environment.isWindows) u64 else Int,
        mode: Int,
        nlink: Int,
        uid: Int,
        gid: Int,
        rdev: Int,
        blksize: Int,
        blocks: Int,

        // Always store size as a 64-bit integer
        size: i64,

        // _ms is either a float if Small, or a 64-bit integer if Big
        atime_ms: Float,
        mtime_ms: Float,
        ctime_ms: Float,
        birthtime_ms: Float,

        // _ns is a u64 storing nanosecond precision. it is a u0 when not BigIntStats
        atime_ns: Timestamp = 0,
        mtime_ns: Timestamp = 0,
        ctime_ns: Timestamp = 0,
        birthtime_ns: Timestamp = 0,

        const This = @This();

        const StatTimespec = if (Environment.isWindows) bun.windows.libuv.uv_timespec_t else std.posix.timespec;

        inline fn toNanoseconds(ts: StatTimespec) Timestamp {
            const tv_sec: i64 = @intCast(ts.tv_sec);
            const tv_nsec: i64 = @intCast(ts.tv_nsec);
            return @as(Timestamp, @intCast(tv_sec * 1_000_000_000)) + @as(Timestamp, @intCast(tv_nsec));
        }

        fn toTimeMS(ts: StatTimespec) Float {
            if (Big) {
                const tv_sec: i64 = @intCast(ts.tv_sec);
                const tv_nsec: i64 = @intCast(ts.tv_nsec);
                return @as(i64, @intCast(tv_sec * std.time.ms_per_s)) + @as(i64, @intCast(@divTrunc(tv_nsec, std.time.ns_per_ms)));
            } else {
                return (@as(f64, @floatFromInt(@max(ts.tv_sec, 0))) * std.time.ms_per_s) + (@as(f64, @floatFromInt(@as(usize, @intCast(@max(ts.tv_nsec, 0))))) / std.time.ns_per_ms);
            }
        }

        const PropertyGetter = fn (this: *This, globalObject: *JSC.JSGlobalObject) JSC.JSValue;

        fn getter(comptime field: meta.FieldEnum(This)) PropertyGetter {
            return struct {
                pub fn callback(this: *This, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
                    const value = @field(this, @tagName(field));
                    if (comptime (Big and @typeInfo(@TypeOf(value)) == .Int)) {
                        return JSC.JSValue.fromInt64NoTruncate(globalObject, @intCast(value));
                    }
                    return globalObject.toJS(value, .temporary);
                }
            }.callback;
        }

        fn dateGetter(comptime field: meta.FieldEnum(This)) PropertyGetter {
            return struct {
                pub fn callback(this: *This, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
                    const value = @field(this, @tagName(field));
                    // Doing `Date{ ... }` here shouldn't actually change the memory layout of `value`
                    // but it will tell comptime code how to convert the i64/f64 to a JS Date.
                    return globalObject.toJS(Date{ .value = value }, .temporary);
                }
            }.callback;
        }

        pub const isBlockDevice_ = JSC.wrapInstanceMethod(This, "isBlockDevice", false);
        pub const isCharacterDevice_ = JSC.wrapInstanceMethod(This, "isCharacterDevice", false);
        pub const isDirectory_ = JSC.wrapInstanceMethod(This, "isDirectory", false);
        pub const isFIFO_ = JSC.wrapInstanceMethod(This, "isFIFO", false);
        pub const isFile_ = JSC.wrapInstanceMethod(This, "isFile", false);
        pub const isSocket_ = JSC.wrapInstanceMethod(This, "isSocket", false);
        pub const isSymbolicLink_ = JSC.wrapInstanceMethod(This, "isSymbolicLink", false);

        pub const isBlockDevice_WithoutTypeChecks = domCall(.isBlockDevice);
        pub const isCharacterDevice_WithoutTypeChecks = domCall(.isCharacterDevice);
        pub const isDirectory_WithoutTypeChecks = domCall(.isDirectory);
        pub const isFIFO_WithoutTypeChecks = domCall(.isFIFO);
        pub const isFile_WithoutTypeChecks = domCall(.isFile);
        pub const isSocket_WithoutTypeChecks = domCall(.isSocket);
        pub const isSymbolicLink_WithoutTypeChecks = domCall(.isSymbolicLink);

        const DOMCallFn = fn (
            *This,
            *JSC.JSGlobalObject,
        ) callconv(JSC.conv) JSC.JSValue;
        fn domCall(comptime decl: meta.DeclEnum(This)) DOMCallFn {
            return struct {
                pub fn run(
                    this: *This,
                    _: *JSC.JSGlobalObject,
                ) callconv(JSC.conv) JSC.JSValue {
                    return @field(This, @tagName(decl))(this);
                }
            }.run;
        }

        pub const dev = getter(.dev);
        pub const ino = getter(.ino);
        pub const mode = getter(.mode);
        pub const nlink = getter(.nlink);
        pub const uid = getter(.uid);
        pub const gid = getter(.gid);
        pub const rdev = getter(.rdev);
        pub const size = getter(.size);
        pub const blksize = getter(.blksize);
        pub const blocks = getter(.blocks);
        pub const atime = dateGetter(.atime_ms);
        pub const mtime = dateGetter(.mtime_ms);
        pub const ctime = dateGetter(.ctime_ms);
        pub const birthtime = dateGetter(.birthtime_ms);
        pub const atimeMs = getter(.atime_ms);
        pub const mtimeMs = getter(.mtime_ms);
        pub const ctimeMs = getter(.ctime_ms);
        pub const birthtimeMs = getter(.birthtime_ms);
        pub const atimeNs = getter(.atime_ns);
        pub const mtimeNs = getter(.mtime_ns);
        pub const ctimeNs = getter(.ctime_ns);
        pub const birthtimeNs = getter(.birthtime_ns);

        inline fn modeInternal(this: *This) i32 {
            return @truncate(this.mode);
        }

        const S = if (Environment.isWindows) bun.C.S else posix.system.S;

        pub fn isBlockDevice(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISBLK(@intCast(this.modeInternal())));
        }

        pub fn isCharacterDevice(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISCHR(@intCast(this.modeInternal())));
        }

        pub fn isDirectory(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISDIR(@intCast(this.modeInternal())));
        }

        pub fn isFIFO(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISFIFO(@intCast(this.modeInternal())));
        }

        pub fn isFile(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(bun.isRegularFile(this.modeInternal()));
        }

        pub fn isSocket(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISSOCK(@intCast(this.modeInternal())));
        }

        /// Node.js says this method is only valid on the result of lstat()
        /// so it's fine if we just include it on stat() because it would
        /// still just return false.
        ///
        /// See https://nodejs.org/api/fs.html#statsissymboliclink
        pub fn isSymbolicLink(this: *This) JSC.JSValue {
            return JSC.JSValue.jsBoolean(S.ISLNK(@intCast(this.modeInternal())));
        }

        // TODO: BigIntStats includes a `_checkModeProperty` but I dont think anyone actually uses it.

        pub fn finalize(this: *This) callconv(.C) void {
            bun.destroy(this);
        }

        pub fn init(stat_: bun.Stat) This {
            const aTime = stat_.atime();
            const mTime = stat_.mtime();
            const cTime = stat_.ctime();

            return .{
                .dev = if (Environment.isWindows) stat_.dev else @truncate(@as(i64, @intCast(stat_.dev))),
                .ino = if (Environment.isWindows) stat_.ino else @truncate(@as(i64, @intCast(stat_.ino))),
                .mode = @truncate(@as(i64, @intCast(stat_.mode))),
                .nlink = @truncate(@as(i64, @intCast(stat_.nlink))),
                .uid = @truncate(@as(i64, @intCast(stat_.uid))),
                .gid = @truncate(@as(i64, @intCast(stat_.gid))),
                .rdev = @truncate(@as(i64, @intCast(stat_.rdev))),
                .size = @truncate(@as(i64, @intCast(stat_.size))),
                .blksize = @truncate(@as(i64, @intCast(stat_.blksize))),
                .blocks = @truncate(@as(i64, @intCast(stat_.blocks))),
                .atime_ms = toTimeMS(aTime),
                .mtime_ms = toTimeMS(mTime),
                .ctime_ms = toTimeMS(cTime),
                .atime_ns = if (Big) toNanoseconds(aTime) else 0,
                .mtime_ns = if (Big) toNanoseconds(mTime) else 0,
                .ctime_ns = if (Big) toNanoseconds(cTime) else 0,

                // Linux doesn't include this info in stat
                // maybe it does in statx, but do you really need birthtime? If you do please file an issue.
                .birthtime_ms = if (Environment.isLinux) 0 else toTimeMS(stat_.birthtime()),
                .birthtime_ns = if (Big and !Environment.isLinux) toNanoseconds(stat_.birthtime()) else 0,
            };
        }

        pub fn initWithAllocator(allocator: std.mem.Allocator, stat: bun.Stat) *This {
            const this = allocator.create(This) catch bun.outOfMemory();
            this.* = init(stat);
            return this;
        }

        pub fn constructor(globalObject: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) callconv(JSC.conv) ?*This {
            if (Big) {
                globalObject.throwInvalidArguments("BigIntStats is not a constructor", .{});
                return null;
            }

            // dev, mode, nlink, uid, gid, rdev, blksize, ino, size, blocks, atimeMs, mtimeMs, ctimeMs, birthtimeMs
            var args = callFrame.argumentsPtr()[0..@min(callFrame.argumentsCount(), 14)];

            const atime_ms: f64 = if (args.len > 10 and args[10].isNumber()) args[10].asNumber() else 0;
            const mtime_ms: f64 = if (args.len > 11 and args[11].isNumber()) args[11].asNumber() else 0;
            const ctime_ms: f64 = if (args.len > 12 and args[12].isNumber()) args[12].asNumber() else 0;
            const birthtime_ms: f64 = if (args.len > 13 and args[13].isNumber()) args[13].asNumber() else 0;

            const this = bun.new(This, .{
                .dev = if (args.len > 0 and args[0].isNumber()) @intCast(args[0].toInt32()) else 0,
                .mode = if (args.len > 1 and args[1].isNumber()) args[1].toInt32() else 0,
                .nlink = if (args.len > 2 and args[2].isNumber()) args[2].toInt32() else 0,
                .uid = if (args.len > 3 and args[3].isNumber()) args[3].toInt32() else 0,
                .gid = if (args.len > 4 and args[4].isNumber()) args[4].toInt32() else 0,
                .rdev = if (args.len > 5 and args[5].isNumber()) args[5].toInt32() else 0,
                .blksize = if (args.len > 6 and args[6].isNumber()) args[6].toInt32() else 0,
                .ino = if (args.len > 7 and args[7].isNumber()) @intCast(args[7].toInt32()) else 0,
                .size = if (args.len > 8 and args[8].isNumber()) args[8].toInt32() else 0,
                .blocks = if (args.len > 9 and args[9].isNumber()) args[9].toInt32() else 0,
                .atime_ms = atime_ms,
                .mtime_ms = mtime_ms,
                .ctime_ms = ctime_ms,
                .birthtime_ms = birthtime_ms,
            });

            return this;
        }

        comptime {
            _ = isBlockDevice_WithoutTypeChecks;
            _ = isCharacterDevice_WithoutTypeChecks;
            _ = isDirectory_WithoutTypeChecks;
            _ = isFIFO_WithoutTypeChecks;
            _ = isFile_WithoutTypeChecks;
            _ = isSocket_WithoutTypeChecks;
            _ = isSymbolicLink_WithoutTypeChecks;
        }
    };
}

pub const StatsSmall = StatType(false);
pub const StatsBig = StatType(true);

/// Union between `Stats` and `BigIntStats` where the type can be decided at runtime
pub const Stats = union(enum) {
    big: StatsBig,
    small: StatsSmall,

    pub inline fn init(stat_: bun.Stat, big: bool) Stats {
        if (big) {
            return .{ .big = StatsBig.init(stat_) };
        } else {
            return .{ .small = StatsSmall.init(stat_) };
        }
    }

    pub fn toJSNewlyCreated(this: *const Stats, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        return switch (this.*) {
            .big => bun.new(StatsBig, this.big).toJS(globalObject),
            .small => bun.new(StatsSmall, this.small).toJS(globalObject),
        };
    }

    pub inline fn toJS(this: *Stats, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        _ = this;
        _ = globalObject;

        @compileError("Only use Stats.toJSNewlyCreated() or Stats.toJS() directly on a StatsBig or StatsSmall");
    }
};

/// A class representing a directory stream.
///
/// Created by {@link opendir}, {@link opendirSync}, or `fsPromises.opendir()`.
///
/// ```js
/// import { opendir } from 'fs/promises';
///
/// try {
///   const dir = await opendir('./');
///   for await (const dirent of dir)
///     console.log(dirent.name);
/// } catch (err) {
///   console.error(err);
/// }
/// ```
///
/// When using the async iterator, the `fs.Dir` object will be automatically
/// closed after the iterator exits.
/// @since v12.12.0
pub const Dirent = struct {
    name: bun.String,
    path: bun.String,
    // not publicly exposed
    kind: Kind,

    pub const Kind = std.fs.File.Kind;
    pub usingnamespace JSC.Codegen.JSDirent;

    pub fn constructor(globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) callconv(JSC.conv) ?*Dirent {
        globalObject.throw("Dirent is not a constructor", .{});
        return null;
    }

    pub fn toJSNewlyCreated(this: *const Dirent, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        var out = bun.new(Dirent, this.*);
        return out.toJS(globalObject);
    }

    pub fn getName(this: *Dirent, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        return this.name.toJS(globalObject);
    }

    pub fn getPath(this: *Dirent, globalThis: *JSC.JSGlobalObject) JSC.JSValue {
        return this.path.toJS(globalThis);
    }

    pub fn isBlockDevice(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.block_device);
    }
    pub fn isCharacterDevice(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.character_device);
    }
    pub fn isDirectory(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.directory);
    }
    pub fn isFIFO(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.named_pipe or this.kind == std.fs.File.Kind.event_port);
    }
    pub fn isFile(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.file);
    }
    pub fn isSocket(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.unix_domain_socket);
    }
    pub fn isSymbolicLink(
        this: *Dirent,
        _: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) JSC.JSValue {
        return JSC.JSValue.jsBoolean(this.kind == std.fs.File.Kind.sym_link);
    }

    pub fn deref(this: *const Dirent) void {
        this.name.deref();
        this.path.deref();
    }

    pub fn finalize(this: *Dirent) callconv(.C) void {
        this.deref();
        bun.destroy(this);
    }
};

pub const Emitter = struct {
    pub const Listener = struct {
        once: bool = false,
        callback: JSC.JSValue,

        pub const List = struct {
            pub const ArrayList = std.MultiArrayList(Listener);
            list: ArrayList = ArrayList{},
            once_count: u32 = 0,

            pub fn append(this: *List, allocator: std.mem.Allocator, ctx: JSC.C.JSContextRef, listener: Listener) !void {
                JSC.C.JSValueProtect(ctx, listener.callback.asObjectRef());
                try this.list.append(allocator, listener);
                this.once_count +|= @as(u32, @intFromBool(listener.once));
            }

            pub fn prepend(this: *List, allocator: std.mem.Allocator, ctx: JSC.C.JSContextRef, listener: Listener) !void {
                JSC.C.JSValueProtect(ctx, listener.callback.asObjectRef());
                try this.list.ensureUnusedCapacity(allocator, 1);
                this.list.insertAssumeCapacity(0, listener);
                this.once_count +|= @as(u32, @intFromBool(listener.once));
            }

            // removeListener() will remove, at most, one instance of a listener from the
            // listener array. If any single listener has been added multiple times to the
            // listener array for the specified eventName, then removeListener() must be
            // called multiple times to remove each instance.
            pub fn remove(this: *List, ctx: JSC.C.JSContextRef, callback: JSC.JSValue) bool {
                const callbacks = this.list.items(.callback);

                for (callbacks, 0..) |item, i| {
                    if (callback.eqlValue(item)) {
                        JSC.C.JSValueUnprotect(ctx, callback.asObjectRef());
                        this.once_count -|= @as(u32, @intFromBool(this.list.items(.once)[i]));
                        this.list.orderedRemove(i);
                        return true;
                    }
                }

                return false;
            }

            pub fn emit(this: *List, globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) void {
                var i: usize = 0;
                outer: while (true) {
                    var slice = this.list.slice();
                    var callbacks = slice.items(.callback);
                    var once = slice.items(.once);
                    while (i < callbacks.len) : (i += 1) {
                        const callback = callbacks[i];

                        globalObject.enqueueMicrotask1(
                            callback,
                            value,
                        );

                        if (once[i]) {
                            this.once_count -= 1;
                            JSC.C.JSValueUnprotect(globalObject, callback.asObjectRef());
                            this.list.orderedRemove(i);
                            slice = this.list.slice();
                            callbacks = slice.items(.callback);
                            once = slice.items(.once);
                            continue :outer;
                        }
                    }

                    return;
                }
            }
        };
    };

    pub fn New(comptime EventType: type) type {
        return struct {
            const EventEmitter = @This();
            pub const Map = std.enums.EnumArray(EventType, Listener.List);
            listeners: Map = Map.initFill(Listener.List{}),

            pub fn addListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, listener: Emitter.Listener) !void {
                try this.listeners.getPtr(event).append(bun.default_allocator, ctx, listener);
            }

            pub fn prependListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, listener: Emitter.Listener) !void {
                try this.listeners.getPtr(event).prepend(bun.default_allocator, ctx, listener);
            }

            pub fn emit(this: *EventEmitter, event: EventType, globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) void {
                this.listeners.getPtr(event).emit(globalObject, value);
            }

            pub fn removeListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, callback: JSC.JSValue) bool {
                return this.listeners.getPtr(event).remove(ctx, callback);
            }
        };
    }
};

pub const Process = struct {
    pub fn getArgv0(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        return JSC.ZigString.fromUTF8(bun.argv[0]).toJS(globalObject);
    }

    pub fn getExecPath(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        const out = bun.selfExePath() catch {
            // if for any reason we are unable to get the executable path, we just return argv[0]
            return getArgv0(globalObject);
        };

        return JSC.ZigString.fromUTF8(out).toJS(globalObject);
    }

    pub fn getExecArgv(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        var sfb = std.heap.stackFallback(4096, globalObject.allocator());
        const temp_alloc = sfb.get();
        const vm = globalObject.bunVM();

        if (vm.worker) |worker| {
            // was explicitly overridden for the worker?
            if (worker.execArgv) |execArgv| {
                const array = JSC.JSValue.createEmptyArray(globalObject, execArgv.len);
                for (0..execArgv.len) |i| {
                    array.putIndex(globalObject, @intCast(i), bun.String.init(execArgv[i]).toJS(globalObject));
                }
                return array;
            }
        }

        var args = std.ArrayList(bun.String).initCapacity(temp_alloc, bun.argv.len - 1) catch bun.outOfMemory();
        defer args.deinit();

        var seen_run = false;
        var prev: ?[]const u8 = null;

        // we re-parse the process argv to extract execArgv, since this is a very uncommon operation
        // it isn't worth doing this as a part of the CLI
        for (bun.argv[@min(1, bun.argv.len)..]) |arg| {
            defer prev = arg;

            if (arg.len >= 1 and arg[0] == '-') {
                args.append(bun.String.createUTF8(arg)) catch bun.outOfMemory();
                continue;
            }

            if (!seen_run and bun.strings.eqlComptime(arg, "run")) {
                seen_run = true;
                continue;
            }

            // A set of execArgv args consume an extra argument, so we do not want to
            // confuse these with script names.
            const map = bun.ComptimeStringMap(void, comptime brk: {
                const auto_params = bun.CLI.Arguments.auto_params;
                const KV = struct { []const u8, void };
                var entries: [auto_params.len]KV = undefined;
                var i = 0;
                for (auto_params) |param| {
                    if (param.takes_value != .none) {
                        if (param.names.long) |name| {
                            entries[i] = .{ "--" ++ name, {} };
                            i += 1;
                        }
                        if (param.names.short) |name| {
                            entries[i] = .{ &[_]u8{ '-', name }, {} };
                            i += 1;
                        }
                    }
                }

                var result: [i]KV = undefined;
                @memcpy(&result, entries[0..i]);
                break :brk result;
            });

            if (prev) |p| if (map.has(p)) {
                args.append(bun.String.createUTF8(arg)) catch @panic("OOM");
                continue;
            };

            // we hit the script name
            break;
        }

        return bun.String.toJSArray(globalObject, args.items);
    }

    pub fn getArgv(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        const vm = globalObject.bunVM();

        // Allocate up to 32 strings in stack
        var stack_fallback_allocator = std.heap.stackFallback(
            32 * @sizeOf(JSC.ZigString) + (bun.MAX_PATH_BYTES + 1) + 32,
            heap_allocator,
        );
        const allocator = stack_fallback_allocator.get();

        var args_count: usize = vm.argv.len;
        if (vm.worker) |worker| {
            args_count = if (worker.argv) |argv| argv.len else 0;
        }

        const args = allocator.alloc(
            bun.String,
            // argv omits "bun" because it could be "bun run" or "bun" and it's kind of ambiguous
            // argv also omits the script name
            args_count + 2,
        ) catch bun.outOfMemory();
        var args_list = std.ArrayListUnmanaged(bun.String){ .items = args, .capacity = args.len };
        args_list.items.len = 0;

        if (vm.standalone_module_graph != null) {
            // Don't break user's code because they did process.argv.slice(2)
            // Even if they didn't type "bun", we still want to add it as argv[0]
            args_list.appendAssumeCapacity(
                bun.String.static("bun"),
            );
        } else {
            const exe_path = bun.selfExePath() catch null;
            args_list.appendAssumeCapacity(
                if (exe_path) |str| bun.String.fromUTF8(str) else bun.String.static("bun"),
            );
        }

        if (vm.main.len > 0)
            args_list.appendAssumeCapacity(bun.String.fromUTF8(vm.main));

        defer allocator.free(args);

        if (vm.worker) |worker| {
            if (worker.argv) |argv| {
                for (argv) |arg| {
                    args_list.appendAssumeCapacity(bun.String.init(arg));
                }
            }
        } else {
            for (vm.argv) |arg| {
                const str = bun.String.fromUTF8(arg);
                // https://github.com/yargs/yargs/blob/adb0d11e02c613af3d9427b3028cc192703a3869/lib/utils/process-argv.ts#L1
                args_list.appendAssumeCapacity(str);
            }
        }

        return bun.String.toJSArray(globalObject, args_list.items);
    }

    pub fn getCwd(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        var buf: bun.PathBuffer = undefined;
        return switch (Path.getCwd(&buf)) {
            .result => |r| JSC.ZigString.init(r).withEncoding().toJS(globalObject),
            .err => |e| e.toJSC(globalObject),
        };
    }

    pub fn setCwd(globalObject: *JSC.JSGlobalObject, to: *JSC.ZigString) callconv(.C) JSC.JSValue {
        if (to.len == 0) {
            return JSC.toInvalidArguments("path is required", .{}, globalObject.ref());
        }

        var buf: bun.PathBuffer = undefined;
        const slice = to.sliceZBuf(&buf) catch {
            return JSC.toInvalidArguments("Invalid path", .{}, globalObject.ref());
        };

        switch (Syscall.chdir(slice)) {
            .result => {
                // When we update the cwd from JS, we have to update the bundler's version as well
                // However, this might be called many times in a row, so we use a pre-allocated buffer
                // that way we don't have to worry about garbage collector
                const fs = JSC.VirtualMachine.get().bundler.fs;
                fs.top_level_dir = switch (Path.getCwd(&fs.top_level_dir_buf)) {
                    .result => |r| r,
                    .err => {
                        _ = Syscall.chdir(@as([:0]const u8, @ptrCast(fs.top_level_dir)));
                        return JSC.toInvalidArguments("Invalid path", .{}, globalObject.ref());
                    },
                };

                const len = fs.top_level_dir.len;
                fs.top_level_dir_buf[len] = std.fs.path.sep;
                fs.top_level_dir_buf[len + 1] = 0;
                fs.top_level_dir = fs.top_level_dir_buf[0 .. len + 1];

                return JSC.JSValue.jsUndefined();
            },
            .err => |e| return e.toJSC(globalObject),
        }
    }

    pub fn exit(globalObject: *JSC.JSGlobalObject, code: u8) callconv(.C) void {
        var vm = globalObject.bunVM();
        if (vm.worker) |worker| {
            vm.exit_handler.exit_code = code;
            worker.requestTerminate();
            return;
        }

        vm.onExit();
        bun.Global.exit(code);
    }

    pub export const Bun__version: [*:0]const u8 = "v" ++ bun.Global.package_json_version;
    pub export const Bun__versions_boringssl: [*:0]const u8 = bun.Global.versions.boringssl;
    pub export const Bun__versions_libarchive: [*:0]const u8 = bun.Global.versions.libarchive;
    pub export const Bun__versions_mimalloc: [*:0]const u8 = bun.Global.versions.mimalloc;
    pub export const Bun__versions_picohttpparser: [*:0]const u8 = bun.Global.versions.picohttpparser;
    pub export const Bun__versions_uws: [*:0]const u8 = bun.Environment.git_sha;
    pub export const Bun__versions_webkit: [*:0]const u8 = bun.Global.versions.webkit;
    pub export const Bun__versions_zig: [*:0]const u8 = bun.Global.versions.zig;
    pub export const Bun__versions_zlib: [*:0]const u8 = bun.Global.versions.zlib;
    pub export const Bun__versions_tinycc: [*:0]const u8 = bun.Global.versions.tinycc;
    pub export const Bun__versions_lolhtml: [*:0]const u8 = bun.Global.versions.lolhtml;
    pub export const Bun__versions_c_ares: [*:0]const u8 = bun.Global.versions.c_ares;
    pub export const Bun__versions_usockets: [*:0]const u8 = bun.Environment.git_sha;
    pub export const Bun__version_sha: [*:0]const u8 = bun.Environment.git_sha;
    pub export const Bun__versions_lshpack: [*:0]const u8 = bun.Global.versions.lshpack;
    pub export const Bun__versions_zstd: [*:0]const u8 = bun.Global.versions.zstd;
};

comptime {
    std.testing.refAllDecls(Process);
}
