-- Deterministic Stormfin motion, shared by the server (hitbox, hit checks) and clients (the drawn
-- creature). The server sends one segment per phase (kind, server start time, duration, points);
-- both sides evaluate it at workspace:GetServerTimeNow(), so they agree without per-frame traffic.
local StormfinMotion = {}

export type Segment = {
	Kind: string, -- Swim | Windup | Leap | Rise | Hover | Stagger | Stun | Dive | Death
	Start: number, -- server time
	Duration: number,
	A: Vector3, -- start point
	B: Vector3, -- end point
	C: Vector3?, -- Bezier control point (Swim)
	Height: number?, -- arc height (Leap, Stagger, Dive)
	Look: Vector3?, -- facing (Windup, Rise, Hover, Stagger, Stun, Death)
	Extra: { [string]: any }?, -- kind-specific timing (Hover: ChargeStart/ChargeTime/FireAt)
}

local UP = Vector3.yAxis

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function easeOut(x: number): number
	x = math.clamp(x, 0, 1)
	return 1 - (1 - x) ^ 3
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Overshoots the target a little and settles back (ends exactly on 1).
local function backOut(x: number): number
	x = math.clamp(x, 0, 1) - 1
	local c = 1.2
	return 1 + (c + 1) * x ^ 3 + c * x ^ 2
end

-- Facing along `base` (flat) pitched nose-up by `pitch` radians.
local function pitched(base: Vector3, pitch: number): Vector3
	return (base * math.cos(pitch) + UP * math.sin(pitch)).Unit
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

-- Ballistic-looking arc: straight line A->B lifted by a parabola of the given height.
local function arc(seg: Segment, u: number): (Vector3, Vector3)
	local h = seg.Height or 0
	local position = seg.A:Lerp(seg.B, u) + UP * (4 * h * u * (1 - u))
	local velocity = (seg.B - seg.A) + UP * (4 * h * (1 - 2 * u))
	return position, unitOr(velocity, unitOr(flat(seg.B - seg.A), -Vector3.zAxis))
end

-- Position (body centre), facing (unit), and progress 0..1 of a segment at a server time.
function StormfinMotion.Evaluate(seg: Segment, now: number): (Vector3, Vector3, number)
	local u = if seg.Duration > 0 then math.clamp((now - seg.Start) / seg.Duration, 0, 1) else 1
	local look = seg.Look or unitOr(flat(seg.B - seg.A), -Vector3.zAxis)
	local kind = seg.Kind

	if kind == "Swim" then
		local c = seg.C or seg.A:Lerp(seg.B, 0.5)
		local v = 1 - u
		local position = seg.A * (v * v) + c * (2 * v * u) + seg.B * (u * u)
		local velocity = (c - seg.A) * (2 * v) + (seg.B - c) * (2 * u)
		return position, unitOr(velocity, look), u
	elseif kind == "Windup" then
		-- Slides under the launch point, then curls nose-up ready to explode out of the water.
		local position = seg.A:Lerp(seg.B, easeOut(u / 0.5))
		local pitch = 0.9 * smooth((u - 0.4) / 0.6)
		-- Anticipation: sinks as it coils, then pushes up in the last instant into the launch.
		local crouch = if u < 0.88 then smooth(u / 0.88) else 1 - ((u - 0.88) / 0.12) ^ 2
		return position - UP * 0.6 * crouch, pitched(unitOr(flat(look), -Vector3.zAxis), pitch), u
	elseif kind == "Stagger" and seg.Look then
		-- Knocked back still facing the player who parried it: the head is thrown back, then it
		-- rights itself as it lands.
		local position = arc(seg, u)
		return position, pitched(unitOr(flat(seg.Look), -Vector3.zAxis), 1.0 * math.sin(math.pi * u)), u
	elseif kind == "Leap" or kind == "Stagger" or kind == "Dive" then
		local position, forward = arc(seg, u)
		return position, forward, u
	elseif kind == "Rise" then
		-- Bursts up out of the water, overshoots the hover height a little and settles; noses up,
		-- then levels off (dipping slightly as it settles).
		local e = backOut(u)
		local position = seg.A:Lerp(seg.B, e)
		return position, pitched(unitOr(flat(look), -Vector3.zAxis), 1.1 * (1 - e)), u
	elseif kind == "Stun" then
		-- Floundering on the surface: thrashes side to side and slaps up and down on the water.
		local t = now - seg.Start
		local thrash = 0.45 * math.sin(t * 7) * (0.6 + 0.4 * math.cos(t * 2.3))
		local forward = CFrame.fromAxisAngle(UP, thrash):VectorToWorldSpace(unitOr(flat(look), -Vector3.zAxis))
		return seg.A + UP * 0.3 * math.abs(math.sin(t * 5)), forward, u
	elseif kind == "Hover" then
		-- Slow figure-eight drift instead of a plain bob, plus the charge coil and shot lunge.
		local t = now - seg.Start
		local base = unitOr(flat(look), -Vector3.zAxis)
		local side = base:Cross(UP)
		local position = seg.A + UP * 0.35 * math.sin(t * 2 * math.pi / 1.6) + side * 0.25 * math.sin(t * math.pi / 1.6)
		local coil = 0
		local extra = seg.Extra
		if extra and extra.ChargeStart and extra.ChargeTime then
			local charge = t - extra.ChargeStart
			coil = chargeCoil(charge / extra.ChargeTime, charge - extra.ChargeTime)
		end
		return position - base * 0.9 * coil, pitched(base, 0.3 * coil), u
	elseif kind == "Death" then
		local extra = seg.Extra or {}
		local float = extra.FloatTime or 0.7
		local t = now - seg.Start
		local sink = math.clamp((t - float) / math.max(seg.Duration - float, 0.01), 0, 1)
		return seg.A - UP * (6 * smooth(sink)), unitOr(look, -Vector3.zAxis), u
	end
	return seg.A, unitOr(look, -Vector3.zAxis), u
end

-- CFrame for the body centre facing along `forward` (works for straight up/down facings too).
function StormfinMotion.CFrame(position: Vector3, forward: Vector3): CFrame
	local up = if math.abs(forward.Y) > 0.98 then Vector3.zAxis else UP
	return CFrame.lookAt(position, position + forward, up)
end

function StormfinMotion.Ended(seg: Segment, now: number): boolean
	return now >= seg.Start + seg.Duration
end

return StormfinMotion
