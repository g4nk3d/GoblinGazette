--[[ Goblin Gazette - Game/Round.lua
	The paper round's rules: throwing, where a paper lands, subscribers kept and lost, bundles, the score.
	Ticked with the ride (Game/Drive.lua, 30 a second); no game API in here, so a test can run it alone.

	  Rd:Setup(ride)          a new ride's round: papers, score, an empty sky
	  Rd:Tick(ride)           one fixed step (after the trike has moved)
	  Rd:Throw(ride)          ask for a throw (taken at the next tick if the trike is free and has papers)
	  Rd:Event(ride, k)       the k-th event since the last Drain (for the stage, the sound, the tests)
	  Rd:Drain(ride)          -> the number of events waiting; Rd:Clear(ride) forgets them

	A throw. The throw animation lets go of the paper on its 3rd frame (16 fps: 4 ticks in); a new throw
	can start once the animation is over (12 ticks). The paper keeps the trike's speed along the road and
	flies toward the houses in an arc: height (px above the ground) h = H0 + VH0 t - G t^2 / 2.
	Thrown from the sidewalk it reaches the house fronts at window height; from the middle of the road it
	arrives low, at the door, and from the far side of the road it lands on the lawn. So where the trike
	is across the road chooses the target and the moment of the throw chooses which one along the road.

	What a paper can meet, in the order it would:
	  a bundle?      no: bundles are picked up by riding over them
	  a mailbox      within MAIL_R of it on the ground and below its top (h1): a subscriber's mailbox is the
	                 best delivery; a non-subscriber's is smashed (bonus)
	  a yard piece   (breakable) within BREAK_R and low: smashed (bonus at a non-subscriber's, and a
	                 subscriber's is lost)
	  the house front, on reaching its wall line (b = face, a little behind the foot of the steps), by
	                 where the paper is DRAWN then: over a window, it breaks (bonus at a non-subscriber's;
	                 a subscriber is lost); over the door or its steps, a doorstep delivery; elsewhere on
	                 the front, it hits the wall, stops and drops
	  the ground     h <= 0: lands. On a door's steps it is a doorstep delivery; elsewhere it lies there.

	Subscribers: one delivery each counts (mailbox or doorstep); a subscriber whose house falls behind
	without one is lost, and so is one whose window or mailbox the paper breaks. Kept subscribers earn a
	bonus at the end of the lane. ]]

local _, ns = ...
local P = ns.P
local Rd = P:Module("Round")

local TPS = 30
local DT = 1 / TPS

Rd.PAPERS, Rd.MAX_PAPERS, Rd.BUNDLE = 10, 15, 5
Rd.RELEASE_TICK = 4          -- the throw animation's 3rd frame at 16 fps: (3 - 1) / 16 s = 3.75 ticks
Rd.THROW_TICKS = 12          -- the animation's 6 frames: 0.375 s
Rd.VB = 9.0                  -- tiles a second toward the houses: a hard, nearly flat throw
Rd.H0, Rd.VH0, Rd.G = 28, 60, 120    -- px: the hand's height, a slight lift, a gentle drop
-- (tuned against all three house designs with the mailboxes in place, gazette/throw_sim2.py: from every
-- lane the moment of the throw picks the mailbox, the door or a window; the paper passes the mailbox
-- at its own height, so it goes in rather than over)
Rd.MAIL_R, Rd.BREAK_R = 0.45, 0.45   -- tiles
Rd.NEAR = 0.4                        -- tiles before the wall line where a paper drawn over a window hits it
Rd.BREAK_H = 45                      -- px: a yard piece's height
Rd.PICK_A, Rd.PICK_B = 0.7, 0.6      -- tiles: riding this close to a bundle picks it up
Rd.STEP_A = 0.9                      -- tiles along the road either side of a door that its steps cover
Rd.LOST_BEHIND = 3                   -- tiles: a house this far behind the trike can no longer be delivered to
Rd.FLY = 4                           -- papers in the air at once (one throw every 0.4 s, each flies < 1 s)

Rd.SCORE = {
	mail = 250,          -- a subscriber's mailbox
	door = 100,          -- a subscriber's doorstep
	window = 200,        -- a non-subscriber's window (the hardest target, worth twice a doorstep)
	smash = 150,         -- a non-subscriber's mailbox
	yard = 75,           -- a non-subscriber's yard piece
	kept = 50,           -- each subscriber kept, at the end of the lane
	subWindow = -150,    -- breaking a subscriber's window costs points (and the subscriber)
	subYard = -50,       -- so does smashing a subscriber's yard piece
}

local EVENTS = 32        -- a ring of reused event tables (a tick makes a handful at most)

-- ------------------------------------------------------------------ setup
function Rd:Setup(r)
	r.score, r.papers = 0, self.PAPERS
	r.throwT, r.throwReq = nil, false
	r.stats = r.stats or {}
	local s = r.stats
	s.mail, s.door, s.windows, s.smashed, s.yard, s.thrown, s.lost, s.kept, s.bonus = 0, 0, 0, 0, 0, 0, 0, 0, 0
	s.penalty = 0
	s.glass, s.escapes, s.falls = 0, 0, 0     -- (for the trophies: non-subscribers' windows, chasers left behind, crashes and catches)
	r.fly = r.fly or {}
	for k = 1, self.FLY do
		local p = r.fly[k] or {}
		p.on = false
		r.fly[k] = p
	end
	r.ev = r.ev or {}
	for k = 1, EVENTS do r.ev[k] = r.ev[k] or {} end
	r.evN = 0
	r.houseNext = 1          -- the first house not yet settled (delivered, lost, or a non-subscriber passed)
	r.bundleNext = 1
	local subs = 0
	for _, h in ipairs(r.route.houses) do if h.sub then subs = subs + 1 end end
	r.subs = subs
	if r.route.bonus then P.Bonus:Setup(r) end
end

-- ------------------------------------------------------------------ events
local function Emit(r, what, tgt, a, b, h, pts)
	local n = r.evN + 1
	if n > EVENTS then return end
	r.evN = n
	local e = r.ev[n]
	e.what, e.tgt, e.a, e.b, e.h, e.pts = what, tgt, a, b, h or 0, pts or 0
end
Rd.Emit = Emit           -- for the hazards (Game/Hazards.lua): one event stream for the stage and the tests
function Rd:Drain(r) return r.evN end
function Rd:Event(r, k) return r.ev[k] end
function Rd:Clear(r) r.evN = 0 end

-- the score never goes below nothing; a penalty takes off only what there is (and is counted as such)
local function Score(r, pts)
	if pts < 0 then
		local take = math.max(pts, -r.score) + 0      -- (+ 0: never a "-0")
		r.score = r.score + take
		r.stats.penalty = r.stats.penalty - take
		return take
	end
	r.score = r.score + pts
	return pts
end

Rd.Score = function(r, pts) return Score(r, pts) end

local function Lose(r, h, why)
	if not h.sub or h.lost then return end
	h.lost = true
	r.stats.lost = r.stats.lost + 1
	Emit(r, "lost", h, h.a, h.b, 0, 0)
end

-- ------------------------------------------------------------------ throwing
function Rd:Throw(r)
	if r.phase == "ride" and not r.throwReq then
		r.throwReq = true
		local log = r.log
		if log then log[#log + 1] = r.tick * 16 + 8 end
	end
end

local function Launch(r)
	for k = 1, Rd.FLY do
		local p = r.fly[k]
		if not p.on then
			p.on = true
			p.a, p.b, p.h = r.a, r.b, Rd.H0
			p.pa, p.pb, p.ph = p.a, p.b, p.h
			p.va = r.v                     -- keeps the trike's speed along the road
			p.vh = Rd.VH0
			p.vb = r.route.bonus and -Rd.VB or Rd.VB    -- on the Bonus Track, to the right (the far side)
			p.air = r.air and true or false             -- thrown in the air (Bonus Track): double points
			p.t = 0
			p.spin = 0
			p.landed = false
			Emit(r, "throw", nil, p.a, p.b, p.h, 0)
			return p
		end
	end
end

local function Drop(p)
	-- stopped by a wall or a mailbox post: falls where it is
	p.vb, p.va = 0, p.va * 0.4
	if p.vh > 0 then p.vh = 0 end
end

-- ------------------------------------------------------------------ what the paper meets
local function Near(x, y, r_) return x * x + y * y <= r_ * r_ end

local function HitMailbox(r, p, m)
	local h = m.house
	if m.state ~= "ok" then return false end
	if not Near(p.a - m.a, p.b - m.b, Rd.MAIL_R) or p.h > m.h1 then return false end
	if h.sub then
		if not h.got and not h.lost then
			h.got = "mail"
			r.stats.mail = r.stats.mail + 1
			m.state = "hit"
			Emit(r, "mail", m, m.a, m.b, p.h, Score(r, Rd.SCORE.mail))
		else
			Emit(r, "bump", m, p.a, p.b, p.h, 0)
		end
	else
		m.state = "broken"
		r.stats.smashed = r.stats.smashed + 1
		Emit(r, "smash", m, m.a, m.b, p.h, Score(r, Rd.SCORE.smash))
	end
	p.on = false            -- a paper in a mailbox (or through one) is spent
	return true
end

local function HitYard(r, p, bk)
	if bk.state ~= "ok" then return false end
	if not Near(p.a - bk.a, p.b - bk.b, Rd.BREAK_R) or p.h > Rd.BREAK_H then return false end
	bk.state = "broken"
	local h = bk.house
	if h.sub then
		Lose(r, h, "yard")
		Emit(r, "yard", bk, bk.a, bk.b, p.h, Score(r, Rd.SCORE.subYard))
	else
		r.stats.yard = r.stats.yard + 1
		Emit(r, "yard", bk, bk.a, bk.b, p.h, Score(r, Rd.SCORE.yard))
	end
	Drop(p)
	return true
end

-- the paper reached the house's wall line between its last position and this one: what it is drawn over
-- there (screen px from the house's pivot) is what it hits
local function Break(r, p, h, w, a, ht, plane)
	if w.broken then
		Emit(r, "wall", h, a, h.face, ht, 0)
	else
		w.broken = true
		h.broken = true
		r.stats.windows = r.stats.windows + 1
		if h.sub then
			Lose(r, h, "window")
			Emit(r, "window", h, a, h.face, ht, Score(r, Rd.SCORE.subWindow))
		else
			r.stats.glass = r.stats.glass + 1
			Emit(r, "window", h, a, h.face, ht, Score(r, Rd.SCORE.window))
		end
	end
	p.b = math.min(p.b, (plane or h.face) - 0.05)
	Drop(p)
end

local function HitFront(r, p, h)
	-- a window on its own plane (Route: drawn higher or lower than a paper reaches at the wall line)
	if p.h >= 0 then
		for _, w in ipairs(h.win) do
			local wf = w.face
			if wf and p.pb < wf and p.b >= wf then
				local f = (wf - p.pb) / (p.b - p.pb)
				local a = p.pa + (p.a - p.pa) * f
				local ht = p.ph + (p.h - p.ph) * f
				local X = 32 * ((a - h.pa) - (wf - h.pb))
				local Y = 16 * ((a - h.pa) + (wf - h.pb)) + ht
				if X >= w.x0 and X <= w.x1 then
					if not w.broken and Y >= w.y0 and Y <= w.y1 then
						Break(r, p, h, w, a, ht, wf)
						return true
					elseif wf > h.face then
						-- past the wall line in this window's column, but not into it: the wall here
						Emit(r, "wall", h, a, wf, ht, 0)
						p.b = wf - 0.05
						Drop(p)
						return true
					end
				end
			end
		end
	end
	-- close to the front (the art's fronts are not quite parallel to the road, so a window can stand a
	-- little nearer than the wall line): a paper DRAWN over a window there has hit it
	if p.b >= h.face - Rd.NEAR and p.b < h.face and p.h >= 0 and p.vb > 0 then
		local X = 32 * ((p.a - h.pa) - (p.b - h.pb))
		local Y = 16 * ((p.a - h.pa) + (p.b - h.pb)) + p.h
		-- ...but only when it is heading INTO that window: carried on to the front, it would still be over
		-- it (a paper on its way to the door is drawn across the far window just before it gets there)
		local af = p.a + p.va * (h.face - p.b) / p.vb
		local Xf = 32 * ((af - h.pa) - (h.face - h.pb))
		for _, w in ipairs(h.win) do
			if not w.face and not w.broken and X >= w.x0 and X <= w.x1 and Xf >= w.x0 and Xf <= w.x1 and Y >= w.y0 and Y <= w.y1 then
				Break(r, p, h, w, p.a, p.h)
				return true
			end
		end
	end
	if not (p.pb < h.face and p.b >= h.face) then return false end
	local f = (h.face - p.pb) / (p.b - p.pb)
	local a = p.pa + (p.a - p.pa) * f
	local ht = p.ph + (p.h - p.ph) * f
	local X = 32 * ((a - h.pa) - (h.face - h.pb))
	local Y = 16 * ((a - h.pa) + (h.face - h.pb)) + ht
	if X < h.wall.x0 or X > h.wall.x1 or ht < 0 then return false end
	for _, w in ipairs(h.win) do
		if not w.face and X >= w.x0 and X <= w.x1 and Y >= w.y0 and Y <= w.y1 then
			Break(r, p, h, w, a, ht)
			return true
		end
	end
	local d = h.door
	if d and X >= d.x0 and X <= d.x1 and Y >= d.y0 and (Y <= d.y1 or d.cut) then
		if h.sub and not h.got and not h.lost then
			h.got = "door"
			r.stats.door = r.stats.door + 1
			Emit(r, "door", h, a, h.face, ht, Score(r, Rd.SCORE.door))
		else
			Emit(r, "wall", h, a, h.face, ht, 0)
		end
		p.b = h.face - 0.05
		Drop(p)
		return true
	end
	-- in the column of a window that stands behind the wall line: on toward it
	for _, w in ipairs(h.win) do
		if w.face and w.face > h.face and not w.broken then
			local Xw = 32 * ((a - h.pa) - (w.face - h.pb))      -- (roughly where it will be at that plane)
			if Xw >= w.x0 - 16 and Xw <= w.x1 + 16 then return false end
		end
	end
	Emit(r, "wall", h, a, h.face, ht, 0)
	p.b = h.face - 0.05
	Drop(p)
	return true
end

local function Land(r, p)
	p.h, p.landed, p.on = 0, true, false
	-- in front of a door: the doorstep
	local hs = r.route.houses
	for k = r.houseNext, #hs do
		local h = hs[k]
		if h.a - 4 > p.a then break end
		if math.abs(p.a - h.doorA) <= Rd.STEP_A and p.b >= h.step - 0.2 and p.b <= h.face then
			if h.sub and not h.got and not h.lost then
				h.got = "door"
				r.stats.door = r.stats.door + 1
				Emit(r, "door", h, p.a, p.b, 0, Score(r, Rd.SCORE.door))
				return
			end
		end
	end
	Emit(r, "land", nil, p.a, p.b, 0, 0)
end

local function Fly(r, p)
	p.pa, p.pb, p.ph = p.a, p.b, p.h
	p.t = p.t + DT
	p.a = p.a + p.va * DT
	p.b = p.b + p.vb * DT
	p.vh = p.vh - Rd.G * DT
	p.h = p.h + p.vh * DT
	p.spin = p.spin + DT
	if r.route.bonus then
		if P.Bonus:HitTargets(r, p) then return end
		if p.h <= 0 then Land(r, p) end
		return
	end
	-- only the houses near the paper are looked at
	local hs = r.route.houses
	for k = r.houseNext, #hs do
		local h = hs[k]
		if h.a - 5 > p.a then break end
		if h.mailbox and HitMailbox(r, p, h.mailbox) then return end
		if h.breakable and HitYard(r, p, h.breakable) then return end
		if HitFront(r, p, h) then
			if p.h <= 0 then Land(r, p) end
			return
		end
	end
	if p.h <= 0 then Land(r, p) end
end

-- ------------------------------------------------------------------ the tick
function Rd:Tick(r)
	if r.phase ~= "ride" then return end
	local tick = r.tick
	-- a throw: starts when asked if the last one is over and a paper is left; lets go on its 3rd frame
	if r.throwReq and (r.fallen or r.skid) then r.throwReq = false end     -- no throwing while down or skidding
	if r.throwReq then
		r.throwReq = false
		if (not r.throwT or tick - r.throwT >= self.THROW_TICKS) and r.papers > 0 then
			r.throwT = tick
			r.papers = r.papers - 1
			r.stats.thrown = r.stats.thrown + 1
		elseif r.papers <= 0 then
			Emit(r, "empty", nil, r.a, r.b, 0, 0)
		end
	end
	if r.throwT and tick - r.throwT == self.RELEASE_TICK then Launch(r) end
	for k = 1, self.FLY do
		local p = r.fly[k]
		if p.on then Fly(r, p) end
	end
	-- bundles
	local bs = r.route.bundles
	while r.bundleNext <= #bs and bs[r.bundleNext].a < r.a - 2 do r.bundleNext = r.bundleNext + 1 end
	for k = r.bundleNext, #bs do
		local bd = bs[k]
		if bd.a - 2 > r.a then break end
		if not bd.taken and math.abs(bd.a - r.a) <= self.PICK_A and math.abs(bd.b - r.b) <= self.PICK_B then
			bd.taken = true
			local before = r.papers
			r.papers = math.min(self.MAX_PAPERS, r.papers + self.BUNDLE)
			Emit(r, "pickup", bd, bd.a, bd.b, 0, r.papers - before)
		end
	end
	-- houses left behind: settled (a subscriber without a paper is lost)
	local hs = r.route.houses
	while r.houseNext <= #hs and hs[r.houseNext].a + self.LOST_BEHIND < r.a do
		local h = hs[r.houseNext]
		if h.sub and not h.got then Lose(r, h, "missed") end
		r.houseNext = r.houseNext + 1
	end
end

-- the end of the lane: every house still ahead is settled, and kept subscribers are counted
function Rd:Finish(r)
	local hs = r.route.houses
	for k = r.houseNext, #hs do
		local h = hs[k]
		if h.sub and not h.got then Lose(r, h, "missed") end
	end
	r.houseNext = #hs + 1
	local kept = 0
	for _, h in ipairs(hs) do if h.sub and not h.lost then kept = kept + 1 end end
	r.stats.kept = kept
	r.stats.bonus = kept * self.SCORE.kept
	r.score = r.score + r.stats.bonus
end

-- the paper's pose for drawing: blended between its last two ticks
function Rd:PaperAt(p, alpha)
	return p.pa + (p.a - p.pa) * alpha, p.pb + (p.b - p.pb) * alpha, p.ph + (p.h - p.ph) * alpha
end
