--[[ Goblin Gazette - Game/Daily.lua
	The daily route: one street for every player in the world on the same date (UTC, from the realm's clock),
	so everyone meets the same houses, subscribers, kobolds and Bonus Track. The day picks the route's
	region too. Ride it as often as you like: your best counts.

	  Dy:Day()                 the day number (days since 1970-01-01, UTC)
	  Dy:Today()               "2026-10-11", the day number
	  Dy.DateOf(day) / Dy.DayOfDate(date)   a day number's date and back (plain functions)
	  Dy:Seed([day])           the day's seed (the same everywhere)
	  Dy:Zone([day])           the day's region id ("duskwood")
	  Dy:Record([date])        this character's record for that date { best, runs, code } or nil
	  Dy:Finish(date, score, code)   a finished daily round: keeps the best; -> isNewBest, previousBest
	  Dy:DaysPlayed()          how many different days this character has ridden the daily route ]]

local _, ns = ...
local P = ns.P
local Dy = P:Module("Daily")

local KEEP_DAYS = 60
local floor = math.floor

local function Now()
	if GetServerTime then
		local ok, t = pcall(GetServerTime)
		if ok and type(t) == "number" and t > 0 then return t end
	end
	return time and time() or 0
end

-- the UTC date of a day number, worked out by hand so it never depends on the player's time zone
-- (Howard Hinnant's civil-from-days)
local function DateOf(day)
	local z = day + 719468
	local era = floor(z / 146097)
	local doe = z - era * 146097
	local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
	local mp = floor((5 * doy + 2) / 153)
	local d = doy - floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then y = y + 1 end
	return ("%04d-%02d-%02d"):format(y, m, d)
end

-- and back: the day number of "YYYY-MM-DD" (nil for anything that isn't a real date)
local function DayOfDate(date)
	local y, m, d = tostring(date):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if not y or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
	if m <= 2 then y = y - 1 end
	local era = floor(y / 400)
	local yoe = y - era * 400
	local mp = m > 2 and m - 3 or m + 9
	local doy = floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
	local day = era * 146097 + doe - 719468
	if DateOf(day) ~= date then return nil end
	return day
end
Dy.DateOf, Dy.DayOfDate = DateOf, DayOfDate

function Dy:Day() return floor(Now() / 86400) end
function Dy:Today()
	local day = self:Day()
	return DateOf(day), day
end

-- the day's seed and region: the day number through the route's own mixer, the same on every machine
function Dy:Seed(day)
	local Rt = P.Route
	local st = Rt.Seed({}, (day or self:Day()) * 7919 + 104729, 77)
	return Rt.Int(st, 1, 2147483000)
end

function Dy:Zone(day)
	local Rt = P.Route
	local st = Rt.Seed({}, (day or self:Day()) * 7919 + 104729, 78)
	return Rt.ZONES[Rt.Int(st, 1, #Rt.ZONES)].id
end

local function Days()
	local c = P.char
	if not c then return {} end
	if type(c.daily) ~= "table" then c.daily = {} end
	return c.daily
end

function Dy:Record(date) return Days()[date or self:Today()] end

function Dy:DaysPlayed()
	local c = P.char
	return c and tonumber(c.dailyDays) or 0
end

function Dy:Finish(date, score, code)
	local c = P.char
	if not c or P.readOnly or not date then return false, nil end
	local days = Days()
	local r = days[date]
	if not r then
		r = { runs = 0 }
		days[date] = r
		c.dailyDays = (tonumber(c.dailyDays) or 0) + 1
	end
	r.runs = (r.runs or 0) + 1
	local prev = r.best
	local newBest = false
	if score > 0 and (not prev or score > prev) then
		r.best = score
		r.code = code               -- the round itself, so the board (and a check of the saved file) can replay it
		r.r = P.Replay.RULES        -- under these rules
		newBest = true
	end
	-- old days are let go (the count of days ridden stays)
	local today = self:Day()
	for d in pairs(days) do
		local day = DayOfDate(d)
		if not day or today - day > KEEP_DAYS then days[d] = nil end
	end
	return newBest, prev
end
