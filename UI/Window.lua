--[[ Goblin Gazette - UI/Window.lua
	The game window and the one driver: the ride ticks 30 times a second while it is on screen and not
	paused, and the stage draws every frame between ticks.

	  G:Open() / G:Close() / G:Toggle() / G:IsOpen()
	  G:NewRide([daily])            a fresh route at the start line (daily: today's route, the same for everyone)
	  G:FromScreen(what)            "next" street, "daily" route, or "again" (the same kind as the last round)
	  G:PeekZone()                  the region the next street will be in
	  G:Pause(on)                   the pause card (Esc, closing the window, combat)
	  G:Perf()                      the /gazette perf readout

	Combat: the window steps aside at once (keyboard released, ride paused) and comes back paused when
	the fight is over; it carries on only with a click or Space. Closed: no OnUpdate, no keyboard. ]]

local _, ns = ...
local P = ns.P
local G = P:Module("Game")
local A, St, Rt, Dr, Rd, Hz, Au, Bn = P.Assets, P.Stage, P.Route, P.Drive, P.Round, P.Hazards, P.Audio, P.Bonus
local Rp, Dy, LB = P.Replay, P.Daily, P.Leaderboard
local Sc                          -- UI/Screens.lua (loaded after this file)
local W = ns.World

local floor, max, min = math.floor, math.max, math.min
local STAGE_W, STAGE_H = 952, 552
-- the window is the framed street and nothing else (no backing slab round it); the wordmark hangs
-- MARK_UP px above it, which the screen clamp and the fit-to-screen size both allow for
local RIM = 14
local WIN_W, WIN_H = STAGE_W + 2 * RIM, STAGE_H + 2 * RIM
local MARK_UP = 92
local TICK = 1 / Dr.TPS
local ROUTE_LEN = Rp.LENGTH

local Win
local ride
local acc = 0
local paused = false
local perf = { n = 0, sum = 0, max = 0, over = 0, tag = "" }

local function InCombat() return InCombatLockdown and InCombatLockdown() end
local HINT = "Space throws      W / S speed up / slow down      A / D swerve      Esc pause"
local HINT_BONUS = "Space throws right      W / S speed up / slow down      A / D swerve      Esc pause"

-- what each of the round's events sounds like (one sound per event; Audio throttles repeats)
local EVENT_SOUND = {
	throw = "throw", mail = "hit_mailbox", bump = "hit_wall", smash = "breakable_smash", yard = "breakable_smash",
	wall = "hit_wall", window = "window_break", door = "hit_door", empty = "ui_error", pickup = "pickup",
	lost = "subscriber_lost", crash = "crash", caught = "caught", splash = "splash", escape = "chaser_escape", alert = "chaser_alert",
	horn = "horn", recover = "engine_rev",
	jump = "ramp_jump", land = "land", target = "target_hit", dummy = "target_hit", skid = "brake",
}
-- and the controls, as they go down while riding
local KEY_SOUND = { fast = "engine_rev", slow = "brake", up = "swerve", down = "swerve" }

local function NewSeed()
	local t = (time and time() or 0) % 1000000
	local g = floor(((GetTime and GetTime() or 0) * 1000) % 1000000)
	return (t * 7919 + g * 104729) % 2147483646 + 1
end

-- ------------------------------------------------------------------ building blocks
local function Text(parent, size, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT, size, "")
	fs:SetTextColor(r or 1, g or 0.95, b or 0.85)
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 0.9)
	return fs
end

-- a 9-slice of one atlas sprite: corners fixed at `corner` px, edges stretched along their length
local function Slice9(f, layer, name, corner)
	local file, u0, u1, v0, v1 = A:Rect(name)
	if not file then return end
	local w, h = A:Size(name)
	local cu, cv = (u1 - u0) * corner / w, (v1 - v0) * corner / h
	local us = { u0, u0 + cu, u1 - cu, u1 }
	local vs = { v0, v0 + cv, v1 - cv, v1 }
	for row = 1, 3 do
		for col = 1, 3 do
			local t = f:CreateTexture(nil, layer)
			t:SetTexture(file)
			t:SetTexCoord(us[col], us[col + 1], vs[row], vs[row + 1])
			if col == 1 then t:SetPoint("LEFT", f, "LEFT") t:SetWidth(corner)
			elseif col == 3 then t:SetPoint("RIGHT", f, "RIGHT") t:SetWidth(corner)
			else t:SetPoint("LEFT", f, "LEFT", corner, 0) t:SetPoint("RIGHT", f, "RIGHT", -corner, 0) end
			if row == 1 then t:SetPoint("TOP", f, "TOP") t:SetHeight(corner)
			elseif row == 3 then t:SetPoint("BOTTOM", f, "BOTTOM") t:SetHeight(corner)
			else t:SetPoint("TOP", f, "TOP", 0, -corner) t:SetPoint("BOTTOM", f, "BOTTOM", 0, corner) end
		end
	end
end

-- a 3-slice of one atlas sprite: end caps fixed at `cap` px wide, the middle stretched
local function Slice3(f, layer, name, cap)
	local file, u0, u1, v0, v1 = A:Rect(name)
	if not file then return end
	local w = A:Size(name)
	local cu = (u1 - u0) * cap / w
	local us = { u0, u0 + cu, u1 - cu, u1 }
	for col = 1, 3 do
		local t = f:CreateTexture(nil, layer)
		t:SetTexture(file)
		t:SetTexCoord(us[col], us[col + 1], v0, v1)
		t:SetPoint("TOP") t:SetPoint("BOTTOM")
		if col == 1 then t:SetPoint("LEFT") t:SetWidth(cap)
		elseif col == 3 then t:SetPoint("RIGHT") t:SetWidth(cap)
		else t:SetPoint("LEFT", f, "LEFT", cap, 0) t:SetPoint("RIGHT", f, "RIGHT", -cap, 0) end
	end
end

-- ------------------------------------------------------------------ the window
local card, cardTitle, cardText, cardHint
local dial, needle, track, marker, hint
local hud = {}           -- score plate, papers, subscribers: text written only when a value changes
local buttons = {}       -- the options, music and sound buttons by the close button

local function Card(title, text, hintText, height)
	card:SetHeight(height or 170)
	cardTitle:SetText(title or "")
	cardText:SetText(text or "")
	cardHint:SetText(hintText or "")
	card:Show()
end

local function Build()
	Win = CreateFrame("Frame", nil, UIParent)
	G.W = Win
	Win:SetSize(WIN_W, WIN_H)
	Win:SetPoint("CENTER")
	Win:SetFrameStrata("MEDIUM")
	Win:SetToplevel(true)
	Win:SetClampedToScreen(true)
	if Win.SetClampRectInsets then Win:SetClampRectInsets(0, 0, MARK_UP, 0) end
	Win:SetMovable(true)
	Win:EnableMouse(true)
	Win:RegisterForDrag("LeftButton")
	Win:SetScript("OnDragStart", function(self) self:StartMoving() end)
	Win:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint(1)
		if P.db and not P.readOnly then P.db.window = { p, rp, floor(x + 0.5), floor(y + 0.5) } end
	end)
	Win:Hide()

	St:Build(Win, STAGE_W, STAGE_H)
	St.frame:SetPoint("TOP", Win, "TOP", 0, -RIM)
	-- a click on the street throws too; dragging it still moves the window
	St.frame:EnableMouse(true)
	St.frame:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" and ride and ride.phase == "ride" and not paused and not card:IsShown() then Rd:Throw(ride) end
	end)
	St.frame:RegisterForDrag("LeftButton")
	St.frame:SetScript("OnDragStart", function() Win:StartMoving() end)
	St.frame:SetScript("OnDragStop", function() Win:GetScript("OnDragStop")(Win) end)

	-- the frame over the stage edges, the wordmark over the top
	local rim = CreateFrame("Frame", nil, Win)
	rim:SetPoint("TOPLEFT", St.frame, "TOPLEFT", -RIM, RIM)
	rim:SetPoint("BOTTOMRIGHT", St.frame, "BOTTOMRIGHT", RIM, -RIM)
	rim:SetFrameLevel(St.frame:GetFrameLevel() + 9800)
	local ws = W.ui.window_frame
	Slice9(rim, "ARTWORK", "window_frame", ws and ws.slice or 32)

	local top = CreateFrame("Frame", nil, Win)
	top:SetAllPoints()
	top:SetFrameLevel(rim:GetFrameLevel() + 10)
	G.top = top
	local mark = top:CreateTexture(nil, "ARTWORK")
	A:Sprite(mark, "wordmark")
	mark:SetSize(270, 120)
	mark:SetPoint("TOP", Win, "TOP", 0, MARK_UP + 14)

	local close = CreateFrame("Button", nil, top)
	close:SetSize(32, 32)
	close:SetPoint("TOPRIGHT", St.frame, "TOPRIGHT", -10, -10)
	close.n = close:CreateTexture(nil, "ARTWORK") A:Sprite(close.n, "close_normal") close.n:SetAllPoints()
	close.h = close:CreateTexture(nil, "HIGHLIGHT") A:Sprite(close.h, "close_hover") close.h:SetAllPoints()
	close:SetScript("OnClick", function() G:Close() end)

	-- beside the close button: the options page, music on/off, sound on/off (the pack's square brass buttons)
	local function Square(icon, tip, onClick)
		local b = CreateFrame("Button", nil, top)
		b:SetSize(38, 38)
		b.n = b:CreateTexture(nil, "ARTWORK") A:Sprite(b.n, "button_square_normal") b.n:SetAllPoints()
		b.p = b:CreateTexture(nil, "ARTWORK") A:Sprite(b.p, "button_square_pressed") b.p:SetAllPoints()
		b:SetNormalTexture(b.n)
		b:SetPushedTexture(b.p)
		b.h = b:CreateTexture(nil, "HIGHLIGHT") A:Sprite(b.h, "button_square_hover") b.h:SetAllPoints()
		b.h:SetBlendMode("BLEND")
		b.icon = b:CreateTexture(nil, "OVERLAY")
		b.icon:SetSize(24, 24)
		b.icon:SetPoint("CENTER", 0, 1)
		A:Sprite(b.icon, icon)
		b.tip = tip
		b:SetScript("OnClick", onClick)
		b:SetScript("OnEnter", function(self)
			if not GameTooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:SetText(type(self.tip) == "function" and self.tip() or self.tip, 1, 0.86, 0.45)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
		return b
	end
	local function Toggle(key)
		P:SetSetting(key, not (P:Setting(key) ~= false))
		Au:Play("ui_click")
	end
	buttons.sound = Square("icon_sound_on", function() return P:Setting("sound") ~= false and "Sound effects: on" or "Sound effects: off" end,
		function() Toggle("sound") end)
	buttons.sound:SetPoint("RIGHT", close, "LEFT", -6, 0)
	buttons.music = Square("icon_music_on", function() return P:Setting("music") ~= false and "Music: on" or "Music: off" end,
		function() Toggle("music") end)
	buttons.music:SetPoint("RIGHT", buttons.sound, "LEFT", -4, 0)
	buttons.menu = Square("icon_menu", "Options", function() G:OpenOptions() end)
	buttons.menu:SetPoint("RIGHT", buttons.music, "LEFT", -4, 0)
	buttons.trophy = Square("icon_trophy", "The trophy shelf", function() G:OpenTrophies() end)
	buttons.trophy:SetPoint("RIGHT", buttons.menu, "LEFT", -4, 0)
	G:SyncButtons()

	-- the ride's own pieces (controls, numbers, dial, rail) go together: the screens hide them
	local hudF = CreateFrame("Frame", nil, top)
	hudF:SetAllPoints()
	G.hudF = hudF
	local top = hudF
	-- the controls, inside the frame along the bottom of the street, on a soft dark strip
	local strip = top:CreateTexture(nil, "BACKGROUND")
	strip:SetColorTexture(0.05, 0.04, 0.03, 0.62)
	strip:SetSize(660, 26)
	strip:SetPoint("BOTTOM", St.frame, "BOTTOM", 0, 8)
	hint = Text(top, 13, 0.85, 0.8, 0.68)
	hint:SetPoint("CENTER", strip, "CENTER", 0, 0)
	hint:SetText(HINT)

	-- the round's numbers, top left of the street: score on its brass plate, papers left, subscribers kept
	local plate = CreateFrame("Frame", nil, top)
	local pw = W.ui.hud_plate_score
	plate:SetSize(pw.w * 1.1, pw.h)
	plate:SetPoint("TOPLEFT", St.frame, "TOPLEFT", 10, -8)
	Slice3(plate, "ARTWORK", "hud_plate_score", pw.slice or 48)
	hud.score = Text(plate, 18, 0.22, 0.13, 0.05)
	hud.score:SetShadowOffset(0, 0)
	hud.score:SetPoint("CENTER", 0, 2)
	local pi = top:CreateTexture(nil, "ARTWORK")
	A:Sprite(pi, "hud_papers")
	pi:SetSize(W.ui.hud_papers.w, W.ui.hud_papers.h)
	pi:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 6, 2)
	hud.papers = Text(top, 16, 0.95, 0.92, 0.8)
	hud.papers:SetPoint("LEFT", pi, "RIGHT", 2, -2)
	local si = top:CreateTexture(nil, "ARTWORK")
	A:Sprite(si, "hud_subscriber_on")
	si:SetSize(W.ui.hud_subscriber_on.w, W.ui.hud_subscriber_on.h)
	si:SetPoint("LEFT", pi, "RIGHT", 64, 0)
	hud.subs = Text(top, 16, 0.95, 0.92, 0.8)
	hud.subs:SetPoint("LEFT", si, "RIGHT", 6, -1)
	-- lives: one trike per life, greyed when spent
	hud.lives = {}
	local lw = W.ui.hud_life_full
	for k = 1, P.Hazards.LIVES do
		local t = top:CreateTexture(nil, "ARTWORK")
		A:Sprite(t, "hud_life_full")
		t:SetSize(lw.w, lw.h)
		t:SetPoint("LEFT", si, "RIGHT", 64 + (k - 1) * (lw.w + 2), 0)
		hud.lives[k] = t
	end

	-- the speed dial: only the needle turns
	dial = top:CreateTexture(nil, "ARTWORK")
	A:Sprite(dial, "hud_speed_dial")
	dial:SetSize(110, 110)
	dial:SetPoint("BOTTOMLEFT", St.frame, "BOTTOMLEFT", 10, 6)
	needle = top:CreateTexture(nil, "ARTWORK", nil, 1)
	A:Sprite(needle, "hud_speed_needle")
	needle:SetSize(110, 110)
	-- the needle's pivot is its canvas centre; the dial's centre is its own canvas centre
	needle:SetPoint("CENTER", dial, "CENTER")
	-- the route rail along the top of the stage, the marker shows how far along the trike is
	track = top:CreateTexture(nil, "ARTWORK")
	A:Sprite(track, "hud_route_track")
	track:SetSize(420, 24)
	track:SetPoint("TOP", St.frame, "TOP", 0, -8)
	marker = top:CreateTexture(nil, "ARTWORK", nil, 1)
	A:Sprite(marker, "hud_route_marker")
	marker:SetSize(32, 32)

	-- the card: start, pause, end of the route
	card = CreateFrame("Button", nil, G.top)
	G.card = card
	card:SetSize(420, 170)
	card:SetPoint("CENTER", St.frame, "CENTER", 0, 30)
	Slice9(card, "BORDER", "panel", 32)
	-- the parchment is far too bright for cream text in daylight: a dark warm wash over the paper only,
	-- inside the frame's posts, so the frame keeps its own colours and a thin rim of paper shows round it
	local cb = card:CreateTexture(nil, "ARTWORK")
	cb:SetPoint("TOPLEFT", 20, -18)
	cb:SetPoint("BOTTOMRIGHT", -20, 18)
	cb:SetColorTexture(0.10, 0.075, 0.05, 0.84)
	cardTitle = Text(card, 22, 1, 0.86, 0.45)
	cardTitle:SetPoint("TOP", 0, -26)
	cardText = Text(card, 14)
	cardText:SetPoint("TOP", cardTitle, "BOTTOM", 0, -12)
	cardText:SetWidth(360)
	cardHint = Text(card, 13, 0.75, 0.9, 0.6)
	cardHint:SetPoint("BOTTOM", 0, 24)
	card:SetScript("OnClick", function() G:Go() end)

	Win:SetScript("OnKeyDown", function(self, key)
		if InCombat() then return end
		local handled = G:Key(key, true)
		self:SetPropagateKeyboardInput(not handled)
	end)
	Win:SetScript("OnKeyUp", function(_, key) if not InCombat() then G:Key(key, false) end end)
	Win:SetScript("OnShow", function() G:Shown() end)
	Win:SetScript("OnHide", function() G:Hidden() end)

	local wp = P.db and P.db.window
	if type(wp) == "table" and type(wp[1]) == "string" and type(wp[3]) == "number" and type(wp[4]) == "number" then
		Win:ClearAllPoints()
		if not pcall(Win.SetPoint, Win, wp[1], UIParent, wp[2] or wp[1], wp[3], wp[4]) then Win:SetPoint("CENTER") end
	end
end

-- the speaker and note show whether they're on; changed from here, the options page, NetherSuite or a slash
function G:SyncButtons()
	if buttons.sound then
		A:Sprite(buttons.sound.icon, P:Setting("sound") ~= false and "icon_sound_on" or "icon_sound_off")
		A:Sprite(buttons.music.icon, P:Setting("music") ~= false and "icon_music_on" or "icon_music_off")
	end
end
P:Register("SETTINGS_CHANGED", function(key) if key == "sound" or key == "music" then G:SyncButtons() end end)

-- the options page (Esc > Options > AddOns > Goblin Gazette): the ride pauses and the keyboard goes back
-- to the game's settings while they are open
function G:OpenOptions()
	if ride and ride.phase == "ride" and not paused then self:Pause(true) end
	self:Keyboard(false)
	local sp = rawget(_G, "SettingsPanel")
	if sp and not self.settingsHooked then
		-- the keyboard comes back when the settings close (the pause card is still up: Space carries on)
		self.settingsHooked = true
		sp:HookScript("OnHide", function() if Win and Win:IsShown() then G:Keyboard(true) end end)
	end
	if not (P.Options and P.Options:Open()) then
		self:Keyboard(true)
		P:Print("the options page isn't available on this client; /gazette sound, music and size work here.")
	end
end

-- the trophy shelf (from anywhere: a ride under way pauses first)
function G:OpenTrophies()
	Sc = Sc or P.Screens
	if ride and ride.phase == "ride" and not paused then self:Pause(true) end
	Au:Play("ui_click")
	Sc:Trophies()
end

-- this character's records: best score, rides, farthest
function G:ResetRecords()
	if P.char and not P.readOnly then
		local c = P.char
		c.farthest, c.rides, c.best, c.top, c.daily, c.dailyDays = nil, nil, nil, nil, nil, nil
		c.ach, c.medals, c.tot = nil, nil, nil
		-- and this character's own places on the boards (other riders' entries stay)
		local boards = P.db and P.db.board
		if type(boards) == "table" then
			for _, list in pairs(boards) do
				for i = #list, 1, -1 do if list[i].u == P.guid then table.remove(list, i) end end
			end
		end
	end
end

-- ------------------------------------------------------------------ the ride
-- the street's region: the next of the five each new street (remembered per character)
local function NextZone()
	local c = P.char
	local k = ((c and c.zone) or 0) % #Rt.ZONES + 1
	if c and not P.readOnly then c.zone = k end
	return Rt.ZONES[k]
end
function G:PeekZone()
	local c = P.char
	return Rt.ZONES[((c and c.zone) or 0) % #Rt.ZONES + 1].id
end

-- the region the game is in now (the Bonus Track keeps its street's)
function G:ZoneId()
	if not ride then return "elwynn" end
	return ride.route.street or ride.route.zone
end

function G:NewRide(daily)
	local zone, seed, date, day
	if daily then
		date, day = Dy:Today()
		zone = Rt:Zone(Dy:Zone(day))
		seed = Dy:Seed(day)
	else
		zone, seed = NextZone(), NewSeed()
	end
	local route = Rt:Build(zone.id, seed, ROUTE_LEN)
	ride = Dr:New(route)
	ride.daily, ride.day = date, day
	Rp:Track(ride)                       -- the inputs, so the round can be checked by playing it again
	self.lastDaily = daily and true or false
	if Sc then Sc:Hide() end
	G:ScreenShown(nil)
	self.ride = ride
	acc = 0
	St:Load(route)
	St:Update(ride, 1, 0)
	paused = false
	hud.last = nil
	G:HUD()
	if hint then hint:SetText(HINT) end
	if Win and Win:IsShown() then Au:Loop("amb", "amb_" .. zone.id) end
	Card(daily and ("Today's route: " .. zone.title) or zone.title,
		("Bright houses take the Gazette: a paper in the mailbox scores best, the doorstep will do. Grey houses don't subscribe, and their windows are fair game. %d papers to start; pick up bundles on the road."):format(Rd.PAPERS),
		"Click or press Space to ride", 200)
	if Win and Win:IsShown() then self:MusicNow() end
end

-- after the street: the Bonus Track, carrying the round's score and lives (a new ride on the course)
function G:NewBonus()
	local main = ride
	local route = Bn:Build(main.route.zone, main.route.seed)
	ride = Dr:New(route)
	ride.main = main
	ride.score = main.score
	ride.lives = main.lives
	ride.daily, ride.day = main.daily, main.day
	Rp:Track(ride)
	self.ride = ride
	acc = 0
	St:Load(route)
	St:Update(ride, 1, 0)
	paused = false
	hud.last = nil
	G:HUD()
	if hint then hint:SetText(HINT_BONUS) end
	Card("The Bonus Track",
		("The goblins' test course. Space throws to the RIGHT here: hit the targets and dummies on the far side. Jump the ramps (a hit thrown in the air scores double) and keep off the oil. %d papers; nothing here costs a trike."):format(Bn.PAPERS),
		"Click or press Space to ride", 200)
	if Win and Win:IsShown() then self:MusicNow() end
end

-- the round is over (the street and its Bonus Track, or out of trikes on the street)
local function Over(r) return r.phase == "done" and (r.route.bonus or r.out) end

-- the music for where the game is: the menu theme at the start line, the riding theme on the road, the
-- Bonus Track's own theme on the course (and on the card before it), the results theme once it's all over
function G:MusicNow()
	local sc = Sc and Sc:Showing()
	if sc == "menu" or ((sc == "board" or sc == "trophies") and Sc.back == "menu") then Au:Music("menu") return end
	if not ride then return end
	if Over(ride) then Au:Music("results")
	elseif ride.route.bonus or ride.phase == "done" then Au:Music("bonus")
	elseif ride.phase == "ride" then Au:Ride(Hz:Danger(ride))
	else Au:Music("menu") end
end

-- the numbers at the top left: rewritten only when one changes
function G:HUD()
	if not ride then return end
	local m = ride.main or ride          -- (on the Bonus Track: the street's subscribers)
	local kept = m.subs - m.stats.lost
	local key = (ride.score * 10000 + ride.papers * 100 + kept) * 10 + (ride.lives or 0)
	if hud.last == key then return end
	hud.last = key
	hud.score:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(ride.score) or tostring(ride.score))
	hud.papers:SetText(tostring(ride.papers))
	hud.subs:SetText(("%d / %d"):format(kept, m.subs))
	if ride.papers == 0 then hud.papers:SetTextColor(1, 0.45, 0.35) else hud.papers:SetTextColor(0.95, 0.92, 0.8) end
	for k = 1, #hud.lives do A:Sprite(hud.lives[k], k <= (ride.lives or 0) and "hud_life_full" or "hud_life_lost") end
end

-- the card's lines. final: the whole round is over (the best score is kept then, not before the Bonus Track)
local function Results(r, final)
	local m = r.main or r                -- the street's ride
	local s = m.stats
	local c = P.char
	local best = c and c.best or 0
	local newBest = final and r.score > best
	local num = BreakUpLargeNumbers or tostring
	local score
	if final then score = ("Score %s%s"):format(num(r.score), newBest and "  (a new best!)" or ("  (best %s)"):format(num(best)))
	else score = ("Score so far %s"):format(num(r.score)) end
	local lines = {
		score,
		("Delivered: %d in mailboxes, %d on doorsteps"):format(s.mail, s.door),
		("Subscribers kept: %d of %d  (+%s)"):format(s.kept, m.subs, num(s.bonus)),
		("Windows broken: %d    Mailboxes smashed: %d    Papers thrown: %d"):format(s.windows, s.smashed, s.thrown),
		s.penalty > 0 and ("Damage to subscribers' homes: -%s"):format(num(s.penalty)) or false,
	}
	if r.route.bonus then
		local b = r.stats
		lines[#lines + 1] = ("Bonus Track: %d targets, %d dummies, %d jumps%s  (+%s)"):format(b.targets, b.dummies, b.jumps,
			b.airHits > 0 and (", %d in the air"):format(b.airHits) or "", num(b.course))
	end
	local out = {}
	for k = 1, #lines do if lines[k] then out[#out + 1] = lines[k] end end
	return table.concat(out, "\n")
end

-- Space / click: start, resume, or ride again
function G:Go()
	if InCombat() then return end
	if not ride then return end
	if ride.phase == "done" then
		if Over(ride) then self:FromScreen("again") else self:NewBonus() end
		return
	end
	card:Hide()
	local was = paused
	paused = false
	self.afterCombat = nil
	if ride.phase == "ready" then
		Dr:Start(ride)
		if ride.route.bonus then
			Au:Play("engine_rev")
		else
			Au:StopMusic()
			Au:Play("day_start")
			Au:Ride(false)
		end
	elseif was then
		Au:Play("ui_confirm")
	end
	self:Keyboard(true)
end

function G:Pause(on)
	if not ride then return end
	if on then
		if not paused then Au:Play("ui_menu_open") end
		paused = true
		self:ReleaseHolds()
		Card("Paused", ("%d tiles along the lane."):format(floor(ride.a)), "Click or press Space to carry on      Esc closes")
	else
		self:Go()
	end
end

-- W/S speed up and slow down, A/D swerve (the houses are on the trike's left as it rides up the lane);
-- the arrow keys the same way round
local KEYS = { W = "fast", UP = "fast", S = "slow", DOWN = "slow", A = "up", LEFT = "up", D = "down", RIGHT = "down" }

function G:ReleaseHolds()
	if not ride then return end
	Dr:Release(ride)
end

function G:Key(key, down)
	if Sc and Sc:Showing() then
		if down then return Sc:Key(key) end
		return key == "SPACE" or key == "ESCAPE"
	end
	if key == "ESCAPE" then
		if not down then return true end
		if card:IsShown() then self:Close() else self:Pause(true) end
		return true
	end
	if key == "SPACE" then
		if down then
			if card:IsShown() then self:Go()
			elseif ride and ride.phase == "ride" and not paused then Rd:Throw(ride) end
		end
		return true
	end
	local k = KEYS[key]
	if k and ride then
		if not paused then
			Dr:Input(ride, k, down)
			if down and ride.phase == "ride" and not ride.fallen then Au:Play(KEY_SOUND[k]) end
		end
		return true
	end
	return false
end

function G:Keyboard(on)
	if not Win then return end
	if InCombat() then on = false end
	Win:EnableKeyboard(on and true or false)
	if not on then self:ReleaseHolds() end
end

-- ------------------------------------------------------------------ the screens
-- a screen came up (or went: nil): the ride's numbers hide under them, the street stops being drawn under
-- the opaque ones, the music follows
function G:ScreenShown(which)
	Sc = Sc or P.Screens
	if not Win then return end
	local on = which ~= nil
	if G.hudF then G.hudF:SetShown(not on) end
	if on and card then card:Hide() end
	-- (under the front page the finished street stands still behind the veil: it isn't redrawn either)
	G.covered = which ~= nil
	if on then self:ReleaseHolds() end
	if Win:IsShown() then self:MusicNow() end
end

function G:FromScreen(what)
	if InCombat() then return end
	if what == "again" then what = self.lastDaily and "daily" or "next" end
	self:NewRide(what == "daily")
	if Win and Win:IsShown() then Au:Loop("amb", "amb_" .. self:ZoneId()) end
end

-- the round is over: keep the records, put it on the boards, and write the front page's story
function G:Finish(r)
	local m = r.main or r
	local b = r.route.bonus and r or nil
	local c = P.char
	local score = r.score
	local zone, seed = m.route.zone, m.route.seed
	local code = m.log and Rp:Encode(m.log, b and b.log or {}) or nil
	local best = c and c.best or 0
	local newBest = score > best and score > 0
	local writable = c and not P.readOnly
	if writable and newBest then c.best = score end
	-- (the very first round is a best by default: the paper only calls it one when it beats an earlier round)
	local info = { zone = zone, seed = seed, score = score, best = best, newBest = newBest and best > 0, out = r.out and true or false,
		downKind = r.downKind, stats = m.stats, bonus = b and b.stats or nil, houses = m.route.houses, subs = m.subs,
		lost = m.stats.lost, windows = m.stats.windows, airHits = b and b.stats.airHits or 0, edition = c and c.rides or 1,
		who = LB.me or (UnitName and UnitName("player")) or "you", daily = r.daily, day = r.day or Dy:Day() }
	-- the best round with its replay (any street): the "Best ever" board
	if writable and code and score > 0 and (not c.top or score > c.top.s) then
		c.top = { s = score, z = zone, sd = seed, m = code, t = (GetServerTime and GetServerTime()) or 0, r = Rp.RULES }
		P:Safe("leaderboard record", LB.Record, LB, LB.ALL, score, zone, seed, code)
	end
	local id = LB.ALL
	if r.daily and code then
		local dailyBest = Dy:Finish(r.daily, score, code)
		info.dailyBest = dailyBest
		local rec = Dy:Record(r.daily)
		info.dailyBestScore = rec and rec.best
		if dailyBest then P:Safe("leaderboard record", LB.Record, LB, LB:DailyId(r.daily), score, zone, seed, code) end
		id = LB:DailyId(r.daily)
	end
	info.rank, info.rankOf = LB:Rank(id), #LB:Board(id)
	-- the medal (and the round's own achievements: their toasts come up over the front page)
	local okR, medal, potential = pcall(P.Rewards.Round, P.Rewards, r, info)
	if okR then info.medal, info.potential = medal, potential else P:RecordError("trophies", medal) end
	return info
end

-- ------------------------------------------------------------------ the driver
local function OnError(err)
	P:RecordError("game loop", err)
	return err
end

local lastNeedle, lastMarker
local stepDt = 0
local function Step()
	local dt = stepDt
	if not ride then return end
	if not paused and ride.phase == "ride" then
		acc = acc + dt
		local n = 0
		while acc >= TICK and n < 4 do
			acc = acc - TICK
			n = n + 1
			Dr:Tick(ride)
			if ride.phase ~= "ride" then break end
		end
		if acc > TICK then acc = 0 end        -- a long hitch: drop the backlog instead of racing to catch up
		perf.tag = n > 0 and "ride" or "draw"
		-- what happened in those ticks: the stage swaps art, plays effects and pops the points
		local ne = Rd:Drain(ride)
		if ne > 0 then
			for k = 1, ne do
				local e = Rd:Event(ride, k)
				St:OnEvent(e)
				local snd = EVENT_SOUND[e.what]
				if snd then Au:Play(snd) end
			end
			Rd:Clear(ride)
		end
		G:HUD()
		if ride.phase == "done" then
			local c = P.char
			local m = ride.main or ride
			Au:StopLoop("engine")
			if not ride.route.bonus then P:Safe("trophies", P.Rewards.Street, P.Rewards, ride) end
			if not ride.route.bonus and c and not P.readOnly then
				c.rides = (c.rides or 0) + 1
				if not c.farthest or ride.farthest > c.farthest then c.farthest = floor(ride.farthest) end
			end
			G:HUD()
			if Over(ride) then
				-- the sign-off: a stinger for a record, a clean round or running out of trikes, then the results theme
				local record = ride.score > ((c and c.best) or 0) and ride.score > 0
				Au:Play("day_end")
				Au:Stinger(ride.out and "fail" or record and "record" or (m.stats.lost == 0 and "perfect") or nil, "results")
				card:Hide()
				Sc:Front(G:Finish(ride))
			else
				-- the street is done: on to the Bonus Track
				Au:Play("day_end")
				Au:Music("bonus")
				Card("The street is done!", Results(ride, false), "Click or press Space for the Bonus Track", 230)
			end
		end
	end
	-- the sound: the motor while the trike is going, the street's bed, the riding theme's mix
	local t2 = P:ProfStart()
	if ride.phase == "ride" and not paused and not ride.fallen then Au:Loop("engine", "engine")
	elseif Au:Looping("engine") then Au:StopLoop("engine", 250) end
	if ride.phase == "ride" and Au:Riding() then Au:Ride(Hz:Danger(ride)) end
	Au:Update()
	P:ProfEnd("audio", t2)
	-- (under the screens the street isn't redrawn)
	if G.covered then return end
	local t1 = P:ProfStart()
	local alpha = (ride.phase == "ride" and not paused) and min(1, acc / TICK) or 1
	St:Update(ride, alpha, paused and 0 or dt)
	P:ProfEnd("stage", t1)
	-- the dial: 0 to the fast speed over 240 degrees; the rail: how far along
	local v = floor(ride.v * 20) / 20
	if v ~= lastNeedle then
		lastNeedle = v
		local f = min(1, v / Dr.SPEED.fast)
		needle:SetRotation(math.rad(120 - 240 * f))
	end
	local m = floor(min(1, ride.a / ride.route.length) * 400)
	if m ~= lastMarker then
		lastMarker = m
		marker:ClearAllPoints()
		marker:SetPoint("CENTER", track, "LEFT", 10 + m, 0)
	end
end

local function Drive(_, elapsed)
	if elapsed > 0.1 then elapsed = 0.1 end
	local t0 = debugprofilestop and debugprofilestop()
	stepDt = elapsed
	local ok = xpcall(Step, OnError)
	if not ok then
		Win:SetScript("OnUpdate", nil)
		P:Print("something went wrong, so the game stopped. /gazette debug shows details; reopening restarts it.")
		return
	end
	if t0 then
		local ms = debugprofilestop() - t0
		perf.n = perf.n + 1
		perf.sum = perf.sum + ms
		if ms > perf.max then perf.max = ms perf.worst = perf.tag end
		if ms > 0.5 then perf.over = perf.over + 1 end
	end
end

function G:Shown()
	self:FitScale()
	Win:SetScript("OnUpdate", Drive)
	-- after a fight the keyboard comes back with the click that carries on, not before
	self:Keyboard(not self.afterCombat)
	P:Listen("PLAYER_REGEN_DISABLED")
	if ride and ride.phase == "ride" and not card:IsShown() then self:Pause(true) end
	if not self.afterCombat then Au:Play("ui_menu_open") end
	if ride then Au:Loop("amb", "amb_" .. self:ZoneId()) end
	self:MusicNow()
end

function G:Hidden()
	Win:SetScript("OnUpdate", nil)       -- closed costs nothing
	self:ReleaseHolds()
	if ride and ride.phase == "ride" and not self.combatHidden then paused = true end
	if not self.combatHidden then
		P:Off("PLAYER_REGEN_DISABLED")
		Au:Play("ui_menu_close")
	end
	Au:Halt()                            -- closed: no music, no beds (zone music comes back)
end

function G:FitScale()
	if not Win then return end
	local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
	local size = tonumber(P:Setting("size")) or 0.9
	local sc = min(uw / WIN_W, uh / (WIN_H + MARK_UP)) * max(0.5, min(1, size))
	Win:SetScale(max(0.35, min(1.6, sc)))
end

function G:Open()
	if InCombat() then
		P:Print("opens after combat.")
		return
	end
	if not P.db then return end
	if not Win then Build() end
	Sc = Sc or P.Screens
	Win:Show()
	-- no round under way: the press office (a finished round keeps its front page)
	if not ride then Sc:Menu()
	elseif Over(ride) and not Sc:Showing() then Sc:Menu() end
end

function G:Close()
	if Win and Win:IsShown() then Win:Hide() end
end

function G:Toggle()
	if Win and Win:IsShown() then self:Close() else self:Open() end
end

function G:IsOpen() return Win ~= nil and Win:IsShown() end

-- ------------------------------------------------------------------ combat: step aside at once
P:On("PLAYER_REGEN_DISABLED", function()
	if not Win or not Win:IsShown() then return end
	G.combatHidden = true
	G:Keyboard(false)
	if ride and ride.phase == "ride" then
		paused = true
		Card("Paused for combat", "The ride is frozen exactly where it was.", "When the fight is over, click here to carry on")
	end
	Win:Hide()
	P:Listen("PLAYER_REGEN_ENABLED")
end)
P:Off("PLAYER_REGEN_DISABLED")

P:On("PLAYER_REGEN_ENABLED", function()
	P:Off("PLAYER_REGEN_ENABLED")
	if not G.combatHidden then return end
	G.combatHidden = false
	if not Win then return end
	G.afterCombat = true
	Win:Show()
end)
P:Off("PLAYER_REGEN_ENABLED")

P:On("DISPLAY_SIZE_CHANGED", function() G:FitScale() end)
P:On("UI_SCALE_CHANGED", function() G:FitScale() end)

-- ------------------------------------------------------------------ perf, debug, slash
function G:Perf()
	local avg = perf.n > 0 and perf.sum / perf.n or 0
	local mem
	if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
		UpdateAddOnMemoryUsage()
		mem = GetAddOnMemoryUsage(P.name)
	end
	P:Print("frame time %.3f ms average, %.3f ms worst (%s) over %d frames, %d frame(s) over the 0.5 ms budget; %s; %d scenery pieces on show; memory %s KB.",
		avg, perf.max, perf.worst or "-", perf.n, perf.over,
		(Win and Win:IsShown()) and "window open" or "window closed: 0 ms, no OnUpdate",
		St:LiveCount(), mem and ("%.0f"):format(mem) or "?")
	local parts = {}
	for name, ms in pairs(P.prof) do if ms >= 0.1 then parts[#parts + 1] = name end end
	table.sort(parts, function(x, y) return P.prof[x] > P.prof[y] end)
	for i, name in ipairs(parts) do parts[i] = ("%s %.2f"):format(name, P.prof[name]) end
	if #parts > 0 then P:Print("slowest parts (ms): %s.", table.concat(parts, ", ")) end
	wipe(P.prof)
	perf.n, perf.sum, perf.max, perf.over, perf.worst = 0, 0, 0, 0, nil
end

local function Slash(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "perf" then
		G:Perf()
	elseif msg == "debug" then
		P.debug = not P.debug
		P:Print("debug %s. %d error(s) recorded; %d missing art.", P.debug and "on" or "off", #P.errors, #A.missing)
		for i = 1, #P.errors do P:Print("  %s (x%d)", P.errors[i].text, P.errors[i].n) end
		for i = 1, #A.missing do P:Print("  missing %s", A.missing[i]) end
	elseif msg == "reset" then
		if P.db and not P.readOnly then P.db.window = nil end
		G:ResetRecords()
		if Win then Win:ClearAllPoints() Win:SetPoint("CENTER") end
		P:Print("window position and this character's records reset.")
	elseif msg == "sound" or msg == "music" then
		local on = not (P:Setting(msg) ~= false)
		P:SetSetting(msg, on)
		P:Print("%s %s.", msg == "sound" and "sound effects" or "music", on and "on" or "off")
	elseif msg:match("^size") then
		local v = tonumber(msg:match("^size%s+([%d%.]+)"))
		if v and v >= 0.5 and v <= 1 and P.db then
			P.db.settings.size = v
			G:FitScale()
			P:Print("window size %.2f.", v)
		else
			P:Print("/gazette size 0.5 .. 1 (now %.2f).", P:Setting("size"))
		end
	elseif msg == "daily" then
		G:Open()
		if G:IsOpen() then G:FromScreen("daily") end
	elseif msg == "trophies" or msg == "trophy" then
		G:Open()
		if G:IsOpen() then G:OpenTrophies() end
	elseif msg == "board" or msg == "leaderboard" then
		G:Open()
		if G:IsOpen() and P.Screens then P.Screens:Board() end
	elseif msg == "" then
		G:Toggle()
	else
		P:Print("/gazette opens the game; /gazette daily (today's route), board (the leaderboard), trophies, perf, debug, reset, sound, music, size <0.5-1>.")
	end
end

SLASH_GOBLINGAZETTE1 = "/gazette"
SLASH_GOBLINGAZETTE2 = "/goblingazette"
SlashCmdList.GOBLINGAZETTE = function(msg) P:Safe("slash", Slash, msg) end
if NetherFamily and NetherFamily.Slash then NetherFamily:Slash(P.name, "GOBLINGAZETTE", "Goblin Gazette") end
