-- Client visuals for the Abyssal Stormfin. The server sends motion segments (StormfinEvent); this
-- plays the creature along the same path (StormfinMotion), with a spine that follows its own trail
-- so it undulates like an eel. The animation is driven by the motion: the tail beat is locked to how
-- far it actually swims (so it never slides), it strokes harder when accelerating and just trails
-- when coasting or flying, and it banks into turns. The creature is the user's rigged Meshy model
-- (ReplicatedStorage/EnemyModels/Stormfin: a skinned MeshPart with bones Spine1 (head)..Spine6
-- under Root) whose bones are driven along that spine; a part-built body is the fallback. Water carries the readability:
-- glow + ripples while it hunts underwater, crackling ripples and the cyan parry cue before a
-- breach, splashes and a droplet trail when it leaves the water, suspended droplets while it hovers.
-- Purely visual: the server's invisible hitbox decides all hits.
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config.StormfinConfig)
local Motion = require(ReplicatedStorage.Shared.StormfinMotion)
local CameraController = require(script.Parent.CameraController)
local EnemyVisuals = require(script.Parent.EnemyVisuals)
local VFXUtil = require(script.Parent.VFXUtil)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Event = Remotes:WaitForChild("StormfinEvent")

local StormfinVisuals = {}

local Visuals = Config.Visuals
local Tex = VFXUtil.Tex
local Fade, Seq = VFXUtil.Fade, VFXUtil.Seq
local UP = Vector3.yAxis
local WHITE = Color3.new(1, 1, 1)
local SPINE_SPACING = Config.BodyLength / 6
local MAX_JOINT_BEND = 0.45 -- radians between neighbouring spine segments: curls like a fish, never folds
local TURN_BLEND = 0.22 -- seconds to swing from the old facing into a new segment's (no snapping)
-- Swimming wave: it travels back along the body WAVE_STEP radians per spine point. Real eels push
-- the wave back a little faster than they swim (slip ~0.8); beating slower than that looks like
-- sliding through the water, so the beat is locked to forward speed: BEAT_PER_STUD radians per stud.
local WAVE_STEP = 0.9
local SLIP = 0.8
local BEAT_PER_STUD = WAVE_STEP / (SLIP * SPINE_SPACING)
local IDLE_BEAT = 3 -- radians/s: the slow scull while hovering or holding still
local COAST_BEAT = 2.5 -- no thrust (airborne, or gliding after a splash): the tail just trails
local THRASH_BEAT = 14 -- floundering on the surface
local BANK_ACCEL = 60 -- studs/s² of sideways (turning) acceleration that banks it 45 degrees
local MAX_BANK = 0.6 -- radians
local CORRECTION_TIME = 0.15 -- seconds to ease out the small jump when a segment arrives late
local MAX_CORRECTION = 8 -- studs; bigger jumps (a resync) snap
local FLINCH_TIME = 0.22 -- hit reaction length
local SHAKE_RANGE = 30 -- studs: a breach this close to you shakes the camera
-- Spine segment sizes, head first: a sleek taper from a broad chest to a thin tail stalk. Each is
-- about twice the spacing long so neighbours overlap into one smooth body (not a string of beads).
local SPINE_SIZES = {
	Vector3.new(1.4, 1.2, 2.9),
	Vector3.new(1.9, 1.5, 2.9),
	Vector3.new(2.0, 1.6, 2.8),
	Vector3.new(1.6, 1.3, 2.7),
	Vector3.new(1.1, 0.95, 2.6),
	Vector3.new(0.65, 0.55, 2.3),
}

type View = {
	Id: number,
	ServerModel: Model?,
	Model: Model,
	Mesh: MeshPart?, -- the rigged model's skinned mesh (nil = part-built fallback body)
	Bones: { Bone }?, -- Spine1 (head) .. Spine6 (tail)
	RestBody: { CFrame }?, -- each bone's rest frame in body space (body centre, -Z forward)
	Spine: { BasePart },
	Markings: { BasePart },
	Points: { Vector3 }, -- rope-follow spine points, head first
	Fins: { Left: BasePart, Right: BasePart, Dorsal: BasePart, TailUpper: BasePart, TailLower: BasePart }?,
	Glow: PointLight,
	Arcs: ParticleEmitter,
	Mouth: Attachment,
	ChargeGlow: ParticleEmitter,
	Droplets: ParticleEmitter, -- leap trail
	Suspended: ParticleEmitter, -- hover
	Surface: Attachment,
	SurfaceGlow: ParticleEmitter,
	Ripples: ParticleEmitter,
	Segment: Motion.Segment?,
	Previous: Motion.Segment?,
	LastY: number?,
	Forward: Vector3?, -- facing drawn last frame
	BlendFrom: Vector3?, -- facing when the current segment began
	BlendStart: number,
	Drawn: Vector3?, -- body centre drawn last frame
	Correction: Vector3, -- offset eased out after a late segment
	CorrectionStart: number,
	Accel: Vector3, -- smoothed acceleration (studs/s²)
	Amplitude: number, -- smoothed undulation size
	Roll: number, -- smoothed roll about the body axis (banking, stun, death)
	Phase: number,
	FlinchUntil: number,
	Dead: boolean,
}

local views: { [number]: View } = {}
local folder: Instance

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function part(name: string, size: Vector3, color: Color3, material: Enum.Material, ellipsoid: boolean): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	if ellipsoid then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
	end
	return p
end

local function fin(name: string, size: Vector3): BasePart
	local p = part(name, size, Visuals.FinColor, Enum.Material.SmoothPlastic, true)
	p.Transparency = 0.35
	return p
end

type Effects = {
	Glow: PointLight,
	Arcs: ParticleEmitter,
	Mouth: Attachment,
	ChargeGlow: ParticleEmitter,
	Droplets: ParticleEmitter,
	Suspended: ParticleEmitter,
	Surface: Attachment,
	SurfaceGlow: ParticleEmitter,
	Ripples: ParticleEmitter,
}

-- Glow, lightning, charge, droplet and water-surface effects, shared by both bodies.
local function addEffects(id: number, chest: BasePart, arcsParent: BasePart, mouthParent: BasePart, mouthPosition: Vector3, dropletsParent: BasePart): Effects
	local glow = Instance.new("PointLight")
	glow.Color = Visuals.MarkingColor
	glow.Range = 12
	glow.Brightness = 1.4
	glow.Shadows = false
	glow.Parent = chest
	local arcs = VFXUtil.Emitter(arcsParent, { -- crackling lightning over the body
		Texture = Tex.Arc,
		Color = ColorSequence.new(Visuals.ArcColor),
		FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2,
		FlipbookMode = Enum.ParticleFlipbookMode.Loop,
		FlipbookFramerate = NumberRange.new(30),
		FlipbookStartRandom = true,
		Size = Fade(1.6, 0.8),
		Transparency = Fade(0.1, 1),
		Lifetime = NumberRange.new(0.06, 0.12),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		LockedToPart = true,
		Rate = 4,
	})
	local mouth = Instance.new("Attachment")
	mouth.Name = "Mouth"
	mouth.Position = mouthPosition
	mouth.Parent = mouthParent
	local chargeGlow = VFXUtil.Emitter(mouth, {
		Texture = Tex.Glow,
		Color = ColorSequence.new(Visuals.BoltColor),
		Size = Fade(1.6, 0.6),
		Transparency = Fade(0.2, 1),
		Lifetime = NumberRange.new(0.15),
		Speed = NumberRange.new(0),
		LockedToPart = true,
	})
	local droplets = VFXUtil.Emitter(dropletsParent, { -- water droplets trailing the leap
		Texture = Tex.Glow,
		Color = ColorSequence.new(Visuals.RippleColor:Lerp(WHITE, 0.5)),
		LightEmission = 0.4,
		Size = Fade(0.28, 0.05),
		Transparency = Fade(0.2, 1),
		Lifetime = NumberRange.new(0.35, 0.6),
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -45, 0),
	})
	local suspended = VFXUtil.Emitter(chest, { -- the lake it carries into the air while hovering
		Texture = Tex.Glow,
		Color = ColorSequence.new(Visuals.RippleColor:Lerp(WHITE, 0.4)),
		LightEmission = 0.4,
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Size = Seq({ { 0, 0 }, { 0.2, 0.22 }, { 1, 0 } }),
		Transparency = Fade(0.3, 1),
		Lifetime = NumberRange.new(1.2, 1.8),
		Speed = NumberRange.new(0.3, 0.8),
		SpreadAngle = Vector2.new(180, 180),
	})

	-- Surface marker: a faint glow patch and slow ripples above it while it hunts underwater.
	local anchor = VFXUtil.Anchor()
	local surface = Instance.new("Attachment")
	surface.Name = "StormfinSurface" .. id
	surface.CFrame = VFXUtil.LookAt(Vector3.zero, UP)
	surface.Parent = anchor
	local surfaceGlow = VFXUtil.Emitter(surface, {
		Texture = Tex.Glow,
		Color = ColorSequence.new(Visuals.RippleColor),
		LightEmission = 0.6,
		Size = NumberSequence.new(7),
		Transparency = Seq({ { 0, 1 }, { 0.5, 0.82 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.6),
		Speed = NumberRange.new(0.01),
		EmissionDirection = Enum.NormalId.Front,
		Orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		Rate = 8,
	})
	local ripples = VFXUtil.Ring(surface, ColorSequence.new(Visuals.RippleColor), 1, 6, 1.1, UP, Seq({ { 0, 0.55 }, { 1, 1 } }))
	ripples.Rate = 1.5
	return {
		Glow = glow,
		Arcs = arcs,
		Mouth = mouth,
		ChargeGlow = chargeGlow,
		Droplets = droplets,
		Suspended = suspended,
		Surface = surface,
		SurfaceGlow = surfaceGlow,
		Ripples = ripples,
	}
end

local function newView(id: number, serverModel: Model?, model: Model, effects: Effects): View
	return {
		Id = id,
		ServerModel = serverModel,
		Model = model,
		Mesh = nil,
		Bones = nil,
		RestBody = nil,
		Spine = {},
		Markings = {},
		Points = {},
		Fins = nil,
		Glow = effects.Glow,
		Arcs = effects.Arcs,
		Mouth = effects.Mouth,
		ChargeGlow = effects.ChargeGlow,
		Droplets = effects.Droplets,
		Suspended = effects.Suspended,
		Surface = effects.Surface,
		SurfaceGlow = effects.SurfaceGlow,
		Ripples = effects.Ripples,
		Segment = nil,
		Previous = nil,
		LastY = nil,
		Forward = nil,
		BlendFrom = nil,
		BlendStart = 0,
		Drawn = nil,
		Correction = Vector3.zero,
		CorrectionStart = 0,
		Accel = Vector3.zero,
		Amplitude = 0,
		Roll = 0,
		Phase = math.random() * 10,
		FlinchUntil = 0,
		Dead = false,
	}
end

-- The user's rigged model: one skinned MeshPart; the bones bend it along the swimming spine.
local function buildMesh(id: number, serverModel: Model?, template: Model): View?
	local model = template:Clone()
	model.Name = "StormfinVisual" .. id
	local mesh = model.PrimaryPart :: MeshPart?
	if not mesh then
		model:Destroy()
		return nil
	end
	mesh.CFrame = CFrame.new() -- body frame at the origin while reading rest poses
	local bones, rest = {}, {}
	for i = 1, #SPINE_SIZES do
		local bone = mesh:FindFirstChild("Spine" .. i, true) :: Bone?
		if not bone then
			warn("StormfinVisuals: rigged model is missing bone Spine" .. i .. "; using the part body")
			model:Destroy()
			return nil
		end
		bones[i] = bone
		rest[i] = bone.WorldCFrame
	end
	local half = mesh.Size.Z * 0.5
	local effects = addEffects(id, mesh, mesh, mesh, Vector3.new(0, 0, -half * 0.9), mesh)
	model.Parent = folder
	local view = newView(id, serverModel, model, effects)
	view.Mesh = mesh
	view.Bones = bones
	view.RestBody = rest
	return view
end

local function build(id: number, serverModel: Model?): View
	local templates = ReplicatedStorage:FindFirstChild("EnemyModels")
	local template = templates and templates:FindFirstChild("Stormfin")
	if template and template:IsA("Model") then
		local view = buildMesh(id, serverModel, template)
		if view then
			return view
		end
	end

	-- Fallback: a part-built body.
	local model = Instance.new("Model")
	model.Name = "StormfinVisual" .. id
	local spine, markings = {}, {}
	for i, size in SPINE_SIZES do
		local segment = part("Spine" .. i, size, Visuals.BodyColor, Enum.Material.SmoothPlastic, true)
		segment.Parent = model
		spine[i] = segment
		-- Glowing electric marking along the back of each segment.
		local marking = part("Marking" .. i, Vector3.new(size.X * 0.32, size.Y * 0.22, size.Z * 0.85), Visuals.MarkingColor, Enum.Material.Neon, true)
		marking.Parent = model
		markings[i] = marking
	end
	for _, side in { -1, 1 } do
		local eye = part(if side < 0 then "EyeL" else "EyeR", Vector3.one * 0.32, Visuals.EyeColor, Enum.Material.Neon, true)
		eye.Parent = model
	end

	local fins = {
		Left = fin("FinL", Vector3.new(3.6, 0.12, 1.9)),
		Right = fin("FinR", Vector3.new(3.6, 0.12, 1.9)),
		Dorsal = fin("Dorsal", Vector3.new(0.12, 1.6, 2.4)),
		TailUpper = fin("TailUpper", Vector3.new(0.14, 2.3, 0.9)),
		TailLower = fin("TailLower", Vector3.new(0.14, 2.3, 0.9)),
	}
	for _, f in fins do
		f.Parent = model
	end
	-- Long flowing fin tips: short trails while it moves.
	for _, f in { fins.Left, fins.Right } do
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(f.Size.X * 0.45, 0, 0.2)
		a0.Parent = f
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(f.Size.X * 0.45, 0, 0.8)
		a1.Parent = f
		local trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = a0, a1
		trail.Lifetime = 0.35
		trail.Color = ColorSequence.new(Visuals.MarkingColor, Visuals.FinColor)
		trail.Transparency = Fade(0.55, 1)
		trail.LightEmission = 0.6
		trail.Parent = f
	end

	local effects = addEffects(id, spine[2], spine[3], spine[1], Vector3.new(0, -0.1, -1.45), spine[5])
	model.Parent = folder
	local view = newView(id, serverModel, model, effects)
	view.Spine = spine
	view.Markings = markings
	view.Fins = fins
	return view
end

local function destroy(view: View)
	view.Model:Destroy()
	view.Surface:Destroy()
	views[view.Id] = nil
end

-- Splash where it breaks the surface (in or out): droplets, a ring and a puff of spray.
local function splash(position: Vector3, big: boolean)
	local at = Vector3.new(position.X, Config.SurfaceY + 0.1, position.Z)
	local a = VFXUtil.At(VFXUtil.LookAt(at, UP), 1.4)
	if not a then
		return
	end
	local scale = if big then 1 else 0.6
	VFXUtil.Emitter(a, {
		Texture = Tex.Glow,
		Color = ColorSequence.new(Visuals.RippleColor:Lerp(WHITE, 0.55)),
		LightEmission = 0.4,
		Size = Fade(0.35, 0.05),
		Transparency = Fade(0.1, 1),
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(12 * scale, 24 * scale),
		SpreadAngle = Vector2.new(35, 35),
		EmissionDirection = Enum.NormalId.Front,
		Acceleration = Vector3.new(0, -55, 0),
	}):Emit(math.round(30 * scale))
	VFXUtil.Ring(a, ColorSequence.new(Visuals.RippleColor:Lerp(WHITE, 0.3)), 1, 9 * scale, 0.5, UP, Seq({ { 0, 0.3 }, { 1, 1 } })):Emit(1)
	VFXUtil.Emitter(a, {
		Texture = Tex.Smoke,
		Color = ColorSequence.new(Color3.fromRGB(200, 215, 240)),
		LightEmission = 0,
		LightInfluence = 1,
		Size = Fade(2 * scale, 4 * scale),
		Transparency = Fade(0.55, 1),
		Lifetime = NumberRange.new(0.4, 0.7),
		Speed = NumberRange.new(3, 7),
		SpreadAngle = Vector2.new(50, 50),
		EmissionDirection = Enum.NormalId.Front,
		Rotation = NumberRange.new(0, 360),
	}):Emit(math.round(6 * scale))
	-- A breach erupting close to you shakes the camera a little.
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if big and root then
		local closeness = 1 - (root.Position - at).Magnitude / SHAKE_RANGE
		if closeness > 0 then
			CameraController.Shake(0.3 * closeness, 0.18)
		end
	end
end

local function setMarkingColor(view: View, color: Color3)
	for _, marking in view.Markings do
		marking.Color = color
	end
	view.Glow.Color = color
end

-- Reacts to a new segment from the server: telegraphs and one-shot effects.
local function onSegment(view: View, segment: Motion.Segment)
	view.Previous = view.Segment
	view.Segment = segment
	view.BlendFrom = view.Forward
	view.BlendStart = os.clock()
	-- The segment reaches us a little after it started; ease out the gap between where we drew the
	-- fish (still on the old segment) and where the new one says it is now.
	if view.Drawn then
		local gap = view.Drawn - Motion.Evaluate(segment, serverNow())
		view.Correction = if gap.Magnitude < MAX_CORRECTION then gap else Vector3.zero
		view.CorrectionStart = os.clock()
	end
	local kind = segment.Kind
	local extra = segment.Extra or {}
	if kind == "Windup" then
		-- Crackling ripples brighten over the launch spot; the cyan glint says "parry this".
		-- The ring closes on the launch: time it from the server's clock, not from when this arrived.
		local untilLaunch = segment.Start + segment.Duration - serverNow()
		if untilLaunch > 0 then
			EnemyVisuals.Telegraph(view.Model, extra.Parryable == true, untilLaunch, view.Surface)
		end
		view.Ripples.Rate = 7
		view.Arcs.Rate = 25
	elseif kind == "Hover" then
		local startsIn = segment.Start + (extra.ChargeStart or 0) - serverNow()
		-- Joined mid-charge: only the rest of it (the ring still closes on the shot); after: nothing.
		local chargeTime = (extra.ChargeTime or 0.8) + math.min(startsIn, 0)
		if chargeTime > 0 then
			task.delay(math.max(startsIn, 0), function()
				if view.Segment ~= segment or view.Dead then
					return
				end
				EnemyVisuals.Telegraph(view.Model, extra.Parryable == true, chargeTime, view.Mouth)
				view.ChargeGlow.Rate = 40
				view.Arcs.Rate = 45
				VFXUtil.Flash(view.Mouth, Visuals.BoltColor, 14, 3, chargeTime)
				-- The shot's lunge is in the motion itself (StormfinMotion, Hover).
				task.delay(chargeTime, function()
					view.ChargeGlow.Rate = 0
					if view.Segment == segment then
						view.Arcs.Rate = 4
					end
				end)
			end)
		end
	elseif kind == "Death" then
		view.Dead = true
	end
	if kind ~= "Windup" then
		EnemyVisuals.ClearTelegraph(view.Model)
		view.Ripples.Rate = 1.5
		if kind ~= "Hover" then
			view.Arcs.Rate = 4
		end
	end
end

local function onDeath(view: View)
	view.Dead = true
	EnemyVisuals.ClearTelegraph(view.Model)
	view.Arcs.Rate = 0
	view.ChargeGlow.Rate = 0
	view.Suspended.Rate = 0
	view.Droplets.Rate = 0
	-- Hangs still, then the markings and glow fade out as it sinks.
	task.delay(Config.DeathFloatTime, function()
		local info = TweenInfo.new(Config.DeathSinkTime * 0.6)
		for _, marking in view.Markings do
			TweenService:Create(marking, info, { Color = Visuals.BodyColor, Transparency = 0.6 }):Play()
		end
		if view.Mesh then
			TweenService:Create(view.Mesh, info, { Transparency = 0.5 }):Play()
		end
		TweenService:Create(view.Glow, info, { Brightness = 0 }):Play()
	end)
end

local function rotationBetween(a: Vector3, b: Vector3): CFrame
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-5 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(a:Dot(b), -1, 1)))
end

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Point and head-ward direction on the drawn spine, `offset` studs ahead of the body centre
-- (extrapolates a little past the head and tail).
local function sampleSpine(drawn: { Vector3 }, offset: number): (Vector3, Vector3)
	local k = (SPINE_SPACING * 2.5 - offset) / SPINE_SPACING + 1
	local i = math.clamp(math.floor(k), 1, #drawn - 1)
	local a, b = drawn[i], drawn[i + 1]
	local along = a - b
	return a:Lerp(b, k - i), if along.Magnitude > 1e-4 then along.Unit else -Vector3.zAxis
end

-- Bends the rigged mesh along the drawn spine: each bone keeps its rest offset from the body
-- centreline but follows the curve's position and direction at its point along the body. The mesh
-- itself sits on the spine's own middle (not the hitbox facing), so bone transforms only carry the
-- curvature and the part's bounds stay on the drawn body (correct culling).
local function poseMesh(view: View, drawn: { Vector3 }, roll: CFrame)
	local mesh = view.Mesh :: MeshPart
	local bones = view.Bones :: { Bone }
	local restBody = view.RestBody :: { CFrame }
	local centre = sampleSpine(drawn, 0)
	local span = drawn[1] - drawn[#drawn]
	local forward = if span.Magnitude > 1e-3 then span.Unit else -Vector3.zAxis
	local body = Motion.CFrame(centre, forward) * roll
	mesh.CFrame = body
	for i, bone in bones do
		local rest = restBody[i]
		local point, direction = sampleSpine(drawn, -rest.Position.Z)
		local turn = rotationBetween(forward, direction)
		local lateral = body:VectorToWorldSpace(Vector3.new(rest.Position.X, rest.Position.Y, 0))
		local restWorld = body * rest
		local desired = CFrame.new(point + turn:VectorToWorldSpace(lateral)) * turn * restWorld.Rotation
		bone.Transform = restWorld:Inverse() * desired
	end
	local mouthPoint, mouthDirection = sampleSpine(drawn, mesh.Size.Z * 0.45)
	view.Mouth.WorldCFrame = Motion.CFrame(mouthPoint, mouthDirection)
end

local function update(dt: number)
	local t = serverNow()
	local clock = os.clock()
	for _, view in views do
		local segment = view.Segment
		if not segment then
			continue
		end
		local centre, forward, progress = Motion.Evaluate(segment, t)
		local fade = (clock - view.CorrectionStart) / CORRECTION_TIME
		if fade < 1 then
			centre += view.Correction * (1 - smooth(fade))
		end
		view.Drawn = centre
		-- Each segment starts with its own facing; swing into it from the old one instead of snapping.
		local blend = (clock - view.BlendStart) / TURN_BLEND
		if view.BlendFrom and blend < 1 then
			forward = Motion.TurnToward(view.BlendFrom, forward, smooth(blend))
		end
		view.Forward = forward
		local kind = segment.Kind
		-- What it is actually doing, from the motion itself (not frame-to-frame differences).
		local velocity = Motion.Velocity(segment, t)
		local accel = (velocity - Motion.Velocity(segment, t - 1 / 30)) * 30
		view.Accel += (accel - view.Accel) * math.min(dt * 10, 1)
		local speed = velocity.Magnitude
		local moving = speed > 4
		local hovering = kind == "Hover" or kind == "Rise" or kind == "Stun"
		local powered = kind == "Swim" or kind == "Windup" or kind == "Rise" or kind == "Hover"
		local submerged = centre.Y < Config.SubmergedBelow

		-- Splash when it crosses the surface either way (a dead one falling in too).
		if view.LastY then
			local surface = Config.SurfaceY
			if (view.LastY < surface) ~= (centre.Y < surface) then
				splash(centre, kind == "Leap" or kind == "Rise")
			end
		end
		view.LastY = centre.Y

		-- Spine: rope-follow from the head, relaxing straight back when it's nearly still.
		local head = centre + forward * (SPINE_SPACING * 2.5)
		local points = view.Points
		if #points == 0 then
			for i = 1, #SPINE_SIZES do
				points[i] = head - forward * SPINE_SPACING * (i - 1)
			end
		end
		points[1] = head
		local relax = math.min(dt * (if moving then 1.5 else 6), 1)
		local previousDir = forward
		for i = 2, #points do
			local toPrevious = points[i - 1] - points[i]
			local dir = if toPrevious.Magnitude > 1e-3 then toPrevious.Unit else previousDir
			-- Sharp turns (a dive into a reversal) would fold the body back on itself; limit each joint.
			if dir:Dot(previousDir) < math.cos(MAX_JOINT_BEND) then
				local axis = previousDir:Cross(dir)
				axis = if axis.Magnitude > 1e-4 then axis.Unit else UP
				dir = CFrame.fromAxisAngle(axis, MAX_JOINT_BEND):VectorToWorldSpace(previousDir)
			end
			local follow = points[i - 1] - dir * SPINE_SPACING
			local straight = points[i - 1] - forward * SPINE_SPACING
			points[i] = follow:Lerp(straight, relax)
			local settled = points[i - 1] - points[i]
			previousDir = if settled.Magnitude > 1e-3 then settled.Unit else previousDir
		end

		-- Undulation: a wave travelling back along the body, strongest at the tail.
		-- Powered (swimming, rising, hovering): the beat is locked to forward speed, and it strokes
		-- harder while accelerating. Floundering: a fast thrash. Otherwise (airborne, or gliding after
		-- a splash) there's no thrust: a slow, small trailing sway.
		local side = forward:Cross(UP)
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
		local forwardSpeed = math.max(velocity:Dot(forward), 0)
		local thrust = math.clamp(view.Accel:Dot(forward) / 40, 0, 1)
		local beat, amplitude
		if view.Dead then
			beat, amplitude = 0, 0
		elseif kind == "Stun" then
			beat, amplitude = THRASH_BEAT, 0.5
		elseif powered then
			beat = math.max(IDLE_BEAT, forwardSpeed * BEAT_PER_STUD) * (1 + 0.4 * thrust)
			amplitude = 0.16 + 0.3 * math.clamp(forwardSpeed / Config.Swim.Speed, 0, 1.3) + 0.2 * thrust
		else
			beat, amplitude = COAST_BEAT, 0.12
		end
		view.Amplitude += (amplitude - view.Amplitude) * math.min(dt * 8, 1)
		view.Phase += dt * beat
		local charging = view.ChargeGlow.Rate > 0
		-- Tension: the whole body trembles as a breach winds up and while a bolt charges.
		local tremble = if view.Dead then 0 elseif kind == "Windup" then smooth(progress / 0.8) elseif charging then 1 else 0
		-- Hit flinch: a quick jolt up that peaks early and eases back out.
		local flinch = 0
		if clock < view.FlinchUntil then
			flinch = math.sin(math.pi * math.sqrt(1 - (view.FlinchUntil - clock) / FLINCH_TIME))
		end
		local drawn = {}
		for i, point in points do
			local along = (i - 1) / (#points - 1)
			local wave = math.sin(view.Phase - i * WAVE_STEP) * view.Amplitude * along ^ 1.3
			local shiver = math.sin(clock * 55 + i * 1.7) * 0.09 * tremble * (0.4 + 0.6 * along)
			drawn[i] = point + side * (wave + shiver) + UP * flinch * 0.5 * (1 - i / #points)
		end
		-- Roll about the body axis: banks into turns while it swims or flies under its own power,
		-- rocks onto its sides while floundering, belly-up when it dies.
		local targetRoll = 0
		if powered and moving then
			-- Turning right (accelerating toward its right) dips the right side.
			targetRoll = -math.clamp(math.atan(view.Accel:Dot(side) / BANK_ACCEL), -MAX_BANK, MAX_BANK)
		elseif kind == "Stun" then
			targetRoll = 0.55 * math.sin((t - segment.Start) * 5)
		elseif kind == "Death" then
			targetRoll = math.pi * smooth((t - segment.Start - Config.DeathFloatTime * 0.5) / 1.1)
		end
		view.Roll += (targetRoll - view.Roll) * math.min(dt * 12, 1)
		local roll = CFrame.Angles(0, 0, view.Roll)
		if view.Mesh then
			poseMesh(view, drawn, roll)
		else
			for i, segmentPart in view.Spine do
				local ahead = if i == 1 then drawn[1] + forward else drawn[i - 1]
				local cframe = Motion.CFrame(drawn[i], (ahead - drawn[i]).Unit) * roll
				segmentPart.CFrame = cframe
				view.Markings[i].CFrame = cframe * CFrame.new(0, segmentPart.Size.Y * 0.38, 0)
			end
			local headCFrame = view.Spine[1].CFrame
			local eyeL = view.Model:FindFirstChild("EyeL") :: BasePart
			local eyeR = view.Model:FindFirstChild("EyeR") :: BasePart
			eyeL.CFrame = headCFrame * CFrame.new(-0.55, 0.2, -0.7)
			eyeR.CFrame = headCFrame * CFrame.new(0.55, 0.2, -0.7)

			-- Fins: steady strokes swimming, slow wide undulation hovering (contracted while charging).
			local fins = view.Fins :: any
			local chest = view.Spine[2].CFrame
			local flapSpeed = if hovering then Visuals.FinFlapSpeed * 0.35 else Visuals.FinFlapSpeed
			local spread = if charging then -0.1 elseif hovering then 0.45 elseif kind == "Leap" then 0.55 else 0.15
			local flap = math.sin(clock * flapSpeed + view.Id) * (if hovering then 0.35 else 0.45)
			for _, s in { -1, 1 } do
				local f = if s < 0 then fins.Left else fins.Right
				local roll = s * (spread + flap)
				f.CFrame = chest * CFrame.new(s * 0.9, -0.1, 0.2) * CFrame.Angles(0, -s * 0.55, roll) * CFrame.new(s * f.Size.X * 0.5, 0, 0)
			end
			local back = view.Spine[3].CFrame
			fins.Dorsal.CFrame = back * CFrame.new(0, 1.2, 0.3) * CFrame.Angles(-0.5, 0, 0)
			local tail = view.Spine[#view.Spine].CFrame
			local tailSwing = math.sin(view.Phase - #points * 0.9) * 0.3 * speedFactor
			fins.TailUpper.CFrame = tail * CFrame.new(0, 0, 0.6) * CFrame.Angles(-0.75, tailSwing, 0) * CFrame.new(0, 1.0, 0.2)
			fins.TailLower.CFrame = tail * CFrame.new(0, 0, 0.6) * CFrame.Angles(0.75, tailSwing, 0) * CFrame.new(0, -1.0, 0.2)
		end

		-- Charging: the markings pulse toward white-hot.
		if not view.Dead then
			local pulse = if charging then 0.5 + 0.5 * math.sin(clock * 18) else 0
			setMarkingColor(view, Visuals.MarkingColor:Lerp(WHITE, pulse * 0.7 + flinch * 0.6))
			view.Glow.Brightness = 1.4 + pulse * 2 + flinch * 2.5
		end

		-- Water effects.
		view.Surface.WorldPosition = Vector3.new(centre.X, Config.SurfaceY + 0.06, centre.Z)
		local showSurface = (submerged or kind == "Windup") and not view.Dead
		view.SurfaceGlow.Enabled = showSurface
		view.Ripples.Enabled = showSurface
		view.Droplets.Rate = if (kind == "Leap" or kind == "Stagger" or kind == "Dive") and not submerged and not view.Dead then 45 else 0
		view.Suspended.Rate = if kind == "Hover" and not view.Dead then 10 else 0
	end
end

local function onEvent(kind: string, id: number, a: any)
	local view = views[id]
	if kind == "Spawn" then
		if not view then
			views[id] = build(id, a)
		end
	elseif kind == "Segment" then
		if not view then
			view = build(id, nil)
			views[id] = view
		end
		onSegment(view, a)
	elseif kind == "Hit" then
		if view then
			view.FlinchUntil = os.clock() + FLINCH_TIME
		end
	elseif kind == "Death" then
		if view then
			onDeath(view)
		end
	elseif kind == "Despawn" then
		if view then
			-- A last small ripple where it went down.
			local at = view.Surface.WorldPosition
			local a2 = VFXUtil.At(VFXUtil.LookAt(at, UP), 1.5)
			if a2 then
				VFXUtil.Ring(a2, ColorSequence.new(Visuals.RippleColor), 1, 5, 1.2, UP, Seq({ { 0, 0.5 }, { 1, 1 } })):Emit(1)
			end
			destroy(view)
		end
	end
end

function StormfinVisuals.Init()
	folder = VFXUtil.Folder() or workspace
	Event.OnClientEvent:Connect(onEvent)
	RunService.RenderStepped:Connect(update)
	Event:FireServer("Sync")
end

return StormfinVisuals
