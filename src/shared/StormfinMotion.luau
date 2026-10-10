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
	Look: Vector3?, -- facing (Windup, Rise, Hover, Stun, Death)
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
		local forward = unitOr(flat(look), -Vector3.zAxis) * math.cos(pitch) + UP * math.sin(pitch)
		return position - UP * 0.4 * math.sin(math.pi * u), forward.Unit, u
	elseif kind == "Leap" or kind == "Stagger" or kind == "Dive" then
		local position, forward = arc(seg, u)
		return position, forward, u
	elseif kind == "Rise" then
		local e = smooth(u)
		local position = seg.A:Lerp(seg.B, e)
		-- Noses up out of the water, levelling off into the hover.
		local pitch = 1.1 * (1 - e)
		local forward = unitOr(flat(look), -Vector3.zAxis) * math.cos(pitch) + UP * math.sin(pitch)
		return position, forward.Unit, u
	elseif kind == "Hover" or kind == "Stun" then
		local t = now - seg.Start
		local bob = if kind == "Hover" then 0.35 * math.sin(t * 2 * math.pi / 1.6) else 0.15 * math.sin(t * 9)
		return seg.A + UP * bob, unitOr(look, -Vector3.zAxis), u
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
