-- Client visuals for the Abyssal Stalker: the user's rigged model (ReplicatedStorage/EnemyModels/
-- Stalker, a skinned MeshPart; rig made by Tools/Stalker/rig_stalker.py) animated procedurally by
-- driving its bones. The server's invisible hitbox model (StalkerService, in Workspace/Enemies)
-- decides everything; this follows it smoothly and reads its attributes (Action, ActionStep,
-- ActionStrike, ActionPoint, Leap*, ParrySeq) to pose the body and show the cyan parry telegraph.
--
-- Rig (model space: origin on the floor under the middle of the body, -Z forward, -X = its left):
-- Root > Hips > Spine > Chest > Neck > Head > Jaw; Hips > Tail1..Tail5; Hips > BackThigh > BackShin >
-- BackFoot (hock) > BackToes (ball) for each hind leg; Chest > FrontUpper > FrontLower > FrontFoot
-- (wrist) for each front leg. The legs are solved with IK onto floor targets, the tail is
-- rope-follow, the neck, head and jaw are rotated. The named points the telegraphs use (Head,
-- BiteOrigin, LeftClaw, RightClaw, the same names as StalkerConfig.Points) are attachments that
-- follow their bones.
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
local FRONT_BONES = { FL = { "FrontUpperL", "FrontLowerL", "FrontFootL" }, FR = { "FrontUpperR", "FrontLowerR", "FrontFootR" } }
local BACK_BONES = { BL = { "BackThighL", "BackShinL", "BackFootL", "BackToesL" }, BR = { "BackThighR", "BackShinR", "BackFootR", "BackToesR" } }
local TAIL_SEGMENTS = 5
local TAIL_BEND = math.rad(14) -- how far each tail segment may trail off its rest direction, times its number
local TAIL_RELAX = 6 -- 1/s: how quickly the tail swings back behind the body
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
local JAW_REST = 0.65
local JAW_RANGE = 0.6
-- Gait phase offsets: a trot (diagonal pairs) at walking pace, a bounding gallop at a run.
local TROT = { FL = 0, BR = 0, FR = math.pi, BL = math.pi }
local GALLOP = { FL = 0, FR = 0.45, BL = math.pi, BR = math.pi + 0.45 }
local RUN_SPEED = 16 -- studs/s where the trot has fully become a gallop
-- Foot targets in the body frame (studs from the body centre): mid-lunge (front: the wrist,
-- hind: the ball of the foot) and a frenzy swipe's raised and raking ends (the wrist; x is
-- mirrored per side).
local FLIGHT_FRONT = Vector3.new(0.9, -1.0, -2.6)
local FLIGHT_BACK = Vector3.new(0.8, -1.9, 3.6)
local SWIPE_RAISED = Vector3.new(1.6, 0.6, -1.7)
local SWIPE_RAKED = Vector3.new(-0.2, -1.4, -3.0)

type Pose = {
	Crouch: number, -- lowers the body
	Pitch: number, -- nose up (+)
	Roll: number,
	HeadPitch: number,
	NeckPush: number, -- head forward (+) or drawn back (-)
	Jaw: number, -- 0 shut .. 1 wide open
	Tremble: number,
	Buckle: number, -- front legs giving way (stagger)
	Collapse: number, -- 0..1 dying
	Flight: boolean,
	LeftSwipe: { Wind: number, Sweep: number, Back: number }?,
	RightSwipe: { Wind: number, Sweep: number, Back: number }?,
}

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
	Stance: { [string]: Vector3 }, -- rest foot targets in the ground frame (wrist / ball of the foot)
	Meta: { [string]: Vector3 }, -- hind legs: hock to ball, model space
	TailLengths: { number },
	Points: { [string]: Attachment }, -- Head, BiteOrigin, LeftClaw, RightClaw
	PointOffsets: { [string]: CFrame }, -- each point relative to its bone
	Flash: Highlight,
	Glow: PointLight,
	GlowPoint: Attachment,
}

type View = {
	Server: Model,
	Body: Body,
	Position: Vector3, -- smoothed body centre
	Heading: Vector3, -- smoothed flat facing
	Speed: number, -- smoothed ground speed
	Phase: number, -- gait phase
	RunBlend: number,
	Gait: number, -- how much the legs step (0 standing still)
	Tail: { Vector3 },
	HeadYaw: number,
	FlinchUntil: number,
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

local function smooth(x: number): number
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
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
	for leg, bones in BACK_BONES do
		body.Meta[leg] = body.Rest[bones[4]].Position - body.Rest[bones[3]].Position
	end
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
	local distance = math.clamp(offset.Magnitude, math.abs(upper - lower) + 0.05, upper + lower - 0.02)
	local dir = unitOr(offset, -UP)
	target = root + dir * distance
	local along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
	local height = math.sqrt(math.max(upper * upper - along * along, 0))
	local side = unitOr(bend - dir * bend:Dot(dir), UP)
	return root + dir * along + side * height, target
end

-- Poses the rig. `frame` is the body centre (Config.BodyHeight above the model origin), `ground`
-- the floor under it, `feet` the solved foot targets (front: wrists, hind: balls of the feet).
local function applyBody(view: View, frame: CFrame, ground: CFrame, pose: Pose, feet: { [string]: Vector3 }, plant: { [string]: number }, dt: number)
	local body = view.Body
	local rest, relative = body.Rest, body.Relative
	local shake = if pose.Tremble > 0 then CFrame.new(math.sin(os.clock() * 61) * 0.04 * pose.Tremble, 0, math.sin(os.clock() * 47) * 0.03 * pose.Tremble) else CFrame.identity
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
	-- Sits at `from` and points at `to`; twist follows the body.
	local function aim(name: string, from: Vector3, to: Vector3, basis: CFrame)
		local restDir = basis:VectorToWorldSpace(body.Direction[name])
		posed[name] = CFrame.new(from) * rotationBetween(restDir, unitOr(to - from, restDir)) * basis.Rotation * rest[name].Rotation
	end
	-- On the floor (`planted` 1) or carried rigidly by its parent (0).
	local function foot(name: string, planted: number)
		local carried = parentOf(name) * relative[name]
		local flatOn = CFrame.new(carried.Position) * ground.Rotation * rest[name].Rotation
		posed[name] = carried:Lerp(flatOn, planted)
	end

	fk("Root")
	fk("Hips")
	fk("Spine")
	fk("Chest")

	-- Neck and head: share the yaw and pitch; pushed forward or drawn back.
	local yaw = view.HeadYaw * 0.5
	fk("Neck", CFrame.Angles(0, yaw, 0) * CFrame.Angles(0.5 * pose.HeadPitch - 0.3 * pose.NeckPush, 0, 0), Vector3.new(0, 0, -0.35 * pose.NeckPush))
	fk("Head", CFrame.Angles(0, yaw, 0) * CFrame.Angles(0.5 * pose.HeadPitch + 0.3 * pose.NeckPush, 0, 0))
	fk("Jaw", CFrame.Angles(-(pose.Jaw - JAW_REST) * JAW_RANGE, 0, 0))

	-- Front legs: shoulder > elbow (bends back) > wrist on its target; the paw lies on the floor.
	for leg, bones in FRONT_BONES do
		local side = SIDE[leg]
		local upper, lower, paw = bones[1], bones[2], bones[3]
		local shoulder = (posed.Chest * relative[upper]).Position
		local bend = modelCF:VectorToWorldSpace(Vector3.new(side * 0.3, 0, 1))
		local elbow, wrist = solveLimb(shoulder, feet[leg], bend, body.Length[upper], body.Length[lower])
		aim(upper, shoulder, elbow, modelCF)
		aim(lower, elbow, wrist, modelCF)
		foot(paw, plant[leg])
	end

	-- Hind legs: hip > knee (bends forward) > hock > ball on its target. The metatarsal keeps its
	-- rest angle to the floor (to the body in flight), so the IK solves hip to hock.
	for leg, bones in BACK_BONES do
		local side = SIDE[leg]
		local thigh, shin, meta, toes = bones[1], bones[2], bones[3], bones[4]
		local basis = if pose.Flight then modelCF else ground
		local hip = (posed.Hips * relative[thigh]).Position
		local metaWorld = basis:VectorToWorldSpace(body.Meta[leg])
		local bend = modelCF:VectorToWorldSpace(Vector3.new(side * 0.3, 0, -1))
		local knee, hock = solveLimb(hip, feet[leg] - metaWorld, bend, body.Length[thigh], body.Length[shin])
		aim(thigh, hip, knee, modelCF)
		aim(shin, knee, hock, modelCF)
		aim(meta, hock, hock + metaWorld, basis)
		foot(toes, plant[leg])
	end

	-- Tail: rope-follow from the hips, keeping its rest curve, swaying side to side.
	local points = view.Tail
	local base = (posed.Hips * relative.Tail1).Position
	if #points == 0 then
		points[1] = base
		for i = 1, TAIL_SEGMENTS do
			points[i + 1] = points[i] + modelCF:VectorToWorldSpace(body.Direction["Tail" .. i]) * body.TailLengths[i]
		end
	end
	points[1] = base
	local floorY = ground.Position.Y + 0.25
	local relax = math.min(dt * TAIL_RELAX, 1)
	local swayAxis = modelCF.RightVector
	for i = 2, #points do
		local length = body.TailLengths[i - 1]
		local restDir = modelCF:VectorToWorldSpace(body.Direction["Tail" .. (i - 1)])
		local follow = points[i - 1] + unitOr(points[i] - points[i - 1], restDir) * length
		local sway = math.sin(view.Phase * 0.5 - i * 0.8) * (0.15 + 0.25 * view.Gait) * (i / #points)
		local straight = points[i - 1] + restDir * length + swayAxis * sway
		local dir = unitOr(follow:Lerp(straight, relax) - points[i - 1], restDir)
		-- A long tail lags far behind fast turns: keep each segment within its bend limit.
		local limit = TAIL_BEND * (i - 1)
		local angle = math.acos(math.clamp(dir:Dot(restDir), -1, 1))
		if angle > limit then
			local axis = restDir:Cross(dir)
			dir = if axis.Magnitude > 1e-5 then CFrame.fromAxisAngle(axis.Unit, limit):VectorToWorldSpace(restDir) else restDir
		end
		local p = points[i - 1] + dir * length
		points[i] = Vector3.new(p.X, math.max(p.Y, floorY), p.Z)
	end
	for i = 1, TAIL_SEGMENTS do
		aim("Tail" .. i, points[i], points[i + 1], modelCF)
	end

	-- Write the bones (each relative to its parent's posed frame) and move the points.
	for _, name in body.Order do
		local cf = posed[name]
		if cf then
			body.Bones[name].Transform = (parentOf(name) * relative[name]):Inverse() * cf
		end
	end
	for name, attachment in body.Points do
		attachment.WorldCFrame = posed[POINTS[name].Bone] * body.PointOffsets[name]
	end
	body.GlowPoint.WorldPosition = posed.Chest.Position
end

-------------------------------------------------------------------------------- animation

local function attribute(model: Model, name: string, default: any): any
	local value = model:GetAttribute(name)
	if value == nil then
		return default
	end
	return value
end

-- The action layer of the pose, from the server's attributes and the server clock.
local function actionPose(view: View, t: number): (Pose, string, number)
	local pose: Pose = {
		Crouch = 0,
		Pitch = 0,
		Roll = 0,
		HeadPitch = 0,
		NeckPush = 0,
		Jaw = 0.08,
		Tremble = 0,
		Buckle = 0,
		Collapse = 0,
		Flight = false,
		LeftSwipe = nil,
		RightSwipe = nil,
	}
	local model = view.Server
	local action = attribute(model, "Action", "")
	local step = attribute(model, "ActionStep", 0)
	local elapsed = t - attribute(model, "ActionStart", 0)
	local strike = attribute(model, "ActionStrike", 0)
	local frenzy = Config.Frenzy

	if action == "Bite" or (action == "Frenzy" and step == 3) then
		-- Head draws back with the jaws opening, snaps forward, then settles.
		local isBite = action == "Bite"
		local windup = if isBite then Config.Bite.Windup else frenzy.Strikes[3].Windup
		local active = if isBite then Config.Bite.Active else frenzy.Active
		local recovery = if isBite then Config.Bite.Recovery else frenzy.Recovery
		local since = t - strike
		if since < 0 then
			local w = easeOut(1 + since / windup)
			pose.NeckPush, pose.HeadPitch, pose.Jaw, pose.Crouch, pose.Tremble = -0.7 * w, 0.3 * w, 0.1 + 0.85 * w, 0.15 * w, w
		elseif since < active then
			local s = easeOut(since / active)
			pose.NeckPush, pose.HeadPitch, pose.Jaw, pose.Crouch = -0.7 + 1.9 * s, 0.3 - 0.45 * s, 0.95 * (1 - s), 0.15 - 0.25 * s
		else
			local r = 1 - smooth((since - active) / recovery)
			pose.NeckPush, pose.HeadPitch, pose.Jaw, pose.Crouch = 1.2 * r, -0.15 * r, 0.1, -0.1 * r
		end
	elseif action == "Frenzy" then
		-- A front leg rears up and back, then rakes forward across; the body rears and rolls with it.
		local strikeCfg = frenzy.Strikes[step]
		local windup = if strikeCfg then strikeCfg.Windup else 0.25
		local since = t - strike
		local swipe = { Wind = 0, Sweep = 0, Back = 0 }
		if since < 0 then
			swipe.Wind = easeOut(1 + since / windup)
		elseif since < frenzy.Active then
			swipe.Wind, swipe.Sweep = 1, easeOut(since / frenzy.Active)
		else
			swipe.Wind, swipe.Sweep, swipe.Back = 1, 1, smooth((since - frenzy.Active) / (frenzy.Gap + 0.15))
		end
		local side = if step == 1 then -1 else 1
		if step == 1 then
			pose.LeftSwipe = swipe
		else
			pose.RightSwipe = swipe
		end
		local raised = swipe.Wind * (1 - swipe.Back)
		pose.Pitch, pose.Roll = 0.14 * raised, -side * 0.12 * raised
		pose.HeadPitch, pose.Jaw = 0.1, 0.45
		pose.Tremble = if since < 0 then 0.6 else 0
	elseif action == "Lunge" then
		if step == 1 then
			-- Crouches low on its hind legs, coiling.
			local w = easeOut(elapsed / Config.Lunge.Windup)
			pose.Crouch, pose.Pitch, pose.HeadPitch, pose.Jaw, pose.Tremble = 0.8 * w, 0.06 * w, 0.15 * w, 0.1 + 0.5 * w, w
		elseif step == 2 then
			pose.Flight, pose.Jaw, pose.HeadPitch, pose.NeckPush = true, 1, 0.05, 0.5
		elseif step == 3 then
			-- Lands hard, then rises out of the crouch.
			local r = 1 - smooth(elapsed / Config.Lunge.Recovery)
			pose.Crouch, pose.Jaw, pose.Pitch = 0.75 * r, 0.1 + 0.3 * r, -0.12 * r
		end
	elseif action == "Recoil" then
		-- A parried bite or lunge: the head is thrown back and up.
		local r = clamp01(elapsed / Config.Recoil.Time)
		local k = math.sin(math.min(r * 4, 1) * math.pi / 2) * (1 - smooth(r))
		pose.HeadPitch, pose.NeckPush, pose.Pitch, pose.Jaw = 0.75 * k, -0.9 * k, 0.2 * k, 0.5 * k
	elseif action == "Stagger" then
		-- All three frenzy strikes parried: the head recoils and the front legs buckle.
		local k = math.min(elapsed / 0.12, 1) * (1 - smooth((elapsed - frenzy.StaggerTime * 0.7) / (frenzy.StaggerTime * 0.3)))
		pose.HeadPitch, pose.NeckPush, pose.Buckle, pose.Pitch, pose.Jaw = 0.55 * k, -0.6 * k, k, -0.22 * k, 0.5 * k
		pose.Roll = 0.12 * math.sin(elapsed * 14) * k
	elseif action == "Death" then
		local c = smooth(elapsed / 0.7)
		pose.Collapse, pose.Crouch, pose.Roll, pose.Jaw, pose.HeadPitch = c, 1.35 * c, 1.15 * c, 0.5 * c, -0.25 * c
	end
	return pose, action, step
end

-- A front wrist's swipe, from its stepping position (all in the body frame).
local function swipeFoot(rest: Vector3, side: number, swipe: { Wind: number, Sweep: number, Back: number }): Vector3
	local raised = mirror(SWIPE_RAISED, side)
	local raked = mirror(SWIPE_RAKED, side)
	if swipe.Sweep <= 0 then
		return rest:Lerp(raised, swipe.Wind)
	elseif swipe.Back <= 0 then
		return raised:Lerp(raked, swipe.Sweep)
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

local function updateView(view: View, dt: number, t: number)
	local server = view.Server
	local root = server.PrimaryPart
	if not root then
		return
	end
	local pose, action, step = actionPose(view, t)

	-- Follow the server's hitbox smoothly; a lunge's flight is drawn from its exact arc.
	local previous = view.Position
	local leapLift = 0
	if action == "Lunge" and step == 2 then
		local from = attribute(server, "LeapFrom", root.Position)
		local to = attribute(server, "LeapTo", root.Position)
		local u = clamp01((t - attribute(server, "LeapStart", t)) / math.max(attribute(server, "LeapDuration", 0.4), 0.01))
		leapLift = 4 * attribute(server, "LeapHeight", 2.5) * u * (1 - u)
		view.Position = from:Lerp(to, u) + UP * (Config.BodyHeight + leapLift)
		view.Heading = unitOr(flat(to - from), view.Heading)
		-- Pitches with the arc.
		pose.Pitch += math.atan2(4 * attribute(server, "LeapHeight", 2.5) * (1 - 2 * u), math.max((to - from).Magnitude, 1))
	else
		local k = 1 - math.exp(-Visuals.Smoothing * dt)
		view.Position = view.Position:Lerp(root.Position, k)
		view.Heading = unitOr(view.Heading:Lerp(flat(root.CFrame.LookVector), k), view.Heading)
	end
	local moved = flat(view.Position - previous)
	if dt > 0 then
		view.Speed += (moved.Magnitude / dt - view.Speed) * math.min(dt * 10, 1)
	end

	-- Flinches: hit (a jolt) and a parried frenzy strike (head knocked back).
	local clock = os.clock()
	if clock < view.FlinchUntil then
		local f = math.sin(math.pi * clamp01(1 - (view.FlinchUntil - clock) / 0.2))
		pose.Crouch -= 0.15 * f
		pose.HeadPitch += 0.2 * f
	end
	if clock < view.ParryFlinchUntil then
		local f = math.sin(math.pi * clamp01(1 - (view.ParryFlinchUntil - clock) / 0.3))
		pose.HeadPitch += 0.5 * f
		pose.NeckPush -= 0.6 * f
	end

	-- Locomotion: gait phase advances with ground speed (feet don't slide), trot -> gallop.
	local moving = not pose.Flight and pose.Collapse <= 0
	view.Gait += ((if moving then clamp01(view.Speed / 6) else 0) - view.Gait) * math.min(dt * 8, 1)
	view.RunBlend += (clamp01((view.Speed - 8) / (RUN_SPEED - 8)) - view.RunBlend) * math.min(dt * 5, 1)
	local stride = 1.5 + 1.5 * view.RunBlend
	view.Phase += dt * view.Speed * math.pi / stride

	-- Body: breathing at rest, a bob that grows into a bounding spine flex at a gallop.
	local breathe = math.sin(t * 2.2) * 0.04 * (1 - view.Gait)
	local bob = math.abs(math.sin(view.Phase)) * (0.05 + 0.12 * view.RunBlend) * view.Gait
	local flex = math.sin(view.Phase * 2) * 0.06 * view.RunBlend * view.Gait
	local floor = view.Position - UP * (Config.BodyHeight + leapLift)
	local ground = CFrame.lookAt(floor, floor + view.Heading)
	local frame = CFrame.lookAt(view.Position, view.Position + view.Heading)
		* CFrame.new(0, breathe + bob - pose.Crouch, 0)
		* CFrame.Angles(pose.Pitch + flex - 0.25 * pose.Buckle, 0, pose.Roll)
		* CFrame.new(0, -0.5 * pose.Buckle, 0)

	-- Head looks toward the nearest player (or idly around).
	local target = nearestPlayer(view.Position, Config.DetectRange)
	local yaw = if target then math.clamp(math.atan2(view.Heading:Cross(unitOr(flat(target - view.Position), view.Heading)).Y, view.Heading:Dot(unitOr(flat(target - view.Position), view.Heading))), -0.6, 0.6) else math.sin(t * 0.45) * 0.5
	if pose.Collapse > 0 then
		yaw = 0
	end
	view.HeadYaw += (yaw - view.HeadYaw) * math.min(dt * 6, 1)

	-- Feet (front: the wrist, hind: the ball of the foot), and how flat each one is on the floor.
	local stance = view.Body.Stance
	local feet: { [string]: Vector3 } = {}
	local plant: { [string]: number } = {}
	for _, leg in LEGS do
		local side = SIDE[leg]
		local front = leg == "FL" or leg == "FR"
		local foot
		local planted = 1
		if pose.Flight then
			-- Front legs reach for the target, hind legs trail from the push-off.
			foot = frame * mirror(if front then FLIGHT_FRONT else FLIGHT_BACK, side)
			planted = 0
		elseif pose.Collapse > 0 then
			-- Legs splay out as it goes down.
			foot = ground * (stance[leg] + Vector3.new(side * 0.9 * pose.Collapse, 0, 0))
		else
			local offset = (TROT[leg] * (1 - view.RunBlend) + GALLOP[leg] * view.RunBlend)
			local p = view.Phase + offset
			local reach = -math.cos(p) * stride * 0.5 * view.Gait
			local lift = math.max(math.sin(p), 0) * (0.35 + 0.35 * view.RunBlend) * view.Gait
			foot = ground * (stance[leg] + Vector3.new(0, lift, reach))
			planted = 1 - clamp01(lift / 0.3)
			local swipe = if leg == "FL" then pose.LeftSwipe elseif leg == "FR" then pose.RightSwipe else nil
			if swipe then
				foot = frame * swipeFoot(frame:PointToObjectSpace(foot), side, swipe)
				planted = 1 - clamp01(swipe.Wind * (1 - swipe.Back) * 3)
			elseif front and pose.Buckle > 0 then
				foot = ground * (stance[leg] + Vector3.new(side * 0.3 * pose.Buckle, 0, -0.5 * pose.Buckle))
			end
		end
		feet[leg] = foot
		plant[leg] = planted
	end

	applyBody(view, frame, ground, pose, feet, plant, dt)
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
	local view: View = {
		Server = server,
		Body = body,
		Position = root.Position,
		Heading = unitOr(flat(root.CFrame.LookVector), -Vector3.zAxis),
		Speed = 0,
		Phase = math.random() * 10,
		RunBlend = 0,
		Gait = 0,
		Tail = {},
		HeadYaw = 0,
		FlinchUntil = 0,
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
				view.FlinchUntil = os.clock() + 0.2
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
