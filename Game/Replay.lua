--[[ Goblin Gazette - Game/Replay.lua
	A round is the same every time it is played with the same seed and the same inputs at the same ticks: the
	route comes from the seed (Park-Miller, exact in doubles), and the rules (Drive, Round, Hazards, Bonus)
	use nothing but the route, the ride and the held controls. No clock, no random numbers, no game API.

	So a round can be written down as its seed and its inputs, and checked anywhere by playing it again. The
	shared leaderboard (Comm/Leaderboard.lua) stores a score only after this client has replayed it and banked
	exactly that score.

	The log. Drive:Input / Drive:Release / Round:Throw write each change into ride.log as tick * 16 + code
	(codes: 0..7 a control held / let go, 8 a throw, 9 everything let go). The street and its Bonus Track
	are two rides, so two logs.

	  Rp:Track(ride)                      start writing this ride's log
	  Rp:Encode(streetLog, bonusLog)      -> text: [0-9A-Z]* tick gaps, [a-j] codes, "." between the two
	  Rp:Decode(text)                     -> streetLog, bonusLog (or nil for anything malformed)
	  Rp:Start(zone, seed, text)          -> a replay job (or nil)
	  Rp:Step(job, ms)                    plays ticks until `ms` of this frame are used; -> true when finished
	                                      (job.score: the round's score; job.ok: it played through cleanly)
	  Rp:Play(zone, seed, text)           the whole round at once (tests only: a round is ~3000 ticks)
	  Rp.RULES                            raise when anything a round's outcome depends on changes, so old
	                                      scores are never checked against new rules ]]

local _, ns = ...
local P = ns.P
local Rp = P:Module("Replay")

Rp.RULES = 2                         -- 2: harder later routes and water on the road (0.9.0)
Rp.LENGTH = 260                      -- a street's length in tiles (the daily route and every other street)
Rp.MAX_EVENTS = 6000                 -- per ride: ~3 inputs a second for half an hour of riding
Rp.MAX_TICKS = 30 * 600              -- per ride: ten minutes (a street takes about two)
Rp.MAX_TEXT = 40000

local floor, byte, char, sub = math.floor, string.byte, string.char, string.sub
local Dr, Rd, Rt, Bn

local function Mods() Dr, Rd, Rt, Bn = P.Drive, P.Round, P.Route, P.Bonus end

function Rp:Track(r)
	r.log = {}
end

-- ------------------------------------------------------------------ text
local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local CODES = "abcdefghij"

local function Put(out, log)
	local prev = 0
	for i = 1, #log do
		local v = log[i]
		local t, c = floor(v / 16), v % 16
		local d = t - prev
		prev = t
		local s = ""
		if d > 0 then
			while d > 0 do
				local k = d % 36
				s = sub(DIGITS, k + 1, k + 1) .. s
				d = floor(d / 36)
			end
		end
		out[#out + 1] = s .. sub(CODES, c + 1, c + 1)
	end
end

function Rp:Encode(street, bonus)
	local out = {}
	Put(out, street or {})
	out[#out + 1] = "."
	Put(out, bonus or {})
	return table.concat(out)
end

local function Get(text)
	local log, t, d = {}, 0, 0
	for i = 1, #text do
		local b = byte(text, i)
		if b >= 48 and b <= 57 then d = d * 36 + (b - 48)
		elseif b >= 65 and b <= 90 then d = d * 36 + (b - 55)
		elseif b >= 97 and b <= 106 then
			t = t + d
			d = 0
			if t > Rp.MAX_TICKS or #log >= Rp.MAX_EVENTS then return nil end
			log[#log + 1] = t * 16 + (b - 97)
		else
			return nil
		end
	end
	if d ~= 0 then return nil end             -- digits with no code after them
	return log
end

function Rp:Decode(text)
	if type(text) ~= "string" or #text > self.MAX_TEXT then return nil end
	local dot = text:find(".", 1, true)
	if not dot or text:find(".", dot + 1, true) then return nil end
	local a, b = Get(sub(text, 1, dot - 1)), Get(sub(text, dot + 1))
	if not a or not b then return nil end
	return a, b
end

-- ------------------------------------------------------------------ playing it again
-- the inputs logged at this tick, before the tick is taken (in the order they were made)
local function Apply(r, log, at)
	local t = r.tick
	while at <= #log do
		local v = log[at]
		local lt = floor(v / 16)
		if lt > t then break end
		if lt == t then
			local c = v % 16
			if c == 8 then Rd:Throw(r)
			elseif c == 9 then Dr:Release(r)
			elseif c <= 7 then
				local key = c < 2 and "up" or c < 4 and "down" or c < 6 and "slow" or "fast"
				Dr:Input(r, key, c % 2 == 0)
			end
		end
		at = at + 1
	end
	return at
end

local function NewRide(job, route)
	local r = Dr:New(route)
	job.r, job.at, job.ticks = r, 1, 0
	-- (anything held while the start card was up was logged at tick 0, and is applied before the first tick)
	Dr:Start(r)
	return r
end

function Rp:Start(zone, seed, text)
	Mods()
	if type(zone) ~= "string" or not Rt:Zone(zone) or type(seed) ~= "number" or seed < 1 or seed ~= floor(seed) then return nil end
	local street, bonus = self:Decode(text)
	if not street then return nil end
	local job = { zone = zone, seed = seed, log = street, bonusLog = bonus, stage = "street", score = 0, ok = false }
	local ok = pcall(NewRide, job, Rt:Build(zone, seed, self.LENGTH))
	if not ok then return nil end
	return job
end

-- one tick of the job; true when the round is over
local function One(job)
	local r = job.r
	job.at = Apply(r, job.log, job.at)
	Dr:Tick(r)
	Rd:Clear(r)                     -- (nobody draws the events: they'd only fill the ring)
	job.ticks = job.ticks + 1
	if r.phase == "done" then
		if job.stage == "street" and not r.out then
			-- on to the Bonus Track, carrying the score and the trikes left (as the game does)
			local main = r
			job.stage = "bonus"
			job.log = job.bonusLog
			local b = NewRide(job, Bn:Build(main.route.zone, main.route.seed))
			b.main = main
			b.score = main.score
			b.lives = main.lives
			return false
		end
		job.score = r.score
		job.ok = true
		job.out = r.out and true or false
		return true
	end
	if job.ticks > Rp.MAX_TICKS then job.ok = false return true end
	return false
end

local now = debugprofilestop
function Rp:Step(job, ms)
	if job.finished then return true end
	local t0 = now and now()
	local n = 0
	while true do
		local ok, done = pcall(One, job)
		if not ok then job.ok, job.err = false, done done = true end
		n = n + 1
		if done then job.finished = true return true end
		-- check the clock every 4 ticks (a Bonus Track tick is ~20 microseconds)
		if n % 4 == 0 then
			if not t0 or now() - t0 >= ms then return false end
		end
	end
end

function Rp:Play(zone, seed, text)
	local job = self:Start(zone, seed, text)
	if not job then return nil end
	while not job.finished do
		local ok, done = pcall(One, job)
		if not ok then job.ok, job.err, job.finished = false, done, true
		elseif done then job.finished = true end
	end
	return job
end
