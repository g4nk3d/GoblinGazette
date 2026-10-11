--[[ Goblin Gazette - Game/Drive.lua
	The ride's rules, ticked 30 times a second (no game API in here: a test can run them alone).

	  Dr:New(route)           -> ride { a, b, v, lean, phase, tick, ... }
	  Dr:Input(ride, key, down)   held controls: "up" (toward the houses), "down", "slow", "fast"
	  Dr:Release(ride)        every control let go
	  Dr:Tick(ride)           one fixed step
	  Dr.TPS

	The trike always rolls forward while riding (speeding up and slowing down never stop it), along the road
	toward the upper right. Up/down swerve across the road and sidewalk. phase: "ready" (waiting at the start),
	"ride", "done" (the end of the route). ]]

local _, ns = ...
local P = ns.P
local Dr = P:Module("Drive")

Dr.TPS = 30
local DT = 1 / Dr.TPS

Dr.SPEED = { slow = 2.6, cruise = 4.2, fast = 6.4 }   -- tiles a second
Dr.ACCEL = 4.0                                         -- tiles a second, per second
Dr.SWERVE = 3.4                                        -- tiles a second across the road
Dr.B_MIN, Dr.B_MAX = -2.7, 0.8                         -- the road's far edge .. the sidewalk's back edge

function Dr:New(route)
	local r = {
		route = route, phase = "ready", tick = 0,
		a = 2, b = -1.5, v = 0,
		pa = 2, pb = -1.5,          -- last tick's position (the stage blends between the two)
		lean = 0, leanT = 0,        -- -1 toward the far side, 1 toward the houses; ticks held
		up = false, down = false, slow = false, fast = false,
		farthest = 0,
	}
	P.Round:Setup(r)
	P.Hazards:Setup(r)
	return r
end

-- every change to the held controls is written into the ride's log (when it keeps one: Game/Replay.lua), at
-- the tick it takes effect before; a replay applies the same changes at the same ticks
local CODE = { up = 0, down = 2, slow = 4, fast = 6 }      -- +1 when let go
function Dr:Input(r, key, down)
	local c = CODE[key]
	if not c then return end
	down = down and true or false
	if r[key] == down then return end
	r[key] = down
	local log = r.log
	if log and r.phase ~= "done" then log[#log + 1] = r.tick * 16 + c + (down and 0 or 1) end
end

-- every control let go at once (a pause, the window closing, the keyboard released)
function Dr:Release(r)
	if not (r.up or r.down or r.slow or r.fast) then return end
	r.up, r.down, r.slow, r.fast = false, false, false, false
	local log = r.log
	if log and r.phase ~= "done" then log[#log + 1] = r.tick * 16 + 9 end
end
Dr.CODE = CODE

function Dr:Start(r)
	if r.phase == "ready" then
		r.phase = "ride"
		r.v = self.SPEED.slow
	end
end

function Dr:Tick(r)
	r.pa, r.pb = r.a, r.b
	if r.phase ~= "ride" then return end
	r.tick = r.tick + 1
	if r.fallen then
		-- down after a crash or a catch: nothing moves the trike until it is up again
		r.lean, r.leanT = 0, 0
		P.Round:Tick(r)
		P.Hazards:Tick(r)
		if r.out then
			r.phase = "done"
			P.Round:Finish(r)
		end
		return
	end
	local Bn = r.route.bonus and P.Bonus
	if Bn then Bn:Steer(r) end
	-- speed: the held control picks a target; the trike eases toward it and never stops
	local target = self.SPEED.cruise
	if r.fast and not r.slow then target = self.SPEED.fast
	elseif r.slow and not r.fast then target = self.SPEED.slow end
	if r.skid then target = self.SPEED.slow end
	local dv = self.ACCEL * DT
	if r.v < target then r.v = math.min(target, r.v + dv) elseif r.v > target then r.v = math.max(target, r.v - dv) end
	r.a = r.a + r.v * DT
	-- swerving
	local s = 0
	if r.up and not r.down then s = 1 elseif r.down and not r.up then s = -1 end
	local lo, hi = self.B_MIN, self.B_MAX
	if Bn then lo, hi = Bn:Edges(r.a) end
	if r.skid then s = 0 end                      -- (the skid slides the trike: Bonus:Tick)
	if s ~= 0 then
		local nb = r.b + s * self.SWERVE * DT
		if nb > hi then nb = hi elseif nb < lo then nb = lo end
		if nb == r.b then s = 0 end
		r.b = nb
	end
	-- the course closing in at an arch carries the trike with it
	if r.b < lo then r.b = math.min(hi, r.b + self.SWERVE * DT) elseif r.b > hi then r.b = math.max(lo, r.b - self.SWERVE * DT) end
	if r.skid then s = r.skidDir end
	if s ~= r.lean then r.lean, r.leanT = s, 0 else r.leanT = r.leanT + 1 end
	if r.a > r.farthest then r.farthest = r.a end
	P.Round:Tick(r)
	P.Hazards:Tick(r)
	if Bn then Bn:Tick(r) end
	if r.out then
		r.phase = "done"
		P.Round:Finish(r)
		return
	end
	local finish = Bn and (Bn.FINISH + 2) or (r.route.length - 4)
	if r.a >= finish then
		r.phase = "done"
		r.v = 0
		P.Round:Finish(r)
	end
end
