-- Walkie: walkie-talkies on any map (PROJECT.md). Included by main.lua (no #version line; globals only).
-- Everyone has one in the wheel from the start and after every respawn (walkie.start = 0: only from pickups). Anything
-- tagged `walkie` (a body or one of its shapes: a map's, or the spawn menu's) is picked up with E - our own aim and
-- prompt, as Dive's pickups, since the engine offers no interact to a swimmer - and puts the Walkie-talkie tool in the
-- wheel (gone from the world unless tagged `remain`). A game mode that takes the tool away takes it until a respawn.
-- The talking is Proximity Comms' (registry API, its PROJECT.md "Devices"): every carried walkie is a radio on its
-- team's channel, heard by everyone on that channel carrying one; in hand and switched on (RMB: off / on, on at first)
-- its holder's voice and typed lines go out on it. Without Proximity Comms the keys are written and nobody reads them:
-- the tool is there, it just carries nothing (the hint says so). Any mod (host):
--   walkie.give.<player> = 1 / 0      hands one out (in hand) / takes it for good (no more at respawns)
--   walkie.team.<player> = "<team>"   that player's walkie on the team's own channel ("" = the shared one); unset:
--                                     Proximity Comms' proxchat.team.<player> if a game sets it
--   walkie.start = 0                  nobody gets one by default (set it in your init)

Walkie = {}

TOOL = "walkietalkie"
TOOL_NAME = "Walkie-talkie"
TOOL_GROUP = 4
CHANNEL = "walkie"    -- the shared channel; a team's is walkie-<team>
REACH = 3.5           -- m from the eye to a pickup you can take (a swimmer's eye is the upright capsule's)
PUBLISH_HZ = 10

----- shared helpers -----

-- an input this frame; walkie.test.<input> (bool) presses it for every player (autotests only, as Dive's dive.test.*)
function walkiePressed(name, p)
	return InputPressed(name, p) or GetBool("walkie.test." .. name)
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
	carriers = {}          -- player -> {on = bool}
	devices = {}           -- proxchat.device.<name> -> the value we wrote
	txSet = {}             -- player -> the proxchat.tx.<p> we wrote ("" once cleared)
	seenAlive = {}         -- player -> alive last tick (nil: not seen yet; a start walkie is due)
	revoked = {}           -- player -> true: taken by walkie.give 0 (no start walkie again)
	publishT = 0
	pickSnd = LoadSound("tool_pickup.ogg")
	shared.walkie = {n = 0}
end

local function give(p, hold)
	carriers[p] = {on = true}
	SetToolEnabled(TOOL, true, p)
	if hold then SetPlayerTool(TOOL, p) end
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

function Walkie.serverTick(dt)
	local t = GetTime()
	local seen, here = {}, {}
	for _, p in ipairs(GetAllPlayers()) do
		here[p] = true
		if HasKey("walkie.give." .. p) then                          -- another mod hands one out (1) or takes it (0)
			local n = GetInt("walkie.give." .. p)
			ClearKey("walkie.give." .. p)
			revoked[p] = n <= 0 or nil
			if n > 0 then give(p, true) else take(p) end
		end
		local c = carriers[p]
		if c and not IsToolEnabled(TOOL, p) then carriers[p], c = nil, nil end   -- (a game mode took it)
		local alive = GetPlayerHealth(p) > 0
		-- one in the wheel (not in hand) at the start and after every respawn
		if alive and seenAlive[p] ~= true and not c and not revoked[p] and not (HasKey("walkie.start") and GetInt("walkie.start") == 0) then
			give(p, false)
			c = carriers[p]
		end
		seenAlive[p] = alive
		if not c and IsToolEnabled(TOOL, p) then SetToolEnabled(TOOL, false, p) end -- (only from us)
		if alive and walkiePressed("interact", p) and not c then
			local b = walkieInView(p)
			if b ~= 0 then
				give(p, true)
				c = carriers[p]
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
				if walkiePressed("rmb", p) and not GetBool("proxchat.typing." .. p) and GetPlayerGrabBody(p) == 0 then
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
		if not here[p] then seenAlive[p], carriers[p], revoked[p], txSet[p] = nil, nil, nil, nil end
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
	anims = {}
	clickSnd = LoadSound("clickup.ogg")
end

function client.walkieClick(p, on)
	if IsPlayerValid(p) then PlaySound(clickSnd, GetPlayerTransform(p).pos, 0.6, false, on and 1.15 or 0.85) end
end

function Walkie.clientTick(dt)
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerTool(p) == TOOL then                             -- in the hands: the game's toolanimation.lua
			anims[p] = anims[p] or ToolAnimator()
			tickToolAnimator(anims[p], dt, nil, p)
		end
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
	local w = shared.walkie or {}
	if w[me] == nil and walkieInView(me) ~= 0 then line(UiMiddle() + 90, "E: pick up " .. TOOL_NAME) end
	if GetPlayerTool(me) == TOOL and w[me] ~= nil then
		local y = UiHeight() - 140
		local who = (w.team or {})[me] and "your team" or "everyone with a walkie-talkie"
		line(y, w[me] and "WALKIE ON: " .. who .. " hears you   RMB: off"
			or "Walkie off   RMB: on (in your hand, it carries what you say)")
		if GetFloat("proxchat.alive") < GetTime() - 2 then line(y + 26, "(needs the Proximity Comms mod)", 0.6) end
	end
end
