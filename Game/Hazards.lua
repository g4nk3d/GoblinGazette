--[[ Goblin Gazette - Game/Hazards.lua
	What can stop the round: obstacles on the road, a chicken crossing, an oncoming horse and cart, and the
	kobolds that lurk in yards and chase the trike. Lives, the crash, being caught, and getting going again.
	Ticked with the ride (30 a second), after the trike has moved; no game API in here.

	  Hz:Setup(ride)          lives, an empty street of actors
	  Hz:Tick(ride)           one fixed step
	  Hz:Busy(ride)           -> true while the trike is down (crashed or caught): no riding, no throwing
	  Hz:Safe(ride)           -> true while the trike can't be hurt (just back up after a fall)

	Actors (ride.actors, a fixed pool reused): { on, kind, a, b, pa, pb, state, t, dir, anim }
	  crosser   walks across the road from one side to the other (dir 1: toward the houses)
	  vehicle   comes down the far lane toward the trike
	  chaser    lurk (in a yard) -> burst (out toward the road) -> run (after the trike, a little faster
	            than cruising: speed up to get away) -> grab (caught) or giveup (left behind, +bonus)
	A crash or a catch costs a life. The trike stays down for a moment (the crash plays, then the rider is
	dazed), gets going at the slow speed and can't be hurt for a short while. No lives left: the round ends.

	  Hz:Danger(ride)         -> true while a kobold is chasing, or lurks just up the lane (the music's chase mix)

	Events (through the round's stream): "crash", "caught", "escape", "recover", "out", and for the sound:
	"alert" (a kobold bursts out of its yard), "horn" (the cart is coming). ]]

local _, ns = ...
local P = ns.P
local Hz = P:Module("Hazards")

local TPS = 30
local DT = 1 / TPS

Hz.LIVES = 3
Hz.CRASH_TICKS = 54          -- the crash animation (10 frames at 14 fps: 0.71 s), then dazed: 1.8 s down
Hz.CAUGHT_TICKS = 48         -- the caught animation (8 frames at 12 fps: 0.67 s), then a moment: 1.6 s
Hz.SAFE_TICKS = 45           -- 1.5 s after getting up
Hz.ACTORS = 6                -- moving actors at once
Hz.WAKE = 16                 -- tiles ahead of the trike at which a moving actor starts
Hz.HIT_OBSTACLE = { 0.5, 0.42 }     -- tiles: along the road, across it
Hz.HIT_CROSSER = { 0.4, 0.4 }
Hz.HIT_VEHICLE = { 1.0, 0.5 }
Hz.CROSS_SPEED = 1.5         -- tiles a second across the road
Hz.CART_SPEED = 3.0          -- tiles a second down the road (toward the trike)
Hz.CART_B = -2.3
Hz.CHASE_SPEED = 5.0         -- faster than cruising (4.2), slower than fast (6.4)
Hz.CHASE_LEVEL = 0.12        -- and a little faster on each later route (Stranglethorn: 5.48)
Hz.SPLASH_TICKS = 54         -- into the water: the splash (8 frames at 14 fps: 0.57 s), then a soggy moment
Hz.WATER_IN = { 0.18, 0.14 } -- tiles the hit area stays inside a puddle's drawn edge (along, across)
Hz.CHASE_TURN = 2.6          -- tiles a second across the road toward the trike
Hz.CHASE_WAKE = 1.5          -- tiles: a kobold bursts out when the trike is this close along the road
Hz.CHASE_TIME = 7 * TPS      -- it gives up after this long, or when left this far behind:
Hz.CHASE_LOST = 4.5
Hz.GRAB = 0.5                -- tiles
Hz.BURST_TICKS = 13          -- 6 frames at 14 fps
Hz.GIVEUP_TICKS = 18         -- 6 frames at 10 fps, then it stays put until left behind
Hz.ESCAPE_BONUS = 50
Hz.HORN_AT = 7               -- tiles: the cart sounds its horn this far ahead of the trike
Hz.DANGER_AHEAD = 8          -- tiles: a lurking kobold this close ahead brings the chase music in early

local Rd

function Hz:Setup(r)
	Rd = Rd or P.Round
	r.lives = self.LIVES
	r.fallen, r.downT, r.downKind = false, 0, nil
	r.safeUntil = -1
	r.out = false
	r.spawnNext = 1
	r.actors = r.actors or {}
	for k = 1, self.ACTORS do
		local x = r.actors[k] or {}
		x.on = false
		r.actors[k] = x
	end
end

function Hz:Busy(r) return r.fallen end
function Hz:Safe(r) return r.tick < r.safeUntil end

-- the trike goes down
local function Down(r, kind, actor)
	r.fallen, r.downT, r.downKind = true, r.tick, kind
	r.v = 0
	r.up, r.down, r.fast, r.slow = false, false, false, false        -- held controls let go
	r.throwReq = false
	r.lives = r.lives - 1
	r.stats.falls = r.stats.falls + 1
	if actor then actor.state, actor.t = "grab", 0 end
	Rd.Emit(r, kind, actor, r.a, r.b, 0, 0)
end

local function Near(dx, dy, box) return math.abs(dx) <= box[1] and math.abs(dy) <= box[2] end

local function Free(r)
	for k = 1, Hz.ACTORS do
		local x = r.actors[k]
		if not x.on then return x end
	end
end

local function Start(r, sp)
	local x = Free(r)
	if not x then return end
	x.on, x.kind, x.t, x.state = true, sp.kind, 0, nil
	if sp.kind == "crosser" then
		x.dir = sp.dir
		x.a = sp.a
		x.b = sp.dir > 0 and -3.8 or 2.4
		x.state = "walk"
	elseif sp.kind == "vehicle" then
		x.a, x.b = sp.a + 4, Hz.CART_B
		x.state = "drive"
		x.honked = false
	else
		x.a, x.b = sp.a, sp.b
		x.state = "lurk"
	end
	x.pa, x.pb = x.a, x.b
end

local function Actor(r, x)
	x.pa, x.pb = x.a, x.b
	x.t = x.t + 1
	local safe = Hz:Safe(r) or r.fallen
	if x.kind == "crosser" then
		x.b = x.b + x.dir * Hz.CROSS_SPEED * DT
		if (x.dir > 0 and x.b > 2.6) or (x.dir < 0 and x.b < -4.0) or x.a < r.a - 14 then x.on = false return end
		if not safe and Near(x.a - r.a, x.b - r.b, Hz.HIT_CROSSER) then Down(r, "crash", nil) end
	elseif x.kind == "vehicle" then
		x.a = x.a - Hz.CART_SPEED * DT
		if x.a < r.a - 14 then x.on = false return end
		if not x.honked and x.a - r.a < Hz.HORN_AT then
			x.honked = true
			Rd.Emit(r, "horn", x, x.a, x.b, 0, 0)
		end
		if not safe and Near(x.a - r.a, x.b - r.b, Hz.HIT_VEHICLE) then Down(r, "crash", nil) end
	else
		local st = x.state
		if st == "lurk" then
			if r.a > x.a - Hz.CHASE_WAKE and not r.fallen then
				x.state, x.t = "burst", 0
				Rd.Emit(r, "alert", x, x.a, x.b, 0, 0)
			end
			if x.a < r.a - 14 then x.on = false end
		elseif st == "burst" then
			-- out of the yard toward the sidewalk
			x.b = x.b - 3.0 * DT
			if x.t >= Hz.BURST_TICKS then x.state, x.t = "run", 0 end
		elseif st == "run" then
			-- after the trike: full pelt when it is ahead, closing in more slowly when it is still behind
			local da = r.a - x.a
			if da > 0 then x.a = x.a + (Hz.CHASE_SPEED + Hz.CHASE_LEVEL * ((r.route.level or 1) - 1)) * DT
			else x.a = x.a + math.max(da, -1.5 * DT) end
			local db = r.b - x.b
			local step = Hz.CHASE_TURN * DT
			if db > step then db = step elseif db < -step then db = -step end
			x.b = x.b + db
			if x.t > Hz.CHASE_TIME or x.a < r.a - Hz.CHASE_LOST then
				x.state, x.t = "giveup", 0
				if not r.fallen then
					r.stats.escapes = r.stats.escapes + 1
					Rd.Emit(r, "escape", x, x.a, x.b, 0, Rd.Score(r, Hz.ESCAPE_BONUS))
				end
			elseif not safe and Near(x.a - r.a, x.b - r.b, { Hz.GRAB, Hz.GRAB }) then
				x.a = r.a - 0.35
				Down(r, "caught", x)
			end
		elseif st == "grab" then
			-- holds on while the trike is down, then lets go
			if not r.fallen then x.state, x.t = "giveup", 0 end
		elseif st == "giveup" then
			if x.a < r.a - 14 then x.on = false end
		end
	end
end

function Hz:Tick(r)
	if r.phase ~= "ride" then return end
	local tick = r.tick
	-- down: the crash or catch plays out, then up again (or out of lives)
	if r.fallen then
		local len = r.downKind == "caught" and self.CAUGHT_TICKS or r.downKind == "splash" and self.SPLASH_TICKS or self.CRASH_TICKS
		if tick - r.downT >= len then
			if r.lives <= 0 then
				r.out = true
				Rd.Emit(r, "out", nil, r.a, r.b, 0, 0)
			else
				r.fallen = false
				r.safeUntil = tick + self.SAFE_TICKS
				r.v = P.Drive.SPEED.slow
				Rd.Emit(r, "recover", nil, r.a, r.b, 0, 0)
			end
		end
	end
	-- obstacles in the trike's way
	if not r.fallen and not self:Safe(r) then
		local os = r.route.obstacles
		for k = 1, #os do
			local o = os[k]
			if o.a > r.a + 1 then break end
			if o.a > r.a - 1 and Near(o.a - r.a, o.b - r.b, self.HIT_OBSTACLE) then
				Down(r, "crash", nil)
				break
			end
		end
	end
	-- water on the road (the later routes): riding into a puddle is a splash
	local ws = r.route.water
	if ws and not r.fallen and not self:Safe(r) then
		for k = 1, #ws do
			local w = ws[k]
			if w.a - w.ra > r.a then break end
			if w.a + w.ra > r.a then
				local da = (r.a - w.a) / (w.ra - self.WATER_IN[1])
				local db = (r.b - w.b) / (w.rb - self.WATER_IN[2])
				if da * da + db * db <= 1 then
					Down(r, "splash", nil)
					break
				end
			end
		end
	end
	-- moving actors start as the trike comes near their spot
	local sp = r.route.spawns
	while r.spawnNext <= #sp and sp[r.spawnNext].a < r.a + self.WAKE do
		Start(r, sp[r.spawnNext])
		r.spawnNext = r.spawnNext + 1
	end
	for k = 1, self.ACTORS do
		local x = r.actors[k]
		if x.on then Actor(r, x) end
	end
end

function Hz:Danger(r)
	if r.phase ~= "ride" then return false end
	for k = 1, self.ACTORS do
		local x = r.actors[k]
		if x.on and x.kind == "chaser" then
			local st = x.state
			if st == "burst" or st == "run" or st == "grab" then return true end
			if st == "lurk" and x.a > r.a - 0.5 and x.a - r.a < self.DANGER_AHEAD then return true end
		end
	end
	return false
end

-- the actor's pose for drawing, blended between its last two ticks
function Hz:ActorAt(x, alpha)
	return x.pa + (x.a - x.pa) * alpha, x.pb + (x.b - x.pb) * alpha
end
