--[[ Goblin Gazette - Game/Bonus.lua
	The Bonus Track: the goblins' own test course at the end of each route. A short run on an oily dirt track
	through a start arch: ramps to jump, oil slicks to avoid, practice targets and straw dummies on the far
	side to hit with papers (thrown to the right on this course), and the finish arch. Nothing here costs a
	life; the points go on the round's score. Ticked with the ride (30 a second); no game API in here.

	  Bn:Build(zone, seed)    -> the course (a route: Game/Route.lua's shape, plus ramps, slicks, targets)
	  Bn:Setup(ride)          the bonus ride's own state
	  Bn:Steer(ride)          before the trike moves: the skid's slide, the narrowing at the arches
	  Bn:Tick(ride)           after it moves: onto a ramp, into the air, down again, onto oil
	  Bn:HitTargets(ride, p)  a paper in the air against the targets (from Round's flight)
	  Bn:Height(ride, alpha)  -> px the trike is drawn above the ground (on a ramp, in the air)

	Events (the round's stream): "jump", "land", "skid", "target", "dummy". ]]

local _, ns = ...
local P = ns.P
local Bn = P:Module("Bonus")

local TPS = 30
local DT = 1 / TPS
local floor = math.floor

Bn.LENGTH = 112              -- tiles: about 25 s at cruising speed
Bn.START, Bn.FINISH = 6, 104 -- the arches (a)
Bn.PAPERS = 12               -- a fresh load for the course
Bn.RAMP_LO, Bn.RAMP_HI = -0.9, 1.0   -- tiles along a ramp from its pivot: where it meets the ground .. its lip
Bn.RAMP_HALF = 0.5           -- tiles across it
Bn.RAMP_H = 42               -- px: the lip's height
Bn.AIR_BASE, Bn.AIR_PER_V = 12, 3.2  -- ticks in the air: faster off the lip flies farther
Bn.AIR_PEAK = 34             -- px above the lip at the top of the jump
Bn.LAND_TICKS = 9            -- the landing bounce (4 frames at 14 fps)
Bn.SLICK_A, Bn.SLICK_B = 0.55, 0.42  -- tiles: riding this close to a slick's middle skids
Bn.SKID_TICKS = 24
Bn.SKID_DRIFT = 1.7          -- tiles a second sideways while skidding
Bn.TARGET_B = -3.85          -- the targets stand on the far side's grass, just past the track
Bn.HIT_A = 0.45              -- tiles along the road either side of a target that a paper passing it hits
Bn.HIT_H = 80                -- px: the boards' height
Bn.GATE_B = { -2.35, -0.75 } -- the span between an arch's legs (b); the course narrows to it near the arches
Bn.FUNNEL = 3.5              -- tiles before and after an arch over which the edges close in
Bn.SCORE = { target = 250, dummy = 150, jump = 100, air = 2 }   -- (air: a target hit by a paper thrown in the air)

local Rt, Rd
local function Mods() Rt, Rd = Rt or P.Route, Rd or P.Round end

-- ------------------------------------------------------------------ the course
function Bn:Build(zone, seed)
	Mods()
	local L = self.LENGTH
	-- (the course's ground is the goblins' own green test track on every route; the trees are the route's)
	local r = { zone = "bonus_elwynn", street = zone, bonus = true, seed = seed, length = L, n = 0, a = {}, b = {}, spr = {}, kind = {},
		tgt = {}, houses = {}, bundles = {}, obstacles = {}, spawns = {}, ramps = {}, slicks = {}, targets = {} }
	local st = Rt.Seed({}, seed, 7)
	local function Add(a, b, spr, kind, tgt)
		local n = r.n + 1
		r.n = n
		r.a[n], r.b[n], r.spr[n], r.kind[n], r.tgt[n] = a, b, spr, kind or 1, tgt or false
	end
	local z = zone .. "_"
	-- the arches: one leg on the far edge of the narrowed course, the other across it
	Add(self.START, self.GATE_B[1], "bonus_gate_start")
	Add(self.FINISH, self.GATE_B[1], "bonus_gate_finish")
	-- the course: a run of sections, each a ramp or a slick on the track with targets alongside
	local a = self.START + 7
	local kindPrev
	while a < self.FINISH - 8 do
		local roll = Rt.Rnd(st)
		local what = roll < 0.45 and "ramp" or "slick"
		if what == kindPrev and Rt.Rnd(st) < 0.6 then what = (what == "ramp") and "slick" or "ramp" end
		kindPrev = what
		local lane = Rt.Range(st, -2.0, 0.2)
		if what == "ramp" then
			local rp = { kind = "ramp", a = a, b = lane }
			r.ramps[#r.ramps + 1] = rp
			Add(rp.a, rp.b, "bonus_ramp", 1, rp)
		else
			local sl = { kind = "slick", a = a, b = lane }
			r.slicks[#r.slicks + 1] = sl
			Add(sl.a, sl.b, "bonus_oil_slick", 2, sl)
			-- now and then a second slick across the other half of the track
			if Rt.Rnd(st) < 0.4 then
				local b2 = lane < -0.9 and Rt.Range(st, -0.2, 0.4) or Rt.Range(st, -2.4, -1.8)
				local s2 = { kind = "slick", a = a + Rt.Range(st, 1.2, 2.4), b = b2 }
				r.slicks[#r.slicks + 1] = s2
				Add(s2.a, s2.b, "bonus_oil_slick", 2, s2)
			end
		end
		-- one to three targets on the far side's grass, a little after the piece (aim while landing or after
		-- the skid), sometimes a dummy
		local n = Rt.Int(st, 1, 3)
		local ta = a + Rt.Range(st, 2.5, 4.0)
		for _ = 1, n do
			local kind = Rt.Rnd(st) < 0.35 and "dummy" or "target"
			local t = { kind = kind, a = ta, b = self.TARGET_B + Rt.Range(st, -0.2, 0.2), state = "ok" }
			r.targets[#r.targets + 1] = t
			Add(t.a, t.b, "bonus_" .. kind, 1, t)
			ta = ta + Rt.Range(st, 1.6, 2.6)
		end
		a = a + Rt.Range(st, 9, 12)
	end
	-- the grass beyond: trees well back on both sides, a few hedges along the near side
	local ta = 2
	while ta < L do
		Add(ta, Rt.Range(st, -6.5, -10), z .. "tree")
		if Rt.Rnd(st) < 0.7 then Add(ta + Rt.Range(st, -1, 1), Rt.Range(st, 3.2, 7), z .. "tree") end
		ta = ta + Rt.Range(st, 4, 7)
	end
	for ha = 3, L, 12 do Add(ha, 1.9, z .. "hedge") end
	-- the order the trike meets them (as Route:Build)
	local order = {}
	for i = 1, r.n do order[i] = i end
	local ra = r.a
	table.sort(order, function(x, y) if ra[x] ~= ra[y] then return ra[x] < ra[y] end return x < y end)
	local na, nb, ns_, nk, nt = {}, {}, {}, {}, {}
	for i, j in ipairs(order) do na[i], nb[i], ns_[i], nk[i], nt[i] = r.a[j], r.b[j], r.spr[j], r.kind[j], r.tgt[j] end
	r.a, r.b, r.spr, r.kind, r.tgt = na, nb, ns_, nk, nt
	for i = 1, r.n do if nt[i] then nt[i].idx = i end end
	return r
end

-- ------------------------------------------------------------------ the ride
function Bn:Setup(r)
	Mods()
	r.air, r.airT, r.airLen, r.lipA = false, 0, 0, nil
	r.onRamp = nil
	r.landT = -100
	r.skid, r.skidT, r.skidDir = false, 0, 0
	r.h, r.ph = 0, 0
	r.papers = self.PAPERS
	local s = r.stats
	s.jumps, s.targets, s.dummies, s.skids, s.airHits, s.course = 0, 0, 0, 0, 0, 0
	r.targetNext = 1
end

local function Emit(r, what, tgt, a, b, h, pts) Rd.Emit(r, what, tgt, a, b, h, pts) end
local function Score(r, pts)
	r.stats.course = r.stats.course + pts
	return Rd.Score(r, pts)
end

-- the course's edges here: the track, closing in to the arches' legs near each arch
function Bn:Edges(a)
	local lo, hi = P.Drive.B_MIN, P.Drive.B_MAX
	for _, ga in ipairs({ self.START, self.FINISH }) do
		local d = math.abs(a - ga)
		if d < self.FUNNEL then
			local f = 1 - d / self.FUNNEL
			f = f * f * (3 - 2 * f)
			lo = lo + (self.GATE_B[1] + 0.15 - lo) * f
			hi = hi + (self.GATE_B[2] - 0.15 - hi) * f
		end
	end
	return lo, hi
end

-- before the trike moves: a skid takes the steering
function Bn:Steer(r)
	if r.skid then
		r.skidT = r.skidT + 1
		if r.skidT >= self.SKID_TICKS then r.skid = false end
	end
end

function Bn:Tick(r)
	r.ph = r.h
	local tick = r.tick
	-- the skid's slide
	if r.skid then
		local lo, hi = self:Edges(r.a)
		r.b = math.max(lo, math.min(hi, r.b + r.skidDir * self.SKID_DRIFT * DT))
	end
	-- in the air: a parabola from the lip's height, then down
	if r.air then
		r.airT = r.airT + 1
		local u = r.airT / r.airLen
		if u >= 1 then
			r.air = false
			r.h = 0
			r.landT = tick
			Emit(r, "land", nil, r.a, r.b, 0, 0)
		else
			r.h = self.RAMP_H * (1 - u) + 4 * self.AIR_PEAK * u * (1 - u)
		end
	else
		-- on a ramp: the trike climbs it; off its lip, it flies
		r.h = 0
		local on = nil
		for _, rp in ipairs(r.route.ramps) do
			local da = r.a - rp.a
			if da >= self.RAMP_LO and da <= self.RAMP_HI + 0.3 and math.abs(r.b - rp.b) <= self.RAMP_HALF then on = rp break end
		end
		if on then
			local da = r.a - on.a
			if da >= self.RAMP_HI then
				r.air, r.airT = true, 0
				r.airLen = floor(self.AIR_BASE + self.AIR_PER_V * r.v + 0.5)
				r.h = self.RAMP_H
				r.stats.jumps = r.stats.jumps + 1
				Emit(r, "jump", on, r.a, r.b, r.h, Score(r, self.SCORE.jump))
			else
				r.h = self.RAMP_H * (da - self.RAMP_LO) / (self.RAMP_HI - self.RAMP_LO)
			end
		end
		r.onRamp = on
		-- oil: on the ground only, and once per slick
		if not on and not r.skid then
			for _, sl in ipairs(r.route.slicks) do
				if not sl.hit and math.abs(r.a - sl.a) <= self.SLICK_A and math.abs(r.b - sl.b) <= self.SLICK_B then
					sl.hit = true
					r.skid, r.skidT = true, 0
					-- slides away from the slick's middle (straight on: toward the track's middle)
					local d = r.b - sl.b
					if math.abs(d) < 0.05 then d = (-0.95 - r.b) end
					r.skidDir = d >= 0 and 1 or -1
					r.v = math.min(r.v, P.Drive.SPEED.slow)
					r.throwReq = false
					r.stats.skids = r.stats.skids + 1
					Emit(r, "skid", sl, r.a, r.b, 0, 0)
					break
				end
			end
		end
	end
end

-- a paper flying toward the far side: it hits a target or dummy when it crosses its line beside it
function Bn:HitTargets(r, p)
	local ts = r.route.targets
	while r.targetNext <= #ts and ts[r.targetNext].a < r.a - 6 do r.targetNext = r.targetNext + 1 end
	for k = r.targetNext, #ts do
		local t = ts[k]
		if t.a - 3 > p.a then break end
		if t.state == "ok" and p.pb > t.b and p.b <= t.b and p.h >= 0 then
			local f = (t.b - p.pb) / (p.b - p.pb)
			local a = p.pa + (p.a - p.pa) * f
			local h = p.ph + (p.h - p.ph) * f
			if math.abs(a - t.a) <= self.HIT_A and h <= self.HIT_H then
				t.state = "hit"
				local pts = self.SCORE[t.kind]
				if p.air then pts = pts * self.SCORE.air r.stats.airHits = r.stats.airHits + 1 end
				if t.kind == "dummy" then r.stats.dummies = r.stats.dummies + 1 else r.stats.targets = r.stats.targets + 1 end
				Emit(r, t.kind, t, t.a, t.b, 50, Score(r, pts))
				p.on = false
				return true
			end
		end
	end
	return false
end

-- the trike's height above the ground for drawing, blended between ticks
function Bn:Height(r, alpha)
	return (r.ph or 0) + ((r.h or 0) - (r.ph or 0)) * alpha
end
