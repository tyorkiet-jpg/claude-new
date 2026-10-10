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
	Decor: Decor?, -- Storm Bolt crystals and ribbons, moved every frame
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

-- Storm Bolt (Stormfin), after the user's "IceBall Magic" reference: a charged ball of storm-ice.
-- GROWING (EnemyVisuals.ChargeStormBolt, at the fin's mouth while it charges): a white-hot orb
-- swells, crystals sprout from it one by one, two energy streams whirl round it and sparkles are
-- drawn in. FIRING (makeStormBolt): a cluster of crystal spikes splaying back from a white-hot
-- core, ribbons twisting round its wake, a soft comet glow and a trail of sparkles. EXPLODING
-- (stormBurst): a flash, shockwave rings, needle rays, sparkles and crystal shards flung outward.
-- A parried bolt comes back as the same thing in the player's attack colour ("ReflectedStormBolt").
-- There are no crystal textures, so the crystals are real parts (crossed neon blades, see
-- newCrystal) and read as solid ice from any angle; the ribbons are Trails on attachments that
-- orbit the flight line every frame; the explosion's rays are thin crystals too, because
-- VelocityParallel particles stand across horizontal motion.
local BOLT_EDGE = Color3.fromRGB(70, 140, 255) -- deep blue edge of the Stormfin's own bolt
local BOLT_LENGTH = 9 -- studs of comet glow behind the head
local BOLT_SCALE = 0.55 -- overall size of the effect relative to the hit radius (user: it was too large)
local CRYSTAL_THICKNESS = 0.05 -- studs; each crystal blade is this thin
local CRYSTAL_ALPHA = { 0.05, 0.05, 0.3, 0.3 } -- the light blade nearly solid, the dark one see-through
local CHARGE_AHEAD = 0.7 -- studs in front of the mouth the charge grows
local CHARGE_CRYSTALS = 7
local SHARD_DRAG = 5 -- 1/s: how fast the explosion's shards slow down

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

type Crystal = {
	Parts: { BasePart },
	Frame: CFrame, -- (bolt) base and pointing direction, relative to the head
	Direction: Vector3, -- (charge) pointing direction, relative to the mouth
	Length: number,
	Width: number,
	Appear: number, -- (charge) charge progress at which it starts to sprout
}

-- One ice crystal: two crossed blades, each an isosceles triangle of two mirrored wedges. A
-- WedgePart is thin along its front-bottom edge, so a wedge and a copy turned upside down beneath
-- it meet in a point at the front: the crystal points along its frame's LookVector (-Z).
local function newCrystal(light: Color3, dark: Color3, parent: Instance): { BasePart }
	local parts = {}
	for i = 1, 4 do
		local wedge = Instance.new("WedgePart")
		wedge.Anchored = true
		wedge.CanCollide = false
		wedge.CanQuery = false
		wedge.CanTouch = false
		wedge.CastShadow = false
		wedge.Material = Enum.Material.Neon
		wedge.Color = if i <= 2 then light else dark
		wedge.Transparency = 1 -- shown once placed (fadeCrystal)
		wedge.Size = Vector3.new(CRYSTAL_THICKNESS, 0.1, 0.1)
		wedge.Parent = parent
		parts[i] = wedge
	end
	return parts
end

-- Shows (0) to hides (1) a crystal.
local function fadeCrystal(parts: { BasePart }, fade: number)
	for i, part in parts do
		part.Transparency = CRYSTAL_ALPHA[i] + (1 - CRYSTAL_ALPHA[i]) * fade
	end
end

-- Puts a crystal's base at frame.Position, pointing along frame.LookVector. `resize` only when the
-- length or width changed (resizing costs more than moving).
local function placeCrystal(parts: { BasePart }, frame: CFrame, length: number, width: number, resize: boolean)
	length = math.max(length, 0.02)
	local half = math.max(width, 0.02) * 0.5
	local centre = frame * CFrame.new(0, 0, -length * 0.5)
	for blade = 0, 1 do
		local bladeFrame = centre * CFrame.Angles(0, 0, blade * math.pi * 0.5)
		local upper, lower = parts[blade * 2 + 1], parts[blade * 2 + 2]
		if resize then
			local size = Vector3.new(CRYSTAL_THICKNESS, half, length)
			upper.Size = size
			lower.Size = size
		end
		upper.CFrame = bladeFrame * CFrame.new(0, half * 0.5, 0)
		lower.CFrame = bladeFrame * CFrame.new(0, -half * 0.5, 0) * CFrame.Angles(0, 0, math.pi)
	end
end

local function destroyAll(parts: { Instance })
	for _, part in parts do
		part:Destroy()
	end
end

type Ribbon = { A0: Attachment, A1: Attachment, Offset: number }

-- A ribbon of light: a Trail between two attachments that the caller moves every frame (their
-- separation is its width). FaceCamera off keeps a twisting band's real 3D twist.
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

-------------------------------------------------------------------------------- growing (charge)

type Charge = {
	Mouth: Attachment,
	Start: number,
	Duration: number,
	Unit: number,
	Holder: BasePart, -- invisible ball at the charge: the intake sparkles' sphere; owns everything else
	Orb: BasePart,
	Light: PointLight,
	Halo: ParticleEmitter,
	Intake: ParticleEmitter,
	Crystals: { Crystal },
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
	local spun = frame * CFrame.Angles(0, 0, elapsed * 1.6) -- the whole cluster turns slowly
	local size = unit * (0.5 + 1.9 * grow)
	charge.Holder.CFrame = frame
	charge.Orb.Size = Vector3.one * size
	charge.Orb.CFrame = frame
	charge.Light.Brightness = 1 + 4 * grow
	charge.Halo.Size = NumberSequence.new(size * 2.6)
	charge.Intake.Rate = 15 + 55 * progress

	-- Crystals sprout one after another and grow out of the orb.
	for _, crystal in charge.Crystals do
		local sprout = easeOut((progress - crystal.Appear) / 0.3)
		if sprout <= 0 then
			fadeCrystal(crystal.Parts, 1)
		else
			local direction = spun:VectorToWorldSpace(crystal.Direction)
			fadeCrystal(crystal.Parts, 0)
			placeCrystal(crystal.Parts, aim(frame.Position + direction * size * 0.3, direction), crystal.Length * sprout, crystal.Width * sprout, true)
		end
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
	local light, dark = WHITE:Lerp(color, 0.35), BOLT_EDGE:Lerp(color, 0.3)
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
	local intake = VFXUtil.Emitter(holder, { -- sparkles drawn in from all round
		Texture = Tex.Glow,
		Color = VFXUtil.Hot(color, WHITE),
		LightEmission = 1,
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		Size = Seq({ { 0, 0 }, { 0.3, unit * 0.35 }, { 1, unit * 0.1 } }),
		Transparency = Seq({ { 0, 1 }, { 0.3, 0.1 }, { 1, 0 } }),
		Lifetime = NumberRange.new(0.25, 0.35),
		Speed = NumberRange.new(unit * 9),
		Rate = 15,
	})

	local orb = invisiblePart(Enum.PartType.Ball, unit)
	orb.Material = Enum.Material.Neon
	orb.Color = WHITE:Lerp(color, 0.3)
	orb.Parent = holder
	local glow = Instance.new("PointLight")
	glow.Color = color
	glow.Range = 12
	glow.Brightness = 1
	glow.Shadows = false
	glow.Parent = orb

	-- Crystals spread round the front half (never back into the fin's head), sprouting in turn.
	local crystals: { Crystal } = {}
	for i = 1, CHARGE_CRYSTALS do
		local azimuth = i * 2.39996 -- golden angle: spreads them evenly round
		local tilt = math.rad(40 + 50 * ((i * 0.618) % 1)) -- from straight ahead out to the sides
		local direction = Vector3.new(math.sin(tilt) * math.cos(azimuth), math.sin(tilt) * math.sin(azimuth), -math.cos(tilt))
		local length = unit * (1.6 + 1.2 * ((i * 0.382) % 1))
		table.insert(crystals, {
			Parts = newCrystal(light, dark, holder),
			Frame = CFrame.identity,
			Direction = direction,
			Length = length,
			Width = length * 0.42,
			Appear = 0.08 + 0.55 * (i - 1) / (CHARGE_CRYSTALS - 1),
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
		Light = glow,
		Halo = halo,
		Intake = intake,
		Crystals = crystals,
		Ribbons = ribbons,
	}
	table.insert(charges, charge)
	updateCharge(charge, charge.Start)
	return function()
		endCharge(charge)
	end
end

-------------------------------------------------------------------------------- firing (projectile)

type Decor = {
	Unit: number,
	Crystals: { Crystal },
	Helix: { Ribbon },
	Tail: Ribbon,
	Spin: number,
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
	local hot = VFXUtil.Hot(WHITE, color)

	VFXUtil.Emitter(tip, { -- white-hot core
		Texture = Tex.Glow,
		Color = ColorSequence.new(WHITE, WHITE:Lerp(color, 0.5)),
		Size = NumberSequence.new(unit * 2.2),
		Transparency = Seq({ { 0, 0 }, { 1, 0.5 } }),
		Lifetime = NumberRange.new(0.08),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		ZOffset = 1,
		Rate = 40,
	})
	VFXUtil.Emitter(tip, { -- coloured halo round the crystals
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
	local tail = Instance.new("Attachment")
	tail.Name = "Tail"
	tail.Parent = bolt
	local function beam(width0: number, width1: number, colors: ColorSequence, transparency: NumberSequence, speed: number)
		local b = Instance.new("Beam")
		b.Attachment0 = tip
		b.Attachment1 = tail
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

	VFXUtil.Emitter(bolt, { -- sparkles shed into its wake
		Texture = Tex.Glow,
		Color = hot,
		LightEmission = 1,
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Size = Seq({ { 0, unit * 0.35 }, { 1, 0 } }),
		Transparency = Seq({ { 0, 0 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.3, 0.6),
		Speed = NumberRange.new(1, 4),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 2,
		Rate = 45,
	})

	-- Crystal head: a spearhead forward, long spikes splayed back from the flight line and a ring
	-- of short, chunky crystals round the core (the head frame looks along the flight: +Z is behind).
	local light2, dark = WHITE:Lerp(color, 0.35), edge:Lerp(color, 0.3)
	local crystals: { Crystal } = {}
	local function addCrystal(base: Vector3, direction: Vector3, length: number, width: number)
		table.insert(crystals, {
			Parts = newCrystal(light2, dark, bolt),
			Frame = aim(base, direction),
			Direction = direction,
			Length = length,
			Width = width,
			Appear = 0,
		})
	end
	addCrystal(Vector3.new(0, 0, unit * 0.4), -Vector3.zAxis, unit * 2.6, unit * 1.1)
	for i = 1, 5 do
		local azimuth = i * 2 * math.pi / 5
		local tilt = math.rad(26 + 14 * ((i * 0.618) % 1))
		local direction = Vector3.new(math.sin(tilt) * math.cos(azimuth), math.sin(tilt) * math.sin(azimuth), math.cos(tilt))
		local length = unit * (3.2 + 1.4 * ((i * 0.382) % 1))
		addCrystal(Vector3.new(0, 0, -unit * 0.2), direction, length, length * 0.4)
	end
	for i = 1, 4 do
		local azimuth = (i + 0.5) * 2 * math.pi / 4
		local tilt = math.rad(60 + 20 * ((i * 0.618) % 1))
		local direction = Vector3.new(math.sin(tilt) * math.cos(azimuth), math.sin(tilt) * math.sin(azimuth), math.cos(tilt))
		addCrystal(Vector3.new(0, 0, unit * 0.1), direction, unit * 1.8, unit * 1.4)
	end
	for _, crystal in crystals do
		fadeCrystal(crystal.Parts, 0)
		placeCrystal(crystal.Parts, crystal.Frame, crystal.Length, crystal.Width, true) -- sized once; after this they only move
	end

	-- Ribbons: three bands twisting round the wake, and a thin wavy streamer down the middle.
	local helixColors = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(0.4, color),
		ColorSequenceKeypoint.new(1, edge),
	})
	local helix = {}
	for i = 1, 3 do
		table.insert(helix, newRibbon(bolt, helixColors, 0.26, false, (i - 1) * 2 * math.pi / 3))
	end
	local decor: Decor = {
		Unit = unit,
		Crystals = crystals,
		Helix = helix,
		Tail = newRibbon(bolt, ColorSequence.new(light2, edge), 0.38, true, 0),
		Spin = 0,
		Phase = 0,
	}
	return bolt, tail, decor
end

-- Moves the bolt's crystals and ribbons with it (after its CFrame is set for this frame).
local function updateBoltDecor(bolt: BasePart, decor: Decor, dt: number)
	decor.Spin += dt * 2.5 -- the crystal head rolls slowly
	decor.Phase += dt * 30 -- the ribbons wind round fast
	local unit = decor.Unit
	local head = bolt.CFrame * CFrame.Angles(0, 0, decor.Spin)
	for _, crystal in decor.Crystals do
		placeCrystal(crystal.Parts, head * crystal.Frame, crystal.Length, crystal.Width, false)
	end
	local behind = Vector3.new(0, 0, unit * 1.2)
	for _, ribbon in decor.Helix do
		local angle = decor.Phase + ribbon.Offset
		local radius = unit * (1.3 + 0.35 * math.sin(decor.Phase * 0.31 + ribbon.Offset * 2))
		local out = Vector3.new(math.cos(angle), math.sin(angle), 0)
		ribbon.A0.Position = behind + out * radius
		ribbon.A1.Position = behind + out * (radius + unit * 0.45)
	end
	local wobble = Vector3.new(math.sin(decor.Phase * 0.45) * unit * 0.9, 0, unit * 1.5)
	decor.Tail.A0.Position = wobble
	decor.Tail.A1.Position = wobble + Vector3.new(0, unit * 0.5, 0)
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

type Shard = {
	Parts: { BasePart },
	Origin: Vector3,
	Velocity: Vector3,
	Tumble: Vector3, -- axis it spins about as it flies
	Length: number,
	Width: number,
	Start: number,
	Life: number,
}

local shards: { Shard } = {}

-- Moves an explosion shard for this frame; false once it has faded out (and is destroyed).
local function updateShard(shard: Shard, now: number): boolean
	local t = now - shard.Start
	if t >= shard.Life then
		destroyAll(shard.Parts)
		return false
	end
	local position = shard.Origin + shard.Velocity * ((1 - math.exp(-SHARD_DRAG * t)) / SHARD_DRAG) - Vector3.yAxis * (14 * t * t)
	local frame = aim(position, shard.Velocity) * CFrame.fromAxisAngle(shard.Tumble, t * 9)
	local life = t / shard.Life
	local scale = 1 - smooth((life - 0.35) / 0.65)
	placeCrystal(shard.Parts, frame, shard.Length * scale, shard.Width * scale, true)
	fadeCrystal(shard.Parts, smooth((life - 0.55) / 0.45))
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
		VFXUtil.Emitter(a, { -- white-hot centre
			Texture = Tex.Glow,
			Color = ColorSequence.new(WHITE),
			Size = Fade(unit * 6, unit * 2),
			Transparency = Fade(0, 1),
			Lifetime = NumberRange.new(0.1),
			Speed = NumberRange.new(0),
			LockedToPart = true,
			ZOffset = 2,
		}):Emit(1)
		VFXUtil.Ring(a, hot, 1, unit * 22, 0.28):Emit(1)
		VFXUtil.Ring(a, ColorSequence.new(edge), 1, unit * 32, 0.45):Emit(1)
		VFXUtil.Emitter(a, { -- sparkles flung out, drifting down
			Texture = Tex.Glow,
			Color = hot,
			LightEmission = 1,
			Size = Seq({ { 0, unit * 0.45 }, { 1, 0 } }),
			Lifetime = NumberRange.new(0.4, 0.9),
			Speed = NumberRange.new(8, 26),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 3,
			Acceleration = Vector3.new(0, -8, 0),
		}):Emit(36)
		VFXUtil.Emitter(a, { -- a puff of icy mist
			Texture = Tex.Smoke,
			Color = ColorSequence.new(color),
			LightEmission = 0.3,
			Size = Fade(unit * 3, unit * 7),
			Transparency = Fade(0.6, 1),
			Lifetime = NumberRange.new(0.4, 0.6),
			Speed = NumberRange.new(2, 5),
			SpreadAngle = Vector2.new(180, 180),
			Rotation = NumberRange.new(0, 360),
		}):Emit(5)
		VFXUtil.Flash(a, color, 18, 6, 0.3)
	end

	-- Crystal shards and needle rays flung outward, mostly back the way it came.
	local folder = fxFolder()
	if not folder then
		return
	end
	local light, dark = WHITE:Lerp(color, 0.35), edge:Lerp(color, 0.3)
	local back = if travel.Magnitude > 1e-3 then -travel.Unit else Vector3.zero
	local now = os.clock()
	local function fling(count: number, speed: NumberRange, length: NumberRange, thinness: number, life: NumberRange)
		for _ = 1, count do
			local direction = (randomUnit() + back * 0.6).Unit
			local size = length.Min + (length.Max - length.Min) * math.random()
			local shard: Shard = {
				Parts = newCrystal(light, dark, folder),
				Origin = position,
				Velocity = direction * (speed.Min + (speed.Max - speed.Min) * math.random()),
				Tumble = randomUnit(),
				Length = size,
				Width = size * thinness,
				Start = now,
				Life = life.Min + (life.Max - life.Min) * math.random(),
			}
			table.insert(shards, shard)
			updateShard(shard, now)
		end
	end
	fling(8, NumberRange.new(24, 42), NumberRange.new(unit * 2, unit * 3.6), 0.45, NumberRange.new(0.45, 0.7)) -- shards
	fling(8, NumberRange.new(45, 65), NumberRange.new(unit * 4, unit * 7), 0.08, NumberRange.new(0.2, 0.3)) -- rays
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
		-- The crystal head shatters (the burst below flings the shards) or blinks out at range.
		for _, crystal in decor.Crystals do
			destroyAll(crystal.Parts)
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
		-- Stormfin's Storm Bolt is blue-white storm-ice.
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
		-- Storm Bolt charges and explosion shards (backwards: finished ones are removed).
		for i = #charges, 1, -1 do
			local charge = charges[i]
			if not updateCharge(charge, now) then
				endCharge(charge)
			end
		end
		for i = #shards, 1, -1 do
			if not updateShard(shards[i], now) then
				table.remove(shards, i)
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
