--[[
	LiquidBounce — example / demo script for the UI library.

	Run this in any executor (or paste into a LocalScript) to see the full
	ClickGUI populated with the classic LiquidBounce module set.

	RightControl — show / hide the menu.
]]

local Lighting = game:GetService("Lighting")

-- The library currently lives on the arena/884cf208-ui branch (it is not on
-- main yet), so /main/LiquidBounce.lua would 404 and return nil. Try both.
local LIBRARY_URLS = {
	"https://raw.githubusercontent.com/gghgdw5/UI/arena/884cf208-ui/LiquidBounce.lua",
	"https://raw.githubusercontent.com/gghgdw5/UI/main/LiquidBounce.lua",
}

local function loadLibrary()
	local firstError = nil
	for _, url in ipairs(LIBRARY_URLS) do
		local ok, source = pcall(function()
			return game:HttpGet(url, true)
		end)
		if ok and type(source) == "string" and #source > 2000 and not source:find("404: Not Found", 1, true) then
			local chunk, compileError = loadstring(source)
			if chunk then
				local ran, lib = pcall(chunk)
				if ran and type(lib) == "table" and lib.CreateWindow then
					return lib
				end
				firstError = firstError or (ran and "the library returned no API" or tostring(lib))
			else
				firstError = firstError or tostring(compileError)
			end
		else
			firstError = firstError or tostring(ok and "HTTP body was not the library (404?)" or source)
		end
	end
	error("[LiquidBounce] could not load the library: " .. tostring(firstError or "unknown error") .. "\n   tried: " .. table.concat(LIBRARY_URLS, ", "), 0)
end

local LiquidBounce = loadLibrary()
-- If the file sits next to your script instead, drop everything above and use:
-- local LiquidBounce = loadstring(readfile("LiquidBounce.lua"))()

local Window = LiquidBounce:CreateWindow({
	Title = "LiquidBounce",
	Subtitle = "v1.0.0  •  RightControl",
	ToggleKey = Enum.KeyCode.RightControl,
	Layout = "columns", -- classic ClickGUI columns; use "sidebar" for the single-panel look
	Watermark = true,
})

-------------------------------------------------------------------------------
-- Module catalogue (name, has settings, default state)
-------------------------------------------------------------------------------
local CATEGORIES = {
	{
		Tab = "Combat",
		Icon = "⚔️",
		Modules = {
			{ "Aimbot", true, false },
			{ "AimAssist", true, false },
			{ "AutoArmor", true, true },
			{ "AutoBow", false, false },
			{ "AutoClicker", true, false },
			{ "AutoLeave", true, false },
			{ "AutoPot", true, false },
			{ "AutoSoup", false, true },
			{ "AutoTotem", true, true },
			{ "BowAimbot", true, false },
			{ "Criticals", true, true },
			{ "HitBox", true, false },
			{ "Ignite", false, false },
			{ "KillAura", true, false },
		},
	},
	{
		Tab = "Movement",
		Icon = "🏃",
		Modules = {
			{ "AirJump", false, false },
			{ "AirLadder", false, false },
			{ "AutoWalk", false, false },
			{ "BugUp", true, false },
			{ "ElytraFly", false, false },
			{ "FastClimb", true, false },
			{ "FastStairs", true, true },
			{ "Fly", false, false },
			{ "Glide", false, false },
			{ "GroundElytra", false, false },
			{ "HighJump", true, false },
			{ "IceSpeed", true, false },
			{ "InventoryMove", true, true },
			{ "LadderJump", false, false },
			{ "LiquidWalk", true, false },
		},
	},
	{
		Tab = "Player",
		Icon = "👤",
		Modules = {
			{ "AntiCactus", false, true },
			{ "AutoRespawn", false, true },
			{ "AutoTool", false, true },
			{ "Blink", false, false },
			{ "Eagle", false, false },
			{ "FarmKingBot", false, false },
			{ "FastUse", true, true },
			{ "InventoryCleaner", true, false },
			{ "NoFall", true, true },
			{ "PotionSaver", false, false },
			{ "Regen", true, false },
			{ "Zoot", false, false },
		},
	},
	{
		Tab = "Render",
		Icon = "🎨",
		Modules = {
			{ "AntiBlind", false, true },
			{ "BlockESP", true, false },
			{ "BlockOverlay", false, false },
			{ "Breadcrumbs", true, false },
			{ "Chams", false, false },
			{ "ClickGUI", true, false },
			{ "ESP", true, false },
			{ "FreeCam", true, false },
			{ "Fullbright", false, true },
			{ "HUD", true, true },
			{ "ItemESP", true, false },
			{ "NameTags", false, false },
			{ "NoBob", false, true },
			{ "NoFOV", true, false },
			{ "NoHurtCam", false, true },
		},
	},
	{
		Tab = "World",
		Icon = "🌍",
		Modules = {
			{ "AutoBreak", false, false },
			{ "ChestAura", true, false },
			{ "ChestStealer", true, true },
			{ "CivBreak", false, false },
			{ "FastBreak", false, true },
			{ "FastPlace", false, true },
			{ "Fucker", true, false },
			{ "Liquids", false, false },
			{ "Nuker", false, false },
			{ "Scaffold", true, false },
			{ "Timer", true, false },
			{ "Tower", true, false },
		},
	},
	{
		Tab = "Misc",
		Icon = "🧩",
		Modules = {
			{ "AntiBot", false, true },
			{ "AtAllProvider", true, false },
			{ "ControllerControl", true, false },
			{ "LiquidChat", false, true },
			{ "MidClick", false, false },
			{ "NameProtect", true, true },
			{ "NoRotateSet", false, true },
			{ "Spammer", true, false },
			{ "Teams", true, false },
		},
	},
	{
		Tab = "Exploit",
		Icon = "💥",
		Modules = {
			{ "AbortBreaking", false, false },
			{ "AntiHunger", false, true },
			{ "BedGodMode", false, false },
			{ "CommandSign", false, false },
			{ "ConsoleSpammer", true, false },
			{ "Ghost", false, false },
			{ "GhostHand", true, false },
			{ "GodMode", false, false },
			{ "Kick", true, false },
			{ "MoreCarry", false, false },
			{ "MultiActions", false, false },
			{ "Paralyze", false, false },
			{ "Phase", false, false },
			{ "PingSpoof", true, false },
		},
	},
	{
		Tab = "Fun",
		Icon = "🎉",
		Modules = {
			{ "Derp", true, false },
			{ "SkinDerp", false, false },
		},
	},
}

-------------------------------------------------------------------------------
-- Build the menu
-------------------------------------------------------------------------------
local enabledCount = 0
local toggles = {}

for _, category in ipairs(CATEGORIES) do
	local Tab = Window:AddTab({ Title = category.Tab })
	local Toggles = Tab:AddSection("Modules")

	for _, module in ipairs(category.Modules) do
		local name, hasSettings, default = module[1], module[2], module[3]
		-- hasSettings marks modules that carry a sub-panel in the real client;
		-- the toggles below are the on/off switches themselves

		toggles[#toggles + 1] = Toggles:AddToggle({
			Title = name,
			Default = default,
			Flag = category.Tab:lower() .. "_" .. name:lower(),
			Callback = function(value)
				if value then
					enabledCount = enabledCount + 1
				else
					enabledCount = math.max(0, enabledCount - 1)
				end
			end,
		})
	end
end

-------------------------------------------------------------------------------
-- A fully detailed tab, showing every control type
-------------------------------------------------------------------------------
local Settings = Window:AddTab({ Title = "Settings" })

local Aim = Settings:AddSection("Aimbot")
Aim:AddSlider({
	Title = "FOV",
	Min = 10, Max = 360, Default = 120, Step = 1, Suffix = "°",
	Flag = "aim_fov",
	Callback = function(value) end,
})
Aim:AddSlider({
	Title = "Smoothing",
	Min = 0, Max = 1, Default = 0.35, Step = 0.05,
	Flag = "aim_smooth",
})
Aim:AddDropdown({
	Title = "Target Part",
	Options = { "Head", "Torso", "Closest", "Lowest Health" },
	Default = "Head",
	Flag = "aim_part",
	Callback = function(value) end,
})
Aim:AddMultiDropdown({
	Title = "Ignore",
	Options = { "Friends", "Bots", "Invisible", "NPC" },
	Default = { "Friends" },
	Flag = "aim_ignore",
})
Aim:AddKeybind({
	Title = "Aim Key",
	Default = Enum.KeyCode.LeftAlt,
	Flag = "aim_key",
})

local Visuals = Settings:AddSection("Visuals")
Visuals:AddColorpicker({
	Title = "Accent",
	Default = LiquidBounce.Theme.Accent,
	Flag = "accent",
	Callback = function(color)
		LiquidBounce.Theme.Accent = color
	end,
})
Visuals:AddToggle({
	Title = "Liquid Glass Blur",
	Default = true,
	Flag = "blur",
	Callback = function(value)
		if blurEffect then
			blurEffect.Enabled = value
		end
	end,
})
local blurEffect = Lighting:FindFirstChildOfClass("BlurEffect")

Visuals:AddSlider({
	Title = "Blur Strength",
	Min = 0, Max = 40, Default = 18, Step = 1,
	Flag = "blur_strength",
	Callback = function(value)
		if blurEffect then
			blurEffect.Size = value
		end
	end,
})
Visuals:AddTextbox({
	Title = "Name Protect",
	Default = "LiquidBounce",
	Placeholder = "your name",
	Flag = "name_protect",
})
Visuals:AddDivider()
Visuals:AddParagraph({
	Text = "Liquid glass panels: translucent fill, blurred backdrop, specular edge highlights and 20+ px corner radii.",
})

local Configs = Settings:AddSection("Configs")
local configName = "default"
Configs:AddTextbox({
	Title = "Config Name",
	Default = "default",
	Flag = "config_name",
	Callback = function(value)
		configName = value
	end,
})
Configs:AddButton({
	Title = "Save Config",
	Accent = true,
	Callback = function()
		LiquidBounce:SaveConfig(configName)
	end,
})
Configs:AddButton({
	Title = "Load Config",
	Callback = function()
		LiquidBounce:LoadConfig(configName)
	end,
})
Configs:AddButton({
	Title = "Unload",
	Callback = function()
		LiquidBounce:Unload()
	end,
})

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------
LiquidBounce:Notify({
	Title = "LiquidBounce " .. LiquidBounce.Version,
	Text = "RightControl to toggle the menu",
	Icon = "💧",
	Duration = 6,
})

local starting = 0
for _, toggle in ipairs(toggles) do
	if toggle:Get() then
		starting = starting + 1
	end
end
print(("[LiquidBounce] loaded: %d modules, %d enabled"):format(#toggles, starting))
