-- Client visuals for the Abyssal Stalker: the user's rigged model (ReplicatedStorage/EnemyModels/
-- Stalker, a skinned MeshPart; rig made by Tools/Stalker/rig_stalker.py) animated procedurally by
-- driving its bones. The server's invisible hitbox model (StalkerService, in Workspace/Enemies)
-- decides everything; this follows it and reads its attributes (Action, ActionStep, ActionStrike,
-- ActionPoint, Leap*, ParrySeq) to pose the body and show the cyan parry telegraph.
--
-- Rig (model space: origin on the floor under the middle of the body, -Z forward, -X = its left):
-- Root > Hips > Spine > Chest > Neck > Head > Jaw; Hips > Tail1..Tail5; Hips > BackThigh > BackShin >
-- BackFoot (hock) > BackToes (ball) for each hind leg; Chest > FrontUpper > FrontLower > FrontFoot
-- (wrist) for each front leg. The named points the telegraphs use (Head, BiteOrigin, LeftClaw,
-- RightClaw, the same names as StalkerConfig.Points) are attachments that follow their bones.
--
-- How it moves (so it reads as an animal, not a puppet):
-- - The body follows the server hitbox on critically damped springs (position and heading), which
--   gives smooth velocity, acceleration and turn rate to drive everything else.
-- - Feet are planted in the WORLD: a foot on the ground stays exactly where it landed (no sliding)
--   and swings to a landing spot predicted from the body's velocity. The gait phase sets when each
--   foot steps: a walk blends into a trot and a rotary gallop with speed; step rate and stride
--   follow the actual speed. Standing or turning on the spot, it takes corrective steps instead.
-- - The torso is alive: it bobs with the footfalls, the spine flexes through the gallop and bends
--   into turns, the body banks into turns and leans when it speeds up or brakes, and it shifts its
--   weight and breathes when still.
-- - The head stays steady while the body bobs (predators keep their eyes still) and tracks the
--   nearest player on an underdamped spring; the neck mostly rotates rather than stretching.
-- - The tail is a chain of springs with inertia: it swings, follows through after turns, and
--   rises a little at a gallop as a counterweight.
-- - Attacks are keyed off the server clock with anticipation, action and follow-through; every
--   windup still peaks exactly on ActionStrike (when the telegraph ring closes and the hit goes
--   live). A change of action never pops: the jump is eased out over a few frames.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config.StalkerConfig)
local EnemyVisuals = require(script.Parent.EnemyVisuals)
local VFXUtil = require(script.Parent.VFXUtil)

local StalkerVisuals = {}

local Visuals = Config.Visuals
local UP = Vector3.yAxis
local WHITE = Color3.new(1, 1, 1)

local SIDE = { FL = -1, FR = 1, BL = -1, BR = 1 }
local LEGS = { "FL", "FR", "BL", "BR" }
local FRONT = { FL = true, FR = true, BL = false, BR = false }
local FRONT_BONES = { FL = { "FrontUpperL", "FrontLowerL", "FrontFootL" }, FR = { "FrontUpperR", "FrontLowerR", "FrontFootR" } }
local BACK_BONES = { BL = { "BackThighL", "BackShinL", "BackFootL", "BackToesL" }, BR = { "BackThighR", "BackShinR", "BackFootR", "BackToesR" } }
local TAIL_SEGMENTS = 5
local TAIL_BEND = math.rad(16) -- how far each tail segment may trail off its rest direction, times its number
-- Rest positions (model space) of the ends of the last bones, which have no child bone: from the
-- joints in rig_stalker.py.
local TIPS = {
	FrontFootL = Vector3.new(-1.142, 0.138, -1.594),
	FrontFootR = Vector3.new(1.19, 0.138, -2.689),
	BackToesL = Vector3.new(-0.976, 0.114, 1.713),
	BackToesR = Vector3.new(0.976, 0.114, 0.642),
	Tail5 = Vector3.new(-0.181, 3.184, 5.473),
}
-- Where the named points sit on the rest model, and the bone each one follows.
local POINTS = {
	Head = { Bone = "Head", Position = Vector3.new(0, 3.1, -3.0) },
	BiteOrigin = { Bone = "Jaw", Position = Vector3.new(0, 2.68, -3.42) },
	LeftClaw = { Bone = "FrontFootL", Position = TIPS.FrontFootL },
	RightClaw = { Bone = "FrontFootR", Position = TIPS.FrontFootR },
}
-- The model's mouth is modelled wide open: Jaw rotation (radians, + opens) = (pose.Jaw - JAW_REST) * JAW_RANGE.
-- It can only close about 0.35 rad before the fangs clip, hence the floor on pose.Jaw.
local JAW_REST = 0.65
local JAW_RANGE = 0.6
local JAW_MIN = 0.08

-- Gaits (numbers from felid/canid locomotion studies, scaled to this body: see the research notes
-- in the handoff). Offsets: when each foot touches down, as a fraction of the stride cycle (hind
-- left = 0). A lateral-sequence walk blends into a trot (diagonal pairs) and a rotary gallop (hind
-- pair, then fore pair in the opposite order, like a big cat). Lift: swing height (studs, front /
-- hind). Bob: the body's vertical bounce (studs, half peak-to-peak), BobRate bounces per stride,
-- BobAt the phase of the highest point. DropF / DropH: how much lower the shoulders / hips ride (a
-- prowl; a crouched, head-low gallop), which also gives the legs the bend they need to reach (the
-- front legs need more of it: they are shorter).
local GAITS = {
	{ Name = "Walk", Until = 8, Offsets = { BL = 0, BR = 0.5, FL = 0.25, FR = 0.75 }, LiftF = 0.26, LiftH = 0.22, Bob = 0.04, BobRate = 2, BobAt = 0.15, DropF = 0.2, DropH = 0.12 },
	{ Name = "Trot", Until = 13.75, Offsets = { BL = 0, FR = 0, BR = 0.5, FL = 0.5 }, LiftF = 0.45, LiftH = 0.4, Bob = 0.06, BobRate = 2, BobAt = 0.47, DropF = 0.28, DropH = 0.17 },
	{ Name = "Gallop", Until = math.huge, Offsets = { BL = 0, BR = 0.1, FR = 0.45, FL = 0.55 }, LiftF = 0.6, LiftH = 0.7, Bob = 0.11, BobRate = 1, BobAt = 0.9, DropF = 0.42, DropH = 0.24 },
}
local GAIT_BLEND = 1.6 -- studs/s over which one gait blends into the next (centred on its Until)
-- Strides per second and the fraction of the stride each foot is on the ground, by speed (studs/s).
local STRIDE_RATE = { { 0, 0.9 }, { 5, 1.25 }, { 7, 1.45 }, { 10, 1.7 }, { 14, 1.95 }, { 20, 2.3 }, { 30, 2.6 } }
local DUTY = { { 0, 0.72 }, { 5, 0.65 }, { 7, 0.6 }, { 10, 0.46 }, { 14, 0.4 }, { 17, 0.37 }, { 20, 0.33 }, { 30, 0.28 } }
local STAND_DROP = 0.15 -- studs lower than the model's straight-legged rest pose, standing still
local LEG_SLACK = 0.94 -- legs stand at most this fraction of their full length (never locked straight)
local GIRDLE = { Front = 0.3, Hind = 0.18, Rise = 0.1 } -- shoulder blade / pelvis travel with each stride (studs)
local MOVE_ON, MOVE_OFF = 1.6, 0.9 -- studs/s: it starts / stops stepping in gait above / below these
local IDLE_STEP_ERROR = 0.4 -- studs: standing, a foot this far from where it should be steps
local IDLE_STEP_TIME = 0.26
local MAX_PLANT_ERROR = 6 -- studs: a planted foot this far off (a teleport) snaps instead of stepping
local RETARGET_UNTIL = 0.7 -- of a swing: the landing spot follows the body until then, then holds

local FOLLOW_RATE = 16 -- 1/s: critically damped spring onto the server hitbox position...
-- ...fed part of its velocity, estimated from the replicated steps (Rate: low-pass of the position,
-- Smooth: spring on the estimate), so it lags less at speed; Feed is kept partial, and dropped once
-- a step is overdue (StopAfter x the usual gap between steps), so a sudden stop barely overshoots.
local TRACK = { Rate = 20, Smooth = 30, Feed = 0.5, StopAfter = 1.6, Carry = 1.2 }
local ACCEL_RATE = 8 -- 1/s: the acceleration the body leans with is smoothed this much
local SOFT_IK = 0.05 -- of a limb's length: it eases into full stretch over the last 5% (no knee snap)
local TURN_RATE = 12 -- 1/s: ...and onto its heading
local G = 35 -- studs/s²: real gravity at this scale (1 stud ~ 0.28 m), for leaning and banking
local BANK = { Gain = 0.55, Max = 0.35, Rate = 11 } -- rolls into turns (fraction of the lean physics asks for)
local LEAN = { Forward = 0.105, Brake = 0.2, Max = 0.2, Drop = 0.135 } -- radians / studs per g of acceleration
local SPINE_BEND = { Reach = 3, Max = 0.5, Rate = 8 } -- curve into turns: curvature x Reach studs, the pelvis lagging
local POSE_BLEND = 12 -- 1/s: a change of action eases out its jump this fast
local POSITION_BLEND = 14 -- 1/s: and so does a jump of the body (a lunge starting a frame late)
local BODY_SPRING = 26 -- 1/s: body channels (crouch, pitch, roll) follow their targets on a spring
local LOOK = { Omega = 9, Damping = 0.6, MaxYaw = 0.75, MaxPitch = 0.35, Lead = 0.2 }
local SCAN = { Hold = { 1.5, 4 }, Yaw = 0.7, Pitch = 0.15 } -- idle head scanning: new gaze every 1.5-4 s
local SHIFT = { Every = { 3, 8 }, Side = 0.08, Fore = 0.05 } -- idle weight shifts

-- Foot targets in the body frame (studs from the body centre): mid-lunge (front: the wrist, hind:
-- the ball of the foot; from take-off to just before landing) and a frenzy swipe's raised,
-- reaching and raking points (the wrist; x is mirrored per side).
local FLIGHT_FRONT = { Vector3.new(0.85, -0.5, -3.0), Vector3.new(0.9, -1.7, -2.5) }
local FLIGHT_BACK = { Vector3.new(0.8, -1.4, 4.0), Vector3.new(0.8, -2.0, 2.3) }
local SWIPE_RAISED = Vector3.new(1.6, 0.45, -1.8)
local SWIPE_REACH = Vector3.new(0.7, 0.3, -3.5)
local SWIPE_RAKED = Vector3.new(-0.5, -1.55, -3.1)

type Swipe = { Wind: number, Sweep: number, Back: number }

type Pose = {
	Crouch: number, -- lowers the body
	Pitch: number, -- nose up (+)
	Roll: number,
	Shift: number, -- body forward (+) / back (-), studs
	Twist: number, -- chest yaw (+ turns its front left)
	Flex: number, -- spine arched (+) / extended (-)
	HeadPitch: number,
	HeadTurn: number, -- head yaw offset (+ left)
	NeckPush: number, -- head forward (+) or drawn back (-)
	Jaw: number, -- 0 shut .. 1 wide open
	Tremble: number,
	Buckle: number, -- front legs giving way (stagger)
	Collapse: number, -- 0..1 dying: legs go limp
	Gather: number, -- hind feet drawn forward under the body (coiling to pounce)
	Wiggle: number, -- hindquarters shimmy before a pounce
	Flight: number, -- 0..1 progress through a lunge's flight; -1 not flying
	LeftSwipe: Swipe?,
	RightSwipe: Swipe?,
}
-- The pose channels eased across a change of action, and those that also ride a spring.
local BLENDED = { "Crouch", "Pitch", "Roll", "Shift", "Twist", "Flex", "HeadPitch", "HeadTurn", "NeckPush", "Jaw", "Buckle", "Gather" }
local SPRUNG = { "Crouch", "Pitch", "Roll", "Shift" }

type Body = {
	Model: Model,
	Mesh: MeshPart,
	MeshRest: CFrame, -- the mesh part in model space
	Bones: { [string]: Bone },
	Order: { string }, -- parents before children
	Parent: { [string]: string? }, -- nil: the mesh part
	Rest: { [string]: CFrame }, -- each bone in model space
	Relative: { [string]: CFrame }, -- each bone relative to its parent bone (rest)
	Length: { [string]: number }, -- bone to its child (or tip)
	Direction: { [string]: Vector3 }, -- the same, model space unit vector
	Stance: { [string]: Vector3 }, -- standing foot targets in the ground frame (wrist / ball of the foot)
	Stride: { [string]: Vector3 }, -- the same, moved fore / aft under its shoulder / hip: the middle of a stride
	Meta: { [string]: Vector3 }, -- hind legs: hock to ball, model space
	Joint: { [string]: Vector3 }, -- shoulder / hip, model space (rest)
	GirdleZ: { Front: number, Hind: number }, -- where the shoulders / hips are along the body (model z)
	Reach: { [string]: number }, -- shoulder to wrist / hip to hock at full stretch
	TailLengths: { number },
	Points: { [string]: Attachment }, -- Head, BiteOrigin, LeftClaw, RightClaw
	PointOffsets: { [string]: CFrame }, -- each point relative to its bone
	Flash: Highlight,
	Glow: PointLight,
	GlowPoint: Attachment,
}

type Foot = {
	Plant: Vector3, -- where it stands (world), while not swinging
	Swinging: boolean,
	From: Vector3, -- where the swing started (world)
	FromLocal: Vector3, -- the same in the body's ground frame at lift-off...
	FromRate: Vector3, -- ...and how it was moving in that frame (studs/s; it was still on the ground)
	SwingStart: number, -- os.clock()
	SwingTime: number,
	Cycle: number, -- gait cycle it last stepped in
	Landing: Vector3, -- where the swing will land (world); follows the body early in the swing
	Position: Vector3, -- this frame's foot target (world)
	Lifted: number, -- 0 flat on the floor .. 1 fully off it
	Girdle: Vector3, -- shoulder blade / pelvis offset this frame (body frame)
	Held: Vector3, -- where an attack pose last put it (world), eased back from when it lets go
}

type View = {
	Server: Model,
	Body: Body,
	Position: Vector3, -- body centre (spring)
	Velocity: Vector3,
	Accel: Vector3, -- smoothed (what the body leans and banks with)
	AccelRate: Vector3,
	Yaw: number, -- heading angle (spring); heading = CFrame.Angles(0, Yaw, 0).LookVector
	YawRate: number,
	Cycle: number, -- gait cycles (unwrapped)
	Moving: boolean, -- stepping in gait (vs standing and making corrective steps)
	GaitWeights: { number }, -- walk, trot, gallop
	Feet: { [string]: Foot },
	Overrides: { [string]: number }, -- per foot: how much an attack pose owns it (smoothed)
	Flying: boolean,
	Air: number, -- 0 on the ground .. 1 in a lunge's flight (eased)
	Trail: Vector3, -- the hitbox position, low-passed (lags it by exactly velocity / TRACK_RATE)
	TargetVelocity: Vector3, -- the hitbox velocity estimate (spring smoothed)
	TargetAccel: Vector3,
	LastTarget: Vector3, -- the last replicated hitbox position, and when it arrived
	LastTargetAt: number,
	StepGap: number, -- usual time between replicated steps (s)
	Offset: Vector3, -- a jump of the body being eased out (world)
	OffsetStart: number,
	Bank: number,
	BankRate: number,
	HipsBend: number, -- the pelvis follows the chest into a turn a little late
	HipsBendRate: number,
	Gaze: Vector2, -- idle scanning: yaw, pitch
	GazeUntil: number,
	Weight: Vector2, -- idle weight shift: side, fore
	WeightGoal: Vector2,
	WeightUntil: number,
	Tail: { Vector3 },
	TailVelocity: { Vector3 },
	LookYaw: number,
	LookYawRate: number,
	LookPitch: number,
	LookPitchRate: number,
	Sprung: { [string]: number },
	SprungRate: { [string]: number },
	LastPose: { [string]: number },
	Residual: { [string]: number },
	ResidualStart: number,
	PendingBlend: boolean,
	FlinchKick: number, -- body jolt from a hit (spring impulse)
	ParryFlinchUntil: number,
	LastHealth: number,
	Seq: number,
	Fading: boolean,
	Connections: { RBXScriptConnection },
}

local views: { [Model]: View } = {}
local warned = false

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function easeOut(x: number): number
	x = clamp01(x)
	return 1 - (1 - x) ^ 3
end

local function easeIn(x: number): number
	x = clamp01(x)
	return x * x * x
end

local function smooth(x: number): number
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

-- Overshoots 1 a little before settling (a strike that carries through).
local function easeOutBack(x: number): number
	x = clamp01(x) - 1
	return 1 + 2.4 * x * x * x + 1.4 * x * x
end

-- A kick that peaks at 1 after `peak` seconds and dies away (an impulse response).
local function kick(t: number, peak: number): number
	if t <= 0 then
		return 0
	end
	local k = t / peak
	return k * math.exp(1 - k)
end

-- A damped wobble starting at 1 (settling after an impact).
local function wobble(t: number, rate: number, frequency: number): number
	if t <= 0 then
		return 1
	end
	return math.exp(-rate * t) * math.cos(frequency * t)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

local function rotationBetween(a: Vector3, b: Vector3): CFrame
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-5 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(a:Dot(b), -1, 1)))
end

local function mirror(v: Vector3, side: number): Vector3
	return Vector3.new(v.X * side, v.Y, v.Z)
end

-- One step of a critically damped spring (exact for a target held still over the step).
local function spring(x: number, v: number, target: number, omega: number, dt: number): (number, number)
	local e = math.exp(-omega * dt)
	local offset = x - target
	local c = v + offset * omega
	return target + (offset + c * dt) * e, (v - c * omega * dt) * e
end

local function springVector(x: Vector3, v: Vector3, target: Vector3, omega: number, dt: number): (Vector3, Vector3)
	local e = math.exp(-omega * dt)
	local offset = x - target
	local c = v + offset * omega
	return target + (offset + c * dt) * e, (v - c * (omega * dt)) * e
end

-- One step of an underdamped spring (it overshoots a little: overlapping action).
local function wobbleSpring(x: number, v: number, target: number, omega: number, damping: number, dt: number): (number, number)
	local steps = math.max(math.ceil(dt * omega / 0.25), 1)
	local h = dt / steps
	for _ = 1, steps do
		v += (omega * omega * (target - x) - 2 * damping * omega * v) * h
		x += v * h
	end
	return x, v
end

-------------------------------------------------------------------------------- body

local function buildBody(id: number): Body?
	local folder = ReplicatedStorage:FindFirstChild("EnemyModels")
	local template = folder and folder:FindFirstChild("Stalker")
	local templateMesh = template and template:FindFirstChildWhichIsA("MeshPart")
	if not templateMesh then
		if not warned then
			warned = true
			warn("StalkerVisuals: ReplicatedStorage.EnemyModels.Stalker is missing; Stalkers are invisible")
		end
		return nil
	end
	local model = (template :: Model):Clone()
	model.Name = "StalkerVisual" .. id
	model:PivotTo(CFrame.identity) -- model space = world space while the rest pose is read
	local mesh = model:FindFirstChildWhichIsA("MeshPart") :: MeshPart
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanQuery = false
	mesh.CanTouch = false

	local body = {
		Model = model,
		Mesh = mesh,
		MeshRest = mesh.CFrame,
		Bones = {},
		Order = {},
		Parent = {},
		Rest = {},
		Relative = {},
		Length = {},
		Direction = {},
		Stance = {},
		Stride = {},
		Meta = {},
		TailLengths = {},
		Points = {},
		PointOffsets = {},
	} :: Body
	local function walk(parent: Instance, parentName: string?)
		for _, child in parent:GetChildren() do
			if child:IsA("Bone") then
				child.Transform = CFrame.identity
				body.Bones[child.Name] = child
				table.insert(body.Order, child.Name)
				body.Parent[child.Name] = parentName
				body.Rest[child.Name] = child.WorldCFrame
				body.Relative[child.Name] = child.CFrame
				walk(child, child.Name)
			end
		end
	end
	walk(mesh, nil)
	-- Each bone's length and direction: to its (first) child bone or its tip.
	for _, name in body.Order do
		local tip = TIPS[name]
		if not tip then
			for _, other in body.Order do
				if body.Parent[other] == name then
					tip = body.Rest[other].Position
					break
				end
			end
		end
		if tip then
			local along = tip - body.Rest[name].Position
			body.Length[name] = along.Magnitude
			body.Direction[name] = unitOr(along, -Vector3.zAxis)
		end
	end
	-- A symmetric standing stance (the model is posed mid-stride).
	local function stance(left: string, right: string): (Vector3, Vector3)
		local a, b = body.Rest[left].Position, body.Rest[right].Position
		local x, y, z = (math.abs(a.X) + math.abs(b.X)) / 2, (a.Y + b.Y) / 2, (a.Z + b.Z) / 2
		return Vector3.new(-x, y, z), Vector3.new(x, y, z)
	end
	body.Stance.FL, body.Stance.FR = stance("FrontFootL", "FrontFootR")
	body.Stance.BL, body.Stance.BR = stance("BackToesL", "BackToesR")
	body.Joint, body.Reach = {}, {}
	for leg, bones in BACK_BONES do
		body.Meta[leg] = body.Rest[bones[4]].Position - body.Rest[bones[3]].Position
		body.Joint[leg] = body.Rest[bones[1]].Position
		body.Reach[leg] = (body.Length[bones[1]] or 1) + (body.Length[bones[2]] or 1)
	end
	for leg, bones in FRONT_BONES do
		body.Joint[leg] = body.Rest[bones[1]].Position
		body.Reach[leg] = (body.Length[bones[1]] or 1) + (body.Length[bones[2]] or 1)
	end
	-- The model stands with its legs almost straight (some can't even reach the averaged stance).
	-- Standing a little lower, pull each foot in under its shoulder / hip until the leg has some
	-- bend, so the IK never locks straight and there is reach left to walk with.
	for _, leg in LEGS do
		local joint = body.Joint[leg] - UP * STAND_DROP
		local endOffset = if FRONT[leg] then Vector3.zero else -body.Meta[leg]
		local target = body.Stance[leg]
		local under = Vector3.new(joint.X, target.Y, joint.Z)
		for _ = 1, 20 do
			if (target + endOffset - joint).Magnitude <= body.Reach[leg] * LEG_SLACK then
				break
			end
			target = target:Lerp(under, 0.15)
		end
		body.Stance[leg] = target
		-- Walking, each foot sweeps evenly about the point under its own shoulder / hip (the model's
		-- shoulders aren't level fore and aft: it was posed mid-stride).
		body.Stride[leg] = Vector3.new(target.X, target.Y, body.Joint[leg].Z - endOffset.Z)
	end
	body.GirdleZ = { Front = (body.Joint.FL.Z + body.Joint.FR.Z) / 2, Hind = (body.Joint.BL.Z + body.Joint.BR.Z) / 2 }
	for i = 1, TAIL_SEGMENTS do
		table.insert(body.TailLengths, body.Length["Tail" .. i])
	end

	for name, point in POINTS do
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Parent = mesh
		body.Points[name] = attachment
		body.PointOffsets[name] = body.Rest[point.Bone]:Inverse() * CFrame.new(point.Position)
	end
	body.GlowPoint = Instance.new("Attachment")
	body.GlowPoint.Name = "Glow"
	body.GlowPoint.Parent = mesh
	body.Glow = Instance.new("PointLight")
	body.Glow.Color = Visuals.MarkingColor
	body.Glow.Range = 10
	body.Glow.Brightness = 0.5
	body.Glow.Shadows = false
	body.Glow.Parent = body.GlowPoint
	-- Hit flash: a brief glow over the whole body.
	body.Flash = Instance.new("Highlight")
	body.Flash.Name = "HitFlash"
	body.Flash.FillColor = WHITE:Lerp(Visuals.MarkingColor, 0.3)
	body.Flash.FillTransparency = 1
	body.Flash.OutlineTransparency = 1
	body.Flash.DepthMode = Enum.HighlightDepthMode.Occluded
	body.Flash.Parent = model
	model.Parent = VFXUtil.Folder() or workspace
	return body
end

-- Two-bone IK: the middle joint for a limb from `root` to `target` with segments `upper` and
-- `lower`, bending toward `bend`. Clamps the end within reach and returns the (possibly moved) end.
local function solveLimb(root: Vector3, target: Vector3, bend: Vector3, upper: number, lower: number): (Vector3, Vector3)
	local offset = target - root
	-- Near full stretch the joint angle changes ever faster for the same reach, so the last bit of
	-- reach is approached exponentially (soft IK) and the knee never snaps straight.
	local full = upper + lower - 0.02
	local soft = SOFT_IK * full
	local distance = offset.Magnitude
	if distance > full - soft then
		distance = full - soft * math.exp((full - soft - distance) / soft)
	end
	distance = math.max(distance, math.abs(upper - lower) + 0.05)
	local dir = unitOr(offset, -UP)
	target = root + dir * distance
	local along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
	local height = math.sqrt(math.max(upper * upper - along * along, 0))
	local side = unitOr(bend - dir * bend:Dot(dir), UP)
	return root + dir * along + side * height, target
end

type Spine = {
	Bend: number, -- sideways curve into a turn (+ left)
	Flex: number, -- arched (+) / extended (-)
	Roll: number, -- shoulders and hips rolling against each other with the legs
	Twist: number, -- chest yaw for the swipes
	NeckPitch: number,
	HeadPitch: number,
	HeadYaw: number,
	NeckShift: number,
	TailYaw: number, -- swings out of a turn
	TailPitch: number, -- up as a counterweight (gallop, braking)
}

-- Poses the rig. `frame` is the body centre (Config.BodyHeight above the model origin), `ground`
-- the floor under it, `feet` the solved foot targets (front: wrists, hind: balls of the feet).
local function applyBody(view: View, frame: CFrame, ground: CFrame, pose: Pose, spine: Spine, dt: number)
	local body = view.Body
	local rest, relative = body.Rest, body.Relative
	local clock = os.clock()
	local shake = if pose.Tremble > 0 then CFrame.new(math.sin(clock * 61) * 0.035 * pose.Tremble, math.sin(clock * 53) * 0.015 * pose.Tremble, math.sin(clock * 47) * 0.025 * pose.Tremble) else CFrame.identity
	local modelCF = frame * shake * CFrame.new(0, -Config.BodyHeight, 0)
	local posed: { [string]: CFrame } = {}

	local meshCF = modelCF * body.MeshRest
	body.Mesh.CFrame = meshCF
	local function parentOf(name: string): CFrame
		local parent = body.Parent[name]
		return if parent then posed[parent] else meshCF
	end
	-- Follows its parent, rotated by `rotation` (model axes) about its own joint, after `shift`.
	local function fk(name: string, rotation: CFrame?, shift: Vector3?)
		if not relative[name] then
			return
		end
		local restRotation = rest[name].Rotation
		local cf = parentOf(name) * relative[name]
		if shift then
			cf *= CFrame.new(restRotation:Inverse() * shift)
		end
		if rotation then
			cf *= restRotation:Inverse() * rotation * restRotation
		end
		posed[name] = cf
	end
	-- Sits at `from` and points at `to`; twist follows `basis`.
	local function aim(name: string, from: Vector3, to: Vector3, basis: CFrame)
		local restDir = basis:VectorToWorldSpace(body.Direction[name])
		posed[name] = CFrame.new(from) * rotationBetween(restDir, unitOr(to - from, restDir)) * basis.Rotation * rest[name].Rotation
	end
	-- On the floor (`lifted` 0) or carried rigidly by its parent (1).
	local function foot(name: string, lifted: number)
		local carried = parentOf(name) * relative[name]
		local flatOn = CFrame.new(carried.Position) * ground.Rotation * rest[name].Rotation
		posed[name] = flatOn:Lerp(carried, lifted)
	end

	-- Torso: the hips, spine and chest share the bend, flex and roll, so the back curves.
	fk("Root")
	fk("Hips", CFrame.Angles(0.4 * spine.Flex, -0.35 * spine.Bend, -spine.Roll))
	fk("Spine", CFrame.Angles(-0.3 * spine.Flex, 0.45 * spine.Bend, 0.5 * spine.Roll))
	fk("Chest", CFrame.Angles(-0.3 * spine.Flex, 0.45 * spine.Bend + spine.Twist, 0.5 * spine.Roll))
	local chestYaw = 0.55 * spine.Bend + spine.Twist

	-- Neck and head: the look shares out between them; pushing the head forward or drawing it back
	-- is mostly rotation, with only a little slide (sliding the bone stretches the skin).
	fk("Neck", CFrame.Angles(0, 0.45 * spine.HeadYaw, 0) * CFrame.Angles(spine.NeckPitch, 0, 0), Vector3.new(0, 0, -spine.NeckShift))
	fk("Head", CFrame.Angles(0, 0.55 * spine.HeadYaw, 0) * CFrame.Angles(spine.HeadPitch, 0, 0))
	fk("Jaw", CFrame.Angles(-(math.max(pose.Jaw, JAW_MIN) - JAW_REST) * JAW_RANGE, 0, 0))

	-- Front legs: shoulder > elbow (bends back) > wrist on its target; the paw lies on the floor.
	local chestBasis = modelCF * CFrame.Angles(0, chestYaw, 0)
	for leg, bones in FRONT_BONES do
		local side = SIDE[leg]
		local upper, lower, paw = bones[1], bones[2], bones[3]
		if posed.Chest and relative[upper] then
			-- The shoulder blade slides with the stride (the leg alone can't reach far enough).
			local shoulder = (posed.Chest * relative[upper]).Position + chestBasis:VectorToWorldSpace(view.Feet[leg].Girdle)
			local bend = chestBasis:VectorToWorldSpace(Vector3.new(side * 0.3, 0, 1))
			local elbow, wrist = solveLimb(shoulder, view.Feet[leg].Position, bend, body.Length[upper], body.Length[lower])
			aim(upper, shoulder, elbow, chestBasis)
			aim(lower, elbow, wrist, chestBasis)
			foot(paw, view.Feet[leg].Lifted)
		end
	end

	-- Hind legs: hip > knee (bends forward) > hock > ball on its target. The metatarsal keeps its
	-- rest angle to the floor (to the body when off the ground), so the IK solves hip to hock.
	for leg, bones in BACK_BONES do
		local side = SIDE[leg]
		local thigh, shin, meta, toes = bones[1], bones[2], bones[3], bones[4]
		if posed.Hips and relative[thigh] then
			local lifted = view.Feet[leg].Lifted
			local basis = if pose.Flight >= 0 or pose.Collapse > 0.5 then modelCF else ground:Lerp(modelCF, lifted * 0.6)
			local hip = (posed.Hips * relative[thigh]).Position + modelCF:VectorToWorldSpace(view.Feet[leg].Girdle)
			local metaWorld = basis:VectorToWorldSpace(body.Meta[leg])
			local bend = modelCF:VectorToWorldSpace(Vector3.new(side * 0.3, 0, -1))
			local knee, hock = solveLimb(hip, view.Feet[leg].Position - metaWorld, bend, body.Length[thigh], body.Length[shin])
			aim(thigh, hip, knee, modelCF)
			aim(shin, knee, hock, modelCF)
			aim(meta, hock, hock + metaWorld, basis)
			foot(toes, lifted)
		end
	end

	-- Tail: a chain of springs from the hips. Each segment is pulled toward its rest direction
	-- (carried by the hips, raised a little at speed, swaying with the gait) and keeps its momentum,
	-- so it swings, lags and follows through; a bend limit keeps it from trailing absurdly far.
	local points, velocities = view.Tail, view.TailVelocity
	local hipsFrame = posed.Hips or modelCF
	local base = if relative.Tail1 then (hipsFrame * relative.Tail1).Position else frame.Position
	local tailBasis = modelCF * CFrame.Angles(0, -0.35 * spine.Bend + spine.TailYaw, 0)
	local limp = pose.Collapse
	if #points == 0 then
		points[1] = base
		velocities[1] = Vector3.zero
		for i = 1, TAIL_SEGMENTS do
			points[i + 1] = points[i] + tailBasis:VectorToWorldSpace(body.Direction["Tail" .. i]) * body.TailLengths[i]
			velocities[i + 1] = Vector3.zero
		end
	end
	points[1] = base
	local floorY = ground.Position.Y + 0.2
	local raise = CFrame.Angles(spine.TailPitch, 0, 0)
	local swayAngle = math.sin(view.Cycle * 2 * math.pi) * 0.12 * (1 - view.GaitWeights[3]) * clamp01(flat(view.Velocity).Magnitude / 6)
	local stiffness = 180 * (1 - limp) + 4
	local gravity = 6 + 60 * limp
	local h = math.min(dt, 1 / 30)
	for i = 2, #points do
		local length = body.TailLengths[i - 1]
		local restLocal = raise * CFrame.Angles(0, swayAngle * (i - 1) * 0.5, 0) * body.Direction["Tail" .. (i - 1)]
		local restDir = tailBasis:VectorToWorldSpace(restLocal)
		local target = points[i - 1] + restDir * length
		local k = stiffness * (1 - 0.13 * (i - 2))
		local old = points[i]
		local v = velocities[i] + ((target - old) * k - UP * gravity) * h
		v *= math.exp(-7 * h)
		local p = old + v * h
		-- Keep the segment's length, and within its bend limit.
		local dir = unitOr(p - points[i - 1], restDir)
		local limit = TAIL_BEND * (i - 1) + limp * 1.2
		local angle = math.acos(math.clamp(dir:Dot(restDir), -1, 1))
		if angle > limit then
			local axis = restDir:Cross(dir)
			dir = if axis.Magnitude > 1e-5 then CFrame.fromAxisAngle(axis.Unit, limit):VectorToWorldSpace(restDir) else restDir
		end
		p = points[i - 1] + dir * length
		p = Vector3.new(p.X, math.max(p.Y, floorY), p.Z)
		velocities[i] = if h > 0 then (p - old) / h else Vector3.zero
		points[i] = p
	end
	for i = 1, TAIL_SEGMENTS do
		aim("Tail" .. i, points[i], points[i + 1], tailBasis)
	end

	-- Write the bones (each relative to its parent's posed frame) and move the points.
	for _, name in body.Order do
		local cf = posed[name]
		if cf then
			body.Bones[name].Transform = (parentOf(name) * relative[name]):Inverse() * cf
		end
	end
	for name, attachment in body.Points do
		local bone = posed[POINTS[name].Bone]
		if bone then
			attachment.WorldCFrame = bone * body.PointOffsets[name]
		end
	end
	if posed.Chest then
		body.GlowPoint.WorldPosition = posed.Chest.Position
	end
end

-------------------------------------------------------------------------------- animation

local function attribute(model: Model, name: string, default: any): any
	local value = model:GetAttribute(name)
	if value == nil then
		return default
	end
	return value
end

local function newPose(): Pose
	return {
		Crouch = 0,
		Pitch = 0,
		Roll = 0,
		Shift = 0,
		Twist = 0,
		Flex = 0,
		HeadPitch = 0,
		HeadTurn = 0,
		NeckPush = 0,
		Jaw = 0.1,
		Tremble = 0,
		Buckle = 0,
		Collapse = 0,
		Gather = 0,
		Wiggle = 0,
		Flight = -1,
		LeftSwipe = nil,
		RightSwipe = nil,
	}
end

-- The action layer of the pose, from the server's attributes and the server clock. Each attack is
-- anticipation (windup, peaking exactly on ActionStrike), action and follow-through/settle.
local function actionPose(view: View, t: number): (Pose, string, number)
	local pose = newPose()
	local model = view.Server
	local action = attribute(model, "Action", "")
	local step = attribute(model, "ActionStep", 0)
	local elapsed = t - attribute(model, "ActionStart", 0)
	local strike = attribute(model, "ActionStrike", 0)
	local frenzy = Config.Frenzy

	if action == "Bite" or (action == "Frenzy" and step == 3) then
		local isBite = action == "Bite"
		local windup = if isBite then Config.Bite.Windup else frenzy.Strikes[3].Windup
		local active = if isBite then Config.Bite.Active else frenzy.Active
		local since = t - strike
		if since < 0 then
			-- Anticipation: weight rocks back, the head draws back and up, the jaws gape.
			local w = smooth(1 + since / windup)
			pose.NeckPush, pose.HeadPitch, pose.Jaw = -0.8 * w, 0.35 * w, 0.1 + 0.9 * w
			pose.Crouch, pose.Pitch, pose.Shift, pose.Tremble = 0.18 * w, 0.07 * w, -0.3 * w, 0.6 * w
		elseif since < active then
			-- The snap: the neck shoots out past its mark, the body follows, the jaws slam shut.
			local s = since / active
			pose.NeckPush = -0.8 + 2.1 * easeOutBack(s)
			pose.HeadPitch = 0.35 - 0.6 * easeOut(s)
			pose.Jaw = 1 - 0.95 * smooth((s - 0.35) / 0.45)
			pose.Shift = -0.3 + 0.85 * easeOut(s)
			pose.Crouch, pose.Pitch = 0.18 - 0.3 * s, 0.07 - 0.15 * s
		else
			-- Follow-through: it hangs on, then settles with a little give.
			local r = since - active
			local settle = wobble(r, 5, 7)
			pose.NeckPush, pose.HeadPitch = 1.3 * settle, -0.25 * settle
			pose.Jaw = 0.1 + 0.25 * kick(r, 0.12)
			pose.Shift, pose.Crouch, pose.Pitch = 0.55 * math.exp(-4 * r), -0.12 * settle, -0.08 * settle
		end
	elseif action == "Frenzy" then
		-- A front leg rears up and back, then rakes forward and across; the body rears, rolls away
		-- from the swinging side and twists through the strike.
		local strikeCfg = frenzy.Strikes[step]
		local windup = if strikeCfg then strikeCfg.Windup else 0.25
		local since = t - strike
		local swipe: Swipe = { Wind = 0, Sweep = 0, Back = 0 }
		if since < 0 then
			swipe.Wind = smooth(1 + since / windup)
		elseif since < frenzy.Active then
			swipe.Wind, swipe.Sweep = 1, easeOut(since / frenzy.Active)
		else
			swipe.Wind, swipe.Sweep, swipe.Back = 1, 1, smooth((since - frenzy.Active) / (frenzy.Gap + 0.2))
		end
		local side = if step == 1 then -1 else 1
		if step == 1 then
			pose.LeftSwipe = swipe
		else
			pose.RightSwipe = swipe
		end
		local raised = swipe.Wind * (1 - swipe.Back)
		local through = swipe.Sweep * (1 - swipe.Back)
		pose.Pitch = 0.22 * raised - 0.1 * through
		pose.Roll = -side * 0.14 * raised
		pose.Crouch = -0.12 * raised + 0.15 * through
		pose.Shift = 0.35 * through
		-- Winds the swinging shoulder back, then whips through past the middle.
		pose.Twist = -side * 0.28 * swipe.Wind * (1 - swipe.Back) + side * 0.5 * through
		pose.HeadTurn = side * 0.18 * raised
		pose.HeadPitch, pose.Jaw = 0.1, 0.5
		pose.Tremble = if since < 0 then 0.5 * swipe.Wind else 0
	elseif action == "Lunge" then
		if step == 1 then
			-- Coils: sinks low with its hindquarters drawn under it, eyes fixed, then the
			-- hindquarters shimmy just before it springs.
			local w = smooth(elapsed / Config.Lunge.Windup)
			pose.Crouch, pose.Pitch, pose.Gather = 0.85 * w, -0.08 * w, w
			pose.HeadPitch, pose.NeckPush, pose.Jaw = 0.12 * w, -0.25 * w, 0.1 + 0.5 * easeIn(w)
			pose.Flex = 0.15 * w
			pose.Wiggle = smooth((w - 0.45) / 0.3)
			pose.Tremble = 0.5 * w
		elseif step == 2 then
			-- Flight: stretched out, front claws reaching for the target, jaws wide.
			local u = clamp01((t - attribute(model, "LeapStart", t)) / math.max(attribute(model, "LeapDuration", 0.4), 0.01))
			pose.Flight = u
			pose.Jaw, pose.HeadPitch, pose.NeckPush = 1, 0.1 - 0.2 * u, 0.6
			pose.Flex = -0.25 + 0.3 * u -- extended off the push, gathering for the landing
		elseif step == 3 then
			-- Lands hard on the forelegs, absorbs it, then rises out of the crouch.
			local land = smooth(elapsed / 0.06) * (1 - smooth((elapsed - 0.06) / (Config.Lunge.Recovery - 0.06)))
			pose.Crouch, pose.Pitch, pose.Jaw = 0.8 * land, -0.14 * land, 0.1 + 0.35 * land
			pose.HeadPitch, pose.Flex = 0.15 * land, 0.12 * land
		end
	elseif action == "Recoil" then
		-- A parried bite or lunge: the head whips back, the weight is thrown onto the hindquarters,
		-- then it shakes it off.
		local snap = kick(elapsed, 0.08)
		local reel = kick(elapsed, 0.16)
		pose.HeadPitch = 0.85 * snap - 0.12 * reel * math.sin(elapsed * 18)
		pose.NeckPush, pose.Jaw = -0.9 * snap, 0.55 * reel
		pose.Pitch, pose.Shift, pose.Crouch = 0.22 * reel, -0.4 * reel, 0.25 * reel
		pose.HeadTurn = 0.15 * math.sin(elapsed * 22) * math.exp(-elapsed * 6)
	elseif action == "Stagger" then
		-- All three frenzy strikes parried: the front legs buckle, the head reels and shakes.
		local hold = math.min(elapsed / 0.1, 1) * (1 - smooth((elapsed - frenzy.StaggerTime * 0.65) / (frenzy.StaggerTime * 0.35)))
		pose.Buckle, pose.Pitch, pose.Jaw = hold, -0.22 * hold, 0.5 * hold
		pose.HeadPitch, pose.NeckPush = 0.5 * hold, -0.55 * hold
		pose.HeadTurn = 0.3 * math.sin(elapsed * 15) * math.exp(-elapsed * 2.2) * hold
		pose.Roll = 0.12 * math.sin(elapsed * 9) * hold
		pose.Tremble = 0.4 * hold
	elseif action == "Death" then
		-- The legs give, it topples onto its side (falling faster as it goes), bounces once and lies
		-- still on the surface.
		local give = smooth(elapsed / 0.25)
		local fall = clamp01((elapsed - 0.12) / 0.5)
		local over = fall * fall
		local bounce = if elapsed > 0.62 then 0.12 * math.exp(-(elapsed - 0.62) * 7) * math.sin((elapsed - 0.62) * 16) else 0
		pose.Collapse = give
		pose.Crouch = 0.45 * give + 1.25 * over - bounce
		pose.Roll = 1.2 * over + bounce
		pose.Jaw, pose.HeadPitch, pose.NeckPush = 0.55 * give, -0.3 * give, -0.2 * give
	end
	return pose, action, step
end

-- A front wrist's swipe (body frame): from its stepping position up to the raised point, then an
-- arc forward through the reach point and across to the raked point, then back down.
local function swipeFoot(rest: Vector3, side: number, swipe: Swipe): Vector3
	local raised = mirror(SWIPE_RAISED, side)
	local reach = mirror(SWIPE_REACH, side)
	local raked = mirror(SWIPE_RAKED, side)
	if swipe.Sweep <= 0 then
		return rest:Lerp(raised, swipe.Wind)
	elseif swipe.Back <= 0 then
		local s = swipe.Sweep
		return raised * ((1 - s) * (1 - s)) + reach * (2 * s * (1 - s)) + raked * (s * s)
	end
	return raked:Lerp(rest, swipe.Back)
end

local function nearestPlayer(position: Vector3, maxDistance: number): Vector3?
	local best, bestDistance = nil, maxDistance
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local distance = (root.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = root.Position, distance
			end
		end
	end
	return best
end

-- Weights of walk, trot and gallop at a speed (they sum to 1).
local function gaitWeights(speed: number): { number }
	local weights = {}
	local remaining = 1
	for i, gait in GAITS do
		if i == #GAITS then
			weights[i] = remaining
		else
			local past = smooth((speed - gait.Until + GAIT_BLEND * 0.5) / GAIT_BLEND)
			weights[i] = remaining * (1 - past)
			remaining *= past
		end
	end
	return weights
end

-- A gait parameter blended by the weights.
local function blendGait(weights: { number }, key: string): number
	local total = 0
	for i, gait in GAITS do
		total += (gait :: any)[key] * weights[i]
	end
	return total
end

-- A leg's lift-off phase blended by the weights (on the circle, so 0.9 and 0.1 meet at 0).
local function blendOffset(weights: { number }, leg: string): number
	local x, y = 0, 0
	for i, gait in GAITS do
		local a = gait.Offsets[leg] * 2 * math.pi
		x += math.cos(a) * weights[i]
		y += math.sin(a) * weights[i]
	end
	return (math.atan2(y, x) / (2 * math.pi)) % 1
end

-- A value from a table of { x, y } points, linearly between them.
local function lookup(points: { { number } }, x: number): number
	if x <= points[1][1] then
		return points[1][2]
	end
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		if x <= b[1] then
			return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1])
		end
	end
	return points[#points][2]
end

-- Where a foot stands (world) for the body standing at `ground`.
local function neutralFoot(view: View, ground: CFrame, leg: string): Vector3
	return ground * view.Body.Stance[leg]
end

-- How a point fixed on the ground moves in the body's ground frame, the body moving at `velocity`
-- (that frame) and turning at `yawRate` (studs/s).
local function stillRate(point: Vector3, velocity: Vector3, yawRate: number): Vector3
	return -(velocity + Vector3.new(yawRate * point.Z, 0, -yawRate * point.X))
end

local function hermite(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3, s: number): Vector3
	local s2, s3 = s * s, s * s * s
	return p0 * (2 * s3 - 3 * s2 + 1) + m0 * (s3 - 2 * s2 + s) + p1 * (3 * s2 - 2 * s3) + m1 * (s3 - s2)
end

local function startSwing(foot: Foot, duration: number, clock: number, ground: CFrame, velocity: Vector3, yawRate: number)
	foot.Swinging = true
	foot.From = foot.Position
	foot.FromLocal = ground:PointToObjectSpace(foot.Position)
	foot.FromRate = stillRate(foot.FromLocal, ground:VectorToObjectSpace(velocity), yawRate)
	foot.SwingStart = clock
	foot.SwingTime = duration
end

-- The ground frame `tau` seconds from now, carried along the arc the body is moving on.
local function predictGround(ground: CFrame, velocity: Vector3, yawRate: number, tau: number): CFrame
	local turn = math.clamp(yawRate * tau, -1.2, 1.2)
	local half = turn / 2
	local chord = if math.abs(half) > 1e-4 then math.sin(half) / half else 1
	local travel = CFrame.Angles(0, half, 0):VectorToWorldSpace(velocity) * (tau * chord)
	return (ground + travel) * CFrame.Angles(0, turn, 0)
end

-- How far a foot can be from under its shoulder / hip (studs, along the ground) with the body `drop`
-- studs lower than rest, before the leg is straight.
local function legReach(body: Body, leg: string, drop: number): number
	local joint = body.Joint[leg]
	local stance = body.Stance[leg] + (if FRONT[leg] then Vector3.zero else -body.Meta[leg])
	local height = joint.Y - drop - stance.Y
	local length = body.Reach[leg] * 0.97
	return math.sqrt(math.max(length * length - height * height, 0))
end

local function updateView(view: View, dt: number, t: number)
	local server = view.Server
	local root = server.PrimaryPart
	if not root or dt <= 0 then
		return
	end
	local clock = os.clock()
	local body = view.Body
	local pose = actionPose(view, t)

	-- Ease out the jump when the action changes (the targets themselves stay exact).
	if view.PendingBlend then
		view.PendingBlend = false
		for _, key in BLENDED do
			view.Residual[key] = (view.LastPose[key] or 0) - (pose :: any)[key]
		end
		view.ResidualStart = clock
	end
	local fade = math.exp(-POSE_BLEND * (clock - view.ResidualStart))
	for _, key in BLENDED do
		local value = (pose :: any)[key] + (view.Residual[key] or 0) * fade
		;(pose :: any)[key] = value
		view.LastPose[key] = value
	end
	-- The body channels ride a spring too, so the torso moves with weight. A hit adds a jolt (eased
	-- in by the same spring).
	view.FlinchKick *= math.exp(-10 * dt)
	pose.Crouch += 0.14 * view.FlinchKick
	pose.Pitch -= 0.07 * view.FlinchKick
	for _, key in SPRUNG do
		local x, v = spring(view.Sprung[key] or 0, view.SprungRate[key] or 0, (pose :: any)[key], BODY_SPRING, dt)
		view.Sprung[key], view.SprungRate[key] = x, v
		;(pose :: any)[key] = x
	end
	if clock < view.ParryFlinchUntil then
		local f = math.sin(math.pi * clamp01(1 - (view.ParryFlinchUntil - clock) / 0.3))
		pose.HeadPitch += 0.5 * f
		pose.NeckPush -= 0.6 * f
	end

	-- 1. The body: on springs onto the server hitbox; a lunge's flight is drawn from its exact arc.
	local flying = pose.Flight >= 0
	local leapLift = 0
	local before = view.Position
	-- The server moves an anchored hitbox, so its position arrives in steps. A low-passed copy of it
	-- trails it by velocity / TRACK.Rate, which gives a smooth velocity estimate; the body follows
	-- the hitbox carried on at part of that velocity since the last step, so it neither stutters
	-- with the steps nor trails far behind at speed.
	local hitbox = root.Position
	if hitbox ~= view.LastTarget then
		local gap = clock - view.LastTargetAt
		if gap < 0.2 then
			view.StepGap += (gap - view.StepGap) * 0.2
		end
		view.LastTarget, view.LastTargetAt = hitbox, clock
	end
	view.Trail += (hitbox - view.Trail) * (1 - math.exp(-TRACK.Rate * dt))
	view.TargetVelocity, view.TargetAccel = springVector(view.TargetVelocity, view.TargetAccel, (hitbox - view.Trail) * TRACK.Rate, TRACK.Smooth, dt)
	if flying then
		local from = attribute(server, "LeapFrom", root.Position)
		local to = attribute(server, "LeapTo", root.Position)
		local duration = math.max(attribute(server, "LeapDuration", 0.4), 0.01)
		local height = attribute(server, "LeapHeight", 2.5)
		local u = pose.Flight
		leapLift = 4 * height * u * (1 - u)
		view.Position = from:Lerp(to, u) + UP * (Config.BodyHeight + leapLift)
		view.Velocity = (to - from) / duration + UP * (4 * height * (1 - 2 * u) / duration)
		local along = flat(to - from)
		if along.Magnitude > 0.05 then
			-- (Swung round onto the leap quickly, not snapped: it may launch a little off its heading.)
			view.Yaw, view.YawRate = spring(view.Yaw, view.YawRate, view.Yaw + wrapAngle(yawOf(along) - view.Yaw), 2 * TURN_RATE, dt)
		end
		-- Pitches with the arc (a little less than the arc itself: the body stays level-ish).
		-- (Eased in at take-off and out at landing, so the body doesn't snap.)
		local window = smooth(u / 0.2) * smooth((1 - u) / 0.2)
		pose.Pitch += 0.7 * window * math.atan2(view.Velocity.Y, math.max(flat(view.Velocity).Magnitude, 1))
	else
		local age = clock - view.LastTargetAt
		local overdue = math.max(0.045, TRACK.StopAfter * view.StepGap)
		local feed = view.TargetVelocity * (TRACK.Feed * clamp01(1 - (age - overdue) / 0.03))
		local carried = hitbox + feed * math.min(age, TRACK.Carry * view.StepGap)
		-- (The lag is measured from where the carried hitbox was a frame ago, so only its surprises
		-- - a step that doesn't match the estimate - go through the spring.)
		local lag, lagRate = springVector(view.Position + feed * dt - carried, view.Velocity - feed, Vector3.zero, FOLLOW_RATE, dt)
		view.Position, view.Velocity = carried + lag, feed + lagRate
		local want = view.Yaw + wrapAngle(yawOf(flat(root.CFrame.LookVector)) - view.Yaw)
		view.Yaw, view.YawRate = spring(view.Yaw, view.YawRate, want, TURN_RATE, dt)
	end
	if flying ~= view.Flying then
		-- The flight usually starts a frame or two late (latency): ease the jump out instead of popping.
		view.Flying = flying
		view.Offset = (before + view.Offset * math.exp(-POSITION_BLEND * (clock - view.OffsetStart))) - view.Position
		view.OffsetStart = clock
	end
	local offset = view.Offset * math.exp(-POSITION_BLEND * (clock - view.OffsetStart))
	local centre = view.Position + offset
	-- (The estimate's own rate of change ripples with the replication steps; the lean wants the
	-- underlying trend.)
	view.Accel, view.AccelRate = springVector(view.Accel, view.AccelRate, if flying then Vector3.zero else view.TargetAccel, ACCEL_RATE, dt)
	local heading = CFrame.Angles(0, view.Yaw, 0).LookVector
	local groundVelocity = flat(view.Velocity)
	local speed = groundVelocity.Magnitude
	local alive = 1 - pose.Collapse

	-- 2. Gait: which gait, how fast the cycle turns, how low it rides, and the body's rhythm.
	local weights = gaitWeights(speed)
	for i = 1, #weights do
		view.GaitWeights[i] += (weights[i] - view.GaitWeights[i]) * math.min(dt * 5, 1)
	end
	weights = view.GaitWeights
	if view.Moving then
		view.Moving = speed > MOVE_OFF
	else
		view.Moving = speed > MOVE_ON
	end
	-- (Leaving and touching the ground blends the gait's crouch, rhythm and lean out and back in.)
	view.Air += ((if flying then 1 else 0) - view.Air) * (1 - math.exp(-12 * dt))
	local stepping = clamp01(speed / 5) * (1 - view.Air)
	local dropF = STAND_DROP + (blendGait(weights, "DropF") - STAND_DROP) * stepping
	local dropH = STAND_DROP + (blendGait(weights, "DropH") - STAND_DROP) * stepping
	-- (Lowering the shoulders more than the hips pitches the body, about its centre.)
	local dropPitch = (dropH - dropF) / (body.GirdleZ.Hind - body.GirdleZ.Front)
	local drop = dropF - body.GirdleZ.Front * dropPitch
	local duty = lookup(DUTY, speed)
	-- Step faster rather than over-stretch: each stance can only sweep as far as the legs reach
	-- (plus the shoulder blades' and pelvis's travel).
	local reach = math.min(legReach(body, "FL", dropF) + GIRDLE.Front, legReach(body, "BL", dropH) + GIRDLE.Hind)
	local rate = math.max(lookup(STRIDE_RATE, speed), speed * duty / math.max(2 * reach * 0.85, 0.5))
	if view.Moving and not flying then
		view.Cycle += dt * rate
	end
	local phase = view.Cycle % 1
	local gallop = weights[3]
	local walkish = weights[1]
	local bob = 0
	for i, gait in GAITS do
		bob += gait.Bob * weights[i] * math.cos(2 * math.pi * gait.BobRate * (phase - gait.BobAt))
	end
	bob *= stepping
	-- Gallop: the spine arches in the gathered flight (phase ~0.9) and extends after the hind push
	-- (~0.4), flexing about twice as far as it extends; the body rocks nose-up at the push.
	local gallopSpeed = clamp01((speed - 15) / 15) * 0.6 + 0.4
	local arch = math.cos(2 * math.pi * (phase - 0.9))
	local gaitFlex = (0.67 * arch + 0.33) * 0.42 * gallop * gallopSpeed * stepping
	local gaitPitch = math.cos(2 * math.pi * (phase - 0.42)) * 0.1 * gallop * stepping
		+ math.cos(4 * math.pi * (phase - 0.1)) * 0.025 * walkish * stepping
	-- Walk: the pelvis rolls with the swinging hind leg and the spine snakes a little.
	local gaitRoll = math.sin(2 * math.pi * phase) * 0.05 * (1 - gallop) * stepping
	local gaitSnake = math.sin(2 * math.pi * (phase + 0.25)) * 0.06 * walkish * stepping
	local breathe = math.sin(t * 2.1) * 0.02 * (1 - stepping)

	-- Idle life: weight shifts now and then, and the head scans about.
	if clock >= view.WeightUntil then
		view.WeightUntil = clock + SHIFT.Every[1] + math.random() * (SHIFT.Every[2] - SHIFT.Every[1])
		view.WeightGoal = Vector2.new((math.random() * 2 - 1) * SHIFT.Side, (math.random() * 2 - 1) * SHIFT.Fore)
	end
	view.Weight = view.Weight:Lerp(view.WeightGoal * (1 - stepping), math.min(dt * 2.5, 1))

	-- Dynamics: banks into turns, leans into acceleration, the spine bends into the turn with the
	-- pelvis following a beat later.
	local grounded = 1 - view.Air
	local forward = view.Accel:Dot(heading)
	local bankTarget = -math.clamp(BANK.Gain * math.atan(speed * view.YawRate / G), -BANK.Max, BANK.Max) * smooth((speed - 4) / 8) * grounded * alive
	view.Bank, view.BankRate = spring(view.Bank, view.BankRate, bankTarget, BANK.Rate, dt)
	local lean = if forward > 0 then -math.min(LEAN.Forward * forward / G, LEAN.Max) else math.min(LEAN.Brake * -forward / G, LEAN.Max)
	lean *= grounded * alive
	local leanDrop = math.min(LEAN.Drop * math.abs(forward) / G, 0.27) * grounded * alive
	local bend = math.clamp(view.YawRate * SPINE_BEND.Reach / math.max(speed, 6), -SPINE_BEND.Max, SPINE_BEND.Max) * grounded * alive
	view.HipsBend, view.HipsBendRate = spring(view.HipsBend, view.HipsBendRate, bend, SPINE_BEND.Rate, dt)

	-- 3. The body frame.
	local floor = view.Position - UP * (Config.BodyHeight + leapLift)
	local ground = CFrame.new(floor) * CFrame.Angles(0, view.Yaw, 0)
	local wiggle = pose.Wiggle * math.sin(clock * 25) * 0.07
	local frame = CFrame.new(centre)
		* CFrame.Angles(0, view.Yaw, 0)
		* CFrame.new(view.Weight.X, breathe + bob - pose.Crouch - drop - leanDrop, -pose.Shift - view.Weight.Y)
		* CFrame.Angles(pose.Pitch + lean + gaitPitch + dropPitch - 0.25 * pose.Buckle, wiggle, pose.Roll + view.Bank + gaitRoll)
		* CFrame.new(0, -0.5 * pose.Buckle, 0)

	-- 4. Feet. Planted feet stay put in the world; the gait phase decides when each lifts off, and
	-- it swings to where the body will be over it half a stance after it lands (following the body's
	-- turn as well as its travel), so it passes under the body. The shoulder blades and pelvis
	-- travel with their legs.
	local stanceTime = duty / math.max(rate, 0.1)
	local swingTime = math.clamp((1 - duty) / math.max(rate, 0.1), 0.14, 0.42)
	local liftF, liftH = blendGait(weights, "LiftF"), blendGait(weights, "LiftH")
	local halfStance = math.min(stanceTime * 0.5, reach * 0.85 / math.max(speed, 0.1))
	-- Standing still: the foot that is furthest off steps back under the body (one at a time).
	local idleStepper: string? = nil
	if not view.Moving and not flying and pose.Collapse <= 0 then
		local busy = false
		local worst = IDLE_STEP_ERROR
		for _, leg in LEGS do
			local foot = view.Feet[leg]
			if foot.Swinging then
				busy = true
			else
				local error = flat(foot.Plant - neutralFoot(view, ground, leg)).Magnitude
				if error > worst then
					worst, idleStepper = error, leg
				end
			end
		end
		if busy then
			idleStepper = nil
		end
	end
	local bodyAtFloor = frame * CFrame.new(0, -Config.BodyHeight, 0)
	for _, leg in LEGS do
		local foot = view.Feet[leg]
		local side = SIDE[leg]
		local front = FRONT[leg]
		local neutral = neutralFoot(view, ground, leg)
		if pose.Gather > 0 and not front then
			neutral += heading * (0.5 * pose.Gather)
		end
		local home = neutral:Lerp(ground * body.Stride[leg], stepping)
		local cycle = view.Cycle + blendOffset(weights, leg)
		local legPhase = cycle % 1
		local cycleIndex = math.floor(cycle)
		-- The shoulder blade / pelvis: forward at touchdown, back at lift-off, returning in the
		-- swing; the stance-side shoulder rises a little (the prowling shoulder roll).
		local travel = if legPhase < duty then math.cos(math.pi * legPhase / duty) else -math.cos(math.pi * (legPhase - duty) / (1 - duty))
		local rise = if legPhase < duty then math.sin(math.pi * legPhase / duty) else 0
		local amount = (if front then GIRDLE.Front else GIRDLE.Hind) * stepping * alive
		foot.Girdle = Vector3.new(0, (if front then GIRDLE.Rise else GIRDLE.Rise * 0.5) * rise * stepping * alive, -amount * travel)
		-- Lift-off: once per gait cycle at its phase, early if the leg is about to over-stretch,
		-- or an idle corrective step.
		if not foot.Swinging and not flying then
			local joint = bodyAtFloor * (body.Joint[leg] + foot.Girdle)
			local endPoint = foot.Plant + (if front then Vector3.zero else -bodyAtFloor:VectorToWorldSpace(body.Meta[leg]))
			local stretched = (endPoint - joint).Magnitude > body.Reach[leg] * 0.99
			if view.Moving and ((legPhase >= duty and foot.Cycle ~= cycleIndex) or stretched) then
				foot.Cycle = if legPhase >= duty then cycleIndex else cycleIndex - 1
				startSwing(foot, swingTime, clock, ground, groundVelocity, view.YawRate)
				foot.Landing = predictGround(ground, groundVelocity, view.YawRate, swingTime + halfStance) * ground:PointToObjectSpace(home)
			elseif leg == idleStepper or (stretched and not view.Moving) then
				startSwing(foot, IDLE_STEP_TIME, clock, ground, groundVelocity, view.YawRate)
				foot.Landing = neutral
			elseif (foot.Plant - neutral).Magnitude > MAX_PLANT_ERROR then
				foot.Plant = neutral -- teleported: catch up at once
			end
		end
		local position
		if foot.Swinging then
			local s = clamp01((clock - foot.SwingStart) / foot.SwingTime)
			if s < RETARGET_UNTIL then
				foot.Landing = if view.Moving
					then predictGround(ground, groundVelocity, view.YawRate, (1 - s) * foot.SwingTime + halfStance) * ground:PointToObjectSpace(home)
					else neutral
			end
			-- The path is drawn in the body's frame, from where the paw left to where it will land
			-- (as the body will be then), leaving and arriving at the ground's speed in that frame:
			-- so the paw lifts off and sets down at rest, trailing back after lift-off and reaching
			-- out past the landing spot before settling onto it, and it follows the body round a
			-- turn instead of cutting under it.
			local touchdown = predictGround(ground, groundVelocity, view.YawRate, (1 - s) * foot.SwingTime)
			local landing = touchdown:PointToObjectSpace(foot.Landing)
			local landingRate = stillRate(landing, ground:VectorToObjectSpace(groundVelocity), view.YawRate)
			local path = hermite(foot.FromLocal, foot.FromRate * foot.SwingTime, landing, landingRate * foot.SwingTime, s)
			local lift = if view.Moving then (if front then liftF else liftH) * stepping + 0.08 else 0.2
			-- Walking it peaks early and sets down softly; at a run the paw stays up longer and
			-- stabs down (it would otherwise skim the floor while still swinging forward fast).
			local descent = 3.2 - 2.2 * clamp01((speed - 5) / 12)
			local peak = 2 / (2 + descent)
			local height = lift * (s / peak) ^ 2 * ((1 - s) / (1 - peak)) ^ descent
			position = ground * path + UP * height
			-- The paw peels off the floor and lands flat a little before touchdown, easing both ways.
			foot.Lifted = smooth(math.min(s, 0.9 - s) / 0.3)
			if s >= 1 then
				foot.Swinging = false
				foot.Plant = foot.Landing
				position = foot.Landing
				foot.Lifted = 0
			end
		else
			position = foot.Plant
			foot.Lifted = 0
		end
		-- Attack poses take over a foot smoothly, and give it back just as smoothly.
		local override: Vector3? = nil
		local want = 0
		local swipe = if leg == "FL" then pose.LeftSwipe elseif leg == "FR" then pose.RightSwipe else nil
		if flying then
			local pair = if front then FLIGHT_FRONT else FLIGHT_BACK
			override = frame * mirror(pair[1]:Lerp(pair[2], smooth(pose.Flight)), side)
			want = 1
		elseif pose.Collapse > 0 then
			-- Dying: the legs go limp, splayed from the body.
			local limp = body.Stance[leg] + Vector3.new(side * 0.6, 0.6, if front then -0.4 else 0.4)
			override = bodyAtFloor * limp
			want = pose.Collapse
		elseif swipe then
			local restLocal = frame:PointToObjectSpace(position)
			override = frame * swipeFoot(restLocal, side, swipe)
			want = clamp01(swipe.Wind * (1 - swipe.Back) + (1 - swipe.Back) * swipe.Sweep)
		elseif front and pose.Buckle > 0 then
			override = ground * (body.Stance[leg] + Vector3.new(side * 0.3, 0, -0.55))
			want = pose.Buckle
		end
		local held = view.Overrides[leg]
		held += (want - held) * math.min(dt * (if want > held then 30 else 9), 1)
		if want <= 0 and held < 0.01 then
			held = 0
		end
		view.Overrides[leg] = held
		if override then
			foot.Held = override
		end
		if held > 0 then
			position = position:Lerp(foot.Held, held)
			foot.Lifted = math.max(foot.Lifted, held)
		end
		if held > 0.5 and (flying or pose.Collapse > 0) then
			-- Off the ground for now: when it comes back, it lands under the body.
			foot.Swinging = false
			foot.Plant = neutral
		end
		-- Never into the floor: a foot goes no lower than it stands (a limp, dying one a little lower).
		local lowest = floor.Y + body.Stance[leg].Y + (0.15 - body.Stance[leg].Y) * pose.Collapse
		position = Vector3.new(position.X, math.max(position.Y, lowest), position.Z)
		foot.Position = position
	end

	-- 5. Head: steady while the body bobs, leading into turns, tracking the nearest player with a
	-- little overshoot, or scanning about when nobody is near.
	local target = nearestPlayer(view.Position, Config.DetectRange)
	local lookYaw, lookPitch
	if target then
		local toTarget = target - view.Position
		local along = unitOr(flat(toTarget), heading)
		lookYaw = math.atan2(heading:Cross(along).Y, heading:Dot(along))
		lookPitch = math.atan2(toTarget.Y, flat(toTarget).Magnitude)
	else
		if clock >= view.GazeUntil then
			view.GazeUntil = clock + SCAN.Hold[1] + math.random() * (SCAN.Hold[2] - SCAN.Hold[1])
			view.Gaze = Vector2.new((math.random() * 2 - 1) * SCAN.Yaw, (math.random() * 2 - 1) * SCAN.Pitch)
		end
		lookYaw, lookPitch = view.Gaze.X, view.Gaze.Y
	end
	lookYaw = math.clamp(lookYaw + view.YawRate * LOOK.Lead, -LOOK.MaxYaw, LOOK.MaxYaw) * alive
	lookPitch = math.clamp(lookPitch, -LOOK.MaxPitch, LOOK.MaxPitch) * alive
	view.LookYaw, view.LookYawRate = wobbleSpring(view.LookYaw, view.LookYawRate, lookYaw - bend * 0.5, LOOK.Omega, LOOK.Damping, dt)
	view.LookPitch, view.LookPitchRate = wobbleSpring(view.LookPitch, view.LookPitchRate, lookPitch, LOOK.Omega, LOOK.Damping, dt)
	-- Undo the body's rhythmic pitch, lean and bob at the neck so the head rides level.
	local steady = -(gaitPitch + lean + bob * 0.3) * alive
	local spine: Spine = {
		Bend = bend * 0.5 + view.HipsBend * 0.5 + gaitSnake,
		Flex = pose.Flex + gaitFlex,
		Roll = gaitRoll * 0.8,
		Twist = pose.Twist,
		NeckPitch = 0.6 * (pose.HeadPitch + view.LookPitch) - 0.35 * pose.NeckPush + 0.7 * steady,
		HeadPitch = 0.4 * (pose.HeadPitch + view.LookPitch) + 0.3 * pose.NeckPush + 0.3 * steady,
		HeadYaw = view.LookYaw + pose.HeadTurn,
		NeckShift = 0.06 * pose.NeckPush,
		TailYaw = math.clamp(-0.17 * view.YawRate, -0.8, 0.8) * alive,
		TailPitch = (0.12 * gallop * stepping + math.clamp(-forward / 80, 0, 1) * 0.4 - 0.6 * gaitPitch) * alive,
	}

	applyBody(view, frame, ground, pose, spine, dt)
end

-------------------------------------------------------------------------------- lifecycle

local function flash(body: Body)
	body.Flash.FillTransparency = 0.45
	TweenService:Create(body.Flash, TweenInfo.new(0.18), { FillTransparency = 1 }):Play()
end

local function onAction(view: View)
	local server = view.Server
	local seq = attribute(server, "ActionSeq", 0)
	if seq == view.Seq then
		return
	end
	view.Seq = seq
	view.PendingBlend = true
	local action = attribute(server, "Action", "")
	local point = attribute(server, "ActionPoint", "")
	local strike = attribute(server, "ActionStrike", 0)
	local remaining = strike - serverNow()
	local adornee = view.Body.Points[point]
	if adornee and remaining > 0.02 then
		-- Same cue language as every enemy: the cyan glint, with its ring closing on the hit.
		EnemyVisuals.Telegraph(view.Body.Model, true, remaining, adornee)
	elseif action == "Recoil" or action == "Stagger" or action == "Death" or action == "" then
		EnemyVisuals.ClearTelegraph(view.Body.Model)
	end
	if action == "Death" and not view.Fading then
		view.Fading = true
		TweenService:Create(view.Body.Glow, TweenInfo.new(0.6), { Brightness = 0 }):Play()
		task.delay(math.max(Config.DeathTime - 0.9, 0.5), function()
			if not view.Body.Model.Parent then
				return
			end
			TweenService:Create(view.Body.Mesh, TweenInfo.new(0.8), { Transparency = 1 }):Play()
		end)
	end
end

local function destroyView(server: Model)
	local view = views[server]
	if not view then
		return
	end
	views[server] = nil
	for _, connection in view.Connections do
		connection:Disconnect()
	end
	EnemyVisuals.ClearTelegraph(view.Body.Model)
	view.Body.Model:Destroy()
end

local function track(server: Model)
	if views[server] or not server:IsA("Model") or server:GetAttribute("StalkerId") == nil then
		return
	end
	local root = server.PrimaryPart or server:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not root or not server.Parent then
		return
	end
	local humanoid = server:FindFirstChildOfClass("Humanoid") or server:WaitForChild("Humanoid", 5) :: Humanoid?
	local body = buildBody(server:GetAttribute("StalkerId"))
	if not body then
		return
	end
	local heading = unitOr(flat(root.CFrame.LookVector), -Vector3.zAxis)
	local yaw = yawOf(heading)
	local ground = CFrame.new(root.Position - UP * Config.BodyHeight) * CFrame.Angles(0, yaw, 0)
	local feet: { [string]: Foot } = {}
	for _, leg in LEGS do
		local plant = ground * body.Stance[leg]
		feet[leg] = {
			Plant = plant,
			Swinging = false,
			From = plant,
			FromLocal = Vector3.zero,
			FromRate = Vector3.zero,
			SwingStart = 0,
			SwingTime = 0.3,
			Cycle = -1,
			Landing = plant,
			Position = plant,
			Lifted = 0,
			Girdle = Vector3.zero,
			Held = plant,
		}
	end
	local view: View = {
		Server = server,
		Body = body,
		Position = root.Position,
		Velocity = Vector3.zero,
		Accel = Vector3.zero,
		AccelRate = Vector3.zero,
		Yaw = yaw,
		YawRate = 0,
		Cycle = math.random(),
		Moving = false,
		GaitWeights = { 1, 0, 0 },
		Feet = feet,
		Overrides = { FL = 0, FR = 0, BL = 0, BR = 0 },
		Flying = false,
		Air = 0,
		Trail = root.Position,
		TargetVelocity = Vector3.zero,
		TargetAccel = Vector3.zero,
		LastTarget = root.Position,
		LastTargetAt = os.clock(),
		StepGap = 1 / 30,
		Offset = Vector3.zero,
		OffsetStart = 0,
		Bank = 0,
		BankRate = 0,
		HipsBend = 0,
		HipsBendRate = 0,
		Gaze = Vector2.zero,
		GazeUntil = 0,
		Weight = Vector2.zero,
		WeightGoal = Vector2.zero,
		WeightUntil = 0,
		Tail = {},
		TailVelocity = {},
		LookYaw = 0,
		LookYawRate = 0,
		LookPitch = 0,
		LookPitchRate = 0,
		Sprung = {},
		SprungRate = {},
		LastPose = {},
		Residual = {},
		ResidualStart = 0,
		PendingBlend = false,
		FlinchKick = 0,
		ParryFlinchUntil = 0,
		LastHealth = if humanoid then humanoid.Health else 0,
		Seq = -1,
		Fading = false,
		Connections = {},
	}
	views[server] = view
	table.insert(view.Connections, server:GetAttributeChangedSignal("ActionSeq"):Connect(function()
		onAction(view)
	end))
	table.insert(view.Connections, server:GetAttributeChangedSignal("ParrySeq"):Connect(function()
		view.ParryFlinchUntil = os.clock() + 0.3
	end))
	if humanoid then
		table.insert(view.Connections, humanoid.HealthChanged:Connect(function(health)
			if health < view.LastHealth and health > 0 then
				view.FlinchKick = 1
				flash(view.Body)
			end
			view.LastHealth = health
		end))
	end
	table.insert(view.Connections, server.AncestryChanged:Connect(function()
		if not server:IsDescendantOf(workspace) then
			destroyView(server)
		end
	end))
	onAction(view)
	view.PendingBlend = false
end

function StalkerVisuals.Init()
	task.spawn(function()
		local folder = workspace:WaitForChild("Enemies")
		folder.ChildAdded:Connect(function(child)
			task.spawn(track, child)
		end)
		for _, child in folder:GetChildren() do
			task.spawn(track, child)
		end
	end)
	RunService.RenderStepped:Connect(function(dt)
		local t = serverNow()
		for _, view in views do
			updateView(view, dt, t)
		end
	end)
end

return StalkerVisuals
