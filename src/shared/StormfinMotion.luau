-- Deterministic Stormfin motion, shared by the server (hitbox, hit checks) and clients (the drawn
-- creature). The server sends one segment per phase (kind, server start time, duration, points,
-- starting velocity); both sides evaluate it at workspace:GetServerTimeNow(), so they agree without
-- per-frame traffic.
--
-- The motion is physically based, so the body's animation can follow what it is actually doing:
-- - Momentum carries over. Every segment starts from the previous one's position AND velocity
--   (V), so it never stops dead or starts at full speed. The only sudden changes are real impulses
--   (the breach launch, a parry knockback, the kick into a dive).
-- - Anything airborne without thrust (leap, knockback, dive, falling dead) follows one gravity,
--   Physics.Gravity. Hitting the water bleeds the speed off with drag while buoyancy settles it at
--   its depth: it plunges a little and glides on instead of stopping on a point.
-- - Powered moves are smooth. A swim is a curve that starts at the current velocity and arrives
--   at a set speed; rising and hovering ride a damped spring (overshoot a little, then settle).
-- Past the end of a segment (the next one hasn't arrived yet) the motion carries on physically
-- rather than freezing, so a late segment doesn't make the fish pop.
-- The segment builders (Swim, Windup, Leap, ...) live here too, so the server and offline tests
-- build them the same way.
local Config = require(script.Parent.Config.StormfinConfig)

local StormfinMotion = {}

export type Segment = {
	Kind: string, -- Swim | Windup | Leap | Rise | Hover | Stagger | Stun | Dive | Death
	Start: number, -- server time
	Duration: number,
	A: Vector3, -- start point
	B: Vector3?, -- where it is heading or settles (Swim, Windup, Rise, Hover, Stun)
	V: Vector3?, -- velocity at the start, carried over from the previous segment (or an impulse)
	W: Vector3?, -- velocity on arrival (Swim)
	Bow: Vector3?, -- sideways bulge at the middle of a swim path
	Depth: number?, -- height it settles to after splashing down (Leap, Dive, Stagger, Death)
	Look: Vector3?, -- facing (Windup, Rise, Hover, Stagger, Stun, Death)
	Extra: { [string]: any }?, -- kind-specific (Windup: Parryable; Hover: ChargeStart/ChargeTime/Parryable; Death: FloatTime)
}

local Physics = Config.Physics
local UP = Vector3.yAxis
local ZERO = Vector3.zero
local GRAVITY = Vector3.new(0, -Physics.Gravity, 0)
local SURFACE = Config.SurfaceY
local LAUNCH_DEPTH = SURFACE - 1.3 -- body centre while coiled under the launch spot
local FLOAT = SURFACE + 0.6 -- body centre floundering on the surface
local DEAD_FLOAT = SURFACE - 0.2 -- a dead fin floats awash before it sinks
local VELOCITY_STEP = 1 / 240 -- seconds; finite-difference step for Velocity

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Facing along `base` (flat) pitched nose-up by `pitch` radians.
local function pitched(base: Vector3, pitch: number): Vector3
	return (base * math.cos(pitch) + UP * math.sin(pitch)).Unit
end

-- Turns unit vector `a` toward unit vector `b` by fraction `w` of the angle between them.
function StormfinMotion.TurnToward(a: Vector3, b: Vector3, w: number): Vector3
	local angle = math.acos(math.clamp(a:Dot(b), -1, 1))
	if angle < 1e-4 then
		return b
	end
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-5 then -- exactly reversed: swing round horizontally
		axis = if math.abs(a.Y) < 0.99 then UP else Vector3.xAxis
	end
	return CFrame.fromAxisAngle(axis.Unit, angle * w):VectorToWorldSpace(a)
end
local turnToward = StormfinMotion.TurnToward

-- Faces along its velocity; as it slows to a stop it settles level along `rest` (a flat unit).
local function heading(velocity: Vector3, rest: Vector3): Vector3
	return unitOr(velocity + rest * 3, rest)
end

-- Nose up while climbing, slightly down while sinking (vertical speed in studs/s).
local function climbPitch(velocity: Vector3): number
	return math.clamp(velocity.Y / 25, -0.35, 1.1)
end

-- Cubic Hermite from p0 (velocity v0) to p1 (velocity v1) over `duration` seconds, at fraction s.
local function hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, duration: number, s: number): (Vector3, Vector3)
	local s2, s3 = s * s, s * s * s
	local position = p0 * (2 * s3 - 3 * s2 + 1) + v0 * (duration * (s3 - 2 * s2 + s)) + p1 * (3 * s2 - 2 * s3) + v1 * (duration * (s3 - s2))
	local velocity = (p0 - p1) * ((6 * s2 - 6 * s) / duration) + v0 * (3 * s2 - 4 * s + 1) + v1 * (3 * s2 - 2 * s)
	return position, velocity
end

-- 0 at both ends with zero slope, 1 at the middle (and its slope): bends a path sideways without
-- touching its start or end velocity.
local function bump(s: number): (number, number)
	return 16 * s * s * (1 - s) * (1 - s), 32 * s * (1 - s) * (1 - 2 * s)
end

-- Damped spring settling on `rest` from offset x0 and velocity v0, after time t.
-- damping < 1 overshoots a little; 1 is critically damped.
local function spring(rest: Vector3, x0: Vector3, v0: Vector3, omega: number, damping: number, t: number): (Vector3, Vector3)
	if damping >= 1 then
		local c2 = v0 + x0 * omega
		local e = math.exp(-omega * t)
		return rest + (x0 + c2 * t) * e, (v0 - c2 * (omega * t)) * e
	end
	local decay = damping * omega
	local wd = omega * math.sqrt(1 - damping * damping)
	local c2 = (v0 + x0 * decay) / wd
	local e = math.exp(-decay * t)
	local cos, sin = math.cos(wd * t), math.sin(wd * t)
	return rest + (x0 * cos + c2 * sin) * e, ((c2 * wd - x0 * decay) * cos - (x0 * wd + c2 * decay) * sin) * e
end

-- Unpowered in the water: the speed bleeds off with drag.
local function coast(p: Vector3, v: Vector3, t: number): (Vector3, Vector3)
	local k = Physics.WaterDrag
	local e = math.exp(-k * t)
	return p + v * ((1 - e) / k), v * e
end

-- After a splash-down: drag slows it while buoyancy settles it at `depth` (critically damped).
local function settle(entry: Vector3, v: Vector3, depth: number, t: number): (Vector3, Vector3)
	local k = Physics.WaterDrag
	local e = math.exp(-k * t)
	local h = flat(v)
	local position = flat(entry) + h * ((1 - e) / k)
	local omega = Physics.Buoyancy
	local y0 = entry.Y - depth
	local c2 = v.Y + y0 * omega
	local b = math.exp(-omega * t)
	return position + UP * (depth + (y0 + c2 * t) * b), h * e + UP * ((v.Y - c2 * omega * t) * b)
end

-- Seconds until a body launched from `a` at velocity `v` comes back down through the surface
-- (0 if it starts in the water and never gets out).
local function entryTime(a: Vector3, v: Vector3): number
	local g = Physics.Gravity
	local disc = v.Y * v.Y + 2 * g * (a.Y - SURFACE)
	if disc < 0 then
		return 0
	end
	return math.max((v.Y + math.sqrt(disc)) / g, 0)
end

-- Free flight under gravity until it re-enters the water, then drag and buoyancy.
local function ballistic(seg: Segment, t: number): (Vector3, Vector3)
	local v = seg.V or ZERO
	local entry = entryTime(seg.A, v)
	if t < entry then
		return seg.A + v * t + GRAVITY * (0.5 * t * t), v + GRAVITY * t
	end
	local p = seg.A + v * entry + GRAVITY * (0.5 * entry * entry)
	return settle(p, v + GRAVITY * entry, seg.Depth or Config.SwimDepth, t - entry)
end

-- Storm Bolt charge: 0 = neutral, 1 = fully coiled back (nose up), negative = lunging forward.
-- Coils over most of the charge, snaps forward into the shot so it is neutral exactly at fire
-- time (the mouth is where the bolt starts), then follows through and settles.
local function chargeCoil(progress: number, sinceFire: number): number
	if progress <= 0 then
		return 0
	elseif sinceFire < 0 then
		if progress < 0.85 then
			return smooth(progress / 0.85)
		end
		local s = (progress - 0.85) / 0.15
		return 1 - s * s
	end
	local k = sinceFire / 0.08
	return -0.6 * k * math.exp(1 - k)
end

-- A dead fin floats for FloatTime (or until shortly after it lands in the water), then sinks.
local function deathSinkStart(seg: Segment): number
	local float = if seg.Extra and seg.Extra.FloatTime then seg.Extra.FloatTime else 0.7
	return math.max(float, entryTime(seg.A, seg.V or ZERO) + 0.4)
end

-- Position (body centre), facing (unit), and progress 0..1 of a segment at a server time.
function StormfinMotion.Evaluate(seg: Segment, now: number): (Vector3, Vector3, number)
	local elapsed = now - seg.Start
	local duration = seg.Duration
	local u = if duration > 0 then math.clamp(elapsed / duration, 0, 1) else 1
	local b = seg.B or seg.A
	local look = unitOr(flat(seg.Look or (b - seg.A)), -Vector3.zAxis)
	local v0 = seg.V or ZERO
	local kind = seg.Kind

	if kind == "Swim" then
		local w = seg.W or ZERO
		if duration <= 0 or elapsed >= duration then
			-- Past the end (or a zero-length hold): coasts on, slowed by the water.
			local position, velocity = coast(b, w, elapsed - duration)
			return position, heading(velocity, unitOr(flat(w), look)), 1
		end
		local s = elapsed / duration
		local position, velocity = hermite(seg.A, v0, b, w, duration, s)
		if seg.Bow then
			local bulge, slope = bump(s)
			position += seg.Bow * bulge
			velocity += seg.Bow * (slope / duration)
		end
		return position, heading(velocity, look), u
	elseif kind == "Windup" then
		-- Brakes to a stop over the launch spot (steady deceleration over the first half), curls
		-- nose-up, sinks as it coils, then pushes up in the last instant into the launch.
		local brake = math.max(duration * 0.5, 1e-3)
		local position = hermite(seg.A, v0, b, ZERO, brake, math.min(elapsed / brake, 1))
		local crouch = if u < 0.88 then smooth(u / 0.88) else 1 - ((u - 0.88) / 0.12) ^ 2
		local pitch = 0.9 * smooth((u - 0.4) / 0.6)
		local forward = turnToward(unitOr(flat(v0), look), pitched(look, pitch), smooth(u / 0.5))
		return position - UP * (0.6 * crouch), forward, u
	elseif kind == "Leap" or kind == "Dive" then
		local position, velocity = ballistic(seg, elapsed)
		return position, heading(velocity, unitOr(flat(v0), look)), u
	elseif kind == "Stagger" then
		-- Knocked back still facing the player who parried it: the head is thrown back, then it
		-- rights itself as it lands.
		local position = ballistic(seg, elapsed)
		return position, pitched(look, math.sin(math.pi * u)), u
	elseif kind == "Rise" then
		-- Springs up out of the water, overshoots the hover height a little and settles; noses up
		-- while it climbs.
		local position, velocity = spring(b, seg.A - b, v0, Physics.LiftOmega, Physics.LiftDamping, elapsed)
		return position, pitched(look, climbPitch(velocity)), u
	elseif kind == "Hover" then
		-- Held on the same spring (it keeps settling from the rise), with a slow figure-eight drift
		-- eased in, plus the charge coil and shot lunge.
		local position, velocity = spring(b, seg.A - b, v0, Physics.LiftOmega, Physics.LiftDamping, elapsed)
		local side = look:Cross(UP)
		local ramp = smooth(elapsed / 0.6)
		position += (UP * (0.35 * math.sin(elapsed * 2 * math.pi / 1.6)) + side * (0.25 * math.sin(elapsed * math.pi / 1.6))) * ramp
		local coil = 0
		local extra = seg.Extra
		if extra and extra.ChargeStart and extra.ChargeTime then
			local charge = elapsed - extra.ChargeStart
			coil = chargeCoil(charge / extra.ChargeTime, charge - extra.ChargeTime)
		end
		return position - look * (0.9 * coil), pitched(look, 0.3 * coil + climbPitch(velocity)), u
	elseif kind == "Stun" then
		-- Bobs on the surface (a softer spring) and flounders: thrashes side to side and slaps on
		-- the water, eased in from the knockback.
		local position = spring(b, seg.A - b, v0, Physics.FloatOmega, Physics.FloatDamping, elapsed)
		local ramp = smooth(elapsed / 0.3)
		local thrash = 0.45 * math.sin(elapsed * 7) * (0.6 + 0.4 * math.cos(elapsed * 2.3)) * ramp
		local forward = CFrame.fromAxisAngle(UP, thrash):VectorToWorldSpace(look)
		return position + UP * (0.3 * math.abs(math.sin(elapsed * 5)) * ramp), forward, u
	elseif kind == "Death" then
		-- Falls if it died in the air, floats awash, then sinks.
		local position, velocity = ballistic(seg, elapsed)
		local sinkStart = deathSinkStart(seg)
		local sink = math.clamp((elapsed - sinkStart) / math.max(duration - sinkStart, 0.01), 0, 1)
		return position - UP * (6 * smooth(sink)), heading(velocity, look), u
	end
	return seg.A, look, u
end

-- Velocity (studs/s) of a segment at a server time.
function StormfinMotion.Velocity(seg: Segment, now: number): Vector3
	local p0 = StormfinMotion.Evaluate(seg, now)
	local p1 = StormfinMotion.Evaluate(seg, now - VELOCITY_STEP)
	local p2 = StormfinMotion.Evaluate(seg, now - 2 * VELOCITY_STEP)
	return (p0 * 3 - p1 * 4 + p2) / (2 * VELOCITY_STEP)
end

-- Seconds into a ballistic segment (Leap, Dive, Stagger, Death) at which it splashes down.
function StormfinMotion.EntryTime(seg: Segment): number
	return entryTime(seg.A, seg.V or ZERO)
end

-- CFrame for the body centre facing along `forward` (works for straight up/down facings too).
function StormfinMotion.CFrame(position: Vector3, forward: Vector3): CFrame
	local up = if math.abs(forward.Y) > 0.98 then Vector3.zAxis else UP
	return CFrame.lookAt(position, position + forward, up)
end

function StormfinMotion.Ended(seg: Segment, now: number): boolean
	return now >= seg.Start + seg.Duration
end

-------------------------------------------------------------------------------- segment builders
-- Each starts at server time `t` from the fin's current position `a` and velocity `v`.

-- Holds still at `a` (a freshly spawned fin).
function StormfinMotion.Still(t: number, a: Vector3): Segment
	return { Kind = "Swim", Start = t, Duration = 0, A = a, B = a, V = ZERO, W = ZERO }
end

-- Swims to `destination` (at swim depth), bowing sideways by `bend` (-1..1 of Swim.Curve) and
-- arriving at Swim.ArriveSpeed.
function StormfinMotion.Swim(t: number, a: Vector3, v: Vector3, destination: Vector3, bend: number): Segment
	local swim = Config.Swim
	local b = Vector3.new(destination.X, Config.SwimDepth, destination.Z)
	local delta = flat(b - a)
	local distance = delta.Magnitude
	local direction = unitOr(delta, unitOr(flat(v), Vector3.xAxis))
	local bulge = distance * swim.Curve * 0.5 * bend
	-- Path length of the bowed curve (close enough for timing).
	local length = distance + (8 / 3) * bulge * bulge / math.max(distance, 1)
	return {
		Kind = "Swim",
		Start = t,
		Duration = math.clamp(length / swim.Speed, swim.MinTime, swim.MaxTime),
		A = a,
		B = b,
		V = v,
		W = direction * swim.ArriveSpeed,
		Bow = direction:Cross(UP) * bulge,
	}
end

-- Thunder Breach windup: glides on to a stop over the launch spot and coils there, facing `target`.
function StormfinMotion.Windup(t: number, a: Vector3, v: Vector3, target: Vector3, parryable: boolean): Segment
	local windup = Config.Breach.Windup
	-- Steady braking over the first half of the windup covers half the distance it would coast.
	local launch = flat(a) + flat(v) * (windup * 0.25) + UP * LAUNCH_DEPTH
	return {
		Kind = "Windup",
		Start = t,
		Duration = windup,
		A = a,
		B = launch,
		V = v,
		Look = unitOr(flat(target - launch), unitOr(flat(v), Vector3.xAxis)),
		Extra = { Parryable = parryable },
	}
end

-- Thunder Breach leap from the launch spot `a` through `aim` under gravity, at Breach.Speed
-- horizontally (slower only for a target so close it would have to rocket straight up, faster for
-- one so far it would have to fly sky-high), then it splashes down past them and glides on underwater.
function StormfinMotion.Leap(t: number, a: Vector3, aim: Vector3, fallback: Vector3): Segment
	local settings = Config.Breach
	local toAim = flat(aim - a)
	local direction = unitOr(toAim, fallback)
	local distance = math.max(toAim.Magnitude, 4)
	local time = math.clamp(distance / settings.Speed, settings.MinAimTime, settings.MaxAimTime)
	local climb = (aim.Y - a.Y + 0.5 * Physics.Gravity * time * time) / time
	local segment: Segment = { Kind = "Leap", Start = t, Duration = 0, A = a, V = direction * (distance / time) + UP * climb, Depth = Config.SwimDepth }
	segment.Duration = StormfinMotion.EntryTime(segment) + Physics.Glide
	return segment
end

-- A parried breach: knocked back (away) and up, still facing the player, into the water where it
-- bobs up to float on the surface.
function StormfinMotion.Stagger(t: number, a: Vector3, away: Vector3): Segment
	local settings = Config.Breach
	local segment: Segment = { Kind = "Stagger", Start = t, Duration = 0, A = a, V = away * settings.KnockBack + UP * settings.KnockUp, Depth = FLOAT, Look = -away }
	segment.Duration = StormfinMotion.EntryTime(segment) + settings.Splashdown
	return segment
end

-- Floundering on the surface after a parried breach, open to fire.
function StormfinMotion.Stun(t: number, a: Vector3, v: Vector3, away: Vector3): Segment
	return { Kind = "Stun", Start = t, Duration = Config.Breach.StunTime, A = a, B = flat(a) + UP * FLOAT, V = v, Look = -away }
end

-- Storm Bolt: springs up to `hoverPoint`, facing along `look`.
function StormfinMotion.Rise(t: number, a: Vector3, v: Vector3, hoverPoint: Vector3, look: Vector3): Segment
	return { Kind = "Rise", Start = t, Duration = Config.Bolt.RiseTime, A = a, B = hoverPoint, V = v, Look = look }
end

function StormfinMotion.Hover(t: number, a: Vector3, v: Vector3, hoverPoint: Vector3, look: Vector3, extra: { [string]: any }): Segment
	return { Kind = "Hover", Start = t, Duration = Config.Bolt.HoverTime, A = a, B = hoverPoint, V = v, Look = look, Extra = extra }
end

-- Tips over and drops back into the water: keeps its momentum plus a small kick forward and up.
function StormfinMotion.Dive(t: number, a: Vector3, forward: Vector3, v: Vector3): Segment
	local direction = unitOr(flat(forward), unitOr(flat(v), Vector3.xAxis))
	local segment: Segment = { Kind = "Dive", Start = t, Duration = 0, A = a, V = v + direction * Config.Dive.Push + UP * Config.Dive.Hop, Depth = Config.SwimDepth }
	segment.Duration = StormfinMotion.EntryTime(segment) + Physics.Glide
	return segment
end

-- Dies: falls if it was in the air, floats awash, then sinks.
function StormfinMotion.Death(t: number, a: Vector3, forward: Vector3, v: Vector3): Segment
	local segment: Segment = {
		Kind = "Death",
		Start = t,
		Duration = 0,
		A = a,
		V = v,
		Depth = DEAD_FLOAT,
		Look = unitOr(flat(forward), unitOr(flat(v), Vector3.xAxis)),
		Extra = { FloatTime = Config.DeathFloatTime },
	}
	segment.Duration = deathSinkStart(segment) + Config.DeathSinkTime
	return segment
end

return StormfinMotion
