--[[ Goblin Gazette - Core/Init.lua
	The namespace and the plumbing every other file uses.

	  P:Module(name)            a module table, created once (P.<name>)
	  P:On(event, fn)           game events; several handlers per event, each protected
	  P:Off(event) / P:Listen(event)   stop / resume listening (handlers stay)
	  P:Register(msg, fn) / P:Fire(msg, ...)   internal messages (LOGIN, SETTINGS_CHANGED, UI_REFRESH)
	  P:After(s, fn)            a timer
	  P:Safe(context, fn, ...)  a protected call; failures are kept for /gazette debug, never thrown
	  P:ProfStart() / P:ProfEnd(name, t0)   the slowest time seen for each named part (/gazette perf)
	  P:Print(fmt, ...)         a chat line
	  P.db                      GoblinGazetteDB (account: settings, window, schema); P.char = this
	                            character's table, keyed by the player's GUID (ready after LOGIN)

	The one global of our own is the saved table GoblinGazetteDB (plus the slash command entries the game
	requires, and the shared Nether family files' own). ]]

local ADDON, ns = ...
local P = { name = ADDON, modules = {} }
ns.P = P

P.VERSION = "1.0.1"
P.SCHEMA = 1
P.MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
P.COLOR = "|cff7fc24a"

local type, pairs, select, tostring, pcall, format, tonumber = type, pairs, select, tostring, pcall, string.format, tonumber

function P:Module(name)
	local m = self.modules[name]
	if not m then
		m = { name = name }
		self.modules[name] = m
		self[name] = m
	end
	return m
end

P.errors = {}
function P:RecordError(context, err)
	local line = format("%s: %s", tostring(context), tostring(err))
	local last = self.errors[#self.errors]
	if last and last.text == line then
		last.n = last.n + 1          -- the same error again: count it, don't fill the list
	elseif #self.errors < 30 then
		self.errors[#self.errors + 1] = { text = line, n = 1, at = GetTime and GetTime() or 0 }
	end
	if self.debug then self:Print("|cffff6060error|r %s", line) end
end

function P:Safe(context, fn, ...)
	local ok, a, b, c = pcall(fn, ...)
	if not ok then self:RecordError(context, a) return nil end
	return a, b, c
end

P.prof = {}
local profNow = debugprofilestop
function P:ProfStart() return profNow and profNow() end
function P:ProfEnd(name, t0)
	if not t0 then return end
	local ms = profNow() - t0
	if ms > (self.prof[name] or 0) then self.prof[name] = ms end
end

function P:Print(fmt, ...)
	local msg = select("#", ...) > 0 and format(fmt, ...) or tostring(fmt)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(self.COLOR .. "Goblin Gazette|r " .. msg) end
end

local frame = CreateFrame("Frame")
P.eventFrame = frame
-- the Nether family's switch: while NetherSuite has Goblin Gazette switched off its events never run
if NetherFamily and NetherFamily.Gate then NetherFamily:Gate(ADDON, frame) end
local handlers = {}
frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do P:Safe(event, list[i], event, ...) end
end)
function P:On(event, fn)
	if not handlers[event] then handlers[event] = {} end
	local list = handlers[event]
	list[#list + 1] = fn
	if not frame:IsEventRegistered(event) then pcall(frame.RegisterEvent, frame, event) end
end
function P:Off(event)
	if frame:IsEventRegistered(event) then frame:UnregisterEvent(event) end
end
function P:Listen(event)
	if handlers[event] and not frame:IsEventRegistered(event) then pcall(frame.RegisterEvent, frame, event) end
end

local bus = {}
function P:Register(msg, fn)
	bus[msg] = bus[msg] or {}
	local list = bus[msg]
	list[#list + 1] = fn
end
function P:Fire(msg, ...)
	local list = bus[msg]
	if not list then return end
	for i = 1, #list do self:Safe("message " .. msg, list[i], ...) end
end

function P:After(s, fn)
	if C_Timer and C_Timer.After then C_Timer.After(s, function() P:Safe("timer", fn) end) end
end

function P:Setting(key)
	local s = self.db and self.db.settings
	if s and s[key] ~= nil then return s[key] end
	return self.DEFAULTS[key]
end
P.DEFAULTS = { size = 0.9, minimapButton = true, sound = true, music = true, followNetherUI = true, shareScores = true }

-- ------------------------------------------------------------------ saved data
-- Every value read back is checked; a broken section is reset on its own with one chat notice, so a
-- damaged file never stops the game from loading.
local function Clean(db)
	local notes = {}
	if type(db.settings) ~= "table" then
		if db.settings ~= nil then notes[#notes + 1] = "settings" end
		db.settings = {}
	end
	if type(db.settings.size) ~= "number" or db.settings.size < 0.5 or db.settings.size > 1 then db.settings.size = nil end
	if type(db.chars) ~= "table" then
		if db.chars ~= nil then notes[#notes + 1] = "character records" end
		db.chars = {}
	end
	if type(db.settings.minimapButton) ~= "boolean" then db.settings.minimapButton = nil end
	if type(db.settings.sound) ~= "boolean" then db.settings.sound = nil end
	if type(db.settings.music) ~= "boolean" then db.settings.music = nil end
	if type(db.settings.followNetherUI) ~= "boolean" then db.settings.followNetherUI = nil end
	if type(db.settings.shareScores) ~= "boolean" then db.settings.shareScores = nil end
	-- the shared leaderboard (Comm/Leaderboard.lua): boards of at most ten checked entries
	if db.board ~= nil and type(db.board) ~= "table" then
		notes[#notes + 1] = "the leaderboard"
		db.board = nil
	elseif db.board then
		for id, list in pairs(db.board) do
			local good = type(id) == "string" and type(list) == "table" and #list <= 10
			if good then
				for _, e in ipairs(list) do
					if type(e) ~= "table" or type(e.s) ~= "number" or type(e.who) ~= "string" or type(e.u) ~= "string" then good = false end
				end
			end
			if not good then db.board[id] = nil end
		end
	end
	if type(db.window) ~= "table" then db.window = nil end
	if type(db.minimap) ~= "table" or (db.minimap.angle ~= nil and type(db.minimap.angle) ~= "number") then db.minimap = nil end
	for guid, c in pairs(db.chars) do
		if type(guid) ~= "string" or type(c) ~= "table" then
			db.chars[guid] = nil
			notes[#notes + 1] = "a character record"
		else
			local v = tonumber(c.farthest)
			c.farthest = (v and v >= 0 and v < 1e7) and math.floor(v) or nil
			v = tonumber(c.rides)
			c.rides = (v and v >= 0 and v < 1e8) and math.floor(v) or nil
			v = tonumber(c.best)
			c.best = (v and v >= 0 and v < 1e8) and math.floor(v) or nil
			v = tonumber(c.zone)
			c.zone = (v and v >= 1 and v <= 5) and math.floor(v) or nil
			if type(c.name) ~= "string" then c.name = nil end
			v = tonumber(c.dailyDays)
			c.dailyDays = (v and v >= 0 and v < 1e6) and math.floor(v) or nil
			-- the daily route's records: { [date] = { best, runs, code } }
			if c.daily ~= nil and type(c.daily) ~= "table" then c.daily = nil end
			if c.daily then
				for d, r in pairs(c.daily) do
					if type(d) ~= "string" or not d:match("^%d%d%d%d%-%d%d%-%d%d$") or type(r) ~= "table" then c.daily[d] = nil
					else
						v = tonumber(r.best)
						r.best = (v and v >= 0 and v < 1e8) and math.floor(v) or nil
						v = tonumber(r.runs)
						r.runs = (v and v >= 0 and v < 1e6) and math.floor(v) or 0
						if type(r.code) ~= "string" then r.code = nil end
					end
				end
			end
			-- the best round with its replay (for the shared board): { s, z, sd, m, t }
			if c.top ~= nil and (type(c.top) ~= "table" or type(c.top.s) ~= "number" or type(c.top.m) ~= "string"
				or type(c.top.z) ~= "string" or type(c.top.sd) ~= "number") then c.top = nil end
			if type(c.seal) ~= "string" then c.seal = nil end
			-- the trophies: { [id] = time earned }, { [zone] = 1..3 }, running counts
			if c.ach ~= nil and type(c.ach) ~= "table" then c.ach = nil end
			if c.ach then for id, t in pairs(c.ach) do if type(id) ~= "string" or type(t) ~= "number" then c.ach[id] = nil end end end
			if c.medals ~= nil and type(c.medals) ~= "table" then c.medals = nil end
			if c.medals then
				for z, m in pairs(c.medals) do
					if type(z) ~= "string" or type(m) ~= "number" or m < 1 or m > 3 then c.medals[z] = nil else c.medals[z] = math.floor(m) end
				end
			end
			if c.tot ~= nil and type(c.tot) ~= "table" then c.tot = nil end
			if c.tot then
				for k, v in pairs(c.tot) do
					if type(k) ~= "string" or type(v) ~= "number" or v < 0 or v > 1e9 then c.tot[k] = nil else c.tot[k] = math.floor(v) end
				end
			end
			c.edited = nil
		end
	end
	return notes
end

local MIGRATE = {
	-- [n] = function(db) ... end   upgrades a schema n-1 table to schema n
}

local function OpenDB()
	local db = rawget(_G, "GoblinGazetteDB")
	if type(db) ~= "table" then db = {} end
	local from = tonumber(db.schema) or 0
	if from > P.SCHEMA then
		-- a newer Goblin Gazette wrote this: keep it untouched, play from a temporary table this session
		P:Print("your saved data comes from a newer version; nothing will be saved until you update.")
		db = { schema = P.SCHEMA }
		P.readOnly = true
	else
		for v = from + 1, P.SCHEMA do
			local fn = MIGRATE[v]
			if fn then
				local ok, err = pcall(fn, db)
				if not ok then P:RecordError("migrate " .. v, err) end
			end
		end
		db.schema = P.SCHEMA
		GoblinGazetteDB = db
	end
	local notes = Clean(db)
	if #notes > 0 then
		P:Print("some saved data was damaged and has been reset: %s.", table.concat(notes, ", "))
	end
	return db
end

P:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	P.db = OpenDB()
end)

-- per-character records are keyed by GUID (several characters can share a name), known at login
P:On("PLAYER_LOGIN", function()
	P.loggedIn = true
	local guid = UnitGUID and UnitGUID("player")
	if type(guid) ~= "string" or guid == "" then guid = "unknown" end
	P.guid = guid
	local c = P.db.chars[guid]
	if type(c) ~= "table" then
		c = {}
		P.db.chars[guid] = c
	end
	c.name = UnitName and UnitName("player") or c.name
	P.char = c
	P:Fire("LOGIN")
end)
