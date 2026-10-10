-- Abyssal Stormfin (user's design doc, 9 Oct 2026; rethemed from moon to thunder to fit the storm
-- arena): an aquatic predator that hunts under the sea surface and is only damageable while out of
-- the water. Two attacks: Thunder Breach (a parryable leap at the player) and Storm Bolt (hover,
-- charge, fire a reflectable lightning projectile).
-- All numbers are the doc's starting balance targets (V2: to be tested).
local StormfinConfig = {
	Enabled = true,
	Count = 2, -- simultaneous Stormfins (doc: 2-3 initially)
	SpawnCenter = Vector3.new(0, 0, 0),
	SpawnRadius = { 30, 55 },
	RespawnDelay = 6, -- sandbox: a slain Stormfin comes back after this long

	Health = 180,
	AggroRange = 160,
	SurfaceY = 0, -- the sea surface
	SwimDepth = -2.4, -- centre of the body while submerged
	SubmergedBelow = -0.8, -- below this height it can't be damaged
	BodyLength = 8.5, -- matches the rigged model (ReplicatedStorage/EnemyModels/Stormfin)
	HitboxSize = Vector3.new(2.6, 2.4, 8.5),
	ThroatOffset = Vector3.new(0, -0.6, -2.6), -- weak point, relative to the body centre (-Z = forward)
	ThroatSize = Vector3.new(1.8, 1.4, 1.8),
	WeakPointMultiplier = 1.5, -- throat damage while charging a bolt

	Swim = {
		Speed = 24, -- studs/s
		MinTime = 1.0,
		MaxTime = 2.2, -- keep underwater phases short: ~40-50% of the cycle should be targetable
		KeepDistance = { 14, 24 }, -- where it repositions to, from the player
		Curve = 0.45, -- how far the path bows sideways (fraction of its length)
		ArriveSpeed = 16, -- studs/s it is still swimming at when it reaches its spot (it never stops dead; closer to Speed = a steadier pace)
		AntiCampRange = 7, -- a player this close makes it attack right away
		IdleRadius = 18, -- circling radius when nobody is in range
	},

	AttackStagger = 1.4, -- seconds between any two Stormfins starting attacks
	-- Fixed attack order, looped (user, 9 Oct 2026: "dive, dive, dive, shoot"). Set to {} to go back
	-- to the doc's weighted random choice (Breach/Bolt Weight + MaxRepeat).
	Pattern = { "Breach", "Breach", "Breach", "Bolt" },
	MaxRepeat = 2, -- random mode only: never the same attack more than twice in a row

	Breach = {
		Weight = 40,
		Windup = 0.7, -- crackling ripples (parryable cue)
		CommitBefore = 0.2, -- locks onto the player's position this long before launch (no midair homing)
		Speed = 46, -- studs/s across the ground during the leap (gravity decides the arc and where it lands)
		MinAimTime = 0.17, -- seconds from launch to the player at the least (a camper right on top of it)...
		MaxAimTime = 0.65, -- ...and at the most: a farther player gets a faster leap instead of a sky-high one...
		MaxSpeedBoost = 1.3, -- ...up to this many times Speed across; past that (~39 studs) it falls short
		MaxRise = 3, -- studs it may climb above the aim point (a jumping player gets a longer, flatter leap, not a sky-high one)
		AimHeight = 3, -- passes through the player at about chest height
		Damage = 25,
		HitRadius = 3.2,
		HitBack = 0.05, -- hit capsule runs from the head to this fraction of BodyLength behind the centre (0.3 = the old whole-body hit)
		Parryable = true,
		KnockBack = 14, -- studs/s: a parried breach is knocked back...
		KnockUp = 16, -- ...and up (studs/s); it falls under Physics.Gravity
		Splashdown = 0.25, -- seconds after it hits the water before it starts floundering...
		StunTime = 1.3, -- ...on the surface, open to fire
	},

	Bolt = {
		Weight = 60,
		RiseTime = 0.5,
		HoverHeight = { 6, 9 },
		HoverTime = 2.0,
		ChargeStart = 0.35, -- seconds into the hover
		ChargeTime = 0.8,
		Damage = 18,
		Speed = 62,
		Radius = 0.9,
		Range = 170,
		Parryable = true,
		Reflectable = true,
		ReflectSpeed = 95,
		ReflectDamage = 45,
	},

	Dive = {
		Push = 6, -- studs/s forward kick as it tips over into a dive (added to its momentum)
		Hop = 5, -- studs/s up; it then falls under Physics.Gravity
	},
	DeathFloatTime = 0.7, -- floats awash (after falling into the water, if it died in the air) before the glow fades and it sinks
	DeathSinkTime = 2.2,

	-- How it moves (StormfinMotion): momentum carries between moves, and anything airborne falls.
	Physics = {
		Gravity = 110, -- studs/s²: one gravity for every unpowered arc (leap, knockback, dive, falling dead). The world's is 196.2; lower gives the leaps some hang time
		WaterDrag = 4.5, -- 1/s: how fast the water bleeds off speed after a splash-down (or when a swim runs over)
		Buoyancy = 7, -- 1/s: how quickly it settles back to its depth after plunging in (critically damped)
		SplashBuoyancy = 18, -- 1/s: the same for a parried fin landing on its back: it slaps the surface instead of plunging under (stays open to fire)
		Glide = 0.1, -- seconds it glides on underwater after a leap or dive before it swims on (the swim carries the rest of its momentum)
		LiftOmega = 8, -- 1/s: stiffness of the spring it rises and hovers on...
		LiftDamping = 0.6, -- ...and its damping (below 1 overshoots: 0.6 is about 10%)
		FloatOmega = 8, -- the spring it bobs on while floundering on the surface
		FloatDamping = 0.5,
	},

	Visuals = {
		BodyColor = Color3.fromRGB(14, 18, 48), -- deep midnight blue
		FinColor = Color3.fromRGB(45, 60, 150),
		MarkingColor = Color3.fromRGB(110, 175, 255), -- glowing electric blue
		ArcColor = Color3.fromRGB(190, 220, 255), -- crackling lightning
		EyeColor = Color3.fromRGB(225, 240, 255), -- electric white
		RippleColor = Color3.fromRGB(120, 175, 255),
		-- Storm Bolt: blue-white lightning, clearly different from the player's purple, which a
		-- reflected bolt takes on.
		BoltColor = Color3.fromRGB(185, 215, 255),
		FinFlapSpeed = 7, -- radians/s swimming (hover is slower)
	},
}

return StormfinConfig
