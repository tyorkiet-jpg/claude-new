-- Abyssal Stalker (user's design doc, 10 Oct 2026): a fast, four-legged amphibious melee predator
-- that hunts players across the sea surface. Three parryable attacks: Rending Bite, Hunter's
-- Lunge and Predator's Frenzy (a three-hit combo; parrying all three staggers it). No underwater
-- invulnerability: it can be shot at any time.
-- All numbers are the doc's prototype values (to be tested).
local StalkerConfig = {
	Enabled = true,
	Count = 1, -- simultaneous Stalkers (3 for pack play; 1 for testing, user 10 Oct 2026)
	SpawnCenter = Vector3.new(0, 0, 0),
	SpawnRadius = { 22, 40 },
	RespawnDelay = 8, -- sandbox: a slain Stalker comes back after this long

	Health = 140,
	-- Sized to the rigged model (ReplicatedStorage/EnemyModels/Stalker: 4 studs tall, 9 long with
	-- the tail, snout 3.6 ahead of the body centre).
	BodyHeight = 2.8, -- body centre above the floor
	HitboxSize = Vector3.new(2.6, 2.2, 6), -- the body (the head is its own part, below)
	HeadSize = Vector3.new(1.4, 1.2, 1.8), -- a part named "Head": gunfire crits on it
	-- Named reference points on the hitbox (studs from the body centre, -Z = forward). Combat logic
	-- only uses these names; StalkerVisuals puts attachments with the same names on the model.
	Points = {
		Head = Vector3.new(0, 0.3, -3.0),
		BiteOrigin = Vector3.new(0, -0.1, -3.5),
		LeftClaw = Vector3.new(-1.0, -1.3, -3.0),
		RightClaw = Vector3.new(1.0, -1.3, -3.0),
	},

	DetectRange = 65, -- notices players this close
	LoseRange = 95, -- gives up on a target this far away
	SwitchMargin = 0.7, -- swaps to another player only if they are this much closer than the current one

	Patrol = {
		Radius = 14, -- wanders this far from its spawn while idle
		Speed = 7,
		PauseTime = { 1.5, 3.5 }, -- stands and looks around between wanders
	},

	Move = {
		ChaseSpeed = 30, -- studs/s
		Accel = 60, -- studs/s²
		Decel = 80,
		TurnRate = 5.5, -- radians/s while running: turns smoothly, never snaps
		AttackTurnRate = 2.4, -- radians/s while winding up (tracks you a little, can be outpaced)
		SlowTurnAngle = 1.3, -- radians off its heading at which it slows to turn
		AvoidDistance = 7, -- whisker length for steering round obstacles
		Separation = 6, -- studs: Stalkers push apart closer than this...
		SeparationStrength = 1.4, -- ...this hard
		MinGap = 4, -- studs: two bodies are pushed apart closer than this, even mid-attack
	},

	Pack = {
		MaxAttackers = 2, -- at most this many Stalkers attack one player at once
		SlotSpread = 55, -- degrees between Stalkers spreading round the same target
		HoldDistance = 9, -- a Stalker waiting for its turn circles at this distance
	},

	AttackCooldown = { 0.4, 0.8 }, -- seconds after an attack (and its reposition) before the next
	Reposition = {
		Time = { 0.6, 1.0 }, -- briefly circles away after attacking
		Radius = { 7, 10 },
		Swing = { 40, 80 }, -- degrees round the target
		Speed = 18,
	},

	Bite = {
		Weight = 60,
		Range = 4.8, -- studs from the target before it bites
		Damage = 18,
		Windup = 0.35,
		Active = 0.15,
		Recovery = 0.45,
		HitRadius = 2.6,
		Snap = 10, -- studs/s forward as the jaws snap
		Parryable = true,
	},

	Lunge = {
		MinRange = 8,
		MaxRange = 18,
		MaxDistance = 18, -- covers up to this far
		Overshoot = 2, -- lands this far past where you stood
		Damage = 25,
		Windup = 0.6,
		CommitBefore = 0.2, -- locks the trajectory this long before launch (no homing in the air)
		FlightTime = { 0.3, 0.45 }, -- short to long leaps
		Height = 2.6, -- arc height
		HitRadius = 3,
		Recovery = 0.65,
		Cooldown = 3.5,
		MaxAngle = 40, -- degrees: only lunges at a target roughly in front
		Parryable = true,
	},

	Frenzy = {
		Weight = 40,
		Range = 4.8,
		Cooldown = 5,
		-- Each strike: its own windup and telegraph, resolved on its own. ~1.6s in total.
		Strikes = {
			{ Kind = "LeftClaw", Point = "LeftClaw", Windup = 0.28, Damage = 12 },
			{ Kind = "RightClaw", Point = "RightClaw", Windup = 0.24, Damage = 12 },
			{ Kind = "Bite", Point = "BiteOrigin", Windup = 0.28, Damage = 20 },
		},
		Active = 0.1,
		Gap = 0.08, -- after each strike before the next windup
		Step = 5, -- studs/s it presses forward during the combo
		HitRadius = 2.8,
		Recovery = 0.35,
		StaggerTime = 1.2, -- parry all three strikes of one combo and it staggers this long
		Parryable = true,
	},

	Recoil = {
		Time = 0.6, -- a parried bite or lunge knocks it back and it can't act for this long
		Speed = 14, -- studs/s knockback
	},
	CloseDistance = 3.5, -- studs: it stops pressing forward when its target is this close
	StaggerKnock = 6, -- studs/s knockback when the frenzy stagger starts
	Gravity = 110, -- studs/s² when it falls out of an interrupted lunge
	DeathTime = 2.5, -- the body lies there this long before it's removed

	Visuals = {
		SkinColor = Color3.fromRGB(26, 28, 34), -- dark charcoal
		ScaleColor = Color3.fromRGB(62, 74, 90), -- blue-grey armoured scales
		MarkingColor = Color3.fromRGB(60, 220, 255), -- cyan glowing markings
		EyeColor = Color3.fromRGB(170, 245, 255),
		Smoothing = 16, -- 1/s: how quickly the drawn body follows the server hitbox
	},
}

return StalkerConfig
