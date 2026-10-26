/* Riptide C interface. All functions are thread-compatible: use one
 * simulator per thread; states may move between threads between calls. */
#ifndef RIPTIDE_H
#define RIPTIDE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rt_simulator rt_simulator;
typedef struct rt_state rt_state;

typedef struct { float x, y, z; } rt_vec3;
typedef struct { float min_x, min_y, min_z, max_x, max_y, max_z; } rt_aabb;

enum { RT_KIND_AIR = 0, RT_KIND_LIQUID = 1, RT_KIND_BLOCK = 2 };
enum { RT_LIQUID_NONE = 0, RT_LIQUID_WATER = 1, RT_LIQUID_LAVA = 2 };
enum { RT_BOUNCE_NONE = 0, RT_BOUNCE_SLIME = 1, RT_BOUNCE_BED = 2 };
enum { RT_INSIDE_NONE = 0, RT_INSIDE_SWEET_BERRY_BUSH = 1, RT_INSIDE_POWDER_SNOW = 2 };
enum { RT_TRAVERSAL_NONE = 0, RT_TRAVERSAL_SCAFFOLDING = 1, RT_TRAVERSAL_POWDER_SNOW = 2 };
enum { RT_BUBBLE_NONE = 0, RT_BUBBLE_UP = 1, RT_BUBBLE_DOWN = 2 };

/* rt_block.flags */
#define RT_BLOCK_SOUL_SPEED_AFFECTED (1u << 0)
#define RT_BLOCK_CLIMBABLE (1u << 1)
#define RT_BLOCK_COBWEB (1u << 2)
#define RT_BLOCK_HONEY (1u << 3)
#define RT_BLOCK_CARPET (1u << 4)
#define RT_BLOCK_FLOW_BARRIER (1u << 5)
#define RT_BLOCK_DYNAMIC_SHAPE (1u << 6)
#define RT_BLOCK_LIQUID_FALLING (1u << 7)

/* rt_block.solid_faces */
#define RT_FACE_WEST (1u << 0)
#define RT_FACE_EAST (1u << 1)
#define RT_FACE_NORTH (1u << 2)
#define RT_FACE_SOUTH (1u << 3)

/* One block cell, merged across both layers. `shape` must stay valid and
 * unchanged for the duration of the rt_tick call. */
typedef struct {
    const rt_aabb *shape;
    uint32_t shape_len;
    float friction;           /* 0.6 for ordinary blocks */
    float accel_friction_mul; /* 1 for ordinary blocks */
    uint32_t flags;
    uint8_t kind;
    uint8_t bounce;
    uint8_t inside;
    uint8_t traversal;
    uint8_t liquid;
    uint8_t liquid_level; /* 0 is a source */
    uint8_t solid_faces;
    uint8_t bubble;
    int8_t bubble_surface; /* -1 unknown, 0 no, 1 yes */
    uint8_t reserved[3];
} rt_block;

typedef struct {
    rt_vec3 position;
    uint8_t sneaking, descending, want_down, leather_boots, descend_through_block;
    uint8_t reserved[3];
} rt_collision_context;

/* Writes the cell at (x, y, z) to *out. Returns 1 if loaded, 0 if unknown. */
typedef int (*rt_block_fn)(void *user, int32_t x, int32_t y, int32_t z, rt_block *out);
/* Writes up to `cap` local boxes for a block flagged RT_BLOCK_DYNAMIC_SHAPE
 * and returns how many were written. */
typedef uint32_t (*rt_dynamic_shape_fn)(void *user, int32_t x, int32_t y, int32_t z,
                                        const rt_collision_context *ctx, rt_aabb *out, uint32_t cap);

typedef struct {
    void *user;
    rt_block_fn block;
    rt_dynamic_shape_fn dynamic_shape; /* may be NULL */
} rt_world;

enum { RT_SWIM_TRUST_CLIENT = 0, RT_SWIM_TICKS = 1 };

typedef struct {
    uint8_t swim_grace;          /* RT_SWIM_* */
    uint8_t legacy_sprint;       /* 1 for clients before 1.21.0 */
    uint16_t swim_grace_ticks;   /* used with RT_SWIM_TICKS */
    float step_client_tiebreak;  /* NaN disables */
    uint32_t max_query_cells;    /* 0 uses the default */
} rt_config;

/* rt_input.flags, in PlayerAuthInput terms. */
#define RT_IN_HORIZONTAL_COLLISION (1u << 0)
#define RT_IN_VERTICAL_COLLISION (1u << 1)
#define RT_IN_START_FLYING (1u << 2)
#define RT_IN_STOP_FLYING (1u << 3)
#define RT_IN_START_SPRINTING (1u << 4)
#define RT_IN_STOP_SPRINTING (1u << 5)
#define RT_IN_SPRINT_DOWN (1u << 6)
#define RT_IN_START_SNEAKING (1u << 7)
#define RT_IN_STOP_SNEAKING (1u << 8)
#define RT_IN_SNEAK_DOWN (1u << 9)
#define RT_IN_SNEAKING (1u << 10)
#define RT_IN_START_JUMPING (1u << 11)
#define RT_IN_JUMPING (1u << 12)
#define RT_IN_AUTO_JUMPING_IN_WATER (1u << 13)
#define RT_IN_ASCEND_BLOCK (1u << 14)
#define RT_IN_DESCEND_BLOCK (1u << 15)
#define RT_IN_START_SWIMMING (1u << 16)
#define RT_IN_STOP_SWIMMING (1u << 17)
#define RT_IN_WANT_DOWN (1u << 18)
#define RT_IN_WANT_DOWN_SLOW (1u << 19)
#define RT_IN_START_CRAWLING (1u << 20)
#define RT_IN_STOP_CRAWLING (1u << 21)
#define RT_IN_START_GLIDING (1u << 22)
#define RT_IN_STOP_GLIDING (1u << 23)
#define RT_IN_USING_CONSUMABLE (1u << 24)
#define RT_IN_USING_ITEM (1u << 25)
#define RT_IN_USING_SPEAR (1u << 26)
#define RT_IN_INVENTORY_ACTION (1u << 27)
#define RT_IN_START_SPIN_ATTACK (1u << 28)
#define RT_IN_STOP_SPIN_ATTACK (1u << 29)

typedef struct {
    float move_x, move_y;   /* strafe, forward */
    float pitch, head_yaw, yaw;
    rt_vec3 reported_pos;
    rt_vec3 reported_vel;
    float item_use_modifier; /* NaN derives it from the flags */
    uint32_t flags;
    uint8_t move_is_raw;
    uint8_t reserved[3];
} rt_input;

enum {
    RT_OUTCOME_NORMAL = 0,
    RT_OUTCOME_TELEPORT,
    RT_OUTCOME_CLIENT_AUTHORITATIVE,
    RT_OUTCOME_UNLOADED,
    RT_OUTCOME_IMMOBILE,
    RT_OUTCOME_MOUNTED,
    RT_OUTCOME_INVALID_INPUT,
    RT_OUTCOME_INVALID_WORLD,
    RT_OUTCOME_QUERY_LIMIT,
};

enum { RT_CONFIDENCE_DECOMPILED = 0, RT_CONFIDENCE_PORTED = 1, RT_CONFIDENCE_UNCERTAIN = 2 };

typedef struct {
    rt_vec3 pos, vel, mov;
    rt_vec3 position_delta, velocity_delta;
    uint32_t mechanics; /* bit set, see the Zig Mechanics struct */
    uint8_t outcome;
    uint8_t confidence;
    uint8_t on_ground, collide_x, collide_y, collide_z;
    uint8_t sprint_movement_blocked;
    uint8_t reserved;
} rt_result;

enum { RT_GAME_SURVIVAL = 0, RT_GAME_CREATIVE, RT_GAME_ADVENTURE, RT_GAME_SPECTATOR };

/* Caller-settable authoritative state. rt_state_set rejects non-finite or
 * out-of-range values. */
typedef struct {
    rt_vec3 pos, vel;
    float pitch, head_yaw, yaw;
    float width, height, scale, standing_height, sneaking_height, crawling_height;
    float movement_speed, default_movement_speed, jump_strength, gravity;
    float underwater_speed, lava_speed, swim_speed_multiplier, fall_distance;
    int32_t jump_boost, levitation; /* amplifier, or -1 when inactive */
    uint32_t dolphin_boost_ticks;
    uint8_t on_ground, sneaking, crawling, swimming, gliding, sprinting, has_gravity;
    uint8_t slow_falling, weaving;
    uint8_t depth_strider, soul_speed, swift_sneak, riptide, leather_boots, elytra;
    uint8_t game_mode, flying, trust_fly_status, no_clip, immobile, ready, alive, in_vehicle;
    uint8_t server_sprint, server_updated_speed, riptide_in_rain;
    uint8_t reserved[2];
} rt_state_view;

const char *rt_version(void);

/* Returns NULL on allocation failure or an invalid config. */
rt_simulator *rt_simulator_create(rt_world world, const rt_config *config);
void rt_simulator_destroy(rt_simulator *sim);
void rt_simulator_set_world(rt_simulator *sim, rt_world world);

rt_state *rt_state_create(rt_vec3 pos);
rt_state *rt_state_clone(const rt_state *state);
void rt_state_destroy(rt_state *state);
void rt_state_get(const rt_state *state, rt_state_view *out);
/* Returns 1 on success, 0 if a value is invalid (the state is unchanged). */
int rt_state_set(rt_state *state, const rt_state_view *view);

void rt_state_queue_motion(rt_state *state, rt_vec3 vel);
void rt_state_queue_teleport(rt_state *state, rt_vec3 target, uint32_t smoothed_ticks);
void rt_state_queue_firework_boost(rt_state *state);
void rt_state_set_riptide_ready(rt_state *state, int ready);

void rt_tick(rt_simulator *sim, rt_state *state, const rt_input *input, rt_result *out);

/* sizeof of each public struct as compiled into the library, in declaration
 * order: rt_block, rt_collision_context, rt_config, rt_input, rt_result,
 * rt_state_view. Lets bindings verify the header matches. */
void rt_abi_sizes(uint32_t out[6]);

#ifdef __cplusplus
}
#endif

#endif
