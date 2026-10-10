-- Abyssal Stalker AI (server). A fast four-legged predator that hunts players across the sea
-- surface: idle patrol near its spawn -> chase (smooth turning, whisker steering round obstacles,
-- spreading round the target with the rest of the pack) -> Rending Bite / Hunter's Lunge /
-- Predator's Frenzy -> a short reposition -> chase again.
-- The server owns targeting, movement, attack choice, hit checks, damage and parry resolution
-- (ParryService.ResolveHit). It moves an invisible hitbox model in Workspace/Enemies (a Humanoid,
-- a body "HumanoidRootPart" and a "Head" part, plus attachments named after Config.Points) and
-- publishes what it is doing through attributes; clients draw and animate the creature
-- (StalkerVisuals). Attacks only use the named points, never placeholder body parts.
--
-- Attributes on the model: Action ("" | Bite | Lunge | Frenzy | Recoil | Stagger | Death),
-- ActionStart (server time), ActionStep (Lunge: 1 windup, 2 flight, 3 landing; Frenzy: strike
-- 1-3), ActionPoint + ActionStrike (the named point to telegraph and the server time the hit
-- commits), ActionSeq (bumped last on every change), Leap* (the lunge's flight), ParrySeq (a
-- frenzy strike was parried).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config.StalkerConfig)
local ParryConfig = require(ReplicatedStorage.Shared.Config.ParryConfig)
local CombatService = require(script.Parent.CombatService)
local ParryService = require(script.Parent.ParryService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local StalkerService = {}

type Leap = { From: Vector3, To: Vector3, Start: number, Duration: number, Height: number }
type Stalker = {
	Id: number,
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Head: BasePart,
	Spawn: Vector3,
	Position: Vector3, -- on the floor (Y = floor height)
	Heading: Vector3, -- flat unit
	Speed: number, -- along Heading
	Lift: number, -- height above its standing height (lunges)
	LiftVelocity: number,
	Motion: string, -- "Steer" (to Goal) | "Fixed" (attacking: turns toward Face, drifts at StepSpeed) | "Lunge" | "Knock"
	Goal: Vector3,
	GoalSpeed: number,
	Face: BasePart?,
	FacePoint: Vector3?,
	TurnRate: number,
	StepSpeed: number,
	Knock: Vector3,
	Leap: Leap?,
	Target: Player?,
	Token: number, -- bumped by every interruption (parry recoil, stagger, death): attack code checks it
	BusyUntil: number, -- recoiling or staggered until then
	NextAttack: number,
	LungeReady: number,
	FrenzyReady: number,
	HoldsToken: Player?, -- counted as one of the (at most MaxAttackers) attackers of this player
	Alive: boolean,
	ActionSeq: number,
	ParrySeq: number,
}

local UP = Vector3.yAxis
local random = Random.new()
local stalkers: { [number]: Stalker } = {}
local attackers: { [Player]: number } = {}
local nextId = 0
local folder: Folder
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-3 then v.Unit else fallback
end

local function range(r: { number }): number
	return random:NextNumber(r[1], r[2])
end

-- Signed angle from flat unit a to flat unit b (positive = counterclockwise seen from above).
local function signedAngle(a: Vector3, b: Vector3): number
	return math.atan2(a:Cross(b).Y, a:Dot(b))
end

-- Turns flat unit `heading` toward `toward` by at most `maxStep` radians; also returns how far off it was.
local function turn(heading: Vector3, toward: Vector3, maxStep: number): (Vector3, number)
	local angle = signedAngle(heading, toward)
	local step = math.clamp(angle, -maxStep, maxStep)
	return CFrame.fromAxisAngle(UP, step):VectorToWorldSpace(heading), math.abs(angle)
end

local function refreshFilter()
	local list: { Instance } = { folder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function floorAt(position: Vector3): number
	local hit = workspace:Raycast(position + UP * 6, Vector3.new(0, -40, 0), rayParams)
	return if hit then hit.Position.Y else position.Y
end

local function characterOf(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if character and humanoid and root and humanoid.Health > 0 then
		return character, humanoid, root
	end
	return nil, nil, nil
end

local function waitUntil(s: Stalker, token: number, untilTime: number): boolean
	while s.Alive and s.Token == token and now() < untilTime do
		RunService.Heartbeat:Wait()
	end
	return s.Alive and s.Token == token
end

local function setAction(s: Stalker, action: string, point: string?, strike: number?, step: number?)
	local model = s.Model
	model:SetAttribute("ActionPoint", point or "")
	model:SetAttribute("ActionStrike", strike or 0)
	model:SetAttribute("ActionStep", step or 0)
	model:SetAttribute("ActionStart", now())
	model:SetAttribute("Action", action)
	s.ActionSeq += 1
	model:SetAttribute("ActionSeq", s.ActionSeq)
end

-------------------------------------------------------------------------------- pack

local function releaseToken(s: Stalker)
	local player = s.HoldsToken
	if player then
		s.HoldsToken = nil
		attackers[player] = math.max((attackers[player] or 1) - 1, 0)
	end
end

local function takeToken(s: Stalker, player: Player): boolean
	if (attackers[player] or 0) >= Config.Pack.MaxAttackers then
		return false
	end
	attackers[player] = (attackers[player] or 0) + 1
	s.HoldsToken = player
	return true
end

-- The nearest player in range; keeps its current target unless another is clearly closer.
local function chooseTarget(s: Stalker): (Player?, BasePart?)
	local current, currentDistance = nil, math.huge
	if s.Target then
		local _, _, root = characterOf(s.Target)
		if root then
			local distance = flat(root.Position - s.Position).Magnitude
			if distance <= Config.LoseRange then
				current, currentDistance = s.Target, distance
			end
		end
	end
	local best, bestDistance = nil, Config.DetectRange
	for _, player in Players:GetPlayers() do
		local _, _, root = characterOf(player)
		if root then
			local distance = flat(root.Position - s.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = player, distance
			end
		end
	end
	if current and (best == nil or best == current or bestDistance > currentDistance * Config.SwitchMargin) then
		best = current
	end
	if best ~= s.Target then
		releaseToken(s)
	end
	s.Target = best
	if best then
		local _, _, root = characterOf(best)
		return best, root
	end
	return nil, nil
end

-- Where a Stalker heads for: a bearing round the target, spread from the rest of the pack hunting
-- the same player (sorted by their current bearings, so they never cross over) so they close in
-- from different sides.
local function approachPoint(s: Stalker, player: Player, target: Vector3, standoff: number): Vector3
	local function bearingOf(position: Vector3): number
		local offset = flat(position - target)
		return math.atan2(offset.Z, offset.X)
	end
	local pack = {}
	for _, other in stalkers do
		if other.Alive and other.Target == player then
			table.insert(pack, { Stalker = other, Bearing = bearingOf(other.Position) })
		end
	end
	local bearing = bearingOf(s.Position)
	if #pack > 1 then
		local sx, sz = 0, 0
		for _, entry in pack do
			sx += math.cos(entry.Bearing)
			sz += math.sin(entry.Bearing)
		end
		local mean = math.atan2(sz, sx)
		local function relative(b: number): number
			return (b - mean + math.pi) % (2 * math.pi) - math.pi
		end
		table.sort(pack, function(a, b)
			return relative(a.Bearing) < relative(b.Bearing)
		end)
		for i, entry in pack do
			if entry.Stalker == s then
				bearing = mean + math.rad(Config.Pack.SlotSpread) * (i - (#pack + 1) / 2)
			end
		end
	end
	return flat(target) + Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * standoff
end

-------------------------------------------------------------------------------- movement

local function steer(s: Stalker, dt: number)
	local move = Config.Move
	local toGoal = flat(s.Goal - s.Position)
	local distance = toGoal.Magnitude
	local want = if distance > 0.3 then toGoal / distance else s.Heading
	-- Keep apart from the rest of the pack.
	local push = Vector3.zero
	for _, other in stalkers do
		if other ~= s and other.Alive then
			local away = flat(s.Position - other.Position)
			local d = away.Magnitude
			if d < move.Separation and d > 1e-3 then
				push += away / d * (1 - d / move.Separation)
			end
		end
	end
	want = unitOr(want + push * move.SeparationStrength, want)
	-- Steer round obstacles: a whisker ahead; when it hits a wall, slide along it.
	local hit = workspace:Raycast(s.Position + UP * Config.BodyHeight, s.Heading * move.AvoidDistance, rayParams)
	if hit and hit.Normal.Y < 0.5 then
		local normal = unitOr(flat(hit.Normal), -s.Heading)
		want = unitOr(want - normal * want:Dot(normal) + normal * 0.5, normal)
	end
	local angle
	s.Heading, angle = turn(s.Heading, want, move.TurnRate * dt)
	-- Slows to turn hard, and eases in as it arrives.
	local target = s.GoalSpeed * math.clamp(1 - angle / move.SlowTurnAngle, 0.25, 1) * math.clamp(distance / 4, 0, 1)
	local rate = if target > s.Speed then move.Accel else move.Decel
	s.Speed += math.clamp(target - s.Speed, -rate * dt, rate * dt)
end

local function holdMotion(s: Stalker, dt: number)
	local face = if s.Face and s.Face.Parent then flat(s.Face.Position - s.Position) elseif s.FacePoint then flat(s.FacePoint - s.Position) else nil
	if face and face.Magnitude > 0.2 then
		s.Heading = turn(s.Heading, face.Unit, s.TurnRate * dt)
	end
	-- Presses forward while attacking, but never on top of its target.
	local step = s.StepSpeed
	if s.Target then
		local _, _, root = characterOf(s.Target)
		if root and flat(root.Position - s.Position).Magnitude < Config.CloseDistance then
			step = 0
			s.Speed = math.min(s.Speed, 0)
		end
	end
	s.Speed += math.clamp(step - s.Speed, -120 * dt, 120 * dt)
end

local function update(dt: number)
	refreshFilter()
	local t = now()
	for _, s in stalkers do
		local leap = s.Leap
		if s.Motion == "Lunge" and leap then
			local u = math.clamp((t - leap.Start) / leap.Duration, 0, 1)
			s.Position = leap.From:Lerp(leap.To, u)
			s.Lift = 4 * leap.Height * u * (1 - u)
			s.LiftVelocity = 4 * leap.Height * (1 - 2 * u) / leap.Duration
		else
			if s.Motion == "Steer" then
				steer(s, dt)
			elseif s.Motion == "Fixed" then
				holdMotion(s, dt)
			end
			if s.Motion == "Knock" then
				s.Position += s.Knock * dt
				s.Knock *= math.exp(-4 * dt)
			elseif s.Speed > 0.05 then
				-- Never walks into a wall.
				local blocked = workspace:Raycast(s.Position + UP * Config.BodyHeight, s.Heading * (s.Speed * dt + 1.6), rayParams)
				if blocked and blocked.Normal.Y < 0.5 then
					s.Speed = 0
				else
					s.Position += s.Heading * (s.Speed * dt)
				end
			end
			-- Falls back down (out of an interrupted lunge).
			if s.Lift > 0 or s.LiftVelocity > 0 then
				s.LiftVelocity -= Config.Gravity * dt
				s.Lift = math.max(s.Lift + s.LiftVelocity * dt, 0)
				if s.Lift <= 0 then
					s.LiftVelocity = 0
				end
			end
		end
	end
	-- Bodies never overlap, whatever they are doing (steering only spreads them while they run).
	local gap = Config.Move.MinGap
	for _, s in stalkers do
		if s.Alive and s.Motion ~= "Lunge" then
			for _, other in stalkers do
				if other ~= s and other.Alive then
					local away = flat(s.Position - other.Position)
					local d = away.Magnitude
					if d < gap then
						local dir = if d > 1e-3 then away / d else Vector3.new(math.cos(s.Id), 0, math.sin(s.Id))
						s.Position += dir * math.min((gap - d) * 0.5, 20 * dt)
					end
				end
			end
		end
	end
	for _, s in stalkers do
		s.Position = Vector3.new(s.Position.X, floorAt(s.Position), s.Position.Z)
		local centre = s.Position + UP * (Config.BodyHeight + s.Lift)
		s.Root.CFrame = CFrame.lookAt(centre, centre + s.Heading)
		s.Head.CFrame = s.Root.CFrame * CFrame.new(Config.Points.Head)
	end
end

-------------------------------------------------------------------------------- attacks

local function damagePlayer(s: Stalker, player: Player, character: Model, humanoid: Humanoid, amount: number, position: Vector3, parryable: boolean, onResolved: ((parried: boolean) -> ())?)
	ParryService.ResolveHit(player, { Parryable = parryable, Attacker = s.Model, Position = position }, function(parried)
		if parried then
			Remotes.EnemyAttack:FireAllClients(s.Model, "Parried")
		elseif humanoid.Health > 0 then
			CombatService.ApplyDamage(humanoid, amount, nil)
			Remotes.EnemyAttack:FireAllClients(s.Model, "Hit", character)
		end
		if onResolved then
			onResolved(parried)
		end
	end)
end

-- The hitbox: every frame for `duration`, a capsule of `radius` (plus about half a character's
-- width) from the chest out to the named point, so a player right in its face is struck as well
-- as one at full reach. Each player is struck once. Stops early if interrupted.
local function strikeWindow(s: Stalker, token: number, point: string, radius: number, duration: number, onContact: (Player, Model, Humanoid, Vector3) -> ())
	local struck: { [Player]: boolean } = {}
	local untilTime = now() + duration
	repeat
		local origin = s.Root.CFrame * Config.Points[point]
		local chest = s.Root.CFrame * Vector3.new(0, 0, -Config.HitboxSize.Z * 0.35)
		local reach = origin - chest
		for _, player in Players:GetPlayers() do
			if not struck[player] then
				local character, humanoid, root = characterOf(player)
				local along = if root then math.clamp((root.Position - chest):Dot(reach) / math.max(reach:Dot(reach), 1e-3), 0, 1) else 0
				if character and humanoid and root and (root.Position - (chest + reach * along)).Magnitude <= radius + 1 then
					struck[player] = true
					onContact(player, character, humanoid, origin)
				end
			end
		end
		RunService.Heartbeat:Wait()
	until not (s.Alive and s.Token == token and now() < untilTime)
end

-- A parried bite or lunge (or the frenzy stagger): knocked back, out of action for `duration`.
local function interrupt(s: Stalker, action: string, duration: number, knock: number)
	if not s.Alive then
		return
	end
	s.Token += 1
	s.Leap = nil
	s.Motion = "Knock"
	s.Knock = -s.Heading * knock
	s.Speed = 0
	s.Face, s.FacePoint = nil, nil
	s.BusyUntil = now() + duration
	releaseToken(s)
	setAction(s, action)
end

local function recoil(s: Stalker)
	interrupt(s, "Recoil", Config.Recoil.Time, Config.Recoil.Speed)
end

-- Rending Bite: head pulls back (telegraph), the jaws snap forward through BiteOrigin, recovery.
local function bite(s: Stalker, token: number, root: BasePart)
	local cfg = Config.Bite
	s.Motion, s.Face, s.TurnRate, s.StepSpeed = "Fixed", root, Config.Move.AttackTurnRate, 0
	local strike = now() + cfg.Windup
	setAction(s, "Bite", "BiteOrigin", strike, 1)
	if not waitUntil(s, token, strike) then
		return
	end
	s.Face = nil -- committed
	s.Speed = cfg.Snap
	strikeWindow(s, token, "BiteOrigin", cfg.HitRadius, cfg.Active, function(player, character, humanoid, origin)
		damagePlayer(s, player, character, humanoid, cfg.Damage, origin, cfg.Parryable, function(parried)
			if parried then
				recoil(s)
			end
		end)
	end)
	waitUntil(s, token, now() + cfg.Recovery)
end

-- Hunter's Lunge: crouch (telegraph), lock onto the target's position CommitBefore seconds before
-- launch, then leap there in a fixed arc (no steering in the air) and recover on landing.
local function lunge(s: Stalker, token: number, root: BasePart)
	local cfg = Config.Lunge
	s.LungeReady = now() + cfg.Cooldown
	s.Motion, s.Face, s.TurnRate, s.StepSpeed = "Fixed", root, Config.Move.AttackTurnRate, 0
	local launch = now() + cfg.Windup
	setAction(s, "Lunge", "Head", launch, 1)
	if not waitUntil(s, token, launch - cfg.CommitBefore) then
		return
	end
	local aim = if root.Parent then flat(root.Position) else s.Position + s.Heading * cfg.MaxDistance
	s.Face, s.FacePoint, s.TurnRate = nil, aim, 10 -- lines up on the locked point
	if not waitUntil(s, token, launch) then
		return
	end
	s.FacePoint = nil
	local from = s.Position
	local toAim = flat(aim - from)
	local direction = unitOr(toAim, s.Heading)
	local distance = math.clamp(toAim.Magnitude + cfg.Overshoot, 3, cfg.MaxDistance)
	local eye = from + UP * Config.BodyHeight
	local blocked = workspace:Raycast(eye, direction * (distance + 2), rayParams)
	if blocked and blocked.Normal.Y < 0.5 then
		distance = math.max((blocked.Position - eye).Magnitude - 2.5, 0.5)
	end
	local span = cfg.FlightTime[2] - cfg.FlightTime[1]
	local leap: Leap = {
		From = from,
		To = from + direction * distance,
		Start = now(),
		Duration = cfg.FlightTime[1] + span * math.clamp(distance / cfg.MaxDistance, 0, 1),
		Height = cfg.Height,
	}
	s.Heading, s.Speed, s.Leap, s.Motion = direction, 0, leap, "Lunge"
	local model = s.Model
	model:SetAttribute("LeapFrom", leap.From)
	model:SetAttribute("LeapTo", leap.To)
	model:SetAttribute("LeapStart", leap.Start)
	model:SetAttribute("LeapDuration", leap.Duration)
	model:SetAttribute("LeapHeight", leap.Height)
	setAction(s, "Lunge", "", 0, 2)
	strikeWindow(s, token, "Head", cfg.HitRadius, leap.Duration, function(player, character, humanoid, origin)
		damagePlayer(s, player, character, humanoid, cfg.Damage, origin, cfg.Parryable, function(parried)
			if parried then
				recoil(s)
			end
		end)
	end)
	if s.Token ~= token then
		return
	end
	s.Leap, s.Motion, s.Lift, s.LiftVelocity = nil, "Fixed", 0, 0
	s.Position = leap.To
	setAction(s, "Lunge", "", 0, 3)
	waitUntil(s, token, now() + cfg.Recovery)
end

-- Predator's Frenzy: left swipe, right swipe, bite, each with its own windup and telegraph and
-- resolved on its own. Parrying one strike doesn't end the combo; parrying all three staggers it.
local function frenzy(s: Stalker, token: number, root: BasePart)
	local cfg = Config.Frenzy
	s.FrenzyReady = now() + cfg.Cooldown
	s.Motion, s.Face, s.TurnRate, s.StepSpeed = "Fixed", root, Config.Move.AttackTurnRate, cfg.Step
	local parried: { [number]: boolean } = {}
	local pending = 0
	for i, strike in cfg.Strikes do
		local at = now() + strike.Windup
		setAction(s, "Frenzy", strike.Point, at, i)
		if not waitUntil(s, token, at) then
			return
		end
		s.Face = nil -- committed for the strike itself
		strikeWindow(s, token, strike.Point, cfg.HitRadius, cfg.Active, function(player, character, humanoid, origin)
			pending += 1
			damagePlayer(s, player, character, humanoid, strike.Damage, origin, cfg.Parryable, function(wasParried)
				pending -= 1
				if wasParried and s.Alive then
					parried[i] = true
					s.ParrySeq += 1
					s.Model:SetAttribute("ParrySeq", s.ParrySeq) -- a flinch on the client
				end
			end)
		end)
		if s.Token ~= token then
			return
		end
		s.Face = root
		if i < #cfg.Strikes and not waitUntil(s, token, now() + cfg.Gap) then
			return
		end
	end
	s.Face, s.StepSpeed = nil, 0
	-- A hit can wait a moment for a parry press still on its way.
	local settle = now() + ParryConfig.MaxResolveDelay + 0.05
	while pending > 0 and s.Alive and s.Token == token and now() < settle do
		RunService.Heartbeat:Wait()
	end
	if s.Token ~= token then
		return
	end
	local all = true
	for i = 1, #cfg.Strikes do
		all = all and parried[i] == true
	end
	if all then
		interrupt(s, "Stagger", cfg.StaggerTime, Config.StaggerKnock)
		return
	end
	waitUntil(s, token, now() + cfg.Recovery)
end

-- Which attack fits right now, if any.
local function chooseAttack(s: Stalker, root: BasePart): string?
	local toTarget = flat(root.Position - s.Position)
	local distance = toTarget.Magnitude
	local facing = math.deg(math.abs(signedAngle(s.Heading, unitOr(toTarget, s.Heading))))
	local t = now()
	if distance <= Config.Bite.Range then
		if facing > 70 then
			return nil
		end
		if t >= s.FrenzyReady and random:NextNumber(0, Config.Bite.Weight + Config.Frenzy.Weight) < Config.Frenzy.Weight then
			return "Frenzy"
		end
		return "Bite"
	end
	local lungeCfg = Config.Lunge
	if distance >= lungeCfg.MinRange and distance <= lungeCfg.MaxRange and t >= s.LungeReady and facing <= lungeCfg.MaxAngle then
		return "Lunge"
	end
	return nil
end

-- After an attack it backs off round the target for a moment instead of attacking again at once.
local function reposition(s: Stalker, token: number, root: BasePart)
	local cfg = Config.Reposition
	local away = flat(s.Position - root.Position)
	local bearing = if away.Magnitude > 0.1 then math.atan2(away.Z, away.X) else random:NextNumber(0, 2 * math.pi)
	bearing += math.rad(range(cfg.Swing)) * (if random:NextNumber() < 0.5 then 1 else -1)
	local radius = range(cfg.Radius)
	local untilTime = now() + range(cfg.Time)
	s.Motion, s.GoalSpeed = "Steer", cfg.Speed
	repeat
		local centre = if root.Parent then flat(root.Position) else s.Position
		s.Goal = centre + Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * radius
		RunService.Heartbeat:Wait()
	until not (s.Alive and s.Token == token and now() < untilTime)
end

local function attack(s: Stalker, kind: string, player: Player, root: BasePart): boolean
	if not takeToken(s, player) then
		return false
	end
	local token = s.Token
	if kind == "Bite" then
		bite(s, token, root)
	elseif kind == "Lunge" then
		lunge(s, token, root)
	else
		frenzy(s, token, root)
	end
	releaseToken(s)
	if s.Alive and s.Token == token then
		setAction(s, "")
		reposition(s, token, root)
	end
	s.NextAttack = now() + range(Config.AttackCooldown)
	return true
end

-- Nobody around: wanders near its spawn, then stands and looks round. Returns as soon as it spots someone.
local function patrol(s: Stalker)
	local cfg = Config.Patrol
	local token = s.Token
	local angle = random:NextNumber(0, 2 * math.pi)
	s.Motion = "Steer"
	s.Goal = s.Spawn + Vector3.new(math.cos(angle), 0, math.sin(angle)) * random:NextNumber(0, cfg.Radius)
	s.GoalSpeed = cfg.Speed
	local giveUp = now() + 6
	while s.Alive and s.Token == token and now() < giveUp and flat(s.Goal - s.Position).Magnitude > 1.5 do
		if chooseTarget(s) then
			return
		end
		RunService.Heartbeat:Wait()
	end
	s.GoalSpeed = 0
	local pauseUntil = now() + range(cfg.PauseTime)
	while s.Alive and s.Token == token and now() < pauseUntil do
		if chooseTarget(s) then
			return
		end
		RunService.Heartbeat:Wait()
	end
end

local function runAI(s: Stalker)
	while s.Alive do
		if now() < s.BusyUntil then
			RunService.Heartbeat:Wait()
			continue
		end
		if s.Motion ~= "Steer" then
			s.Motion = "Steer"
			setAction(s, "")
		end
		local player, root = chooseTarget(s)
		if not player or not root then
			patrol(s)
			continue
		end
		local open = now() >= s.NextAttack and (attackers[player] or 0) < Config.Pack.MaxAttackers
		if open then
			local kind = chooseAttack(s, root)
			if kind and attack(s, kind, player, root) then
				continue
			end
		end
		-- Close in from its own side of the target; one waiting for its turn circles further out.
		local distance = flat(root.Position - s.Position).Magnitude
		local standoff = if open then 2.5 else Config.Pack.HoldDistance
		s.Goal = approachPoint(s, player, root.Position, standoff)
		s.GoalSpeed = if not open and distance < Config.Pack.HoldDistance + 4 then Config.Reposition.Speed else Config.Move.ChaseSpeed
		RunService.Heartbeat:Wait()
	end
end

-------------------------------------------------------------------------------- lifecycle

local spawnStalker: () -> ()

local function die(s: Stalker)
	if not s.Alive then
		return
	end
	s.Alive = false
	s.Token += 1
	releaseToken(s)
	s.Leap, s.Face, s.FacePoint = nil, nil, nil
	s.Motion = "Knock"
	s.Knock = s.Heading * s.Speed * 0.3
	s.Speed = 0
	setAction(s, "Death")
	task.delay(Config.DeathTime, function()
		stalkers[s.Id] = nil
		s.Model:Destroy()
	end)
	task.delay(Config.DeathTime + Config.RespawnDelay, spawnStalker)
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

spawnStalker = function()
	if not Config.Enabled then
		return
	end
	nextId += 1
	local id = nextId
	refreshFilter()
	local angle = random:NextNumber(0, 2 * math.pi)
	local spawn = Config.SpawnCenter + Vector3.new(math.cos(angle), 0, math.sin(angle)) * range(Config.SpawnRadius)
	spawn = Vector3.new(spawn.X, floorAt(spawn + UP * 20), spawn.Z)
	local heading = Vector3.new(-math.cos(angle), 0, -math.sin(angle)) -- facing the middle

	local model = Instance.new("Model")
	model.Name = "Stalker"
	local root = hitboxPart("HumanoidRootPart", Config.HitboxSize)
	root.CFrame = CFrame.lookAt(spawn + UP * Config.BodyHeight, spawn + UP * Config.BodyHeight + heading)
	root.Parent = model
	for name, offset in Config.Points do
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Position = offset
		attachment.Parent = root
	end
	local head = hitboxPart("Head", Config.HeadSize)
	head.CFrame = root.CFrame * CFrame.new(Config.Points.Head)
	head.Parent = model
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
	model:SetAttribute("StalkerId", id)
	model:SetAttribute("Action", "")
	model:SetAttribute("ActionSeq", 0)
	model:SetAttribute("ParrySeq", 0)
	model.Parent = folder

	local s: Stalker = {
		Id = id,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Head = head,
		Spawn = spawn,
		Position = spawn,
		Heading = heading,
		Speed = 0,
		Lift = 0,
		LiftVelocity = 0,
		Motion = "Steer",
		Goal = spawn,
		GoalSpeed = 0,
		Face = nil,
		FacePoint = nil,
		TurnRate = Config.Move.AttackTurnRate,
		StepSpeed = 0,
		Knock = Vector3.zero,
		Leap = nil,
		Target = nil,
		Token = 0,
		BusyUntil = 0,
		NextAttack = 0,
		LungeReady = 0,
		FrenzyReady = 0,
		HoldsToken = nil,
		Alive = true,
		ActionSeq = 0,
		ParrySeq = 0,
	}
	stalkers[id] = s
	humanoid.HealthChanged:Connect(function(health)
		if health <= 0 then
			die(s)
		end
	end)
	task.spawn(runAI, s)
end

function StalkerService.Init()
	folder = workspace:FindFirstChild("Enemies") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Enemies"
		folder.Parent = workspace
	end
	RunService.Heartbeat:Connect(update)
	Players.PlayerRemoving:Connect(function(player)
		attackers[player] = nil
	end)
	if Config.Enabled then
		for _ = 1, Config.Count do
			spawnStalker()
		end
	end
end

return StalkerService
