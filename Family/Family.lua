--[[ Goblin Gazette - Family/Family.lua
	Goblin Gazette's tile in NetherSuite's Minigames tab (category "Games") and the settings it shows there
	(all optional: the game plays exactly the same without NetherSuite).

	  P:SetSetting(key, value)   applied at once wherever it is changed (then SETTINGS_CHANGED) ]]

local ADDON, ns = ...
local P = ns.P

function P:SetSetting(key, value)
	if not self.db or self.readOnly then return end
	local was = self:Setting(key)
	self.db.settings[key] = value
	if was == value then return end
	if key == "minimapButton" then
		if self.Minimap and self.Minimap.SetShown then self.Minimap:SetShown(value) end
	elseif key == "size" then
		if self.Game and self.Game.FitScale then self.Game:FitScale() end
	elseif key == "sound" then
		if not value and self.Audio then self.Audio:StopLoop("engine", 0) self.Audio:StopLoop("amb", 0) end
		if value and self.Game and self.Game.IsOpen and self.Game:IsOpen() and self.Audio then self.Audio:Loop("amb", "amb_" .. self.Game:ZoneId()) end
	elseif key == "music" then
		if self.Audio then self.Audio:StopMusic() end
		if value and self.Game and self.Game.IsOpen and self.Game:IsOpen() then self.Game:MusicNow() end
	end
	self:Fire("SETTINGS_CHANGED", key)
end

local LABELS = {
	{ "sound", "Sound effects", { "sound", "effects", "audio", "engine" } },
	{ "music", "Music", { "music", "theme", "audio" } },
	{ "shareScores", "Share scores (the leaderboard)", { "leaderboard", "share", "scores", "daily", "guild" } },
	{ "minimapButton", "Show the minimap button", { "minimap", "button" } },
	{ "followNetherUI", "Follow NetherUI's theme (options page)", { "theme", "look", "netherui", "skin" } },
}

local function Settings()
	local list = {}
	for _, l in ipairs(LABELS) do
		local key = l[1]
		list[#list + 1] = { id = key, kind = "toggle", label = l[2], page = "general", keywords = l[3],
			get = function() return P:Setting(key) and true or false end,
			set = function(v) P:SetSetting(key, v and true or false) end }
	end
	return list
end

local function Status()
	local c = P.char or {}
	return {
		{ "Best score", c.best and (BreakUpLargeNumbers and BreakUpLargeNumbers(c.best) or tostring(c.best)) or "none yet" },
		{ "Rides", tostring(c.rides or 0) },
		{ "Daily routes", tostring(c.dailyDays or 0) },
		{ "Trophies", ("%d / %d"):format(P.Rewards:Count()) },
		{ "Farthest", c.farthest and ("%d tiles"):format(c.farthest) or "not ridden yet" },
	}
end

local function Descriptor()
	return {
		id = "goblingazette", name = "Goblin Gazette", version = P.VERSION, apiVersion = 1, addon = ADDON,
		icon = P.MEDIA .. "Logo", banner = P.MEDIA .. "Banner",
		description = "Ride Fizzwick's steam trike up the lane and deliver the Goblin Gazette. Extra! Extra! That's gonna cost extra!",
		category = "Games", slash = { "/gazette", "/goblingazette" },
		pages = { { id = "general", label = "General" } },
		settings = Settings(),
		open = function() P.Game:Open() return true end,
		focus = function() P.Game:Open() return true end,
		status = Status,
	}
end

local joined = false
local function JoinSuite()
	if joined then return end
	local S = rawget(_G, "NetherSuite")
	if type(S) == "table" and type(S.RegisterAddon) == "function" then
		joined = pcall(S.RegisterAddon, S, Descriptor())
	elseif C_AddOns and C_AddOns.DoesAddOnExist and C_AddOns.DoesAddOnExist("NetherSuite") then
		NetherSuite_Queue = NetherSuite_Queue or {}
		table.insert(NetherSuite_Queue, Descriptor())
		joined = true
	end
end

P:On("PLAYER_LOGIN", JoinSuite)
P:On("ADDON_LOADED", function(_, name)
	if name == "NetherSuite" and P.loggedIn then P:After(0, JoinSuite) end
end)
