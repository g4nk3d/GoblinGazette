--[[ Goblin Gazette - Game/Route.lua
	A route is a street laid out from a seed: the same seed gives the same street on every machine (the
	daily route will use the day's seed). It is kept as flat parallel arrays in the order the trike meets
	things, so the stage can spawn them one by one as they come into view and nothing is allocated per tick.

	  Rt:Build(zone, seed, length)   -> route { zone, length, n, a = {}, b = {}, spr = {}, kind = {}, tgt = {},
	                                            houses = {...}, bundles = {...} }
	  Rt.Seed / Rt.Rnd / Rt.Int      the deterministic numbers (Park-Miller, exact in double arithmetic)

	World coordinates (Data/World.lua): a runs along the road toward the upper right, b across it toward
	the houses. Lanes: far side b < -3 | road -3..0 | sidewalk 0..1 | lawns b > 1. Kinds: 1 upright
	scenery (sorted by depth), 2 ground decal (drawn flat under everything upright).

	Targets. tgt[i] is the piece's live game record (or false for plain scenery): the stage reads it to pick
	the art, the rules change it when a paper lands. Each house record carries the geometry papers are
	tested against, worked out here once from the art's door and window rectangles:
	  face        b of the house front: the wall the windows and door sit in. The art's "door" rectangle
	              frames the front steps, so its bottom edge is the foot of the stairs; the wall stands
	              FRONT_DEPTH tiles further back (measured on all three Elwynn designs)
	  step        b of the foot of the stairs: a paper landing between step and face is on the doorstep
	  win[k]      { x0, x1, y0, y1, broken }   a window as drawn: px from the house's pivot (y up)
	  door        { x0, x1, y0, y1 }           the door and its steps as drawn
	  wall        { x0, x1 }                   the front's span on screen; anything else there stops a paper
	  sub         a subscriber (true) or not
	  mailbox, breakable   the yard's records; mailbox = { a, b, h1, state = "ok" | "hit" | "broken" }
	Bundles of papers lie on the road and sidewalk: { kind = "bundle", a, b, taken }. ]]

local _, ns = ...
local P = ns.P
local Rt = P:Module("Route")
local W = ns.World

local floor = math.floor

-- ------------------------------------------------------------------ deterministic numbers
local M = 2147483647
local function Mix(seed, a, b)
	local h = (floor(seed) % (M - 1)) + 1
	h = (h * 48271 + (a or 0) * 7919 + (b or 0) * 104729) % M
	if h == 0 then h = 1 end
	for _ = 1, 3 do h = (h * 16807) % M end
	return h
end
local function Seed(st, seed, a, b) st[1] = Mix(seed, a, b) return st end
local function Rnd(st) st[1] = (st[1] * 16807) % M return (st[1] - 1) / (M - 1) end
local function Int(st, lo, hi) return lo + floor(Rnd(st) * (hi - lo + 1)) end
local function Range(st, lo, hi) return lo + Rnd(st) * (hi - lo) end
Rt.Seed, Rt.Rnd, Rt.Int, Rt.Range = Seed, Rnd, Int, Range

-- where a house's door step is, in tiles from its pivot (from the door hotspot's bottom middle)
local function DoorOffset(name)
	local s = W.spr[name]
	local d = s and s.hot and s.hot.door
	if not d then return 1, 0 end
	local dx = (d[1] + d[3] / 2) - s.px          -- drawn px, right
	local dy = s.py - (d[2] + d[4])              -- drawn px, up
	local amb, apb = dx / 32, dy / 16            -- a - b, a + b
	return (amb + apb) / 2, (apb - amb) / 2
end
Rt.DoorOffset = DoorOffset

-- the five routes, in the order the Gazette's rounds go (each street is the next one)
Rt.ZONES = {
	{ id = "elwynn", title = "Elwynn Forest: the Goldshire Road" },
	{ id = "westfall", title = "Westfall: the Sentinel Hill farms" },
	{ id = "duskwood", title = "Duskwood: Darkshire Lane" },
	{ id = "durotar", title = "Durotar: the Razor Hill track" },
	{ id = "stranglethorn", title = "Stranglethorn: the Booty Bay boardwalk" },
}
-- the routes get harder in that order: obstacles, crossers and carts come closer together, more yards hide a
-- kobold (and they run a little faster: Game/Hazards.lua), and from Westfall on there's water on the road
-- (Durotar: mud wallows). water = the mean gap between puddles, in tiles (nil: none).
Rt.LEVELS = {
	{ gap = 1.00, chase = 0.00, water = nil },
	{ gap = 0.90, chase = 0.05, water = 70 },
	{ gap = 0.82, chase = 0.10, water = 52 },
	{ gap = 0.74, chase = 0.15, water = 42 },
	{ gap = 0.66, chase = 0.20, water = 34 },
}
Rt.WATER = { { 1.05, 0.70 }, { 1.35, 0.85 }, { 0.85, 0.58 } }    -- the puddle art's half-axes (tiles along, across)

function Rt:Level(id)
	for i, z in ipairs(self.ZONES) do if z.id == id then return i end end
	return 1
end

function Rt:Zone(id)
	for _, z in ipairs(self.ZONES) do if z.id == id then return z end end
end

local HOUSE_B = 4.8          -- every house's pivot across the road
local LAWN = 1.0             -- the lawn's front edge (the sidewalk's back edge)
local SUBSCRIBERS = 0.65     -- the share of houses that take the paper
Rt.HOUSE_B, Rt.LAWN = HOUSE_B, LAWN

Rt.FRONT_DEPTH = 0.9         -- tiles from the foot of the front steps back to the wall a paper stops at
Rt.MAILBOX_A = 2.2           -- tiles along the road from the door's path to the mailbox
Rt.DOOR_UP = 60              -- px above the step rectangle's top that the door itself reaches
Rt.WINDOW_MARGIN = 9         -- px round each window that still counts as the window (a near miss is a hit),
                             -- trimmed back wherever it would reach into the door's own target
-- A thrown paper reaches a house front HEIGHT_LO..HEIGHT_HI px above the ground (its flight is nearly flat).
-- A window drawn higher or lower than that band allows at the wall line (the routes' designs differ: porches,
-- stilts, bay fronts) is tested on its own plane, the b at which a paper reaching it is drawn over it; the
-- paper is still compared with the window where the player sees it.
Rt.HEIGHT_LO, Rt.HEIGHT_HI, Rt.HEIGHT_MID = 26, 48, 37
Rt.PLANE_MIN, Rt.PLANE_MAX = 0.25, 2.8   -- tiles behind the foot of the steps a window's own plane may be
Rt.WALL_ONLY = { elwynn = true }         -- (Elwynn's designs were tuned and play-tested at the wall line)

-- A house's front, for the paper. The art's rectangles are tested where the player sees them: when a paper
-- reaches the wall line its drawn position (screen px from the house's pivot, y up) is compared with the
-- window and door rectangles as drawn (ASSEMBLY_GUIDE 4: source hotspot -> screen). The fronts are not
-- quite parallel to the road in the art, so no single plane would match every window.
local function Front(name, a, b, zone)
	local s = W.spr[name]
	local da, db = DoorOffset(name)
	local step = b + db
	local h = { step = step, face = step + Rt.FRONT_DEPTH, doorA = a + da, pa = a, pb = b, win = {} }
	local function Rect(r, up, m)
		m = m or 0
		return { x0 = r[1] - s.px - m, x1 = r[1] + r[3] - s.px + m, y0 = s.py - (r[2] + r[4]) - m, y1 = s.py - r[2] + (up or 0) + m, broken = false }
	end
	for k = 1, 4 do
		local r = s.hot and s.hot["window_" .. k]
		if r then h.win[#h.win + 1] = Rect(r, 0, Rt.WINDOW_MARGIN) end
	end
	local d = s.hot and s.hot.door
	if d then h.door = Rect(d, Rt.DOOR_UP) end
	-- a window's widened target never reaches into the door's: trim it back on the side facing the door.
	-- Where a design's door is drawn wide, so that a window stands above its reach rather than beside it,
	-- trimming would leave nothing of the window: the door's reach stops under the window instead.
	local dr = h.door
	if dr then
		for _, w in ipairs(h.win) do
			if w.x0 < dr.x1 and w.x1 > dr.x0 and w.y0 < dr.y1 and w.y1 > dr.y0 then
				local left = (w.x0 + w.x1) / 2 < (dr.x0 + dr.x1) / 2
				local keep = left and (dr.x0 - w.x0) or (w.x1 - dr.x1)
				if keep >= (w.x1 - w.x0 - 2 * Rt.WINDOW_MARGIN) * 0.5 then
					if left then w.x1 = dr.x0 else w.x0 = dr.x1 end
				else
					dr.y1 = math.max(dr.y0 + 8, w.y0)
					dr.cut = true         -- (the wall above it, where no window is, still counts as the door)
				end
			end
		end
	end
	-- the front's span on screen: the middle 70% of the drawing (the rest is roof overhang and side wall)
	h.wall = { x0 = -s.px + s.w * 0.15, x1 = -s.px + s.w * 0.85 }
	-- windows the paper can't reach at the wall line get their own plane (see HEIGHT_LO above)
	for _, w in ipairs(Rt.WALL_ONLY[zone or ""] and {} or h.win) do
		local xc, yc = (w.x0 + w.x1) / 2, (w.y0 + w.y1) / 2
		local need = yc - xc / 2 - 32 * (h.face - b)          -- the height a paper must have at the wall line
		if need < Rt.HEIGHT_LO or need > Rt.HEIGHT_HI then
			local f = b + (yc - xc / 2 - Rt.HEIGHT_MID) / 32
			w.face = math.max(step + Rt.PLANE_MIN, math.min(step + Rt.PLANE_MAX, f))
		end
	end
	return h
end
Rt.Front = Front

function Rt:Build(zone, seed, length)
	local level = self:Level(zone)
	local D = self.LEVELS[level]
	local r = { zone = zone, seed = seed, length = length, level = level, n = 0, a = {}, b = {}, spr = {}, kind = {}, tgt = {},
		houses = {}, bundles = {}, obstacles = {}, spawns = {}, water = {} }
	local st = Seed({}, seed, 1)
	local sub = Seed({}, seed, 2)       -- who subscribes: its own stream, so the layout doesn't change with it
	local function Add(a, b, spr, kind, tgt)
		local n = r.n + 1
		r.n = n
		r.a[n], r.b[n], r.spr[n], r.kind[n], r.tgt[n] = a, b, spr, kind or 1, tgt or false
	end
	local z = zone .. "_"
	-- the house side: a house every 9 to 12 tiles, each with its path, mailbox and some garden
	local a = 7
	local last = 0
	while a < length - 6 do
		local n = Int(st, 1, 3)
		if n == last then n = n % 3 + 1 end
		last = n
		local house = z .. "house_" .. n
		local da, db = DoorOffset(house)
		local doorA = a + da
		local h = Front(house, a, HOUSE_B, zone)
		h.kind, h.a, h.b, h.n, h.spr = "house", a, HOUSE_B, n, house
		h.sub = Rnd(sub) < SUBSCRIBERS
		h.got = nil                     -- "mail" | "door" once delivered
		h.lost = false                  -- a subscriber lost (missed, or their window or mailbox broken)
		-- the mailbox and the yard ornament stand along the lawn past the far window's line: a paper on its
		-- way to a window or the door crosses the lawn a little behind where it hits (it keeps the trike's
		-- speed), and nearer the path they stood in the way of the far window
		local m = { kind = "mailbox", a = doorA + Rt.MAILBOX_A, b = LAWN + 0.45, h1 = 62, state = "ok", house = h }
		h.mailbox = m
		r.houses[#r.houses + 1] = h
		Add(doorA, LAWN, z .. "path", 2)
		Add(a, HOUSE_B, house, 1, h)
		Add(m.a, m.b, z .. "mailbox", 1, m)
		-- a hedge along the front of some yards, between this path and the next house
		if Rnd(st) < 0.45 then
			local ha = doorA + 4.4
			for i = 0, Int(st, 1, 2) - 1 do Add(ha + 2 * i, LAWN + 0.6, z .. "hedge") end
		end
		-- garden trees and ornaments behind and between the houses
		local gap = Range(st, 9, 12)
		if Rnd(st) < 0.8 then Add(a + gap * 0.55, Range(st, 3.0, 4.2), z .. "tree") end
		if Rnd(st) < 0.5 then Add(a + gap * 0.5 + Range(st, -1, 1), Range(st, 7.6, 10), z .. "tree") end
		if Rnd(st) < 0.35 then
			local bk = { kind = "breakable", a = doorA + Range(st, 3.0, 3.6), b = Range(st, 1.9, 2.5), state = "ok", house = h }
			h.breakable = bk
			Add(bk.a, bk.b, z .. "breakable", 1, bk)
		end
		a = a + gap
	end
	-- the far side: lamps, a fence that runs the whole way, trees beyond it
	local step = W.spr[z .. "fence"] and W.spr[z .. "fence"].foot and W.spr[z .. "fence"].foot[1] or 2
	for fa = 1, length, step do Add(fa, -4.4, z .. "fence") end
	for la = 4, length, 8 do Add(la, -3.6, z .. "lamp") end
	local ta = 3
	while ta < length do
		Add(ta, Range(st, -6.5, -11), z .. "tree")
		ta = ta + Range(st, 3.5, 7)
	end
	-- bundles of papers on the road and sidewalk, every 30 to 42 tiles
	local ba = 24
	while ba < length - 10 do
		local bd = { kind = "bundle", a = ba, b = Range(st, -2.2, 0.4), taken = false }
		r.bundles[#r.bundles + 1] = bd
		Add(bd.a, bd.b, "bundle", 1, bd)
		ba = ba + Range(st, 30, 42)
	end
	-- hazards, from their own stream (the street above stays the same whatever is added here). They grow
	-- busier toward the end of the lane: the gaps shrink from `far` to `near` tiles.
	local hz = Seed({}, seed, 3)
	local function Gap(a0, far, near)
		local f = math.min(1, math.max(0, a0 / length))
		return (far + (near - far) * f) * D.gap
	end
	local function ClearOfBundles(a0)
		for _, bd in ipairs(r.bundles) do if math.abs(bd.a - a0) < 3 then return false end end
		return true
	end
	-- obstacles stand on the road and sidewalk: swerve round them
	local oa = 30
	while oa < length - 8 do
		if ClearOfBundles(oa) then
			local o = { kind = "obstacle", a = oa, b = Range(hz, -2.4, 0.5) }
			r.obstacles[#r.obstacles + 1] = o
			Add(o.a, o.b, z .. (Rnd(hz) < 0.5 and "obstacle_a" or "obstacle_b"), 1, o)
		end
		oa = oa + Range(hz, Gap(oa, 22, 11), Gap(oa, 30, 16))
	end
	-- the moving ones start when the trike comes near their spot (spawns sorted by a)
	local ca = 40
	while ca < length - 10 do
		r.spawns[#r.spawns + 1] = { kind = "crosser", a = ca, dir = Rnd(hz) < 0.5 and 1 or -1 }
		ca = ca + Range(hz, Gap(ca, 50, 28), Gap(ca, 64, 36))
	end
	local va = 70
	while va < length - 10 do
		r.spawns[#r.spawns + 1] = { kind = "vehicle", a = va }
		va = va + Range(hz, Gap(va, 80, 45), Gap(va, 100, 60))
	end
	for _, h in ipairs(r.houses) do
		local f = math.min(1, math.max(0, h.a / length))
		if not h.sub and h.a > 45 and h.a < length - 20 and Rnd(hz) < 0.35 + 0.35 * f + D.chase then
			r.spawns[#r.spawns + 1] = { kind = "chaser", a = h.doorA - 1.2, b = 2.6 }
		end
	end
	table.sort(r.spawns, function(x, y) return x.a < y.a end)
	-- water on the road (the later routes), from its own stream; never on a bundle or an obstacle, and never
	-- across the whole road: there is always a way round
	if D.water then
		local ws = Seed({}, seed, 4)
		local wa = 36
		while wa < length - 14 do
			local clear = ClearOfBundles(wa)
			for _, o in ipairs(r.obstacles) do if math.abs(o.a - wa) < 3.5 then clear = false end end
			if clear then
				local n = Int(ws, 1, #self.WATER)
				local ax = self.WATER[n]
				local w = { kind = "water", a = wa, b = Range(ws, -2.2, 0.2), ra = ax[1], rb = ax[2], n = n }
				r.water[#r.water + 1] = w
				Add(w.a, w.b, z .. "water_" .. n, 2, w)
				wa = wa + Range(ws, D.water * 0.7, D.water * 1.3)
			else
				wa = wa + 4            -- (something already stands there: a little further on)
			end
		end
	end
	-- the order the trike meets them (stable for equal a: by index)
	local order = {}
	for i = 1, r.n do order[i] = i end
	local ra = r.a
	table.sort(order, function(x, y) if ra[x] ~= ra[y] then return ra[x] < ra[y] end return x < y end)
	local na, nb, ns_, nk, nt = {}, {}, {}, {}, {}
	for i, j in ipairs(order) do na[i], nb[i], ns_[i], nk[i], nt[i] = r.a[j], r.b[j], r.spr[j], r.kind[j], r.tgt[j] end
	r.a, r.b, r.spr, r.kind, r.tgt = na, nb, ns_, nk, nt
	-- each record knows where it sits in the route (the stage swaps a piece's art by it)
	for i = 1, r.n do if nt[i] then nt[i].idx = i end end
	return r
end
