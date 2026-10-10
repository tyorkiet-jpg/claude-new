-- Abyssal Stormfin AI (server). Each fin runs a loop: swim to reposition under the surface
-- (can't be damaged) -> Thunder Breach (a parryable leap at the player) or Storm Bolt (hover, charge,
-- fire a reflectable bolt; the throat is a weak point while charging) -> dive -> repeat.
-- Motion is a chain of StormfinMotion segments broadcast to clients; the server moves an invisible
-- hitbox along the same path and decides every hit, parry and point of damage. Each new segment
-- starts from the fin's current position and velocity, so momentum carries between phases.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config.StormfinConfig)
local Motion = require(ReplicatedStorage.Shared.StormfinMotion)
local CombatService = require(script.Parent.CombatService)
local ParryService = require(script.Parent.ParryService)
local ProjectileService = require(script.Parent.ProjectileService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Event = Remotes:WaitForChild("StormfinEvent")

local StormfinService = {}

type Segment = Motion.Segment
type Fin = {
	Id: number,
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Throat: BasePart,
	Segment: Segment,
	Alive: boolean,
	Interrupted: boolean, -- a parry stagger (or death) owns the motion; the AI loop waits
	History: { string },
	PatternStep: number, -- next index into Config.Pattern
}

local UP = Vector3.yAxis
local random = Random.new()
local fins: { [number]: Fin } = {}
local nextId = 0
local lastAttackStart = -math.huge
local folder: Folder

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-3 then v.Unit else fallback
end

local function evaluate(fin: Fin): (Vector3, Vector3)
	local position, forward = Motion.Evaluate(fin.Segment, now())
	return position, forward
end

-- Server time, position, facing and velocity of the fin right now (a new segment starts from these).
local function state(fin: Fin): (number, Vector3, Vector3, Vector3)
	local t = now()
	local position, forward = Motion.Evaluate(fin.Segment, t)
	return t, position, forward, Motion.Velocity(fin.Segment, t)
end

-- Starts a new motion segment. The AI loop can't replace a stagger/death sequence (force = false).
local function setSegment(fin: Fin, segment: Segment, force: boolean?): boolean
	if not force and (fin.Interrupted or not fin.Alive) then
		return false
	end
	fin.Segment = segment
	Event:FireAllClients("Segment", fin.Id, segment)
	return true
end

-- Yields until `segment` finishes. False if it was replaced (stagger, death) first.
local function waitSegment(fin: Fin, segment: Segment, untilTime: number?): boolean
	local finish = untilTime or (segment.Start + segment.Duration)
	while fin.Segment == segment and now() < finish do
		RunService.Heartbeat:Wait()
	end
	return fin.Segment == segment and fin.Alive
end

local function targetFor(fin: Fin): (Player?, BasePart?)
	local position = evaluate(fin)
	local best, bestRoot, bestDistance = nil, nil, Config.AggroRange
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and root and humanoid.Health > 0 then
			local distance = flat(root.Position - position).Magnitude
			if distance < bestDistance then
				best, bestRoot, bestDistance = player, root, distance
			end
		end
	end
	return best, bestRoot
end

-------------------------------------------------------------------------------- movement phases

local function swimTo(fin: Fin, destination: Vector3): Segment?
	local t, position, _, velocity = state(fin)
	local segment = Motion.Swim(t, position, velocity, destination, if random:NextNumber() < 0.5 then 1 else -1)
	return if setSegment(fin, segment) then segment else nil
end

-- A point KeepDistance from the target, swung round from the fin's current bearing (curved paths,
-- never straight at the player).
local function repositionPoint(fin: Fin, targetPosition: Vector3): Vector3
	local position = evaluate(fin)
	local away = flat(position - targetPosition)
	local bearing = if away.Magnitude > 0.1 then math.atan2(away.Z, away.X) else random:NextNumber(0, 2 * math.pi)
	local swing = math.rad(random:NextNumber(40, 110)) * (if random:NextNumber() < 0.5 then 1 else -1)
	local distance = random:NextNumber(Config.Swim.KeepDistance[1], Config.Swim.KeepDistance[2])
	return targetPosition + Vector3.new(math.cos(bearing + swing), 0, math.sin(bearing + swing)) * distance
end

-- Swims, but cuts the swim short when a player camps right on top of it. Returns true if camped.
local function swimWatching(fin: Fin, segment: Segment?, targetRoot: BasePart?): boolean
	if not segment then
		return false
	end
	while fin.Segment == segment and now() < segment.Start + segment.Duration do
		if targetRoot and targetRoot.Parent then
			local position = evaluate(fin)
			if flat(targetRoot.Position - position).Magnitude < Config.Swim.AntiCampRange then
				return true
			end
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

local function dive(fin: Fin, force: boolean?): Segment?
	local t, position, forward, velocity = state(fin)
	local segment = Motion.Dive(t, position, forward, velocity)
	return if setSegment(fin, segment, force) then segment else nil
end

-- A parried breach knocks the fin back, leaves it floundering on the surface (open to fire), then
-- it dives. Runs outside the AI loop, which waits while Interrupted.
local function stagger(fin: Fin, away: Vector3)
	if not fin.Alive or fin.Interrupted then
		return
	end
	fin.Interrupted = true
	task.spawn(function()
		local t, position = state(fin)
		local knock = Motion.Stagger(t, position, away)
		setSegment(fin, knock, true)
		if waitSegment(fin, knock) then
			local t2, landed, _, velocity = state(fin)
			local stun = Motion.Stun(t2, landed, velocity, away)
			setSegment(fin, stun, true)
			if waitSegment(fin, stun) then
				local down = dive(fin, true)
				if down then
					waitSegment(fin, down)
				end
			end
		end
		if fin.Alive then
			fin.Interrupted = false
		end
	end)
end

-------------------------------------------------------------------------------- attacks

local function chooseAttack(fin: Fin): string
	-- Fixed pattern (dive, dive, dive, shoot), looped per fin.
	local pattern = Config.Pattern
	if pattern and #pattern > 0 then
		local kind = pattern[(fin.PatternStep - 1) % #pattern + 1]
		fin.PatternStep += 1
		return kind
	end

	local history = fin.History
	local count = #history
	if count >= Config.MaxRepeat then
		local last = history[count]
		local repeated = true
		for i = count - Config.MaxRepeat + 1, count do
			if history[i] ~= last then
				repeated = false
			end
		end
		if repeated then
			return if last == "Breach" then "Bolt" else "Breach"
		end
	end
	local total = Config.Breach.Weight + Config.Bolt.Weight
	return if random:NextNumber(0, total) < Config.Breach.Weight then "Breach" else "Bolt"
end

local function damagePlayer(fin: Fin, player: Player, character: Model, humanoid: Humanoid, amount: number, position: Vector3, parryable: boolean, onParried: () -> ())
	local attack = { Parryable = parryable, Attacker = fin.Model, Position = position }
	ParryService.ResolveHit(player, attack, function(parried)
		if parried then
			Remotes.EnemyAttack:FireAllClients(fin.Model, "Parried")
			onParried()
		elseif humanoid.Health > 0 then
			CombatService.ApplyDamage(humanoid, amount, nil)
			Remotes.EnemyAttack:FireAllClients(fin.Model, "Hit", character)
		end
	end)
end

-- Thunder Breach: it glides on to a stop over the launch spot while crackling ripples mark it; it
-- locks onto the player's position just before launch (no midair homing) and leaps through it
-- under gravity, splashing down past them and gliding on underwater.
local function breach(fin: Fin, targetRoot: BasePart)
	local settings = Config.Breach
	local t, start, _, velocity = state(fin)
	local windup = Motion.Windup(t, start, velocity, targetRoot.Position, settings.Parryable)
	if not setSegment(fin, windup) then
		return
	end
	local launch = windup.B :: Vector3
	local look = windup.Look :: Vector3
	if not waitSegment(fin, windup, windup.Start + settings.Windup - settings.CommitBefore) then
		return
	end
	local aim = if targetRoot.Parent then targetRoot.Position + UP * (settings.AimHeight - 3) else launch + look * 14 + UP * 3
	if not waitSegment(fin, windup) then
		return
	end

	local t2, from = state(fin)
	local leap = Motion.Leap(t2, from, aim, look)
	if not setSegment(fin, leap) then
		return
	end
	local direction = unitOr(flat(leap.V :: Vector3), look)

	-- Hits only while it is out of the water (plus a moment as it splashes down).
	local airborne = leap.Start + Motion.EntryTime(leap) + 0.1
	local alreadyHit: { [Player]: boolean } = {}
	while fin.Segment == leap and now() < airborne do
		local position, forward = evaluate(fin)
		local head = position + forward * (Config.BodyLength * 0.3)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if character and humanoid and root and humanoid.Health > 0 and not alreadyHit[player] then
				-- Capsule from the head back to HitBack along the body: the front of the fish hits,
				-- a brush from the tail doesn't.
				local tail = position - forward * (Config.BodyLength * settings.HitBack)
				local segment = head - tail
				local along = math.clamp((root.Position - tail):Dot(segment) / segment:Dot(segment), 0, 1)
				if (root.Position - (tail + segment * along)).Magnitude <= settings.HitRadius then
					alreadyHit[player] = true
					damagePlayer(fin, player, character, humanoid, settings.Damage, head, settings.Parryable, function()
						stagger(fin, -unitOr(flat(forward), direction))
					end)
				end
			end
		end
		RunService.Heartbeat:Wait()
	end
	waitSegment(fin, leap) -- the underwater glide
end

local function reflectBolt(player: Player, character: Model, from: Vector3, fin: Fin)
	local settings = Config.Bolt
	local target = evaluate(fin)
	local direction = unitOr(target - from, -Vector3.zAxis)
	local id = ProjectileService.NewVisualId()
	-- Drawn as the same Storm Bolt, in the reflecting player's attack colour.
	Remotes.EnemyProjectile:FireAllClients("Fire", id, from, direction, settings.ReflectSpeed, settings.Range, "ReflectedStormBolt")
	ProjectileService.Fire({
		OwnerCharacter = character,
		Origin = from,
		Direction = direction,
		Speed = settings.ReflectSpeed,
		Range = settings.Range,
		Radius = settings.Radius,
		OnHit = function(result: RaycastResult)
			local humanoid, model = CombatService.GetHumanoidFromPart(result.Instance)
			if model and Players:GetPlayerFromCharacter(model) then
				return "pass", model
			end
			Remotes.EnemyProjectile:FireAllClients("End", id, result.Position, if humanoid then "Contact" else "World")
			if humanoid and humanoid.Health > 0 then
				local dealt, killed = CombatService.ApplyDamage(humanoid, settings.ReflectDamage, player)
				if dealt > 0 then
					Remotes.HitConfirm:FireClient(player, result.Position, dealt, false, killed)
				end
			end
			return "stop"
		end,
	})
end

local function fireBolt(fin: Fin, origin: Vector3, targetPosition: Vector3)
	local settings = Config.Bolt
	local direction = unitOr(targetPosition - origin, -Vector3.zAxis)
	local id = ProjectileService.NewVisualId()
	Remotes.EnemyProjectile:FireAllClients("Fire", id, origin, direction, settings.Speed, settings.Range, "StormBolt")
	ProjectileService.Fire({
		OwnerCharacter = fin.Model,
		Origin = origin,
		Direction = direction,
		Speed = settings.Speed,
		Range = settings.Range,
		Radius = settings.Radius,
		OnHit = function(result: RaycastResult)
			local humanoid, model = CombatService.GetHumanoidFromPart(result.Instance)
			local player = model and Players:GetPlayerFromCharacter(model)
			if humanoid and model and not player then
				return "pass", model -- other enemies don't block it
			end
			Remotes.EnemyProjectile:FireAllClients("End", id, result.Position, if player then "Contact" else "World")
			if player and humanoid and model and humanoid.Health > 0 then
				damagePlayer(fin, player, model, humanoid, settings.Damage, result.Position, settings.Parryable, function()
					if settings.Reflectable and fin.Alive then
						reflectBolt(player, model, result.Position, fin)
					end
				end)
			end
			return "stop"
		end,
	})
end

-- Storm Bolt: springs up out of the water, hovers (the main window to shoot it), charges with the
-- throat exposed, fires at where the player is (no homing), stays open briefly, then dives.
local function bolt(fin: Fin, targetRoot: BasePart)
	local settings = Config.Bolt
	local t, start, _, velocity = state(fin)
	local spot = flat(start)
	local toTarget = flat(targetRoot.Position) - spot
	if toTarget.Magnitude < 12 then
		spot = flat(targetRoot.Position) - unitOr(toTarget, Vector3.xAxis) * 12 -- don't hover on top of them
	end
	local hoverPoint = spot + UP * (Config.SurfaceY + random:NextNumber(settings.HoverHeight[1], settings.HoverHeight[2]))
	local look = unitOr(flat(targetRoot.Position - hoverPoint), Vector3.xAxis)

	local rise = Motion.Rise(t, start, velocity, hoverPoint, look)
	if not setSegment(fin, rise) or not waitSegment(fin, rise) then
		return
	end
	local t2, risen, _, riseVelocity = state(fin)
	local hover = Motion.Hover(t2, risen, riseVelocity, hoverPoint, look, {
		ChargeStart = settings.ChargeStart,
		ChargeTime = settings.ChargeTime,
		Parryable = settings.Parryable,
	})
	if not setSegment(fin, hover) then
		return
	end
	local fireAt = hover.Start + settings.ChargeStart + settings.ChargeTime
	if not waitSegment(fin, hover, fireAt) then
		return
	end
	if targetRoot.Parent then
		-- From the mouth where it is right now (the hover drifts), so the bolt leaves the fish's mouth.
		local position, forward = evaluate(fin)
		fireBolt(fin, position + forward * (Config.BodyLength * 0.45), targetRoot.Position)
	end
	if not waitSegment(fin, hover) then
		return
	end
	local down = dive(fin)
	if down then
		waitSegment(fin, down)
	end
end

-------------------------------------------------------------------------------- lifecycle

local function runAI(fin: Fin)
	while fin.Alive do
		if fin.Interrupted then
			RunService.Heartbeat:Wait()
			continue
		end
		local _, targetRoot = targetFor(fin)
		if not targetRoot then
			-- Nobody in range: circle lazily around the spawn area.
			local angle = random:NextNumber(0, 2 * math.pi)
			local idle = Config.SpawnCenter + Vector3.new(math.cos(angle), 0, math.sin(angle)) * Config.Swim.IdleRadius * 2
			local segment = swimTo(fin, idle)
			if segment then
				waitSegment(fin, segment)
			end
			continue
		end

		local camped = swimWatching(fin, swimTo(fin, repositionPoint(fin, targetRoot.Position)), targetRoot)
		-- Stagger attacks across fins so players aren't hit by several at once.
		while fin.Alive and not fin.Interrupted and not camped and os.clock() - lastAttackStart < Config.AttackStagger do
			camped = swimWatching(fin, swimTo(fin, repositionPoint(fin, targetRoot.Position)), targetRoot)
		end
		if not fin.Alive or fin.Interrupted then
			continue
		end
		_, targetRoot = targetFor(fin)
		if not targetRoot then
			continue
		end

		lastAttackStart = os.clock()
		local kind = chooseAttack(fin)
		table.insert(fin.History, kind)
		if #fin.History > 6 then
			table.remove(fin.History, 1)
		end
		if kind == "Breach" then
			breach(fin, targetRoot)
		else
			bolt(fin, targetRoot)
		end
	end
end

local spawnFin: () -> ()

local function die(fin: Fin)
	if not fin.Alive then
		return
	end
	fin.Alive = false
	fin.Interrupted = true
	local t, position, forward, velocity = state(fin)
	local death = Motion.Death(t, position, forward, velocity)
	local duration = death.Duration
	setSegment(fin, death, true)
	Event:FireAllClients("Death", fin.Id)
	task.delay(duration + 0.2, function()
		fins[fin.Id] = nil
		Event:FireAllClients("Despawn", fin.Id)
		fin.Model:Destroy()
	end)
	task.delay(duration + Config.RespawnDelay, spawnFin)
end

local function hitboxPart(name: string, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = false
	part.Transparency = 1
	return part
end

spawnFin = function()
	if not Config.Enabled then
		return
	end
	nextId += 1
	local id = nextId
	local angle = random:NextNumber(0, 2 * math.pi)
	local radius = random:NextNumber(Config.SpawnRadius[1], Config.SpawnRadius[2])
	local position = Config.SpawnCenter + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
	position = flat(position) + UP * Config.SwimDepth

	local model = Instance.new("Model")
	model.Name = "Stormfin"
	local root = hitboxPart("HumanoidRootPart", Config.HitboxSize)
	root.CFrame = CFrame.new(position)
	root.Parent = model
	local throat = hitboxPart("Throat", Config.ThroatSize)
	throat:SetAttribute("WeakPointMultiplier", Config.WeakPointMultiplier)
	throat.CFrame = root.CFrame * CFrame.new(Config.ThroatOffset)
	throat.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.EvaluateStateMachine = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.MaxHealth = Config.Health
	humanoid.Health = Config.Health
	humanoid.Parent = model
	model:SetAttribute("StormfinId", id)
	model:SetAttribute("Invulnerable", true)
	model.Parent = folder

	local fin: Fin = {
		Id = id,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Throat = throat,
		Segment = Motion.Still(now(), position),
		Alive = true,
		Interrupted = false,
		History = {},
		PatternStep = 1,
	}
	fins[id] = fin
	Event:FireAllClients("Spawn", id, model)
	Event:FireAllClients("Segment", id, fin.Segment)

	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		if health < lastHealth then
			Event:FireAllClients("Hit", id)
		end
		lastHealth = health
		if health <= 0 then
			die(fin)
		end
	end)
	task.spawn(runAI, fin)
end

-- Keeps every hitbox on its fin's path and the damage state in sync with it.
local function update()
	local t = now()
	for _, fin in fins do
		local position, forward = Motion.Evaluate(fin.Segment, t)
		local cframe = Motion.CFrame(position, forward)
		fin.Root.CFrame = cframe
		fin.Throat.CFrame = cframe * CFrame.new(Config.ThroatOffset)
		fin.Model:SetAttribute("Invulnerable", not fin.Alive or position.Y < Config.SubmergedBelow)
		local segment = fin.Segment
		local open = false
		if segment.Kind == "Hover" and segment.Extra then
			local elapsed = t - segment.Start
			open = elapsed >= segment.Extra.ChargeStart and elapsed < segment.Extra.ChargeStart + segment.Extra.ChargeTime
		end
		fin.Model:SetAttribute("WeakPointOpen", open)
	end
end

function StormfinService.Init()
	folder = workspace:FindFirstChild("Enemies") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Enemies"
		folder.Parent = workspace
	end
	RunService.Heartbeat:Connect(update)
	-- Clients joining late ask for the fins that already exist.
	Event.OnServerEvent:Connect(function(player, request)
		if request ~= "Sync" then
			return
		end
		for id, fin in fins do
			Event:FireClient(player, "Spawn", id, fin.Model)
			Event:FireClient(player, "Segment", id, fin.Segment)
			if not fin.Alive then
				Event:FireClient(player, "Death", id)
			end
		end
	end)
	if Config.Enabled then
		for _ = 1, Config.Count do
			spawnFin()
		end
	end
end

return StormfinService
