--[[ Goblin Gazette - UI/Screens.lua
	The screens round the ride, made the first time each is shown:

	  the press office   the menu: today's route card (date, region, your best), Next street, Today's route,
	                     Leaderboard
	  the front page     the round's results printed as the Gazette: a headline written from how it went, a
	                     photograph of the street with the trike as the round ended, the round's numbers, a
	                     map of every house (kept, lost, not a subscriber), the Bonus Track and the standings
	  the leaderboard    Today's route and Best ever, the top ten of each (Comm/Leaderboard.lua)

	  the trophy shelf   the twelve achievements (earned, or how far along) and each route's best medal
	  toasts             a banner at the top of the street for each achievement as it is earned

	  Sc:Menu()  Sc:Front(info)  Sc:Board([tab])  Sc:Trophies()  Sc:Toast(id)  Sc:Hide()
	  Sc:Showing() -> "menu" | "front" | "board" | "trophies" | nil
	  Sc:Key(key) -> true when a screen used the key

	Text is the game's own (the art has none but the masthead): dark ink on the paper, cream on dark panels.
	Every label is fitted to its well, so a long "Name Surname-Realm" or headline shrinks rather than spills. ]]

local _, ns = ...
local P = ns.P
local Sc = P:Module("Screens")
local G, A, Rt, Au = P.Game, P.Assets, P.Route, P.Audio
local W = ns.World

local floor, min, max = math.floor, math.min, math.max
local TEX = P.MEDIA .. "Tex\\"
local SERIF = "Fonts\\MORPHEUS.TTF"           -- the newspaper's headline face (falls back to the standard font)
local BODY = "Fonts\\FRIZQT__.TTF"
local INK = { 0.13, 0.09, 0.06 }
local INK_SOFT = { 0.30, 0.22, 0.14 }
local CREAM = { 0.96, 0.91, 0.78 }
local GOLD = { 1, 0.84, 0.42 }

local frames = {}           -- menu, front, board, veil
local showing

-- ------------------------------------------------------------------ text
local fontOk = {}
local function SetFont(fs, face, size)
	if fontOk[face] ~= false then
		local ok = fs:SetFont(face, size, "")
		if ok == false or (ok == nil and not fs:GetFont()) then fontOk[face] = false else fontOk[face] = true return end
	end
	fs:SetFont(STANDARD_TEXT_FONT, size, "")
end

local function Text(parent, face, size, color, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	SetFont(fs, face, size)
	fs:SetTextColor(color[1], color[2], color[3])
	fs.face, fs.size = face, size
	return fs
end

-- one line that must fit `width`: the size steps down (to `least`) until it does
local function Fit(fs, text, width, least)
	SetFont(fs, fs.face, fs.size)
	fs:SetText(text)
	local s = fs.size
	while fs:GetStringWidth() > width and s > (least or 8) do
		s = s - 1
		SetFont(fs, fs.face, s)
		fs:SetText(text)
	end
end
Sc.Fit = Fit

-- ------------------------------------------------------------------ pieces
-- a 3-slice of an atlas sprite whose caps scale with its height
local function Slice3(f, layer, name, h)
	local file, u0, u1, v0, v1 = A:Rect(name)
	if not file then return {} end
	local sw, shh = A:Size(name)
	local rec = W.ui[name]
	local capSrc = rec and rec.slice or (sw * 0.2)
	local cap = capSrc * h / shh
	local cu = (u1 - u0) * capSrc / sw
	local us = { u0, u0 + cu, u1 - cu, u1 }
	local out = {}
	for col = 1, 3 do
		local t = f:CreateTexture(nil, layer)
		t:SetTexture(file)
		t:SetTexCoord(us[col], us[col + 1], v0, v1)
		t:SetPoint("TOP") t:SetPoint("BOTTOM")
		if col == 1 then t:SetPoint("LEFT") t:SetWidth(cap)
		elseif col == 3 then t:SetPoint("RIGHT") t:SetWidth(cap)
		else t:SetPoint("LEFT", f, "LEFT", cap, 0) t:SetPoint("RIGHT", f, "RIGHT", -cap, 0) end
		out[col] = t
	end
	out.cap = cap
	return out
end

local function Repaint(set, name)
	local file, u0, u1, v0, v1 = A:Rect(name)
	if not file or not set[1] then return end
	local sw = A:Size(name)
	local rec = W.ui[name]
	local cu = (u1 - u0) * (rec and rec.slice or sw * 0.2) / sw
	local us = { u0, u0 + cu, u1 - cu, u1 }
	for col = 1, 3 do
		set[col]:SetTexture(file)
		set[col]:SetTexCoord(us[col], us[col + 1], v0, v1)
	end
end

-- the pack's wide brass button: the label sits on the plank between the gear ends (its label well: the
-- middle 0.60 of the width, measured on this art)
local function Button(parent, label, w, h, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	b.art = Slice3(b, "ARTWORK", "button_wide_normal", h)
	b.label = Text(b, BODY, 15, INK)
	b.label:SetPoint("CENTER", 0, 1)
	b.room = w - 2 * (b.art.cap or h) - 10
	b.state = "normal"
	local function Look(st)
		if b.state == st then return end
		b.state = st
		Repaint(b.art, "button_wide_" .. st)
		b.label:SetTextColor(st == "disabled" and 0.35 or INK[1], st == "disabled" and 0.35 or INK[2], st == "disabled" and 0.35 or INK[3])
	end
	b.Look = Look
	b:SetScript("OnEnter", function(self) if self:IsEnabled() then Look("hover") end end)
	b:SetScript("OnLeave", function(self) if self:IsEnabled() then Look("normal") end end)
	b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then Look("pressed") self.label:SetPoint("CENTER", 0, 0) end end)
	b:SetScript("OnMouseUp", function(self)
		self.label:SetPoint("CENTER", 0, 1)
		if self:IsEnabled() then Look(self:IsMouseOver() and "hover" or "normal") end
	end)
	b:SetScript("OnClick", function()
		Au:Play("ui_click")
		onClick()
	end)
	function b:SetLabel(text) Fit(self.label, text, self.room, 10) end
	function b:SetOn(on)
		if on then self:Enable() Look("normal") else self:Disable() Look("disabled") end
	end
	b:SetLabel(label)
	return b
end

local function Tab(parent, label, w, h, onClick)
	local t = CreateFrame("Button", nil, parent)
	t:SetSize(w, h)
	t.art = Slice3(t, "ARTWORK", "tab_inactive", h)
	t.label = Text(t, BODY, 13, INK)
	t.label:SetPoint("CENTER", 0, 1)
	Fit(t.label, label, w - 2 * (t.art.cap or h) - 4, 9)
	t:SetScript("OnEnter", function(self) if not self.active then Repaint(self.art, "tab_hover") end end)
	t:SetScript("OnLeave", function(self) if not self.active then Repaint(self.art, "tab_inactive") end end)
	t:SetScript("OnClick", function() Au:Play("ui_click") onClick() end)
	function t:SetActive(on)
		self.active = on
		Repaint(self.art, on and "tab_active" or "tab_inactive")
		self.label:SetTextColor(on and INK[1] or INK_SOFT[1], on and INK[2] or INK_SOFT[2], on and INK[3] or INK_SOFT[3])
	end
	return t
end

-- a 9-slice of an atlas sprite, corners drawn `corner` px
local function Slice9(f, layer, name, corner)
	local file, u0, u1, v0, v1 = A:Rect(name)
	if not file then return end
	local w, h = A:Size(name)
	local rec = W.ui[name]
	local c = rec and rec.slice or 32
	local cu, cv = (u1 - u0) * c / w, (v1 - v0) * c / h
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

-- ------------------------------------------------------------------ words
local num = function(v) return BreakUpLargeNumbers and BreakUpLargeNumbers(v) or tostring(v) end
Sc.Num = num
local DAYS = { "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
local function LongDate(day)
	local y, m, d = P.Daily.DateOf(day):match("^(%d+)-(%d+)-(%d+)$")
	return ("%s %d %s %s"):format(DAYS[day % 7 + 1], tonumber(d), MONTHS[tonumber(m)], y)
end
local function ShortDate(day)
	local _, m, d = P.Daily.DateOf(day):match("^(%d+)-(%d+)-(%d+)$")
	return ("%s %d %s"):format(DAYS[day % 7 + 1]:sub(1, 3), tonumber(d), MONTHS[tonumber(m)]:sub(1, 3))
end
Sc.LongDate, Sc.ShortDate = LongDate, ShortDate
local function Ordinal(n)
	local s = "th"
	if n % 100 < 11 or n % 100 > 13 then s = ({ "st", "nd", "rd" })[n % 10] or "th" end
	return n .. s
end
Sc.Ordinal = Ordinal

-- a route's region and street from its title ("Duskwood: Darkshire Lane")
local function Names(zone)
	local z = Rt:Zone(zone)
	local title = z and z.title or zone
	local region, street = title:match("^(.-):%s*(.+)$")
	return region or title, street or title
end
Sc.Names = Names

-- the headline: the first that fits how the round went; which wording, from the street's seed
local HEADLINES = {
	{ "caught", { "KOBOLD NABS GAZETTE GOBLIN ON %S", "CAUGHT! %R KOBOLDS 1, FIZZWICK 0", "PAPER ROUND ENDS IN KOBOLD AMBUSH" } },
	{ "crash", { "TRIKE TOTALLED ON %S", "WHEELS OFF IN %R!", "STEAM TRIKE MEETS ITS MATCH" } },
	{ "splash", { "GAZETTE GOBLIN TAKES AN EARLY BATH", "SOGGY EDITION: TRIKE SINKS IN %R", "PAPERS DROWNED ON %S" } },
	{ "record", { "RECORD RUN! FIZZWICK BANKS %N", "BEST ROUND EVER IN %R", "GAZETTE GOBLIN SETS NEW MARK" } },
	{ "perfect", { "EVERY SUBSCRIBER SERVED IN %R!", "NOT ONE SUBSCRIBER LOST!", "PERFECT DAY ON %S" } },
	{ "glass", { "GLASS SHORTAGE HITS %R", "%W WINDOWS SMASHED: GLAZIERS REJOICE", "WINDOWS FALL ON %S" } },
	{ "flee", { "%R CANCELS THE GAZETTE", "SUBSCRIBERS FLEE AS PAPERS MISS", "WHERE'S MY PAPER? ASKS %R" } },
	{ "stunts", { "STUNT GOBLIN WOWS TEST TRACK", "%A HITS IN THE AIR AT THE BONUS TRACK", "FIZZWICK FLIES!" } },
	{ "plain", { "THE GAZETTE GETS THROUGH IN %R", "ANOTHER DAY, ANOTHER DELIVERY", "PAPERS LAND ON %S" } },
}
local function Headline(info)
	local region, street = Names(info.zone)
	local why
	if info.out then why = (info.downKind == "caught" or info.downKind == "splash") and info.downKind or "crash"
	elseif info.newBest then why = "record"
	elseif info.lost == 0 and info.subs > 0 then why = "perfect"
	elseif info.windows >= 5 then why = "glass"
	elseif info.subs > 0 and info.lost * 2 > info.subs then why = "flee"
	elseif info.airHits >= 3 then why = "stunts"
	else why = "plain" end
	local list
	for _, h in ipairs(HEADLINES) do if h[1] == why then list = h[2] end end
	local text = list[(info.seed or 0) % #list + 1]
	text = text:gsub("%%S", street:upper()):gsub("%%R", region:upper()):gsub("%%N", num(info.score))
		:gsub("%%W", tostring(info.windows)):gsub("%%A", tostring(info.airHits))
	return text
end
Sc.Headline = Headline

-- ------------------------------------------------------------------ the veil behind the paper
local function Veil()
	if frames.veil then return frames.veil end
	local v = CreateFrame("Frame", nil, G.W)
	v:SetAllPoints(P.Stage.frame)
	v:SetFrameLevel(P.Stage.frame:GetFrameLevel() + 9500)
	local t = v:CreateTexture(nil, "BACKGROUND")
	t:SetAllPoints()
	t:SetColorTexture(0.03, 0.025, 0.02, 0.72)
	v:EnableMouse(true)                  -- the street under it can't be clicked
	v:Hide()
	frames.veil = v
	return v
end

-- ------------------------------------------------------------------ the press office
local function BuildMenu()
	local St = P.Stage
	local m = CreateFrame("Frame", nil, G.W)
	m:SetAllPoints(St.frame)
	m:SetFrameLevel(St.frame:GetFrameLevel() + 9500)
	m:EnableMouse(true)
	local SW, SH = St.frame:GetWidth(), St.frame:GetHeight()
	-- the press room fills the stage's height; the harbour window's left edge is let go
	local bg = m:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetTexture(TEX .. "PressOffice")
	local k = SH / 512
	local u0 = 1 - SW / k / 1024
	bg:SetTexCoord(u0, 1, 0, 1)
	-- the pack's quiet menu area, in stage px
	local mx0 = (614 - u0 * 1024) * k
	local mx1 = min(SW - 6, (992 - u0 * 1024) * k)
	local cx = (mx0 + mx1) / 2
	-- today's route card
	local cw = 400
	local ck = cw / 512
	local card = CreateFrame("Frame", nil, m)
	card:SetSize(cw, 256 * ck)
	card:SetPoint("TOP", m, "TOPLEFT", cx, -60)
	local ct = card:CreateTexture(nil, "ARTWORK")
	ct:SetAllPoints()
	ct:SetTexture(TEX .. "CardDaily")
	local function WellText(x, y, w, h, face, size, color)
		local fs = Text(card, face, size, color)
		fs:SetPoint("CENTER", card, "TOPLEFT", (x + w / 2) * ck, -(y + h / 2) * ck)
		fs:SetJustifyH("CENTER")
		fs.room = w * ck - 6
		return fs
	end
	m.kicker = Text(card, BODY, 10, GOLD)
	m.kicker:SetPoint("BOTTOM", card, "TOPLEFT", (318 + 88) * ck, -20 * ck)
	m.kicker:SetText("TODAY'S ROUTE")
	m.date = WellText(318, 22, 176, 44, SERIF, 17, CREAM)
	m.route = WellText(318, 86, 176, 48, SERIF, 16, CREAM)
	m.street = Text(card, BODY, 10, { 0.78, 0.74, 0.64 })
	m.street:SetPoint("TOP", m.route, "BOTTOM", 0, -1)
	m.best = WellText(318, 156, 176, 40, BODY, 13, GOLD)
	m.best2 = Text(card, BODY, 10, { 0.78, 0.74, 0.64 })
	m.best2:SetPoint("TOP", m.best, "BOTTOM", 0, -2)
	m.card = card
	-- the buttons
	local bw, bh = 300, 58
	m.next = Button(m, "Next street", bw, bh, function() G:FromScreen("next") end)
	m.next:SetPoint("TOP", m, "TOPLEFT", cx, -60 - 256 * ck - 20)
	m.daily = Button(m, "Ride today's route", bw, bh, function() G:FromScreen("daily") end)
	m.daily:SetPoint("TOP", m.next, "BOTTOM", 0, -8)
	m.board = Button(m, "Leaderboard", bw, bh, function() Sc:Board() end)
	m.board:SetPoint("TOP", m.daily, "BOTTOM", 0, -8)
	m.stats = Text(m, BODY, 11, { 0.82, 0.77, 0.64 })
	m.stats:SetPoint("TOP", m.board, "BOTTOM", 0, -12)
	m.hint = Text(m, BODY, 11, { 0.62, 0.58, 0.48 })
	m.hint:SetPoint("BOTTOM", m, "BOTTOMLEFT", cx, 14)
	m.hint:SetText("Space rides the next street      Esc closes")
	m.room = bw
	m:Hide()
	frames.menu = m
	return m
end

function Sc:FillMenu()
	local m = frames.menu
	local Dy = P.Daily
	local date, day = Dy:Today()
	local zone = Dy:Zone(day)
	local region, street = Names(zone)
	Fit(m.date, ShortDate(day), m.date.room, 10)
	Fit(m.route, region, m.route.room, 10)
	Fit(m.street, street, m.route.room, 8)
	local rec = Dy:Record(date)
	if rec and rec.best then
		Fit(m.best, "Your best " .. num(rec.best), m.best.room, 9)
		local rank = P.Leaderboard:Rank(P.Leaderboard:DailyId(date))
		local n = #P.Leaderboard:Board(P.Leaderboard:DailyId(date))
		m.best2:SetText(rank and ("%s of %d on the board"):format(Ordinal(rank), n) or (("ridden %d time%s"):format(rec.runs or 1, (rec.runs or 1) == 1 and "" or "s")))
	else
		Fit(m.best, "Not ridden yet", m.best.room, 9)
		m.best2:SetText("the same street for everyone")
	end
	local nz = G:PeekZone()
	m.next:SetLabel("Next street: " .. (Names(nz)))
	local c = P.char or {}
	local have, all = P.Rewards:Count()
	m.stats:SetText(("Best %s      Rides %d      Daily routes %d      Trophies %d / %d"):format(c.best and num(c.best) or "-", c.rides or 0, c.dailyDays or 0, have, all))
end

-- ------------------------------------------------------------------ the front page
local PAGE = 580
local PK = PAGE / 1024
local WELL = {
	headline = { 64, 220, 896, 82 }, photo = { 64, 328, 896, 250 },
	column_1 = { 64, 606, 282, 284 }, column_2 = { 371, 606, 282, 284 }, column_3 = { 678, 606, 282, 284 },
	footer = { 64, 930, 896, 48 },
}
local function Well(name, inset)
	local w = WELL[name]
	inset = inset or 0
	return w[1] * PK + inset, -(w[2] * PK + inset), w[3] * PK - 2 * inset, w[4] * PK - 2 * inset
end

-- a column: a heading, a rule under it, then rows of label .. value
local ROWS = 9
local function Column(page, name, title)
	local x, y, w, h = Well(name, 6)
	local col = CreateFrame("Frame", nil, page)
	col:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
	col:SetSize(w, h)
	col.head = Text(col, SERIF, 15, INK)
	col.head:SetPoint("TOP", 0, -1)
	Fit(col.head, title, w, 10)
	local rule = col:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(INK[1], INK[2], INK[3], 0.75)
	rule:SetPoint("TOPLEFT", 4, -20) rule:SetPoint("TOPRIGHT", -4, -20)
	rule:SetHeight(1)
	local rule2 = col:CreateTexture(nil, "ARTWORK")
	rule2:SetColorTexture(INK[1], INK[2], INK[3], 0.4)
	rule2:SetPoint("TOPLEFT", 4, -22) rule2:SetPoint("TOPRIGHT", -4, -22)
	rule2:SetHeight(1)
	col.l, col.r = {}, {}
	for i = 1, ROWS do
		local l = Text(col, BODY, 10, INK)
		l:SetPoint("TOPLEFT", 4, -26 - (i - 1) * 14)
		l:SetJustifyH("LEFT")
		local r = Text(col, BODY, 10, INK)
		r:SetPoint("TOPRIGHT", -4, -26 - (i - 1) * 14)
		r:SetJustifyH("RIGHT")
		col.l[i], col.r[i] = l, r
	end
	col.w = w - 8
	return col
end

local function Row(col, i, label, value, color)
	if i > ROWS then return end
	local l, r = col.l[i], col.r[i]
	color = color or INK
	l:SetTextColor(color[1], color[2], color[3])
	r:SetTextColor(color[1], color[2], color[3])
	r:SetText(value or "")
	Fit(l, label or "", col.w - r:GetStringWidth() - 6, 8)
end

local function ClearRows(col)
	for i = 1, ROWS do col.l[i]:SetText("") col.r[i]:SetText("") end
end

local MAP_N = 40              -- house icons in the subscriber map (a street has about 24)
local function BuildFront()
	local St = P.Stage
	Veil()
	local f = CreateFrame("Frame", nil, G.W)
	f:SetSize(PAGE, PAGE)
	f:SetPoint("LEFT", St.frame, "LEFT", 18, 0)
	f:SetFrameLevel(St.frame:GetFrameLevel() + 9805)
	f:EnableMouse(true)
	local page = f:CreateTexture(nil, "BACKGROUND")
	page:SetAllPoints()
	page:SetTexture(TEX .. "FrontPage")
	-- a shadow under the paper
	local sh = f:CreateTexture(nil, "BACKGROUND", nil, -1)
	sh:SetPoint("TOPLEFT", 6, -6) sh:SetPoint("BOTTOMRIGHT", 6, -6)
	sh:SetColorTexture(0, 0, 0, 0.45)
	-- headline
	local x, y, w, h = Well("headline", 4)
	f.headline = Text(f, SERIF, 30, INK)
	f.headline:SetPoint("CENTER", f, "TOPLEFT", x + w / 2, y - h / 2 + 1)
	f.headline.room = w
	-- the photograph: the street, and the trike as the round ended
	x, y, w, h = Well("photo", 3)
	local ph = CreateFrame("Frame", nil, f)
	ph:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
	ph:SetSize(w, h)
	f.photo = ph:CreateTexture(nil, "ARTWORK")
	f.photo:SetAllPoints()
	-- (the photo is 4:1, the well about 3.6:1: its ends are trimmed)
	local trim = (1 - (w / h) / 4) / 2
	f.photo:SetTexCoord(trim, 1 - trim, 0, 1)
	f.photoTrim = trim
	f.actor = ph:CreateTexture(nil, "ARTWORK", nil, 1)
	f.trike = ph:CreateTexture(nil, "ARTWORK", nil, 2)
	for _, t in ipairs({ f.actor, f.trike }) do
		if t.SetDesaturated then t:SetDesaturated(true) end
		t:SetVertexColor(1, 0.86, 0.64)
	end
	local cap = ph:CreateTexture(nil, "OVERLAY")
	cap:SetPoint("BOTTOMLEFT") cap:SetPoint("BOTTOMRIGHT")
	cap:SetHeight(15)
	cap:SetColorTexture(0.89, 0.85, 0.72, 0.92)
	f.caption = Text(ph, BODY, 9, INK)
	f.caption:SetPoint("BOTTOMLEFT", 5, 3)
	f.caption:SetJustifyH("LEFT")
	f.photoW, f.photoH = w, h
	-- the columns
	f.c1 = Column(f, "column_1", "THE ROUND")
	f.c2 = Column(f, "column_2", "SUBSCRIBERS")
	f.c3 = Column(f, "column_3", "THE BONUS TRACK")
	-- the subscriber map: one house per house on the street, in the order the trike met them
	local c2 = f.c2
	f.map = {}
	local per = 7
	local size = floor((c2.w) / per) - 1
	for i = 1, MAP_N do
		local t = c2:CreateTexture(nil, "ARTWORK")
		t:SetSize(size, size)
		local col, row = (i - 1) % per, floor((i - 1) / per)
		t:SetPoint("TOPLEFT", c2, "TOPLEFT", 4 + col * (size + 1), -44 - row * (size + 1))
		t:Hide()
		f.map[i] = t
	end
	f.mapSize = size
	f.legend = Text(c2, BODY, 9, INK_SOFT)
	f.legend:SetJustifyH("LEFT")
	f.legend:SetWidth(c2.w)
	f.legend:SetWordWrap(true)
	-- the footer
	x, y, w, h = Well("footer", 6)
	f.footL = Text(f, BODY, 10, INK)
	f.footL:SetPoint("LEFT", f, "TOPLEFT", x, y - h / 2)
	f.footL:SetJustifyH("LEFT")
	f.footC = Text(f, SERIF, 12, INK)
	f.footC:SetPoint("CENTER", f, "TOPLEFT", x + w / 2, y - h / 2)
	f.footR = Text(f, BODY, 10, INK)
	f.footR:SetPoint("RIGHT", f, "TOPLEFT", x + w, y - h / 2)
	f.footR:SetJustifyH("RIGHT")
	f.footW = w
	-- beside the paper: the score and what to do next
	local side = CreateFrame("Frame", nil, G.W)
	side:SetPoint("TOPLEFT", f, "TOPRIGHT", 14, 0)
	side:SetPoint("BOTTOMRIGHT", St.frame, "BOTTOMRIGHT", -14, 0)
	side:SetFrameLevel(St.frame:GetFrameLevel() + 9805)
	local sw = St.frame:GetWidth() - PAGE - 18 - 14 - 14
	side.medal = side:CreateTexture(nil, "ARTWORK")
	side.medal:SetSize(84, 84)
	side.medal:SetPoint("TOP", 0, -54)            -- (below the window's row of square buttons)
	-- the medal's name under it (the bronze is brass-coloured: easily taken for the gold at a glance)
	side.medalName = Text(side, SERIF, 14, CREAM)
	side.medalName:SetPoint("TOP", side.medal, "BOTTOM", 0, -1)
	side.title = Text(side, SERIF, 20, GOLD)
	side.title:SetPoint("TOP", side.medalName, "BOTTOM", 0, -6)
	side.score = Text(side, SERIF, 34, CREAM)
	side.score:SetPoint("TOP", side.title, "BOTTOM", 0, -6)
	side.note = Text(side, BODY, 12, { 0.85, 0.8, 0.66 })
	side.note:SetPoint("TOP", side.score, "BOTTOM", 0, -6)
	side.note:SetWidth(sw - 10)
	local bw = min(300, sw)
	side.again = Button(side, "Next street", bw, 54, function() G:FromScreen("again") end)
	side.again:SetPoint("TOP", side.note, "BOTTOM", 0, -18)
	side.board = Button(side, "Leaderboard", bw, 54, function() Sc:Board() end)
	side.board:SetPoint("TOP", side.again, "BOTTOM", 0, -6)
	side.menu = Button(side, "Press office", bw, 54, function() Sc:Menu() end)
	side.menu:SetPoint("TOP", side.board, "BOTTOM", 0, -6)
	side.hint = Text(side, BODY, 11, { 0.62, 0.58, 0.48 })
	side.hint:SetPoint("TOP", side.menu, "BOTTOM", 0, -10)
	side.room = sw
	f.side = side
	f:SetScript("OnHide", function() side:Hide() end)
	f:SetScript("OnShow", function() side:Show() end)
	f:Hide()
	frames.front = f
	return f
end

-- info: { zone, seed, daily (date) or nil, score, best, newBest, dailyBest, out, downKind, stats (street),
--         bonus (stats) or nil, houses, subs, lost, windows, airHits, edition, rank, rankOf, board }
function Sc:FillFront(info)
	local f = frames.front
	local region, street = Names(info.zone)
	Fit(f.headline, Headline(info), f.headline.room, 14)
	-- the photo: the street, the trike as it ended (and the kobold that caught it)
	f.photo:SetTexture(TEX .. "Photo_" .. info.zone)
	local pose, actor = "trike_throw_left_03", nil
	if info.out and info.downKind == "caught" then pose, actor = "trike_caught_08", info.zone .. "_chaser_grab_06"
	elseif info.out and info.downKind == "splash" then pose = info.zone == "durotar" and "trike_splash_mud_08" or "trike_splash_08"
	elseif info.out then pose = "trike_crash_10"
	elseif info.airHits > 0 then pose = "trike_jump_03" end
	-- where the road is in the photo (gg_build_paper.py: the stage band 0..952 x 10..248; the trike's lane
	-- at stage (794, 230)), and the drawn sprite at the photo's scale, a little nearer the camera
	local ph = f.photoW / ((1 - 2 * f.photoTrim) * 952)
	local tx = (794 / 952 - f.photoTrim) / (1 - 2 * f.photoTrim) * f.photoW
	local ty = (230 - 10) / 238 * f.photoH
	local s = ph * 1.35
	local tw, th = A:Sprite(f.trike, pose)
	f.trike:SetSize(tw * s, th * s)
	local an = A:Anim("trike_ride")
	f.trike:ClearAllPoints()
	f.trike:SetPoint("TOPLEFT", f.trike:GetParent(), "TOPLEFT", tx - an.px * s, -(ty - an.py * s))
	if actor and A:Has(actor) then
		local aw, ah = A:Sprite(f.actor, actor)
		f.actor:SetSize(aw * s, ah * s)
		f.actor:ClearAllPoints()
		f.actor:SetPoint("TOPLEFT", f.actor:GetParent(), "TOPLEFT", tx - aw * s * 0.5 - 26 * s, -(ty - ah * s * 0.86 - 6 * s))
		f.actor:Show()
	else
		f.actor:Hide()
	end
	local what = info.out and (info.downKind == "caught" and "in a kobold's grip" or info.downKind == "splash" and "after a dunking" or "after the crash")
		or (info.airHits > 0 and "in the air at the Bonus Track") or "at work"
	Fit(f.caption, ("Fizzwick %s: %s, %s."):format(what, street, region), f.photoW - 10, 7)
	-- column 1: the round
	local s1, c1 = info.stats, f.c1
	ClearRows(c1)
	local i = 0
	local function R(col, l, v, c) i = i + 1 Row(col, i, l, v, c) end
	R(c1, "Score", num(info.score))
	if info.newBest then R(c1, "A new best!", "", { 0.45, 0.12, 0.05 })
	else R(c1, "Best", num(max(info.best or 0, info.score))) end
	R(c1, "In mailboxes", tostring(s1.mail))
	R(c1, "On doorsteps", tostring(s1.door))
	R(c1, "Windows broken", tostring(s1.windows))
	R(c1, "Mailboxes smashed", tostring(s1.smashed))
	R(c1, "Papers thrown", tostring(s1.thrown + (info.bonus and info.bonus.thrown or 0)))
	if s1.penalty > 0 then R(c1, "Damage to subscribers", "-" .. num(s1.penalty), { 0.5, 0.1, 0.05 }) end
	R(c1, "Subscribers kept", "+" .. num(s1.bonus))
	-- column 2: the map
	local c2 = f.c2
	ClearRows(c2)
	i = 0
	R(c2, ("Kept %d of %d"):format(info.subs - info.lost, info.subs), "")
	local hs = info.houses
	for k = 1, MAP_N do
		local t, h = f.map[k], hs[k]
		if h then
			A:Sprite(t, not h.sub and "map_house_other" or h.lost and "map_house_lost" or "map_house_subscriber")
			t:SetAlpha(h.sub and 1 or 0.7)
			t:Show()
		else
			t:Hide()
		end
	end
	local rows = math.ceil(min(#hs, MAP_N) / 7)
	f.legend:ClearAllPoints()
	f.legend:SetPoint("TOPLEFT", c2, "TOPLEFT", 4, -44 - rows * (f.mapSize + 1) - 4)
	f.legend:SetText("Lit: kept.  Dark: lost.  Plain: not a subscriber.")
	-- column 3: the Bonus Track and the standings
	local c3 = f.c3
	ClearRows(c3)
	i = 0
	local b = info.bonus
	if b then
		R(c3, "Targets", tostring(b.targets))
		R(c3, "Dummies", tostring(b.dummies))
		R(c3, "Jumps", tostring(b.jumps))
		R(c3, "Hit in the air", tostring(b.airHits))
		R(c3, "Course", "+" .. num(b.course))
	else
		R(c3, "Out of trikes on the", "")
		R(c3, "street: no Bonus Track.", "")
	end
	local mname = (info.medal or 0) > 0 and (P.Rewards.MEDALS[info.medal]:gsub("^%l", string.upper)) or "None"
	R(c3, "Medal", ("%s (%d%%)"):format(mname, info.potential and info.potential > 0 and floor(100 * info.score / info.potential) or 0),
		(info.medal or 0) > 0 and { 0.45, 0.30, 0.05 } or INK)
	R(c3, "STANDINGS", "", INK)
	if info.daily then
		R(c3, "Today's route", info.rank and (Ordinal(info.rank) .. " of " .. info.rankOf) or "-")
		R(c3, "Your best today", num(info.dailyBestScore or info.score))
	else
		R(c3, "Best ever board", info.rank and (Ordinal(info.rank) .. " of " .. info.rankOf) or "-")
	end
	-- footer
	Fit(f.footL, LongDate(info.day), f.footW * 0.36, 7)
	f.footC:SetText(info.daily and "THE DAILY EDITION" or ("EDITION No. %d"):format(info.edition or 1))
	Fit(f.footR, "Delivered by " .. (info.who or "you"), f.footW * 0.36, 7)
	-- beside the paper
	local side = f.side
	local medal = info.medal or 0
	A:Sprite(side.medal, medal > 0 and ("medal_" .. P.Rewards.MEDALS[medal] .. "_earned") or "medal_bronze_not_earned")
	side.medal:SetAlpha(medal > 0 and 1 or 0.9)
	local MEDAL_TEXT = { { "Bronze medal", 0.86, 0.58, 0.36 }, { "Silver medal", 0.86, 0.88, 0.92 }, { "Gold medal", 1, 0.84, 0.30 } }
	local mt = MEDAL_TEXT[medal]
	if mt then
		side.medalName:SetText(mt[1])
		side.medalName:SetTextColor(mt[2], mt[3], mt[4])
	else
		side.medalName:SetText("No medal this time")
		side.medalName:SetTextColor(0.7, 0.66, 0.56)
	end
	Fit(side.title, info.out and "Out of trikes" or (info.newBest and "A new best!") or (info.dailyBest and "Today's best!") or "The round is done", side.room, 12)
	Fit(side.score, num(info.score), side.room, 16)
	local where = ("%s, %s"):format(street:gsub("^%l", string.upper), region)
	side.note:SetText(info.daily and ("Today's route: " .. where) or where)
	side.again:SetLabel(info.daily and "Ride it again" or ("Next street: " .. (Names(G:PeekZone()))))
	side.hint:SetText(info.daily and "Space rides it again      Esc closes" or "Space rides the next street      Esc closes")
end

-- ------------------------------------------------------------------ the leaderboard
local BOARD_ROWS = 10
local function BuildBoard()
	local St = P.Stage
	local b = CreateFrame("Frame", nil, G.W)
	b:SetAllPoints(St.frame)
	b:SetFrameLevel(St.frame:GetFrameLevel() + 9810)
	b:EnableMouse(true)
	local dim = b:CreateTexture(nil, "BACKGROUND")
	dim:SetAllPoints()
	dim:SetColorTexture(0.03, 0.025, 0.02, 0.6)
	local p = CreateFrame("Frame", nil, b)
	p:SetSize(600, 430)
	p:SetPoint("CENTER", 0, -14)
	Slice9(p, "BORDER", "paper_panel", 44)
	b.panel = p
	b.tabs = {}
	b.tabs.daily = Tab(b, "Today's route", 170, 40, function() Sc:Board("daily") end)
	b.tabs.daily:SetPoint("BOTTOMLEFT", p, "TOPLEFT", 40, -8)
	b.tabs.all = Tab(b, "Best ever", 170, 40, function() Sc:Board("all") end)
	b.tabs.all:SetPoint("LEFT", b.tabs.daily, "RIGHT", 4, 0)
	b.tabs.daily:SetFrameLevel(b:GetFrameLevel() + 5)
	b.tabs.all:SetFrameLevel(b:GetFrameLevel() + 5)
	b.title = Text(p, SERIF, 22, INK)
	b.title:SetPoint("TOP", 0, -34)
	b.sub = Text(p, BODY, 11, INK_SOFT)
	b.sub:SetPoint("TOP", b.title, "BOTTOM", 0, -2)
	-- columns: place, rider, route (best ever), score
	local X = { 52, 92, 352, 548 }
	local function Head(x, text, just)
		local fs = Text(p, BODY, 11, INK_SOFT)
		fs:SetPoint(just == "RIGHT" and "TOPRIGHT" or "TOPLEFT", p, "TOPLEFT", x, -86)
		fs:SetText(text)
		return fs
	end
	Head(X[1], "#") Head(X[2], "Rider") b.headRoute = Head(X[3], "Route") Head(X[4], "Score", "RIGHT")
	local rule = p:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(INK[1], INK[2], INK[3], 0.6)
	rule:SetPoint("TOPLEFT", X[1] - 4, -101) rule:SetPoint("TOPRIGHT", -(600 - X[4]) + 4, -101)
	rule:SetHeight(1)
	b.rows = {}
	for i = 1, BOARD_ROWS + 1 do
		local y = -108 - (i - 1) * 24
		if i == BOARD_ROWS + 1 then y = y - 6 end
		local row = {}
		row.hl = p:CreateTexture(nil, "ARTWORK")
		row.hl:SetColorTexture(0.55, 0.42, 0.15, 0.22)
		row.hl:SetPoint("TOPLEFT", p, "TOPLEFT", X[1] - 6, y + 3)
		row.hl:SetSize(X[4] - X[1] + 12, 22)
		row.n = Text(p, SERIF, 14, INK) row.n:SetPoint("TOPLEFT", X[1], y)
		row.who = Text(p, BODY, 12, INK) row.who:SetPoint("TOPLEFT", X[2], y + 1) row.who:SetJustifyH("LEFT")
		row.route = Text(p, BODY, 11, INK_SOFT) row.route:SetPoint("TOPLEFT", X[3], y + 1) row.route:SetJustifyH("LEFT")
		row.s = Text(p, SERIF, 14, INK) row.s:SetPoint("TOPRIGHT", p, "TOPLEFT", X[4], y)
		b.rows[i] = row
	end
	b.whoRoom = X[3] - X[2] - 10
	b.empty = Text(p, BODY, 12, INK_SOFT)
	b.empty:SetPoint("TOP", 0, -150)
	b.empty:SetWidth(460)
	b.status = Text(p, BODY, 10, INK_SOFT)
	b.status:SetPoint("BOTTOM", 0, 36)
	b.status:SetWidth(540)
	b.back = Button(b, "Back", 200, 52, function() Sc:Back() end)
	b.back:SetPoint("TOP", p, "BOTTOM", 0, 6)
	b.back:SetFrameLevel(b:GetFrameLevel() + 5)
	b:Hide()
	frames.board = b
	return b
end

function Sc:FillBoard()
	local b = frames.board
	local LB, Dy = P.Leaderboard, P.Daily
	local tab = self.tab or "daily"
	b.tabs.daily:SetActive(tab == "daily")
	b.tabs.all:SetActive(tab == "all")
	local date, day = Dy:Today()
	local id, list
	if tab == "daily" then
		id = LB:DailyId(date)
		local region, street = Names(Dy:Zone(day))
		b.title:SetText("Today's Route")
		b.sub:SetText(("%s: %s, %s. The same street for every rider."):format(LongDate(day), street, region))
		b.headRoute:SetText("")
	else
		id = LB.ALL
		b.title:SetText("Best Ever")
		b.sub:SetText("The best rounds on any street, each checked by riding it again.")
		b.headRoute:SetText("Route")
	end
	list = LB:Board(id)
	local mine = LB:Rank(id)
	for i = 1, BOARD_ROWS do
		local row, e = b.rows[i], list[i]
		if e then
			row.n:SetText(tostring(i))
			Fit(row.who, e.who .. (e.g and "" or ""), b.whoRoom, 9)
			row.route:SetText(tab == "all" and e.z and (Names(e.z)) or "")
			row.s:SetText(num(e.s))
			row.hl:SetShown(e.u == P.guid)
		else
			row.n:SetText("") row.who:SetText("") row.route:SetText("") row.s:SetText("")
			row.hl:Hide()
		end
	end
	-- this player's own best when it's not in the top ten (it is kept even so: their own record)
	local last = b.rows[BOARD_ROWS + 1]
	last.n:SetText("") last.who:SetText("") last.route:SetText("") last.s:SetText("") last.hl:Hide()
	if not mine then
		local own
		if tab == "daily" then
			local rec = Dy:Record(date)
			own = rec and rec.best
		else
			own = P.char and P.char.top and P.char.top.s
		end
		if own then
			last.who:SetText("You") last.s:SetText(num(own)) last.hl:Show()
			last.n:SetText("-")
		end
	end
	if #list == 0 then
		b.empty:SetText(tab == "daily" and "No one has ridden today's route yet. Be the first!" or "No rounds on the board yet. Ride a street!")
		b.empty:Show()
	else
		b.empty:Hide()
	end
	local pend = LB:Pending()
	if not LB:Enabled() then
		b.status:SetText("Sharing is off (Options): only your own rounds are shown.")
	elseif pend > 0 then
		b.status:SetText(("Checking %d round%s from other riders..."):format(pend, pend == 1 and "" or "s"))
	else
		b.status:SetText("Shared with your guild and the Nether games channel. Every score is checked by riding it again.")
	end
end

-- ------------------------------------------------------------------ the trophy shelf
local function BuildTrophies()
	local St = P.Stage
	local Rw = P.Rewards
	local t = CreateFrame("Frame", nil, G.W)
	t:SetAllPoints(St.frame)
	t:SetFrameLevel(St.frame:GetFrameLevel() + 9810)
	t:EnableMouse(true)
	local dim = t:CreateTexture(nil, "BACKGROUND")
	dim:SetAllPoints()
	dim:SetColorTexture(0.03, 0.025, 0.02, 0.6)
	local p = CreateFrame("Frame", nil, t)
	p:SetSize(600, 444)
	p:SetPoint("CENTER", 0, 10)
	Slice9(p, "BORDER", "paper_panel", 44)
	t.title = Text(p, SERIF, 22, INK)
	t.title:SetPoint("TOP", 0, -30)
	t.title:SetText("The Trophy Shelf")
	t.sub = Text(p, BODY, 11, INK_SOFT)
	t.sub:SetPoint("TOP", t.title, "BOTTOM", 0, -2)
	-- twelve badges, six to a row: the ring, the pictogram in it, its name, how far along
	local CW, X0 = 84, (600 - 6 * 84) / 2
	t.cells = {}
	for i, a in ipairs(Rw.LIST) do
		local col, row = (i - 1) % 6, floor((i - 1) / 6)
		local c = CreateFrame("Frame", nil, p)
		c:SetSize(CW, 108)
		c:SetPoint("TOPLEFT", X0 + col * CW, -78 - row * 112)
		c:EnableMouse(true)
		c.ring = c:CreateTexture(nil, "ARTWORK")
		c.ring:SetSize(62, 62)
		c.ring:SetPoint("TOP", 0, 0)
		c.icon = c:CreateTexture(nil, "ARTWORK", nil, 1)
		c.icon:SetSize(46, 46)
		c.icon:SetPoint("CENTER", c.ring, "CENTER", 0, 1)
		A:Sprite(c.icon, "ach_" .. a.id)
		c.name = Text(c, BODY, 10, INK)
		c.name:SetPoint("TOP", c.ring, "BOTTOM", 0, -3)
		Fit(c.name, a.name, CW - 4, 7)
		c.prog = Text(c, BODY, 9, INK_SOFT)
		c.prog:SetPoint("TOP", c.name, "BOTTOM", 0, -2)
		c.a = a
		c:SetScript("OnEnter", function(self)
			if not GameTooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.a.name, 1, 0.84, 0.42)
			GameTooltip:AddLine(self.a.text, 1, 1, 1, true)
			if self.tip then GameTooltip:AddLine(self.tip, 0.7, 0.9, 0.6, true) end
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
		t.cells[i] = c
	end
	-- each route's best medal
	t.mhead = Text(p, SERIF, 15, INK)
	t.mhead:SetPoint("TOP", 0, -312)
	t.mhead:SetText("Best medal on each route")
	local rule = p:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(INK[1], INK[2], INK[3], 0.5)
	rule:SetPoint("TOP", 0, -332)
	rule:SetSize(440, 1)
	t.medals = {}
	local MW = 100
	local MX = (600 - #Rt.ZONES * MW) / 2
	for i, z in ipairs(Rt.ZONES) do
		local m = {}
		m.tex = p:CreateTexture(nil, "ARTWORK")
		m.tex:SetSize(50, 50)
		m.tex:SetPoint("TOP", p, "TOPLEFT", MX + (i - 0.5) * MW, -338)
		m.name = Text(p, BODY, 10, INK)
		m.name:SetPoint("TOP", m.tex, "BOTTOM", 0, -1)
		Fit(m.name, (Names(z.id)), MW - 6, 7)
		m.zone = z.id
		t.medals[i] = m
	end
	t.back = Button(t, "Back", 200, 52, function() Sc:Back() end)
	t.back:SetPoint("TOP", p, "BOTTOM", 0, 6)
	t.back:SetFrameLevel(t:GetFrameLevel() + 5)
	t:Hide()
	frames.trophies = t
	return t
end

function Sc:FillTrophies()
	local t, Rw = frames.trophies, P.Rewards
	local have, all = Rw:Count()
	t.sub:SetText(("%d of %d earned. Hover over a badge to see what it takes."):format(have, all))
	local c = P.char or {}
	for _, cell in ipairs(t.cells) do
		local a = cell.a
		local got = Rw:Has(a.id)
		A:Sprite(cell.ring, got and "badge_frame_earned" or "badge_frame_locked")
		if cell.icon.SetDesaturated then cell.icon:SetDesaturated(not got) end
		cell.icon:SetAlpha(got and 1 or 0.45)
		cell.name:SetTextColor(got and INK[1] or INK_SOFT[1], got and INK[2] or INK_SOFT[2], got and INK[3] or INK_SOFT[3])
		local cur, goal = Rw:Progress(a.id)
		if got then
			local at = type(c.ach) == "table" and c.ach[a.id]
			local day = type(at) == "number" and at > 0 and floor(at / 86400)
			cell.prog:SetText("Earned")
			cell.tip = day and ("Earned " .. LongDate(day) .. ".") or "Earned."
		elseif goal then
			cell.prog:SetText(("%s / %s"):format(num(cur), num(goal)))
			cell.tip = nil
		else
			cell.prog:SetText("")
			cell.tip = nil
		end
	end
	for _, m in ipairs(t.medals) do
		local md = Rw:Medal(m.zone)
		A:Sprite(m.tex, md > 0 and ("medal_" .. Rw.MEDALS[md] .. "_earned") or "medal_bronze_not_earned")
		m.tex:SetAlpha(md > 0 and 1 or 0.5)
	end
end

-- ------------------------------------------------------------------ toasts
-- one at a time, each about three seconds, at the top of the street; they never take the keyboard or mouse
local toastQ, toastN = {}, 0
local TOAST_SHOW, TOAST_FADE = 3.2, 0.5
local function BuildToast()
	local St = P.Stage
	local f = CreateFrame("Frame", nil, G.top or G.W)
	f:SetSize(330, 82)
	f:SetPoint("BOTTOMRIGHT", St.frame, "BOTTOMRIGHT", -16, 42)  -- (above the controls strip, clear of the HUD, the masthead and the medal)
	f:SetFrameLevel((G.top or G.W):GetFrameLevel() + 60)
	f.art = Slice3(f, "ARTWORK", "toast", 82)
	f.ring = f:CreateTexture(nil, "OVERLAY")
	f.ring:SetSize(56, 56)
	f.ring:SetPoint("CENTER", f, "LEFT", 41, 0)
	A:Sprite(f.ring, "badge_frame_earned")
	f.icon = f:CreateTexture(nil, "OVERLAY", nil, 1)
	f.icon:SetSize(42, 42)
	f.icon:SetPoint("CENTER", f.ring, "CENTER", 0, 1)
	f.title = Text(f, BODY, 11, INK_SOFT)
	f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 90, -17)
	f.title:SetJustifyH("LEFT")
	f.title:SetText("Trophy earned")
	f.name = Text(f, SERIF, 17, INK)
	f.name:SetPoint("TOPLEFT", f, "TOPLEFT", 90, -34)
	f.name:SetJustifyH("LEFT")
	f.room = 330 - 90 - 40
	f:Hide()
	f:SetScript("OnUpdate", function(self, el)
		self.t = self.t + el
		-- (a queue of them goes by quicker)
		local show = toastN > 0 and math.max(1.4, TOAST_SHOW - 0.5 * toastN) or TOAST_SHOW
		if self.t > show then
			local a = 1 - (self.t - show) / TOAST_FADE
			if a <= 0 then
				self:Hide()
				Sc:NextToast()
				return
			end
			self:SetAlpha(a)
		end
	end)
	frames.toast = f
	return f
end

function Sc:NextToast()
	if toastN == 0 then return end
	local id = table.remove(toastQ, 1)
	toastN = toastN - 1
	local a = P.Rewards.BY[id]
	if not a then return self:NextToast() end
	local f = frames.toast or BuildToast()
	A:Sprite(f.icon, "ach_" .. id)
	Fit(f.name, a.name, f.room, 11)
	f.t = 0
	f:SetAlpha(1)
	f:Show()
	Au:Play("ui_achievement")
end

function Sc:ClearToasts()
	wipe(toastQ)
	toastN = 0
	if frames.toast then frames.toast:Hide() end
end

function Sc:Toast(id)
	if not G.W then return end
	toastQ[#toastQ + 1] = id
	toastN = toastN + 1
	local f = frames.toast
	if not (f and f:IsShown()) then self:NextToast() end
end
P:Register("ACHIEVEMENT", function(id) Sc:Toast(id) end)

-- ------------------------------------------------------------------ showing them
local function HideAll()
	for k, f in pairs(frames) do if k ~= "veil" and k ~= "toast" then f:Hide() end end
	if frames.veil then frames.veil:Hide() end
end

function Sc:Menu()
	if not frames.menu then BuildMenu() end
	HideAll()
	self.back = nil
	self:FillMenu()
	frames.menu:Show()
	showing = "menu"
	G:ScreenShown("menu")
end

function Sc:Front(info)
	if not frames.front then BuildFront() end
	HideAll()
	self.info = info or self.info
	self:FillFront(self.info)
	frames.veil:Show()
	frames.front:Show()
	showing = "front"
	G:ScreenShown("front")
end

-- the board and the trophy shelf sit over whatever they were opened from (the press office, the front page,
-- or a paused ride) and go back to it
local function Overlay(which)
	if showing ~= "board" and showing ~= "trophies" then Sc.back = showing end
	if frames.board and which ~= "board" then frames.board:Hide() end
	if frames.trophies and which ~= "trophies" then frames.trophies:Hide() end
	showing = which
	G:ScreenShown(which)
end

function Sc:Board(tab)
	if not frames.board then BuildBoard() end
	if tab then self.tab = tab elseif not self.tab then self.tab = "daily" end
	Overlay("board")
	frames.board:Show()
	self:FillBoard()
end

function Sc:Trophies()
	if not frames.trophies then BuildTrophies() end
	Overlay("trophies")
	frames.trophies:Show()
	self:FillTrophies()
	Au:Play("ui_menu_open")
end

function Sc:Back()
	if frames.board then frames.board:Hide() end
	if frames.trophies then frames.trophies:Hide() end
	if self.back == "front" and frames.front and frames.front:IsShown() then showing = "front" G:ScreenShown("front")
	elseif self.back == "front" then self:Front()
	elseif self.back == "menu" or not G.ride then self:Menu()
	else
		-- opened over the ride: back to it, paused
		showing = nil
		G:ScreenShown(nil)
		G:Pause(true)
	end
end

function Sc:Hide()
	HideAll()
	showing = nil
end

function Sc:Showing() return showing end

-- the board fills in as checked rounds arrive (and its "checking" line counts down)
P:Register("LEADERBOARD_CHECKED", function()
	if showing == "board" and frames.board and frames.board:IsShown() then Sc:FillBoard() end
end)
P:Register("LEADERBOARD_CHANGED", function()
	if showing == "board" and frames.board and frames.board:IsShown() then Sc:FillBoard() end
	if showing == "menu" and frames.menu and frames.menu:IsShown() then Sc:FillMenu() end
end)

-- Space and Esc on the screens
function Sc:Key(key)
	if not showing then return false end
	if key == "ESCAPE" then
		if showing == "board" or showing == "trophies" then self:Back() else G:Close() end
		return true
	end
	if key == "SPACE" then
		if showing == "menu" then G:FromScreen("next")
		elseif showing == "front" then G:FromScreen("again") end
		return true
	end
	return false               -- every other key goes on to the game (chat, movement, the rest)
end
