--[[ Goblin Gazette - Family/Options.lua
	Esc > Options > AddOns > Goblin Gazette: every switch, the window size, a Play button and a reset for
	this character's records. It has the Nether family look and follows the current NetherUI theme when
	NetherUI is installed (Family/Skin.lua); the game's own screens keep Goblin Gazette's art. Always there,
	NetherSuite or not.

	  P.Options:Open()   show this page in the game's settings ]]

local _, ns = ...
local P = ns.P
local Options = P:Module("Options")
local W, Skin = P.Widgets, P.Skin

local function CloseSettings()
	local sp = rawget(_G, "SettingsPanel")
	if sp and sp:IsShown() and HideUIPanel then HideUIPanel(sp) end
end

function Options:Build()
	local SS = rawget(_G, "Settings")
	if type(SS) ~= "table" or not SS.RegisterCanvasLayoutCategory or not SS.RegisterAddOnCategory or self.panel then return end
	local p = CreateFrame("Frame")
	p:Hide()
	p.widgets = {}
	self.panel = p
	-- the page is registered at login but its contents are made the first time it is shown
	p:SetScript("OnShow", function() Options:Fill() W.Refresh(p) end)
	local ok, cat = pcall(SS.RegisterCanvasLayoutCategory, p, "Goblin Gazette")
	if ok and cat then
		pcall(SS.RegisterAddOnCategory, cat)
		self.category = cat
	end
end

function Options:Fill()
	local p = self.panel
	if not p or p.filled then return end
	p.filled = true

	local logo = p:CreateTexture(nil, "ARTWORK")
	logo:SetSize(52, 52)
	logo:SetPoint("TOPLEFT", 16, -14)
	logo:SetTexture(P.MEDIA .. "Logo")
	local title = W.Text(p, "title", 22, "header")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, -6)
	title:SetText("Goblin Gazette  " .. P.VERSION)
	local about = W.Text(p, "body", 12, "text")
	about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	about:SetText("Ride Fizzwick's steam trike up the lane and deliver the Goblin Gazette: mailboxes score best, doorsteps will do, and the grey houses' windows are fair game. Mind the kobolds.")
	about:SetWidth(560)

	local st = W.Stack(p, 16, -86)
	local function C(key, label, tip)
		local cb = W.Check(p, label, function() return P:Setting(key) end, function(v) P:SetSetting(key, v) end, tip)
		p.widgets[#p.widgets + 1] = cb
		st:Add(cb, 30)
	end
	st:Add(W.Header(p, "Sound"), 26)
	C("sound", "Sound effects", "The trike's motor, the throws and hits, the street, the kobolds. Also on the speaker button in the game window.")
	C("music", "Music", "The menu, riding and results themes; the riding theme turns urgent while a kobold is after you. Also on the note button in the game window.")
	st:Gap(8)
	st:Add(W.Header(p, "Window and sharing"), 26)
	local size = W.Cycle(p, "Window size", function()
		return { { 0.6, "Small" }, { 0.75, "Medium" }, { 0.9, "Large" }, { 1, "Fill the screen" } }
	end, function() return P:Setting("size") end, function(v)
		P:SetSetting("size", v)
	end)
	p.widgets[#p.widgets + 1] = size
	st:Add(size, 36)
	C("shareScores", "Share scores on the leaderboard", "Your best rounds go to Goblin Gazette riders in your guild and on the Nether family's hidden games channel, and theirs come to you. Every score is checked by riding the round again before it counts.")
	C("minimapButton", "Show the minimap button")
	C("followNetherUI", "Follow NetherUI's theme", "This page takes your current NetherUI theme (when NetherUI is installed). The game itself keeps Goblin Gazette's art.")
	st:Gap(10)

	local play = st:Add(W.Button(p, "Play Goblin Gazette", 170, function() CloseSettings() P.Game:Open() end), 32)
	-- reset asks twice: the first click arms it for a few seconds
	local reset
	local armed = false
	reset = W.Button(p, "Reset my records", 170, function()
		if not armed then
			armed = true
			reset:SetText("Click again to reset")
			P:After(4, function()
				if armed then armed = false reset:SetText("Reset my records") end
			end)
			return
		end
		armed = false
		reset:SetText("Records reset")
		P.Game:ResetRecords()
		P:After(2, function() if not armed then reset:SetText("Reset my records") end end)
	end)
	reset:SetPoint("LEFT", play, "RIGHT", 12, 0)
	local rn = W.Text(p, "body", 11, "textDim")
	rn:SetPoint("LEFT", reset, "RIGHT", 10, 0)
	rn:SetText("This character's best score, rides, daily routes, trophies, medals and farthest ride.")
	local hint = W.Text(p, "body", 11, "textDim")
	hint:SetPoint("TOPLEFT", play, "BOTTOMLEFT", 0, -14)
	hint:SetText("Commands: /gazette or /goblingazette (play), /gazette daily, /gazette board, /gazette trophies, /gazette sound, /gazette music, /gazette size <0.5-1>, /gazette perf, /gazette debug, /gazette reset.")

	W.pages[#W.pages + 1] = p
	-- the page's backing and text follow the skin (the family look, or the current NetherUI theme)
	local bg = p:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	Skin:Paint(bg, "bg", { alpha = 0.35 })
end

function Options:Open()
	self:Build()
	local SS = rawget(_G, "Settings")
	if self.category and SS and SS.OpenToCategory then
		local id = self.category.GetID and self.category:GetID() or self.category.ID
		pcall(SS.OpenToCategory, id)
		return true
	end
	return false
end

P:Register("LOGIN", function() Options:Build() end)
P:Register("SETTINGS_CHANGED", function() if Options.panel and Options.panel:IsShown() then W.Refresh(Options.panel) end end)
