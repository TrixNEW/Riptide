// Command oracle runs Riptide's fixture scenarios through BedSim and records
// the per-tick results as JSON fixtures for the Zig differential tests.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"strconv"
	"time"

	"github.com/df-mc/dragonfly/server/block"
	"github.com/df-mc/dragonfly/server/block/cube"
	"github.com/df-mc/dragonfly/server/block/model"
	"github.com/df-mc/dragonfly/server/world"
	"github.com/go-gl/mathgl/mgl32"
	"github.com/oomph-ac/bedsim"
	movementblock "github.com/oomph-ac/bedsim/block"
	"github.com/sandertv/gophertunnel/minecraft/protocol/packet"
)

const evidence = "bedsim 9c12b344 + tools/oracle/oracle.patch"

// F32 marshals as the shortest decimal that round-trips to the same float32.
type F32 float32

func (f F32) MarshalJSON() ([]byte, error) {
	return []byte(strconv.FormatFloat(float64(f), 'g', -1, 32)), nil
}

type Vec [3]F32

func vec(v mgl32.Vec3) Vec    { return Vec{F32(v[0]), F32(v[1]), F32(v[2])} }
func (v Vec) mgl() mgl32.Vec3 { return mgl32.Vec3{float32(v[0]), float32(v[1]), float32(v[2])} }
func box(b [6]F32) cube.BBox32 {
	return cube.Box32(float32(b[0]), float32(b[1]), float32(b[2]), float32(b[3]), float32(b[4]), float32(b[5]))
}
func f32p(v float32) *F32 { f := F32(v); return &f }
func i32p(v int32) *int32 { return &v }
func boolp(v bool) *bool  { return &v }

type Sem struct {
	Friction  F32    `json:"friction"`
	AccelMul  F32    `json:"accel_mul"`
	SoulSpeed bool   `json:"soul_speed,omitempty"`
	Climbable bool   `json:"climbable,omitempty"`
	Cobweb    bool   `json:"cobweb,omitempty"`
	Honey     bool   `json:"honey,omitempty"`
	Carpet    bool   `json:"carpet,omitempty"`
	Bounce    string `json:"bounce,omitempty"`
	Inside    string `json:"inside,omitempty"`
	Traversal string `json:"traversal,omitempty"`
}

type LiquidSpec struct {
	Kind    string `json:"kind"`
	Level   int    `json:"level"`
	Falling bool   `json:"falling,omitempty"`
}

// BlockSpec describes one block state. Kind is "block", "liquid" or "air".
type BlockSpec struct {
	Kind          string      `json:"kind"`
	Boxes         [][6]F32    `json:"boxes,omitempty"`
	Sem           Sem         `json:"sem"`
	Liquid        *LiquidSpec `json:"liquid,omitempty"`
	SolidFaces    uint8       `json:"solid_faces,omitempty"`
	Barrier       bool        `json:"barrier,omitempty"`
	Bubble        string      `json:"bubble,omitempty"`
	BubbleSurface *bool       `json:"bubble_surface,omitempty"`
}

// Fill sets every cell in the inclusive box to Block. Later fills win.
type Fill struct {
	From  [3]int32  `json:"from"`
	To    [3]int32  `json:"to"`
	Block BlockSpec `json:"block"`
}

type StateSpec struct {
	Pos           Vec    `json:"pos"`
	Vel           Vec    `json:"vel"`
	Yaw           F32    `json:"yaw"`
	Pitch         F32    `json:"pitch"`
	OnGround      bool   `json:"on_ground,omitempty"`
	Sneaking      bool   `json:"sneaking,omitempty"`
	Crawling      bool   `json:"crawling,omitempty"`
	Swimming      bool   `json:"swimming,omitempty"`
	Gliding       bool   `json:"gliding,omitempty"`
	Sprinting     bool   `json:"sprinting,omitempty"`
	Height        F32    `json:"height"`
	Speed         F32    `json:"speed"`
	DefaultSpeed  F32    `json:"default_speed"`
	Gravity       F32    `json:"gravity"`
	NoGravity     bool   `json:"no_gravity,omitempty"`
	FallDistance  F32    `json:"fall_distance"`
	GlideBoost    int    `json:"glide_boost,omitempty"`
	SwimMul       F32    `json:"swim_multiplier"`
	DolphinTicks  int    `json:"dolphin_ticks,omitempty"`
	JumpBoost     *int32 `json:"jump_boost,omitempty"`
	Levitation    *int32 `json:"levitation,omitempty"`
	SlowFalling   bool   `json:"slow_falling,omitempty"`
	Weaving       bool   `json:"weaving,omitempty"`
	DepthStrider  int    `json:"depth_strider,omitempty"`
	SoulSpeed     int    `json:"soul_speed,omitempty"`
	SwiftSneak    int    `json:"swift_sneak,omitempty"`
	Riptide       int    `json:"riptide,omitempty"`
	LeatherBoots  bool   `json:"leather_boots,omitempty"`
	Elytra        bool   `json:"elytra,omitempty"`
	RiptideInRain bool   `json:"riptide_in_rain,omitempty"`
}

type TeleportSpec struct {
	Pos      Vec `json:"pos"`
	Smoothed int `json:"smoothed"`
}

type InputSpec struct {
	Move         [2]F32        `json:"move"`
	Raw          bool          `json:"raw,omitempty"`
	Yaw          F32           `json:"yaw"`
	Pitch        F32           `json:"pitch"`
	ItemUse      *F32          `json:"item_use,omitempty"`
	Flags        []string      `json:"flags,omitempty"`
	Motion       *Vec          `json:"motion,omitempty"`
	Teleport     *TeleportSpec `json:"teleport,omitempty"`
	RiptideReady bool          `json:"riptide_ready,omitempty"`
}

// Expect omits default values: outcome "normal", false, and zero.
type Expect struct {
	Outcome   string `json:"outcome,omitempty"`
	Pos       Vec    `json:"pos"`
	Vel       Vec    `json:"vel"`
	Mov       Vec    `json:"mov"`
	OnGround  bool   `json:"on_ground,omitempty"`
	Collide   uint8  `json:"collide,omitempty"`
	Fall      F32    `json:"fall,omitempty"`
	Height    F32    `json:"height"`
	Sneaking  bool   `json:"sneaking,omitempty"`
	Crawling  bool   `json:"crawling,omitempty"`
	Swimming  bool   `json:"swimming,omitempty"`
	Gliding   bool   `json:"gliding,omitempty"`
	JumpDelay int    `json:"jump_delay,omitempty"`
	Riptide   int    `json:"riptide,omitempty"`
}

func collideBits(x, y, z bool) uint8 {
	var b uint8
	if x {
		b |= 1
	}
	if y {
		b |= 2
	}
	if z {
		b |= 4
	}
	return b
}

type Scenario struct {
	Name         string      `json:"name"`
	Evidence     string      `json:"evidence"`
	SprintLegacy bool        `json:"sprint_legacy,omitempty"`
	World        []Fill      `json:"world"`
	State        StateSpec   `json:"state"`
	Inputs       []InputSpec `json:"inputs"`
	Expected     []Expect    `json:"expected"`
}

// fixtureBlock is a registry-free stand-in for a non-liquid block.
type fixtureBlock struct{ id int }

func (b fixtureBlock) EncodeBlock() (string, map[string]any) {
	return "riptide:fixture_" + strconv.Itoa(b.id), nil
}
func (fixtureBlock) Hash() (uint64, uint64)  { return 0, math.MaxUint64 }
func (fixtureBlock) Model() world.BlockModel { return model.Solid{} }

type carpetBlock struct{ fixtureBlock }

func (b carpetBlock) EncodeBlock() (string, map[string]any) {
	return "riptide:fixture_" + strconv.Itoa(b.id) + "_carpet", nil
}

type cell struct {
	spec  *BlockSpec
	block world.Block
}

type fixtureWorld struct {
	cells map[cube.Pos]cell
	specs []*BlockSpec
}

func newWorld(fills []Fill) *fixtureWorld {
	w := &fixtureWorld{cells: map[cube.Pos]cell{}}
	for i := range fills {
		spec := &fills[i].Block
		id := len(w.specs)
		w.specs = append(w.specs, spec)
		var b world.Block = fixtureBlock{id}
		switch {
		case spec.Kind == "air":
			b = block.Air{}
		case spec.Kind == "liquid":
			b = liquidBlock(spec.Liquid)
		case spec.Sem.Carpet:
			b = carpetBlock{fixtureBlock{id}}
		}
		f := fills[i]
		for x := f.From[0]; x <= f.To[0]; x++ {
			for y := f.From[1]; y <= f.To[1]; y++ {
				for z := f.From[2]; z <= f.To[2]; z++ {
					w.cells[cube.Pos{int(x), int(y), int(z)}] = cell{spec, b}
				}
			}
		}
	}
	return w
}

func liquidBlock(l *LiquidSpec) world.Liquid {
	depth := 8 - l.Level
	if l.Kind == "lava" {
		return block.Lava{Still: l.Level == 0, Depth: depth, Falling: l.Falling}
	}
	return block.Water{Still: l.Level == 0, Depth: depth, Falling: l.Falling}
}

func (w *fixtureWorld) Block(pos cube.Pos) world.Block {
	if c, ok := w.cells[pos]; ok {
		return c.block
	}
	return block.Air{}
}

func (w *fixtureWorld) spec(pos cube.Pos) *BlockSpec {
	if c, ok := w.cells[pos]; ok {
		return c.spec
	}
	return nil
}

func (w *fixtureWorld) BlockCollisions(pos cube.Pos) []cube.BBox32 {
	s := w.spec(pos)
	if s == nil {
		return nil
	}
	out := make([]cube.BBox32, 0, len(s.Boxes))
	for _, b := range s.Boxes {
		out = append(out, box(b))
	}
	return out
}

// GetNearbyBBoxes gathers in Riptide's order: x, then z, then y, with one
// extra layer below for shapes taller than a block.
func (w *fixtureWorld) GetNearbyBBoxes(aabb cube.BBox32) []cube.BBox32 {
	min, max := aabb.Min(), aabb.Max()
	x0, x1 := int(math.Floor(float64(min[0]))), int(math.Floor(float64(max[0])))
	y0, y1 := int(math.Floor(float64(min[1])))-1, int(math.Floor(float64(max[1])))
	z0, z1 := int(math.Floor(float64(min[2]))), int(math.Floor(float64(max[2])))
	var out []cube.BBox32
	for x := x0; x <= x1; x++ {
		for z := z0; z <= z1; z++ {
			for y := y0; y <= y1; y++ {
				pos := cube.Pos{x, y, z}
				origin := mgl32.Vec3{float32(x), float32(y), float32(z)}
				for _, b := range w.BlockCollisions(pos) {
					t := b.Translate(origin)
					if bedsim.BBHasZeroVolume(t) || !t.IntersectsWith(aabb) {
						continue
					}
					out = append(out, t)
				}
			}
		}
	}
	return out
}

func (*fixtureWorld) IsChunkLoaded(int32, int32) bool { return true }

func (w *fixtureWorld) Liquid(pos cube.Pos) (world.Liquid, bool) {
	s := w.spec(pos)
	if s == nil || s.Liquid == nil {
		return nil, false
	}
	return liquidBlock(s.Liquid), true
}

func (w *fixtureWorld) LiquidFlowFaceClosed(pos cube.Pos, face cube.Face) bool {
	s := w.spec(pos)
	if s == nil {
		return false
	}
	bit := map[cube.Face]uint8{cube.FaceWest: 1, cube.FaceEast: 2, cube.FaceNorth: 4, cube.FaceSouth: 8}[face]
	return s.SolidFaces&bit != 0
}

func (w *fixtureWorld) LiquidFlowBarrier(pos cube.Pos) bool {
	s := w.spec(pos)
	return s != nil && s.Barrier
}

func (w *fixtureWorld) BubbleColumn(pos cube.Pos) (bedsim.BubbleColumnDirection, bool) {
	s := w.spec(pos)
	if s == nil || s.Bubble == "" {
		return 0, false
	}
	if s.Bubble == "down" {
		return bedsim.BubbleColumnDown, true
	}
	return bedsim.BubbleColumnUp, true
}

func (w *fixtureWorld) BubbleColumnSurface(pos cube.Pos) (bool, bool) {
	s := w.spec(pos)
	if s == nil || s.BubbleSurface == nil {
		return false, false
	}
	return *s.BubbleSurface, true
}

func (w *fixtureWorld) BlockMovementSemantics(b world.Block) movementblock.MovementSemantics {
	var id int
	switch t := b.(type) {
	case fixtureBlock:
		id = t.id
	case carpetBlock:
		id = t.id
	default:
		return movementblock.MovementSemantics{GroundFriction: 0.6, GroundAccelerationFrictionMultiplier: 1}
	}
	s := w.specs[id].Sem
	return movementblock.MovementSemantics{
		GroundFriction:                           float32(s.Friction),
		GroundAccelerationFrictionMultiplier:     float32(s.AccelMul),
		SoulSpeedNeutralizesAccelerationFriction: s.SoulSpeed,
		Climbable:                                s.Climbable,
		Cobweb:                                   s.Cobweb,
		Honey:                                    s.Honey,
		Bounce:                                   map[string]movementblock.Bounce{"": 0, "slime": movementblock.BounceSlime, "bed": movementblock.BounceBed}[s.Bounce],
		InsideMovement:                           map[string]movementblock.InsideMovement{"": 0, "sweet_berry_bush": movementblock.InsideMovementSweetBerryBush, "powder_snow": movementblock.InsideMovementPowderSnow}[s.Inside],
		Traversal:                                map[string]movementblock.Traversal{"": 0, "scaffolding": movementblock.TraversalScaffolding, "powder_snow": movementblock.TraversalPowderSnow}[s.Traversal],
	}
}

type effects StateSpec

func (e *effects) GetEffect(id int32) (int32, bool) {
	switch {
	case id == packet.EffectJumpBoost && e.JumpBoost != nil:
		return *e.JumpBoost, true
	case id == packet.EffectLevitation && e.Levitation != nil:
		return *e.Levitation, true
	case id == packet.EffectSlowFalling && e.SlowFalling:
		return 0, true
	case id == bedsim.EffectWeaving && e.Weaving:
		return 0, true
	}
	return 0, false
}

func (e *effects) HasElytra() bool { return e.Elytra }

func (e *effects) EnchantmentLevel(m bedsim.MovementEnchantment) int {
	switch m {
	case bedsim.EnchantmentDepthStrider:
		return e.DepthStrider
	case bedsim.EnchantmentSoulSpeed:
		return e.SoulSpeed
	case bedsim.EnchantmentSwiftSneak:
		return e.SwiftSneak
	case bedsim.EnchantmentRiptide:
		return e.Riptide
	}
	return 0
}

func (e *effects) WearingLeatherBoots() bool { return e.LeatherBoots }

var outcomes = map[bedsim.SimulationOutcome]string{
	bedsim.SimulationOutcomeNormal:             "normal",
	bedsim.SimulationOutcomeTeleport:           "teleport",
	bedsim.SimulationOutcomeUnreliable:         "client_authoritative",
	bedsim.SimulationOutcomeUnloadedChunk:      "unloaded",
	bedsim.SimulationOutcomeImmobileOrNotReady: "immobile",
	bedsim.SimulationOutcomeMounted:            "mounted",
	bedsim.SimulationOutcomeInvalidInput:       "invalid_input",
}

func initialState(s StateSpec) *bedsim.MovementState {
	rot := mgl32.Vec3{float32(s.Pitch), float32(s.Yaw), float32(s.Yaw)}
	st := &bedsim.MovementState{
		Pos:                     s.Pos.mgl(),
		Vel:                     s.Vel.mgl(),
		Rotation:                rot,
		LastRotation:            rot,
		OnGround:                s.OnGround,
		Sneaking:                s.Sneaking,
		Crawling:                s.Crawling,
		Swimming:                s.Swimming,
		Gliding:                 s.Gliding,
		Sprinting:               s.Sprinting,
		Size:                    mgl32.Vec3{0.6, float32(s.Height), 1},
		StandingHeight:          1.8,
		SneakingHeight:          1.49,
		CrawlingHeight:          0.6,
		MovementSpeed:           float32(s.Speed),
		DefaultMovementSpeed:    float32(s.DefaultSpeed),
		AirSpeed:                0.02,
		JumpStrength:            0.42,
		Gravity:                 float32(s.Gravity),
		HasGravity:              !s.NoGravity,
		FallDistance:            float32(s.FallDistance),
		GlideBoostTicks:         int64(s.GlideBoost),
		SwimSpeedMultiplier:     float32(s.SwimMul),
		DolphinBoostTicks:       int64(s.DolphinTicks),
		UnderwaterMovementSpeed: 0.02,
		LavaMovementSpeed:       0.02,
		RiptideInRain:           s.RiptideInRain,
		ServerSprintApplied:     true,
		Ready:                   true,
		Alive:                   true,
		GameMode:                packet.GameTypeSurvival,
		TicksSinceKnockback:     1,
		TicksSinceTeleport:      1,
	}
	if s.Sprinting {
		st.AirSpeed = bedsim.SprintAirSpeed
	}
	return st
}

var flagSetters = map[string]func(*bedsim.InputState){
	"horizontal_collision":  func(i *bedsim.InputState) { i.HorizontalCollision = true },
	"vertical_collision":    func(i *bedsim.InputState) { i.VerticalCollision = true },
	"start_sprinting":       func(i *bedsim.InputState) { i.StartSprinting = true },
	"stop_sprinting":        func(i *bedsim.InputState) { i.StopSprinting = true },
	"sprint_down":           func(i *bedsim.InputState) { i.SprintDown = true },
	"start_sneaking":        func(i *bedsim.InputState) { i.StartSneaking = true },
	"stop_sneaking":         func(i *bedsim.InputState) { i.StopSneaking = true },
	"sneak_down":            func(i *bedsim.InputState) { i.SneakDown = true },
	"sneaking":              func(i *bedsim.InputState) { i.Sneaking = true },
	"start_jumping":         func(i *bedsim.InputState) { i.StartJumping = true },
	"jumping":               func(i *bedsim.InputState) { i.Jumping = true },
	"auto_jumping_in_water": func(i *bedsim.InputState) { i.AutoJumpingInWater = true },
	"ascend_block":          func(i *bedsim.InputState) { i.AscendBlock = true },
	"descend_block":         func(i *bedsim.InputState) { i.DescendBlock = true },
	"start_swimming":        func(i *bedsim.InputState) { i.StartSwimming = true },
	"stop_swimming":         func(i *bedsim.InputState) { i.StopSwimming = true },
	"want_down":             func(i *bedsim.InputState) { i.WantDown = true },
	"want_down_slow":        func(i *bedsim.InputState) { i.WantDownSlow = true },
	"start_crawling":        func(i *bedsim.InputState) { i.StartCrawling = true },
	"stop_crawling":         func(i *bedsim.InputState) { i.StopCrawling = true },
	"start_gliding":         func(i *bedsim.InputState) { i.StartGliding = true },
	"stop_gliding":          func(i *bedsim.InputState) { i.StopGliding = true },
	"using_consumable":      func(i *bedsim.InputState) { i.UsingConsumable = true },
	"using_item":            func(i *bedsim.InputState) { i.UsingItem = true },
	"using_spear":           func(i *bedsim.InputState) { i.UsingSpear = true },
	"inventory_action":      func(i *bedsim.InputState) { i.InventoryAction = true },
	"start_spin_attack":     func(i *bedsim.InputState) { i.StartSpinAttack = true },
	"stop_spin_attack":      func(i *bedsim.InputState) { i.StopSpinAttack = true },
}

func run(sc *Scenario) error {
	w := newWorld(sc.World)
	e := effects(sc.State)
	sim := &bedsim.Simulator{
		World:          w,
		BlockSemantics: w,
		Liquids:        w,
		Effects:        &e,
		Inventory:      &e,
		Equipment:      &e,
		Options: bedsim.SimulationOptions{
			Mode:                       bedsim.SimulationModePassive,
			IgnoreClientStepTiebreaker: true,
			SwimWaterGraceTicks:        10,
		},
	}
	if sc.SprintLegacy {
		sim.Options.SprintTiming = bedsim.SprintTimingLegacy
	}
	st := initialState(sc.State)
	sc.Evidence = evidence
	sc.Expected = sc.Expected[:0]
	for _, in := range sc.Inputs {
		input := bedsim.InputState{
			MoveVector:      mgl32.Vec2{float32(in.Move[0]), float32(in.Move[1])},
			MoveVectorIsRaw: in.Raw,
			Pitch:           float32(in.Pitch),
			Yaw:             float32(in.Yaw),
			HeadYaw:         float32(in.Yaw),
		}
		if in.ItemUse != nil {
			v := float32(*in.ItemUse)
			input.ItemUseMovementModifier = &v
		}
		for _, f := range in.Flags {
			set, ok := flagSetters[f]
			if !ok {
				return fmt.Errorf("%s: unknown flag %q", sc.Name, f)
			}
			set(&input)
		}
		if in.Motion != nil {
			st.QueueKnockback(in.Motion.mgl())
		}
		if in.Teleport != nil {
			st.QueueTeleport(in.Teleport.Pos.mgl(), in.Teleport.Smoothed > 0, uint64(in.Teleport.Smoothed))
		}
		st.RiptideReady = in.RiptideReady
		r := sim.Simulate(st, input)
		outcome := outcomes[r.Outcome]
		if outcome == "normal" {
			outcome = ""
		}
		sc.Expected = append(sc.Expected, Expect{
			Outcome:   outcome,
			Pos:       vec(st.Pos),
			Vel:       vec(st.Vel),
			Mov:       vec(st.Mov),
			OnGround:  st.OnGround,
			Collide:   collideBits(st.CollideX, st.CollideY, st.CollideZ),
			Fall:      F32(st.FallDistance),
			Height:    F32(st.Size[1]),
			Sneaking:  st.Sneaking,
			Crawling:  st.Crawling,
			Swimming:  st.Swimming,
			Gliding:   st.Gliding,
			JumpDelay: int(st.JumpDelay),
			Riptide:   st.RiptideTicks,
		})
	}
	return nil
}

// benchmark replays every scenario like Riptide's "fixtures" benchmark:
// worlds and inputs are prepared up front and only ticks are timed.
func benchmark(scenarios []Scenario) {
	type prepared struct {
		sim    *bedsim.Simulator
		state  bedsim.MovementState
		inputs []bedsim.InputState
		events []InputSpec
	}
	ps := make([]prepared, len(scenarios))
	ticks := 0
	for i := range scenarios {
		sc := &scenarios[i]
		w := newWorld(sc.World)
		e := effects(sc.State)
		sim := &bedsim.Simulator{World: w, BlockSemantics: w, Liquids: w, Effects: &e, Inventory: &e, Equipment: &e,
			Options: bedsim.SimulationOptions{Mode: bedsim.SimulationModePassive, IgnoreClientStepTiebreaker: true, SwimWaterGraceTicks: 10}}
		if sc.SprintLegacy {
			sim.Options.SprintTiming = bedsim.SprintTimingLegacy
		}
		p := prepared{sim: sim, state: *initialState(sc.State), events: sc.Inputs}
		for _, in := range sc.Inputs {
			input := bedsim.InputState{MoveVector: mgl32.Vec2{float32(in.Move[0]), float32(in.Move[1])}, MoveVectorIsRaw: in.Raw,
				Pitch: float32(in.Pitch), Yaw: float32(in.Yaw), HeadYaw: float32(in.Yaw)}
			if in.ItemUse != nil {
				v := float32(*in.ItemUse)
				input.ItemUseMovementModifier = &v
			}
			for _, f := range in.Flags {
				flagSetters[f](&input)
			}
			p.inputs = append(p.inputs, input)
		}
		ticks += len(p.inputs)
		ps[i] = p
	}
	const reps, runs = 20, 5
	samples := make([]float64, runs)
	var allocs uint64
	for r := range samples {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		start := time.Now()
		for range reps {
			for i := range ps {
				st := ps[i].state.Clone()
				for t := range ps[i].inputs {
					ev := &ps[i].events[t]
					if ev.Motion != nil {
						st.QueueKnockback(ev.Motion.mgl())
					}
					if ev.Teleport != nil {
						st.QueueTeleport(ev.Teleport.Pos.mgl(), ev.Teleport.Smoothed > 0, uint64(ev.Teleport.Smoothed))
					}
					st.RiptideReady = ev.RiptideReady
					ps[i].sim.Simulate(&st, ps[i].inputs[t])
				}
			}
		}
		samples[r] = float64(time.Since(start).Nanoseconds()) / float64(reps*ticks)
		runtime.ReadMemStats(&after)
		allocs = (after.Mallocs - before.Mallocs) / uint64(reps*ticks)
		_ = r
	}
	sort.Float64s(samples)
	fmt.Printf("fixtures %8.1f ns/tick %8.2f Mticks/s (%d scenarios, %d ticks, %d allocs/tick, %s)\n",
		samples[runs/2], 1e3/samples[runs/2], len(ps), ticks, allocs, runtime.Version())
}

func main() {
	out := flag.String("out", "fixtures.json", "output file")
	seed := flag.Uint64("seed", 1, "random scenario seed")
	random := flag.Int("random", 120, "number of random scenarios")
	bench := flag.Bool("bench", false, "benchmark fixture replay instead of writing fixtures")
	flag.Parse()
	scenarios := append(handwritten(), randomScenarios(*seed, *random)...)
	if *bench {
		benchmark(scenarios)
		return
	}
	for i := range scenarios {
		if err := run(&scenarios[i]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	data, err := json.Marshal(scenarios)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("wrote %d scenarios to %s\n", len(scenarios), *out)
}
