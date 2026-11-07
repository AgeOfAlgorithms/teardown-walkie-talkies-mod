#version 2
-- Walkie-Talkies: walkie-talkies as pickups on any map, talking through Proximity Comms' devices (walkie.lua,
-- PROJECT.md). A global mod; a map places pickups by tagging a body `walkie`.

#include "script/toolanimation.lua"
#include "walkie.lua"

-- (test builds add their modules here)

function server.init()
	Walkie.serverInit()
	if WALKIE_TEST then WALKIE_TEST.serverInit() end
end

function server.tick(dt)
	Walkie.serverTick(dt)
	if WALKIE_TEST then WALKIE_TEST.serverTick(dt) end
end

function server.destroy()
	Walkie.serverDestroy()
end

function client.init()
	Walkie.clientInit()
	if WALKIE_TEST then WALKIE_TEST.clientInit() end
end

function client.tick(dt)
	Walkie.clientTick(dt)
	if WALKIE_TEST then WALKIE_TEST.clientTick(dt) end
end

function client.draw()
	Walkie.clientDraw()
	if WALKIE_TEST then WALKIE_TEST.clientDraw() end
end
