--[[
	LiquidBounce — Luau UI library for Roblox
	Dark liquid glass, strong rounding, blue (#0A84FF) accent, drawn droplet logo.

	Quick start
	-----------
	local LiquidBounce = assert(loadstring(game:HttpGet(
		"https://raw.githubusercontent.com/gghgdw5/UI/arena/884cf208-ui/LiquidBounce.lua", true)))()
	-- (until this file is merged into main, /main/LiquidBounce.lua is a 404)

	local Window = LiquidBounce:CreateWindow({
		Title = "LiquidBounce",
		ToggleKey = Enum.KeyCode.RightControl,
		Layout = "columns",        -- "columns" (classic ClickGUI) or "sidebar"
	})

	local Combat = Window:AddTab({ Title = "Combat" })
	local Modules = Combat:AddSection("Modules")

	Modules:AddToggle({ Title = "KillAura", Default = false, Callback = function(v) end })
	Modules:AddSlider({ Title = "Range", Min = 1, Max = 6, Default = 3, Step = 0.1, Suffix = "m" })
	Modules:AddDropdown({ Title = "Target", Options = { "Closest", "Lowest HP" }, Default = "Closest" })
	Modules:AddMultiDropdown({ Title = "Ignore", Options = { "Friends", "Bots" }, Default = { "Friends" } })
	Modules:AddKeybind({ Title = "Bind", Default = Enum.KeyCode.LeftAlt })
	Modules:AddColorpicker({ Title = "Colour", Default = Color3.fromRGB(10, 132, 255) })
	Modules:AddTextbox({ Title = "Name", Default = "LiquidBounce" })
	Modules:AddButton({ Title = "Save config", Accent = true, Callback = function() end })

	Controls are also reachable straight from a tab (they land in the last
	section, creating a "General" one when needed):
		Combat:AddToggle({ Title = "Aimbot" })

	Every control returns an object with :Set(value, silent) / :Get().
	Flags land in LiquidBounce.Flags[name]; configs are saved as JSON through
	LiquidBounce:SaveConfig(name) / :LoadConfig(name) (executor filesystem).
]]

local VERSION = "1.0.0"

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")

local env = (typeof(getgenv) == "function" and getgenv()) or _G
do
	-- re-executing the script replaces the previous instance instead of stacking GUIs
	local previous = env.LiquidBounce
	if type(previous) == "table" then
		if type(previous.Destroy) == "function" then
			pcall(function()
				previous:Destroy()
			end)
		elseif type(previous.Unload) == "function" then
			pcall(function()
				previous:Unload()
			end)
		elseif type(previous.Windows) == "table" then
			for _, window in ipairs(previous.Windows) do
				pcall(function()
					window:Destroy()
				end)
			end
		end
	end
end

local LocalPlayer = Players.LocalPlayer
local unpack = table.unpack or unpack

local Library = {
	Version = VERSION,
	Flags = {},
	Windows = {},
	Unloaded = false,
	ToggleKey = Enum.KeyCode.RightControl,
	Settings = {
		Blur = true,
		BlurSize = 18,
		Watermark = true,
	},
	Theme = {
		Accent = Color3.fromRGB(10, 132, 255), -- #0A84FF, logo blue
		AccentDark = Color3.fromRGB(0, 90, 220),
		Background = Color3.fromRGB(16, 18, 24),
		Card = Color3.fromRGB(26, 28, 36),
		WindowTransparency = 0.06,
		CardTransparency = 0.10,
		Stroke = Color3.fromRGB(255, 255, 255),
		Text = Color3.fromRGB(240, 242, 245),
		SubText = Color3.fromRGB(150, 156, 168),
		ToggleOff = Color3.fromRGB(52, 56, 68),
	},
	_controls = {},
	_tabs = {},
}
env.LiquidBounce = Library

local Theme = Library.Theme

local connections = {}
local function track(conn)
	connections[#connections + 1] = conn
	return conn
end

---------------------------------------------------------------------------
-- Util
---------------------------------------------------------------------------
local Util = {}

function Util.new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local new = Util.new

function Util.corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

function Util.cornerScale(s)
	return new("UICorner", { CornerRadius = UDim.new(s, 0) })
end

function Util.pad(t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t),
		PaddingLeft = UDim.new(0, l or r or t),
	})
end

function Util.list(dir, gap)
	return new("UIListLayout", {
		FillDirection = dir or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function Util.tween(obj, t, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

function Util.fire(cb, ...)
	if type(cb) ~= "function" then
		return
	end
	local args = table.pack(...)
	task.spawn(function()
		local ok, err = pcall(cb, unpack(args, 1, args.n))
		if not ok then
			warn("[LiquidBounce] callback error: " .. tostring(err))
		end
	end)
end

function Util.opt(o, default, ...)
	if type(o) ~= "table" then
		return default
	end
	for i = 1, select("#", ...) do
		local v = o[select(i, ...)]
		if v ~= nil then
			return v
		end
	end
	return default
end
local opt = Util.opt

function Util.clamp(v, min, max)
	if v < min then return min end
	if v > max then return max end
	return v
end

function Util.decimals(step)
	local s = tostring(step or 1)
	local dot = s:find(".", 1, true)
	return dot and (#s - dot) or 0
end

function Util.snap(v, min, step)
	if not step or step <= 0 then
		return v
	end
	return min + math.floor((v - min) / step + 0.5) * step
end

function Util.format(v, decimals)
	if decimals <= 0 then
		return tostring(math.floor(v + 0.5))
	end
	return string.format("%." .. decimals .. "f", v)
end

function Util.toHex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function Util.fromHex(s)
	s = tostring(s):gsub("#", "")
	if #s == 3 then
		s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
	end
	if #s ~= 6 or not s:match("^%x+$") then
		return nil
	end
	return Color3.fromRGB(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16))
end

function Util.keyName(key)
	if key == nil then
		return "None"
	end
	if typeof(key) == "EnumItem" then
		local names = {
			MouseButton1 = "LMB", MouseButton2 = "RMB", MouseButton3 = "MMB",
			LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
			LeftAlt = "LAlt", RightAlt = "RAlt", Return = "Enter", Backspace = "Back", Escape = "Esc",
		}
		return names[key.Name] or key.Name
	end
	return tostring(key)
end

function Util.toKey(v)
	if typeof(v) == "EnumItem" then
		return v
	end
	if type(v) == "string" and v ~= "" and v ~= "None" then
		local short = {
			MB1 = Enum.UserInputType.MouseButton1, MB2 = Enum.UserInputType.MouseButton2, MB3 = Enum.UserInputType.MouseButton3,
			LMB = Enum.UserInputType.MouseButton1, RMB = Enum.UserInputType.MouseButton2, MMB = Enum.UserInputType.MouseButton3,
		}
		if short[v:upper()] then
			return short[v:upper()]
		end
		local ok, k = pcall(function() return Enum.KeyCode[v] end)
		if ok and k then return k end
		ok, k = pcall(function() return Enum.UserInputType[v] end)
		if ok and k then return k end
	end
	return nil
end

function Util.flagName(title)
	return tostring(title or "control"):lower():gsub("%W", "_")
end

function Util.registerControl(control)
	Library._controls[#Library._controls + 1] = control
	if control.Flag and control.Flag ~= "" then
		Library.Flags[control.Flag] = control
	end
	return control
end

-- forward declarations: tab/section methods are attached lazily so that
-- adding a control to a tab or section resolves to the shared helpers below.
local attachTabMethods
local attachSectionMethods
local sectionFor

---------------------------------------------------------------------------
-- Glass helpers (liquid glass: translucent fill + blur behind + specular sheen)
---------------------------------------------------------------------------
local function glass(parent, radius, bg, transparency)
	local frame = new("Frame", {
		BackgroundColor3 = bg,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Parent = parent,
	}, {
		Util.corner(radius),
		new("UIStroke", {
			Color = Theme.Stroke,
			Transparency = 0.88,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		new("UIStroke", {
			Color = Color3.fromRGB(255, 255, 255),
			Transparency = 0.55,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, {
			new("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.15),
					NumberSequenceKeypoint.new(0.55, 1),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}),
	})
	-- specular highlight: soft white sheen fading from the top edge
	local sheen = new("Frame", {
		Size = UDim2.new(1, 0, 0.55, 0),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 0.93,
		BorderSizePixel = 0,
	}, {
		Util.corner(radius),
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	sheen.Parent = frame
	return frame
end

---------------------------------------------------------------------------
-- Logo: LiquidBounce droplet, drawn with frames (no external assets).
-- A clipped disc whose centre sits on the top-left corner gives the
-- flat top/left edges and the big rounded arc of the original logo.
---------------------------------------------------------------------------
local function createLogo(parent, size, color)
	local holder = new("Frame", {
		Size = UDim2.new(0, size, 0, size),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	local disc = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(2, 0, 2, 0),
		BackgroundColor3 = color or Theme.Accent,
		BorderSizePixel = 0,
		Parent = holder,
	}, {
		Util.cornerScale(0.5),
		new("UIGradient", {
			Rotation = 135,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Theme.Accent),
				ColorSequenceKeypoint.new(1, Theme.AccentDark),
			}),
		}),
	})
	return holder, disc
end
Library.CreateLogo = createLogo

---------------------------------------------------------------------------
-- ScreenGui + blur
---------------------------------------------------------------------------
local guiParent = nil
local ScreenGui = nil
local blurEffect = nil

local function resolveGuiParent()
	if guiParent then
		return guiParent
	end
	local ok, holder = pcall(function()
		if typeof(gethui) == "function" then
			return gethui()
		end
		return nil
	end)
	if ok and holder then
		guiParent = holder
	else
		guiParent = LocalPlayer:WaitForChild("PlayerGui")
	end
	return guiParent
end

-- the ScreenGui is created on first use so that requiring the library never
-- touches the game until the user actually builds a window
local notifyHolder = nil
local function ensureGui()
	if ScreenGui and ScreenGui.Parent then
		return ScreenGui
	end
	ScreenGui = new("ScreenGui", {
		Name = "LiquidBounce",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = resolveGuiParent(),
	})
	pcall(function()
		if typeof(protect_gui) == "function" then protect_gui(ScreenGui) end
		if typeof(protectgui) == "function" then protectgui(ScreenGui) end
	end)
	notifyHolder = new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.new(0, 300, 1, -24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 40,
		Parent = ScreenGui,
	}, { Util.list(Enum.FillDirection.Vertical, 8) })
	if Library.Settings.Blur and not blurEffect then
		blurEffect = new("BlurEffect", { Size = Library.Settings.BlurSize, Parent = Lighting })
	end
	return ScreenGui
end
Library._ensureGui = ensureGui

---------------------------------------------------------------------------
-- Popup manager (dropdowns / colorpicker live above the window)
---------------------------------------------------------------------------
local openPopup = nil
local popupOutsideConn = nil

local function closePopup()
	if openPopup then
		openPopup:Destroy()
		openPopup = nil
	end
	if popupOutsideConn then
		popupOutsideConn:Disconnect()
		popupOutsideConn = nil
	end
end

local function showPopup(anchor, popup, width, height)
	closePopup()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	ensureGui()
	local pos = anchor.AbsolutePosition + Vector2.new(0, anchor.AbsoluteSize.Y + 6)
	local x = Util.clamp(pos.X, 8, math.max(8, viewport.X - width - 8))
	local y = pos.Y
	if y + height > viewport.Y - 8 then
		y = math.max(8, anchor.AbsolutePosition.Y - height - 6)
	end
	popup.Position = UDim2.new(0, x, 0, y)
	popup.Size = UDim2.new(0, width, 0, height)
	popup.ZIndex = 50
	popup.Parent = ScreenGui
	openPopup = popup
	popupOutsideConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local p = input.Position
		local insidePopup = p.X >= popup.AbsolutePosition.X and p.X <= popup.AbsolutePosition.X + popup.AbsoluteSize.X
			and p.Y >= popup.AbsolutePosition.Y and p.Y <= popup.AbsolutePosition.Y + popup.AbsoluteSize.Y
		local insideAnchor = p.X >= anchor.AbsolutePosition.X and p.X <= anchor.AbsolutePosition.X + anchor.AbsoluteSize.X
			and p.Y >= anchor.AbsolutePosition.Y and p.Y <= anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y
		if not insidePopup and not insideAnchor then
			closePopup()
		end
	end)
	return popup
end

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------
function Library:Notify(data, text)
	if Library.Unloaded then return end
	ensureGui()
	if type(data) == "string" then
		data = { Title = data, Text = text }
	end
	data = data or {}
	local title = opt(data, "LiquidBounce", "Title", "Text")
	local body = opt(data, "", "Text", "Description")
	local duration = opt(data, 4, "Duration", "Time")
	local icon = opt(data, nil, "Icon")

	local toast = new("CanvasGroup", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		GroupTransparency = 1,
		BorderSizePixel = 0,
	}, {
		Util.corner(16),
		new("UIStroke", { Color = Theme.Stroke, Transparency = 0.88, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		Util.pad(12),
		Util.list(Enum.FillDirection.Vertical, 4),
	})
	toast.BackgroundColor3 = Theme.Card
	toast.BackgroundTransparency = Theme.CardTransparency

	local accentBar = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 4, 0, 28),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
	}, { Util.corner(2) })
	accentBar.Parent = toast

	local titleLabel = new("TextLabel", {
		Size = UDim2.new(1, -8, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Theme.Text,
		Text = (icon and (icon .. "  ") or "") .. tostring(title),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	titleLabel.Parent = toast

	if body ~= "" then
		local bodyLabel = new("TextLabel", {
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = Theme.SubText,
			Text = tostring(body),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		})
		bodyLabel.Parent = toast
	end

	toast.Parent = notifyHolder
	Util.tween(toast, 0.35, { GroupTransparency = 0 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

	task.delay(duration, function()
		if toast.Parent then
			Util.tween(toast, 0.3, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.wait(0.3)
			toast:Destroy()
		end
	end)
end

---------------------------------------------------------------------------
-- Watermark (logo + FPS + ping, top-left)
---------------------------------------------------------------------------
local watermark = nil
local watermarkAlive = false

function Library:SetWatermark(enabled)
	if watermark then
		watermark:Destroy()
		watermark = nil
	end
	watermarkAlive = false
	if not enabled then return end

	watermarkAlive = true
	watermark = glass(ensureGui(), 14, Theme.Card, Theme.CardTransparency)
	watermark.Position = UDim2.new(0, 12, 0, 12)
	watermark.Size = UDim2.new(0, 220, 0, 30)
	watermark.ZIndex = 5

	local logoHolder = createLogo(watermark, 18)
	logoHolder.AnchorPoint = Vector2.new(0, 0.5)
	logoHolder.Position = UDim2.new(0, 8, 0.5, 0)

	local label = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 32, 0.5, 0),
		Size = UDim2.new(0, 72, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = "LiquidBounce",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	label.Parent = watermark

	local stats = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.new(1, -122, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Theme.SubText,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	stats.Parent = watermark

	task.spawn(function()
		local frames = 0
		local last = os.clock()
		while watermarkAlive and watermark and watermark.Parent do
			RunService.Heartbeat:Wait()
			frames = frames + 1
			local now = os.clock()
			if now - last >= 0.5 then
				local fps = math.floor(frames / (now - last) + 0.5)
				frames = 0
				last = now
				local ping = 0
				pcall(function()
					ping = math.floor(LocalPlayer:GetNetworkPing() * 1000 + 0.5)
				end)
				stats.Text = fps .. " FPS  |  " .. ping .. " ms"
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- Roblox' default fonts have no colour emoji, so tabs use geometric glyphs
local DEFAULT_TAB_ICONS = {
	combat = "◆", movement = "▲", player = "●", render = "■",
	world = "◈", misc = "▣", exploit = "◉", fun = "★",
	settings = "◎", config = "▤", main = "◇", aim = "◈",
	visuals = "▦", lua = "▥", hud = "▬",
}

function Library:CreateWindow(config)
	config = config or {}
	local title = opt(config, "LiquidBounce", "Title", "Name")
	local subtitle = opt(config, "v" .. VERSION, "Subtitle", "Version", "Description")
	local toggleKey = Util.toKey(opt(config, self.ToggleKey, "ToggleKey", "Key", "Bind")) or self.ToggleKey
	self.ToggleKey = toggleKey

	-- Layout = "columns" recreates the classic LiquidBounce ClickGUI:
	-- one glass column per category, arranged side by side, all visible at once.
	local layout = tostring(opt(config, "columns", "Layout", "Style")):lower()
	local isColumns = layout ~= "sidebar" and layout ~= "tabs" and layout ~= "single"
	local columnCount = opt(config, 7, "Columns", "ColumnCount")
	local perRow = math.max(1, opt(config, columnCount, "ColumnsPerRow", "PerRow"))
	local size = opt(config, { 940, 600 }, "Size")
	local defaultWidth = size[1] or 940
	local defaultHeight = size[2] or 600
	if isColumns then
		defaultWidth = math.max(defaultWidth, 220 * columnCount + 24)
	end

	ensureGui()
	local windowRoot = new("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0, defaultWidth, 0, defaultHeight),
		GroupTransparency = 0,
		BorderSizePixel = 0,
		Parent = ScreenGui,
	})
	windowRoot.BackgroundColor3 = Theme.Background
	windowRoot.BackgroundTransparency = isColumns and 1 or Theme.WindowTransparency
	new("UICorner", { CornerRadius = UDim.new(0, isColumns and 0 or 24), Parent = windowRoot })
	new("UIScale", { Scale = 1, Parent = windowRoot })

	local Window = {
		Title = title,
		TitleBar = nil,
		_tabs = {},
		_selectedTab = nil,
		_open = true,
		_isColumns = isColumns,
		Root = windowRoot,
	}

	local pageHolder
	local contentTitle
	local tabList
	local searchBox

	if not isColumns then
		new("UIStroke", {
			Color = Theme.Stroke, Transparency = 0.86, Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = windowRoot,
		})

		-- specular sheen across the whole window
		new("Frame", {
			Size = UDim2.new(1, 0, 0.4, 0),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0.95,
			BorderSizePixel = 0,
			Parent = windowRoot,
		}, {
			Util.corner(24),
			new("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})

		-- blue tint that makes the glass feel refractive instead of flat grey
		new("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Parent = windowRoot,
		}, {
			Util.corner(24),
			new("UIGradient", {
				Rotation = 45,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.92),
					NumberSequenceKeypoint.new(0.45, 0.985),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})

		-- sidebar --------------------------------------------------------
		local sidebar = new("Frame", {
			Size = UDim2.new(0, 200, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = windowRoot,
		}, { Util.pad(14, 14, 12, 14), Util.list(Enum.FillDirection.Vertical, 8) })

		local header = new("Frame", {
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = true,
			LayoutOrder = 1,
		})
		header.Parent = sidebar

		local logoHolder = createLogo(header, 38)
		logoHolder.Position = UDim2.new(0, 0, 0.5, 0)
		logoHolder.AnchorPoint = Vector2.new(0, 0.5)

		local nameLabel = new("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 50, 0.5, 0),
			Size = UDim2.new(1, -50, 1, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBlack,
			TextSize = 16,
			TextColor3 = Theme.Text,
			Text = "LIQUID\nBOUNCE",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
		})
		nameLabel.Parent = header

		local versionLabel = new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextColor3 = Theme.SubText,
			Text = tostring(subtitle),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
		})
		versionLabel.Parent = sidebar

		searchBox = new("TextBox", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = Theme.Card,
			BackgroundTransparency = Theme.CardTransparency,
			BorderSizePixel = 0,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = Theme.Text,
			PlaceholderText = "Search modules...",
			PlaceholderColor3 = Theme.SubText,
			Text = "",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 3,
		}, {
			Util.corner(12),
			new("UIStroke", { Color = Theme.Stroke, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
			Util.pad(10),
		})
		searchBox.Parent = sidebar

		tabList = new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -112),
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 0,
			LayoutOrder = 4,
		}, { Util.list(Enum.FillDirection.Vertical, 4) })
		tabList.Parent = sidebar

		-- content --------------------------------------------------------
		local content = new("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(1, -200, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = windowRoot,
		})

		local contentHeader = new("Frame", {
			Position = UDim2.new(0, 16, 0, 14),
			Size = UDim2.new(1, -32, 0, 36),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = true,
		})
		contentHeader.Parent = content

		contentTitle = new("TextLabel", {
			Size = UDim2.new(1, -90, 1, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			TextColor3 = Theme.Text,
			Text = title,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		contentTitle.Parent = contentHeader

		local function headerButton(symbol, x)
			local btn = new("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, x, 0.5, 0),
				Size = UDim2.new(0, 30, 0, 30),
				BackgroundColor3 = Theme.Card,
				BackgroundTransparency = Theme.CardTransparency,
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Theme.SubText,
				Text = symbol,
				AutoButtonColor = false,
			}, {
				Util.corner(10),
				new("UIStroke", { Color = Theme.Stroke, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
			})
			btn.Parent = contentHeader
			btn.MouseEnter:Connect(function() btn.TextColor3 = Theme.Text end)
			btn.MouseLeave:Connect(function() btn.TextColor3 = Theme.SubText end)
			return btn
		end
		local minimizeBtn = headerButton("-", -38)
		local closeBtn = headerButton("X", -4)
		minimizeBtn.MouseButton1Click:Connect(function() Window:Toggle(false) end)
		closeBtn.MouseButton1Click:Connect(function() Window:Toggle(false) end)

		pageHolder = new("Frame", {
			Position = UDim2.new(0, 16, 0, 58),
			Size = UDim2.new(1, -32, 1, -72),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		})
		pageHolder.Parent = content

		-- drag handles
		local dragging = false
		local dragStart = nil
		local startPos = nil
		local function beginDrag(input)
			dragging = true
			dragStart = input.Position
			startPos = windowRoot.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
		for _, handle in ipairs({ header, contentHeader }) do
			handle.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					beginDrag(input)
				end
			end)
		end
		track(UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			local delta = input.Position - dragStart
			windowRoot.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end))
	else
		-- ----------------------------------------------------------------
		-- Classic column layout
		-- ----------------------------------------------------------------
		-- tinted glass backdrop that follows the columns' width
		local sheet = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(0, 0, 1, -20),
			BackgroundColor3 = Theme.Background,
			BackgroundTransparency = 0.22,
			BorderSizePixel = 0,
			ZIndex = 0,
			Parent = windowRoot,
		}, {
			Util.corner(26),
			new("UIStroke", {
				Color = Theme.Stroke, Transparency = 0.9, Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border, ZIndex = 0,
			}),
			new("UIGradient", {
				Rotation = 45,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.55),
					NumberSequenceKeypoint.new(0.5, 0.86),
					NumberSequenceKeypoint.new(1, 0.55),
				}),
			}),
		})
		Util.tween(sheet, 0.4, { Size = UDim2.new(0, defaultWidth - 24, 1, -20) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

		-- columns scroll horizontally when the window is narrower than the row
		local columnScroll = new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, 0),
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			ScrollingDirection = Enum.ScrollingDirection.X,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.Accent,
			ZIndex = 2,
			Parent = windowRoot,
		})
		Window._columnScroll = columnScroll
		local outer = new("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = columnScroll,
		}, {
			Util.pad(10),
			new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Top,
			}),
		})

		local columnHolder = new("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		})
		local columnLayout = new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			-- more categories than fit in one row wrap onto a second row
			FillDirectionMaxCells = perRow > 1 and perRow or 0,
		})
		columnLayout.Parent = columnHolder
		columnHolder.Parent = outer

		pageHolder = columnHolder

		-- title bar: droplet + LIQUID BOUNCE, used as the drag handle
		local titleBar = glass(windowRoot, 16, Theme.Card, Theme.CardTransparency)
		titleBar.AnchorPoint = Vector2.new(0.5, 0)
		titleBar.Position = UDim2.new(0.5, 0, 0, -54)
		titleBar.Size = UDim2.new(0, 244, 0, 44)
		titleBar.ZIndex = 2
		titleBar.Active = true
		Window.TitleBar = titleBar

		local barLogo = createLogo(titleBar, 26)
		barLogo.AnchorPoint = Vector2.new(0, 0.5)
		barLogo.Position = UDim2.new(0, 12, 0.5, 0)

		local barLabel = new("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 48, 0.5, 0),
			Size = UDim2.new(0, 140, 1, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBlack,
			TextSize = 13,
			TextColor3 = Theme.Text,
			Text = "LIQUID BOUNCE",
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		barLabel.Parent = titleBar

		local hideBtn = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.new(0, 24, 0, 24),
			BackgroundColor3 = Theme.ToggleOff,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = Theme.SubText,
			Text = "−",
			AutoButtonColor = false,
		}, { Util.corner(8) })
		hideBtn.Parent = titleBar
		hideBtn.MouseButton1Click:Connect(function() Window:Toggle(false) end)

		local dragging = false
		local dragStart = nil
		local startPos = nil
		titleBar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = windowRoot.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						dragging = false
					end
				end)
			end
		end)
		track(UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			local delta = input.Position - dragStart
			windowRoot.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end))

		Window._columnHolder = columnHolder
		Window._columnLayout = columnLayout
	end

	-- open / close -------------------------------------------------------
	local scaleObj = windowRoot:FindFirstChildOfClass("UIScale")
	function Window:Toggle(force)
		local target = force
		if target == nil then
			target = not self._open
		end
		self._open = target
		if target then
			windowRoot.Visible = true
			Util.tween(windowRoot, 0.25, { GroupTransparency = 0 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			if scaleObj then
				Util.tween(scaleObj, 0.25, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			end
			if self.TitleBar then
				Util.tween(self.TitleBar, 0.25, { BackgroundTransparency = Theme.CardTransparency }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			end
		else
			Util.tween(windowRoot, 0.2, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			if scaleObj then
				Util.tween(scaleObj, 0.2, { Scale = 0.96 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
			if self._isColumns then
				-- keep the title bar visible so the menu can be reopened by clicking it
				windowRoot.Visible = true
				if self.TitleBar then
					self.TitleBar.BackgroundTransparency = 0.25
				end
			else
				task.delay(0.2, function()
					if not self._open then
						windowRoot.Visible = false
					end
				end)
			end
		end
	end
	function Window:IsOpen()
		return self._open
	end
	function Window:SetToggleKey(key)
		Library.ToggleKey = Util.toKey(key) or key
	end

	local window = Window
	track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if Library.Unloaded then return end
		if input.KeyCode == Library.ToggleKey then
			if UserInputService:GetFocusedTextBox() then return end
			window:Toggle()
		end
	end))

	-- intro animation ----------------------------------------------------
	windowRoot.GroupTransparency = 1
	if scaleObj then scaleObj.Scale = 0.94 end
	Util.tween(windowRoot, 0.4, { GroupTransparency = 0 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	if scaleObj then
		Util.tween(scaleObj, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end

	-- search -------------------------------------------------------------
	if searchBox then
		local function applySearch(query)
			query = tostring(query or ""):lower()
			local filtering = query ~= ""
			for _, tab in ipairs(Window._tabs) do
				local tabHasMatch = false
				for _, control in ipairs(tab._controls) do
					local match = not filtering or control.Title:lower():find(query, 1, true) ~= nil
					control._frame.Visible = match
					if match then tabHasMatch = true end
				end
				for _, section in ipairs(tab._sections) do
					local sectionVisible = false
					for _, control in ipairs(section._controls) do
						if control._frame.Visible then
							sectionVisible = true
							break
						end
					end
					section._frame.Visible = sectionVisible
				end
				if Window._isColumns then
					tab._column.Visible = tabHasMatch
				end
			end
		end
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			applySearch(searchBox.Text)
		end)
	end

	-- tabs ---------------------------------------------------------------
	function Window:SelectTab(tab)
		if not tab then return end
		self._selectedTab = tab
		for _, t in ipairs(self._tabs) do
			local active = (t == tab)
			if t._page then
				t._page.Visible = active
			end
			if t._button then
				Util.tween(t._button, 0.2, {
					BackgroundTransparency = active and 0.82 or 1,
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				t._button.BackgroundColor3 = active and Theme.Accent or Theme.Card
			end
			if t._label then
				t._label.TextColor3 = active and Theme.Text or Theme.SubText
			end
			if t._icon then
				t._icon.TextColor3 = active and Theme.Text or Theme.SubText
			end
			if t._indicator then
				t._indicator.Visible = active
			end
		end
		if contentTitle then
			contentTitle.Text = tab.Title
		end
	end

	function Window:GetTab(name)
		for _, t in ipairs(self._tabs) do
			if t.Title:lower() == tostring(name):lower() then
				return t
			end
		end
		return nil
	end

	function Window:AddTab(data)
		data = data or {}
		local tabTitle = opt(data, "Tab", "Title", "Name", "Text")
		local icon = opt(data, nil, "Icon")

		local page, button, label, iconLabel, indicator, column

		if self._isColumns then
			-- one column per category, sized by its content (max 3 columns wide)
			column = new("ScrollingFrame", {
				Size = UDim2.new(0, 186, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(0, 0, 0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 0,
				ClipsDescendants = false,
				LayoutOrder = #self._tabs + 1,
			}, { Util.list(Enum.FillDirection.Vertical, 8) })
			column.Parent = pageHolder

			button = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 40),
				BackgroundColor3 = Theme.Accent,
				BackgroundTransparency = 0.12,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = 1,
			}, {
				Util.corner(14),
				new("UIStroke", {
					Color = Color3.fromRGB(255, 255, 255),
					Transparency = 0.7,
					Thickness = 1,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
				new("UIGradient", {
					Rotation = 90,
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(56, 158, 255)),
						ColorSequenceKeypoint.new(1, Theme.AccentDark),
					}),
				}),
			})
			button.Parent = column

			label = new("TextLabel", {
				Size = UDim2.new(1, -20, 1, 0),
				Position = UDim2.new(0, 10, 0, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = Theme.Text,
				Text = tabTitle,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			label.Parent = button

			page = new("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = 2,
			}, { Util.list(Enum.FillDirection.Vertical, 8) })
			page.Parent = column
		else
			icon = icon or DEFAULT_TAB_ICONS[tabTitle:lower()] or "•"
			button = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 36),
				BackgroundColor3 = Theme.Card,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = #self._tabs + 1,
			}, { Util.corner(12) })
			button.Parent = tabList

			indicator = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.new(0, 4, 0, 18),
				BackgroundColor3 = Theme.Accent,
				BorderSizePixel = 0,
				Visible = false,
			}, { Util.corner(2) })
			indicator.Parent = button

			iconLabel = new("TextLabel", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 14, 0.5, 0),
				Size = UDim2.new(0, 20, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 14,
				TextColor3 = Theme.SubText,
				Text = tostring(icon),
			})
			iconLabel.Parent = button

			label = new("TextLabel", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 38, 0.5, 0),
				Size = UDim2.new(1, -44, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = Theme.SubText,
				Text = tabTitle,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			label.Parent = button

			page = new("ScrollingFrame", {
				Size = UDim2.new(1, 0, 1, 0),
				CanvasSize = UDim2.new(0, 0, 0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 3,
				ScrollBarImageColor3 = Theme.Accent,
				Visible = false,
			}, {
				Util.list(Enum.FillDirection.Vertical, 10),
				Util.pad(2),
			})
			page.Parent = pageHolder
		end

		local Tab = {
			Title = tabTitle,
			Window = Window,
			Icon = icon,
			_sections = {},
			_controls = {},
			_page = page,
			_button = button,
			_label = label,
			_icon = iconLabel,
			_indicator = indicator,
			_column = column,
		}

		button.MouseButton1Click:Connect(function()
			Window:SelectTab(Tab)
		end)
		button.MouseEnter:Connect(function()
			if Window._selectedTab ~= Tab then
				label.TextColor3 = Theme.Text
			end
		end)
		button.MouseLeave:Connect(function()
			if Window._selectedTab ~= Tab then
				label.TextColor3 = Theme.SubText
			end
		end)

		attachTabMethods(Tab)
		Window._tabs[#Window._tabs + 1] = Tab
		Library._tabs[#Library._tabs + 1] = Tab
		if not Window._isColumns and #Window._tabs == 1 then
			Window:SelectTab(Tab)
		end
		return Tab
	end

	function Window:SetScale(scale)
		local uiScale = windowRoot:FindFirstChildOfClass("UIScale")
		if uiScale then
			uiScale.Scale = Util.clamp(tonumber(scale) or 1, 0.4, 2.5)
		end
	end

	function Window:Destroy()
		for index, entry in ipairs(Library.Windows) do
			if entry == self then
				table.remove(Library.Windows, index)
				break
			end
		end
		windowRoot:Destroy()
	end

	self.Windows[#self.Windows + 1] = Window
	if self.Settings.Watermark and not watermark then
		self:SetWatermark(true)
	end
	return Window
end

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------
local function addSection(Tab, title)
	local frame = glass(Tab._page, 18, Theme.Card, Theme.CardTransparency)
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = #Tab._sections + 1

	local header = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = 1,
	})
	header.Parent = frame

	local titleLabel = new("TextLabel", {
		Size = UDim2.new(1, -40, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = tostring(title):upper(),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	titleLabel.Position = UDim2.new(0, 14, 0, 0)
	titleLabel.Parent = header

	local arrow = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, 16, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Theme.SubText,
		Text = ">",
		Rotation = 90,
	})
	arrow.Parent = header

	local body = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
	}, {
		Util.pad(6, 10, 10, 10),
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, 3),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	body.Parent = frame

	-- the frame stacks header + body so its AutomaticSize is exact
	local frameList = new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	frameList.Parent = frame

	local Section = {
		Title = tostring(title),
		Tab = Tab,
		_frame = frame,
		_body = body,
		_controls = {},
		_collapsed = false,
	}

	header.MouseButton1Click:Connect(function()
		Section._collapsed = not Section._collapsed
		body.Visible = not Section._collapsed
		arrow.Rotation = Section._collapsed and 0 or 90
	end)

	attachSectionMethods(Section)
	Tab._sections[#Tab._sections + 1] = Section
	return Section
end

---------------------------------------------------------------------------
-- Control helpers
---------------------------------------------------------------------------
local function makeRow(parent, height)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = true,
	})
	row.Parent = parent
	return row
end

local function makeLabel(parent, text, x, width)
	local label = new("TextLabel", {
		Position = UDim2.new(0, x or 4, 0, 0),
		Size = UDim2.new(1, -((x or 4) + (width or 0)), 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = Theme.Text,
		Text = tostring(text),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
	})
	label.Parent = parent
	return label
end

local function finishControl(Tab, Section, control, frame)
	control._frame = frame
	control.Tab = Tab
	control.Section = Section
	Section._controls[#Section._controls + 1] = control
	Tab._controls[#Tab._controls + 1] = control
	return Util.registerControl(control)
end

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------
local function addToggle(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Toggle", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local value = opt(data, false, "Default", "Value")
	if type(value) ~= "boolean" then value = false end

	local row = makeRow(Section._body, 32)
	local rowBg = new("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.ToggleOff,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
	}, { Util.corner(10) })
	rowBg.Parent = row
	makeLabel(row, title, 10, 60)
	rowBg.ZIndex = 1

	local trackFrame = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0, 38, 0, 20),
		BackgroundColor3 = Theme.ToggleOff,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, { Util.cornerScale(0.5) })
	trackFrame.Parent = row

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.new(0, 14, 0, 14),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, { Util.cornerScale(0.5) })
	knob.Parent = trackFrame

	local control = {
		Type = "toggle",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = value,
	}

	local function render(animate)
		local targetColor = value and Theme.Accent or Theme.ToggleOff
		local targetX = value and (38 - 14 - 3) or 3
		if animate then
			Util.tween(trackFrame, 0.2, { BackgroundColor3 = targetColor }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			Util.tween(knob, 0.2, { Position = UDim2.new(0, targetX, 0.5, 0) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		else
			trackFrame.BackgroundColor3 = targetColor
			knob.Position = UDim2.new(0, targetX, 0.5, 0)
		end
	end

	function control:Set(newValue, silent)
		value = newValue and true or false
		control.Value = value
		render(true)
		if not silent then
			Util.fire(callback, value)
		end
	end
	function control:Get()
		return value
	end
	function control:Toggle()
		control:Set(not value)
	end

	row.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			control:Toggle()
		end
	end)
	row.MouseEnter:Connect(function()
		rowBg.BackgroundTransparency = 0.72
	end)
	row.MouseLeave:Connect(function()
		rowBg.BackgroundTransparency = 0.82
	end)

	render(false)
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Slider
---------------------------------------------------------------------------
local function addSlider(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Slider", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local min = opt(data, 0, "Min", "Minimum")
	local max = opt(data, 100, "Max", "Maximum")
	local step = opt(data, 1, "Step", "Increment")
	local value = opt(data, min, "Default", "Value")
	value = Util.clamp(Util.snap(value, min, step), min, max)
	local suffix = opt(data, "", "Suffix", "Unit")
	local decimals = Util.decimals(step)

	local row = makeRow(Section._body, 48)
	local titleLabel = makeLabel(row, title, 4, 70)
	titleLabel.Size = UDim2.new(1, -80, 0, 18)

	local valueLabel = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 0),
		Size = UDim2.new(0, 70, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Theme.Accent,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	valueLabel.Parent = row

	local trackFrame = new("Frame", {
		Position = UDim2.new(0, 4, 0, 28),
		Size = UDim2.new(1, -8, 0, 8),
		BackgroundColor3 = Theme.ToggleOff,
		BorderSizePixel = 0,
		Active = true,
	}, { Util.cornerScale(0.5) })
	trackFrame.Parent = row

	local fill = new("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
	}, { Util.cornerScale(0.5) })
	fill.Parent = trackFrame

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 14, 0, 14),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
	}, {
		Util.cornerScale(0.5),
		new("UIStroke", { Color = Theme.Accent, Transparency = 0.4, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	knob.Parent = trackFrame

	local control = {
		Type = "slider",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = value,
		Min = min, Max = max, Step = step,
	}

	local function ratio()
		if max == min then return 0 end
		return (value - min) / (max - min)
	end

	local function render()
		local r = ratio()
		fill.Size = UDim2.new(r, 0, 1, 0)
		knob.Position = UDim2.new(r, 0, 0.5, 0)
		valueLabel.Text = Util.format(value, decimals) .. tostring(suffix)
	end

	function control:Set(newValue, silent)
		value = Util.clamp(Util.snap(tonumber(newValue) or value, min, step), min, max)
		control.Value = value
		render()
		if not silent then
			Util.fire(callback, value)
		end
	end
	function control:Get()
		return value
	end

	local draggingSlider = false
	local function updateFromInput(input)
		local pos = input.Position.X
		local left = trackFrame.AbsolutePosition.X
		local width = trackFrame.AbsoluteSize.X
		if width <= 0 then return end
		local r = Util.clamp((pos - left) / width, 0, 1)
		control:Set(min + r * (max - min))
	end

	trackFrame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			draggingSlider = true
			updateFromInput(input)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					draggingSlider = false
				end
			end)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if draggingSlider then
			updateFromInput(input)
		end
	end))

	render()
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Button
---------------------------------------------------------------------------
local function addButton(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Button", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local accent = opt(data, false, "Accent", "Primary")

	local row = makeRow(Section._body, 38)
	local button = new("TextButton", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = accent and Theme.Accent or Theme.ToggleOff,
		BackgroundTransparency = accent and 0 or 0.35,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Text = tostring(title),
		AutoButtonColor = false,
	}, {
		Util.corner(12),
		new("UIStroke", { Color = Theme.Stroke, Transparency = accent and 1 or 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	button.Parent = row

	button.MouseEnter:Connect(function()
		Util.tween(button, 0.15, { BackgroundTransparency = accent and 0.15 or 0.15 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end)
	button.MouseLeave:Connect(function()
		Util.tween(button, 0.15, { BackgroundTransparency = accent and 0 or 0.35 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end)
	button.MouseButton1Click:Connect(function()
		Util.fire(callback)
	end)

	local control = {
		Type = "button",
		Title = title,
		Flag = opt(data, "", "Flag"),
		Value = nil,
	}
	function control:Set()
		Util.fire(callback)
	end
	function control:Get()
		return nil
	end

	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Dropdown (single + multi)
---------------------------------------------------------------------------
local function addDropdown(Tab, Section, data, multi)
	data = data or {}
	local title = opt(data, "Dropdown", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local options = opt(data, {}, "Options", "Values", "Items")
	local default = opt(data, nil, "Default", "Value")

	local selected = {}
	if multi then
		if type(default) == "table" then
			for _, v in ipairs(default) do
				selected[v] = true
			end
		elseif default ~= nil then
			selected[default] = true
		end
	else
		if default == nil and #options > 0 then
			default = options[1]
		end
		selected = default
	end

	local row = makeRow(Section._body, 52)
	local titleLabel = makeLabel(row, title, 4, 0)
	titleLabel.Size = UDim2.new(1, -8, 0, 18)

	local box = new("TextButton", {
		Position = UDim2.new(0, 4, 0, 22),
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundColor3 = Theme.ToggleOff,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = "",
		AutoButtonColor = false,
	}, {
		Util.corner(10),
		new("UIStroke", { Color = Theme.Stroke, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		Util.pad(10),
	})
	box.Parent = row

	local arrow = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.new(0, 16, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Theme.SubText,
		Text = ">",
		Rotation = 90,
	})
	arrow.Parent = box

	local control = {
		Type = multi and "multidropdown" or "dropdown",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = selected,
		Options = options,
	}

	local function displayText()
		if multi then
			local chosen = {}
			for _, option in ipairs(options) do
				if selected[option] then
					chosen[#chosen + 1] = tostring(option)
				end
			end
			if #chosen == 0 then
				return "None"
			end
			return table.concat(chosen, ", ")
		end
		return tostring(selected or "None")
	end

	local function render()
		box.Text = displayText()
		control.Value = selected
	end

	function control:Set(newValue, silent)
		if multi then
			selected = {}
			if type(newValue) == "table" then
				for _, v in ipairs(newValue) do
					selected[v] = true
				end
			elseif newValue ~= nil then
				selected[newValue] = true
			end
		else
			selected = newValue
		end
		render()
		if not silent then
			if multi then
				local chosen = {}
				for _, option in ipairs(options) do
					if selected[option] then
						chosen[#chosen + 1] = option
					end
				end
				Util.fire(callback, chosen)
			else
				Util.fire(callback, selected)
			end
		end
	end
	function control:Get()
		if multi then
			local chosen = {}
			for _, option in ipairs(options) do
				if selected[option] then
					chosen[#chosen + 1] = option
				end
			end
			return chosen
		end
		return selected
	end

	box.MouseButton1Click:Connect(function()
		if openPopup and openPopup.Name == "LiquidBounceDropdown" then
			closePopup()
			arrow.Rotation = 90
			return
		end
		closePopup()
		arrow.Rotation = 270

		local popup = glass(nil, 14, Theme.Card, Theme.CardTransparency)
		popup.Name = "LiquidBounceDropdown"
		popup.ClipsDescendants = true

		local list = new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, 0),
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.Accent,
		}, {
			Util.list(Enum.FillDirection.Vertical, 2),
			Util.pad(6),
		})
		list.Parent = popup

		local function refreshRows()
			for _, child in ipairs(list:GetChildren()) do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end
			for _, option in ipairs(options) do
				local isSelected = multi and selected[option] or (selected == option)
				local item = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 26),
					BackgroundColor3 = isSelected and Theme.Accent or Theme.ToggleOff,
					BackgroundTransparency = isSelected and 0.15 or 0.55,
					BorderSizePixel = 0,
					Font = Enum.Font.Gotham,
					TextSize = 12,
					TextColor3 = isSelected and Theme.Text or Theme.SubText,
					Text = (isSelected and "• " or "") .. tostring(option),
					AutoButtonColor = false,
				}, { Util.corner(8) })
				item.Parent = list
				item.MouseButton1Click:Connect(function()
					if multi then
						selected[option] = not selected[option]
						control:Set(control:Get(), true)
						render()
						refreshRows()
						local chosen = {}
						for _, o in ipairs(options) do
							if selected[o] then
								chosen[#chosen + 1] = o
							end
						end
						Util.fire(callback, chosen)
					else
						control:Set(option)
						closePopup()
						arrow.Rotation = 90
					end
				end)
			end
		end
		refreshRows()

		local height = math.min(220, math.max(40, #options * 30 + 12))
		showPopup(box, popup, box.AbsoluteSize.X, height)
		-- reset the arrow whenever the popup goes away (click outside, tab change, ...)
		popup.Destroying:Connect(function()
			arrow.Rotation = 90
		end)
	end)

	render()
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Keybind
---------------------------------------------------------------------------
local function addKeybind(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Keybind", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local key = opt(data, nil, "Default", "Key", "Value")
	key = Util.toKey(key)

	local row = makeRow(Section._body, 34)
	makeLabel(row, title, 4, 80)

	local pill = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.new(0, 76, 0, 24),
		BackgroundColor3 = Theme.ToggleOff,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Theme.Text,
		Text = Util.keyName(key),
		AutoButtonColor = false,
	}, {
		Util.corner(8),
		new("UIStroke", { Color = Theme.Stroke, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	pill.Parent = row

	local control = {
		Type = "keybind",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = key,
		_listening = false,
	}

	local function render()
		pill.Text = control._listening and "..." or Util.keyName(key)
		control.Value = key
	end

	function control:Set(newKey, silent)
		key = Util.toKey(newKey)
		render()
		if not silent then
			Util.fire(callback, key)
		end
	end
	function control:Get()
		return key
	end
	function control:GetKeyName()
		return Util.keyName(key)
	end

	pill.MouseButton1Click:Connect(function()
		if control._listening then return end
		control._listening = true
		render()
		local conn
		conn = UserInputService.InputBegan:Connect(function(input)
			if not control._listening then
				if conn then conn:Disconnect() end
				return
			end
			local captured = nil
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3 then
				captured = input.UserInputType
			elseif input.KeyCode ~= Enum.KeyCode.Unknown then
				if input.KeyCode == Enum.KeyCode.Escape then
					captured = nil
				else
					captured = input.KeyCode
				end
			end
			if captured ~= nil or input.KeyCode == Enum.KeyCode.Escape then
				control._listening = false
				control:Set(captured)
				if conn then conn:Disconnect() end
			end
		end)
		track(conn)
	end)

	render()
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Textbox
---------------------------------------------------------------------------
local function addTextbox(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Textbox", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local placeholder = opt(data, "Type here...", "Placeholder")
	local value = opt(data, "", "Default", "Value")

	local row = makeRow(Section._body, 52)
	local titleLabel = makeLabel(row, title, 4, 0)
	titleLabel.Size = UDim2.new(1, -8, 0, 18)

	local box = new("TextBox", {
		Position = UDim2.new(0, 4, 0, 22),
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundColor3 = Theme.ToggleOff,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.Text,
		PlaceholderText = tostring(placeholder),
		PlaceholderColor3 = Theme.SubText,
		Text = tostring(value),
		ClearTextOnFocus = false,
	}, {
		Util.corner(10),
		new("UIStroke", { Color = Theme.Stroke, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		Util.pad(10),
	})
	box.Parent = row

	local control = {
		Type = "textbox",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = tostring(value),
	}

	function control:Set(newValue, silent)
		value = tostring(newValue or "")
		box.Text = value
		control.Value = value
		if not silent then
			Util.fire(callback, value)
		end
	end
	function control:Get()
		return value
	end

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			value = box.Text
			control.Value = value
			Util.fire(callback, value)
		end
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		value = box.Text
		control.Value = value
	end)

	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Colorpicker
---------------------------------------------------------------------------
local function addColorpicker(Tab, Section, data)
	data = data or {}
	local title = opt(data, "Colorpicker", "Title", "Text", "Name")
	local callback = opt(data, nil, "Callback", "Function")
	local color = opt(data, Theme.Accent, "Default", "Value", "Color")
	if typeof(color) == "string" then
		color = Util.fromHex(color) or Theme.Accent
	end
	if typeof(color) ~= "Color3" then
		color = Theme.Accent
	end

	local row = makeRow(Section._body, 34)
	makeLabel(row, title, 4, 60)

	local preview = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.new(0, 44, 0, 24),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
	}, {
		Util.corner(8),
		new("UIStroke", { Color = Theme.Stroke, Transparency = 0.85, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	preview.Parent = row

	local control = {
		Type = "colorpicker",
		Title = title,
		Flag = opt(data, Util.flagName(title), "Flag"),
		Value = color,
	}

	local function render()
		preview.BackgroundColor3 = color
		control.Value = color
	end

	function control:Set(newColor, silent)
		if typeof(newColor) == "string" then
			newColor = Util.fromHex(newColor)
		end
		if typeof(newColor) ~= "Color3" then return end
		color = newColor
		render()
		if not silent then
			Util.fire(callback, color)
		end
	end
	function control:Get()
		return color
	end

	preview.MouseButton1Click:Connect(function()
		if openPopup and openPopup.Name == "LiquidBounceColor" then
			closePopup()
			return
		end
		closePopup()

		local h, s, v = color:ToHSV()
		local popup = glass(nil, 16, Theme.Card, Theme.CardTransparency)
		popup.Name = "LiquidBounceColor"
		popup.ClipsDescendants = true

		local pad = 12
		local svSize = 180
		local sv = new("Frame", {
			Position = UDim2.new(0, pad, 0, pad),
			Size = UDim2.new(0, svSize, 0, 120),
			BackgroundColor3 = Color3.fromHSV(h, 1, 1),
			BorderSizePixel = 0,
			Active = true,
		}, { Util.corner(10) })
		sv.Parent = popup

		new("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Parent = sv,
		}, {
			Util.corner(10),
			new("UIGradient", {
				Rotation = 0,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})
		new("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Color3.fromRGB(0, 0, 0),
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Parent = sv,
		}, {
			Util.corner(10),
			new("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0),
				}),
			}),
		})

		local svKnob = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.new(0, 12, 0, 12),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
		}, {
			Util.cornerScale(0.5),
			new("UIStroke", { Color = Color3.fromRGB(0, 0, 0), Transparency = 0.5, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		})
		svKnob.Parent = sv

		local hueBar = new("Frame", {
			Position = UDim2.new(0, pad, 0, pad + 120 + 10),
			Size = UDim2.new(0, svSize, 0, 14),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Active = true,
		}, {
			Util.cornerScale(0.5),
			new("UIGradient", {
				Rotation = 0,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
					ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 1, 1)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
				}),
			}),
		})
		hueBar.Parent = popup

		local hueKnob = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.new(0, 12, 0, 12),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
		}, {
			Util.cornerScale(0.5),
			new("UIStroke", { Color = Color3.fromRGB(0, 0, 0), Transparency = 0.5, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		})
		hueKnob.Parent = hueBar

		local hexLabel = new("TextLabel", {
			Position = UDim2.new(0, pad, 0, pad + 120 + 10 + 14 + 8),
			Size = UDim2.new(1, -pad * 2, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Theme.Text,
			Text = Util.toHex(color),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		hexLabel.Parent = popup

		local function renderPicker()
		sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svKnob.Position = UDim2.new(s, 0, 1 - v, 0)
		hueKnob.Position = UDim2.new(h, 0, 0.5, 0)
		hexLabel.Text = Util.toHex(color)
		end

		local function applyColor(silent)
		color = Color3.fromHSV(h, s, v)
		render()
		renderPicker()
		if not silent then
			Util.fire(callback, color)
		end
	end

	local svDragging = false
	local hueDragging = false
	sv.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			svDragging = true
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					svDragging = false
				end
			end)
		end
	end)
	hueBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			hueDragging = true
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					hueDragging = false
				end
			end)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if svDragging then
			local rel = Vector2.new(
				Util.clamp((input.Position.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1),
				Util.clamp((input.Position.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1)
			)
			s = rel.X
			v = 1 - rel.Y
			applyColor()
		elseif hueDragging then
			h = Util.clamp((input.Position.X - hueBar.AbsolutePosition.X) / hueBar.AbsoluteSize.X, 0, 1)
			applyColor()
		end
	end))

	renderPicker()
	showPopup(preview, popup, svSize + pad * 2, pad + 120 + 10 + 14 + 8 + 18 + pad)
	end)

	render()
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Divider / Label / Paragraph
---------------------------------------------------------------------------
local function addDivider(Tab, Section, data)
	data = data or {}
	local row = makeRow(Section._body, 14)
	new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.new(1, -8, 0, 1),
		BackgroundColor3 = Theme.Stroke,
		BackgroundTransparency = 0.9,
		BorderSizePixel = 0,
		Parent = row,
	})
	local control = { Type = "divider", Title = "", Flag = "", Value = nil }
	function control:Set() end
	function control:Get() return nil end
	finishControl(Tab, Section, control, row)
	return control
end

local function addLabel(Tab, Section, data)
	data = data or {}
	local text = opt(data, "", "Title", "Text", "Name")
	local row = makeRow(Section._body, 22)
	makeLabel(row, text, 4, 0)
	local control = { Type = "label", Title = tostring(text), Flag = "", Value = text }
	function control:Set(newText)
		text = tostring(newText or "")
		control.Title = text
		for _, child in ipairs(row:GetChildren()) do
			if child:IsA("TextLabel") then
				child.Text = text
			end
		end
	end
	function control:Get() return text end
	finishControl(Tab, Section, control, row)
	return control
end

local function addParagraph(Tab, Section, data)
	data = data or {}
	local text = opt(data, "", "Text", "Description", "Title")
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	row.Parent = Section._body
	local label = new("TextLabel", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.SubText,
		Text = tostring(text),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	})
	label.Position = UDim2.new(0, 4, 0, 0)
	label.Parent = row
	local control = { Type = "paragraph", Title = "", Flag = "", Value = text }
	function control:Set(newText)
		text = tostring(newText or "")
		label.Text = text
	end
	function control:Get() return text end
	finishControl(Tab, Section, control, row)
	return control
end

---------------------------------------------------------------------------
-- Tab / Section API
---------------------------------------------------------------------------
local SectionMethods = {}
function SectionMethods:AddToggle(data) return addToggle(self.Tab, self, data) end
function SectionMethods:AddSlider(data) return addSlider(self.Tab, self, data) end
function SectionMethods:AddButton(data) return addButton(self.Tab, self, data) end
function SectionMethods:AddDropdown(data) return addDropdown(self.Tab, self, data, false) end
function SectionMethods:AddMultiDropdown(data) return addDropdown(self.Tab, self, data, true) end
function SectionMethods:AddKeybind(data) return addKeybind(self.Tab, self, data) end
function SectionMethods:AddBind(data) return addKeybind(self.Tab, self, data) end
function SectionMethods:AddTextbox(data) return addTextbox(self.Tab, self, data) end
function SectionMethods:AddInput(data) return addTextbox(self.Tab, self, data) end
function SectionMethods:AddColorpicker(data) return addColorpicker(self.Tab, self, data) end
function SectionMethods:AddColorPicker(data) return addColorpicker(self.Tab, self, data) end
function SectionMethods:AddDivider(data) return addDivider(self.Tab, self, data) end
function SectionMethods:AddLabel(data) return addLabel(self.Tab, self, data) end
function SectionMethods:AddParagraph(data) return addParagraph(self.Tab, self, data) end

function attachSectionMethods(Section)
	for name, fn in pairs(SectionMethods) do
		Section[name] = fn
	end
	return Section
end

function sectionFor(Tab)
	local current = Tab._sections[#Tab._sections]
	if not current then
		current = addSection(Tab, "General")
	end
	return current
end

local TabMethods = {}
function TabMethods:AddSection(title) return addSection(self, title) end
function TabMethods:AddToggle(data) return addToggle(self, sectionFor(self), data) end
function TabMethods:AddSlider(data) return addSlider(self, sectionFor(self), data) end
function TabMethods:AddButton(data) return addButton(self, sectionFor(self), data) end
function TabMethods:AddDropdown(data) return addDropdown(self, sectionFor(self), data, false) end
function TabMethods:AddMultiDropdown(data) return addDropdown(self, sectionFor(self), data, true) end
function TabMethods:AddKeybind(data) return addKeybind(self, sectionFor(self), data) end
function TabMethods:AddBind(data) return addKeybind(self, sectionFor(self), data) end
function TabMethods:AddTextbox(data) return addTextbox(self, sectionFor(self), data) end
function TabMethods:AddInput(data) return addTextbox(self, sectionFor(self), data) end
function TabMethods:AddColorpicker(data) return addColorpicker(self, sectionFor(self), data) end
function TabMethods:AddColorPicker(data) return addColorpicker(self, sectionFor(self), data) end
function TabMethods:AddDivider(data) return addDivider(self, sectionFor(self), data) end
function TabMethods:AddLabel(data) return addLabel(self, sectionFor(self), data) end
function TabMethods:AddParagraph(data) return addParagraph(self, sectionFor(self), data) end

function attachTabMethods(Tab)
	for name, fn in pairs(TabMethods) do
		Tab[name] = fn
	end
	return Tab
end

---------------------------------------------------------------------------
-- Config save / load (executor filesystem, JSON)
---------------------------------------------------------------------------
local CONFIG_FOLDER = "LiquidBounce/configs"

local function configPath(name)
	return CONFIG_FOLDER .. "/" .. tostring(name) .. ".json"
end

function Library:SaveConfig(name)
	name = tostring(name or "default")
	if typeof(writefile) ~= "function" then
		warn("[LiquidBounce] writefile is not available in this environment")
		return false
	end
	local data = {}
	for flag, control in pairs(self.Flags) do
		local ok, value = pcall(function() return control:Get() end)
		if ok then
			if control.Type == "keybind" then
				value = Util.keyName(value)
			elseif control.Type == "colorpicker" and typeof(value) == "Color3" then
				value = Util.toHex(value)
			end
			data[flag] = value
		end
	end
	local ok, err = pcall(function()
		if typeof(makefolder) == "function" then
			pcall(makefolder, CONFIG_FOLDER)
		end
		writefile(configPath(name), HttpService:JSONEncode(data))
	end)
	if not ok then
		warn("[LiquidBounce] failed to save config: " .. tostring(err))
		return false
	end
	self:Notify({ Title = "Config saved", Text = name, Icon = "💾" })
	return true
end

function Library:LoadConfig(name)
	name = tostring(name or "default")
	if typeof(readfile) ~= "function" then
		warn("[LiquidBounce] readfile is not available in this environment")
		return false
	end
	local ok, content = pcall(readfile, configPath(name))
	if not ok or not content then
		warn("[LiquidBounce] config not found: " .. name)
		return false
	end
	local okDecode, data = pcall(function()
		return HttpService:JSONDecode(content)
	end)
	if not okDecode or type(data) ~= "table" then
		warn("[LiquidBounce] config is corrupted: " .. name)
		return false
	end
	for flag, value in pairs(data) do
		local control = self.Flags[flag]
		if control then
			pcall(function()
				control:Set(value, true)
			end)
		end
	end
	self:Notify({ Title = "Config loaded", Text = name, Icon = "📂" })
	return true
end

function Library:GetConfigList()
	if typeof(listfiles) ~= "function" then
		return {}
	end
	local ok, files = pcall(listfiles, CONFIG_FOLDER)
	if not ok or type(files) ~= "table" then
		return {}
	end
	local names = {}
	for _, path in ipairs(files) do
		local name = tostring(path):match("([^/\\]+)%.json$")
		if name then
			names[#names + 1] = name
		end
	end
	return names
end

---------------------------------------------------------------------------
-- Destroy
---------------------------------------------------------------------------
function Library:Destroy()
	if self.Unloaded then return end
	self.Unloaded = true
	closePopup()
	watermarkAlive = false
	for _, conn in ipairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	if blurEffect then
		blurEffect:Destroy()
		blurEffect = nil
	end
	if watermark then
		watermark:Destroy()
		watermark = nil
	end
	ScreenGui:Destroy()
	if env.LiquidBounce == self then
		env.LiquidBounce = nil
	end
end
Library.Unload = Library.Destroy

return Library
