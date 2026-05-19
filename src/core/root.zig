// Engine core subsystem — public API.
//
// Exports all core primitives: types, allocators, fixed-point math, math
// types, and the seeded PRNG. Game code imports these via:
//
//   const core = @import("engine").core;
//   const EntityId = core.types.EntityId;
//   const Fp16 = core.fixed_point.Fp16;
//   const FVec3 = core.math.FVec3;

pub const types = @import("types/root.zig");
pub const memory = @import("memory.zig");
pub const fixed_point = @import("fixed_point.zig");
pub const math = @import("math.zig");
pub const random = @import("random.zig");
pub const ecs = @import("ecs.zig");
pub const sidecar_store = @import("sidecar_store.zig");
pub const spatial = @import("spatial/hash_grid.zig");
pub const compress = @import("compress.zig");

// Pull all sub-module tests into the engine test binary.
test {
    _ = types;
    _ = memory;
    _ = fixed_point;
    _ = math;
    _ = random;
    _ = ecs;
    _ = sidecar_store;
    _ = @import("sidecar_store_test.zig");
    _ = spatial;
    _ = @import("spatial/hash_grid_rebuild_test.zig");
    _ = @import("spatial/hash_grid_visit_test.zig");
    _ = compress;
}
