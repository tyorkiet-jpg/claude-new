-- Client-side attack visuals for enemies (the target dummies' punch and energy blast), driven by
-- the server's EnemyAttack events (windup pose + telegraph glint, attack, recovery, hit reaction)
-- and EnemyProjectile events (the server-simulated blasts, drawn here).
-- Parryable attacks use the V2 cue language: a cyan glint (unparryable would be red/orange).
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DummyConfig = require(ReplicatedStorage.Shared.Config.DummyConfig)
local StormfinConfig = require(ReplicatedStorage.Shared.Config.StormfinConfig)
local WeaponConfig = require(ReplicatedStorage.Shared.Config.WeaponConfig)
local ParryConfig = require(ReplicatedStorage.Shared.Config.ParryConfig)
local CameraController = require(script.Parent.CameraController)
local SFX = require(script.Parent.SFX)
local VFXUtil = require(script.Parent.VFXUtil)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local EnemyVisuals = {}

local PARRYABLE_COLOR = Color3.fromRGB(80, 220, 255)
local UNPARRYABLE_COLOR = Color3.fromRGB(255, 110, 40)
local PUNCH_SNAP = 0.07 -- seconds for the fist to shoot out
local TELEGRAPH_SIZE = 3.2 -- studs; the glint billboard
local TELEGRAPH_RING_START = 3 -- the timing ring starts this many times the glint size and closes on the hit

local Tex = VFXUtil.Tex
local Fade, Seq = VFXUtil.Fade, VFXUtil.Seq
local WHITE = Color3.new(1, 1, 1)

type Attack = {
	Phase: string, -- "Windup" | "Strike" | "Parried"
	Kind: string, -- "Punch" | "Blast"
	Start: number,
	Duration: number,
	Recovery: number,
	Charge: BasePart?, -- blast charge orb between the hands during the windup
	Intake: BasePart?, -- invisible sphere around the orb that energy is drawn in from
}

type Projectile = {
	Part: BasePart,
	Color: Color3,
	Origin: Vector3,
	Direction: Vector3,
	Speed: number,
	Range: number,
	Start: number,
	Style: string?,
	Edge: Color3?, -- Storm Bolt: deep outer colour
	Tail: Attachment?, -- Storm Bolt wake end, trailing behind the head
	Decor: Decor?, -- Storm Bolt droplets and streams, moved every frame
}

local projectiles: { [number]: Projectile } = {}

local attacks: { [Model]: Attack } = {}
local localPlayer = Players.LocalPlayer

local function easeOut(x: number): number
	x = math.clamp(x, 0, 1)
	return 1 - (1 - x) ^ 3
end

local function joints(model: Model): (Motor6D?, Motor6D?, Motor6D?)
	local root = model:FindFirstChild("HumanoidRootPart")
	local torso = model:FindFirstChild("Torso")
	return root and root:FindFirstChild("RootJoint") :: Motor6D?,
		torso and torso:FindFirstChild("Right Shoulder") :: Motor6D?,
		torso and torso:FindFirstChild("Left Shoulder") :: Motor6D?
end

local function fistAttachment(model: Model): Attachment?
	local arm = model:FindFirstChild("Right Arm")
	if not arm then
		return nil
	end
	local attachment = arm:FindFirstChild("FistFX") :: Attachment?
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "FistFX"
		attachment.Position = Vector3.new(0, -1.1, 0)
		attachment.Parent = arm
	end
	return attachment
end

-- Live telegraphs per attacker, so a cancelled attack can take its warning down.
local telegraphs: { [Model]: { Instance } } = {}

local telegraph: (Model, boolean, number, Instance) -> ()

local function clearTelegraph(model: Model)
	local parts = telegraphs[model]
	telegraphs[model] = nil
	if parts then
		for _, instance in parts do
			instance:Destroy()
		end
	end
end

-- Windup warning (V2 cue language). Drawn as an always-on-top billboard so muzzle flashes, impacts
-- and other players' effects can never hide it. Parryable: a cyan star glint plus a ring that
-- closes exactly when the attack commits (the timing cue), a ping on commit and a cyan outline on
-- the attacker. Unparryable (bosses later): a red/orange ring and glow with no star - a different
-- shape, not just a different colour.
-- Shared with other enemy visuals (StormfinVisuals) so every enemy uses the same cue language.
function EnemyVisuals.Telegraph(model: Model, parryable: boolean, duration: number, adornee: Instance)
	telegraph(model, parryable, duration, adornee)
end

function EnemyVisuals.ClearTelegraph(model: Model)
	clearTelegraph(model)
end

function telegraph(model: Model, parryable: boolean, duration: number, adornee: Instance)
	clearTelegraph(model)
	local color = if parryable then PARRYABLE_COLOR else UNPARRYABLE_COLOR

	local gui = Instance.new("BillboardGui")
	gui.Name = "Telegraph"
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 250
	gui.Size = UDim2.fromScale(TELEGRAPH_SIZE * TELEGRAPH_RING_START, TELEGRAPH_SIZE * TELEGRAPH_RING_START)
	gui.ClipsDescendants = false

	local function image(texture: string, scale: number, transparency: number): ImageLabel
		local label = Instance.new("ImageLabel")
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(scale, scale)
		label.BackgroundTransparency = 1
		label.Image = texture
		label.ImageColor3 = color
		label.ImageTransparency = transparency
		label.Parent = gui
		return label
	end
	local unit = 1 / TELEGRAPH_RING_START -- one glint size, as a fraction of the billboard
	local ring = image(Tex.Ring, 1, 0.6)
	local glow = image(Tex.Glow, unit * 0.6, 0.3)
	local glint = if parryable then image(Tex.Flare, unit * 0.3, 0) else nil

	local windup = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(ring, windup, { Size = UDim2.fromScale(unit * 0.55, unit * 0.55), ImageTransparency = 0 }):Play()
	TweenService:Create(glow, windup, { Size = UDim2.fromScale(unit, unit), ImageTransparency = 0 }):Play()
	if glint then
		glint.Rotation = -45
		TweenService:Create(glint, windup, { Size = UDim2.fromScale(unit, unit), Rotation = 0 }):Play()
	end
	gui.Parent = adornee

	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 0.6
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	TweenService:Create(highlight, windup, { FillTransparency = 0.8, OutlineTransparency = 0 }):Play()

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Brightness = 0
	light.Shadows = false
	light.Parent = adornee
	TweenService:Create(light, windup, { Brightness = 4 }):Play()

	local parts = { gui, highlight, light }
	telegraphs[model] = parts
	if parryable then
		SFX.Play("TelegraphParryable", if adornee:IsA("Attachment") then adornee else adornee :: BasePart)
	end

	-- Commit: the ring has closed; the glint pings and everything clears.
	task.delay(duration, function()
		if telegraphs[model] ~= parts then
			return
		end
		local ping = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		ring.ImageTransparency = 1
		if glint then
			glint.ImageColor3 = WHITE:Lerp(color, 0.3)
			TweenService:Create(glint, ping, { Size = UDim2.fromScale(unit * 1.8, unit * 1.8), ImageTransparency = 1 }):Play()
		end
		TweenService:Create(glow, ping, { Size = UDim2.fromScale(unit * 1.4, unit * 1.4), ImageTransparency = 1 }):Play()
		TweenService:Create(highlight, ping, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		light.Enabled = false
		task.delay(0.2, function()
			if telegraphs[model] == parts then
				clearTelegraph(model)
			end
		end)
	end)
end

local function impact(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	VFXUtil.Emitter(attachment, {
		Texture = Tex.Streak,
		Color = ColorSequence.new(WHITE),
		Size = Fade(0.35, 0),
		Lifetime = NumberRange.new(0.15, 0.3),
		Speed = NumberRange.new(15, 30),
		SpreadAngle = Vector2.new(180, 180),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Drag = 5,
	}):Emit(16)
	VFXUtil.Emitter(attachment, {
		Texture = Tex.Flare,
		Color = ColorSequence.new(WHITE),
		Size = Fade(3, 0.5),
		Transparency = Fade(0.2, 1),
		Lifetime = NumberRange.new(0.08),
		Speed = NumberRange.new(0),
		LockedToPart = true,
	}):Emit(1)
	Debris:AddItem(attachment, 0.5)
end

function EnemyVisuals.IsAttacking(model: Model): boolean
	return attacks[model] ~= nil
end

local function fxFolder(): Instance?
	return workspace:FindFirstChild("ClientFX")
end

local function invisiblePart(shape: Enum.PartType, size: number): BasePart
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.one * size
	return part
end

-- Energy orb: a white-hot neon core inside a coloured glow halo with crackling arcs.
local function makeOrb(color: Color3, size: number): BasePart
	local orb = invisiblePart(Enum.PartType.Ball, size)
	orb.Material = Enum.Material.Neon
	orb.Color = WHITE:Lerp(color, 0.65) -- hot, but still clearly the cue colour
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = 3
	light.Shadows = false
	light.Parent = orb
	local center = Instance.new("Attachment")
	center.Name = "Center"
	center.Parent = orb
	VFXUtil.Emitter(center, {
		Name = "Halo",
		Texture = Tex.Glow,
		Color = ColorSequence.new(color),
		LightEmission = 0.5,
		Size = NumberSequence.new(size * 2.6),
		Transparency = Seq({ { 0, 0.4 }, { 0.5, 0.25 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.15),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		Rate = 30,
	})
	VFXUtil.Emitter(center, {
		Name = "Arcs",
		Texture = Tex.Arc,
		Color = VFXUtil.Hot(WHITE, color),
		FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2,
		FlipbookMode = Enum.ParticleFlipbookMode.Loop,
		FlipbookFramerate = NumberRange.new(30),
		FlipbookStartRandom = true,
		Size = Fade(size * 1.8, size),
		Transparency = Fade(0, 1),
		Lifetime = NumberRange.new(0.06, 0.12),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		LockedToPart = true,
		Rate = 18,
	})
	return orb
end

-- Invisible sphere around a charging orb; particles spawn on its surface and rush inward.
local function makeIntake(color: Color3): BasePart
	local intake = invisiblePart(Enum.PartType.Ball, 7)
	intake.Transparency = 1
	VFXUtil.Emitter(intake, {
		Texture = Tex.Streak,
		Color = VFXUtil.Hot(color, WHITE),
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		Size = Fade(0.25, 0.5),
		Transparency = Seq({ { 0, 1 }, { 0.3, 0.2 }, { 1, 0 } }),
		Lifetime = NumberRange.new(0.3),
		Speed = NumberRange.new(10),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Rate = 45,
	})
	return intake
end

-- Storm Bolt (Stormfin): a charged ball of storm-water, staged like the user's reference (growing,
-- firing, exploding) but made of water droplets.
-- GROWING (EnemyVisuals.ChargeStormBolt, at the fin's mouth while it charges): droplets spiral in
-- from all round and are swallowed by a swelling water orb, two streams whirl round it and mist is
-- drawn in. FIRING (makeStormBolt): one big glowing teardrop inside a see-through bubble, droplets
-- circling it, streams twisting round its wake, a comet glow and spray falling away behind.
-- EXPLODING (stormBurst): a flash, splash rings, mist and droplets bursting out, stretching as they
-- fly and falling. A parried bolt comes back as the same thing in the player's attack colour
-- ("ReflectedStormBolt").
-- The droplets are real parts (a glowing ball with a stretched ellipsoid tail, see newDroplet) so
-- they keep their teardrop shape and point the way they move; the streams are Trails on
-- attachments that orbit every frame.
local BOLT_EDGE = Color3.fromRGB(70, 140, 255) -- deep blue edge of the Stormfin's own bolt
local BOLT_LENGTH = 9 -- studs of comet glow behind the head
local BOLT_SCALE = 0.55 -- overall size of the effect relative to the hit radius (user: it was too large)
local DROPLET_ALPHA = { 0.15, 0.4 } -- ball, tail: glowing water, the tail thinner
local SHELL_ALPHA = { 0.72, 0.82 } -- the see-through bubble round the bolt's core
local CHARGE_AHEAD = 0.7 -- studs in front of the mouth the charge grows
local CHARGE_DROPLETS = 8
local CHARGE_CYCLE = 0.55 -- seconds a droplet takes to spiral in and be swallowed
local BOLT_DROPLETS = 6
local SPLASH_DRAG = 3.5 -- 1/s: air drag on the splash droplets...
local SPLASH_GRAVITY = 60 -- ...and how hard they fall (studs/s²)

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- CFrame at `position` looking along `direction` (straight up or down included).
local function aim(position: Vector3, direction: Vector3): CFrame
	if direction.Magnitude < 1e-4 then
		return CFrame.new(position)
	end
	local up = if math.abs(direction.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, position + direction, up)
end

local function randomUnit(): Vector3
	local v = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
	return if v.Magnitude > 1e-3 then v.Unit else Vector3.yAxis
end

local function destroyAll(parts: { Instance })
	for _, part in parts do
		part:Destroy()
	end
end

-- One water droplet: a glowing ball with a stretched ellipsoid tail behind it, together a teardrop
-- that points along its frame's LookVector (the way it moves).
local function newDroplet(body: Color3, tail: Color3, parent: Instance): { BasePart }
	local parts = {}
	for i = 1, 2 do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Transparency = 1 -- shown once placed (fadeDroplet)
		if i == 1 then
			part.Shape = Enum.PartType.Ball
			part.Color = body
		else
			part.Color = tail
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere -- an ellipsoid filling the part's size
			mesh.Parent = part
		end
		part.Size = Vector3.one * 0.1
		part.Parent = parent
		parts[i] = part
	end
	return parts
end

-- Shows (0) to hides (1) a droplet; `alpha` is its fully-shown transparency (ball, tail).
local function fadeDroplet(parts: { BasePart }, fade: number, alpha: { number }?)
	local base = alpha or DROPLET_ALPHA
	for i, part in parts do
		part.Transparency = base[i] + (1 - base[i]) * fade
	end
end

-- Puts a droplet's ball (diameter `size`) at frame.Position with its tail streaming back from the
-- LookVector; `stretch` 0 is a round drop, 1 a teardrop three times as long as it is wide. Pass
-- `resize` only when the size or stretch changed (resizing costs more than moving).
local function placeDroplet(parts: { BasePart }, frame: CFrame, size: number, stretch: number, resize: boolean)
	size = math.max(size, 0.02)
	local length = size * (1 + 2 * stretch)
	if resize then
		parts[1].Size = Vector3.one * size
		parts[2].Size = Vector3.new(size * 0.82, size * 0.82, length)
	end
	parts[1].CFrame = frame
	parts[2].CFrame = frame * CFrame.new(0, 0, length * 0.5 - size * 0.32)
end

type Ribbon = { A0: Attachment, A1: Attachment, Offset: number }

-- A stream of water light: a Trail between two attachments that the caller moves every frame
-- (their separation is its width). FaceCamera off keeps a twisting band's real 3D twist.
local function newRibbon(parent: Instance, colors: ColorSequence, lifetime: number, faceCamera: boolean, offset: number): Ribbon
	local a0 = Instance.new("Attachment")
	a0.Parent = parent
	local a1 = Instance.new("Attachment")
	a1.Parent = parent
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = faceCamera
	trail.Lifetime = lifetime
	trail.MinLength = 0
	trail.Color = colors
	trail.Transparency = Seq({ { 0, 0.05 }, { 0.5, 0.4 }, { 1, 1 } })
	trail.WidthScale = Seq({ { 0, 1 }, { 1, 0.3 } })
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Parent = parent
	return { A0 = a0, A1 = a1, Offset = offset }
end

-- Body and tail colours of the bolt's water.
local function waterColors(color: Color3, edge: Color3): (Color3, Color3)
	return WHITE:Lerp(color, 0.55), color:Lerp(edge, 0.45)
end

-------------------------------------------------------------------------------- growing (charge)

type Inflow = { Parts: { BasePart }, Angle: number, Plane: CFrame, Phase: number, Appear: number }

type Charge = {
	Mouth: Attachment,
	Start: number,
	Duration: number,
	Unit: number,
	Holder: BasePart, -- invisible ball at the charge: the mist's sphere; owns everything else
	Orb: { BasePart },
	Shell: { BasePart },
	Light: PointLight,
	Halo: ParticleEmitter,
	Intake: ParticleEmitter,
	Droplets: { Inflow },
	Ribbons: { Ribbon },
}

local charges: { Charge } = {}

local function endCharge(charge: Charge)
	local index = table.find(charges, charge)
	if index then
		table.remove(charges, index)
	end
	charge.Holder:Destroy()
end

-- Poses a charge for this frame; false once it has run its course (or the fin is gone).
local function updateCharge(charge: Charge, now: number): boolean
	local elapsed = now - charge.Start
	if elapsed >= charge.Duration or not charge.Mouth.Parent then
		return false
	end
	local unit = charge.Unit
	local progress = elapsed / charge.Duration
	local grow = easeOut(progress)
	local frame = charge.Mouth.WorldCFrame * CFrame.new(0, 0, -CHARGE_AHEAD)
	local spun = frame * CFrame.Angles(0, 0, elapsed * 1.6) -- the whole thing turns slowly
	local size = unit * (0.5 + 1.9 * grow)
	charge.Holder.CFrame = frame
	placeDroplet(charge.Orb, frame, size, 0, true)
	placeDroplet(charge.Shell, frame, size * 1.35, 0, true)
	fadeDroplet(charge.Orb, 0)
	fadeDroplet(charge.Shell, 0, SHELL_ALPHA)
	charge.Light.Brightness = 1 + 4 * grow
	charge.Halo.Size = NumberSequence.new(size * 2.6)
	charge.Intake.Rate = 15 + 55 * progress

	-- Droplets spiral in from all round, faster as they near the orb, and are swallowed.
	local outer = unit * (5 - 1.5 * grow)
	local inner = size * 0.45
	for _, droplet in charge.Droplets do
		if progress < droplet.Appear then
			fadeDroplet(droplet.Parts, 1)
			continue
		end
		local function at(s: number): Vector3
			local radius = outer + (inner - outer) * s * s
			local angle = droplet.Angle + s * 2.6
			return frame.Position + (spun * droplet.Plane):VectorToWorldSpace(Vector3.new(math.cos(angle), math.sin(angle), 0)) * radius
		end
		local s = (elapsed / CHARGE_CYCLE + droplet.Phase) % 1
		local position = at(s)
		local scale = smooth(s / 0.15) * (1 - smooth((s - 0.75) / 0.25)) -- grows in, shrinks as it is swallowed
		placeDroplet(droplet.Parts, aim(position, at(math.min(s + 0.02, 1)) - position), unit * 0.55 * scale, 0.3 + 1.2 * s, true)
		fadeDroplet(droplet.Parts, 0)
	end

	-- Two streams whirl round it on tilted circles that tighten as it grows.
	local radius = unit * (3.2 - 1.2 * grow)
	local band = unit * (0.25 + 0.3 * grow)
	for i, ribbon in charge.Ribbons do
		local plane = spun * CFrame.Angles(if i == 1 then 0.9 else -0.9, 0.5, 0)
		local angle = elapsed * 13 + ribbon.Offset
		local out = plane:VectorToWorldSpace(Vector3.new(math.cos(angle), math.sin(angle), 0))
		ribbon.A0.WorldPosition = frame.Position + out * radius
		ribbon.A1.WorldPosition = frame.Position + out * (radius + band)
	end
	return true
end

-- GROWING: the Storm Bolt swells at `mouth` (an Attachment whose LookVector is the fin's facing)
-- for `duration` seconds and is gone when the bolt fires. Returns a function that cancels it.
function EnemyVisuals.ChargeStormBolt(mouth: Attachment, duration: number): () -> ()
	local folder = fxFolder()
	if not folder or duration <= 0 then
		return function() end
	end
	local color = StormfinConfig.Visuals.BoltColor
	local body, tail = waterColors(color, BOLT_EDGE)
	local unit = StormfinConfig.Bolt.Radius * BOLT_SCALE

	local holder = invisiblePart(Enum.PartType.Ball, unit * 7)
	holder.Transparency = 1
	holder.CFrame = mouth.WorldCFrame
	local centre = Instance.new("Attachment")
	centre.Parent = holder
	local halo = VFXUtil.Emitter(centre, {
		Texture = Tex.Glow,
		Color = ColorSequence.new(color),
		LightEmission = 0.6,
		Size = NumberSequence.new(unit),
		Transparency = Seq({ { 0, 0.5 }, { 0.5, 0.3 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.15),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		Rate = 30,
	})
	local intake = VFXUtil.Emitter(holder, { -- fine mist drawn in from all round
		Texture = Tex.Glow,
		Color = VFXUtil.Hot(color, WHITE),
		LightEmission = 1,
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		Size = Seq({ { 0, 0 }, { 0.3, unit * 0.3 }, { 1, unit * 0.1 } }),
		Transparency = Seq({ { 0, 1 }, { 0.3, 0.2 }, { 1, 0 } }),
		Lifetime = NumberRange.new(0.25, 0.35),
		Speed = NumberRange.new(unit * 9),
		Rate = 15,
	})

	local orb = newDroplet(body, body, holder)
	local shell = newDroplet(color, color, holder)
	local glow = Instance.new("PointLight")
	glow.Color = color
	glow.Range = 12
	glow.Brightness = 1
	glow.Shadows = false
	glow.Parent = orb[1]

	local droplets: { Inflow } = {}
	for i = 1, CHARGE_DROPLETS do
		table.insert(droplets, {
			Parts = newDroplet(body, tail, holder),
			Angle = i * 2.39996, -- golden angle: spreads them evenly round
			Plane = CFrame.Angles(math.rad(-50 + 100 * ((i * 0.618) % 1)), math.rad(-40 + 80 * ((i * 0.382) % 1)), 0),
			Phase = i / CHARGE_DROPLETS,
			Appear = 0.05 + 0.4 * (i - 1) / (CHARGE_DROPLETS - 1),
		})
	end
	local ribbons = {
		newRibbon(holder, ColorSequence.new(WHITE, color), 0.16, true, 0),
		newRibbon(holder, ColorSequence.new(WHITE, color), 0.16, true, math.pi),
	}

	holder.Parent = folder
	local charge: Charge = {
		Mouth = mouth,
		Start = os.clock(),
		Duration = duration,
		Unit = unit,
		Holder = holder,
		Orb = orb,
		Shell = shell,
		Light = glow,
		Halo = halo,
		Intake = intake,
		Droplets = droplets,
		Ribbons = ribbons,
	}
	table.insert(charges, charge)
	updateCharge(charge, charge.Start)
	return function()
		endCharge(charge)
	end
end

-------------------------------------------------------------------------------- firing (projectile)

type Orbiter = { Parts: { BasePart }, Offset: number, Size: number, Behind: number }

type Decor = {
	Unit: number,
	Body: { BasePart },
	Shell: { BasePart },
	Orbiters: { Orbiter },
	Helix: { Ribbon },
	Tail: Ribbon,
	Phase: number,
}

local function makeStormBolt(color: Color3, edge: Color3, radius: number): (BasePart, Attachment, Decor)
	local unit = radius * BOLT_SCALE -- every size below is relative to this
	local bolt = invisiblePart(Enum.PartType.Block, unit * 3)
	bolt.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 3
	light.Shadows = false
	light.Parent = bolt
	local tip = Instance.new("Attachment")
	tip.Name = "Center"
	tip.Parent = bolt
	local body, tail = waterColors(color, edge)

	VFXUtil.Emitter(tip, { -- bright heart of the drop
		Texture = Tex.Glow,
		Color = ColorSequence.new(WHITE, WHITE:Lerp(color, 0.5)),
		Size = NumberSequence.new(unit * 1.8),
		Transparency = Seq({ { 0, 0 }, { 1, 0.5 } }),
		Lifetime = NumberRange.new(0.08),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		ZOffset = 1,
		Rate = 40,
	})
	VFXUtil.Emitter(tip, { -- coloured glow round it
		Texture = Tex.Glow,
		Color = ColorSequence.new(color, edge),
		LightEmission = 0.6,
		Size = NumberSequence.new(unit * 5.5),
		Transparency = Seq({ { 0, 0.55 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.12),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		Rate = 30,
	})

	-- Comet glow: Beams from the head to a tail attachment that trails BOLT_LENGTH behind (moved
	-- each frame, see Init), widening back. The texture scrolls toward the tail so it streams.
	local tailEnd = Instance.new("Attachment")
	tailEnd.Name = "Tail"
	tailEnd.Parent = bolt
	local function beam(width0: number, width1: number, colors: ColorSequence, transparency: NumberSequence, speed: number)
		local b = Instance.new("Beam")
		b.Attachment0 = tip
		b.Attachment1 = tailEnd
		b.Texture = Tex.Beam
		b.TextureMode = Enum.TextureMode.Stretch
		b.TextureLength = 1
		b.TextureSpeed = speed
		b.Width0 = width0
		b.Width1 = width1
		b.Color = colors
		b.Transparency = transparency
		b.FaceCamera = true
		b.Segments = 1
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Parent = bolt
	end
	beam(unit * 2.4, unit * 8, ColorSequence.new(color, edge), Seq({ { 0, 0.35 }, { 0.5, 0.65 }, { 1, 1 } }), -1.5) -- glow
	beam(unit, unit * 3, ColorSequence.new(WHITE, color), Seq({ { 0, 0.1 }, { 0.6, 0.5 }, { 1, 1 } }), -2.5) -- core

	VFXUtil.Emitter(bolt, { -- spray shed into its wake, falling away
		Texture = Tex.Glow,
		Color = VFXUtil.Hot(WHITE, color),
		LightEmission = 1,
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Size = Seq({ { 0, unit * 0.35 }, { 1, unit * 0.1 } }),
		Transparency = Seq({ { 0, 0 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.35, 0.7),
		Speed = NumberRange.new(1, 4),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -40, 0),
		Drag = 1,
		Rate = 45,
	})

	-- The head: one big teardrop of water inside a see-through bubble, droplets circling it.
	local decor: Decor = {
		Unit = unit,
		Body = newDroplet(body, tail, bolt),
		Shell = newDroplet(color, color, bolt),
		Orbiters = {},
		Helix = {},
		Tail = newRibbon(bolt, ColorSequence.new(body, edge), 0.38, true, 0),
		Phase = 0,
	}
	placeDroplet(decor.Body, CFrame.identity, unit * 2.2, 0.8, true)
	placeDroplet(decor.Shell, CFrame.identity, unit * 3, 0.5, true)
	fadeDroplet(decor.Body, 0)
	fadeDroplet(decor.Shell, 0, SHELL_ALPHA)
	for i = 1, BOLT_DROPLETS do
		local orbiter: Orbiter = {
			Parts = newDroplet(body, tail, bolt),
			Offset = i * 2 * math.pi / BOLT_DROPLETS,
			Size = unit * (0.45 + 0.3 * ((i * 0.618) % 1)),
			Behind = unit * (0.2 + 1.2 * ((i * 0.382) % 1)),
		}
		placeDroplet(orbiter.Parts, CFrame.identity, orbiter.Size, 1.2, true)
		fadeDroplet(orbiter.Parts, 0)
		table.insert(decor.Orbiters, orbiter)
	end

	-- Streams: three bands twisting round the wake, and a thin wavy streamer down the middle.
	local helixColors = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(0.4, color),
		ColorSequenceKeypoint.new(1, edge),
	})
	for i = 1, 3 do
		table.insert(decor.Helix, newRibbon(bolt, helixColors, 0.26, false, (i - 1) * 2 * math.pi / 3))
	end
	return bolt, tailEnd, decor
end

-- Moves the bolt's droplets and streams with it (after its CFrame is set for this frame).
local function updateBoltDecor(bolt: BasePart, decor: Decor, dt: number)
	decor.Phase += dt * 30 -- the streams wind round fast
	local unit = decor.Unit
	local head = bolt.CFrame
	-- The drop wobbles like liquid: the body and bubble breathe a little.
	local wobble = 1 + 0.08 * math.sin(decor.Phase * 0.7)
	placeDroplet(decor.Body, head, unit * 2.2 * wobble, 0.8, true)
	placeDroplet(decor.Shell, head, unit * 3 / wobble, 0.5, true)
	for _, orbiter in decor.Orbiters do
		local angle = decor.Phase * 0.35 + orbiter.Offset
		local radius = unit * (1.7 + 0.3 * math.sin(decor.Phase * 0.5 + orbiter.Offset * 3))
		local out = Vector3.new(math.cos(angle), math.sin(angle), 0)
		local tangent = Vector3.new(-math.sin(angle), math.cos(angle), 0)
		-- Moving with the bolt and round it: pointed mostly forward, leaning into its orbit.
		local frame = aim(out * radius + Vector3.new(0, 0, orbiter.Behind), -Vector3.zAxis + tangent * 0.35)
		placeDroplet(orbiter.Parts, head * frame, orbiter.Size, 1.2, false)
	end
	local behind = Vector3.new(0, 0, unit * 1.2)
	for _, ribbon in decor.Helix do
		local angle = decor.Phase + ribbon.Offset
		local radius = unit * (1.3 + 0.35 * math.sin(decor.Phase * 0.31 + ribbon.Offset * 2))
		local out = Vector3.new(math.cos(angle), math.sin(angle), 0)
		ribbon.A0.Position = behind + out * radius
		ribbon.A1.Position = behind + out * (radius + unit * 0.45)
	end
	local sway = Vector3.new(math.sin(decor.Phase * 0.45) * unit * 0.9, 0, unit * 1.5)
	decor.Tail.A0.Position = sway
	decor.Tail.A1.Position = sway + Vector3.new(0, unit * 0.5, 0)
end

-- A small burst where a bolt leaves the mouth (or the parrying player).
local function stormMuzzle(position: Vector3, color: Color3)
	local a = VFXUtil.At(position, 0.6)
	if not a then
		return
	end
	local unit = StormfinConfig.Bolt.Radius * BOLT_SCALE
	VFXUtil.Ring(a, VFXUtil.Hot(WHITE, color), 0.5, unit * 10, 0.2):Emit(1)
	VFXUtil.Emitter(a, {
		Texture = Tex.Glow,
		Color = ColorSequence.new(WHITE, color),
		LightEmission = 1,
		Size = Fade(unit * 6, unit * 2),
		Transparency = Fade(0, 1),
		Lifetime = NumberRange.new(0.12),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		ZOffset = 1,
	}):Emit(1)
end

-------------------------------------------------------------------------------- exploding (impact)

type Splash = {
	Parts: { BasePart },
	Origin: Vector3,
	Velocity: Vector3,
	Size: number,
	Start: number,
	Life: number,
}

local splashes: { Splash } = {}

-- Moves a splash droplet for this frame (drag and gravity, stretched along its motion); false once
-- it has faded out (and is destroyed).
local function updateSplash(splash: Splash, now: number): boolean
	local t = now - splash.Start
	if t >= splash.Life then
		destroyAll(splash.Parts)
		return false
	end
	local decay = math.exp(-SPLASH_DRAG * t)
	local position = splash.Origin + splash.Velocity * ((1 - decay) / SPLASH_DRAG) - Vector3.yAxis * (0.5 * SPLASH_GRAVITY * t * t)
	local velocity = splash.Velocity * decay - Vector3.yAxis * (SPLASH_GRAVITY * t)
	local life = t / splash.Life
	local scale = 1 - smooth((life - 0.45) / 0.55)
	placeDroplet(splash.Parts, aim(position, velocity), splash.Size * scale, math.clamp(velocity.Magnitude / 25, 0.2, 2.2), true)
	fadeDroplet(splash.Parts, smooth((life - 0.6) / 0.4))
	return true
end

local function stormBurst(position: Vector3, color: Color3, edge: Color3, travel: Vector3)
	local unit = StormfinConfig.Bolt.Radius * BOLT_SCALE
	local hot = VFXUtil.Hot(WHITE, color)
	local a = VFXUtil.At(position, 1.2)
	if a then
		VFXUtil.Emitter(a, { -- the flash
			Texture = Tex.Glow,
			Color = ColorSequence.new(WHITE, color),
			LightEmission = 1,
			Size = Seq({ { 0, unit * 4 }, { 0.25, unit * 14 }, { 1, unit * 16 } }),
			Transparency = Seq({ { 0, 0 }, { 0.35, 0.25 }, { 1, 1 } }),
			Lifetime = NumberRange.new(0.28),
			Speed = NumberRange.new(0),
			LockedToPart = true,
			ZOffset = 1,
		}):Emit(1)
		VFXUtil.Emitter(a, { -- bright centre
			Texture = Tex.Glow,
			Color = ColorSequence.new(WHITE),
			Size = Fade(unit * 6, unit * 2),
			Transparency = Fade(0, 1),
			Lifetime = NumberRange.new(0.1),
			Speed = NumberRange.new(0),
			LockedToPart = true,
			ZOffset = 2,
		}):Emit(1)
		VFXUtil.Ring(a, hot, 1, unit * 22, 0.28):Emit(1) -- splash rings
		VFXUtil.Ring(a, ColorSequence.new(edge), 1, unit * 32, 0.45):Emit(1)
		VFXUtil.Emitter(a, { -- fine spray flung out and raining down
			Texture = Tex.Glow,
			Color = hot,
			LightEmission = 1,
			Size = Seq({ { 0, unit * 0.4 }, { 1, unit * 0.1 } }),
			Lifetime = NumberRange.new(0.5, 1),
			Speed = NumberRange.new(8, 24),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 2,
			Acceleration = Vector3.new(0, -45, 0),
		}):Emit(40)
		VFXUtil.Emitter(a, { -- a puff of mist
			Texture = Tex.Smoke,
			Color = ColorSequence.new(color),
			LightEmission = 0.3,
			Size = Fade(unit * 3, unit * 7),
			Transparency = Fade(0.55, 1),
			Lifetime = NumberRange.new(0.45, 0.7),
			Speed = NumberRange.new(2, 5),
			SpreadAngle = Vector2.new(180, 180),
			Rotation = NumberRange.new(0, 360),
		}):Emit(6)
		VFXUtil.Flash(a, color, 18, 6, 0.3)
	end

	-- Droplets burst out, mostly back the way it came: big drops, then thin fast streaks of spray.
	local folder = fxFolder()
	if not folder then
		return
	end
	local body, tail = waterColors(color, edge)
	local back = if travel.Magnitude > 1e-3 then -travel.Unit else Vector3.zero
	local now = os.clock()
	local function burst(count: number, speed: NumberRange, size: NumberRange, life: NumberRange)
		for _ = 1, count do
			local direction = (randomUnit() + back * 0.6 + Vector3.yAxis * 0.4).Unit
			local splash: Splash = {
				Parts = newDroplet(body, tail, folder),
				Origin = position,
				Velocity = direction * (speed.Min + (speed.Max - speed.Min) * math.random()),
				Size = size.Min + (size.Max - size.Min) * math.random(),
				Start = now,
				Life = life.Min + (life.Max - life.Min) * math.random(),
			}
			table.insert(splashes, splash)
			updateSplash(splash, now)
		end
	end
	burst(12, NumberRange.new(16, 34), NumberRange.new(unit * 0.6, unit * 1.1), NumberRange.new(0.55, 0.85)) -- drops
	burst(8, NumberRange.new(38, 55), NumberRange.new(unit * 0.25, unit * 0.4), NumberRange.new(0.25, 0.4)) -- spray streaks
end

local function clearCharge(model: Model)
	local attack = attacks[model]
	if attack and attack.Charge then
		attack.Charge:Destroy()
		attack.Charge = nil
	end
	if attack and attack.Intake then
		attack.Intake:Destroy()
		attack.Intake = nil
	end
end

local function onEnemyAttack(model: Model, phase: string, a: any, b: any, c: any)
	if not model or not model.Parent then
		return
	end
	local previous = attacks[model]
	local kind = if previous then previous.Kind else "Punch"
	if phase == "Windup" then
		clearCharge(model)
		kind = if c == "Blast" then "Blast" else "Punch"
		local color = if b == true then PARRYABLE_COLOR else UNPARRYABLE_COLOR
		local attack: Attack = { Phase = "Windup", Kind = kind, Start = os.clock(), Duration = a, Recovery = 0, Charge = nil, Intake = nil }
		local adornee: Instance? = fistAttachment(model)
		if kind == "Blast" then
			local orb = makeOrb(color, 0.4)
			local intake = makeIntake(color)
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local start = CFrame.new(root.Position + root.CFrame.LookVector * 2.5 + Vector3.new(0, 0.5, 0))
				orb.CFrame = start
				intake.CFrame = start
			end
			orb.Parent = fxFolder()
			intake.Parent = fxFolder()
			attack.Charge = orb
			attack.Intake = intake
			adornee = orb
		end
		attacks[model] = attack
		if adornee then
			telegraph(model, b == true, a, adornee)
		end
	elseif phase == "Strike" then
		clearCharge(model)
		attacks[model] = { Phase = "Strike", Kind = kind, Start = os.clock(), Duration = a, Recovery = b, Charge = nil }
	elseif phase == "Parried" then
		-- Hitstop: hold the punch for a beat, then the arm is knocked back.
		attacks[model] = { Phase = "Parried", Kind = kind, Start = os.clock(), Duration = ParryConfig.Visuals.HitstopTime, Recovery = ParryConfig.AttackerStagger, Charge = nil }
	elseif phase == "Cancel" then
		clearCharge(model)
		clearTelegraph(model)
		attacks[model] = nil
		local rootJoint, right, left = joints(model)
		for _, joint in { rootJoint, right, left } do
			if joint then
				joint.Transform = CFrame.identity
			end
		end
	elseif phase == "Hit" then
		local target = a :: Model
		impact(target)
		local targetRoot = target:FindFirstChild("HumanoidRootPart")
		if target == localPlayer.Character then
			SFX.Play2D("PunchImpact")
		elseif targetRoot then
			SFX.Play("PunchImpact", targetRoot)
		end
		if target == localPlayer.Character then
			CameraController.Shake(0.4, 0.2)
			local root = target:FindFirstChild("HumanoidRootPart") :: BasePart?
			local enemyRoot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and enemyRoot then
				local away = root.Position - enemyRoot.Position
				away = Vector3.new(away.X, 0, away.Z)
				if away.Magnitude > 0.01 then
					root.AssemblyLinearVelocity = away.Unit * DummyConfig.Knockback + Vector3.yAxis * 12
				end
			end
		end
	end
end

-- R6 transform axes: shoulder Angles(0, 0, +a) swings the right arm forward (the left arm uses -a);
-- RootJoint Angles(0, 0, +a) twists the torso to the left.
local function pose(model: Model, attack: Attack): boolean
	local rootJoint, right, left = joints(model)
	if not rootJoint or not right or not left then
		return false
	end
	local elapsed = os.clock() - attack.Start
	local armRaise, twist, guard
	if attack.Kind == "Blast" then
		-- Both hands push forward to charge, then kick up on release.
		if attack.Phase == "Windup" then
			local alpha = easeOut(elapsed / attack.Duration)
			armRaise, guard, twist = 1.45 * alpha, 1.45 * alpha, 0
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if attack.Charge and root then
				local size = 0.4 + 1.8 * math.clamp(elapsed / attack.Duration, 0, 1)
				local at = CFrame.new(root.Position + root.CFrame.LookVector * 2.5 + Vector3.new(0, 0.5, 0))
				attack.Charge.Size = Vector3.one * size
				attack.Charge.CFrame = at
				if attack.Intake then
					attack.Intake.CFrame = at
				end
			end
		else
			local kick = 1 - easeOut(elapsed / math.max(attack.Duration, 0.01))
			local recover = math.clamp((elapsed - attack.Duration) / attack.Recovery, 0, 1)
			if recover >= 1 then
				return false
			end
			local raise = (1.45 + 0.5 * math.max(kick, 0)) * (1 - easeOut(recover))
			armRaise, guard, twist = raise, raise, 0
		end
	elseif attack.Phase == "Windup" then
		local alpha = easeOut(elapsed / attack.Duration)
		armRaise = -0.8 * alpha -- fist drawn back
		twist = -0.4 * alpha -- shoulders coil away
		guard = 1.2 * alpha
	elseif attack.Phase == "Parried" then
		if elapsed < attack.Duration then
			armRaise, twist, guard = math.pi / 2, 0.35, 1.2 -- frozen mid-punch
		else
			local recover = (elapsed - attack.Duration) / attack.Recovery
			if recover >= 1 then
				return false
			end
			local knock = math.sin(math.min(recover * 3, 1) * math.pi / 2) * (1 - easeOut(recover))
			armRaise = -1.4 * knock -- arm flung back and up
			twist = -0.7 * knock -- staggered away
			guard = 0.3 * (1 - recover)
		end
	else
		local snap = easeOut(elapsed / PUNCH_SNAP)
		local recover = math.clamp((elapsed - attack.Duration) / attack.Recovery, 0, 1)
		if recover >= 1 then
			return false
		end
		local hold = 1 - easeOut(recover)
		armRaise = (-0.8 + (math.pi / 2 + 0.8) * snap) * hold
		twist = (-0.4 + 0.75 * snap) * hold
		guard = 1.2 * hold
	end
	right.Transform = CFrame.Angles(0, 0, armRaise)
	left.Transform = CFrame.Angles(0, 0, -guard)
	rootJoint.Transform = CFrame.Angles(0, 0, twist)
	return true
end

local function endProjectile(id: number, position: Vector3?, reason: string?)
	local projectile = projectiles[id]
	if not projectile then
		return
	end
	projectiles[id] = nil
	local color = projectile.Color
	local decor = projectile.Decor
	if decor then
		-- The drop bursts (the splash below flings its droplets) or vanishes at the end of its range.
		destroyAll(decor.Body)
		destroyAll(decor.Shell)
		for _, orbiter in decor.Orbiters do
			destroyAll(orbiter.Parts)
		end
	end
	-- Let the trail and wake finish instead of vanishing with the orb.
	local part = projectile.Part
	part.Transparency = 1
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		elseif descendant:IsA("PointLight") or descendant:IsA("Beam") then
			descendant.Enabled = false
		end
	end
	Debris:AddItem(part, 0.4)
	if not position or reason == "Expired" then
		return
	end
	if decor then
		stormBurst(position, color, projectile.Edge or BOLT_EDGE, projectile.Direction)
		SFX.Play("BulletImpact", position)
		return
	end
	local a = VFXUtil.At(position, 0.8)
	if a then
		local hot = VFXUtil.Hot(WHITE, color)
		VFXUtil.Emitter(a, {
			Texture = Tex.Flare,
			Color = hot,
			Size = Fade(5, 1),
			Transparency = Fade(0, 1),
			Lifetime = NumberRange.new(0.1),
			Speed = NumberRange.new(0),
			Rotation = NumberRange.new(0, 45),
			LockedToPart = true,
			ZOffset = 1,
		}):Emit(1)
		VFXUtil.Ring(a, hot, 1, 7, 0.22):Emit(1)
		VFXUtil.Emitter(a, {
			Texture = Tex.Streak,
			Color = hot,
			Size = Fade(0.35, 0),
			Lifetime = NumberRange.new(0.2, 0.4),
			Speed = NumberRange.new(15, 35),
			SpreadAngle = Vector2.new(180, 180),
			Orientation = Enum.ParticleOrientation.VelocityParallel,
			Drag = 4,
		}):Emit(20)
		VFXUtil.Flash(a, color, 14, 5, 0.25)
	end
	SFX.Play("BulletImpact", position)
end

local function onEnemyProjectile(kind: string, id: number, a: any, b: any, c: any, d: any, e: any)
	if kind == "Fire" then
		local origin, direction, speed, range, style = a, b, c, d, e
		-- Blasts are cyan (parryable); a reflected projectile takes the player's attack colour; the
		-- Stormfin's Storm Bolt is blue-white storm-water.
		local color = PARRYABLE_COLOR
		local radius = DummyConfig.Blast.Radius
		local edge = BOLT_EDGE
		if style == "Reflected" then
			color = WeaponConfig.DualPistols.Visuals.Color
		elseif style == "StormBolt" then
			color = StormfinConfig.Visuals.BoltColor
			radius = StormfinConfig.Bolt.Radius
		elseif style == "ReflectedStormBolt" then
			edge = WeaponConfig.DualPistols.Visuals.Color
			color = edge:Lerp(WHITE, 0.35)
			radius = StormfinConfig.Bolt.Radius
		end
		if style == "StormBolt" or style == "ReflectedStormBolt" then
			local bolt, tail, decor = makeStormBolt(color, edge, radius)
			bolt.CFrame = CFrame.lookAt(origin, origin + direction)
			updateBoltDecor(bolt, decor, 0)
			bolt.Parent = fxFolder()
			stormMuzzle(origin, color)
			projectiles[id] = { Part = bolt, Color = color, Edge = edge, Origin = origin, Direction = direction, Speed = speed, Range = range, Start = os.clock(), Style = style, Tail = tail, Decor = decor }
			return
		end
		-- The neon core is smaller than the hit radius; the halo shows the full size.
		local orb = makeOrb(color, radius * 1.3)
		local center = orb:FindFirstChild("Center") :: Attachment
		VFXUtil.Emitter(center, { -- flame wake left behind as it flies
			Texture = Tex.Wisp,
			Color = VFXUtil.Hot(WHITE:Lerp(color, 0.6), color, color:Lerp(Color3.new(0, 0, 0), 0.4)),
			LightEmission = 0.35, -- mostly alpha-blended so overlapping wake keeps the cue colour
			FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2,
			FlipbookMode = Enum.ParticleFlipbookMode.OneShot,
			Size = Fade(radius * 1.6, 0.2),
			Transparency = Seq({ { 0, 0.3 }, { 1, 1 } }),
			Lifetime = NumberRange.new(0.25, 0.35),
			Speed = NumberRange.new(0),
			Rotation = NumberRange.new(0, 360),
			Rate = 28,
		})
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, radius * 0.7, 0)
		a0.Parent = orb
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -radius * 0.7, 0)
		a1.Parent = orb
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.FaceCamera = true
		trail.Lifetime = 0.35
		trail.Color = ColorSequence.new(WHITE:Lerp(color, 0.7), color)
		trail.Transparency = Fade(0.2, 1)
		trail.WidthScale = Fade(1, 0)
		trail.LightEmission = 1
		trail.LightInfluence = 0
		trail.Parent = orb
		orb.CFrame = CFrame.lookAt(origin, origin + direction)
		orb.Parent = fxFolder()
		projectiles[id] = { Part = orb, Color = color, Origin = origin, Direction = direction, Speed = speed, Range = range, Start = os.clock(), Style = style }
	elseif kind == "End" then
		endProjectile(id, a, b)
	end
end

function EnemyVisuals.Init()
	Remotes.EnemyAttack.OnClientEvent:Connect(onEnemyAttack)
	Remotes.EnemyProjectile.OnClientEvent:Connect(onEnemyProjectile)
	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		for id, projectile in projectiles do
			local traveled = projectile.Speed * (now - projectile.Start)
			if traveled >= projectile.Range then
				endProjectile(id, nil, "Expired")
			else
				local at = projectile.Origin + projectile.Direction * traveled
				projectile.Part.CFrame = CFrame.lookAt(at, at + projectile.Direction)
				if projectile.Decor then
					updateBoltDecor(projectile.Part, projectile.Decor, dt)
				end
				if projectile.Tail then
					-- +Z is behind the part (it looks along the flight); never behind the muzzle.
					projectile.Tail.Position = Vector3.new(0, 0, math.min(traveled, BOLT_LENGTH))
				end
			end
		end
		-- Storm Bolt charges and splash droplets (backwards: finished ones are removed).
		for i = #charges, 1, -1 do
			local charge = charges[i]
			if not updateCharge(charge, now) then
				endCharge(charge)
			end
		end
		for i = #splashes, 1, -1 do
			if not updateSplash(splashes[i], now) then
				table.remove(splashes, i)
			end
		end
	end)
	RunService.PreSimulation:Connect(function()
		for model, attack in attacks do
			if not model.Parent or not pose(model, attack) then
				if attack.Charge then
					attack.Charge:Destroy()
				end
				if attack.Intake then
					attack.Intake:Destroy()
				end
				attacks[model] = nil
				local rootJoint, right, left = joints(model)
				for _, joint in { rootJoint, right, left } do
					if joint then
						joint.Transform = CFrame.identity
					end
				end
			end
		end
	end)
end

return EnemyVisuals
