// Thin wrapper around Flecs ECS (via zflecs bindings).
//
// Provides a Zig-idiomatic interface to the Flecs world lifecycle and
// common operations. Game code should use this wrapper instead of calling
// zflecs directly for core operations. Raw zflecs access is re-exported
// for advanced use (system registration, queries, etc.).
//
// Design:
//   - Single-threaded by default. Threading is a future optimization.
//   - Assert-heavy lifecycle management.
//   - EntityId (u64) is the same type as zflecs entity_t.
//   - Raw zflecs bindings are re-exported as World.zflecs for advanced use.

const std = @import("std");
const types = @import("types/root.zig");
const EntityId = types.EntityId;

/// A wrapped Flecs world instance.
///
/// Invariants:
///   - Exactly one init() call must be paired with one deinit() call.
///   - All operations between init and deinit are valid.
///   - Single-threaded: do not call from multiple threads.
pub const World = struct {
    raw: *zflecs.world_t,
    /// True while an each/eachChunk/eachN iteration is active.
    /// Used to assert that callbacks do not mutate the world (nested iteration
    /// or structural changes invalidate the Flecs iterator).
    is_iterating: bool = false,

    /// Re-export raw zflecs bindings for advanced use (observers, queries,
    /// custom iterators). Prefer World methods for common operations.
    pub const zflecs = @import("zflecs");

    /// Create a new Flecs world, configured for single-threaded deterministic
    /// simulation. The world must be destroyed with deinit().
    pub fn init() World {
        const raw = zflecs.init();
        // Enforce single-threaded execution for determinism.
        zflecs.set_threads(raw, 1);
        return .{ .raw = raw };
    }

    /// Destroy the world and release all resources.
    /// All entity and component pointers are invalidated.
    pub fn deinit(self: *World) void {
        _ = zflecs.fini(self.raw);
        self.raw = undefined;
    }

    /// Advance the simulation by delta_time seconds.
    /// Runs all registered systems in phase order.
    /// Returns true if the application should continue running.
    pub fn progress(self: *World, delta_time: f32) bool {
        return zflecs.progress(self.raw, delta_time);
    }

    /// Register a component type with the world. Must be called before
    /// any set/get/add operations using this type. Idempotent - safe
    /// to call multiple times for the same type.
    pub fn registerComponent(self: *World, comptime T: type) void {
        zflecs.COMPONENT(self.raw, T);
    }

    /// Register a zero-sized tag type with the world.
    pub fn registerTag(self: *World, comptime T: type) void {
        zflecs.TAG(self.raw, T);
    }

    /// Create a new empty entity. Returns its EntityId.
    pub fn newEntity(self: *World) EntityId {
        return zflecs.new_id(self.raw);
    }

    /// Delete an entity and all its components.
    pub fn deleteEntity(self: *World, entity: EntityId) void {
        std.debug.assert(types.entity_id_valid(entity));
        zflecs.delete(self.raw, entity);
    }

    /// Set a component value on an entity. Registers the component type
    /// if not already registered.
    pub fn setComponent(
        self: *World,
        entity: EntityId,
        comptime T: type,
        val: T,
    ) void {
        std.debug.assert(types.entity_id_valid(entity));
        _ = zflecs.set(self.raw, entity, T, val);
    }

    /// Get a read-only pointer to a component on an entity.
    /// Returns null if the entity does not have this component.
    pub fn getComponent(
        self: *World,
        entity: EntityId,
        comptime T: type,
    ) ?*const T {
        std.debug.assert(types.entity_id_valid(entity));
        return zflecs.get(self.raw, entity, T);
    }

    /// Get a mutable pointer to a component on an entity.
    /// Returns null if the entity does not have this component.
    pub fn getComponentMut(
        self: *World,
        entity: EntityId,
        comptime T: type,
    ) ?*T {
        std.debug.assert(types.entity_id_valid(entity));
        return zflecs.get_mut(self.raw, entity, T);
    }

    /// Check if an entity is alive (not deleted or recycled).
    pub fn isAlive(self: *World, entity: EntityId) bool {
        return zflecs.is_alive(self.raw, entity);
    }

    // -----------------------------------------------------------------
    // System registration
    // -----------------------------------------------------------------

    /// Simulation phases for system scheduling.
    /// Systems within a phase execute in registration order (deterministic).
    pub const Phase = enum {
        pre_update,
        on_update,
        on_validate,
        post_update,
    };

    /// Register a system function in the given phase.
    /// Returns the system entity ID.
    pub fn addSystem(
        self: *World,
        name: [*:0]const u8,
        phase: Phase,
        comptime system_fn: anytype,
    ) EntityId {
        const phase_entity: zflecs.entity_t = switch (phase) {
            .pre_update => zflecs.PreUpdate,
            .on_update => zflecs.OnUpdate,
            .on_validate => zflecs.OnValidate,
            .post_update => zflecs.PostUpdate,
        };
        return zflecs.ADD_SYSTEM(self.raw, name, phase_entity, system_fn);
    }

    // -----------------------------------------------------------------
    // Prefabs and relationships
    // -----------------------------------------------------------------

    /// Create a named prefab entity. Returns its EntityId.
    pub fn newPrefab(self: *World, name: [*:0]const u8) EntityId {
        return zflecs.new_prefab(self.raw, name);
    }

    /// Add an IsA relationship: `entity` inherits from `base`.
    pub fn addIsA(self: *World, entity: EntityId, base: EntityId) void {
        std.debug.assert(types.entity_id_valid(entity));
        std.debug.assert(types.entity_id_valid(base));
        zflecs.add_pair(self.raw, entity, zflecs.IsA, base);
    }

    /// Iterate all entities that have component T, calling cb once per archetype chunk.
    ///
    /// The callback receives full entity and component slices for each chunk, enabling
    /// SoA-style processing. Prefab archetypes are excluded at query level so the
    /// callback is never invoked for prefab entities.
    ///
    /// Precondition: T must be registered via registerComponent before calling.
    /// Precondition: cb must not mutate the world (no setComponent/newEntity/deleteEntity).
    pub fn eachChunk(
        self: *World,
        comptime T: type,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, entities: []const EntityId, comps: []const T) void,
    ) void {
        std.debug.assert(!self.is_iterating);
        self.is_iterating = true;
        defer self.is_iterating = false;
        var desc: zflecs.query_desc_t = .{};
        desc.terms[0] = .{ .id = zflecs.id(T) };
        desc.terms[1] = .{ .id = zflecs.Prefab, .oper = .Not };
        const query = zflecs.query_init(self.raw, &desc) catch @panic("eachChunk: query_init failed");
        defer zflecs.query_fini(query);
        var it = zflecs.query_iter(self.raw, query);
        while (zflecs.query_next(&it)) {
            const comps = zflecs.field(&it, T, 0) orelse continue;
            const ents = it.entities();
            std.debug.assert(comps.len == ents.len);
            cb(ctx, ents, comps);
        }
    }

    /// Iterate all entities that have component T, calling cb for each entity.
    ///
    /// ctx is passed through to cb unchanged - use a pointer to local state
    /// to capture variables without heap allocation. Prefab entities are
    /// excluded at query level and will not be visited.
    ///
    /// Delegates to eachChunk internally. Prefer eachChunk for hot paths where
    /// SoA slice processing or autovectorization is beneficial.
    pub fn each(
        self: *World,
        comptime T: type,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, entity: EntityId, comp: *const T) void,
    ) void {
        const Wrapper = struct {
            inner_ctx: *anyopaque,
            inner_cb: *const fn (*anyopaque, EntityId, *const T) void,
        };
        var wrapper = Wrapper{ .inner_ctx = ctx, .inner_cb = cb };
        self.eachChunk(T, @ptrCast(&wrapper), struct {
            fn run(raw: *anyopaque, entities: []const EntityId, comps: []const T) void {
                const w: *Wrapper = @ptrCast(@alignCast(raw));
                for (entities, comps) |entity, *comp| {
                    w.inner_cb(w.inner_ctx, entity, comp);
                }
            }
        }.run);
    }

    /// Iterate all entities that have ALL listed components, calling cb once per chunk.
    ///
    /// ChunkTuple(Components) is a struct of []const T slices, one per component type.
    /// Access them as chunks.Health, chunks.Position, etc. (field names derived from
    /// the component type name). Prefab entities and entities missing any component
    /// are excluded at query level.
    ///
    /// Precondition: all types in Components are registered via registerComponent.
    /// Precondition: cb must not mutate the world (no setComponent/newEntity/deleteEntity).
    pub fn eachN(
        self: *World,
        comptime Components: []const type,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, entities: []const EntityId, chunks: ChunkTuple(Components)) void,
    ) void {
        std.debug.assert(!self.is_iterating);
        self.is_iterating = true;
        defer self.is_iterating = false;
        var desc: zflecs.query_desc_t = .{};
        inline for (Components, 0..) |T, i| {
            desc.terms[i] = .{ .id = zflecs.id(T) };
        }
        desc.terms[Components.len] = .{ .id = zflecs.Prefab, .oper = .Not };
        const query = zflecs.query_init(self.raw, &desc) catch @panic("eachN: query_init failed");
        defer zflecs.query_fini(query);
        var it = zflecs.query_iter(self.raw, query);
        while (zflecs.query_next(&it)) {
            const ents = it.entities();
            var chunks: ChunkTuple(Components) = undefined;
            var valid = true;
            inline for (Components, 0..) |T, i| {
                const fname = comptime typeBaseName(T);
                if (zflecs.field(&it, T, i)) |slice| {
                    @field(chunks, fname) = slice;
                } else {
                    valid = false;
                }
            }
            if (!valid) continue;
            std.debug.assert(ents.len == @field(chunks, typeBaseName(Components[0])).len);
            cb(ctx, ents, chunks);
        }
    }
};

// ============================================================================
// ChunkTuple
// ============================================================================

/// Comptime-generated struct of component slices for eachN callbacks.
/// ChunkTuple(&[_]type{A, B}) produces a struct with fields A: []const A, B: []const B
/// (field names derived from the component type name).
/// Access via chunks.Health, chunks.Position, etc.
pub fn ChunkTuple(comptime Components: []const type) type {
    comptime var fields: [Components.len]std.builtin.Type.StructField = undefined;
    comptime {
        for (Components, 0..) |T, i| {
            fields[i] = .{
                .name = typeBaseName(T),
                .type = []const T,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf([]const T),
            };
        }
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Extracts the base type name (after the last '.') from a fully qualified type.
/// e.g., typeBaseName(components.Health) returns "Health".
fn typeBaseName(comptime T: type) [:0]const u8 {
    const full = @typeName(T);
    comptime var i = full.len;
    while (i > 0) {
        i -= 1;
        if (full[i] == '.') return full[i + 1 .. :0];
    }
    return full;
}

// ============================================================================
// Tests
// ============================================================================

// Simple extern struct for testing. Flecs requires extern structs.
const TestPosition = extern struct {
    x: i64,
    y: i64,
};

const TestVelocity = extern struct {
    vx: i64,
    vy: i64,
};

test "World: init and deinit lifecycle" {
    var world = World.init();
    defer world.deinit();
    // World pointer is valid after init (non-null guaranteed by zflecs).
    _ = world.raw;
}

test "World: register component, set, and get roundtrip" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    const e = world.newEntity();
    std.debug.assert(types.entity_id_valid(e));

    world.setComponent(e, TestPosition, .{ .x = 42, .y = -7 });
    const pos = world.getComponent(e, TestPosition).?;
    try std.testing.expectEqual(@as(i64, 42), pos.x);
    try std.testing.expectEqual(@as(i64, -7), pos.y);
}

test "World: delete entity removes component" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 1, .y = 2 });

    // Component exists before deletion.
    try std.testing.expect(world.getComponent(e, TestPosition) != null);

    world.deleteEntity(e);

    // Entity is no longer alive after deletion.
    try std.testing.expect(!world.isAlive(e));
}

test "World: progress does not crash" {
    var world = World.init();
    defer world.deinit();

    // Progress with zero delta should succeed.
    const ok = world.progress(0.0);
    try std.testing.expect(ok);
}

test "World: multiple components on one entity" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 10, .y = 20 });
    world.setComponent(e, TestVelocity, .{ .vx = 1, .vy = -1 });

    const pos = world.getComponent(e, TestPosition).?;
    const vel = world.getComponent(e, TestVelocity).?;
    try std.testing.expectEqual(@as(i64, 10), pos.x);
    try std.testing.expectEqual(@as(i64, 1), vel.vx);
}

test "World: getComponent returns null for missing component" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 0, .y = 0 });

    // Velocity was not set on this entity.
    try std.testing.expect(world.getComponent(e, TestVelocity) == null);
}

test "World: getComponentMut allows mutation" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 0, .y = 0 });

    const pos = world.getComponentMut(e, TestPosition).?;
    pos.x = 99;

    const check = world.getComponent(e, TestPosition).?;
    try std.testing.expectEqual(@as(i64, 99), check.x);
}

test "World: addSystem registers and runs system" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    _ = world.addSystem("TestMoveSystem", .on_update, testMoveSystem);

    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 0, .y = 0 });
    world.setComponent(e, TestVelocity, .{ .vx = 5, .vy = -3 });

    _ = world.progress(0.0);

    const pos = world.getComponent(e, TestPosition).?;
    try std.testing.expectEqual(@as(i64, 5), pos.x);
    try std.testing.expectEqual(@as(i64, -3), pos.y);
}

fn testMoveSystem(positions: []TestPosition, velocities: []const TestVelocity) void {
    for (positions, velocities) |*pos, vel| {
        pos.x +%= vel.vx;
        pos.y +%= vel.vy;
    }
}

test "World: newPrefab and addIsA inheritance" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    // Create a prefab with default position.
    const prefab = world.newPrefab("TestPrefab");
    world.setComponent(prefab, TestPosition, .{ .x = 42, .y = 99 });

    // Instantiate from the prefab.
    const instance = world.newEntity();
    world.addIsA(instance, prefab);

    // Instance inherits prefab values.
    const pos = world.getComponent(instance, TestPosition).?;
    try std.testing.expectEqual(@as(i64, 42), pos.x);
    try std.testing.expectEqual(@as(i64, 99), pos.y);

    // Override on instance does not affect prefab.
    world.setComponent(instance, TestPosition, .{ .x = 1, .y = 2 });
    const prefab_pos = world.getComponent(prefab, TestPosition).?;
    try std.testing.expectEqual(@as(i64, 42), prefab_pos.x);
}

// ============================================================================
// World.each() tests
// ============================================================================

// Context struct used by each() tests to collect visited entities.
const EachCtx = struct {
    visited: u32,
    last_entity: EntityId,
    last_x: i64,
};

fn eachTestCallback(ctx: *anyopaque, entity: EntityId, comp: *const TestPosition) void {
    const c: *EachCtx = @ptrCast(@alignCast(ctx));
    c.visited += 1;
    c.last_entity = entity;
    c.last_x = comp.x;
}

test "World.each: empty world - cb never called" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    var ctx = EachCtx{ .visited = 0, .last_entity = 0, .last_x = 0 };
    world.each(TestPosition, @ptrCast(&ctx), eachTestCallback);
    try std.testing.expectEqual(@as(u32, 0), ctx.visited);
}

test "World.each: one entity - cb called once with correct data" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 42, .y = -7 });

    var ctx = EachCtx{ .visited = 0, .last_entity = 0, .last_x = 0 };
    world.each(TestPosition, @ptrCast(&ctx), eachTestCallback);

    try std.testing.expectEqual(@as(u32, 1), ctx.visited);
    try std.testing.expectEqual(e, ctx.last_entity);
    try std.testing.expectEqual(@as(i64, 42), ctx.last_x);
}

test "World.each: N entities - cb called N times" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    const n: u32 = 8;
    for (0..n) |i| {
        const e = world.newEntity();
        world.setComponent(e, TestPosition, .{ .x = @intCast(i), .y = 0 });
    }

    var ctx = EachCtx{ .visited = 0, .last_entity = 0, .last_x = 0 };
    world.each(TestPosition, @ptrCast(&ctx), eachTestCallback);
    try std.testing.expectEqual(n, ctx.visited);
}

test "World.each: entity without T is not visited" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    // Only add TestVelocity - no TestPosition.
    const e = world.newEntity();
    world.setComponent(e, TestVelocity, .{ .vx = 1, .vy = 2 });

    var ctx = EachCtx{ .visited = 0, .last_entity = 0, .last_x = 0 };
    world.each(TestPosition, @ptrCast(&ctx), eachTestCallback);
    try std.testing.expectEqual(@as(u32, 0), ctx.visited);
}

test "World: create and delete many entities" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    // Create 2048 entities.
    const count = 2048;
    var ids: [count]EntityId = undefined;
    for (&ids, 0..) |*slot, i| {
        slot.* = world.newEntity();
        world.setComponent(slot.*, TestPosition, .{
            .x = @intCast(i),
            .y = @intCast(i * 2),
        });
    }

    // Verify all are alive with correct data.
    for (ids, 0..) |eid, i| {
        try std.testing.expect(world.isAlive(eid));
        const pos = world.getComponent(eid, TestPosition).?;
        try std.testing.expectEqual(@as(i64, @intCast(i)), pos.x);
    }

    // Delete the first half.
    for (ids[0 .. count / 2]) |eid| {
        world.deleteEntity(eid);
    }

    // First half dead, second half alive.
    for (ids[0 .. count / 2]) |eid| {
        try std.testing.expect(!world.isAlive(eid));
    }
    for (ids[count / 2 ..]) |eid| {
        try std.testing.expect(world.isAlive(eid));
    }
}

// ============================================================================
// World.eachChunk() tests
// ============================================================================

const EachChunkCtx = struct {
    call_count: u32,
    total_visited: u32,
    last_x: i64,
};

fn eachChunkCallback(ctx: *anyopaque, entities: []const EntityId, comps: []const TestPosition) void {
    const c: *EachChunkCtx = @ptrCast(@alignCast(ctx));
    c.call_count += 1;
    c.total_visited += @as(u32, @intCast(entities.len));
    if (comps.len > 0) c.last_x = comps[comps.len - 1].x;
}

test "World.eachChunk: empty world - cb never called" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    var ctx = EachChunkCtx{ .call_count = 0, .total_visited = 0, .last_x = 0 };
    world.eachChunk(TestPosition, @ptrCast(&ctx), eachChunkCallback);
    try std.testing.expectEqual(@as(u32, 0), ctx.total_visited);
}

test "World.eachChunk: one entity - cb called with slice of length 1" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 77, .y = 0 });

    var ctx = EachChunkCtx{ .call_count = 0, .total_visited = 0, .last_x = 0 };
    world.eachChunk(TestPosition, @ptrCast(&ctx), eachChunkCallback);

    try std.testing.expectEqual(@as(u32, 1), ctx.total_visited);
    try std.testing.expectEqual(@as(i64, 77), ctx.last_x);
}

test "World.eachChunk: N entities - all visited" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    const n: u32 = 10;
    for (0..n) |i| {
        const e = world.newEntity();
        world.setComponent(e, TestPosition, .{ .x = @intCast(i), .y = 0 });
    }

    var ctx = EachChunkCtx{ .call_count = 0, .total_visited = 0, .last_x = 0 };
    world.eachChunk(TestPosition, @ptrCast(&ctx), eachChunkCallback);

    try std.testing.expectEqual(n, ctx.total_visited);
}

test "World.eachChunk: prefab entity excluded" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    // Spawn two live entities and one prefab - only live entities should be visited.
    const e1 = world.newEntity();
    world.setComponent(e1, TestPosition, .{ .x = 1, .y = 0 });
    const e2 = world.newEntity();
    world.setComponent(e2, TestPosition, .{ .x = 2, .y = 0 });
    const prefab = world.newPrefab("ChunkTestPrefab");
    world.setComponent(prefab, TestPosition, .{ .x = 999, .y = 0 });

    var ctx = EachChunkCtx{ .call_count = 0, .total_visited = 0, .last_x = 0 };
    world.eachChunk(TestPosition, @ptrCast(&ctx), eachChunkCallback);

    try std.testing.expectEqual(@as(u32, 2), ctx.total_visited);
}

test "World.eachChunk: equivalence with each for single archetype" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);

    const n: u32 = 5;
    for (0..n) |i| {
        const e = world.newEntity();
        world.setComponent(e, TestPosition, .{ .x = @intCast(i * 10), .y = 0 });
    }

    // Collect via each
    var each_sum: i64 = 0;
    var each_count: u32 = 0;
    const EachSumCtx = struct { sum: *i64, count: *u32 };
    var sum_ctx = EachSumCtx{ .sum = &each_sum, .count = &each_count };
    world.each(TestPosition, @ptrCast(&sum_ctx), struct {
        fn cb(raw: *anyopaque, _: EntityId, comp: *const TestPosition) void {
            const c: *EachSumCtx = @ptrCast(@alignCast(raw));
            c.sum.* += comp.x;
            c.count.* += 1;
        }
    }.cb);

    // Collect via eachChunk
    var chunk_sum: i64 = 0;
    var chunk_count: u32 = 0;
    const ChunkSumCtx = struct { sum: *i64, count: *u32 };
    var csum_ctx = ChunkSumCtx{ .sum = &chunk_sum, .count = &chunk_count };
    world.eachChunk(TestPosition, @ptrCast(&csum_ctx), struct {
        fn cb(raw: *anyopaque, _: []const EntityId, comps: []const TestPosition) void {
            const c: *ChunkSumCtx = @ptrCast(@alignCast(raw));
            for (comps) |comp| {
                c.sum.* += comp.x;
                c.count.* += 1;
            }
        }
    }.cb);

    try std.testing.expectEqual(each_count, chunk_count);
    try std.testing.expectEqual(each_sum, chunk_sum);
}

// ============================================================================
// World.eachN() tests
// ============================================================================

test "World.eachN: empty world - cb never called" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    var visited: u32 = 0;
    world.eachN(&[_]type{ TestPosition, TestVelocity }, @ptrCast(&visited), struct {
        fn cb(raw: *anyopaque, entities: []const EntityId, _: ChunkTuple(&[_]type{ TestPosition, TestVelocity })) void {
            (@as(*u32, @ptrCast(@alignCast(raw)))).* += @intCast(entities.len);
        }
    }.cb);
    try std.testing.expectEqual(@as(u32, 0), visited);
}

test "World.eachN: entities with all components are visited" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 1, .y = 0 });
    world.setComponent(e, TestVelocity, .{ .vx = 2, .vy = 0 });

    var visited: u32 = 0;
    world.eachN(&[_]type{ TestPosition, TestVelocity }, @ptrCast(&visited), struct {
        fn cb(raw: *anyopaque, entities: []const EntityId, _: ChunkTuple(&[_]type{ TestPosition, TestVelocity })) void {
            (@as(*u32, @ptrCast(@alignCast(raw)))).* += @intCast(entities.len);
        }
    }.cb);
    try std.testing.expectEqual(@as(u32, 1), visited);
}

test "World.eachN: entity missing one component is not visited" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    // e1 has both - should be visited. e2 has only Position - should not.
    const e1 = world.newEntity();
    world.setComponent(e1, TestPosition, .{ .x = 1, .y = 0 });
    world.setComponent(e1, TestVelocity, .{ .vx = 1, .vy = 0 });
    const e2 = world.newEntity();
    world.setComponent(e2, TestPosition, .{ .x = 2, .y = 0 });

    var visited: u32 = 0;
    world.eachN(&[_]type{ TestPosition, TestVelocity }, @ptrCast(&visited), struct {
        fn cb(raw: *anyopaque, entities: []const EntityId, _: ChunkTuple(&[_]type{ TestPosition, TestVelocity })) void {
            (@as(*u32, @ptrCast(@alignCast(raw)))).* += @intCast(entities.len);
        }
    }.cb);
    try std.testing.expectEqual(@as(u32, 1), visited);
}

test "World.eachN: prefab entity excluded" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    const e = world.newEntity();
    world.setComponent(e, TestPosition, .{ .x = 1, .y = 0 });
    world.setComponent(e, TestVelocity, .{ .vx = 1, .vy = 0 });
    const prefab = world.newPrefab("EachNPrefab");
    world.setComponent(prefab, TestPosition, .{ .x = 99, .y = 0 });
    world.setComponent(prefab, TestVelocity, .{ .vx = 99, .vy = 0 });

    var visited: u32 = 0;
    world.eachN(&[_]type{ TestPosition, TestVelocity }, @ptrCast(&visited), struct {
        fn cb(raw: *anyopaque, entities: []const EntityId, _: ChunkTuple(&[_]type{ TestPosition, TestVelocity })) void {
            (@as(*u32, @ptrCast(@alignCast(raw)))).* += @intCast(entities.len);
        }
    }.cb);
    try std.testing.expectEqual(@as(u32, 1), visited);
}

test "World.eachN: component slices are correct length and accessible" {
    var world = World.init();
    defer world.deinit();

    world.registerComponent(TestPosition);
    world.registerComponent(TestVelocity);

    const n: u32 = 4;
    for (0..n) |i| {
        const e = world.newEntity();
        world.setComponent(e, TestPosition, .{ .x = @intCast(i), .y = 0 });
        world.setComponent(e, TestVelocity, .{ .vx = @intCast(i * 10), .vy = 0 });
    }

    var pos_sum: i64 = 0;
    var vel_sum: i64 = 0;
    var total: u32 = 0;
    const SumCtx = struct { pos: *i64, vel: *i64, count: *u32 };
    var sum_ctx = SumCtx{ .pos = &pos_sum, .vel = &vel_sum, .count = &total };
    world.eachN(&[_]type{ TestPosition, TestVelocity }, @ptrCast(&sum_ctx), struct {
        fn cb(raw: *anyopaque, entities: []const EntityId, chunks: ChunkTuple(&[_]type{ TestPosition, TestVelocity })) void {
            const c: *SumCtx = @ptrCast(@alignCast(raw));
            c.count.* += @intCast(entities.len);
            for (chunks.TestPosition, chunks.TestVelocity) |pos, vel| {
                c.pos.* += pos.x;
                c.vel.* += vel.vx;
            }
        }
    }.cb);

    try std.testing.expectEqual(n, total);
    try std.testing.expectEqual(@as(i64, 0 + 1 + 2 + 3), pos_sum);
    try std.testing.expectEqual(@as(i64, 0 + 10 + 20 + 30), vel_sum);
}
