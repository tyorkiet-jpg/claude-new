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
	Aligned: { [ParticleEmitter]: number }?, -- Storm Bolt streaks kept pointing along the flight
	Tail: Attachment?, -- Storm Bolt wake end, trailing behind the head
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

-- Storm Bolt (Stormfin): a lightning arrow. A white-hot head, a wake that widens and fades behind
-- it (two tapered Beams from the head back along the flight: white core, coloured glow), a bow
-- wave of thin streaks flaring back off the head and long faint dashes streaming past. The part
-- is an invisible box around the flight line: its volume seeds the dashes; the Center attachment
-- is the head. A parried bolt is reflected as the same arrow in the player's attack colour
-- (style "ReflectedStormBolt").
-- The streaks are camera-facing and re-rotated every frame to lie along the bolt's on-screen
-- direction (alignStreaks). VelocityParallel can't be used: it only lines a texture up with
-- vertical motion and stands it across horizontal motion. Squash > 0 makes them longer/thinner.
local BOLT_EDGE = Color3.fromRGB(70, 140, 255) -- outer glow of the Stormfin's own bolt
local BOLT_LENGTH = 14 -- studs of wake behind the head
local BOLT_SCALE = 0.55 -- overall size of the effect relative to the hit radius (user: it was too large)

local END_ON = 0.35 -- below this much sideways view the streaks are switched off (see alignStreaks)

-- Points each streak emitter along the bolt as the camera sees it at the head's position (with
-- perspective, so it holds when the bolt passes close by); `spread` fans it by up to that many
-- degrees. Camera-facing streaks can't foreshorten, so when the bolt is seen nearly end-on
-- (flying at you) they'd stand up as long lines: they stop emitting and the head and its arcs
-- carry the look.
local function alignStreaks(aligned: { [ParticleEmitter]: number }, head: Vector3, direction: Vector3)
	local camera = workspace.CurrentCamera
	local ray = head - camera.CFrame.Position
	local sideways = if ray.Magnitude > 0.01 then direction:Cross(ray.Unit).Magnitude else 0
	local a = camera:WorldToViewportPoint(head)
	local b = camera:WorldToViewportPoint(head - direction * 2)
	local angle
	if a.Z > 0 and b.Z > 0 then
		-- Particle Rotation turns counterclockwise on screen; viewport Y grows downward.
		angle = -math.deg(math.atan2(a.X - b.X, b.Y - a.Y))
	else
		local view = camera.CFrame
		angle = -math.deg(math.atan2(view.RightVector:Dot(direction), view.UpVector:Dot(direction)))
	end
	for emitter, spread in aligned do
		emitter.Enabled = sideways >= END_ON
		emitter.Rotation = NumberRange.new(angle - spread, angle + spread)
	end
end

local function makeStormBolt(color: Color3, edge: Color3, radius: number): (BasePart, { [ParticleEmitter]: number }, Attachment)
	radius *= BOLT_SCALE -- every size below is relative to this
	local bolt = invisiblePart(Enum.PartType.Block, 1)
	bolt.Size = Vector3.new(radius * 8, radius * 8, radius * 2)
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
	local back = Enum.NormalId.Back -- the part looks along the flight, so Back is behind the tip
	local aligned: { [ParticleEmitter]: number } = {}

	-- Head: camera-facing, so the bolt still reads when it flies straight at you (the wake and
	-- streaks below all lie along the flight and collapse to nothing when seen head-on).
	VFXUtil.Emitter(tip, { -- white-hot core
		Texture = Tex.Glow,
		Color = ColorSequence.new(WHITE, WHITE:Lerp(color, 0.5)),
		Size = NumberSequence.new(radius * 1.8),
		Transparency = Seq({ { 0, 0 }, { 1, 0.5 } }),
		Lifetime = NumberRange.new(0.08),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		ZOffset = 1,
		Rate = 40,
	})
	VFXUtil.Emitter(tip, { -- spiky star around the core
		Texture = Tex.Flare,
		Color = hot,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, radius * 3.5, radius), NumberSequenceKeypoint.new(1, radius * 2) }),
		Transparency = Seq({ { 0, 0.1 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.06, 0.1),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		LockedToPart = true,
		ZOffset = 1,
		Rate = 30,
	})
	VFXUtil.Emitter(tip, { -- arcs crackling over the head
		Texture = Tex.Arc,
		Color = hot,
		FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2,
		FlipbookMode = Enum.ParticleFlipbookMode.Loop,
		FlipbookFramerate = NumberRange.new(30),
		FlipbookStartRandom = true,
		Size = NumberSequence.new(radius * 3),
		Transparency = Seq({ { 0, 0 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.06, 0.12),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		LockedToPart = true,
		Rate = 20,
	})

	-- Wake: Beams from the head to a tail attachment that trails BOLT_LENGTH behind (moved each
	-- frame, see the RenderStepped loop), pointed at the head and widening back like the
	-- reference's beam. The texture scrolls toward the tail so the beam streams.
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
	beam(radius * 2, radius * 13, ColorSequence.new(color, edge), Seq({ { 0, 0.1 }, { 0.5, 0.45 }, { 1, 1 } }), -1.5) -- glow
	beam(radius, radius * 7, ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(0.5, WHITE:Lerp(color, 0.4)),
		ColorSequenceKeypoint.new(1, color),
	}), Seq({ { 0, 0 }, { 0.6, 0.35 }, { 1, 1 } }), -2.5) -- core
	aligned[VFXUtil.Emitter(tip, { -- bow wave: thin streaks flaring out and back off the tip
		Texture = Tex.Streak,
		Color = hot,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, radius * 2, radius * 0.8), NumberSequenceKeypoint.new(1, radius * 0.6) }),
		Squash = NumberSequence.new(1.5),
		Transparency = Seq({ { 0, 0 }, { 0.6, 0.3 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.1, 0.2),
		Speed = NumberRange.new(25, 45),
		EmissionDirection = back,
		SpreadAngle = Vector2.new(60, 60),
		Drag = 3,
		Rate = 60,
	})] = 18
	VFXUtil.Emitter(tip, { -- bright chips thrown off the tip
		Texture = Tex.Flare,
		Color = hot,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, radius * 1.2, radius * 0.5), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.15, 0.3),
		Speed = NumberRange.new(10, 25),
		EmissionDirection = back,
		SpreadAngle = Vector2.new(70, 70),
		Rotation = NumberRange.new(0, 360),
		Drag = 4,
		Rate = 22,
	})
	aligned[VFXUtil.Emitter(tip, { -- arrowhead: a sharp white spike riding the tip
		Texture = Tex.Streak,
		Color = ColorSequence.new(WHITE),
		Size = NumberSequence.new(radius * 4),
		Transparency = Seq({ { 0, 0 }, { 1, 0.6 } }),
		Lifetime = NumberRange.new(0.05),
		Speed = NumberRange.new(0),
		LockedToPart = true,
		ZOffset = 1,
		Rate = 60,
	})] = 0

	-- Volume around the line.
	aligned[VFXUtil.Emitter(bolt, { -- long faint dashes streaming past
		Texture = Tex.Streak,
		Color = ColorSequence.new(WHITE:Lerp(color, 0.4)),
		LightEmission = 0.5,
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, radius * 3.5, radius * 1.5), NumberSequenceKeypoint.new(1, radius * 3.5, radius * 1.5) }),
		Squash = NumberSequence.new(1.5), -- positive = longer and thinner along the (rotated) streak
		Transparency = Seq({ { 0, 1 }, { 0.2, 0.45 }, { 1, 1 } }),
		Lifetime = NumberRange.new(0.25, 0.4),
		Speed = NumberRange.new(3, 8),
		EmissionDirection = back,
		Rate = 30,
	})] = 0
	return bolt, aligned, tail
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
		-- Stormfin's Storm Bolt is blue-white lightning.
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
			local bolt, aligned, tail = makeStormBolt(color, edge, radius)
			bolt.CFrame = CFrame.lookAt(origin, origin + direction)
			alignStreaks(aligned, origin, direction)
			bolt.Parent = fxFolder()
			projectiles[id] = { Part = bolt, Color = color, Origin = origin, Direction = direction, Speed = speed, Range = range, Start = os.clock(), Style = style, Aligned = aligned, Tail = tail }
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
	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for id, projectile in projectiles do
			local traveled = projectile.Speed * (now - projectile.Start)
			if traveled >= projectile.Range then
				endProjectile(id, nil, "Expired")
			else
				local at = projectile.Origin + projectile.Direction * traveled
				projectile.Part.CFrame = CFrame.lookAt(at, at + projectile.Direction)
				if projectile.Aligned then
					alignStreaks(projectile.Aligned, at, projectile.Direction)
				end
				if projectile.Tail then
					-- +Z is behind the part (it looks along the flight); never behind the muzzle.
					projectile.Tail.Position = Vector3.new(0, 0, math.min(traveled, BOLT_LENGTH))
				end
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
