-- Walkie-Talkies' options (Mod Manager). In multiplayer the host's choice counts for everyone.
-- savegame.mod.nostart (bool): true = nobody starts with a walkie-talkie (pickups, the spawn menu, and with the
-- McPuppet Inventory System its store); unset / false = everyone starts with one (walkie.lua startOn).

function draw()
	local off = GetBool("savegame.mod.nostart")
	UiTranslate(UiCenter(), 90)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiColor(1, 1, 1)
	UiText("Walkie-Talkies")
	UiTranslate(0, 110)
	UiFont("regular.ttf", 28)
	UiText("Everyone starts with a walkie-talkie")
	UiTranslate(0, 56)
	UiFont("bold.ttf", 30)
	for i, name in ipairs({"Yes", "No"}) do
		UiPush()
		UiTranslate((i - 1.5) * 180, 0)
		if (i == 2) == off then UiColor(0.45, 0.85, 1) else UiColor(0.55, 0.55, 0.55) end
		if UiTextButton(name, 160, 46) then SetBool("savegame.mod.nostart", i == 2) end
		UiPop()
	end
	UiTranslate(0, 70)
	UiFont("regular.ttf", 22)
	UiColor(0.8, 0.8, 0.8)
	UiWordWrap(900)
	if off then
		UiText("Nobody starts with one. Walkie-talkies come from pickups on the map and the spawn menu, and with the McPuppet Inventory System from its store.")
	else
		UiText("Everyone has one from the start. With the McPuppet Inventory System it is an item in the inventory (given once: it drops where you die, like everything else, and the store sells more). Without it, it is in the tool wheel and comes back at every respawn.")
	end
	UiTranslate(0, 110)
	UiColor(0.7, 0.7, 0.7)
	UiText("In multiplayer the host's choice counts for everyone.")
	UiTranslate(0, 110)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
