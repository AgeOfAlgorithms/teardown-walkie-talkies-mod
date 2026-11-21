-- Walkie: walkie-talkies on any map (PROJECT.md). Included by main.lua (no #version line; globals only).
-- Everyone has one in the wheel from the start and after every respawn (the host's option, options.lua; walkie.start =
-- 0: only from pickups). Anything tagged `walkie` (a body or one of its shapes: a map's, or the spawn menu's) is picked
-- up with E - our own aim and prompt, as Dive's pickups, since the engine offers no interact to a swimmer - and puts
-- the Walkie-talkie tool in the wheel (gone from the world unless tagged `remain`). A game mode that takes the tool
-- away takes it until a respawn.
-- The talking is Proximity Comms' (registry API, its PROJECT.md "Devices"): every carried walkie is a radio on its
-- team's channel, heard by everyone on that channel carrying one; in hand and switched on (RMB: off / on, on at first)
-- its holder's voice and typed lines go out on it. Without Proximity Comms the keys are written and nobody reads them:
-- the tool is there, it just carries nothing (the hint says so). Any mod (host):
--   walkie.give.<player> = 1 / 0      hands one out (in hand) / takes it for good (no more at respawns)
--   walkie.team.<player> = "<team>"   that player's walkie on the team's own channel ("" = the shared one); unset:
--                                     Proximity Comms' proxchat.team.<player> if a game sets it
--   walkie.start = 0                  nobody gets one by default (set it in your init), whatever the host's option
--
-- With the McPuppet Inventory System running (inventory.present; the user, 2026-11-21: "when inventory mod is on, it
-- should be available in the shop ... you cannot use the game's native hotkey inventory system"), the walkie-talkie is
-- one of ITS items: declared an Inventory tool (inventory.tools.walkietalkie: the store, hotkeys, dropped and picked up
-- as any item, lost at death as any item), and this script never touches the tool wheel (the Inventory owns it: a
-- write fight otherwise). A player carries one when the Inventory says so (inventory.count.<p>.walkietalkie; not while
-- inventory.block.<p>); it is a radio wherever it lies in their inventory and transmits in the hands (on a hotkey).
-- Handing out, pickups and walkie.give go through inventory.give / .take. The default one is given once, when a
-- player is first seen on the map with none (not again after a death: it lies where they died).

Walkie = {}

TOOL = "walkietalkie"
TOOL_NAME = "Walkie-talkie"
TOOL_GROUP = 4
CHANNEL = "walkie"    -- the shared channel; a team's is walkie-<team>
REACH = 3.5           -- m from the eye to a pickup you can take (a swimmer's eye is the upright capsule's)
PUBLISH_HZ = 10
INV_PRICE = 150       -- gold in the Inventory's store
INV_ICON = "images/walkietalkie.png"
INV_WAIT = 4.0        -- s from a player's first tick to the default walkie at the latest: their kept inventory comes
                      -- back first (sooner when the Inventory says so: inventory.ready.<p>, its releases after 1.4)
INV_BUSY = 1.0        -- s after a give during which no second one is asked for (the count follows the give)

----- shared helpers -----

-- an input this frame; walkie.test.<input> (bool) presses it for every player (autotests only, as Dive's dive.test.*)
function walkiePressed(name, p)
	return InputPressed(name, p) or GetBool("walkie.test." .. name)
end

-- the McPuppet Inventory System runs (its synced flag, set again every second)
function walkieInv()
	return GetBool("inventory.present")
end

-- the walkie-talkie as an Inventory tool, on every machine (the store, names, the icon); nobody reads it without
-- the Inventory
function walkieDeclare()
	local k = "inventory.tools." .. TOOL
	SetBool(k, true)
	SetInt(k .. ".price", INV_PRICE)
	SetString(k .. ".icon", INV_ICON)
	SetString(k .. ".tip", "Carried: you hear everyone with one|In your hands: they hear you (RMB: off / on)")
end

-- the pickup a player looks at: on the camera's ray (over the shoulder in third person) within REACH of the eye ->
-- body (0 if none)
function walkieInView(p)
	local cam = GetPlayerCameraTransform(p)
	local dir = TransformToParentVec(cam, Vec(0, 0, -1))
	local eye = GetPlayerEyeTransform(p).pos
	QueryRejectPlayer(p)
	QueryRequire("physical")
	local hit, dist, _, shape = QueryRaycast(cam.pos, dir, VecLength(VecSub(eye, cam.pos)) + REACH + 0.5)
	if not hit then return 0 end
	local b = GetShapeBody(shape)
	if b == 0 then return 0 end
	if VecLength(VecSub(VecAdd(cam.pos, VecScale(dir, dist)), eye)) > REACH then return 0 end
	if HasTag(b, "walkie") or HasTag(shape, "walkie") then return b end
	for _, sh in ipairs(GetBodyShapes(b)) do
		if HasTag(sh, "walkie") then return b end
	end
	return 0
end

local function tagged(b, tag)
	if HasTag(b, tag) then return true end
	for _, sh in ipairs(GetBodyShapes(b)) do
		if HasTag(sh, tag) then return true end
	end
	return false
end

----- server -----

function Walkie.serverInit()
	RegisterTool(TOOL, TOOL_NAME, "MOD/prefab/walkie.xml", TOOL_GROUP)
	walkieDeclare()
	carriers = {}          -- player -> {on = bool}
	devices = {}           -- proxchat.device.<name> -> the value we wrote
	txSet = {}             -- player -> the proxchat.tx.<p> we wrote ("" once cleared)
	seenAlive = {}         -- player -> alive last tick (nil: not seen yet; a start walkie is due)
	revoked = {}           -- player -> true: taken by walkie.give 0 (no start walkie again)
	invMode = false        -- the Inventory ran last tick
	invDue = {}            -- player -> the time their default walkie is decided (Inventory)
	invBusy = {}           -- player -> until when a give of ours is on its way (Inventory)
	invScreen = {}         -- player -> true: their inventory screen is open (their client says so)
	publishT = 0
	pickSnd = LoadSound("tool_pickup.ogg")
	shared.walkie = {n = 0}
end

-- a player's client: the Inventory's screen opened / closed (right-clicks in it are not the walkie's switch)
function server.walkieScreen(p, open)
	if type(p) == "number" and invScreen then invScreen[p] = open == true or nil end
end

local function give(p, hold)
	carriers[p] = {on = true}
	SetToolEnabled(TOOL, true, p)
	if hold then SetPlayerTool(TOOL, p) end
end

-- the host's option "Everyone starts with a walkie-talkie" (options.lua; on unless switched off), and a mode's veto
local function startOn()
	if HasKey("walkie.start") and GetInt("walkie.start") == 0 then return false end
	return not GetBool("savegame.mod.nostart")
end

-- the channel a player's walkie is on: walkie.team.<p>, else Proximity Comms' own proxchat.team.<p> (a game's teams for
-- its pings); its channels: lower case, no spaces, 24 at most
function walkieChannel(p)
	local key = HasKey("walkie.team." .. p) and "walkie.team." .. p or "proxchat.team." .. p
	local team = (GetString(key):lower():gsub("[^%w_%-]", ""))
	if team == "" then return CHANNEL end
	return CHANNEL .. "-" .. team:sub(1, 17)
end

local function take(p)
	carriers[p] = nil
	SetToolEnabled(TOOL, false, p)
end

local function setDevice(name, value, seen)
	seen[name] = true
	if devices[name] ~= value then
		devices[name] = value
		SetString("proxchat.device." .. name, value)
	end
end

local function invAppend(key, word)
	local cur = GetString(key)
	SetString(key, cur == "" and word or (cur .. " " .. word))
end

-- one from us into p's inventory (the Inventory puts it in the grid and on the first free hotkey)
local function invGive(p, t)
	invAppend("inventory.give." .. p, TOOL)
	invBusy[p] = t + INV_BUSY
end

-- who carries one, by our own wheel (no Inventory): gifts, the start walkie, a mode taking the tool -> the carrier
local function ownCarrier(p, alive)
	if HasKey("walkie.give." .. p) then                          -- another mod hands one out (1) or takes it (0)
		local n = GetInt("walkie.give." .. p)
		ClearKey("walkie.give." .. p)
		revoked[p] = n <= 0 or nil
		if n > 0 then give(p, true) else take(p) end
	end
	local c = carriers[p]
	if c and not IsToolEnabled(TOOL, p) then carriers[p], c = nil, nil end   -- (a game mode took it)
	-- one in the wheel (not in hand) at the start and after every respawn
	if alive and seenAlive[p] ~= true and not c and not revoked[p] and startOn() then
		give(p, false)
		c = carriers[p]
	end
	if not c and IsToolEnabled(TOOL, p) then SetToolEnabled(TOOL, false, p) end -- (only from us)
	return c
end

-- who carries one, by the Inventory: its count is the truth, gifts and takes go through its keys -> the carrier
local function invCarrier(p, alive, t)
	local has = GetInt("inventory.count." .. p .. "." .. TOOL) > 0 and not GetBool("inventory.block." .. p)
	local busy = (invBusy[p] or 0) > t
	if HasKey("walkie.give." .. p) then
		local n = GetInt("walkie.give." .. p)
		ClearKey("walkie.give." .. p)
		revoked[p] = n <= 0 or nil
		if n > 0 then
			if not has and not busy then invGive(p, t) end
		else
			invAppend("inventory.take." .. p, TOOL)
			invDue[p] = nil
		end
	end
	-- the default one: once, when the player's kept inventory is back (the Inventory session, 2026-11-21: a give that
	-- lands before it is merged with the kept items - two walkies; inventory.ready.<p> says when, an older Inventory
	-- has it back within a second or two), if they have none
	if seenAlive[p] == nil then invDue[p] = t + INV_WAIT end
	if invDue[p] and alive and (t >= invDue[p] or GetBool("inventory.ready." .. p)) then
		invDue[p] = nil
		if not has and not busy and not revoked[p] and startOn() and not GetBool("inventory.block." .. p) then invGive(p, t) end
	end
	if has then
		carriers[p] = carriers[p] or {on = true}
	else
		carriers[p] = nil
	end
	return carriers[p], busy
end

function Walkie.serverTick(dt)
	local t = GetTime()
	local seen, here = {}, {}
	local inv = walkieInv()
	if inv ~= invMode then                                          -- the Inventory came (or went): everyone starts afresh
		invMode = inv                                               -- under the other rule (what we enabled before it
		carriers, seenAlive, invDue, invBusy = {}, {}, {}, {}       -- showed up, the Inventory takes out of the wheel)
	end
	for _, p in ipairs(GetAllPlayers()) do
		here[p] = true
		local alive = GetPlayerHealth(p) > 0
		local c, busy
		if inv then c, busy = invCarrier(p, alive, t) else c = ownCarrier(p, alive) end
		seenAlive[p] = alive
		if alive and walkiePressed("interact", p) and not c and not busy and not (inv and GetBool("inventory.block." .. p)) then
			local b = walkieInView(p)
			if b ~= 0 then
				if inv then
					invGive(p, t)
				else
					give(p, true)
					c = carriers[p]
				end
				PlaySound(pickSnd, GetBodyTransform(b).pos, 1)
				if not tagged(b, "remain") then Delete(b) end
			end
		end
		local tx = ""
		if c and alive then
			local ch = walkieChannel(p)
			c.team = ch ~= CHANNEL
			setDevice("walkie" .. p, "radio channel=" .. ch .. " at=player:" .. p, seen)
			if GetPlayerTool(p) == TOOL then
				if walkiePressed("rmb", p) and not GetBool("proxchat.typing." .. p) and GetPlayerGrabBody(p) == 0 and not invScreen[p] then
					c.on = not c.on
					ClientCall(0, "client.walkieClick", p, c.on)
				end
				if c.on then tx = ch end
			end
		end
		-- proxchat.tx.<p> is one key per player that a game mode may write too: only ours to set while we talk, and
		-- cleared once when we stop
		if tx ~= "" or (txSet[p] or "") ~= "" then
			if txSet[p] ~= tx then SetString("proxchat.tx." .. p, tx) end
			txSet[p] = tx
		end
	end
	for p in pairs(seenAlive) do                                    -- (gone: a new player with this id starts afresh)
		if not here[p] then
			seenAlive[p], carriers[p], revoked[p], txSet[p] = nil, nil, nil, nil
			invDue[p], invBusy[p], invScreen[p] = nil, nil, nil
		end
	end
	for name in pairs(devices) do
		if not seen[name] then
			SetString("proxchat.device." .. name, "")
			devices[name] = nil
		end
	end
	if t - publishT >= 1 / PUBLISH_HZ then
		publishT = t
		local out = {n = shared.walkie.n + 1, team = {}}
		for p, c in pairs(carriers) do
			out[p] = c.on
			if c.team then out.team[p] = true end
		end
		shared.walkie = out
	end
end

function Walkie.serverDestroy()
	for name in pairs(devices or {}) do SetString("proxchat.device." .. name, "") end
	for p, v in pairs(txSet or {}) do if v ~= "" then SetString("proxchat.tx." .. p, "") end end
end

----- client -----

function Walkie.clientInit()
	walkieDeclare()
	anims = {}
	sentScreen = false
	clickSnd = LoadSound("clickup.ogg")
end

function client.walkieClick(p, on)
	if IsPlayerValid(p) then PlaySound(clickSnd, GetPlayerTransform(p).pos, 0.6, false, on and 1.15 or 0.85) end
end

function Walkie.clientTick(dt)
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerTool(p) == TOOL and GetPlayerHealth(p) > 0 then  -- in the hands: the game's toolanimation.lua (not
			anims[p] = anims[p] or ToolAnimator()                    -- for the dead: the corpse stayed standing)
			tickToolAnimator(anims[p], dt, nil, p)
		end
	end
	local open = GetBool("inventory.screenopen")                    -- (the Inventory's, local to this machine)
	if open ~= sentScreen then
		sentScreen = open
		ServerCall("server.walkieScreen", GetLocalPlayer(), open)
	end
end

local function line(y, text, a)
	UiPush()
		UiTranslate(UiCenter(), y)
		UiAlign("center middle")
		UiFont("bold.ttf", 22)
		UiColor(1, 1, 1, a or 0.9)
		UiText(text)
	UiPop()
end

function Walkie.clientDraw()
	local me = GetLocalPlayer()
	if GetPlayerHealth(me) <= 0 then return end
	local inv = walkieInv()
	if inv and (GetBool("inventory.screenopen") or GetBool("inventory.block." .. me)) then return end
	local w = shared.walkie or {}
	if w[me] == nil and walkieInView(me) ~= 0 then line(UiMiddle() + 90, "E: pick up " .. TOOL_NAME) end
	if GetPlayerTool(me) == TOOL and w[me] ~= nil then
		local y = UiHeight() - (inv and 200 or 140)                 -- (over the Inventory's hotbar)
		local who = (w.team or {})[me] and "your team" or "everyone with a walkie-talkie"
		line(y, w[me] and "WALKIE ON: " .. who .. " hears you   RMB: off"
			or "Walkie off   RMB: on (in your hand, it carries what you say)")
		if GetFloat("proxchat.alive") < GetTime() - 2 then line(y + 26, "(needs the Proximity Comms mod)", 0.6) end
	end
end
