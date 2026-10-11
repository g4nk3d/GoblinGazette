--[[ Goblin Gazette - Comm/Leaderboard.lua
	The SHARED LEADERBOARD: the best rounds Goblin Gazette players have ridden, passed between players and
	checked by replaying the round before an entry counts (Game/Replay.lua). Two boards:
	  "d<date>"   the daily route (everyone rides the same street that day: a fair comparison)
	  "all"       best ever, on any street: each entry carries its street's seed and region, so it can be
	              replayed too
	One entry per player per board (their best), top ten kept.

	How scores travel (chat channels keep no history, so players tell each other; the same way as Piggle,
	Body Pull, Need Before Greed and Hearth & Haul):
	  * the family's ONE hidden games channel, "PiggleScores", with our own message prefix "GG1" (every
	    message under another game's prefix is ignored), plus the guild. The channel is removed from every
	    chat window, its notices are hidden, and it is kept behind the game's own channels (NetherChannels);
	  * on login a player asks ("Q"); everyone who hears it answers after a random 2-9 s with the best entries
	    they know of (today's, yesterday's and best ever), skipping anything someone else has just sent;
	  * a new best that makes a board's top ten is sent at once;
	  * every entry carries the round's whole input log (split over as many messages as it needs) and the
	    rules version; it is stored only after this client replays it and banks exactly the claimed score.
	    Replays take at most 0.25 ms of a frame (a round is about 3,000 ticks: a few seconds of frames).
	  Messages go out one every 0.35 s, never in combat. The setting "Share scores" turns all of it off.

	SEALED RECORDS: on logout this character's records are sealed (a digest of them, the character and a
	salt). If the saved file was edited outside the game the seal fails and every record with a log is
	replayed again: only records that really bank their score are kept.

	  LB:Board(id) -> top ten { who, u, s, t, z, sd, m, g }   (u: the player's GUID, z region, sd seed, m log)
	  LB:Record(id, score, zone, seed, code)      a finished round by this player
	  LB:Rank(id) -> this player's place on that board, or nil
	  LB:Enabled() / LB:SetEnabled(on) / LB:Pending() ]]

local _, ns = ...
local P = ns.P
local LB = P:Module("Leaderboard")

local PREFIX, CHANNEL, SEP = "GG1", "PiggleScores", "~"
local TOP = 10
local PART = 200                      -- characters of an entry per message (addon messages hold 255)
local MAX_PARTS = 60                  -- 12,000 characters: a very long round's log
local CHECK_MS = 0.25                 -- replay time per frame
local SALT = "goblingazette-seal-1"
LB.CHANNEL, LB.PREFIX, LB.TOP = CHANNEL, PREFIX, TOP
LB.ALL = "all"
-- the other Nether games on the same channel: it is left only when none of them is loaded
local SIBLINGS = { "Piggle", "BodyPull", "NeedBeforeGreed", "HearthAndHaul" }

local Rp, Dy, Rt
local function Mods() Rp, Dy, Rt = P.Replay, P.Daily, P.Route end

local function DB()
	local d = P.db and P.db.board
	if type(d) ~= "table" then
		d = {}
		if P.db and not P.readOnly then P.db.board = d end
	end
	return d
end

function LB:Enabled() return P:Setting("shareScores") ~= false end
function LB:Board(id) return DB()[id] or {} end
function LB:DailyId(date) return "d" .. date end

-- the day a daily board is, or nil (only yesterday, today or tomorrow unless `any`: realms' clocks differ)
function LB:DayOf(id, any)
	Mods()
	if type(id) ~= "string" then return nil end
	local date = id:match("^d(%d%d%d%d%-%d%d%-%d%d)$")
	local day = date and Dy.DayOfDate(date)
	if not day then return nil end
	if not any and math.abs(day - Dy:Day()) > 1 then return nil end
	return day
end

-- the street a board entry was ridden on: the day's for a daily board, its own for best ever
local function Street(id, e)
	local day = LB:DayOf(id, true)
	if day then return Dy:Zone(day), Dy:Seed(day) end
	if id == LB.ALL and type(e.z) == "string" and Rt:Zone(e.z) and type(e.sd) == "number" then return e.z, e.sd end
	return nil
end

function LB:Rank(id)
	local list = self:Board(id)
	for i, e in ipairs(list) do if e.u == P.guid then return i, e end end
	return nil
end

-- ------------------------------------------------------------------ the shared tables
local function Qualifies(list, e)
	for _, o in ipairs(list) do
		if o.u == e.u and o.s >= e.s then return false end
	end
	return #list < TOP or e.s > list[#list].s
end

local function Insert(id, e)
	local d = DB()
	local list = d[id] or {}
	d[id] = list
	if not Qualifies(list, e) then return false end
	for i = #list, 1, -1 do if list[i].u == e.u then table.remove(list, i) end end
	local at = #list + 1
	while at > 1 and (list[at - 1].s < e.s or (list[at - 1].s == e.s and (list[at - 1].t or 0) > (e.t or 0))) do at = at - 1 end
	table.insert(list, at, { who = e.who, u = e.u, s = e.s, t = e.t, z = e.z, sd = e.sd, m = e.m, g = e.g or nil, r = Rp.RULES })
	while #list > TOP do table.remove(list) end
	P:Fire("LEADERBOARD_CHANGED", id)
	return true
end
LB.Insert = Insert

-- daily boards older than a week are let go; best ever stays. Entries ridden under other rules (an older
-- Goblin Gazette: different streets or hazards) can't be checked any more and are let go too.
local function Prune()
	Mods()
	local d, today = DB(), Dy:Day()
	for _, list in pairs(d) do
		for i = #list, 1, -1 do if (list[i].r or 1) ~= Rp.RULES then table.remove(list, i) end end
	end
	for id in pairs(d) do
		if id ~= LB.ALL then
			local day = LB:DayOf(id, true)
			if not day or today - day > 7 then d[id] = nil end
		end
	end
end

LB.Prune = function() Prune() end

-- ------------------------------------------------------------------ replay checks (a little each frame)
local jobs, job = {}, nil
local checker = CreateFrame("Frame")
checker:Hide()

local function Finish(ok, score)
	local j = job
	job = nil
	if j and j.done then P:Safe("score check", j.done, ok, score) end
	P:Fire("LEADERBOARD_CHECKED")
end

checker:SetScript("OnUpdate", function(self)
	if InCombatLockdown and InCombatLockdown() then return end
	if not job then
		job = table.remove(jobs, 1)
		if not job then self:Hide() return end
		-- decoding the log and laying out the street are this frame's work
		job.run = Rp:Start(job.zone, job.seed, job.m)
		if not job.run then Finish(false) end
		return
	end
	local t0 = P:ProfStart()
	local done = Rp:Step(job.run, CHECK_MS)
	P:ProfEnd("score check", t0)
	if done then
		local run = job.run
		Finish(run.ok and (job.score == nil or run.score == job.score), run.score)
	end
end)

-- queue a check: the log must bank exactly `score` on that street (score nil: whatever it banks);
-- done(ok, banked) afterwards
local function Check(zone, seed, score, code, done)
	if type(code) ~= "string" or #code == 0 or #code > PART * MAX_PARTS then
		if done then done(false) end
		return
	end
	if #jobs >= 40 then return end
	jobs[#jobs + 1] = { zone = zone, seed = seed, score = score, m = code, done = done }
	checker:Show()
end
LB.Check = Check
function LB:Pending() return #jobs + (job and 1 or 0) end

-- ------------------------------------------------------------------ sending (queued, paced, out of combat)
local outq = {}
local sender = CreateFrame("Frame")
sender:Hide()
local nextAt = 0
sender:SetScript("OnUpdate", function(self)
	if #outq == 0 then self:Hide() return end
	if InCombatLockdown and InCombatLockdown() then return end
	local now = GetTime()
	if now < nextAt then return end
	nextAt = now + 0.35
	local m = table.remove(outq, 1)
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		local ok, err = pcall(C_ChatInfo.SendAddonMessage, PREFIX, m[1], m[2], m[3])
		if not ok then P:RecordError("leaderboard send", err) end
	end
end)

local function Queue(text, kind, target)
	if #outq >= 400 then return end
	outq[#outq + 1] = { text, kind, target }
	sender:Show()
end

local function ChannelId()
	if not GetChannelName then return nil end
	local id = GetChannelName(CHANNEL)
	return (type(id) == "number" and id > 0) and id or nil
end

local function Targets(only)
	local t = {}
	local id = ChannelId()
	if id and (not only or only == "CHANNEL") then t[#t + 1] = { "CHANNEL", id } end
	if IsInGuild and IsInGuild() and (not only or only == "GUILD") then t[#t + 1] = { "GUILD" } end
	return t
end

local Join
local lastJoin = 0
-- an entry is one text (rules, board, score, who, guid, time, region, seed, log) cut into numbered parts:
-- "E~mid~i~n~part"
local function SendEntry(id, e, only)
	-- the shared channel can be gone (another game's sharing switched off left it): join again, at most once a minute
	if not ChannelId() and GetTime() - lastJoin > 60 then lastJoin = GetTime() Join() end
	local body = table.concat({ Rp.RULES, id, e.s, e.who, e.u, e.t or 0, e.z or "", e.sd or 0, e.m }, SEP)
	local n = math.ceil(#body / PART)
	if n > MAX_PARTS then return end
	local mid = ("%06x"):format(math.random(0, 16777215))
	for _, tg in ipairs(Targets(only)) do
		for i = 1, n do
			Queue(table.concat({ "E", mid, i, n, body:sub((i - 1) * PART + 1, i * PART) }, SEP), tg[1], tg[2])
		end
	end
end

-- ------------------------------------------------------------------ receiving
local seenAt = {}     -- id..guid..score -> time last heard (answers skip what was just sent)
local partial = {}    -- sender..mid -> { n, got, parts, at }
local answerAt
local me

local function SeenKey(id, e) return id .. "|" .. e.u .. "|" .. e.s end

local function Parse(body)
	local f = {}
	for x in (body .. SEP):gmatch("(.-)" .. SEP) do f[#f + 1] = x end
	if #f ~= 9 then return nil end
	if tonumber(f[1]) ~= Rp.RULES then return nil end                 -- another version's rules: can't be checked here
	local id, s, who, u, t, z, sd, m = f[2], tonumber(f[3]), f[4], f[5], tonumber(f[6]), f[7], tonumber(f[8]), f[9]
	if id ~= LB.ALL and not id:match("^d%d%d%d%d%-%d%d%-%d%d$") then return nil end
	if not s or s < 0 or s > 1e7 or s ~= math.floor(s) then return nil end
	if who == "" or #who > 60 or who:find("[|\n]") or u == "" or #u > 40 or u:find("[|\n]") then return nil end
	if m == "" or m:find("[^0-9A-Za-j%.]") then return nil end
	local e = { s = s, who = who, u = u, t = t, m = m }
	if id == LB.ALL then
		if not Rt:Zone(z) or not sd or sd < 1 or sd > 2147483646 or sd ~= math.floor(sd) then return nil end
		e.z, e.sd = z, sd
	end
	return id, e
end

local function Heard(id, e, kind)
	seenAt[SeenKey(id, e)] = GetTime()
	if id ~= LB.ALL and not LB:DayOf(id) then return end
	if not Qualifies(DB()[id] or {}, e) then return end
	local zone, seed = Street(id, e)
	if not zone then return end
	if kind == "GUILD" then e.g = true end
	Check(zone, seed, e.s, e.m, function(ok) if ok then Insert(id, e) end end)
end

local function Answer(kind)
	answerAt = nil
	local now, sent = GetTime(), 0
	local today = Dy:Day()
	for id, list in pairs(DB()) do
		local day = id ~= LB.ALL and LB:DayOf(id, true)
		if id == LB.ALL or (day and today - day <= 1) then
			for i = 1, math.min(3, #list) do
				local e = list[i]
				local k = SeenKey(id, e)
				if not (seenAt[k] and now - seenAt[k] < 60) and sent < 6 then
					seenAt[k] = now
					SendEntry(id, e, kind)
					sent = sent + 1
				end
			end
		end
	end
end

local function OnMessage(_, prefix, text, kind, from)
	-- the channel is shared by the Nether games: only our own prefix is ours
	if prefix ~= PREFIX or not LB:Enabled() or type(text) ~= "string" or P.readOnly then return end
	Mods()
	if from and me and (from == me or from:match("^([^%-]+)") == me:match("^([^%-]+)")) then return end
	local tag = text:sub(1, 1)
	if tag == "Q" then
		if not answerAt and C_Timer and C_Timer.After then
			answerAt = GetTime() + 2 + math.random() * 7
			local reply = kind == "GUILD" and "GUILD" or "CHANNEL"
			C_Timer.After(answerAt - GetTime(), function() P:Safe("leaderboard answer", Answer, reply) end)
		end
	elseif tag == "E" then
		local mid, i, n, part = text:match("^E" .. SEP .. "(%x+)" .. SEP .. "(%d+)" .. SEP .. "(%d+)" .. SEP .. "(.*)$")
		i, n = tonumber(i), tonumber(n)
		if not mid or not i or not n or n < 1 or n > MAX_PARTS or i < 1 or i > n or #part > PART then return end
		local key = tostring(from) .. mid
		local now = GetTime()
		-- unfinished entries are let go after two minutes
		for k, pe in pairs(partial) do if now - pe.at > 120 then partial[k] = nil end end
		local pe = partial[key]
		if not pe then
			pe = { n = n, got = 0, parts = {}, at = now }
			partial[key] = pe
		end
		if pe.n ~= n then partial[key] = nil return end
		if not pe.parts[i] then pe.parts[i] = part pe.got = pe.got + 1 end
		if pe.got < n then return end
		partial[key] = nil
		local id, e = Parse(table.concat(pe.parts))
		if id then Heard(id, e, kind) end
	end
end
LB.OnMessage = OnMessage

-- ------------------------------------------------------------------ the hidden channel
local function HideChannel()
	local remove = (ChatFrameUtil and ChatFrameUtil.RemoveChannel) or ChatFrame_RemoveChannel
	if not remove then return end
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local cf = _G["ChatFrame" .. i]
		if cf then pcall(remove, cf, CHANNEL) end
	end
end

local function NoticeFilter(_, _, ...)
	for i = 1, select("#", ...) do
		local a = select(i, ...)
		if type(a) == "string" and a:lower():find(CHANNEL:lower(), 1, true) then return true end
	end
	return false
end

function Join()
	if not LB:Enabled() then return end
	if not ChannelId() then
		local join = JoinTemporaryChannel or JoinChannelByName
		if join then pcall(join, CHANNEL) end
	end
	P:After(2, function()
		HideChannel()
		if NetherChannels and NetherChannels.Settle then NetherChannels:Settle(CHANNEL) end
		if LB:Enabled() then
			for _, tg in ipairs(Targets()) do Queue("Q" .. SEP .. "1", tg[1], tg[2]) end
		end
	end)
end

-- another Nether game that also uses the channel is loaded (then the channel is never left)
local function SiblingLoaded()
	local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or rawget(_G, "IsAddOnLoaded")
	if not loaded then return false end
	for _, name in ipairs(SIBLINGS) do
		local ok, on = pcall(loaded, name)
		if ok and on then return true end
	end
	return false
end
LB.SiblingLoaded = SiblingLoaded

function LB:SetEnabled(on)
	if on then Join()
	else
		local leave = LeaveChannelByName
		if leave and ChannelId() and not SiblingLoaded() then pcall(leave, CHANNEL) end
		wipe(outq)
	end
end
P:Register("SETTINGS_CHANGED", function(key) if key == "shareScores" then LB:SetEnabled(P:Setting("shareScores") ~= false) end end)

-- ------------------------------------------------------------------ this player's rounds
function LB:Record(id, score, zone, seed, code)
	Mods()
	if P.readOnly or not me or not code or not P.guid then return false end
	local c = P.char
	if c and c.edited then return false end             -- records still being re-checked after an outside edit
	local e = { who = me, u = P.guid, s = score, t = (GetServerTime and GetServerTime()) or 0, m = code, g = true }
	if id == LB.ALL then e.z, e.sd = zone, seed end
	local placed = Insert(id, e)
	if placed and self:Enabled() then SendEntry(id, e) end
	return placed
end

-- ------------------------------------------------------------------ sealed records
local function Hash(str)
	local h = 7
	for i = 1, #str do h = (h * 31 + str:byte(i)) % 4294967291 end
	return ("%08x"):format(h)
end

local function Digest(c, guid)
	local out = {}
	local days = {}
	for d in pairs(c.daily or {}) do days[#days + 1] = d end
	table.sort(days)
	for _, d in ipairs(days) do
		local r = c.daily[d]
		out[#out + 1] = d .. ":" .. tostring(r.best) .. ":" .. tostring(r.code)
	end
	local t = c.top
	if type(t) == "table" then out[#out + 1] = tostring(t.s) .. ":" .. tostring(t.z) .. ":" .. tostring(t.sd) .. ":" .. tostring(t.m) end
	out[#out + 1] = tostring(c.dailyDays)
	return Hash(table.concat(out, ";") .. guid .. SALT)
end
LB.Digest = Digest

-- an outside edit: every record with a log is replayed; what does not check out is dropped
local function Recheck(c)
	Mods()
	c.edited = true
	local left = 0
	local function Done() left = left - 1 if left == 0 then c.edited = nil end end
	for d, r in pairs(c.daily or {}) do
		local day = Dy.DayOfDate(d)
		if r.best and r.code and day and (r.r or 1) ~= Rp.RULES then
			-- (ridden under older rules: it can't be replayed now; kept as the day's record, never shared)
		elseif r.best and r.code and day then
			left = left + 1
			Check(Dy:Zone(day), Dy:Seed(day), r.best, r.code, function(ok)
				if not ok then c.daily[d] = nil end
				Done()
			end)
		elseif r.best then
			c.daily[d] = nil
		end
	end
	local t = c.top
	if type(t) == "table" then
		if t.m and Rt:Zone(t.z) and type(t.sd) == "number" then
			left = left + 1
			Check(t.z, t.sd, t.s, t.m, function(ok)
				if not ok then c.top = nil end
				Done()
			end)
		else
			c.top = nil
		end
	end
	if left == 0 then c.edited = nil end
end
LB.Recheck = Recheck

-- ------------------------------------------------------------------ start up
P:Register("LOGIN", function()
	Mods()
	local name = UnitName and UnitName("player")
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	me = name and (realm and realm ~= "" and (name .. "-" .. realm) or name) or nil
	LB.me = me
	local c = P.char
	if c and c.seal and c.seal ~= Digest(c, P.guid) then P:Safe("records check", Recheck, c) end
	-- this character's best round from older rules can't go on the board any more (the score itself stays as
	-- their best); checked after the seal, which was made over it
	if c and type(c.top) == "table" and (c.top.r or 1) ~= Rp.RULES and not P.readOnly then c.top = nil end
	P:Safe("leaderboard prune", Prune)
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		for _, ev in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
			pcall(addFilter, ev, NoticeFilter)
		end
	end
	-- channels are not ready the moment the world loads
	P:After(10, Join)
end)
P:On("CHAT_MSG_ADDON", OnMessage)
P:On("PLAYER_LOGOUT", function()
	local c = P.char
	if c and P.guid and not c.edited and not P.readOnly then c.seal = Digest(c, P.guid) end
end)
