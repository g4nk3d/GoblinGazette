--[[ Goblin Gazette - Game/Rewards.lua
	The trophies: twelve achievements (the pack's badges, with the brief's triggers) and a medal for each round.

	MEDALS. A street can be worth more or less than another (how many houses subscribe, how many windows,
	how the Bonus Track is laid out), so a medal is the share of what that street could pay: every subscriber
	in the mailbox and kept, every non-subscriber window, mailbox and yard piece, every Bonus Track target,
	dummy and ramp (air-doubled hits and escaped kobolds are extra on top):
	    bronze 25%    silver 45%    gold 65%   (a full street pays about 13,000: roughly 3,300 / 5,900 / 8,500)
	Each region keeps its best medal (the Editor's Pick wants gold in all five).

	ACHIEVEMENTS (brief 7.9; triggers as listed there):
	  first_delivery   a first paper delivered (mailbox or doorstep)
	  bullseye         50 papers in subscribers' mailboxes (all rounds)
	  perfect_day      every subscriber on a street given a paper
	  full_week        every subscriber kept through a whole route (the street ridden to its end, none lost)
	  glass_act        25 non-subscribers' windows broken (all rounds)
	  outrunner        10 kobolds left behind (all rounds)
	  clean_ride       a whole round, street and Bonus Track, without a crash or a catch
	  trick_rider      5 ramp jumps in one Bonus Track
	  paper_tiger      1000 papers thrown (all rounds)
	  daily_regular    7 daily routes
	  booty_bay_bound  reach the last route: ride Stranglethorn's street to its end
	  editors_pick     gold on every route

	  Rw:Street(ride)              the street is over (to the Bonus Track or out of trikes): counts, unlocks
	  Rw:Round(ride, info)         the round is over: the medal, the round's unlocks; -> medal (0-3), potential
	  Rw:Has(id) / Rw:Progress(id) -> have it; current, goal (for the counted ones)
	  Rw:Medal(zone)               this character's best medal there (0-3)
	  Rw.LIST                      { id, name, text, goal } in shelf order
	New unlocks are fired as ACHIEVEMENT (id); nothing is ever taken back except by "Reset my records". ]]

local _, ns = ...
local P = ns.P
local Rw = P:Module("Rewards")

Rw.LIST = {
	{ id = "first_delivery", name = "First Delivery", text = "Deliver your first Gazette." },
	{ id = "bullseye", name = "Bullseye", text = "Put 50 papers in subscribers' mailboxes.", goal = 50, count = "mail" },
	{ id = "perfect_day", name = "Perfect Day", text = "Give every subscriber on a street a paper." },
	{ id = "full_week", name = "Full Week", text = "Keep every subscriber through a whole route." },
	{ id = "glass_act", name = "Glass Act", text = "Break 25 non-subscribers' windows.", goal = 25, count = "glass" },
	{ id = "outrunner", name = "Outrunner", text = "Leave 10 kobolds behind.", goal = 10, count = "escapes" },
	{ id = "clean_ride", name = "Clean Ride", text = "Ride a whole round without a crash or a catch." },
	{ id = "trick_rider", name = "Trick Rider", text = "Jump 5 ramps in one Bonus Track." },
	{ id = "paper_tiger", name = "Paper Tiger", text = "Throw 1,000 papers.", goal = 1000, count = "thrown" },
	{ id = "daily_regular", name = "Daily Regular", text = "Ride 7 daily routes.", goal = 7 },
	{ id = "booty_bay_bound", name = "Booty Bay Bound", text = "Reach the last route: ride Stranglethorn's street to its end." },
	{ id = "editors_pick", name = "Editor's Pick", text = "Earn gold on every route.", goal = 5 },
}
Rw.BY = {}
for i, a in ipairs(Rw.LIST) do Rw.BY[a.id] = a a.n = i end
Rw.MEDAL_AT = { 0.25, 0.45, 0.65 }
Rw.MEDALS = { "bronze", "silver", "gold" }

local function C()
	local c = P.char
	if not c or P.readOnly then return nil end
	if type(c.ach) ~= "table" then c.ach = {} end
	if type(c.medals) ~= "table" then c.medals = {} end
	if type(c.tot) ~= "table" then c.tot = {} end
	return c
end

function Rw:Has(id)
	local c = P.char
	return c and type(c.ach) == "table" and c.ach[id] ~= nil or false
end

function Rw:Medal(zone)
	local c = P.char
	return c and type(c.medals) == "table" and c.medals[zone] or 0
end

local function Golds()
	local n = 0
	for _, z in ipairs(P.Route.ZONES) do if Rw:Medal(z.id) >= 3 then n = n + 1 end end
	return n
end

function Rw:Progress(id)
	local a = self.BY[id]
	if not a or not a.goal then return nil end
	local c = P.char or {}
	local have
	if a.count then have = type(c.tot) == "table" and c.tot[a.count] or 0
	elseif id == "daily_regular" then have = P.Daily:DaysPlayed()
	elseif id == "editors_pick" then have = Golds() end
	return math.min(have or 0, a.goal), a.goal
end

local function Unlock(c, id, list)
	if c.ach[id] then return end
	c.ach[id] = (GetServerTime and GetServerTime()) or 0
	list[#list + 1] = id
	P:Fire("ACHIEVEMENT", id)
end

local function Add(c, key, n) c.tot[key] = (c.tot[key] or 0) + (n or 0) end

-- the street is over: the counted ones, and those the street alone decides
function Rw:Street(r)
	local c = C()
	local got = {}
	if not c then return got end
	local s = r.stats
	Add(c, "mail", s.mail)
	Add(c, "glass", s.glass)
	Add(c, "escapes", s.escapes)
	Add(c, "thrown", s.thrown)
	if s.mail + s.door > 0 then Unlock(c, "first_delivery", got) end
	for _, a in ipairs(self.LIST) do
		if a.count and (c.tot[a.count] or 0) >= a.goal then Unlock(c, a.id, got) end
	end
	-- every subscriber given a paper (a window broken afterwards still loses them: that's Full Week's business)
	local subs, given, kept = 0, 0, 0
	for _, h in ipairs(r.route.houses) do
		if h.sub then
			subs = subs + 1
			if h.got then given = given + 1 end
			if h.got and not h.lost then kept = kept + 1 end
		end
	end
	if subs > 0 and given == subs then Unlock(c, "perfect_day", got) end
	if not r.out then
		if subs > 0 and kept == subs then Unlock(c, "full_week", got) end
		if r.route.zone == "stranglethorn" then Unlock(c, "booty_bay_bound", got) end
	end
	return got
end

-- what the street (and its Bonus Track) could pay at most, before air-doubled hits and escapes
function Rw:Potential(route, seed)
	local Rd, Bn = P.Round, P.Bonus
	local S = Rd.SCORE
	local total = 0
	for _, h in ipairs(route.houses) do
		if h.sub then total = total + S.mail + S.kept
		else
			total = total + #h.win * S.window + S.smash
			if h.breakable then total = total + S.yard end
		end
	end
	local b = Bn:Build(route.zone, seed or route.seed)
	for _, t in ipairs(b.targets) do total = total + (t.kind == "dummy" and Bn.SCORE.dummy or Bn.SCORE.target) end
	total = total + #b.ramps * Bn.SCORE.jump
	return total
end

function Rw:MedalFor(score, potential)
	if not potential or potential <= 0 then return 0 end
	local f = score / potential
	local m = 0
	for i, at in ipairs(self.MEDAL_AT) do if f >= at then m = i end end
	return m
end

-- the round is over (r: the last ride; r.main the street when the Bonus Track was ridden)
function Rw:Round(r, info)
	local c = C()
	local got = info and info.unlocked or {}
	local m = r.main or r
	local b = r.route.bonus and r or nil
	local potential = self:Potential(m.route, m.route.seed)
	local medal = self:MedalFor(r.score, potential)
	if not c then return medal, potential, got end
	if b then Add(c, "thrown", b.stats.thrown) end
	for _, a in ipairs(self.LIST) do
		if a.count and (c.tot[a.count] or 0) >= a.goal then Unlock(c, a.id, got) end
	end
	local zone = m.route.zone
	if medal > (c.medals[zone] or 0) then c.medals[zone] = medal end
	if b and not r.out then
		if m.stats.falls == 0 and (b.stats.falls or 0) == 0 then Unlock(c, "clean_ride", got) end
		if b.stats.jumps >= 5 then Unlock(c, "trick_rider", got) end
	end
	if P.Daily:DaysPlayed() >= 7 then Unlock(c, "daily_regular", got) end
	if Golds() >= #P.Route.ZONES then Unlock(c, "editors_pick", got) end
	return medal, potential, got
end

function Rw:Count()
	local n = 0
	for _, a in ipairs(self.LIST) do if self:Has(a.id) then n = n + 1 end end
	return n, #self.LIST
end
