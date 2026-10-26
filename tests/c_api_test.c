/* Exercises the C interface: ABI agreement, a short walk, invalid world data,
 * and state validation. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "riptide.h"

static const rt_aabb unit = {0, 0, 0, 1, 1, 1};

/* Stone floor at y = -1, plus a block with an invalid enum at (5, 0, 5). */
static int block(void *user, int32_t x, int32_t y, int32_t z, rt_block *out) {
    (void)user;
    memset(out, 0, sizeof *out);
    out->friction = 0.6f;
    out->accel_friction_mul = 1;
    out->bubble_surface = -1;
    if (y == -1) {
        out->kind = RT_KIND_BLOCK;
        out->shape = &unit;
        out->shape_len = 1;
        out->flags = RT_BLOCK_FLOW_BARRIER;
        out->solid_faces = RT_FACE_WEST | RT_FACE_EAST | RT_FACE_NORTH | RT_FACE_SOUTH;
    } else if (x == 5 && y == 0 && z == 5) {
        out->kind = 9;
    } else {
        out->kind = RT_KIND_AIR;
    }
    return 1;
}

#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            return 1;                                                  \
        }                                                              \
    } while (0)

int main(void) {
    uint32_t sizes[6];
    rt_abi_sizes(sizes);
    CHECK(sizes[0] == sizeof(rt_block));
    CHECK(sizes[1] == sizeof(rt_collision_context));
    CHECK(sizes[2] == sizeof(rt_config));
    CHECK(sizes[3] == sizeof(rt_input));
    CHECK(sizes[4] == sizeof(rt_result));
    CHECK(sizes[5] == sizeof(rt_state_view));
    CHECK(strcmp(rt_version(), "0.1.0") == 0);

    rt_world world = {NULL, block, NULL};
    rt_config cfg = {RT_SWIM_TICKS, 0, 10, NAN, 0};
    rt_simulator *sim = rt_simulator_create(world, &cfg);
    CHECK(sim != NULL);

    rt_vec3 spawn = {0.5f, 0, 0.5f};
    rt_state *state = rt_state_create(spawn);
    CHECK(state != NULL);

    rt_input in;
    memset(&in, 0, sizeof in);
    in.move_y = 1;
    in.item_use_modifier = NAN;
    rt_result r;
    for (int i = 0; i < 40; i++) {
        rt_tick(sim, state, &in, &r);
        CHECK(r.outcome == RT_OUTCOME_NORMAL);
    }
    CHECK(r.on_ground);
    CHECK(r.pos.y == 0);
    CHECK(r.pos.z > 4);
    CHECK(fabsf(r.vel.z - 0.11785906f) < 1e-6f);

    rt_state *copy = rt_state_clone(state);
    rt_state_view view;
    rt_state_get(copy, &view);
    CHECK(view.on_ground && view.jump_boost == -1);
    view.vel.x = NAN;
    CHECK(rt_state_set(copy, &view) == 0);
    view.vel.x = 0;
    view.pos = (rt_vec3){5.5f, 0, 5.5f};
    CHECK(rt_state_set(copy, &view) == 1);
    rt_tick(sim, copy, &in, &r);
    CHECK(r.outcome == RT_OUTCOME_INVALID_WORLD);

    rt_state_queue_teleport(state, (rt_vec3){1, 2, 3}, 0);
    rt_tick(sim, state, &in, &r);
    CHECK(r.outcome == RT_OUTCOME_TELEPORT && r.pos.x == 1 && r.pos.y == 2 && r.pos.z == 3);

    rt_state_destroy(copy);
    rt_state_destroy(state);
    rt_simulator_destroy(sim);
    puts("c api ok");
    return 0;
}
