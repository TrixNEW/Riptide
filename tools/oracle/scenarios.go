package main

import (
	"fmt"
	"math/rand/v2"
)

func sem() Sem { return Sem{Friction: 0.6, AccelMul: 1} }

func solid(s Sem) BlockSpec {
	return BlockSpec{Kind: "block", Boxes: [][6]F32{{0, 0, 0, 1, 1, 1}}, Sem: s, SolidFaces: 15, Barrier: true}
}

func shaped(s Sem, boxes ...[6]F32) BlockSpec {
	return BlockSpec{Kind: "block", Boxes: boxes, Sem: s, Barrier: len(boxes) > 0}
}

func passable(s Sem) BlockSpec { return BlockSpec{Kind: "block", Sem: s} }

func liquid(kind string, level int, falling bool) BlockSpec {
	return BlockSpec{Kind: "liquid", Sem: sem(), Liquid: &LiquidSpec{Kind: kind, Level: level, Falling: falling}}
}

var (
	stone     = solid(sem())
	ice       = solid(Sem{Friction: 0.98, AccelMul: 1})
	blueIce   = solid(Sem{Friction: 0.989, AccelMul: 1})
	slime     = solid(Sem{Friction: 0.8, AccelMul: 1, Bounce: "slime"})
	honey     = shaped(Sem{Friction: 0.8, AccelMul: 1, Honey: true}, [6]F32{0.0625, 0, 0.0625, 0.9375, 0.9375, 0.9375})
	soulSand  = shaped(Sem{Friction: 0.6, AccelMul: 1.225000023841858, SoulSpeed: true}, [6]F32{0, 0, 0, 1, 0.875, 1})
	bed       = shaped(Sem{Friction: 0.6, AccelMul: 1, Bounce: "bed"}, [6]F32{0, 0, 0, 1, 0.5625, 1})
	slab      = shaped(sem(), [6]F32{0, 0, 0, 1, 0.5, 1})
	topSlab   = shaped(sem(), [6]F32{0, 0.5, 0, 1, 1, 1})
	stairs    = shaped(sem(), [6]F32{0, 0, 0, 1, 0.5, 1}, [6]F32{0, 0.5, 0.5, 1, 1, 1})
	fence     = shaped(sem(), [6]F32{0.375, 0, 0.375, 0.625, 1.5, 0.625})
	wallPost  = shaped(sem(), [6]F32{0.25, 0, 0.25, 0.75, 1.5, 0.75})
	carpet    = shaped(Sem{Friction: 0.6, AccelMul: 1, Carpet: true}, [6]F32{0, 0, 0, 1, 0.0625, 1})
	ladder    = shaped(Sem{Friction: 0.6, AccelMul: 1, Climbable: true}, [6]F32{0, 0, 0.8125, 1, 1, 1})
	vine      = passable(Sem{Friction: 0.6, AccelMul: 1, Climbable: true})
	web       = passable(Sem{Friction: 0.6, AccelMul: 1, Cobweb: true})
	berry     = passable(Sem{Friction: 0.6, AccelMul: 1, Inside: "sweet_berry_bush"})
	powder    = passable(Sem{Friction: 0.6, AccelMul: 1, Inside: "powder_snow", Traversal: "powder_snow"})
	scaffold  = shaped(Sem{Friction: 0.6, AccelMul: 1, Traversal: "scaffolding"}, [6]F32{0, 0.875, 0, 1, 1, 1})
	water     = liquid("water", 0, false)
	lava      = liquid("lava", 0, false)
	air       = BlockSpec{Kind: "air", Sem: sem()}
	waterSlab = func() BlockSpec { b := slab; b.Liquid = &LiquidSpec{Kind: "water"}; return b }()
)

func bubble(dir string, surface *bool) BlockSpec {
	b := water
	b.Bubble = dir
	b.BubbleSurface = surface
	return b
}

func at(x, y, z int32, b BlockSpec) Fill {
	return Fill{From: [3]int32{x, y, z}, To: [3]int32{x, y, z}, Block: b}
}

func box3(x0, y0, z0, x1, y1, z1 int32, b BlockSpec) Fill {
	return Fill{From: [3]int32{x0, y0, z0}, To: [3]int32{x1, y1, z1}, Block: b}
}

func floor(r int32, b BlockSpec) Fill { return box3(-r, -1, -r, r, -1, r, b) }

func spawn(x, y, z float32) StateSpec {
	return StateSpec{Pos: Vec{F32(x), F32(y), F32(z)}, Height: 1.8, Speed: 0.1, DefaultSpeed: 0.1, Gravity: 0.08, SwimMul: 1}
}

func grounded(x, y, z float32) StateSpec {
	s := spawn(x, y, z)
	s.OnGround = true
	return s
}

func rep(n int, in InputSpec) []InputSpec {
	out := make([]InputSpec, n)
	for i := range out {
		out[i] = in
		out[i].Flags = append([]string(nil), in.Flags...)
	}
	return out
}

func fwd(flags ...string) InputSpec { return InputSpec{Move: [2]F32{0, 1}, Flags: flags} }

func cat(parts ...[]InputSpec) []InputSpec {
	var out []InputSpec
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func withYaw(in []InputSpec, yaw func(i int) float32) []InputSpec {
	for i := range in {
		in[i].Yaw = F32(yaw(i))
	}
	return in
}

func handwritten() []Scenario {
	tru, fal := boolp(true), boolp(false)
	sprintJump := func(i int) InputSpec {
		in := fwd("sprint_down")
		if i == 0 {
			in.Flags = append(in.Flags, "start_sprinting")
		}
		if i%12 == 2 {
			in.Flags = append(in.Flags, "start_jumping", "jumping")
		}
		return in
	}
	var sprintJumps []InputSpec
	for i := range 60 {
		sprintJumps = append(sprintJumps, sprintJump(i))
	}
	glideState := spawn(0.5, 80, 0.5)
	glideState.Gliding, glideState.Elytra, glideState.Vel = true, true, Vec{0, -0.3, 0.6}
	boostState := glideState
	boostState.GlideBoost = 20
	swimState := spawn(0.5, 1, 0.5)
	swimState.Swimming = true
	riptideState := spawn(0.5, 1, 0.5)
	riptideState.Riptide = 3
	soulState := grounded(0.5, 0.875, 0.5)
	soulState.SoulSpeed = 2
	strider := spawn(0.5, 0, 0.5)
	strider.OnGround, strider.DepthStrider = true, 3
	dolphin := swimState
	dolphin.SwimMul, dolphin.DolphinTicks = 2, 8
	sneaking := grounded(0.5, 0, 0.5)
	sneaking.Sneaking, sneaking.Height = true, 1.49
	swift := sneaking
	swift.SwiftSneak = 3
	levitate := grounded(0.5, 0, 0.5)
	levitate.Levitation = i32p(1)
	boosted := grounded(0.5, 0, 0.5)
	boosted.JumpBoost = i32p(1)
	slowFall := spawn(0.5, 20, 0.5)
	slowFall.SlowFalling = true
	weave := spawn(0.5, 2, 0.5)
	weave.Weaving = true
	boots := spawn(0.5, 3, 0.5)
	boots.LeatherBoots = true

	pool := box3(-6, 0, -6, 6, 2, 6, water)

	jumpTick := func(n int, every int) []InputSpec {
		out := rep(n, InputSpec{})
		for i := range out {
			if i%every == 0 {
				out[i].Flags = []string{"start_jumping", "jumping"}
			}
		}
		return out
	}

	return []Scenario{
		{Name: "walk_stone", World: []Fill{floor(32, stone)}, State: grounded(0.5, 0, 0.5), Inputs: rep(40, fwd())},
		{Name: "walk_yaw_sweep", World: []Fill{floor(48, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: withYaw(rep(120, fwd()), func(i int) float32 { return float32(i)*7.3 - 400 })},
		{Name: "strafe_diagonal", World: []Fill{floor(32, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: withYaw(rep(40, InputSpec{Move: [2]F32{0.7071068, 0.7071068}}), func(i int) float32 { return 33.3 })},
		{Name: "sprint_jump", World: []Fill{floor(64, stone)}, State: grounded(0.5, 0, 0.5), Inputs: sprintJumps},
		{Name: "sprint_jump_legacy", SprintLegacy: true, World: []Fill{floor(64, stone)}, State: grounded(0.5, 0, 0.5), Inputs: sprintJumps},
		{Name: "ice_slide", World: []Fill{floor(48, ice)}, State: grounded(0.5, 0, 0.5), Inputs: cat(rep(20, fwd()), rep(40, InputSpec{}))},
		{Name: "blue_ice_sprint", World: []Fill{floor(64, blueIce)}, State: grounded(0.5, 0, 0.5), Inputs: rep(40, fwd("start_sprinting", "sprint_down"))},
		{Name: "slime_walk", World: []Fill{floor(32, slime)}, State: grounded(0.5, 0, 0.5), Inputs: cat(rep(20, fwd()), jumpTick(20, 7))},
		{Name: "slime_bounce", World: []Fill{floor(8, slime)}, State: spawn(0.5, 6, 0.5), Inputs: rep(60, InputSpec{})},
		{Name: "bed_bounce", World: []Fill{floor(8, bed)}, State: spawn(0.5, 6, 0.5), Inputs: rep(50, InputSpec{})},
		{Name: "slime_sneak_land", World: []Fill{floor(8, slime)}, State: func() StateSpec { s := spawn(0.5, 4, 0.5); s.Sneaking, s.Height = true, 1.49; return s }(),
			Inputs: rep(30, InputSpec{Flags: []string{"sneak_down", "sneaking"}})},
		{Name: "soul_sand", World: []Fill{floor(32, soulSand)}, State: grounded(0.5, 0.875, 0.5), Inputs: rep(40, fwd())},
		{Name: "soul_speed", World: []Fill{floor(32, soulSand)}, State: soulState, Inputs: rep(40, fwd())},
		{Name: "honey_walk_jump", World: []Fill{floor(32, honey)}, State: grounded(0.5, 0.9375, 0.5), Inputs: cat(rep(20, fwd()), jumpTick(30, 9))},
		{Name: "honey_wall_slide", World: []Fill{floor(4, stone), box3(1, 0, -2, 1, 8, 2, honey)}, State: spawn(0.6, 6, 0.5),
			Inputs: rep(40, InputSpec{Move: [2]F32{-1, 0}})},
		{Name: "carpet_honey_jump", World: []Fill{floor(8, honey), box3(-8, 0, -8, 8, 0, 8, carpet)}, State: grounded(0.5, 0.0625, 0.5), Inputs: jumpTick(30, 12)},
		{Name: "step_slab_stairs", World: []Fill{floor(32, stone), at(0, 0, 3, slab), at(0, 0, 6, stairs), at(0, 1, 7, slab), at(0, 0, 10, stone)},
			State: grounded(0.5, 0, 0.5), Inputs: rep(60, fwd())},
		{Name: "step_while_jumping", World: []Fill{floor(32, stone), box3(-2, 0, 3, 2, 0, 3, slab)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(4, fwd()), rep(1, fwd("start_jumping", "jumping")), rep(25, fwd()))},
		{Name: "wall_corner", World: []Fill{floor(16, stone), box3(-3, 0, 3, 3, 2, 3, stone), box3(3, 0, -3, 3, 2, 3, stone)},
			State: grounded(0.5, 0, 0.5), Inputs: withYaw(rep(50, fwd()), func(int) float32 { return -45 })},
		{Name: "fence_blocks_jump", World: []Fill{floor(16, stone), box3(-3, 0, 2, 3, 0, 2, fence)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(5, fwd()), rep(1, fwd("start_jumping", "jumping")), rep(30, fwd()))},
		{Name: "wall_post_slide", World: []Fill{floor(16, stone), box3(0, 0, 2, 0, 0, 2, wallPost)}, State: grounded(0.7, 0, 0.5),
			Inputs: withYaw(rep(40, fwd()), func(int) float32 { return 5 })},
		{Name: "head_bump", World: []Fill{floor(8, stone), box3(-8, 2, -8, 8, 2, 8, topSlab)}, State: grounded(0.5, 0, 0.5), Inputs: jumpTick(40, 13)},
		{Name: "sneak_edge", World: []Fill{at(0, -1, 0, stone)}, State: sneaking, Inputs: rep(40, fwd("sneak_down", "sneaking"))},
		{Name: "sneak_edge_diagonal_ice", World: []Fill{box3(0, -1, 0, 1, -1, 1, ice)}, State: sneaking,
			Inputs: withYaw(rep(60, fwd("sneak_down", "sneaking")), func(i int) float32 { return float32(i * 13 % 360) })},
		{Name: "swift_sneak", World: []Fill{floor(32, stone)}, State: swift, Inputs: rep(30, fwd("sneak_down", "sneaking"))},
		{Name: "sneak_under_ceiling", World: []Fill{floor(8, stone), box3(-8, 1, 2, 8, 1, 8, topSlab)}, State: sneaking,
			Inputs: cat(rep(10, fwd("sneak_down", "sneaking")), rep(10, fwd("stop_sneaking")), rep(10, InputSpec{Move: [2]F32{0, -1}}))},
		{Name: "crawl_gap", World: []Fill{floor(8, stone), box3(-8, 1, -8, 8, 1, 8, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(1, fwd("start_crawling")), rep(20, fwd()), rep(1, fwd("stop_crawling")))},
		{Name: "ladder_climb", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 6, 0, ladder), box3(0, 0, 1, 0, 8, 1, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(20, InputSpec{Flags: []string{"jumping"}}), rep(10, InputSpec{Flags: []string{"sneak_down", "sneaking"}}), rep(20, InputSpec{}))},
		{Name: "ladder_push_wall", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 6, 0, ladder), box3(0, 0, 1, 0, 8, 1, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: rep(30, fwd())},
		{Name: "vine_fall", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 12, 0, vine)}, State: spawn(0.5, 10, 0.5), Inputs: rep(40, InputSpec{})},
		{Name: "scaffold_climb_descend", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 5, 0, scaffold)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(25, InputSpec{Flags: []string{"jumping"}}), rep(30, InputSpec{Flags: []string{"sneak_down", "sneaking"}}))},
		{Name: "cobweb_fall", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 3, 0, web)}, State: spawn(0.5, 6, 0.5), Inputs: rep(60, fwd())},
		{Name: "cobweb_weaving", World: []Fill{floor(8, stone), at(0, 0, 0, web), at(0, 1, 0, web)}, State: weave, Inputs: rep(30, fwd())},
		{Name: "berry_bush", World: []Fill{floor(8, stone), box3(-1, 0, 1, 1, 0, 6, berry)}, State: grounded(0.5, 0, 0.5), Inputs: rep(40, fwd("start_sprinting"))},
		{Name: "powder_snow", World: []Fill{floor(8, stone), box3(-1, 0, -1, 1, 1, 1, powder)}, State: spawn(0.5, 3, 0.5), Inputs: rep(40, fwd())},
		{Name: "powder_snow_boots", World: []Fill{floor(8, stone), box3(-1, 0, -1, 1, 1, 1, powder)}, State: boots,
			Inputs: cat(rep(20, InputSpec{Flags: []string{"jumping"}}), rep(20, InputSpec{Flags: []string{"sneak_down", "sneaking"}}))},
		{Name: "water_idle_sink", World: []Fill{floor(8, stone), pool}, State: spawn(0.5, 1.5, 0.5), Inputs: rep(40, InputSpec{})},
		{Name: "water_swim_up", World: []Fill{floor(8, stone), pool}, State: spawn(0.5, 0, 0.5), Inputs: rep(40, fwd("jumping"))},
		{Name: "water_swim_pitch", World: []Fill{floor(16, stone), box3(-12, 0, -12, 12, 4, 12, water)}, State: swimState,
			Inputs: func() []InputSpec {
				in := rep(80, fwd("sprint_down", "start_sprinting"))
				for i := range in {
					in[i].Pitch = F32(float32(i%40)*4 - 70)
				}
				return in
			}()},
		{Name: "water_start_stop_swim", World: []Fill{floor(16, stone), box3(-12, 0, -12, 12, 3, 12, water)}, State: spawn(0.5, 0.5, 0.5),
			Inputs: cat(rep(1, fwd("start_swimming", "start_sprinting")), rep(20, fwd("sprint_down")), rep(1, fwd("stop_swimming", "stop_sprinting")), rep(20, fwd()))},
		{Name: "water_exit_ledge", World: append([]Fill{floor(8, stone), box3(-8, 0, -8, 8, 0, 8, water)}, box3(-8, 0, 3, 8, 0, 8, stone)),
			State: spawn(0.5, 0, 0.5), Inputs: rep(40, fwd("jumping"))},
		{Name: "water_depth_strider", World: []Fill{floor(32, stone), box3(-32, 0, -32, 32, 0, 32, water)}, State: strider, Inputs: rep(40, fwd())},
		{Name: "water_dolphin", World: []Fill{floor(32, stone), box3(-32, 0, -32, 32, 3, 32, water)}, State: dolphin, Inputs: rep(30, fwd("sprint_down"))},
		{Name: "water_current", World: func() []Fill {
			f := []Fill{floor(16, stone)}
			for x := int32(-7); x <= 7; x++ {
				lvl := int(x + 7)
				if lvl > 7 {
					lvl = 7
				}
				f = append(f, at(x, 0, 0, liquid("water", lvl, false)), at(x, 0, 1, liquid("water", lvl, false)))
			}
			return f
		}(), State: grounded(-6.5, 0, 0.5), Inputs: rep(60, InputSpec{})},
		{Name: "water_falling_column", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 8, 0, liquid("water", 0, true)), at(1, 2, 0, stone)},
			State: spawn(0.5, 6, 0.5), Inputs: rep(40, InputSpec{})},
		{Name: "waterlogged_slab_flow", World: []Fill{floor(8, stone), box3(-4, 0, -4, 4, 0, 4, liquid("water", 2, false)), at(0, 0, 1, waterSlab), at(0, 0, 2, liquid("water", 0, false))},
			State: grounded(0.5, 0, 0.5), Inputs: rep(30, InputSpec{})},
		{Name: "lava_walk", World: []Fill{floor(8, stone), box3(-8, 0, -8, 8, 0, 8, lava)}, State: grounded(0.5, 0, 0.5), Inputs: cat(rep(20, fwd()), rep(20, fwd("jumping")))},
		{Name: "bubble_up", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 5, 0, bubble("up", nil)), at(0, 6, 0, bubble("up", tru))},
			State: spawn(0.5, 0, 0.5), Inputs: rep(40, InputSpec{})},
		{Name: "bubble_down", World: []Fill{floor(8, stone), box3(0, 0, 0, 0, 5, 0, bubble("down", nil)), at(0, 6, 0, bubble("down", fal))},
			State: spawn(0.5, 6, 0.5), Inputs: rep(40, InputSpec{})},
		{Name: "glide_pitch", World: []Fill{floor(64, stone)}, State: glideState,
			Inputs: func() []InputSpec {
				in := rep(100, InputSpec{})
				for i := range in {
					in[i].Pitch = F32(float32(i%50) - 25)
					in[i].Yaw = F32(float32(i) * 3.7)
				}
				return in
			}()},
		{Name: "glide_boost", World: []Fill{floor(64, stone)}, State: boostState, Inputs: withYaw(rep(40, InputSpec{Pitch: -20}), func(i int) float32 { return float32(i) })},
		{Name: "glide_wall", World: []Fill{floor(32, stone), box3(-8, 70, 6, 8, 90, 6, stone)}, State: glideState, Inputs: rep(30, InputSpec{Pitch: 10})},
		{Name: "glide_land", World: []Fill{floor(64, stone)}, State: func() StateSpec { s := glideState; s.Pos = Vec{0.5, 3, 0.5}; return s }(), Inputs: rep(40, InputSpec{Pitch: 30})},
		{Name: "glide_levitation", World: []Fill{floor(32, stone)}, State: func() StateSpec { s := glideState; s.Levitation = i32p(0); return s }(), Inputs: rep(10, InputSpec{})},
		{Name: "riptide_water", World: []Fill{floor(16, stone), box3(-16, 0, -16, 16, 2, 16, water)}, State: riptideState,
			Inputs: cat([]InputSpec{{Pitch: -40, Yaw: 30, Flags: []string{"start_spin_attack"}, RiptideReady: true}}, rep(30, InputSpec{Pitch: -40, Yaw: 30}))},
		{Name: "riptide_grounded", World: []Fill{floor(16, stone), box3(-16, 0, -16, 16, 0, 16, water)}, State: func() StateSpec { s := riptideState; s.Pos[1], s.OnGround = 0, true; return s }(),
			Inputs: cat([]InputSpec{{Pitch: -10, Flags: []string{"start_spin_attack"}, RiptideReady: true}}, rep(30, InputSpec{}))},
		{Name: "knockback_ground", World: []Fill{floor(16, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(3, fwd()), []InputSpec{{Motion: &Vec{0.4, 0.36, -0.2}}}, rep(25, fwd()))},
		{Name: "knockback_water", World: []Fill{floor(8, stone), pool}, State: spawn(0.5, 0.5, 0.5),
			Inputs: cat(rep(3, InputSpec{}), []InputSpec{{Motion: &Vec{0.3, 0.4, 0.3}}}, rep(15, InputSpec{}))},
		{Name: "teleport_instant", World: []Fill{floor(16, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(3, fwd()), []InputSpec{{Teleport: &TeleportSpec{Pos: Vec{5.5, 4, -3.25}}}}, rep(20, fwd()))},
		{Name: "teleport_smoothed", World: []Fill{floor(16, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(3, fwd()), []InputSpec{{Teleport: &TeleportSpec{Pos: Vec{3.3, 0, 2.1}, Smoothed: 2}}}, rep(20, fwd()))},
		{Name: "item_use_processed", World: []Fill{floor(16, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(10, InputSpec{Move: [2]F32{0.6, 1}, Flags: []string{"using_item"}}), rep(10, InputSpec{Move: [2]F32{1, 1}, ItemUse: f32p(0.35)}), rep(5, fwd("inventory_action")))},
		{Name: "item_use_raw_sneak", World: []Fill{floor(16, stone)}, State: grounded(0.5, 0, 0.5),
			Inputs: cat(rep(10, InputSpec{Move: [2]F32{1, 1}, Raw: true, Flags: []string{"using_consumable"}}), rep(10, InputSpec{Move: [2]F32{1, 1}, Raw: true, Flags: []string{"sneak_down", "sneaking", "start_sneaking"}}))},
		{Name: "jump_boost", World: []Fill{floor(16, stone)}, State: boosted, Inputs: jumpTick(40, 15)},
		{Name: "levitation", World: []Fill{floor(16, stone)}, State: levitate, Inputs: rep(40, fwd())},
		{Name: "slow_falling", World: []Fill{floor(16, stone)}, State: slowFall, Inputs: rep(60, fwd())},
		{Name: "embedded_depenetrate", World: []Fill{floor(8, stone), at(0, 0, 0, stone)}, State: spawn(0.5, 0.5, 0.3), Inputs: rep(20, InputSpec{})},
		{Name: "fall_long", World: []Fill{floor(8, stone)}, State: spawn(0.5, 120, 0.5), Inputs: rep(80, InputSpec{})},
	}
}

func randomScenarios(seed uint64, n int) []Scenario {
	rng := rand.New(rand.NewPCG(seed, 0x5eed))
	floors := []BlockSpec{stone, stone, stone, ice, blueIce, slime, soulSand, honey}
	obstacles := []BlockSpec{stone, slab, topSlab, stairs, fence, wallPost, carpet, web, berry, ladder, vine, bed, water, liquid("water", 3, false), liquid("water", 1, true), powder, scaffold}
	out := make([]Scenario, 0, n)
	for i := range n {
		world := []Fill{floor(12, floors[rng.IntN(len(floors))])}
		for range 4 + rng.IntN(5) {
			x, z := int32(rng.IntN(9)-4), int32(rng.IntN(9)-4)
			world = append(world, box3(x-int32(rng.IntN(2)), -1, z-int32(rng.IntN(2)), x, -1, z, floors[rng.IntN(len(floors))]))
		}
		for range 6 + rng.IntN(10) {
			x, z := int32(rng.IntN(11)-5), int32(rng.IntN(11)-5)
			y := int32(rng.IntN(3))
			b := obstacles[rng.IntN(len(obstacles))]
			if rng.IntN(5) == 0 {
				world = append(world, box3(x, 0, z, x+int32(rng.IntN(3)), y, z, b))
			} else {
				world = append(world, at(x, y, z, b))
			}
		}
		st := grounded(rng.Float32()-0.5, 0, rng.Float32()-0.5)
		st.Yaw = F32(rng.Float32()*360 - 180)
		if rng.IntN(4) == 0 {
			st.OnGround = false
			st.Pos[1] = F32(rng.Float32() * 3)
		}
		if rng.IntN(6) == 0 {
			st.SlowFalling = true
		}
		if rng.IntN(6) == 0 {
			st.JumpBoost = i32p(int32(rng.IntN(3)))
		}
		if rng.IntN(5) == 0 {
			st.SwiftSneak = rng.IntN(4)
		}
		if rng.IntN(5) == 0 {
			st.DepthStrider = rng.IntN(4)
		}
		if rng.IntN(8) == 0 {
			st.LeatherBoots = true
		}
		yaw, pitch := float32(st.Yaw), float32(0)
		sneak, sprint := false, false
		inputs := make([]InputSpec, 50)
		for t := range inputs {
			in := &inputs[t]
			yaw += rng.Float32()*40 - 20
			pitch = max(-90, min(90, pitch+rng.Float32()*20-10))
			in.Yaw, in.Pitch = F32(yaw), F32(pitch)
			switch rng.IntN(6) {
			case 0:
			case 1:
				in.Move = [2]F32{F32(rng.Float32()*2 - 1), F32(rng.Float32()*2 - 1)}
				in.Raw = rng.IntN(2) == 0
			default:
				in.Move = [2]F32{0, 1}
			}
			if rng.IntN(8) == 0 {
				in.Flags = append(in.Flags, "start_jumping", "jumping")
			} else if rng.IntN(10) == 0 {
				in.Flags = append(in.Flags, "jumping")
			}
			if rng.IntN(12) == 0 {
				sneak = !sneak
				if sneak {
					in.Flags = append(in.Flags, "start_sneaking")
				} else {
					in.Flags = append(in.Flags, "stop_sneaking")
				}
			}
			if sneak {
				in.Flags = append(in.Flags, "sneak_down", "sneaking")
			}
			if rng.IntN(10) == 0 {
				sprint = !sprint
				if sprint {
					in.Flags = append(in.Flags, "start_sprinting")
				} else {
					in.Flags = append(in.Flags, "stop_sprinting")
				}
			}
			if rng.IntN(25) == 0 {
				in.Flags = append(in.Flags, "using_item")
			}
			if rng.IntN(40) == 0 {
				in.Motion = &Vec{F32(rng.Float32() - 0.5), F32(rng.Float32() * 0.5), F32(rng.Float32() - 0.5)}
			}
		}
		out = append(out, Scenario{Name: fmt.Sprintf("random_%03d", i), World: world, State: st, Inputs: inputs})
	}
	return out
}
