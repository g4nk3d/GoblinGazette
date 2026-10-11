--[[ Goblin Gazette - UI/Stage.lua
	The scrolling street. Everything in the world sits on one "world" frame inside a clipping stage frame;
	following the trike is one SetPoint on the world frame per drawn frame, so a route can be any length.

	  St:Build(parent, w, h)         the stage (clips its children) and its pools
	  St:Load(route)                 start a route: forget the old street, place the ground
	  St:Update(ride, alpha, dt)     draw: blend the ride between its last two ticks by alpha (0..1)
	  St:Reset()                     hide everything (the window closed or a new route)
	  St.camX, St.camY               where the trike's ground point sits on the stage (px from top-left)

	What is drawn:
	  ground   copies of the zone's street picture, one every 16 tiles (BACKGROUND layer of the world frame)
	  decals   flat ground pieces such as garden paths (BORDER layer, above the ground, below the rest)
	  sprites  upright scenery and actors: small frames whose frame levels order them by depth, nearer
	           (lower a + b) in front. Scenery never moves against the world, so it is given a level once,
	           when it appears; only the trike's level is checked each frame.
	Scenery appears when it comes within AHEAD tiles of the trike and goes back to its pool BEHIND tiles
	after it; pools grow by count and are never rebuilt. ]]

local _, ns = ...
local P = ns.P
local St = P:Module("Stage")
local A = P.Assets
local W = ns.World

local floor = math.floor
local GW, GH, GAX, GAY, EVERY = W.ground.w, W.ground.h, W.ground.ax, W.ground.ay, W.ground.every
local NG = 4                       -- ground copies
local AHEAD, BEHIND = 24, 14       -- tiles: the farthest any piece can be seen from the trike, with a margin
local PER_FRAME = 3                -- pieces brought in per drawn frame while riding (AHEAD leaves plenty of slack:
                                   -- even at full speed the trike covers about 0.1 tile a frame)
local WARM_SPRITES, WARM_DECALS = 64, 12  -- pool frames made up front, so riding never has to make one
local NFX, NPOP, NANIM = 6, 5, 6         -- effects, score pops and art animations playing at once
local DIM_DESAT, DIM_SHADE = 0.6, 0.78   -- a house that doesn't take the paper: greyer and a little darker
local POP_UP, POP_TIME = 34, 0.9         -- a score pop rises this many px over this many seconds
St.camX, St.camY = 330, 462

local stage, world
local grounds, decals, sprites = {}, {}, {}
local groundK = {}          -- copy index -> the 16-tile stretch it shows (or nil)
local route
local nextIdx = 1           -- the next route entry to bring in
local live = {}             -- route index -> pooled piece now showing it
local liveList, liveN = {}, 0
local REF = 0               -- depth reference: levels are 100 + (REF - (a + b)) * 10
local trike, trikeLevel
local zone
local papers, shadows = {}, {}     -- one per paper the rules can have in the air
local fxs, pops, anims = {}, {}, {}
local actors = {}                  -- one drawn sprite per actor slot the hazards can have
local stars, swirl = {}, nil       -- the dizzy effect, drawn on the trike's own frame
local Hz
local STARS = 4
local DIZZY_X, DIZZY_UP = -5.5, 36 -- px from the trike's pivot: just above the rider's head on the crash's last frames
local ORBIT_X, ORBIT_Y = 23, 8     -- px: the stars' oval (flat: they circle the head in the street's own angle)
local ORBIT_SPEED = 3.2            -- radians a second
local DIZZY_FROM = 7               -- the crash frame the stars start on (the rider has landed)
local Rd                           -- the round's rules (Game/Round.lua), for the throw timing and paper poses
local Bn                           -- the Bonus Track's rules (Game/Bonus.lua): the trike's height, its jump
local trikeShadow                  -- under the trike while it is up a ramp or in the air
local LIFT_LEVEL = 40              -- up a ramp or in the air the trike is drawn over what it passes

-- textures move by fractions of a pixel as the street scrolls: without this they would snap and shimmer
local function Smooth(t)
	if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
	if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

-- world (a, b) to the world frame's own coordinates (px, y up)
local function WX(a, b) return 32 * (a - b) end
local function WY(a, b) return 16 * (a + b) end
St.WX, St.WY = WX, WY

function St:Build(parent, w, h)
	stage = CreateFrame("Frame", nil, parent)
	stage:SetSize(w, h)
	stage:SetClipsChildren(true)
	self.frame = stage
	local bg = stage:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	bg:SetColorTexture(0.12, 0.16, 0.08, 1)
	world = CreateFrame("Frame", nil, stage)
	world:SetSize(1, 1)
	world:SetFrameLevel(stage:GetFrameLevel() + 1)
	self.world = world
	for i = 1, NG do
		local t = world:CreateTexture(nil, "BACKGROUND")
		t:SetSize(GW, GH)
		Smooth(t)
		t:Hide()
		grounds[i] = t
	end
	-- the trike: one frame, the ride's picture and its overlays share its canvas and pivot
	trike = CreateFrame("Frame", nil, world)
	trike.body = trike:CreateTexture(nil, "ARTWORK")
	trike.fx = trike:CreateTexture(nil, "ARTWORK", nil, 1)
	trike.dust = trike:CreateTexture(nil, "ARTWORK", nil, 2)
	for _, t in ipairs({ trike.body, trike.fx, trike.dust }) do t:SetAllPoints() Smooth(t) end
	trike:Hide()
	self.trike = trike
	trikeShadow = world:CreateTexture(nil, "BORDER", nil, 3)
	Smooth(trikeShadow)
	A:Sprite(trikeShadow, "paper_shadow")
	trikeShadow:SetSize(58, 22)
	trikeShadow:Hide()
	-- make the pools now (when the window is first built), not one frame at a time during a ride
	for _ = 1, WARM_SPRITES do
		local f = CreateFrame("Frame", nil, world)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints()
		Smooth(f.tex)
		f:Hide()
		sprites[#sprites + 1] = f
	end
	for _ = 1, WARM_DECALS do
		local t = world:CreateTexture(nil, "BORDER")
		Smooth(t)
		t:Hide()
		decals[#decals + 1] = t
	end
	Rd = P.Round
	Hz = P.Hazards
	Bn = P.Bonus
	for k = 1, Hz.ACTORS do
		local f = CreateFrame("Frame", nil, world)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints()
		Smooth(f.tex)
		f:Hide()
		actors[k] = f
	end
	-- the dizzy stars: behind the rider (far side of the orbit) and in front of him (near side), and the
	-- swirl ring under them
	swirl = trike:CreateTexture(nil, "ARTWORK", nil, -2)
	A:Sprite(swirl, "dizzy_swirl")
	Smooth(swirl)
	swirl:Hide()
	for k = 1, STARS do
		local t = trike:CreateTexture(nil, "ARTWORK", nil, 3)
		A:Sprite(t, "dizzy_star")
		Smooth(t)
		t:Hide()
		stars[k] = t
	end
	-- papers in the air: an upright sprite each (sorted by depth like scenery) and a shadow on the ground
	for k = 1, Rd.FLY do
		local f = CreateFrame("Frame", nil, world)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints()
		Smooth(f.tex)
		A:Sprite(f.tex, "paper")
		local s = W.spr.paper
		f:SetSize(s.w, s.h)
		f:Hide()
		papers[k] = f
		local sh = world:CreateTexture(nil, "BORDER", nil, 2)
		Smooth(sh)
		A:Sprite(sh, "paper_shadow")
		local ss = W.spr.paper_shadow
		sh:SetSize(ss.w, ss.h)
		sh:Hide()
		shadows[k] = sh
	end
	-- one-shot effects (glass, the mailbox sparkle), drawn just in front of what they came from
	for k = 1, NFX do
		local f = CreateFrame("Frame", nil, world)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints()
		Smooth(f.tex)
		f:Hide()
		fxs[k] = f
	end
	-- score pops: a number that rises and fades where the points were made
	for k = 1, NPOP do
		local f = CreateFrame("Frame", nil, world)
		f:SetSize(120, 24)
		f.text = f:CreateFontString(nil, "OVERLAY")
		f.text:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
		f.text:SetPoint("CENTER")
		f:SetFrameLevel(9000)
		f:Hide()
		pops[k] = f
	end
	for k = 1, NANIM do anims[k] = {} end
end

local function Level(a, b) return 100 + floor((REF - (a + b)) * 10) end

local function Decal()
	for i = 1, #decals do
		if not decals[i].used then return decals[i] end
	end
	local t = world:CreateTexture(nil, "BORDER")
	Smooth(t)
	decals[#decals + 1] = t
	return t
end

local function Sprite()
	for i = 1, #sprites do
		if not sprites[i].used then return sprites[i] end
	end
	local f = CreateFrame("Frame", nil, world)
	f.tex = f:CreateTexture(nil, "ARTWORK")
	f.tex:SetAllPoints()
	Smooth(f.tex)
	sprites[#sprites + 1] = f
	return f
end

-- the art a target shows now (its base sprite's canvas and pivot are shared by every state)
local function ArtName(i)
	local name, t = route.spr[i], route.tgt[i]
	if not t then return name, false end
	local kind = t.kind
	if kind == "house" then
		return t.broken and (name .. "_broken") or name, not t.sub
	elseif kind == "mailbox" then
		local dim = not t.house.sub
		if t.state == "broken" then return name .. "_broken", dim end
		if t.state == "hit" then
			local an = A:Anim(name .. "_hit")
			return an and an[#an] or name, dim
		end
		return name, dim
	elseif kind == "breakable" then
		return t.state == "broken" and (name .. "_broken") or name, not t.house.sub
	elseif kind == "dummy" and t.state == "hit" then
		local an = A:Anim("bonus_dummy_hit")             -- toppled: its last frame, held
		return an and an[#an] or name, false
	end
	return name, false
end

local function Dim(tex, on)
	if tex.SetDesaturation then tex:SetDesaturation(on and DIM_DESAT or 0)
	elseif tex.SetDesaturated then tex:SetDesaturated(on and true or false) end
	local v = on and DIM_SHADE or 1
	tex:SetVertexColor(v, v, v)
end

local function Paint(p, i)
	local tex = p.tex or p
	local name, dim = ArtName(i)
	A:Sprite(tex, name)
	Dim(tex, dim)
end

-- place a piece showing route entry i
local function Spawn(i)
	local name = route.spr[i]
	local s = W.spr[name]
	if not s then return end
	local t = route.tgt[i]
	if t and t.kind == "bundle" and t.taken then return end
	local a, b = route.a[i], route.b[i]
	local x, y = WX(a, b), WY(a, b)
	local p
	if route.kind[i] == 2 then
		p = Decal()
	else
		p = Sprite()
		p:SetFrameLevel(Level(a, b))
	end
	Paint(p, i)
	p.used = true
	p:SetSize(s.w, s.h)
	p:ClearAllPoints()
	p:SetPoint("TOPLEFT", world, "BOTTOMLEFT", x - s.px, y + s.py)
	p:Show()
	live[i] = p
	liveN = liveN + 1
	liveList[liveN] = i
end

local function Despawn(k)
	local i = liveList[k]
	local p = live[i]
	if p then
		p:Hide()
		p.used = false
		live[i] = nil
	end
	liveList[k] = liveList[liveN]
	liveList[liveN] = nil
	liveN = liveN - 1
end

function St:Reset()
	for k = liveN, 1, -1 do Despawn(k) end
	for i = 1, #grounds do grounds[i]:Hide() groundK[i] = nil end
	if trike then trike:Hide() end
	if trikeShadow then trikeShadow:Hide() end
	for k = 1, #papers do papers[k]:Hide() shadows[k]:Hide() end
	for k = 1, #fxs do fxs[k]:Hide() fxs[k].on = false end
	for k = 1, #pops do pops[k]:Hide() pops[k].on = false end
	for k = 1, #anims do anims[k].on = false end
	for k = 1, #actors do actors[k]:Hide() actors[k].anim = nil end
	if swirl then swirl:Hide() for k = 1, #stars do stars[k]:Hide() end end
	if trike then trike:SetAlpha(1) end
	nextIdx = 1
	route = nil
end

function St:Load(r)
	self:Reset()
	route = r
	if zone ~= r.zone then
		zone = r.zone
		local path = A:Ground(zone)
		for i = 1, #grounds do grounds[i]:SetTexture(path) end
	end
	REF = 400
	trikeLevel = nil
	-- the street in view at the start line is laid out here, behind the start card, rather than in the
	-- first drawn frame; after that pieces come in a few a frame
	local startA = 2                 -- every ride starts at a = 2 (Drive:New)
	while nextIdx <= r.n and r.a[nextIdx] < startA + AHEAD do
		Spawn(nextIdx)
		nextIdx = nextIdx + 1
	end
end

-- the ground copies: stretch k shows a 16k .. 16k + 16 (its picture reaches well across the road).
-- Stretch k always lives in copy k % 4 + 1, so crossing into a new stretch moves one copy, not all four.
local function PlaceGround(camA)
	local k0 = floor((camA - 12) / EVERY)
	for k = k0, k0 + NG - 1 do
		local i = k % NG + 1
		if groundK[i] ~= k then
			local t = grounds[i]
			local x, y = WX(EVERY * k, 0), WY(EVERY * k, 0)
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", world, "BOTTOMLEFT", x - GAX, y + GAY)
			t:Show()
			groundK[i] = k
		end
	end
end

-- scenery levels are 100 + (REF - depth) * 10; a long ride would climb past the frame-level limit, so the
-- reference moves forward now and then and the pieces on show are given their new levels (a few dozen calls)
local function Rebase(camA)
	REF = camA + 400
	for k = 1, liveN do
		local i = liveList[k]
		local p = live[i]
		if route.kind[i] ~= 2 then p:SetFrameLevel(Level(route.a[i], route.b[i])) end
	end
	trikeLevel = nil
end

local animT = 0
local trikeAnim, trikeFrame, fxAnim, fxFrame

local function TrikeArt(r, dt, alpha)
	animT = animT + dt
	local name
	-- a throw plays from the tick it began (its 3rd frame is the tick the paper leaves the hand)
	local throwing = r.throwT and r.phase == "ride" and (r.tick - r.throwT) < Rd.THROW_TICKS
	local fallen = r.fallen or (r.out and r.downKind)
	local bonus = r.route.bonus
	local landing = bonus and r.landT and (r.tick - r.landT) < Bn.LAND_TICKS
	if fallen then
		if r.downKind == "caught" then name = "trike_caught"
		elseif r.downKind == "splash" then name = r.route.zone == "durotar" and "trike_splash_mud" or "trike_splash"
		else name = "trike_crash" end
	elseif throwing then name = bonus and "trike_throw_right" or "trike_throw_left"
	elseif bonus and r.air then name = "trike_jump"
	elseif landing then name = "trike_land"
	elseif bonus and r.skid then name = "trike_brake"
	elseif r.phase == "ready" then name = "trike_idle"
	elseif r.lean == 1 then name = "trike_lean_left"
	elseif r.lean == -1 then name = "trike_lean_right"
	else name = "trike_ride" end
	local an = A:Anim(name)
	if not an then return end
	local i
	if fallen then i = math.min(#an, floor((r.tick - r.downT + alpha) / 30 * an.fps) + 1)
	elseif throwing then i = math.min(#an, floor((r.tick - r.throwT + alpha) / 30 * an.fps) + 1)
	elseif name == "trike_jump" then i = math.min(#an, floor((r.airT + alpha) / 30 * an.fps) + 1)
	elseif name == "trike_land" then i = math.min(#an, floor((r.tick - r.landT + alpha) / 30 * an.fps) + 1)
	elseif name == "trike_brake" then i = math.min(#an, floor((r.skidT + alpha) / 30 * an.fps) + 1)
	elseif an.loop then i = floor(animT * an.fps) % #an + 1
	else i = math.min(#an, floor(r.leanT / 30 * an.fps) + 1) end
	if trikeAnim ~= name then
		trikeAnim = name
		A:Sprite(trike.body, an[i])
		trike:SetSize(an.w, an.h)
		trikeFrame = i
	elseif trikeFrame ~= i then
		A:Coords(trike.body, an[i])
		trikeFrame = i
	end
	-- the exhaust flare while speeding up, the dust while riding fast
	local boost = r.phase == "ride" and r.fast and not r.slow and r.v < 6.3
	local fx = boost and "trike_boost" or nil
	if fx then
		local fa = A:Anim(fx)
		local fi = floor(animT * fa.fps) % #fa + 1
		if fxAnim ~= fx then A:Sprite(trike.fx, fa[fi]) trike.fx:Show() fxAnim = fx fxFrame = fi
		elseif fxFrame ~= fi then A:Coords(trike.fx, fa[fi]) fxFrame = fi end
	elseif fxAnim then
		trike.fx:Hide()
		fxAnim = nil
	end
	if r.phase == "ride" and r.v > 5.2 then
		local da = A:Anim("trike_dust")
		local di = floor(animT * da.fps) % #da + 1
		if not trike.dust.on then A:Sprite(trike.dust, da[di]) trike.dust:Show() trike.dust.on = true trike.dust.i = di
		elseif trike.dust.i ~= di then A:Coords(trike.dust, da[di]) trike.dust.i = di end
	elseif trike.dust.on then
		trike.dust:Hide()
		trike.dust.on = false
	end
end

function St:Update(r, alpha, dt)
	if not route then return end
	local a = r.pa + (r.a - r.pa) * alpha
	local b = r.pb + (r.b - r.pb) * alpha
	-- the camera follows the trike along the road only (swerving moves the trike, not the street)
	local camA, camB = a, -1.5
	if camA > REF - 200 then local tr = P:ProfStart() Rebase(camA) P:ProfEnd("stage: depth reset", tr) end
	local t0 = P:ProfStart()
	world:ClearAllPoints()
	world:SetPoint("BOTTOMLEFT", stage, "TOPLEFT", self.camX - WX(camA, camB), -self.camY - WY(camA, camB))
	P:ProfEnd("stage: scroll", t0)
	t0 = P:ProfStart()
	PlaceGround(camA)
	P:ProfEnd("stage: ground", t0)
	t0 = P:ProfStart()
	-- scenery coming into view, scenery left behind
	local n, brought = route.n, 0
	while nextIdx <= n and brought < PER_FRAME and route.a[nextIdx] < camA + AHEAD do
		Spawn(nextIdx)
		nextIdx = nextIdx + 1
		brought = brought + 1
	end
	P:ProfEnd("stage: new scenery", t0)
	t0 = P:ProfStart()
	local k = 1
	while k <= liveN do
		if route.a[liveList[k]] < camA - BEHIND then Despawn(k) else k = k + 1 end
	end
	P:ProfEnd("stage: old scenery", t0)
	t0 = P:ProfStart()
	-- the trike
	local s = W.spr.trike_ride
	local lift = r.route.bonus and Bn:Height(r, alpha) or 0
	trike:ClearAllPoints()
	trike:SetPoint("TOPLEFT", world, "BOTTOMLEFT", WX(a, b) - s.px, WY(a, b) + lift + s.py)
	local lv = Level(a, b)
	if r.route.bonus and (r.air or r.onRamp) then lv = lv + LIFT_LEVEL end
	if lift > 1 then
		trikeShadow:ClearAllPoints()
		trikeShadow:SetPoint("CENTER", world, "BOTTOMLEFT", WX(a, b), WY(a, b) + 2)
		trikeShadow:SetAlpha(math.max(0.25, 0.8 - lift / 160))
		if not trikeShadow:IsShown() then trikeShadow:Show() end
	elseif trikeShadow:IsShown() then
		trikeShadow:Hide()
	end
	if lv ~= trikeLevel then trike:SetFrameLevel(lv) trikeLevel = lv end
	if not trike:IsShown() then trike:Show() end
	TrikeArt(r, dt, alpha)
	self:Dizzy(r, alpha)
	-- just back up: the trike blinks while nothing can hurt it
	if Hz:Safe(r) and not r.fallen then
		trike:SetAlpha((floor(r.tick / 3) % 2 == 0) and 0.4 or 1)
	elseif trike:GetAlpha() ~= 1 then
		trike:SetAlpha(1)
	end
	P:ProfEnd("stage: trike", t0)
	t0 = P:ProfStart()
	self:Actors(r, alpha, dt)
	P:ProfEnd("stage: actors", t0)
	t0 = P:ProfStart()
	self:Papers(r, alpha)
	self:Effects(dt)
	P:ProfEnd("stage: papers and effects", t0)
end

-- ------------------------------------------------------------------ the dizzy stars
-- Four stars circle the rider's head on a flat oval (the street's angle). Those on the far half pass
-- behind his head (drawn under the trike's picture) and dim a little; each one twinkles (size and
-- brightness) out of step with the others; a pale swirl turns under them. It fades in as the crash
-- lands and out as he gets up.
local dizzyT, dizzyOn = 0, false
function St:Dizzy(r, alpha)
	local on = r.fallen and r.downKind == "crash" and (r.tick - r.downT) / 30 * 14 >= DIZZY_FROM - 1
	if not on then
		if dizzyOn then
			dizzyOn = false
			swirl:Hide()
			for k = 1, STARS do stars[k]:Hide() end
		end
		return
	end
	local t = (r.tick - r.downT + alpha) / 30
	if not dizzyOn then dizzyOn = true dizzyT = t end
	local since = t - dizzyT
	local left = (Hz.CRASH_TICKS - (r.tick - r.downT) - alpha) / 30
	local fade = math.min(1, since / 0.25, math.max(0, left) / 0.3)
	local an = A:Anim(r.downKind == "caught" and "trike_caught" or "trike_crash")
	local px, py = an.px or W.spr.trike_crash.px, an.py or W.spr.trike_crash.py
	local cx, cy = px + DIZZY_X, py - DIZZY_UP            -- in the trike frame, from its top-left (y down)
	local base = since * ORBIT_SPEED
	for k = 1, STARS do
		local tex = stars[k]
		local ang = base + (k - 1) * (2 * math.pi / STARS)
		local sx, sy = math.cos(ang), math.sin(ang)
		local x, y = cx + ORBIT_X * sx, cy - ORBIT_Y * sy  -- sy > 0: the far side (up the screen)
		local tw = 0.5 + 0.5 * math.sin(since * 7 + k * 1.7)
		local size = 27 * (0.75 + 0.4 * tw) * (sy > 0 and 0.85 or 1)
		tex:SetDrawLayer("ARTWORK", sy > 0 and -1 or 3)
		tex:SetSize(size, size)
		tex:ClearAllPoints()
		tex:SetPoint("CENTER", trike, "TOPLEFT", x, -y)
		tex:SetAlpha(fade * (sy > 0 and 0.65 or 1) * (0.7 + 0.3 * tw))
		if not tex:IsShown() then tex:Show() end
	end
	local sw = W.spr.dizzy_swirl
	local pulse = 1.25 + 0.07 * math.sin(since * 5)
	swirl:SetSize(sw.w * pulse, sw.h * pulse)
	swirl:ClearAllPoints()
	swirl:SetPoint("CENTER", trike, "TOPLEFT", cx, -(cy + 1))
	swirl:SetAlpha(fade * (0.55 + 0.2 * math.sin(since * 3.1)))
	if swirl.SetRotation then swirl:SetRotation(0.12 * math.sin(since * 2.3)) end
	if not swirl:IsShown() then swirl:Show() end
end

-- ------------------------------------------------------------------ actors
local ANIM = { crosser = "_crosser", vehicle = "_vehicle", lurk = "_chaser_lurk", burst = "_chaser_burst",
	run = "_chaser_run", grab = "_chaser_grab", giveup = "_chaser_giveup" }
local HOLD = { burst = true, grab = true, giveup = true }   -- one-shot: keep the last frame

function St:Actors(r, alpha, dt)
	local list = r.actors
	if not list then return end
	for k = 1, #actors do
		local x, f = list[k], actors[k]
		if x and x.on then
			local key = x.kind == "chaser" and x.state or x.kind
			local name = zone .. ANIM[key]
			local an = A:Anim(name)
			if an then
				local flip = x.kind == "crosser" and x.dir > 0     -- walking toward the houses: mirrored
				local i
				if HOLD[key] then i = math.min(#an, floor((x.t + alpha) / 30 * an.fps) + 1)
				else i = floor((x.t + alpha) / 30 * an.fps) % #an + 1 end
				if f.anim ~= name or f.flip ~= flip then
					f.anim, f.flip, f.i = name, flip, i
					A:Sprite(f.tex, an[i], flip)
					f:SetSize(an.w, an.h)
				elseif f.i ~= i then
					f.i = i
					A:Coords(f.tex, an[i], flip)
				end
				local a, b = Hz:ActorAt(x, alpha)
				local px = flip and (an.w - an.px) or an.px
				f:ClearAllPoints()
				f:SetPoint("TOPLEFT", world, "BOTTOMLEFT", WX(a, b) - px, WY(a, b) + an.py)
				f:SetFrameLevel(Level(a, b))
				if not f:IsShown() then f:Show() end
			end
		elseif f:IsShown() then
			f:Hide()
			f.anim = nil
		end
	end
end

-- ------------------------------------------------------------------ papers, effects, pops
local function Place(f, x, y, w, h)
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", world, "BOTTOMLEFT", x - w / 2, y + h / 2)
end

function St:Papers(r, alpha)
	local fly = r.fly
	if not fly then return end
	local s, ss = W.spr.paper, W.spr.paper_shadow
	for k = 1, #papers do
		local p, f, sh = fly[k], papers[k], shadows[k]
		if p and p.on then
			local a, b, h = Rd:PaperAt(p, alpha)
			local x, y = WX(a, b), WY(a, b)
			f:ClearAllPoints()
			f:SetPoint("TOPLEFT", world, "BOTTOMLEFT", x - s.px, y + h + s.py)
			f:SetFrameLevel(Level(a, b) + 1)
			if f.tex.SetRotation then f.tex:SetRotation(-(p.spin + alpha / 30) * 14) end
			if not f:IsShown() then f:Show() end
			sh:ClearAllPoints()
			sh:SetPoint("TOPLEFT", world, "BOTTOMLEFT", x - ss.px, y + ss.py)
			sh:SetAlpha(math.max(0.25, 1 - h / 140))
			if not sh:IsShown() then sh:Show() end
		elseif f:IsShown() then
			f:Hide()
			sh:Hide()
		end
	end
end

local function FX(name, a, b, h)
	local an = A:Anim(name)
	if not an then return end
	for k = 1, #fxs do
		local f = fxs[k]
		if not f.on then
			f.on, f.an, f.t, f.i = true, an, 0, 1
			A:Sprite(f.tex, an[1])
			f:SetSize(an.w, an.h)
			Place(f, WX(a, b), WY(a, b) + h, an.w, an.h)
			f:SetFrameLevel(Level(a, b) + 5)
			f:Show()
			return
		end
	end
end

local function Pop(text, a, b, h, r, g, bl)
	for k = 1, #pops do
		local f = pops[k]
		if not f.on then
			f.on, f.t = true, 0
			f.x, f.y = WX(a, b), WY(a, b) + h + 20
			f.text:SetText(text)
			f.text:SetTextColor(r, g, bl)
			Place(f, f.x, f.y, 120, 24)
			f:SetAlpha(1)
			f:Show()
			return
		end
	end
end

-- the art on a live piece plays an animation, then keeps its last frame (the mailbox's flag up)
local function PlayOn(i, name, back)
	local p = live[i]
	local an = A:Anim(name)
	if not (p and an) then return end
	for k = 1, #anims do
		local m = anims[k]
		if not m.on then
			m.on, m.p, m.i, m.an, m.t, m.f, m.back = true, p, i, an, 0, 1, back
			A:Coords(p.tex or p, an[1])
			return
		end
	end
end

function St:Effects(dt)
	for k = 1, #fxs do
		local f = fxs[k]
		if f.on then
			f.t = f.t + dt
			local i = floor(f.t * f.an.fps) + 1
			if i > #f.an then
				f.on = false
				f:Hide()
			elseif i ~= f.i then
				f.i = i
				A:Coords(f.tex, f.an[i])
			end
		end
	end
	for k = 1, #pops do
		local f = pops[k]
		if f.on then
			f.t = f.t + dt
			if f.t >= POP_TIME then
				f.on = false
				f:Hide()
			else
				local u = f.t / POP_TIME
				Place(f, f.x, f.y + POP_UP * u, 120, 24)
				f:SetAlpha(u < 0.6 and 1 or (1 - (u - 0.6) / 0.4))
			end
		end
	end
	for k = 1, #anims do
		local m = anims[k]
		if m.on then
			if live[m.i] ~= m.p then
				m.on = false                       -- the piece went back to its pool
			else
				m.t = m.t + dt
				local i = floor(m.t * m.an.fps) + 1
				if i >= #m.an then
					-- the last frame is kept (the mailbox's flag up), or the piece goes back to its own picture
					A:Coords(m.p.tex or m.p, m.back or m.an[#m.an])
					m.on = false
				elseif i ~= m.f then
					m.f = i
					A:Coords(m.p.tex or m.p, m.an[i])
				end
			end
		end
	end
end

-- something happened in the round (Game/Round.lua events): swap art, play effects, pop the points
local GOLD, PAPER, GREY, RED = { 1, 0.86, 0.35 }, { 0.85, 0.95, 0.7 }, { 0.85, 0.8, 0.75 }, { 1, 0.38, 0.3 }
function St:OnEvent(e)
	if not route then return end
	local t, what = e.tgt, e.what
	local i = t and t.idx
	if i and live[i] and (what == "mail" or what == "smash" or what == "window" or what == "yard" or what == "pickup") then
		if what == "pickup" then
			live[i]:Hide()
		else
			Paint(live[i], i)
		end
	end
	if what == "mail" then
		if i then PlayOn(i, route.spr[i] .. "_hit") end
		FX("fx_mailbox_bonus", t.a, t.b, 30)
	elseif what == "window" then
		FX("fx_glass_shatter", e.a, e.b, e.h)
	elseif what == "target" then
		if i then PlayOn(i, "bonus_target_hit", "bonus_target") end      -- spins, then stands still again
		FX("fx_target_break", t.a, t.b, 50)
	elseif what == "dummy" then
		if i then PlayOn(i, "bonus_dummy_hit") end                       -- topples, and stays down
		FX("fx_target_break", t.a, t.b, 40)
	end
	if e.pts and e.pts > 0 then
		local c = what == "pickup" and PAPER or GOLD
		local air = (what == "target" or what == "dummy") and e.pts > Bn.SCORE[what]
		local label = what == "pickup" and ("+%d papers"):format(e.pts)
			or what == "escape" and ("got away! +%d"):format(e.pts)
			or what == "jump" and ("jump! +%d"):format(e.pts)
			or air and ("in the air! +%d"):format(e.pts) or ("+%d"):format(e.pts)
		Pop(label, e.a, e.b, e.h, c[1], c[2], c[3])
	elseif e.pts and e.pts < 0 then
		Pop(("%d"):format(e.pts), e.a, e.b, e.h, RED[1], RED[2], RED[3])
	elseif what == "crash" or what == "caught" or what == "splash" then
		Pop(what == "caught" and "caught!" or what == "splash" and "splash!" or "crash!", e.a, e.b, 70, RED[1], RED[2], RED[3])
	elseif what == "skid" then
		Pop("slick!", e.a, e.b, 50, GREY[1], GREY[2], GREY[3])
	elseif what == "lost" then
		Pop("subscriber lost", t.doorA or e.a, t.face or e.b, 60, GREY[1], GREY[2], GREY[3])
	end
end

function St:LiveCount() return liveN end
