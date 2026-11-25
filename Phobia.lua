--[[
                                Phobia UI Library
    ~ Ported from the Neverlose.cc UI Library (4lpaca, MIT) to the
      penablox RECODE Lua API (luapi sandbox). ~

    - No external assets: the logo ("P") and the whole icon set are
      drawn procedurally with native instances (vector strokes).
    - No rbxassetid / rbxasset images are required for icons.
    - Filesystem calls (writefile/readfile/...) fall back to the
      in-memory `database` API when the native fs layer is missing.
    - Works with the engine's automatic lifecycle cleanup (instances,
      connections and tasks are released on unload).

    Usage:
        local Phobia = loadstring(game:HttpGet('.../Phobia.lua'))();
        -- or just execute the script: the library also lands in getgenv().Phobia

        local Window = Phobia:CreateWindow({
            Name = 'Phobia',
            Content = 'Roblox',
            Size = Phobia.Scales.Default,
            ConfigFolder = 'Phobia/Configs',
            Keybind = 'Insert',
        });

        local Tab = Window:AddTab({ Name = 'Combat', Icon = 'sword' });  -- built-in drawn icon
        local Section = Tab:AddSection({ Name = 'Rage', Position = 'left' });
        local Group = Section:AddLabel('Aimbot');

        Group:AddToggle({ Name = 'Enabled', Default = false, Callback = function(v) end });
        Group:AddSlider({ Name = 'FOV', Min = 10, Max = 500, Default = 120, Callback = function(v) end });
        Group:AddDropdown({ Name = 'Part', Options = { 'Head', 'Body' }, Default = 'Head', Callback = function(v) end });
        Group:AddColorPicker({ Name = 'Color', Default = Color3.fromRGB(255, 0, 0), Callback = function(c) end });
        Group:AddKeybind({ Name = 'Key', Default = 'E', Callback = function() end });
        Section:AddButton({ Name = 'Reload', Icon = 'refresh', Callback = function() end });

        Phobia:CreateNotification():new({ Title = 'Phobia', Content = 'Loaded', Duration = 3 });

    Icon set (all hand-drawn vectors, append '-bold' for heavier strokes):
        phobia, gear, check, x, plus-large, minus, magnifying-glass, floppy-disk,
        trash-can, folder, file, user, shield, key, bell, palette, sliders, home,
        globe, terminal, alert, info, heart, star, lock, clock, eye, refresh,
        download, upload, image, message, zap, flame, gamepad, monitor, list, menu,
        wifi, bug, cloud, cpu, logout, exit-rect, play, pause, crosshair, copy, edit,
        skull, ghost, chevron-large-left/right, chevron-small-up/down/left/right,
        three-dots-horizontal/vertical + aliases (settings, search, save, trash, ...)
]]

--// Luau / executor compatibility shims -------------------------------------------------
local LPH_NO_VIRTUALIZE = (type(LPH_NO_VIRTUALIZE) == 'function' and LPH_NO_VIRTUALIZE) or function(f) return f end;
getgenv().LPH_NO_VIRTUALIZE = getgenv().LPH_NO_VIRTUALIZE or LPH_NO_VIRTUALIZE;

cloneref = cloneref or function(i) return i end;
gethui = gethui or get_hidden_gui;
getcustomasset = getcustomasset or getsynasset;
getgenv = getgenv or getfenv;

-- small Luau polyfills (present in the engine, safe to redefine otherwise)
table.clear = table.clear or function(t)
	for k in next , t do
		t[k] = nil;
	end;
end;

table.find = table.find or function(t , value , init)
	for i = (init or 1) , #t do
		if t[i] == value then
			return i;
		end;
	end;

	return nil;
end;

local Phobia = {};

Phobia.GlobalSignals = {};
Phobia.UnloadEnabled = true;

--// Services ----------------------------------------------------------------------------
local TweenService: TweenService = cloneref(game:GetService('TweenService'));
local UserInputService: UserInputService = cloneref(game:GetService('UserInputService'));
local TextService: TextService = cloneref(game:GetService('TextService'));
local RunService: RunService = cloneref(game:GetService('RunService'));
local Players: Players = cloneref(game:GetService('Players'));
local HttpService: HttpService = cloneref(game:GetService('HttpService'));
local LocalPlayer: Player = Players.LocalPlayer;
local CoreGui = (function()
	-- the engine safely redirects CoreGui parenting to PlayerGui on permission errors
	local __ok , __hui = pcall(function()
		return (gethui and gethui()) or game:GetService('CoreGui');
	end);

	if __ok and typeof(__hui) == 'Instance' then
		return __hui;
	end;

	if LocalPlayer then
		return LocalPlayer:FindFirstChildOfClass('PlayerGui');
	end;

	return nil;
end)();
local Mouse: Mouse = LocalPlayer and LocalPlayer:GetMouse() or nil;
local CurrentCamera: Camera = cloneref(workspace.CurrentCamera);
local ProtectGui = protect_gui or protectgui or (syn and syn.protect_gui) or function(s) return s; end;
local GlobalWindow = Instance.new('ScreenGui');
local ManualTween = TweenInfo.new(0.1);
local SlowyTween = TweenInfo.new(0.175);
local FastTween = TweenInfo.new(0.05);
local VSlowTween = TweenInfo.new(0.5,Enum.EasingStyle.Quint);
local TabTween = TweenInfo.new(0.28,Enum.EasingStyle.Quad,Enum.EasingDirection.Out);
local Encryption = {};

--// Storage layer -----------------------------------------------------------------------
-- Native fs when available, otherwise a virtual filesystem persisted through `database`.
local FS = {};
do
	local NativeWrite = type(writefile) == 'function' and writefile or nil;
	local NativeRead = type(readfile) == 'function' and readfile or nil;
	local NativeIsFile = type(isfile) == 'function' and isfile or nil;
	local NativeIsFolder = type(isfolder) == 'function' and isfolder or nil;
	local NativeMakeFolder = type(makefolder) == 'function' and makefolder or nil;
	local NativeListFiles = type(listfiles) == 'function' and listfiles or nil;
	local NativeDelFile = type(delfile) == 'function' and delfile or nil;

	local Database = (type(database) == 'table' or typeof(database) == 'userdata') and database or nil;
	local FSKey = 'PhobiaFileSystemV2';

	local function SplitPath(Path: string)
		local Parts = {};

		for Part in string.gmatch(Path , '[^/]+') do
			Parts[#Parts + 1] = Part;
		end;

		return Parts;
	end;

	local function Join(Parts , Count)
		local Out = '';

		for i = 1 , (Count or #Parts) do
			Out = Out .. ((i > 1 and '/') or '') .. Parts[i];
		end;

		return Out;
	end;

	local SessionTree = nil;

	local function LoadTree()
		if SessionTree then
			return SessionTree;
		end;

		if Database then
			local __ok , __tree = pcall(function()
				return Database.read(FSKey);
			end);

			if __ok and typeof(__tree) == 'table' and type(__tree.Files) == 'table' and type(__tree.Dirs) == 'table' then
				SessionTree = __tree;
				return SessionTree;
			end;
		end;

		SessionTree = { Dirs = { Phobia = true } , Files = {} };
		return SessionTree;
	end;

	local function SaveTree(Tree)
		SessionTree = Tree;

		if Database then
			pcall(function()
				Database.write(FSKey , Tree);

				if type(Database.flush) == 'function' then
					pcall(function()
						Database.flush();
					end);
				end;
			end);
		end;
	end;

	local function EnsureDir(Tree , Path)
		if Path == '' or Tree.Dirs[Path] then
			return;
		end;

		local Parts = SplitPath(Path);
		local Current = '';

		for i , Part in ipairs(Parts) do
			Current = (Current == '' and Part) or (Current .. '/' .. Part);
			Tree.Dirs[Current] = true;
		end;
	end;

	function FS.IsFolder(Path)
		if NativeIsFolder then
			local __ok , __res = pcall(NativeIsFolder , Path);

			if __ok then
				return __res == true;
			end;
		end;

		local Tree = LoadTree();
		return Tree.Dirs[Path] == true;
	end;

	function FS.MakeFolder(Path)
		if NativeMakeFolder then
			local __ok = pcall(NativeMakeFolder , Path);

			if __ok then
				return;
			end;
		end;

		local Tree = LoadTree();
		EnsureDir(Tree , tostring(Path));
		SaveTree(Tree);
	end;

	function FS.IsFile(Path)
		if NativeIsFile then
			local __ok , __res = pcall(NativeIsFile , Path);

			if __ok then
				return __res == true;
			end;
		end;

		local Tree = LoadTree();
		return Tree.Files[Path] ~= nil;
	end;

	function FS.WriteFile(Path , Content)
		if NativeWrite then
			local __ok = pcall(NativeWrite , Path , Content);

			if __ok then
				return;
			end;
		end;

		local Tree = LoadTree();
		local Parts = SplitPath(tostring(Path));

		if #Parts > 1 then
			EnsureDir(Tree , Join(Parts , #Parts - 1));
		end;

		Tree.Files[tostring(Path)] = tostring(Content);
		SaveTree(Tree);
	end;

	function FS.ReadFile(Path)
		if NativeRead then
			local __ok , __res = pcall(NativeRead , Path);

			if __ok then
				return __res;
			end;
		end;

		local Tree = LoadTree();
		return Tree.Files[tostring(Path)];
	end;

	function FS.ListFiles(Path)
		if NativeListFiles then
			local __ok , __res = pcall(NativeListFiles , Path);

			if __ok and type(__res) == 'table' then
				return __res;
			end;
		end;

		local Tree = LoadTree();
		local Out = {};
		local Prefix = (Path == '' and '') or (tostring(Path) .. '/');
		local PathLen = #Prefix;

		for File in next , Tree.Files do
			if string.sub(File , 1 , PathLen) == Prefix then
				local Rest = string.sub(File , PathLen + 1);

				if string.find(Rest , '/' , 1 , true) == nil then
					Out[#Out + 1] = Prefix .. Rest;
				end;
			end;
		end;

		for Dir in next , Tree.Dirs do
			if #Dir > PathLen and string.sub(Dir , 1 , PathLen) == Prefix then
				local Rest = string.sub(Dir , PathLen + 1);

				if string.find(Rest , '/' , 1 , true) == nil then
					Out[#Out + 1] = Prefix .. Rest;
				end;
			end;
		end;

		return Out;
	end;

	function FS.DelFile(Path)
		if NativeDelFile then
			local __ok = pcall(NativeDelFile , Path);

			if __ok then
				return;
			end;
		end;

		local Tree = LoadTree();
		Tree.Files[tostring(Path)] = nil;
		SaveTree(Tree);
	end;
end;

Phobia.FS = FS;

local writefile = FS.WriteFile;
local readfile = FS.ReadFile;
local isfile = FS.IsFile;
local isfolder = FS.IsFolder;
local makefolder = FS.MakeFolder;
local listfiles = FS.ListFiles;
local delfile = FS.DelFile;

--// Basic info --------------------------------------------------------------------------
Phobia.UserProfile = (function()
	if not LocalPlayer then
		return nil;
	end;

	local __ok , __thumb = pcall(function()
		return Players:GetUserThumbnailAsync(LocalPlayer.UserId , Enum.ThumbnailType.HeadShot , Enum.ThumbnailSize.Size150x150);
	end);

	if __ok and type(__thumb) == 'string' then
		return __thumb;
	end;

	return nil;
end)();

Phobia.RandomString = LPH_NO_VIRTUALIZE(function()
	return string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4))..string.rep(string.char(math.random(97,122)),math.random(1,4));
end);

ProtectGui(GlobalWindow);

GlobalWindow.Name = Phobia.RandomString();
GlobalWindow.IgnoreGuiInset = true;
GlobalWindow.ZIndexBehavior = Enum.ZIndexBehavior.Global;
GlobalWindow.ResetOnSpawn = false;
GlobalWindow.Parent = CoreGui;

Phobia.Scales = {
	Small = UDim2.fromOffset(540,380),
	Mobile = UDim2.fromOffset(640,385),
	Default = UDim2.fromOffset(640 , 480),
	Large = UDim2.fromOffset(800 , 600)
};

Phobia.IconColor = Color3.fromRGB(255, 255, 255);
Phobia.ScreenGui = GlobalWindow;
Phobia.Flags = {};
Phobia.AccentColor = Color3.fromRGB(116, 94, 230);
Phobia.MainColor = Color3.fromRGB(8, 8, 13);
Phobia.RegisiteryColor = {};
Phobia.NameRegisitry = {};
Phobia.IsMosueOverOtherFrame = false;
-- the logo is the drawn "P" mark (no image assets)
Phobia.GlobalLogo = 'phobia';

--========================================================================================--
--   Phobia.VectorIcons — built-in hand-drawn icon set                                    --
--   Every icon is a small vector drawing (strokes + fills) rendered with native          --
--   instances. Nothing is loaded from rbxassetid / icon packs — fully offline.           --
--========================================================================================--

Phobia.Icons = {};

-- Design grid: 24 x 24 units, rendered at any pixel size (kept pixel-perfect).
local GRID = 24;

do
	-- Spec reference:
	--   w            default stroke width (grid units)
	--   s            stroke list:
	--     { p = {{x,y},...}, w }              polyline (round caps/joins)
	--     { p = {{x,y},...}, c = true, w }    closed polyline
	--     { l = {x1,y1,x2,y2}, w }            line
	--     { a = {cx,cy,r,a0,a1}, w }          circular arc, degrees; 0 = right, 90 = down
	--     { e = {cx,cy,rx,ry,a0,a1}, w }      elliptical arc
	--     { q = {x,y,w,h,rad}, w }            rounded-rect outline
	--   f            fills:
	--     { d = {x,y,r} }                     filled dot
	--     { r = {x,y,w,h,rad} }               filled rounded rect

	local Icons = Phobia.Icons;

	Icons['phobia'] = { w = 2.4, s = { -- the "P" logo mark
		{ p = { {8, 19.6}, {8, 4.4}, {12.4, 4.4} } },
		{ a = {12.4, 9.7, 5.3, 270, 450} },
		{ p = { {12.4, 15}, {8, 15} } }
	} };

	Icons['gear'] = { w = 2, s = {
		{ a = {12, 12, 6.6, 0, 360} },
		{ a = {12, 12, 2.8, 0, 360} },
		{ l = {19, 12, 22, 12} },
		{ l = {17.37, 17.37, 19.07, 19.07} },
		{ l = {12, 19, 12, 22} },
		{ l = {6.63, 17.37, 4.93, 19.07} },
		{ l = {5, 12, 2, 12} },
		{ l = {6.63, 6.63, 4.93, 4.93} },
		{ l = {12, 5, 12, 2} },
		{ l = {17.37, 6.63, 19.07, 4.93} }
	} };

	Icons['check'] = { w = 2.4, s = {
		{ p = { {4.6, 12.6}, {9.6, 17.6}, {19.4, 6.4} } }
	} };

	Icons['chevron-large-right'] = { w = 2.4, s = { { p = { {9, 5}, {15.5, 12}, {9, 19} } } } };
	Icons['chevron-large-left'] = { w = 2.4, s = { { p = { {15, 5}, {8.5, 12}, {15, 19} } } } };
	Icons['chevron-small-down'] = { w = 2.2, s = { { p = { {6.5, 9.5}, {12, 15}, {17.5, 9.5} } } } };
	Icons['chevron-small-up'] = { w = 2.2, s = { { p = { {6.5, 14.5}, {12, 9}, {17.5, 14.5} } } } };
	Icons['chevron-small-right'] = { w = 2.2, s = { { p = { {9.5, 6.5}, {15, 12}, {9.5, 17.5} } } } };
	Icons['chevron-small-left'] = { w = 2.2, s = { { p = { {14.5, 6.5}, {9, 12}, {14.5, 17.5} } } } };

	Icons['three-dots-horizontal'] = { w = 2, f = { { d = {5, 12, 2} }, { d = {12, 12, 2} }, { d = {19, 12, 2} } } };
	Icons['three-dots-vertical'] = { w = 2, f = { { d = {12, 5, 2} }, { d = {12, 12, 2} }, { d = {12, 19, 2} } } };

	Icons['plus-large'] = { w = 2.2, s = { { l = {12, 5, 12, 19} }, { l = {5, 12, 19, 12} } } };
	Icons['minus'] = { w = 2.2, s = { { l = {5, 12, 19, 12} } } };
	Icons['x'] = { w = 2.2, s = { { l = {6, 6, 18, 18} }, { l = {18, 6, 6, 18} } } };

	Icons['magnifying-glass'] = { w = 2.2, s = {
		{ a = {10.5, 10.5, 6.6, 0, 360} },
		{ l = {15.4, 15.4, 20.2, 20.2} }
	} };

	Icons['floppy-disk'] = { w = 2, s = {
		{ q = {3.5, 3.5, 17, 17, 2.5} },
		{ p = { {8.5, 3.5}, {8.5, 8.5}, {15.5, 8.5}, {15.5, 3.5} } },
		{ q = {7.5, 12.5, 9, 8, 1} }
	} };

	Icons['trash-can'] = { w = 2, s = {
		{ l = {4.5, 6.5, 19.5, 6.5} },
		{ p = { {9.5, 6.5}, {9.5, 4}, {14.5, 4}, {14.5, 6.5} } },
		{ q = {6, 6.5, 12, 14, 2} },
		{ l = {10, 10.5, 10, 16.5} },
		{ l = {14, 10.5, 14, 16.5} }
	} };

	Icons['folder'] = { w = 2, s = {
		{ p = { {3, 20}, {3, 7}, {9, 7}, {11, 4.8}, {21, 4.8}, {21, 20}, {3, 20} } }
	} };

	Icons['file'] = { w = 2, s = {
		{ p = { {6.5, 3.5}, {14.5, 3.5}, {19.5, 8.5}, {19.5, 20.5}, {6.5, 20.5} }, c = true },
		{ p = { {14.5, 3.5}, {14.5, 8.5}, {19.5, 8.5} } },
		{ l = {9.5, 12.5, 16.5, 12.5} , w = 1.8 },
		{ l = {9.5, 16, 14.5, 16} , w = 1.8 }
	} };

	Icons['user'] = { w = 2, s = {
		{ a = {12, 8.3, 3.6, 0, 360} },
		{ a = {12, 15.4, 6.6, 180, 360} },
		{ l = {5.4, 15.4, 5.4, 20.5} },
		{ l = {18.6, 15.4, 18.6, 20.5} }
	} };

	Icons['shield'] = { w = 2, s = {
		{ p = { {12, 3.5}, {5.5, 6.2}, {5.5, 12} } },
		{ a = {12, 12, 6.5, 180, 0} },
		{ p = { {18.5, 12}, {18.5, 6.2}, {12, 3.5} } }
	} };

	Icons['key'] = { w = 2, s = {
		{ a = {7.8, 15.8, 3.9, 0, 360} },
		{ l = {10.4, 13.2, 19.5, 4.1} },
		{ l = {15.2, 8.4, 18.4, 11.6} }
	} };

	Icons['bell'] = { w = 2, s = {
		{ a = {12, 8.6, 5.9, 180, 360} },
		{ p = { {6.1, 8.6}, {6.1, 13}, {3.4, 17} } },
		{ p = { {17.9, 8.6}, {17.9, 13}, {20.6, 17} } },
		{ l = {3.4, 17, 20.6, 17} },
		{ a = {12, 18.6, 2.5, 0, 180} }
	} };

	Icons['palette'] = { w = 2, s = {
		{ a = {12, 12, 8.3, 0, 360} }
	}, f = {
		{ d = {8.6, 9.4, 1.5} }, { d = {13.4, 7.6, 1.5} }, { d = {16.6, 11.4, 1.5} }, { d = {10, 15.4, 1.5} }
	} };

	Icons['sliders'] = { w = 2, s = {
		{ l = {4, 7.2, 12.2, 7.2} }, { l = {16.8, 7.2, 20, 7.2} },
		{ l = {4, 12, 6.2, 12} }, { l = {10.8, 12, 20, 12} },
		{ l = {4, 16.8, 13.7, 16.8} }, { l = {18.3, 16.8, 20, 16.8} },
		{ a = {14.5, 7.2, 2.1, 0, 360} },
		{ a = {8.5, 12, 2.1, 0, 360} },
		{ a = {16, 16.8, 2.1, 0, 360} }
	} };

	Icons['home'] = { w = 2, s = {
		{ p = { {3.5, 11.2}, {12, 3.8}, {20.5, 11.2} } },
		{ p = { {5.8, 9.6}, {5.8, 20.2}, {18.2, 20.2}, {18.2, 9.6} } },
		{ q = {9.9, 14.2, 4.2, 6, 1} }
	} };

	Icons['globe'] = { w = 2, s = {
		{ a = {12, 12, 8.2, 0, 360} },
		{ l = {3.8, 12, 20.2, 12} },
		{ e = {12, 12, 3.9, 8.2, 90, 270} },
		{ e = {12, 12, 3.9, 8.2, 270, 450} }
	} };

	Icons['terminal'] = { w = 2, s = {
		{ q = {3, 4.5, 18, 15, 2.5} },
		{ p = { {6.8, 8.5}, {10.3, 12}, {6.8, 15.5} } },
		{ l = {12, 15.5, 16.8, 15.5} }
	} };

	Icons['alert'] = { w = 2, s = {
		{ p = { {12, 3.6}, {21.2, 19.6}, {2.8, 19.6} }, c = true },
		{ l = {12, 9.8, 12, 14} }
	}, f = {
		{ d = {12, 16.9, 1.3} }
	} };

	Icons['info'] = { w = 2, s = {
		{ a = {12, 12, 8.2, 0, 360} },
		{ l = {12, 11.6, 12, 16.4} }
	}, f = {
		{ d = {12, 8.4, 1.4} }
	} };

	Icons['heart'] = { w = 2, s = {
		{ a = {7.6, 9.7, 4.8, 270, -90} },
		{ a = {16.4, 9.7, 4.8, 270, 450} },
		{ p = { {7.6, 4.9}, {12, 8.6}, {16.4, 4.9} } },
		{ p = { {7.6, 14.5}, {12, 19.6}, {16.4, 14.5} } }
	} };

	Icons['star'] = { w = 2, s = {
		{ p = { {12, 3.6}, {14.23, 9.53}, {20.56, 9.82}, {15.61, 13.77}, {17.29, 19.88}, {12, 16.4}, {6.71, 19.88}, {8.39, 13.77}, {3.44, 9.82}, {9.77, 9.53} }, c = true }
	} };

	Icons['lock'] = { w = 2, s = {
		{ a = {12, 11.2, 3.7, 180, 360} },
		{ q = {5.3, 11.2, 13.4, 9.6, 2} }
	}, f = {
		{ d = {12, 16, 1.5} }
	} };

	Icons['clock'] = { w = 2, s = {
		{ a = {12, 12, 8.2, 0, 360} },
		{ p = { {12, 7.4}, {12, 12.8}, {15.4, 14.8} } }
	} };

	Icons['eye'] = { w = 2, s = {
		{ e = {12, 12, 8.6, 6.6, 180, 360} },
		{ e = {12, 12, 8.6, 5, 180, 0} },
		{ a = {12, 12, 2.7, 0, 360} }
	}, f = {
		{ d = {12, 12, 1.1} }
	} };

	Icons['refresh'] = { w = 2, s = {
		{ a = {12, 12, 7.9, 50, 360} },
		{ p = { {16.9, 8.9}, {19.9, 12}, {16.9, 15.1} } }
	} };

	Icons['download'] = { w = 2, s = {
		{ l = {12, 4.4, 12, 13.6} },
		{ p = { {7.2, 10}, {12, 14.8}, {16.8, 10} } },
		{ p = { {4.6, 15}, {4.6, 19.4}, {19.4, 19.4}, {19.4, 15} } }
	} };

	Icons['upload'] = { w = 2, s = {
		{ l = {12, 14.6, 12, 4.6} },
		{ p = { {7.2, 9.4}, {12, 4.6}, {16.8, 9.4} } },
		{ p = { {4.6, 15}, {4.6, 19.4}, {19.4, 19.4}, {19.4, 15} } }
	} };

	Icons['image'] = { w = 2, s = {
		{ q = {3.5, 4.5, 17, 15, 2.5} },
		{ p = { {6.3, 17.3}, {10.8, 12.6}, {13.8, 15.6}, {15.9, 13.6}, {19.3, 17} } }
	}, f = {
		{ d = {8.8, 9.4, 1.7} }
	} };

	Icons['message'] = { w = 2, s = {
		{ q = {3.5, 4.5, 17, 13, 2.5} },
		{ p = { {8, 17.5}, {8, 21}, {12, 17.5} } }
	} };

	Icons['zap'] = { w = 2, s = {
		{ p = { {12.8, 3}, {5.8, 13.4}, {11, 13.4}, {10.4, 21}, {18.2, 10.4}, {12.9, 10.4} }, c = true }
	} };

	Icons['flame'] = { w = 2, s = {
		{ a = {12, 14.2, 7.6, 300, 600} },
		{ p = { {8.2, 7.63}, {12, 3.2}, {15.8, 7.63} } },
		{ a = {12, 16, 3.6, 140, 400} }
	} };

	Icons['gamepad'] = { w = 2, s = {
		{ q = {2.8, 7.5, 18.4, 9.5, 4.7} },
		{ l = {7, 10.4, 7, 14.1} },
		{ l = {5.15, 12.25, 8.85, 12.25} }
	}, f = {
		{ d = {15.6, 11.2, 1.15} }, { d = {18.2, 13.4, 1.15} }
	} };

	Icons['monitor'] = { w = 2, s = {
		{ q = {3, 4.3, 18, 12.4, 2} },
		{ l = {12, 16.7, 12, 19.6} },
		{ l = {8.4, 19.6, 15.6, 19.6} }
	} };

	Icons['list'] = { w = 2, s = {
		{ l = {8.6, 6.6, 20, 6.6} }, { l = {8.6, 12, 20, 12} }, { l = {8.6, 17.4, 20, 17.4} }
	}, f = {
		{ d = {4.9, 6.6, 1.25} }, { d = {4.9, 12, 1.25} }, { d = {4.9, 17.4, 1.25} }
	} };

	Icons['menu'] = { w = 2, s = {
		{ l = {4, 7, 20, 7} }, { l = {4, 12, 20, 12} }, { l = {4, 17, 20, 17} }
	} };

	Icons['wifi'] = { w = 2, s = {
		{ a = {12, 18.2, 4.8, 215, 325} },
		{ a = {12, 18.2, 8.2, 215, 325} },
		{ a = {12, 18.2, 11.6, 215, 325} }
	}, f = {
		{ d = {12, 18.2, 1.5} }
	} };

	Icons['bug'] = { w = 2, s = {
		{ e = {12, 13, 5.4, 6.6, 0, 360} },
		{ l = {12, 6.4, 12, 19.6} },
		{ p = { {9.3, 7}, {7.4, 4.6} } },
		{ p = { {14.7, 7}, {16.6, 4.6} } },
		{ l = {6.6, 10.8, 3.6, 10} },
		{ l = {6.6, 14.6, 3.6, 15.6} },
		{ l = {17.4, 10.8, 20.4, 10} },
		{ l = {17.4, 14.6, 20.4, 15.6} }
	} };

	Icons['cloud'] = { w = 2, s = {
		{ a = {9.2, 13.6, 3.9, 90, 270} },
		{ a = {14.3, 11.6, 5.2, 270, 450} },
		{ p = { {9.2, 9.7}, {11, 7.6}, {13, 6.6}, {14.3, 6.4} } },
		{ l = {5.4, 17.4, 18.6, 17.4} }
	} };

	Icons['cpu'] = { w = 2, s = {
		{ q = {6.4, 6.4, 11.2, 11.2, 1.8} },
		{ q = {10, 10, 4, 4, 0.8} },
		{ l = {9.2, 3.4, 9.2, 6.4} }, { l = {14.8, 3.4, 14.8, 6.4} },
		{ l = {9.2, 17.6, 9.2, 20.6} }, { l = {14.8, 17.6, 14.8, 20.6} },
		{ l = {3.4, 9.2, 6.4, 9.2} }, { l = {3.4, 14.8, 6.4, 14.8} },
		{ l = {17.6, 9.2, 20.6, 9.2} }, { l = {17.6, 14.8, 20.6, 14.8} }
	} };

	Icons['logout'] = { w = 2, s = {
		{ p = { {11.5, 4}, {5.8, 4}, {5.8, 20}, {11.5, 20} } },
		{ l = {9, 12, 20.4, 12} },
		{ p = { {17.4, 8.9}, {20.5, 12}, {17.4, 15.1} } }
	} };

	Icons['exit-rect'] = { w = 2, s = {
		{ q = {3.5, 4.5, 10.5, 15, 2} },
		{ l = {6.5, 12, 20.4, 12} },
		{ p = { {17.4, 8.9}, {20.5, 12}, {17.4, 15.1} } }
	} };

	Icons['play'] = { w = 2, s = {
		{ p = { {8.6, 5.6}, {18.4, 12}, {8.6, 18.4} }, c = true }
	} };

	Icons['pause'] = { w = 2.2, s = {
		{ l = {9.4, 6, 9.4, 18} }, { l = {14.6, 6, 14.6, 18} }
	} };

	Icons['crosshair'] = { w = 2, s = {
		{ a = {12, 12, 7.6, 0, 360} },
		{ l = {12, 3.2, 12, 6.4} }, { l = {12, 17.6, 12, 20.8} },
		{ l = {3.2, 12, 6.4, 12} }, { l = {17.6, 12, 20.8, 12} }
	}, f = {
		{ d = {12, 12, 1.2} }
	} };

	Icons['copy'] = { w = 2, s = {
		{ q = {8.6, 8.6, 11.8, 11.8, 2} },
		{ p = { {15.6, 8.6}, {15.6, 4.6}, {4.6, 4.6}, {4.6, 15.6}, {8.6, 15.6} } }
	} };

	Icons['edit'] = { w = 2, s = {
		{ p = { {15.2, 4.8}, {19.2, 8.8}, {7.8, 20.2}, {3.6, 20.4}, {3.8, 16.2} }, c = true },
		{ l = {14.2, 5.8, 18.2, 9.8} }
	} };

	Icons['skull'] = { w = 2, s = {
		{ a = {12, 10.6, 7.7, 0, 360} },
		{ l = {9.6, 18.3, 9.6, 21} }, { l = {12, 18.3, 12, 21.2} }, { l = {14.4, 18.3, 14.4, 21} }
	}, f = {
		{ d = {9.3, 10.2, 1.5} }, { d = {14.7, 10.2, 1.5} }, { d = {12, 13.6, 1.2} }
	} };

	Icons['ghost'] = { w = 2, s = {
		{ a = {12, 12.4, 8, 180, 360} },
		{ l = {4, 12.4, 4, 19.4} }, { l = {20, 12.4, 20, 19.4} },
		{ p = { {4, 19.4}, {6.7, 16.6}, {9.3, 19.4}, {12, 16.6}, {14.6, 19.4}, {17.3, 16.6}, {20, 19.4} } }
	}, f = {
		{ d = {9.3, 11.4, 1.5} }, { d = {14.7, 11.4, 1.5} }
	} };

	-- Friendly aliases
	Icons['settings'] = Icons['gear'];
	Icons['search'] = Icons['magnifying-glass'];
	Icons['save'] = Icons['floppy-disk'];
	Icons['trash'] = Icons['trash-can'];
	Icons['plus'] = Icons['plus-large'];
	Icons['cross'] = Icons['x'];
	Icons['close'] = Icons['x'];
	Icons['dots'] = Icons['three-dots-horizontal'];
	Icons['target'] = Icons['crosshair'];
	Icons['crosshairs'] = Icons['crosshair'];
	Icons['paint'] = Icons['palette'];
	Icons['chat'] = Icons['message'];
	Icons['image-icon'] = Icons['image'];
	Icons['rotate'] = Icons['refresh'];
	Icons['rotate-cw'] = Icons['refresh'];
	Icons['sword'] = Icons['zap'];
	Icons['log-out'] = Icons['logout'];
	Icons['log-in'] = Icons['logout'];
	Icons['grid'] = Icons['gamepad'];
	Icons['list-check'] = Icons['list'];
end;

-- Heavier stroke variant for "<name>-bold" icon requests
function Phobia.Icons.BoldVariant(Spec)
	local Copy = { w = (Spec.w or 2) * 1.3 , s = {} , f = Spec.f };

	for i , Stroke in ipairs(Spec.s or {}) do
		local Clone = {};

		for Key , Value in pairs(Stroke) do
			Clone[Key] = Value;
		end;

		Clone.w = (Stroke.w or Spec.w or 2) * 1.3;
		Copy.s[i] = Clone;
	end;

	return Copy;
end;

--// Vector rendering primitives ----------------------------------------------------------

-- Expands an icon spec into primitive ops (grid space)
local function IconOps(Spec)
	local Ops = {};

	local function PushPolyline(Pts , Width , Close)
		local Count = #Pts;

		if Count < 2 then
			return;
		end;

		Ops[#Ops + 1] = { t = 's' , p = Pts , w = Width , c = Close };

		if Close then
			Ops[#Ops + 1] = { t = 's' , p = { Pts[Count] , Pts[1] } , w = Width };
		end;
	end;

	local function ArcPoints(cx , cy , rx , ry , a0 , a1 , Width)
		local Sweep = math.abs(a1 - a0);
		local AvgR = (rx + ry) / 2;
		local ArcLen = Sweep / 180 * math.pi * AvgR;
		local Steps = math.max(2 , math.ceil(ArcLen / 2.2));
		local Pts = {};

		for i = 0 , Steps do
			local Ang = math.rad(a0 + (a1 - a0) * i / Steps);
			Pts[#Pts + 1] = { cx + rx * math.cos(Ang) , cy + ry * math.sin(Ang) };
		end;

		PushPolyline(Pts , Width , false);
	end;

	local function RoundedRectPoints(x , y , w , h , r)
		r = math.min(r or 0 , w / 2 , h / 2);
		local x2 , y2 = x + w , y + h;
		local Pts = {};

		local function Corner(cx , cy , a0 , a1)
			for i = 0 , 3 do
				local Ang = math.rad(a0 + (a1 - a0) * i / 3);
				Pts[#Pts + 1] = { cx + r * math.cos(Ang) , cy + r * math.sin(Ang) };
			end;
		end;

		if r <= 0.01 then
			Pts[#Pts + 1] = { x , y };
			Pts[#Pts + 1] = { x2 , y };
			Pts[#Pts + 1] = { x2 , y2 };
			Pts[#Pts + 1] = { x , y2 };
			Pts[#Pts + 1] = { x , y };
		else
			Pts[#Pts + 1] = { x + r , y };
			Pts[#Pts + 1] = { x2 - r , y };
			Corner(x2 - r , y + r , 270 , 360);
			Pts[#Pts + 1] = { x2 , y2 - r };
			Corner(x2 - r , y2 - r , 0 , 90);
			Pts[#Pts + 1] = { x + r , y2 };
			Corner(x + r , y2 - r , 90 , 180);
			Pts[#Pts + 1] = { x , y + r };
			Corner(x + r , y + r , 180 , 270);
		end;

		return Pts;
	end;

	for _ , Stroke in ipairs(Spec.s or {}) do
		local Width = Stroke.w or Spec.w or 2;

		if Stroke.p then
			PushPolyline(Stroke.p , Width , Stroke.c == true);
		elseif Stroke.l then
			local L = Stroke.l;
			PushPolyline({ { L[1] , L[2] } , { L[3] , L[4] } } , Width , false);
		elseif Stroke.a then
			local A = Stroke.a;
			ArcPoints(A[1] , A[2] , A[3] , A[3] , A[4] , A[5] , Width);
		elseif Stroke.e then
			local E = Stroke.e;
			ArcPoints(E[1] , E[2] , E[3] , E[4] , E[5] , E[6] , Width);
		elseif Stroke.q then
			local Q = Stroke.q;
			PushPolyline(RoundedRectPoints(Q[1] , Q[2] , Q[3] , Q[4] , Q[5]) , Width , false);
		end;
	end;

	for _ , Fill in ipairs(Spec.f or {}) do
		if Fill.d then
			Ops[#Ops + 1] = { t = 'd' , x = Fill.d[1] , y = Fill.d[2] , r = Fill.d[3] };
		elseif Fill.r then
			Ops[#Ops + 1] = { t = 'r' , x = Fill.r[1] , y = Fill.r[2] , w = Fill.r[3] , h = Fill.r[4] , rad = Fill.r[5] or 0 };
		end;
	end;

	return Ops;
end;

Phobia.IconRecords = setmetatable({} , { __mode = 'k' });

-- Removes a previously drawn icon from a container
function Phobia.Icons.Clear(Target)
	for _ , Child in ipairs(Target:GetChildren()) do
		if Child:GetAttribute('PhobiaIconDrawn') then
			Phobia.IconRecords[Target] = nil;
			Child:Destroy();
		end;
	end;
end;

-- Draws an icon into any Frame / TextLabel / TextButton / ImageButton
-- Opts: { Size = px, Color = Color3, Transparency = number, ZIndex = number, OffsetX, OffsetY }
function Phobia:ApplyIcon(Target , Name , Opts)
	if typeof(Target) ~= 'Instance' then
		return nil;
	end;

	Opts = Opts or {};
	Phobia.Icons.Clear(Target);

	if type(Name) ~= 'string' then
		return nil;
	end;

	local Bold = false;
	local Lower = string.lower(Name);

	if string.sub(Lower , -5) == '-bold' then
		Bold = true;
		Name = string.sub(Name , 1 , -6);
	end;

	local Spec = Phobia.Icons[Name];

	if not Spec then
		return nil;
	end;

	if Bold then
		Spec = Phobia.Icons.BoldVariant(Spec);
	end;

	local Size = Opts.Size or 16;
	local Color = Opts.Color;

	if not Color and (Target:IsA('TextLabel') or Target:IsA('TextButton')) then
		Color = Target.TextColor3;
	end;

	Color = Color or Phobia.IconColor;

	local Transparency = Opts.Transparency;

	if Transparency == nil and Target:IsA('TextLabel') then
		Transparency = Target.TextTransparency;
	end;

	Transparency = Transparency or 0;

	if Target:IsA('TextLabel') or Target:IsA('TextButton') then
		Target.Text = '';
	end;

	local BaseZ = Opts.ZIndex or Target.ZIndex or 1;

	local Holder = Instance.new('Frame');
	Holder.Name = 'PhobiaIcon_' .. Name;
	Holder.AnchorPoint = Vector2.new(0.5 , 0.5);
	Holder.Position = UDim2.fromScale(0.5 , 0.5);
	Holder.Size = UDim2.fromOffset(Size , Size);
	Holder.BackgroundTransparency = 1;
	Holder.BorderSizePixel = 0;
	Holder.ZIndex = BaseZ;
	Holder:SetAttribute('PhobiaIconDrawn' , true);
	Holder:SetAttribute('PhobiaIconName' , Name);
	-- adapter flags (PlayAnimate routes icon tweens through the vector values)
	Target:SetAttribute('PhobiaIconDrawn' , true);
	Target:SetAttribute('PhobiaIconName' , Name);

	local TValue = Instance.new('NumberValue');
	TValue.Name = '_TransparencyValue';
	TValue.Value = Transparency;
	TValue.Parent = Holder;

	local CValue = Instance.new('Color3Value');
	CValue.Name = '_ColorValue';
	CValue.Value = Color;
	CValue.Parent = Holder;

	local Frames = {};
	local K = Size / GRID;
	local Ops = IconOps(Spec);

	local function MakeSeg(Cx , Cy , Len , Rot , Width)
		local Frame = Instance.new('Frame');
		Frame.Name = 's';
		Frame.AnchorPoint = Vector2.new(0.5 , 0.5);
		Frame.Position = UDim2.fromOffset(Cx , Cy);
		Frame.Size = UDim2.fromOffset(math.max(Len , 0.1) , Width);
		Frame.Rotation = Rot;
		Frame.BackgroundColor3 = Color;
		Frame.BackgroundTransparency = Transparency;
		Frame.BorderSizePixel = 0;
		Frame.ZIndex = BaseZ + 1;

		local Corner = Instance.new('UICorner');
		Corner.CornerRadius = UDim.new(1 , 0);
		Corner.Parent = Frame;

		Frame.Parent = Holder;
		Frames[#Frames + 1] = Frame;
	end;

	local function MakeDot(Cx , Cy , D)
		local Frame = Instance.new('Frame');
		Frame.Name = 'd';
		Frame.AnchorPoint = Vector2.new(0.5 , 0.5);
		Frame.Position = UDim2.fromOffset(Cx , Cy);
		Frame.Size = UDim2.fromOffset(math.max(D , 0.6) , math.max(D , 0.6));
		Frame.BackgroundColor3 = Color;
		Frame.BackgroundTransparency = Transparency;
		Frame.BorderSizePixel = 0;
		Frame.ZIndex = BaseZ + 1;

		local Corner = Instance.new('UICorner');
		Corner.CornerRadius = UDim.new(1 , 0);
		Corner.Parent = Frame;

		Frame.Parent = Holder;
		Frames[#Frames + 1] = Frame;
	end;

	local function MakeRect(X , Y , W , H , Rad)
		local Frame = Instance.new('Frame');
		Frame.Name = 'r';
		Frame.Position = UDim2.fromOffset(X , Y);
		Frame.Size = UDim2.fromOffset(math.max(W , 0.6) , math.max(H , 0.6));
		Frame.BackgroundColor3 = Color;
		Frame.BackgroundTransparency = Transparency;
		Frame.BorderSizePixel = 0;
		Frame.ZIndex = BaseZ + 1;

		if Rad and Rad > 0.01 then
			local Corner = Instance.new('UICorner');
			Corner.CornerRadius = UDim.new(0 , Rad * K);
			Corner.Parent = Frame;
		end;

		Frame.Parent = Holder;
		Frames[#Frames + 1] = Frame;
	end;

	for _ , Op in ipairs(Ops) do
		if Op.t == 's' then
			local Pts = Op.p;
			local Width = math.max(Op.w * K , 1);

			for i = 1 , (#Pts - 1) do
				local x1 , y1 = Pts[i][1] * K , Pts[i][2] * K;
				local x2 , y2 = Pts[i + 1][1] * K , Pts[i + 1][2] * K;
				local dx , dy = x2 - x1 , y2 - y1;
				local Len = math.sqrt(dx * dx + dy * dy);

				if Len > 0.05 then
					MakeSeg((x1 + x2) / 2 , (y1 + y2) / 2 , Len , math.deg(math.atan2(dy , dx)) , Width);
				end;
			end;
		elseif Op.t == 'd' then
			MakeDot(Op.x * K , Op.y * K , Op.r * 2 * K);
		elseif Op.t == 'r' then
			MakeRect(Op.x * K , Op.y * K , Op.w * K , Op.h * K , Op.rad);
		end;
	end;

	Holder.Parent = Target;

	local Record = {
		Name = Name,
		Root = Holder,
		Value = TValue,
		ColorValue = CValue,
		Frames = Frames,
		SetColor = function(_, C)
			CValue.Value = C;
		end,
		SetTransparency = function(_, T)
			TValue.Value = T;
		end,
		Destroy = function(_)
			Phobia.IconRecords[Target] = nil;
			Holder:Destroy();
		end
	};

	TValue.Changed:Connect(function(V)
		V = math.clamp(V , 0 , 1);

		for _ , Frame in ipairs(Frames) do
			Frame.BackgroundTransparency = V;
		end;
	end);

	CValue.Changed:Connect(function(V)
		for _ , Frame in ipairs(Frames) do
			Frame.BackgroundColor3 = V;
		end;
	end);

	Phobia.IconRecords[Target] = Record;

	return Record;
end;

-- TweenService adapter: lets the UI tween drawn icons exactly like text icons
-- (PlayAnimate on an icon container handles TextTransparency / ImageTransparency / TextColor3)
function Phobia.Icons.Animate(Target , Info , Property)
	local Record = Phobia.IconRecords[Target];

	if not Record then
		return nil;
	end;

	local Fallback = Info or TweenInfo.new(0.25);
	local MainTween = nil;
	local Others = nil;

	for Key , Value in pairs(Property) do
		if Key == 'TextTransparency' or Key == 'ImageTransparency' then
			local TweenA = TweenService:Create(Record.Value , Fallback , { Value = Value });
			local TweenB = TweenService:Create(Target , Fallback , { [Key] = Value });

			TweenA:Play();
			TweenB:Play();

			MainTween = MainTween or TweenA;
		elseif Key == 'TextColor3' then
			local TweenA = TweenService:Create(Record.ColorValue , Fallback , { Value = Value });
			local TweenB = TweenService:Create(Target , Fallback , { TextColor3 = Value });

			TweenA:Play();
			TweenB:Play();

			MainTween = MainTween or TweenA;
		else
			Others = Others or {};
			Others[Key] = Value;
		end;
	end;

	if Others then
		local TweenC = TweenService:Create(Target , Fallback , Others);

		TweenC:Play();

		MainTween = MainTween or TweenC;
	end;

	return MainTween;
end;


function Phobia:AddSignal(RBXSignal)
	if Phobia.UnloadEnabled then
		table.insert(Phobia.GlobalSignals,RBXSignal);
	end;

	return RBXSignal;
end;

function Phobia:AddQuery(ItemRoot: Frame , Name : string)
	table.insert(Phobia.NameRegisitry , {
		Root = ItemRoot,
		Idx = Name,
	});
end;

function Encryption.new(data: string)
	local bytes = {};
	local encrypt_seed = ((#data + 3782) % 111) + 1;

	string.gsub(data , '.', LPH_NO_VIRTUALIZE(function(dt)
		table.insert(bytes , tostring(dt:byte() + encrypt_seed));
	end));

	local concatbyte = table.concat(bytes,'?');

	table.clear(bytes);

	return "{"..tostring(encrypt_seed + 72667).."}?"..concatbyte;
end;

function Encryption.reverse(data: string)
	local main_data = string.split(data,'?');
	local seed_str = main_data[1]:gsub('{',''):gsub('}','');
	local seed = tonumber(seed_str) or 0;

	local ks = {};
	local real_seed = seed - 72667;

	for i,v in next , main_data do
		if i > 1 then
			local fake_byte = tonumber(v);
			table.insert(ks , string.char(fake_byte - real_seed))	
		end;
	end;

	local data = table.concat(ks);

	table.clear(ks);

	return data;
end;

do
	local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

	Phobia.Base64Encode = LPH_NO_VIRTUALIZE(function(data)
		return ((data:gsub('.', function(x) 
			local r,b='',x:byte()
			for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
			return r;
		end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
			if (#x < 6) then return '' end
			local c=0
			for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
			return b:sub(c+1,c+1)
		end)..({ '', '==', '=' })[#data%3+1])
	end);

	Phobia.Base64Decode = LPH_NO_VIRTUALIZE(function(data)
		data = string.gsub(data, '[^'..b..'=]', '')
		return (data:gsub('.', function(x)
			if (x == '=') then return '' end
			local r,f='',(b:find(x)-1)
			for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
			return r;
		end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
			if (#x ~= 8) then return '' end
			local c=0
			for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
			return string.char(c)
		end))
	end);
end;

Phobia.LoadIcon = LPH_NO_VIRTUALIZE(function()
	Phobia.RobloxIcon = {
		["3d-cube-arrow-left"] = "3d-cube-arrow-left",
		["amazon"] = "amazon",
		["arm-left"] = "arm-left",
		["arm-right"] = "arm-right",
		["arrow-curl-to-left"] = "arrow-curl-to-left",
		["arrow-curl-to-right"] = "arrow-curl-to-right",
		["arrow-down-to-line"] = "arrow-down-to-line",
		["arrow-large-down"] = "arrow-large-down",
		["arrow-large-left"] = "arrow-large-left",
		["arrow-large-right"] = "arrow-large-right",
		["arrow-large-up"] = "arrow-large-up",
		["arrow-right-from-portrait-rectangle"] = "arrow-right-from-portrait-rectangle",
		["arrow-right-to-portrait-rectangle"] = "arrow-right-to-portrait-rectangle",
		["arrow-rotate-down-dashed"] = "arrow-rotate-down-dashed",
		["arrow-rotate-right"] = "arrow-rotate-right",
		["arrow-rotate-right-dashed"] = "arrow-rotate-right-dashed",
		["arrow-small-down"] = "arrow-small-down",
		["arrow-small-left"] = "arrow-small-left",
		["arrow-small-right"] = "arrow-small-right",
		["arrow-small-up"] = "arrow-small-up",
		["arrow-spin-clockwise"] = "arrow-spin-clockwise",
		["arrow-spin-clockwise-10"] = "arrow-spin-clockwise-10",
		["arrow-spin-clockwise-15"] = "arrow-spin-clockwise-15",
		["arrow-spin-clockwise-30"] = "arrow-spin-clockwise-30",
		["arrow-spin-counter-clockwise-10"] = "arrow-spin-counter-clockwise-10",
		["arrow-spin-counter-clockwise-15"] = "arrow-spin-counter-clockwise-15",
		["arrow-spin-counter-clockwise-30"] = "arrow-spin-counter-clockwise-30",
		["arrow-thick-to-left"] = "arrow-thick-to-left",
		["arrow-thick-to-right"] = "arrow-thick-to-right",
		["arrow-up-from-landscape-rectangle"] = "arrow-up-from-landscape-rectangle",
		["arrow-up-right-from-square"] = "arrow-up-right-from-square",
		["arrow-wide-short-down"] = "arrow-wide-short-down",
		["arrow-wide-short-left"] = "arrow-wide-short-left",
		["arrow-wide-short-right"] = "arrow-wide-short-right",
		["arrow-wide-short-up"] = "arrow-wide-short-up",
		["arrows-small-directional"] = "arrows-small-directional",
		["audio-wave-dotted-line"] = "audio-wave-dotted-line",
		["backpack"] = "backpack",
		["beard"] = "beard",
		["bell"] = "bell",
		["bell-clock"] = "bell-clock",
		["bell-plus"] = "bell-plus",
		["bell-slash"] = "bell-slash",
		["belt"] = "belt",
		["binoculars"] = "binoculars",
		["book-closed"] = "book-closed",
		["bookmark"] = "bookmark",
		["bow-tie"] = "bow-tie",
		["building-store"] = "building-store",
		["bullet-flying"] = "bullet-flying",
		["butterfly-wings"] = "butterfly-wings",
		["calendar"] = "calendar",
		["calendar-plus"] = "calendar-plus",
		["calendar-star"] = "calendar-star",
		["camera-small"] = "camera-small",
		["caret-small-down"] = "caret-small-down",
		["caret-small-left"] = "caret-small-left",
		["caret-small-right"] = "caret-small-right",
		["caret-small-up"] = "caret-small-up",
		["chain-link"] = "chain-link",
		["chart-four-vertical-bars"] = "chart-four-vertical-bars",
		["chart-line"] = "chart-line",
		["chart-pie"] = "chart-pie",
		["chart-scatter-plot"] = "chart-scatter-plot",
		["chart-three-vertical-bars"] = "chart-three-vertical-bars",
		["check"] = "check",
		["check-large"] = "check-large",
		["check-small"] = "check-small",
		["chevron-large-down"] = "chevron-large-down",
		["chevron-large-down-to-line"] = "chevron-large-down-to-line",
		["chevron-large-left"] = "chevron-large-left",
		["chevron-large-left-to-line"] = "chevron-large-left-to-line",
		["chevron-large-right"] = "chevron-large-right",
		["chevron-large-right-to-line"] = "chevron-large-right-to-line",
		["chevron-large-up"] = "chevron-large-up",
		["chevron-large-up-to-line"] = "chevron-large-up-to-line",
		["chevron-small-down"] = "chevron-small-down",
		["chevron-small-down-to-line"] = "chevron-small-down-to-line",
		["chevron-small-left"] = "chevron-small-left",
		["chevron-small-left-to-line"] = "chevron-small-left-to-line",
		["chevron-small-right"] = "chevron-small-right",
		["chevron-small-right-to-line"] = "chevron-small-right-to-line",
		["chevron-small-up"] = "chevron-small-up",
		["chevron-small-up-to-line"] = "chevron-small-up-to-line",
		["circle-check"] = "circle-check",
		["circle-i"] = "circle-i",
		["circle-minus"] = "circle-minus",
		["circle-person"] = "circle-person",
		["circle-person-three-horizontal-bars-wrapping-right"] = "circle-person-three-horizontal-bars-wrapping-right",
		["circle-play"] = "circle-play",
		["circle-plus"] = "circle-plus",
		["circle-question"] = "circle-question",
		["circle-slash"] = "circle-slash",
		["circle-star"] = "circle-star",
		["circle-three-dots-horizontal"] = "circle-three-dots-horizontal",
		["circle-three-dots-vertical"] = "circle-three-dots-vertical",
		["circle-x"] = "circle-x",
		["clock"] = "clock",
		["clock-dashed"] = "clock-dashed",
		["clock-spin-reverse"] = "clock-spin-reverse",
		["clock-spin-reverse-dashed"] = "clock-spin-reverse-dashed",
		["clothes-hanger"] = "clothes-hanger",
		["cloud"] = "cloud",
		["cloud-arrow-down"] = "cloud-arrow-down",
		["code"] = "code",
		["compact-makeup-brush"] = "compact-makeup-brush",
		["compass"] = "compass",
		["controller-with-cog"] = "controller-with-cog",
		["crop"] = "crop",
		["crosshairs"] = "crosshairs",
		["crosshairs-slash"] = "crosshairs-slash",
		["cube-vertexes"] = "cube-vertexes",
		["curved-rectangle-megaphone"] = "curved-rectangle-megaphone",
		["diagonal-line-pattern"] = "diagonal-line-pattern",
		["diagonal-line-pattern-sticker"] = "diagonal-line-pattern-sticker",
		["diamond-simplified"] = "diamond-simplified",
		["discord"] = "discord",
		["disguise-nose-glasses"] = "disguise-nose-glasses",
		["document-circle-slash"] = "document-circle-slash",
		["document-list-heart"] = "document-list-heart",
		["door-open-arrow-to-bottom-right"] = "door-open-arrow-to-bottom-right",
		["dress"] = "dress",
		["dual-arrows-horizontal"] = "dual-arrows-horizontal",
		["dual-arrows-to-corners"] = "dual-arrows-to-corners",
		["dual-arrows-vertical"] = "dual-arrows-vertical",
		["envelope"] = "envelope",
		["eraser"] = "eraser",
		["eye"] = "eye",
		["eye-slash"] = "eye-slash",
		["eye-with-eyeliner"] = "eye-with-eyeliner",
		["eyebrows"] = "eyebrows",
		["eyelashes"] = "eyelashes",
		["face-winking"] = "face-winking",
		["facebook"] = "facebook",
		["file-box"] = "file-box",
		["fingerprint"] = "fingerprint",
		["flag"] = "flag",
		["flame"] = "flame",
		["folder"] = "folder",
		["fountain-pen-nib"] = "fountain-pen-nib",
		["four-bars-horizontal-center-aligned"] = "four-bars-horizontal-center-aligned",
		["four-bars-horizontal-chevron-left"] = "four-bars-horizontal-chevron-left",
		["four-bars-horizontal-chevron-right"] = "four-bars-horizontal-chevron-right",
		["four-bars-horizontal-justified-aligned"] = "four-bars-horizontal-justified-aligned",
		["four-bars-horizontal-left-aligned"] = "four-bars-horizontal-left-aligned",
		["four-bars-horizontal-right-aligned"] = "four-bars-horizontal-right-aligned",
		["frame-bubble-slash"] = "frame-bubble-slash",
		["frame-bubble-soundwave"] = "frame-bubble-soundwave",
		["frame-camera"] = "frame-camera",
		["frame-camera-center"] = "frame-camera-center",
		["frame-collapsed"] = "frame-collapsed",
		["frame-corners"] = "frame-corners",
		["frame-expanded"] = "frame-expanded",
		["frame-face"] = "frame-face",
		["frame-person-torso"] = "frame-person-torso",
		["frame-record"] = "frame-record",
		["frame-single-bar-horizontal"] = "frame-single-bar-horizontal",
		["frame-soundwave"] = "frame-soundwave",
		["frame-video-camera"] = "frame-video-camera",
		["gear"] = "gear",
		["generic-dpad"] = "generic-dpad",
		["gift-box"] = "gift-box",
		["gift-card"] = "gift-card",
		["glasses"] = "glasses",
		["globe-detailed"] = "globe-detailed",
		["globe-simplified"] = "globe-simplified",
		["globe-simplipfied-speech-bubble"] = "globe-simplipfied-speech-bubble",
		["grid"] = "grid",
		["guilded"] = "guilded",
		["hack-week"] = "hack-week",
		["hammer-code"] = "hammer-code",
		["hand-curved-arrow-left"] = "hand-curved-arrow-left",
		["hand-dual-arrows"] = "hand-dual-arrows",
		["hand-ellipse"] = "hand-ellipse",
		["hand-half-ellipse"] = "hand-half-ellipse",
		["hand-two-arrows-horizontal"] = "hand-two-arrows-horizontal",
		["hashtag"] = "hashtag",
		["hat-fedora"] = "hat-fedora",
		["hat-toque"] = "hat-toque",
		["head-blank"] = "head-blank",
		["head-blush"] = "head-blush",
		["head-female"] = "head-female",
		["head-freckles"] = "head-freckles",
		["head-lips"] = "head-lips",
		["head-male"] = "head-male",
		["headphones"] = "headphones",
		["headphones-arrow-up"] = "headphones-arrow-up",
		["headphones-arrow-up-lock"] = "headphones-arrow-up-lock",
		["headphones-slash"] = "headphones-slash",
		["headphones-x"] = "headphones-x",
		["headphones-x-lock"] = "headphones-x-lock",
		["heart"] = "heart",
		["house"] = "house",
		["image"] = "image",
		["image-stacked"] = "image-stacked",
		["instagram"] = "instagram",
		["jacket"] = "jacket",
		["key"] = "key",
		["key-alt"] = "key-alt",
		["key-apostrophe"] = "key-apostrophe",
		["key-arrow-down"] = "key-arrow-down",
		["key-arrow-right"] = "key-arrow-right",
		["key-arrow-up"] = "key-arrow-up",
		["key-asterisk"] = "key-asterisk",
		["key-backspace"] = "key-backspace",
		["key-caps-lock"] = "key-caps-lock",
		["key-caret"] = "key-caret",
		["key-comma"] = "key-comma",
		["key-command"] = "key-command",
		["key-control"] = "key-control",
		["key-grave-accent"] = "key-grave-accent",
		["key-period"] = "key-period",
		["key-return"] = "key-return",
		["key-shift"] = "key-shift",
		["key-space"] = "key-space",
		["key-tab"] = "key-tab",
		["language-characters"] = "language-characters",
		["leg-left"] = "leg-left",
		["leg-right"] = "leg-right",
		["lightning-bolt"] = "lightning-bolt",
		["linkedin"] = "linkedin",
		["lips"] = "lips",
		["lipstick"] = "lipstick",
		["list-bulleted"] = "list-bulleted",
		["location-pin"] = "location-pin",
		["location-pin-map"] = "location-pin-map",
		["lock-closed"] = "lock-closed",
		["lollipop"] = "lollipop",
		["magnifying-glass"] = "magnifying-glass",
		["magnifying-glass-minus"] = "magnifying-glass-minus",
		["magnifying-glass-plus"] = "magnifying-glass-plus",
		["mascara"] = "mascara",
		["megaphone"] = "megaphone",
		["memory-card"] = "memory-card",
		["messenger"] = "messenger",
		["microphone"] = "microphone",
		["microphone-slash"] = "microphone-slash",
		["microphone-text-box"] = "microphone-text-box",
		["microphone-triangle-exclamation"] = "microphone-triangle-exclamation",
		["minus"] = "minus",
		["minus-small"] = "minus-small",
		["mirror-standing"] = "mirror-standing",
		["moments"] = "moments",
		["moon"] = "moon",
		["mouse-button-left"] = "mouse-button-left",
		["mouse-button-right"] = "mouse-button-right",
		["mouse-scrollwheel"] = "mouse-scrollwheel",
		["music-note"] = "music-note",
		["nebula"] = "nebula",
		["necklace"] = "necklace",
		["nine-dots-grid"] = "nine-dots-grid",
		["ninja"] = "ninja",
		["nose"] = "nose",
		["page"] = "page",
		["paint-brush"] = "paint-brush",
		["paint-bucket"] = "paint-bucket",
		["pants"] = "pants",
		["pants-2d-text"] = "pants-2d-text",
		["paper-airplane"] = "paper-airplane",
		["parrot"] = "parrot",
		["pause-large"] = "pause-large",
		["pause-small"] = "pause-small",
		["pencil"] = "pencil",
		["pencil-square"] = "pencil-square",
		["person"] = "person",
		["person-arrow-from-bottom-right"] = "person-arrow-from-bottom-right",
		["person-check"] = "person-check",
		["person-circle-slash"] = "person-circle-slash",
		["person-climbing"] = "person-climbing",
		["person-clock"] = "person-clock",
		["person-falling"] = "person-falling",
		["person-graduate"] = "person-graduate",
		["person-jumping"] = "person-jumping",
		["person-magnifying-glass"] = "person-magnifying-glass",
		["person-photo-camera"] = "person-photo-camera",
		["person-play"] = "person-play",
		["person-play-clock"] = "person-play-clock",
		["person-plus"] = "person-plus",
		["person-racing"] = "person-racing",
		["person-running"] = "person-running",
		["person-standing"] = "person-standing",
		["person-standing-arrow-reverse"] = "person-standing-arrow-reverse",
		["person-standing-dual-arrows-vertical"] = "person-standing-dual-arrows-vertical",
		["person-standing-gear"] = "person-standing-gear",
		["person-swimming"] = "person-swimming",
		["person-teleport"] = "person-teleport",
		["person-trash-can"] = "person-trash-can",
		["person-walking"] = "person-walking",
		["person-with-smaller-person"] = "person-with-smaller-person",
		["phone"] = "phone",
		["phone-down"] = "phone-down",
		["phone-plus"] = "phone-plus",
		["phone-volume"] = "phone-volume",
		["phone-x"] = "phone-x",
		["photo-camera"] = "photo-camera",
		["photo-camera-face"] = "photo-camera-face",
		["photo-camera-slash"] = "photo-camera-slash",
		["picture-in-picture"] = "picture-in-picture",
		["pig"] = "pig",
		["pin"] = "pin",
		["pin-slash"] = "pin-slash",
		["play-large"] = "play-large",
		["play-small"] = "play-small",
		["plus-large"] = "plus-large",
		["plus-small"] = "plus-small",
		["premium"] = "premium",
		["ps-circle"] = "ps-circle",
		["ps-dpad-down"] = "ps-dpad-down",
		["ps-dpad-left"] = "ps-dpad-left",
		["ps-dpad-right"] = "ps-dpad-right",
		["ps-dpad-up"] = "ps-dpad-up",
		["ps-l1"] = "ps-l1",
		["ps-l2"] = "ps-l2",
		["ps-l3"] = "ps-l3",
		["ps-r1"] = "ps-r1",
		["ps-r2"] = "ps-r2",
		["ps-r3"] = "ps-r3",
		["ps-square"] = "ps-square",
		["ps-stick-left"] = "ps-stick-left",
		["ps-stick-right"] = "ps-stick-right",
		["ps-triagle"] = "ps-triagle",
		["ps-x"] = "ps-x",
		["ps4-options"] = "ps4-options",
		["ps4-share"] = "ps4-share",
		["ps4-touchpad"] = "ps4-touchpad",
		["ps5-options"] = "ps5-options",
		["ps5-share"] = "ps5-share",
		["ps5-touchpad"] = "ps5-touchpad",
		["pumpkin"] = "pumpkin",
		["purse"] = "purse",
		["rectangle-list"] = "rectangle-list",
		["rectangle-numbers-counting"] = "rectangle-numbers-counting",
		["rectangle-person-with-three-horizontal-lines"] = "rectangle-person-with-three-horizontal-lines",
		["robux"] = "robux",
		["rosette-seven-point"] = "rosette-seven-point",
		["rosette-ten-point"] = "rosette-ten-point",
		["seven-point-rosette"] = "seven-point-rosette",
		["shield-check"] = "shield-check",
		["shield-lock"] = "shield-lock",
		["shirt"] = "shirt",
		["shirt-2d-text"] = "shirt-2d-text",
		["shirt-pants"] = "shirt-pants",
		["shoe-left"] = "shoe-left",
		["shoe-right"] = "shoe-right",
		["shopping-basket"] = "shopping-basket",
		["shopping-basket-check"] = "shopping-basket-check",
		["shopping-cart"] = "shopping-cart",
		["shorts"] = "shorts",
		["sidebar"] = "sidebar",
		["signal-exclamation"] = "signal-exclamation",
		["six-dots-two-column-grid"] = "six-dots-two-column-grid",
		["skip-end-large"] = "skip-end-large",
		["skip-end-small"] = "skip-end-small",
		["skip-next-large"] = "skip-next-large",
		["skip-next-small"] = "skip-next-small",
		["skip-previous-large"] = "skip-previous-large",
		["skip-previous-small"] = "skip-previous-small",
		["skip-start-large"] = "skip-start-large",
		["skip-start-small"] = "skip-start-small",
		["smartphone-portrait"] = "smartphone-portrait",
		["speaker"] = "speaker",
		["speaker-slash"] = "speaker-slash",
		["speaker-triangle-exclamation"] = "speaker-triangle-exclamation",
		["speaker-x"] = "speaker-x",
		["speech-bubble-align-center"] = "speech-bubble-align-center",
		["speech-bubble-align-left"] = "speech-bubble-align-left",
		["speech-bubble-exclamation"] = "speech-bubble-exclamation",
		["speech-bubble-round"] = "speech-bubble-round",
		["square-bone"] = "square-bone",
		["square-books"] = "square-books",
		["square-check"] = "square-check",
		["square-code"] = "square-code",
		["square-dashed-person-standing"] = "square-dashed-person-standing",
		["square-dual-arrows-horizontal"] = "square-dual-arrows-horizontal",
		["square-dual-arrows-to-corner"] = "square-dual-arrows-to-corner",
		["square-face-sound"] = "square-face-sound",
		["square-face-waving-hand"] = "square-face-waving-hand",
		["square-face-winking"] = "square-face-winking",
		["square-minus"] = "square-minus",
		["square-person"] = "square-person",
		["squares-grid-plus"] = "squares-grid-plus",
		["squares-grid-qr"] = "squares-grid-qr",
		["stacked-squares-arrow-down-left"] = "stacked-squares-arrow-down-left",
		["stacked-squares-arrow-up-right"] = "stacked-squares-arrow-up-right",
		["stacked-squares-plus"] = "stacked-squares-plus",
		["star"] = "star",
		["stop-large"] = "stop-large",
		["stop-small"] = "stop-small",
		["studio"] = "studio",
		["sun"] = "sun",
		["sweater"] = "sweater",
		["sword"] = "sword",
		["tag-sparkle"] = "tag-sparkle",
		["teletype"] = "teletype",
		["tencent-qq"] = "tencent-qq",
		["text-b-bold"] = "text-b-bold",
		["text-box-microphone"] = "text-box-microphone",
		["text-h-subscript-1"] = "text-h-subscript-1",
		["text-h-subscript-2"] = "text-h-subscript-2",
		["text-h-subscript-3"] = "text-h-subscript-3",
		["text-i-italic"] = "text-i-italic",
		["text-s-strikethrough"] = "text-s-strikethrough",
		["text-u-underline"] = "text-u-underline",
		["text-uppercase-a-lowercase-a"] = "text-uppercase-a-lowercase-a",
		["text-x-subscript-2"] = "text-x-subscript-2",
		["text-x-superscript-2"] = "text-x-superscript-2",
		["three-bars-horizontal"] = "three-bars-horizontal",
		["three-bars-horizontal-chevron-left"] = "three-bars-horizontal-chevron-left",
		["three-bars-horizontal-narrowing"] = "three-bars-horizontal-narrowing",
		["three-bars-horizontal-triangles-vertical"] = "three-bars-horizontal-triangles-vertical",
		["three-bars-vertical-triangles-horizontal"] = "three-bars-vertical-triangles-horizontal",
		["three-chevrons-enlarging-down"] = "three-chevrons-enlarging-down",
		["three-chevrons-enlarging-up"] = "three-chevrons-enlarging-up",
		["three-dots-horizontal"] = "three-dots-horizontal",
		["three-dots-vertical"] = "three-dots-vertical",
		["three-horizontal-bars-wrapping-right"] = "three-horizontal-bars-wrapping-right",
		["three-people"] = "three-people",
		["three-ring-note"] = "three-ring-note",
		["three-sliders-horizontal"] = "three-sliders-horizontal",
		["three-stacked-squares-tilted"] = "three-stacked-squares-tilted",
		["thumb-down"] = "thumb-down",
		["thumb-up"] = "thumb-up",
		["tik-tok"] = "tik-tok",
		["tilt"] = "tilt",
		["torso"] = "torso",
		["trash-can"] = "trash-can",
		["triangle-exclamation"] = "triangle-exclamation",
		["trophy"] = "trophy",
		["tshirt"] = "tshirt",
		["tshirt-2d-text"] = "tshirt-2d-text",
		["tshirt-dual-arrows"] = "tshirt-dual-arrows",
		["twitch"] = "twitch",
		["twitter"] = "twitter",
		["two-arrows-down-and-up"] = "two-arrows-down-and-up",
		["two-arrows-from-center"] = "two-arrows-from-center",
		["two-arrows-left-right"] = "two-arrows-left-right",
		["two-arrows-loop-clockwise"] = "two-arrows-loop-clockwise",
		["two-arrows-loop-clockwise-1"] = "two-arrows-loop-clockwise-1",
		["two-arrows-loop-clockwise-infinity"] = "two-arrows-loop-clockwise-infinity",
		["two-arrows-spin-clockwise"] = "two-arrows-spin-clockwise",
		["two-arrows-spin-clockwise-plus"] = "two-arrows-spin-clockwise-plus",
		["two-arrows-switch-right"] = "two-arrows-switch-right",
		["two-arrows-to-center"] = "two-arrows-to-center",
		["two-folders"] = "two-folders",
		["two-location-pins-connecting-arrow"] = "two-location-pins-connecting-arrow",
		["two-makeup-brushes"] = "two-makeup-brushes",
		["two-people"] = "two-people",
		["two-people-speech-bubble"] = "two-people-speech-bubble",
		["two-stacked-squares"] = "two-stacked-squares",
		["two-switches-horizontal"] = "two-switches-horizontal",
		["verified-backplate"] = "verified-backplate",
		["verified-check"] = "verified-check",
		["verified-mono"] = "verified-mono",
		["video-camera"] = "video-camera",
		["video-camera-arrow-to-bottom-left"] = "video-camera-arrow-to-bottom-left",
		["video-camera-arrow-to-top-right"] = "video-camera-arrow-to-top-right",
		["video-camera-slash"] = "video-camera-slash",
		["video-camera-triangle-exclamation"] = "video-camera-triangle-exclamation",
		["video-camera-x"] = "video-camera-x",
		["wallet"] = "wallet",
		["we-chat"] = "we-chat",
		["whatsapp"] = "whatsapp",
		["x"] = "x",
		["x-small"] = "x-small",
		["xbox-a"] = "xbox-a",
		["xbox-a-pressed"] = "xbox-a-pressed",
		["xbox-a-unpressed"] = "xbox-a-unpressed",
		["xbox-b"] = "xbox-b",
		["xbox-dpad"] = "xbox-dpad",
		["xbox-dpad-down"] = "xbox-dpad-down",
		["xbox-dpad-left"] = "xbox-dpad-left",
		["xbox-dpad-right"] = "xbox-dpad-right",
		["xbox-dpad-up"] = "xbox-dpad-up",
		["xbox-lb"] = "xbox-lb",
		["xbox-lt"] = "xbox-lt",
		["xbox-menu"] = "xbox-menu",
		["xbox-rb"] = "xbox-rb",
		["xbox-rt"] = "xbox-rt",
		["xbox-stick-left"] = "xbox-stick-left",
		["xbox-stick-left-directional"] = "xbox-stick-left-directional",
		["xbox-stick-left-horizontal"] = "xbox-stick-left-horizontal",
		["xbox-stick-left-vertical"] = "xbox-stick-left-vertical",
		["xbox-stick-right"] = "xbox-stick-right",
		["xbox-stick-right-directional"] = "xbox-stick-right-directional",
		["xbox-stick-right-horizontal"] = "xbox-stick-right-horizontal",
		["xbox-stick-right-vertical"] = "xbox-stick-right-vertical",
		["xbox-view"] = "xbox-view",
		["xbox-x"] = "xbox-x",
		["xbox-y"] = "xbox-y",
		["xr-headset"] = "xr-headset",
		["youtube"] = "youtube"
	};
end);

Phobia.IsMouseOverFrame = LPH_NO_VIRTUALIZE(function(self , Frame)
	if not Frame then
		return;
	end;

	if Phobia.Global3DRenderMode then
		if Frame.GuiState == Enum.GuiState.Hover or Frame.GuiState == Enum.GuiState.Press then
			return true;
		end;

		return false;
	end;

	local AbsPos: Vector2, AbsSize: Vector2 = Frame.AbsolutePosition, Frame.AbsoluteSize;

	if Mouse.X >= AbsPos.X and Mouse.X <= AbsPos.X + AbsSize.X and Mouse.Y >= AbsPos.Y and Mouse.Y <= AbsPos.Y + AbsSize.Y then
		return true;
	end;
end);

Phobia.CreateSignal = LPH_NO_VIRTUALIZE(function(self , DefaultValue)
	local __cache = Instance.new('BindableEvent');
	local bind = {
		Value = DefaultValue,
		__event = __cache
	};

	function bind:GetValue()
		return bind.Value;
	end;

	function bind:SetValue(f)
		bind.Value = f;

		return __cache:Fire(f);
	end;

	function bind:Connect(f)
		local signal = __cache.Event:Connect(f);

		Phobia:AddSignal(signal);

		return signal;
	end;

	return bind;
end);

Phobia.SetIconMode = LPH_NO_VIRTUALIZE(function(self , Label: TextLabel , Icon: string)
	Phobia:ApplyIcon(Label , Icon , { });
end);

function Phobia:GetIconFont(icon: string)
	return Enum.Font.Gotham;
end;

function Phobia:MoreThanHalfY(Value: number)
	return (Phobia.ScreenGui.AbsoluteSize.Y / 2) < Value
end;

Phobia.IsStudio = RunService:IsStudio();
Phobia.IsMobile = UserInputService.TouchEnabled;

Phobia.CreateInput = LPH_NO_VIRTUALIZE(function(self , Frame , Callback)
	local Button = Instance.new('ImageButton',Frame);

	Button.ZIndex = Frame.ZIndex + 10;
	Button.Size = UDim2.fromScale(1,1);
	Button.BackgroundTransparency = 1;
	Button.ImageTransparency = 1;
	Button.Image = "";

	if Callback then
		local bth_signal = Button.MouseButton1Click:Connect(Callback);

		return Button , bth_signal;
	end;

	return Button;
end);

Phobia.PlayAnimate = LPH_NO_VIRTUALIZE(function(Self , Info , Property)
	if typeof(Self) == 'Instance' and Self:GetAttribute('PhobiaIconDrawn') then
		return Phobia.Icons.Animate(Self , Info or TweenInfo.new(0.25) , Property);
	end;

	local Tween = TweenService:Create(Self , Info or TweenInfo.new(0.25) , Property);

	Tween:Play();

	return Tween;
end);

Phobia.Drag = LPH_NO_VIRTUALIZE(function(InputFrame: Frame, MoveFrame: Frame, Speed : number)
	local dragToggle: boolean = false;
	local dragStart: Vector3 = nil;
	local startPos: UDim2 = nil;
	local Tween = TweenInfo.new(Speed);

	local updateInput = function(input)
		local delta = input.Position - dragStart;
		local position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y);

		if Phobia.Global3DRenderMode then
			Phobia.PlayAnimate(MoveFrame,Tween,{
				Position = UDim2.fromScale(0.5,0.5)
			});
		else
			Phobia.PlayAnimate(MoveFrame,Tween,{
				Position = position
			});
		end;
	end;

	Phobia:AddSignal(InputFrame.InputBegan:Connect(function(input)
		if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then 
			dragToggle = true;
			dragStart = input.Position;
			startPos = MoveFrame.Position;

			local input_end;
			input_end = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragToggle = false;

					input_end:Disconnect();
				end
			end)
		end
	end));

	Phobia:AddSignal(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			if dragToggle then
				updateInput(input)
			end
		end
	end));
end);

Phobia.Rounding = LPH_NO_VIRTUALIZE(function(num, numDecimalPlaces)
	local mult = 10 ^ (numDecimalPlaces or 0);
	return math.floor(num * mult + 0.5) / mult;
end);

Phobia.ProcessParams = LPH_NO_VIRTUALIZE(function(self , Params , Fixed)
	Params = Params or {};

	local k = Params or {};

	for i,v in next , Fixed do
		k[i] = Params[i] or v;
	end;

	table.clear(Fixed);

	return k;
end);

Phobia.EnabledBlur = true;
Phobia.BlurModuleParent = workspace.CurrentCamera;

Phobia.GetCalculatePosition = LPH_NO_VIRTUALIZE(function(planePos, planeNormal, rayOrigin, rayDirection)
	local n = planeNormal;
	local d = rayDirection;
	local v = rayOrigin - planePos;

	local num = (n.x * v.x) + (n.y * v.y) + (n.z * v.z);
	local den = (n.x * d.x) + (n.y * d.y) + (n.z * d.z);
	local a = -num / den;

	return rayOrigin + (a * rayDirection);
end);

Phobia.__CreateBlurModuleImpl = LPH_NO_VIRTUALIZE(function(self , Frame , Signal)
	if not Phobia.EnabledBlur then
		return Phobia:AddSignal(Instance.new('BindableEvent').Event:Connect(function() return "nl"; end));	
	end;

	local Part = Instance.new('Part',Phobia.BlurModuleParent);
	local DepthOfField = Instance.new('DepthOfFieldEffect',cloneref(game:GetService('Lighting')));
	local BlockMesh = Instance.new("BlockMesh");

	BlockMesh.Parent = Part;

	Part.Material = Enum.Material.Glass;
	Part.Transparency = 1;
	Part.Reflectance = 1;
	Part.CastShadow = false;
	Part.Anchored = true;
	Part.CanCollide = false;
	Part.CanQuery = false;
	Part.CollisionGroup = Phobia.RandomString();
	Part.Size = Vector3.new(1, 1, 1) * 0.01;
	Part.Color = Color3.fromRGB(0,0,0);

	DepthOfField.Enabled = true;
	DepthOfField.FarIntensity = 0;
	DepthOfField.FocusDistance = 0;
	DepthOfField.InFocusRadius = 1000;
	DepthOfField.NearIntensity = 1;
	DepthOfField.Name = Phobia.RandomString();

	Part.Name = Phobia.RandomString();

	local disconnect;

	local UpdateFunction = function()
		local IsWindowActive = Signal:GetValue();

		if IsWindowActive and not Phobia.Global3DRenderMode then

			Phobia.PlayAnimate(DepthOfField,TweenInfo.new(0.1),{
				NearIntensity = 1
			})

			Phobia.PlayAnimate(Part,TweenInfo.new(0.1),{
				Transparency = 0.97,
				Size = Vector3.new(1, 1, 1) * 0.01;
			})

			Part.Parent = Phobia.BlurModuleParent;
		else
			Phobia.PlayAnimate(DepthOfField,TweenInfo.new(0.1),{
				NearIntensity = 0
			})

			Phobia.PlayAnimate(Part,TweenInfo.new(0.1),{
				Size = Vector3.zero,
				Transparency = 1.5,
			})

			Part.Parent = nil;

			return false;
		end;

		if IsWindowActive then
			local corner0 = Frame.AbsolutePosition;
			local corner1 = corner0 + Frame.AbsoluteSize;

			local ray0 = CurrentCamera.ScreenPointToRay(CurrentCamera,corner0.X, corner0.Y, 1);
			local ray1 = CurrentCamera.ScreenPointToRay(CurrentCamera,corner1.X, corner1.Y, 1);

			local planeOrigin = CurrentCamera.CFrame.Position + CurrentCamera.CFrame.LookVector * (0.05 - CurrentCamera.NearPlaneZ);

			local planeNormal = CurrentCamera.CFrame.LookVector;

			local pos0 = Phobia.GetCalculatePosition(planeOrigin, planeNormal, ray0.Origin, ray0.Direction);
			local pos1 = Phobia.GetCalculatePosition(planeOrigin, planeNormal, ray1.Origin, ray1.Direction);

			pos0 = CurrentCamera.CFrame:PointToObjectSpace(pos0);
			pos1 = CurrentCamera.CFrame:PointToObjectSpace(pos1);

			local size   = pos1 - pos0;
			local center = (pos0 + pos1) / 2;

			BlockMesh.Offset = center
			BlockMesh.Scale  = size / 0.0101;
			Part.CFrame = CurrentCamera.CFrame;
		end;
	end;

	local rbxsignal = Phobia:AddSignal(CurrentCamera:GetPropertyChangedSignal('CFrame'):Connect(UpdateFunction))
	local loopThread = Phobia:AddSignal(UserInputService.InputChanged:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch then
			pcall(UpdateFunction);
		end;
	end));

	local THREAD = task.spawn(function()
		while true do task.wait(0.1)
			pcall(UpdateFunction);
		end;
	end);

	disconnect = function()
		rbxsignal:Disconnect();
		loopThread:Disconnect();
		task.cancel(THREAD);
		Part:Destroy();
		DepthOfField:Destroy();
	end;

	Frame.Destroying:Connect(disconnect);

	return rbxsignal;
end);

Phobia.CreateBlurModule = LPH_NO_VIRTUALIZE(function(self , Frame , Signal)
	local __ok , __result = pcall(Phobia.__CreateBlurModuleImpl , self , Frame , Signal);

	if not __ok then
		warn('[Phobia] blur module disabled: ' .. tostring(__result));

		return Phobia:AddSignal(Instance.new('BindableEvent').Event:Connect(function() return "nl"; end));
	end;

	return __result;
end);

local EmptyFunction = function() end;

function Phobia:RollingEffect(parent)
	local UIGradient = Instance.new("UIGradient")

	UIGradient.Transparency = NumberSequence.new{NumberSequenceKeypoint.new(0.00, 0.4), NumberSequenceKeypoint.new(1.00, 0.00)}
	UIGradient.Parent = parent

	return UIGradient;
end;

function Phobia:CreateShadow(parent , RollingEffect)
	local Shadow = {};

	local UIShadowSafe85 = Instance.new("UIStroke")
	local UIShadowSafe65 = Instance.new("UIStroke")
	local UIShadowSafe50 = Instance.new("UIStroke")
	local UIShadowSafe45 = Instance.new("UIStroke")

	UIShadowSafe85.Thickness = 6.000
	UIShadowSafe85.Transparency = 1
	UIShadowSafe85.Parent = parent

	UIShadowSafe65.Thickness = 5.000
	UIShadowSafe65.Transparency = 1
	UIShadowSafe65.Parent = parent

	UIShadowSafe50.Thickness = 4.000
	UIShadowSafe50.Transparency = 1
	UIShadowSafe50.Parent = parent

	UIShadowSafe45.Thickness = 3.000
	UIShadowSafe45.Transparency = 1
	UIShadowSafe45.Parent = parent

	local RollingEffectThread;
	local r1,r2,r3,r4;

	if RollingEffect then
		r1 = Phobia:RollingEffect(UIShadowSafe85);
		r2 = Phobia:RollingEffect(UIShadowSafe65);
		r3 = Phobia:RollingEffect(UIShadowSafe50);
		r4 = Phobia:RollingEffect(UIShadowSafe45);
	end;

	Shadow.Render = LPH_NO_VIRTUALIZE(function(self , value)
		if RollingEffectThread then
			task.cancel(RollingEffectThread);
			RollingEffectThread = nil;
		end;

		if value then
			Phobia.PlayAnimate(UIShadowSafe85 , SlowyTween , {
				Transparency = 0.900
			})

			Phobia.PlayAnimate(UIShadowSafe65 , SlowyTween , {
				Transparency = 0.900
			})

			Phobia.PlayAnimate(UIShadowSafe50 , SlowyTween , {
				Transparency = 0.900
			})

			Phobia.PlayAnimate(UIShadowSafe45 , SlowyTween , {
				Transparency = 0.900
			})

			if RollingEffect then
				RollingEffectThread = task.spawn(function()
					local level = 20;
					while true do task.wait(0.025)
						Phobia.PlayAnimate(r1 , SlowyTween , {
							Rotation = r1.Rotation + level
						});

						Phobia.PlayAnimate(r2 , SlowyTween , {
							Rotation = r2.Rotation + level
						});

						Phobia.PlayAnimate(r3 , SlowyTween , {
							Rotation = r3.Rotation + level
						});

						Phobia.PlayAnimate(r4 , SlowyTween , {
							Rotation = r4.Rotation + level
						});
					end;
				end);
			end;
		else
			Phobia.PlayAnimate(UIShadowSafe85 , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(UIShadowSafe65 , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(UIShadowSafe50 , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(UIShadowSafe45 , SlowyTween , {
				Transparency = 1
			})
		end;
	end);

	return Shadow;
end;

function Phobia:CreateOptionWindow(Frame: Frame , Zindex)
	Zindex = Zindex or 9;

	local Window = {
		Signal = Phobia:CreateSignal(false),
	};

	local OptionHandler = Instance.new("Frame")
	local UICorner = Instance.new("UICorner")
	local UIListLayout = Instance.new("UIListLayout")
	local UIStroke = Instance.new("UIStroke")
	local shadow = Phobia:CreateShadow(OptionHandler);

	OptionHandler.Name = Phobia.RandomString();
	OptionHandler.Parent = Phobia.ScreenGui
	OptionHandler.AnchorPoint = Vector2.new(0, 0)
	OptionHandler.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
	OptionHandler.BackgroundTransparency = 0.035
	OptionHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
	OptionHandler.BorderSizePixel = 0
	OptionHandler.ClipsDescendants = true
	OptionHandler.Position = UDim2.new(255,255,255,255)
	OptionHandler.Size = UDim2.new(0, 220, 0, 75)
	OptionHandler.ZIndex = Zindex + 9

	UICorner.CornerRadius = UDim.new(0, 10)
	UICorner.Parent = OptionHandler

	UIListLayout.Parent = OptionHandler
	UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

	UIStroke.Transparency = 0.650
	UIStroke.Color = Color3.fromRGB(45, 48, 58)
	UIStroke.Parent = OptionHandler

	Phobia:AddSignal(UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
		Phobia.PlayAnimate(OptionHandler , SlowyTween , {
			Size = UDim2.new(0, 220, 0, UIListLayout.AbsoluteContentSize.Y - 1)
		})
	end)));

	Phobia:AddSignal(OptionHandler:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
		if OptionHandler.BackgroundTransparency > 0.9 then
			OptionHandler.Visible = false;
			UIListLayout.Parent = nil;
			OptionHandler.Parent = nil;
		else
			OptionHandler.Visible = true;
			UIListLayout.Parent = OptionHandler

			if Phobia.Global3DRenderMode then
				OptionHandler.Parent = Phobia.GlobalSurfaceGui;
			else
				OptionHandler.Parent = Phobia.ScreenGui;
			end;
		end
	end)));

	local FollowingThread;
	local SetPosition = LPH_NO_VIRTUALIZE(function()
		if Phobia:MoreThanHalfY(Frame.AbsolutePosition.Y + 65) then
			OptionHandler.AnchorPoint = Vector2.new(0,1)
		else
			OptionHandler.AnchorPoint = Vector2.new(0,0)
		end;

		OptionHandler.Position = UDim2.fromOffset(Frame.AbsolutePosition.X + 18 , Frame.AbsolutePosition.Y + 65);
	end);

	Window.SetRender = LPH_NO_VIRTUALIZE(function(value)
		if FollowingThread then
			task.cancel(FollowingThread);
			FollowingThread = nil;
		end;

		if value then
			SetPosition();

			Phobia.PlayAnimate(OptionHandler , SlowyTween , {
				BackgroundTransparency = 0.035
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 0.650
			})

			shadow:Render(true);

			if Phobia.Global3DRenderMode then
				OptionHandler.Parent = Phobia.GlobalSurfaceGui;
			else
				OptionHandler.Parent = Phobia.ScreenGui;
			end;

			FollowingThread = task.spawn(function()
				while true do task.wait()
					SetPosition();
				end
			end)
		else
			Phobia.PlayAnimate(OptionHandler , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 1
			})

			shadow:Render(false);
		end;
	end);

	Window.SetRender(false);
	Window.Signal:Connect(Window.SetRender)

	local Payback = Phobia:RegisiterItem(OptionHandler , Window.Signal);

	Payback.Winbdow = Window;
	Payback.Root = OptionHandler;
	Payback.Signal = Window.Signal;

	return Payback;
end;

function Phobia:CreateColorPicker(HandleFrame: Frame)
	local ZIndex = HandleFrame.ZIndex;

	local ColorPickerLib = {};

	local ColorPickerHandler = Instance.new("Frame")
	local UICorner = Instance.new("UICorner")
	local UIStroke = Instance.new("UIStroke")
	local SaViMap = Instance.new("ImageLabel")
	local UICorner_2 = Instance.new("UICorner")
	local ColorZoneSelection = Instance.new("Frame")
	local UICorner_3 = Instance.new("UICorner")
	local UIStroke_2 = Instance.new("UIStroke")
	local ColorMap = Instance.new("Frame")
	local UIGradient = Instance.new("UIGradient")
	local UICorner_4 = Instance.new("UICorner")
	local ColorMapSelection = Instance.new("Frame")
	local UIStroke_3 = Instance.new("UIStroke")
	local UICorner_5 = Instance.new("UICorner")
	local RGBLabel = Instance.new("TextLabel")
	local UICorner_6 = Instance.new("UICorner")
	local Shadow = Phobia:CreateShadow(ColorPickerHandler);

	ColorPickerHandler.Name = Phobia.RandomString();
	ColorPickerHandler.Parent = Phobia.ScreenGui
	ColorPickerHandler.AnchorPoint = Vector2.new(0, 0)
	ColorPickerHandler.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
	ColorPickerHandler.BackgroundTransparency = 0.035
	ColorPickerHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ColorPickerHandler.BorderSizePixel = 0
	ColorPickerHandler.ClipsDescendants = true
	ColorPickerHandler.Position = UDim2.new(255, 0, 255, 20)
	ColorPickerHandler.Size = UDim2.new(0, 200, 0, 240)
	ColorPickerHandler.ZIndex = ZIndex + 125

	Phobia:AddSignal(ColorPickerHandler:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
		if ColorPickerHandler.BackgroundTransparency > 0.9 then
			ColorPickerHandler.Visible = false;
			ColorPickerHandler.Parent = nil
		else
			ColorPickerHandler.Visible = true;

			if Phobia.Global3DRenderMode then
				ColorPickerHandler.Parent = Phobia.GlobalSurfaceGui;
			else
				ColorPickerHandler.Parent = Phobia.ScreenGui;
			end;
		end;
	end)));

	UICorner.CornerRadius = UDim.new(0, 10)
	UICorner.Parent = ColorPickerHandler

	UIStroke.Transparency = 0.650
	UIStroke.Color = Color3.fromRGB(45, 48, 58)
	UIStroke.Parent = ColorPickerHandler

	SaViMap.Name = Phobia.RandomString();
	SaViMap.Parent = ColorPickerHandler
	SaViMap.AnchorPoint = Vector2.new(0.5, 0)
	SaViMap.BackgroundColor3 = Color3.fromRGB(255, 0, 4)
	SaViMap.BorderColor3 = Color3.fromRGB(0, 0, 0)
	SaViMap.BorderSizePixel = 0
	SaViMap.Position = UDim2.new(0.5, 0, 0, 5)
	SaViMap.Size = UDim2.new(0, 185, 0, 185)
	SaViMap.ZIndex = ZIndex + 126
	SaViMap.Image = "" -- saturation/value map is drawn with gradients (no external assets)

	local SatOverlay = Instance.new("Frame")
	SatOverlay.Name = Phobia.RandomString();
	SatOverlay.Parent = SaViMap
	SatOverlay.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	SatOverlay.BorderColor3 = Color3.fromRGB(0, 0, 0)
	SatOverlay.BorderSizePixel = 0
	SatOverlay.Size = UDim2.fromScale(1, 1)
	SatOverlay.ZIndex = SaViMap.ZIndex

	local SatGradient = Instance.new("UIGradient")
	SatGradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 255, 255))
	SatGradient.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)})
	SatGradient.Parent = SatOverlay

	local ValOverlay = Instance.new("Frame")
	ValOverlay.Name = Phobia.RandomString();
	ValOverlay.Parent = SatOverlay
	ValOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	ValOverlay.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ValOverlay.BorderSizePixel = 0
	ValOverlay.Size = UDim2.fromScale(1, 1)
	ValOverlay.ZIndex = SaViMap.ZIndex

	local ValGradient = Instance.new("UIGradient")
	ValGradient.Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromRGB(0, 0, 0))
	ValGradient.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0)})
	ValGradient.Rotation = 90
	ValGradient.Parent = ValOverlay

	UICorner_2.CornerRadius = UDim.new(0, 5)
	UICorner_2.Parent = SaViMap

	ColorZoneSelection.Name = Phobia.RandomString();
	ColorZoneSelection.Parent = SaViMap
	ColorZoneSelection.AnchorPoint = Vector2.new(0.5, 0.5)
	ColorZoneSelection.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ColorZoneSelection.BackgroundTransparency = 1.000
	ColorZoneSelection.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ColorZoneSelection.BorderSizePixel = 0
	ColorZoneSelection.Position = UDim2.new(0.5, 0, 0.5, 0)
	ColorZoneSelection.Size = UDim2.new(0, 10, 0, 10)
	ColorZoneSelection.ZIndex = ZIndex + 127

	UICorner_3.CornerRadius = UDim.new(1, 0)
	UICorner_3.Parent = ColorZoneSelection

	UIStroke_2.Color = Color3.fromRGB(255, 255, 255)
	UIStroke_2.Parent = ColorZoneSelection

	ColorMap.Name = Phobia.RandomString();
	ColorMap.Parent = ColorPickerHandler
	ColorMap.AnchorPoint = Vector2.new(0.5, 0)
	ColorMap.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ColorMap.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ColorMap.BorderSizePixel = 0
	ColorMap.Position = UDim2.new(0.5, 0, 0, 200)
	ColorMap.Size = UDim2.new(1, -15, 0, 10)
	ColorMap.ZIndex = ZIndex + 126

	UIGradient.Color = ColorSequence.new{ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)), ColorSequenceKeypoint.new(0.10, Color3.fromRGB(255, 153, 0)), ColorSequenceKeypoint.new(0.20, Color3.fromRGB(203, 255, 0)), ColorSequenceKeypoint.new(0.30, Color3.fromRGB(50, 255, 0)), ColorSequenceKeypoint.new(0.40, Color3.fromRGB(0, 255, 102)), ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)), ColorSequenceKeypoint.new(0.60, Color3.fromRGB(0, 101, 255)), ColorSequenceKeypoint.new(0.70, Color3.fromRGB(50, 0, 255)), ColorSequenceKeypoint.new(0.80, Color3.fromRGB(204, 0, 255)), ColorSequenceKeypoint.new(0.90, Color3.fromRGB(255, 0, 153)), ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0))}
	UIGradient.Parent = ColorMap

	UICorner_4.CornerRadius = UDim.new(0, 3)
	UICorner_4.Parent = ColorMap

	ColorMapSelection.Name = Phobia.RandomString();
	ColorMapSelection.Parent = ColorMap
	ColorMapSelection.AnchorPoint = Vector2.new(0.5, 0.5)
	ColorMapSelection.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ColorMapSelection.BackgroundTransparency = 1.000
	ColorMapSelection.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ColorMapSelection.BorderSizePixel = 0
	ColorMapSelection.Position = UDim2.new(0, 0, 0.5, 0)
	ColorMapSelection.Size = UDim2.new(0, 5, 1, 0)
	ColorMapSelection.ZIndex = ZIndex + 126

	UIStroke_3.Thickness = 2.000
	UIStroke_3.Color = Color3.fromRGB(255, 255, 255)
	UIStroke_3.Parent = ColorMapSelection

	UICorner_5.CornerRadius = UDim.new(0, 3)
	UICorner_5.Parent = ColorMapSelection

	RGBLabel.Name = Phobia.RandomString();
	RGBLabel.Parent = ColorPickerHandler
	RGBLabel.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
	RGBLabel.BackgroundTransparency = 0.750
	RGBLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
	RGBLabel.BorderSizePixel = 0
	RGBLabel.Position = UDim2.new(0, 10, 0, 217)
	RGBLabel.Size = UDim2.new(1, -20, 0, 15)
	RGBLabel.ZIndex = ZIndex + 127
	RGBLabel.Font = Enum.Font.GothamMedium
	RGBLabel.Text = "#FFFFFF"
	RGBLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	RGBLabel.TextSize = 12.000
	RGBLabel.TextTransparency = 0.400
	RGBLabel.TextXAlignment = Enum.TextXAlignment.Left

	UICorner_6.CornerRadius = UDim.new(0, 4)
	UICorner_6.Parent = RGBLabel

	ColorPickerLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
		if value then
			ColorPickerHandler.Position = UDim2.new(0,HandleFrame.AbsolutePosition.X + 20 , 0 ,HandleFrame.AbsolutePosition.Y + 75);

			Phobia.PlayAnimate(ColorPickerHandler,SlowyTween , {
				BackgroundTransparency = 0.035
			})

			Phobia.PlayAnimate(UIStroke,SlowyTween , {
				Transparency = 0.650
			})

			Phobia.PlayAnimate(SaViMap,SlowyTween , {
				BackgroundTransparency = 0
			})

			Phobia.PlayAnimate(SatOverlay,SlowyTween , {
				BackgroundTransparency = 0
			})

			Phobia.PlayAnimate(ValOverlay,SlowyTween , {
				BackgroundTransparency = 0
			})

			Phobia.PlayAnimate(UIStroke_2,SlowyTween , {
				Transparency = 0
			})

			Phobia.PlayAnimate(ColorMap,SlowyTween , {
				BackgroundTransparency = 0
			})

			Phobia.PlayAnimate(UIStroke_3,SlowyTween , {
				Transparency = 0
			})

			Phobia.PlayAnimate(RGBLabel,SlowyTween , {
				BackgroundTransparency = 0.750,
				TextTransparency = 0.400
			})

			Shadow:Render(true)
		else
			Phobia.PlayAnimate(ColorPickerHandler,SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke,SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(SaViMap,SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(SatOverlay,SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(ValOverlay,SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke_2,SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(ColorMap,SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke_3,SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(RGBLabel,SlowyTween , {
				BackgroundTransparency = 1,
				TextTransparency = 1
			})

			Shadow:Render(false)
		end;
	end);

	ColorPickerLib.SetRender(false);
	ColorPickerLib.Root = ColorPickerHandler;
	ColorPickerLib.H = 1;
	ColorPickerLib.S = 1;
	ColorPickerLib.V = 1;
	ColorPickerLib.Callback = EmptyFunction;

	function ColorPickerLib:Update()
		local RealColor = Color3.fromHSV(ColorPickerLib.H , ColorPickerLib.S , ColorPickerLib.V);

		Phobia.PlayAnimate(ColorZoneSelection,ManualTween,{
			Position = UDim2.fromScale(ColorPickerLib.S , 1 - ColorPickerLib.V)
		});

		Phobia.PlayAnimate(SaViMap,ManualTween,{
			BackgroundColor3 = Color3.fromHSV(ColorPickerLib.H , 1 , 1)
		});

		Phobia.PlayAnimate(ColorMapSelection,ManualTween,{
			Position = UDim2.fromScale(ColorPickerLib.H,0.5)
		});

		RGBLabel.Text = "#"..RealColor:ToHex();

		ColorPickerLib.Callback(RealColor);
	end;

	function ColorPickerLib:SetValue(Color)
		if typeof(Color) == 'string' then
			Color = Color3.fromHex(Color);
		end;

		local H , S , V = Color:ToHSV();

		ColorPickerLib.H = H;
		ColorPickerLib.S = S;
		ColorPickerLib.V = V;

		ColorPickerLib:Update();
	end;

	ColorPickerLib.IsHold = false;

	Phobia:AddSignal(ColorPickerHandler.InputBegan:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			ColorPickerLib.IsHold = true;
		end;
	end));

	Phobia:AddSignal(ColorPickerHandler.InputEnded:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			ColorPickerLib.IsHold = false;
		end;
	end));

	Phobia:AddSignal(ColorMap.InputBegan:Connect(LPH_NO_VIRTUALIZE(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			ColorPickerLib.IsHold = true;

			while (UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or ColorPickerLib.IsHold) do task.wait()
				local ColorY = ColorMap.AbsolutePosition.X
				local ColorYM = ColorY + ColorMap.AbsoluteSize.X;
				local Value = math.clamp(Mouse.X, ColorY, ColorYM)
				local Code = ((Value - ColorY) / (ColorYM - ColorY));

				ColorPickerLib.H = Code;
				ColorPickerLib:Update();
			end;
		end;
	end)));

	Phobia:AddSignal(SaViMap.InputBegan:Connect(LPH_NO_VIRTUALIZE(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			ColorPickerLib.IsHold = true;

			while (UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or ColorPickerLib.IsHold) do task.wait();
				local PosX = SaViMap.AbsolutePosition.X;
				local ScaleX = PosX + SaViMap.AbsoluteSize.X;
				local Value, PosY = math.clamp(Mouse.X, PosX, ScaleX), SaViMap.AbsolutePosition.Y;
				local ScaleY = PosY + SaViMap.AbsoluteSize.Y;
				local Vals = math.clamp(Mouse.Y, PosY, ScaleY);

				ColorPickerLib.S = (Value - PosX) / (ScaleX - PosX);
				ColorPickerLib.V = (1 - ((Vals - PosY) / (ScaleY - PosY)));
				ColorPickerLib:Update();
			end
		end
	end)));

	return ColorPickerLib;
end;

Phobia.KeyEnum = {
	One = '1',
	Two = '2',
	Three = '3',
	Four = '4',
	Five = '5',
	Six = '6',
	Seven = '7',
	Eight = '8',
	Nine = '9',
	Zero = '0',
	['Minus'] = "-",
	['Plus'] = "+",
	BackSlash = "\\",
	Slash = "/",
	Period = '.',
	Semicolon = ';',
	Colon = ":",
	LeftControl = "LCtrl",
	RightControl = "RCtrl",
	LeftShift = "LShift",
	RightShift = "RShift",
	Return = "Enter",
	LeftBracket = "[",
	RightBracket = "]",
	Quote = "'",
	Comma = ",",
	Equals = "=",
	LeftSuper = "Super",
	RightSuper = "Super",
	LeftAlt = "LAlt",
	RightAlt = "RAlt",
	Escape = "Esc",
};

Phobia.EnumReverse = {};

for i,v in next , Phobia.KeyEnum do
	Phobia.EnumReverse[v] = i;
end;

function Phobia:KeyCodeToStr(K: Enum.KeyCode)
	if typeof(K) == 'string' then
		if Phobia.KeyEnum[K] then
			return Phobia.KeyEnum[K];
		end;

		return K;
	end;

	if K == nil then return 'None' end; return (Phobia.KeyEnum[K.Name] or K.Name);
end;

function Phobia:StrToKeyCode(str: string)
	if Phobia.EnumReverse[str] then
		return Enum.KeyCode[Phobia.EnumReverse[str]];
	end;

	return Enum.KeyCode[str];
end;

function Phobia:RegisiterHandler(Handler: Frame , Signal)
	local handle = {};
	local ZINdex = Handler.ZIndex;

	function handle:AddToggle(Config)
		Config = Phobia:ProcessParams(Config , {
			Default = false,
			Flag = nil,
			Callback = EmptyFunction,
		});

		local Toggle = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local Circle = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")

		Toggle.Name = Phobia.RandomString();
		Toggle.Parent = Handler
		Toggle.BackgroundColor3 = Color3.fromRGB(10, 13, 21)
		Toggle.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Toggle.BorderSizePixel = 0
		Toggle.ClipsDescendants = true
		Toggle.Size = UDim2.new(0, 30, 0, 18)
		Toggle.ZIndex = ZINdex + 13
		Toggle.LayoutOrder = -(#Handler:GetChildren() + 5);

		UICorner.CornerRadius = UDim.new(1, 0)
		UICorner.Parent = Toggle

		Circle.Name = Phobia.RandomString();
		Circle.Parent = Toggle
		Circle.AnchorPoint = Vector2.new(0.5, 0.5)
		Circle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Circle.BackgroundTransparency = 0.500
		Circle.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Circle.BorderSizePixel = 0
		Circle.Position = UDim2.new(0.300000012, 0, 0.5, 0)
		Circle.Size = UDim2.new(0, 16, 0, 16)
		Circle.ZIndex = ZINdex + 14

		UICorner_2.CornerRadius = UDim.new(1, 0)
		UICorner_2.Parent = Circle

		local ToggleLib = {
			Root = Toggle	
		};

		ToggleLib.SetUI = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(Toggle,SlowyTween,{
					BackgroundTransparency = 0,
					BackgroundColor3 = Phobia.AccentColor
				})

				Phobia.PlayAnimate(Circle,SlowyTween,{
					BackgroundColor3 = Color3.fromRGB(255, 255, 255),
					BackgroundTransparency = 0,
					Position = UDim2.new(0.7, 0, 0.5, 0)
				})
			else
				Phobia.PlayAnimate(Toggle,SlowyTween,{
					BackgroundTransparency = 0,
					BackgroundColor3 = Color3.fromRGB(10, 13, 21)
				})

				Phobia.PlayAnimate(Circle,SlowyTween,{
					BackgroundColor3 = Color3.fromRGB(255, 255, 255),
					BackgroundTransparency = 0.500,
					Position = UDim2.new(0.300000012, 0, 0.5, 0)
				})
			end;
		end);

		ToggleLib.SetVisible = LPH_NO_VIRTUALIZE(function(value)
			if value then
				ToggleLib.SetUI(Config.Default);
			else
				Phobia.PlayAnimate(Toggle,SlowyTween,{
					BackgroundTransparency = 1,
					BackgroundColor3 = Color3.fromRGB(10, 13, 21)
				})

				Phobia.PlayAnimate(Circle,SlowyTween,{
					BackgroundColor3 = Color3.fromRGB(255, 255, 255),
					BackgroundTransparency = 1,
					Position = UDim2.new(0.300000012, 0, 0.5, 0)
				})
			end;
		end);

		ToggleLib.SetUI(Config.Default);
		ToggleLib.SetVisible(Signal:GetValue());

		Phobia:CreateInput(Toggle , LPH_NO_VIRTUALIZE(function()
			Config.Default = not Config.Default;

			ToggleLib.SetUI(Config.Default);

			Config.Callback(Config.Default)
		end))

		ToggleLib.Signal = Signal:Connect(ToggleLib.SetVisible);

		function ToggleLib:GetValue()
			return Config.Default;
		end;

		function ToggleLib:SetValue(v)
			Config.Default = v;

			if Signal:GetValue() then
				ToggleLib.SetUI(Config.Default);
			end;

			Config.Callback(Config.Default)
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = ToggleLib;
		end;

		return ToggleLib;
	end;

	function handle:AddSlider(Config)
		Config = Phobia:ProcessParams(Config , {
			Default = 50,
			Min = 0,
			Max = 10,
			Type = "",
			Rounding = 0,
			Nums = {},
			Flag = nil,
			Size = 125,
			Callback = EmptyFunction,
		});

		local SliderLib = {};

		SliderLib.GetSize = LPH_NO_VIRTUALIZE(function()
			return (Config.Default - Config.Min) / (Config.Max - Config.Min);
		end);

		local FullNumSize = TextService:GetTextSize(string.rep("0",(Config.Rounding + #tostring(Config.Max))+1)..tostring(Config.Type),10,Enum.Font.Gotham,Vector2.new(math.huge,math.huge));

		SliderLib.MaximumSize = FullNumSize.X;

		if Config.Nums then
			local nszie = 0;

			for i,ns in next , Config.Nums do
				local size = TextService:GetTextSize(string.rep("m",string.len(tostring(ns))),10,Enum.Font.Gotham,Vector2.new(math.huge,math.huge));

				if nszie < size.X then
					nszie = size.X;
				end
			end;

			if SliderLib.MaximumSize < nszie then
				SliderLib.MaximumSize = nszie;
			end;
		end;

		local Slider = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local ValueFrame = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local ValueLabel = Instance.new("TextBox")
		local SlideMain = Instance.new("Frame")
		local SlideFrame = Instance.new("Frame")
		local UICorner_3 = Instance.new("UICorner")
		local SlideMoving = Instance.new("Frame")
		local UICorner_4 = Instance.new("UICorner")
		local Frame = Instance.new("Frame")
		local UICorner_5 = Instance.new("UICorner")
		local boxSize = 2;

		Slider.Name = Phobia.RandomString();
		Slider.Parent = Handler
		Slider.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		Slider.BackgroundTransparency = 1.000
		Slider.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Slider.BorderSizePixel = 0
		Slider.ClipsDescendants = false
		Slider.Size = UDim2.new(0, Config.Size, 0, 18)
		Slider.ZIndex = ZINdex + 13
		Slider.LayoutOrder = -(#Handler:GetChildren() + 5);

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = Slider

		ValueFrame.Name = Phobia.RandomString();
		ValueFrame.Parent = Slider
		ValueFrame.AnchorPoint = Vector2.new(1, 0)
		ValueFrame.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		ValueFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ValueFrame.BorderSizePixel = 0
		ValueFrame.ClipsDescendants = true
		ValueFrame.Position = UDim2.new(1, 0, 0, 0)
		ValueFrame.Size = UDim2.new(0, SliderLib.MaximumSize + boxSize, 0, 18)
		ValueFrame.ZIndex = ZINdex + 13

		UICorner_2.CornerRadius = UDim.new(0, 4)
		UICorner_2.Parent = ValueFrame

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = ValueFrame

		ValueLabel.Name = Phobia.RandomString();
		ValueLabel.Parent = ValueFrame
		ValueLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		ValueLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ValueLabel.BackgroundTransparency = 1.000
		ValueLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ValueLabel.BorderSizePixel = 0
		ValueLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
		ValueLabel.Size = UDim2.new(1, 0, 1, 0)
		ValueLabel.ZIndex = ZINdex + 14
		ValueLabel.Font = Enum.Font.Gotham
		ValueLabel.Text = tostring(Config.Default)..tostring(Config.Type);
		ValueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		ValueLabel.TextSize = 10.000
		ValueLabel.ClearTextOnFocus = false;
		ValueLabel.TextTransparency = 0.350

		SlideMain.Name = Phobia.RandomString();
		SlideMain.Parent = Slider
		SlideMain.AnchorPoint = Vector2.new(0, 0.5)
		SlideMain.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		SlideMain.BackgroundTransparency = 1.000
		SlideMain.BorderColor3 = Color3.fromRGB(0, 0, 0)
		SlideMain.BorderSizePixel = 0
		SlideMain.Position = UDim2.new(0, 0, 0.5, 0)
		SlideMain.Size = UDim2.new(1, -((SliderLib.MaximumSize + 11)), 0, 18)
		SlideMain.ZIndex = ZINdex + 13

		SlideFrame.Name = Phobia.RandomString();
		SlideFrame.Parent = SlideMain
		SlideFrame.AnchorPoint = Vector2.new(0, 0.5)
		SlideFrame.BackgroundColor3 = Color3.fromRGB(30, 29, 36)
		SlideFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		SlideFrame.BorderSizePixel = 0
		SlideFrame.Position = UDim2.new(0, 0, 0.5, 0)
		SlideFrame.Size = UDim2.new(1, 0, 0, 5)
		SlideFrame.ZIndex = ZINdex + 13

		UICorner_3.CornerRadius = UDim.new(1, 0)
		UICorner_3.Parent = SlideFrame

		SlideMoving.Name = Phobia.RandomString();
		SlideMoving.Parent = SlideFrame
		SlideMoving.BackgroundColor3 = Phobia.AccentColor
		SlideMoving.BorderColor3 = Color3.fromRGB(0, 0, 0)
		SlideMoving.BorderSizePixel = 0
		SlideMoving.Size = UDim2.new(SliderLib.GetSize(), 0, 1, 0)
		SlideMoving.ZIndex = ZINdex + 14

		UICorner_4.CornerRadius = UDim.new(1, 0)
		UICorner_4.Parent = SlideMoving

		Frame.Parent = SlideMoving
		Frame.AnchorPoint = Vector2.new(1, 0.5)
		Frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Frame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Frame.BorderSizePixel = 0
		Frame.Position = UDim2.new(1, 5, 0.5, 0)
		Frame.Size = UDim2.new(0, 10, 0, 10)
		Frame.ZIndex = ZINdex + 15

		UICorner_5.CornerRadius = UDim.new(1, 0)
		UICorner_5.Parent = Frame

		local LoadText = LPH_NO_VIRTUALIZE(function()
			if Config.Nums[Config.Default] then
				ValueLabel.Text = Config.Nums[Config.Default]

			else
				ValueLabel.Text = tostring(Config.Default)..tostring(Config.Type);

			end;
		end);

		ValueLabel.FocusLost:Connect(LPH_NO_VIRTUALIZE(function()
			local OutVal = Phobia:ParseInput(ValueLabel.Text , true);
			if OutVal then
				local rx = math.clamp(OutVal , Config.Min , Config.Max);
				local Value = Phobia.Rounding(rx,Config.Rounding);

				if Value then
					Config.Default = Value;

					TweenService:Create(SlideMoving , ManualTween ,{
						Size = UDim2.new(SliderLib.GetSize(), 0, 1, 0)
					}):Play();

					LoadText();

					Config.Callback(Config.Default)
				else
					LoadText();
				end;

			else
				LoadText()
			end;
		end));

		SliderLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(ValueFrame,SlowyTween,{
					BackgroundTransparency = 0,
					Size = UDim2.new(0, SliderLib.MaximumSize + boxSize, 0, 18)
				});

				Phobia.PlayAnimate(UIStroke,SlowyTween,{
					Transparency = 0.650
				});

				Phobia.PlayAnimate(ValueLabel,SlowyTween,{
					TextTransparency = 0.350
				});

				Phobia.PlayAnimate(SlideFrame,SlowyTween,{
					BackgroundTransparency = 0
				});

				Phobia.PlayAnimate(SlideMoving,SlowyTween,{
					BackgroundTransparency = 0,
					Size = UDim2.new(SliderLib.GetSize(), 0, 1, 0)
				});

				Phobia.PlayAnimate(Frame,SlowyTween,{
					BackgroundTransparency = 0
				});
			else
				Phobia.PlayAnimate(ValueFrame,SlowyTween,{
					BackgroundTransparency = 1,
				});

				Phobia.PlayAnimate(UIStroke,SlowyTween,{
					Transparency = 1
				});

				Phobia.PlayAnimate(ValueLabel,SlowyTween,{
					TextTransparency = 1
				});

				Phobia.PlayAnimate(SlideFrame,SlowyTween,{
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(SlideMoving,SlowyTween,{
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 0, 1, 0)
				});

				Phobia.PlayAnimate(Frame,SlowyTween,{
					BackgroundTransparency = 1
				});
			end;
		end);

		SliderLib.SetRender(Signal:GetValue());
		SliderLib.Signal = Signal:Connect(SliderLib.SetRender);

		local Update = function(Input)
			local SizeScale = math.clamp((((Input.Position.X) - SlideMain.AbsolutePosition.X) / SlideMain.AbsoluteSize.X), 0, 1);
			local Main = ((Config.Max - Config.Min) * SizeScale) + Config.Min;
			local Value = Phobia.Rounding(Main,Config.Rounding);
			local PositionX = UDim2.fromScale(SizeScale, 1);
			local Size = ((Value - Config.Min) / (Config.Max - Config.Min)) + 0.02;

			Config.Default = Value;

			TweenService:Create(SlideMoving , ManualTween ,{
				Size = UDim2.new(SliderLib.GetSize(), 0, 1, 0)
			}):Play();

			LoadText()


			Config.Callback(Value)
		end;

		local IsHold = false;

		do
			SlideMain.InputBegan:Connect(LPH_NO_VIRTUALIZE(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					IsHold = true
					Update(Input)
				end
			end))

			SlideMain.InputEnded:Connect(LPH_NO_VIRTUALIZE(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					if UserInputService.TouchEnabled then
						if not Phobia:IsMouseOverFrame(SlideMain) then
							IsHold = false
						end;
					else
						IsHold = false
					end;
				end
			end))

			UserInputService.InputChanged:Connect(LPH_NO_VIRTUALIZE(function(Input)
				if IsHold then
					if (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch)  then
						if UserInputService.TouchEnabled then
							if not Phobia:IsMouseOverFrame(SlideMain) then
								IsHold = false
							else
								Update(Input)
							end;
						else
							Update(Input)
						end;
					end;
				end;
			end));
		end;

		function SliderLib:GetValue()
			return Config.Default;
		end;

		function SliderLib:SetValue(v)
			Config.Default = v;

			if Signal:GetValue() then
				Phobia.PlayAnimate(SlideMoving,SlowyTween,{
					BackgroundTransparency = 0,
					Size = UDim2.new(SliderLib.GetSize(), 0, 1, 0)
				});
			end;

			LoadText()

			Config.Callback(Config.Default);
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = SliderLib;
		end;

		return SliderLib;
	end;

	function handle:AddOption(GearIcon)
		local Option = Instance.new("Frame")
		local Icon = Instance.new("TextLabel")
		local UICorner = Instance.new("UICorner")

		Option.Name = Phobia.RandomString();
		Option.Parent = Handler
		Option.BackgroundColor3 = Color3.fromRGB(39, 40, 49)
		Option.BackgroundTransparency = 1.000
		Option.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Option.BorderSizePixel = 0
		Option.ClipsDescendants = true
		Option.Size = UDim2.new(0, 20, 0, 18)
		Option.ZIndex = ZINdex + 13
		Option.LayoutOrder = -(#Handler:GetChildren() + 5);

		Icon.Name = Phobia.RandomString();
		Icon.Parent = Option
		Icon.AnchorPoint = Vector2.new(0.5, 0.5)
		Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Icon.BackgroundTransparency = 1.000
		Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Icon.BorderSizePixel = 0
		Icon.Position = UDim2.new(0.5, 0, 0.5, 0)
		Icon.Size = UDim2.new(1, 0, 1, 0)
		Icon.ZIndex = ZINdex + 14
		Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
		Icon.TextTransparency = 0.400
		Phobia:ApplyIcon(Icon , (GearIcon == 1 and 'gear') or (GearIcon == 2 and 'chevron-large-right') or 'three-dots-horizontal' , { Size = 15 });
		Icon.TextWrapped = true

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = Option

		local Window = Phobia:CreateOptionWindow(Option , ZINdex + 13);
		local reciveSignal;

		Window.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 0.400
				})
			else
				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 1
				})
			end;
		end);

		Window.SetRender(Signal:GetValue());
		Signal:Connect(Window.SetRender);

		local bthg = Phobia:CreateInput(Option , LPH_NO_VIRTUALIZE(function()
			if reciveSignal then
				reciveSignal:Disconnect();
				reciveSignal = nil;	
			end;

			Window.Signal:SetValue(true);

			reciveSignal = UserInputService.InputBegan:Connect(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					if not Phobia:IsMouseOverFrame(Window.Root) and not Phobia:IsMouseOverFrame(Option) then
						if reciveSignal then
							reciveSignal:Disconnect();
							reciveSignal = nil;	
						end;

						Window.Signal:SetValue(false);
					end
				end
			end)
		end));

		Phobia:AddSignal(bthg.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(Option , SlowyTween , {
				BackgroundTransparency = 0.5
			})

			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 0.25
			})
		end)));

		Phobia:AddSignal(bthg.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(Option , SlowyTween , {
				BackgroundTransparency = 1.000
			})

			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 0.400
			})
		end)));

		return Window;
	end;

	function handle:AddColorPicker(Config)
		Config = Phobia:ProcessParams(Config , {
			Default = Color3.fromRGB(255, 255, 255),
			Callback  = EmptyFunction,
		});

		if typeof(Config.Default) == 'string' then
			Config.Default = Color3.fromHex(Config.Default:gsub('#',''));
		end;

		local ColorPickerLib = {};
		local ColorPicker = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local ImageLabel = Instance.new("ImageLabel")
		local UICorner_2 = Instance.new("UICorner")

		ColorPicker.Name = Phobia.RandomString();
		ColorPicker.Parent = Handler
		ColorPicker.BackgroundColor3 = Config.Default;
		ColorPicker.BackgroundTransparency = 0
		ColorPicker.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ColorPicker.BorderSizePixel = 0
		ColorPicker.ClipsDescendants = true
		ColorPicker.Size = UDim2.new(0, 18, 0, 18)
		ColorPicker.ZIndex = ZINdex + 13
		ColorPicker.LayoutOrder = -(#Handler:GetChildren() + 5);

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = ColorPicker

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = ColorPicker

		ImageLabel.Parent = ColorPicker
		ImageLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ImageLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ImageLabel.BorderSizePixel = 0
		ImageLabel.Size = UDim2.new(1, 0, 1, 0)
		ImageLabel.ZIndex = ZINdex + 11
		ImageLabel.Image = ""
		ImageLabel.ImageTransparency = 1
		ImageLabel.BackgroundTransparency = 1;
		ImageLabel.ScaleType = Enum.ScaleType.Crop

		UICorner_2.CornerRadius = UDim.new(0, 4)
		UICorner_2.Parent = ImageLabel

		local BackendM = Phobia:CreateColorPicker(ColorPicker);

		BackendM:SetValue(Config.Default)
		BackendM.Callback = function(color)
			ColorPicker.BackgroundColor3 = color;
			Config.Default = color;
			Config.Callback(Config.Default);
		end;

		local signal;
		Phobia:CreateInput(ColorPicker , LPH_NO_VIRTUALIZE(function()
			if signal then
				signal:Disconnect();
				signal = nil;
			end;

			BackendM.SetRender(true);

			signal = UserInputService.InputBegan:Connect(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					if not Phobia:IsMouseOverFrame(ColorPicker) and not Phobia:IsMouseOverFrame(BackendM.Root) then
						if signal then
							signal:Disconnect();
							signal = nil;
						end;

						BackendM.SetRender(false);
					end;
				end;
			end)
		end));

		ColorPickerLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(ColorPicker , SlowyTween , {
					BackgroundTransparency = 0
				})

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 0.650
				})

				Phobia.PlayAnimate(ImageLabel , SlowyTween , {
					ImageTransparency = 0.9
				})
			else
				Phobia.PlayAnimate(ColorPicker , SlowyTween , {
					BackgroundTransparency = 1
				})

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 1
				})

				Phobia.PlayAnimate(ImageLabel , SlowyTween , {
					ImageTransparency = 1
				})
			end;
		end);

		ColorPickerLib.SetRender(Signal:GetValue());
		Signal:Connect(ColorPickerLib.SetRender);

		function ColorPickerLib:GetValue()
			return Config.Default;
		end;

		function ColorPickerLib:SetValue(v)
			Config.Default = v;
			BackendM:SetValue(Config.Default)
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = ColorPickerLib;
		end;

		return ColorPickerLib;
	end;

	function handle:AddKeybind(Config)
		Config = Phobia:ProcessParams(Config,{
			Default = nil,
			Blacklist = {},
			Callback = EmptyFunction,
			Flag = nil
		});

		local KeybindLib = {};

		local Keybind = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local ValueLabel = Instance.new("TextLabel")

		Keybind.Name = Phobia.RandomString();
		Keybind.Parent = Handler
		Keybind.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		Keybind.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Keybind.BorderSizePixel = 0
		Keybind.ClipsDescendants = true
		Keybind.Size = UDim2.new(0, 45, 0, 18)
		Keybind.ZIndex = ZINdex + 13
		Keybind.LayoutOrder = -(#Handler:GetChildren() + 5);

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = Keybind

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = Keybind

		ValueLabel.Name = Phobia.RandomString();
		ValueLabel.Parent = Keybind
		ValueLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		ValueLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ValueLabel.BackgroundTransparency = 1.000
		ValueLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ValueLabel.BorderSizePixel = 0
		ValueLabel.ClipsDescendants = true
		ValueLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
		ValueLabel.Size = UDim2.new(1, 0, 1, 0)
		ValueLabel.ZIndex = ZINdex + 14
		ValueLabel.Font = Enum.Font.Gotham
		ValueLabel.Text = Phobia:KeyCodeToStr(Config.Default or "None")
		ValueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		ValueLabel.TextSize = 10.000
		ValueLabel.TextTransparency = 0.500

		KeybindLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(Keybind,SlowyTween, {
					BackgroundTransparency = 0
				})

				Phobia.PlayAnimate(UIStroke,SlowyTween, {
					Transparency = 0.650
				})

				Phobia.PlayAnimate(ValueLabel,SlowyTween, {
					TextTransparency = 0.500
				})
			else
				Phobia.PlayAnimate(Keybind,SlowyTween, {
					BackgroundTransparency = 1
				})

				Phobia.PlayAnimate(UIStroke,SlowyTween, {
					Transparency = 1
				})

				Phobia.PlayAnimate(ValueLabel,SlowyTween, {
					TextTransparency = 1
				})
			end;
		end);

		function KeybindLib:Update()
			local size = TextService:GetTextSize(ValueLabel.Text,ValueLabel.TextSize,ValueLabel.Font,Vector2.new(math.huge,math.huge));

			Phobia.PlayAnimate(Keybind , SlowyTween , {
				Size = UDim2.new(0, size.X + 7, 0, 18)
			})
		end;

		local IsBlacklist = LPH_NO_VIRTUALIZE(function(v)
			return Config.Blacklist and (Config.Blacklist[v] or table.find(Config.Blacklist,v))
		end);

		KeybindLib:Update()

		KeybindLib.SetRender(Signal:GetValue());
		Signal:Connect(KeybindLib.SetRender);

		local IsBinding = false;
		Phobia:CreateInput(Keybind , function()
			if IsBinding then
				return;
			end;

			IsBinding = true;

			ValueLabel.Text = "...";

			KeybindLib:Update();

			local Selected = nil;

			while not Selected do
				local Key = UserInputService.InputBegan:Wait();

				if Key.KeyCode ~= Enum.KeyCode.Unknown and not IsBlacklist(Key.KeyCode) and not IsBlacklist(Key.KeyCode.Name) then
					Selected = Key.KeyCode;
				else
					if Key.UserInputType == Enum.UserInputType.MouseButton1 and not IsBlacklist(Enum.UserInputType.MouseButton1) and not IsBlacklist("M1B") then
						Selected = "M1B";
					elseif Key.UserInputType == Enum.UserInputType.MouseButton2 and not IsBlacklist(Enum.UserInputType.MouseButton2) and not IsBlacklist("M2B") then
						Selected = "M2B";
					end;
				end;
			end;

			IsBinding = false;

			local KeyName = typeof(Selected) == "string" and Selected or Selected.Name;

			Config.Default = KeyName;
			KeybindLib.CurrentKey = KeyName;

			ValueLabel.Text = Phobia:KeyCodeToStr(KeyName);

			KeybindLib:Update();
		end)

		KeybindLib.CurrentKey = Config.Default;

		local function kbMatch(input, cur)
			if not cur or cur == "None" or cur == "" then return false end;
			if typeof(cur) == "string" then
				if cur == "M1B" then return input.UserInputType == Enum.UserInputType.MouseButton1 end;
				if cur == "M2B" then return input.UserInputType == Enum.UserInputType.MouseButton2 end;
				return input.KeyCode.Name == cur;
			end;
			return input.KeyCode == cur;
		end;

		Phobia:AddSignal(UserInputService.InputBegan:Connect(function(input, gpe)
			if gpe then return end;
			if IsBinding then return end;
			if kbMatch(input, KeybindLib.CurrentKey) then
				task.spawn(function() pcall(Config.Callback, true) end);
			end;
		end));

		Phobia:AddSignal(UserInputService.InputEnded:Connect(function(input, gpe)
			if kbMatch(input, KeybindLib.CurrentKey) then
				task.spawn(function() pcall(Config.Callback, false) end);
			end;
		end));

		function KeybindLib:GetValue()
			return Config.Default;
		end;

		function KeybindLib:SetValue(v)
			Config.Default = v;
			KeybindLib.CurrentKey = v;
			ValueLabel.Text = Phobia:KeyCodeToStr(v);
			KeybindLib:Update();
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = KeybindLib;
		end;

		return KeybindLib;
	end;

	function handle:AddTextInput(Config)
		Config = Phobia:ProcessParams(Config , {
			Default = "",
			Placeholder = "Placeholder",
			Callback = print,
			Flag = nil,
			Size = 100,
			Numeric = false,
		});

		local TextBoxLib = {};

		local TextInput = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local TextBox = Instance.new("TextBox")

		TextInput.Name = Phobia.RandomString();
		TextInput.Parent = Handler
		TextInput.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		TextInput.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TextInput.BorderSizePixel = 0
		TextInput.ClipsDescendants = true
		TextInput.Size = UDim2.new(0, Config.Size, 0, 18)
		TextInput.ZIndex = ZINdex + 13
		TextInput.LayoutOrder = -(#Handler:GetChildren() + 5);

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = TextInput

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = TextInput

		TextBox.Parent = TextInput
		TextBox.AnchorPoint = Vector2.new(0, 0.5)
		TextBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TextBox.BackgroundTransparency = 1.000
		TextBox.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TextBox.BorderSizePixel = 0
		TextBox.Position = UDim2.new(0, 5, 0.5, 0)
		TextBox.Size = UDim2.new(1, -5, 0, 17)
		TextBox.ZIndex = ZINdex + 14
		TextBox.ClearTextOnFocus = false
		TextBox.Font = Enum.Font.Gotham
		TextBox.PlaceholderText = Config.Placeholder
		TextBox.Text = tostring(Config.Default)
		TextBox.TextColor3 = Color3.fromRGB(255, 255, 255)
		TextBox.TextSize = 11.000
		TextBox.TextTransparency = 0.350
		TextBox.TextXAlignment = Enum.TextXAlignment.Left

		TextBoxLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(TextInput , SlowyTween ,{
					BackgroundTransparency = 0
				})	

				Phobia.PlayAnimate(UIStroke , SlowyTween ,{
					Transparency = 0.650
				})	

				Phobia.PlayAnimate(TextBox , SlowyTween ,{
					TextTransparency = 0.350
				})	
			else
				Phobia.PlayAnimate(TextInput , SlowyTween ,{
					BackgroundTransparency = 1
				})	

				Phobia.PlayAnimate(UIStroke , SlowyTween ,{
					Transparency = 1
				})	

				Phobia.PlayAnimate(TextBox , SlowyTween ,{
					TextTransparency = 1
				})
			end;
		end);

		Phobia:AddSignal(TextBox:GetPropertyChangedSignal('Text'):Connect(LPH_NO_VIRTUALIZE(function()
			local valout = Phobia:ParseInput(TextBox.Text , Config.Numeric);

			if Config.Numeric then
				TextBox.Text = string.gsub(TextBox.Text , '[^0-9.]','')
			end;

			if valout then
				Config.Default = valout;
				Config.Callback(valout);
			end
		end)));

		TextBoxLib.SetRender(Signal:GetValue());
		Signal:Connect(TextBoxLib.SetRender);

		function TextBoxLib:GetValue()
			return Config.Default;
		end;

		function TextBoxLib:SetValue(v)
			Config.Default = v;
			TextBox.Text = tostring(v);
			Config.Callback(Config.Default);
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = TextBoxLib;
		end;

		return TextBoxLib;
	end;

	function handle:AddDropdown(Config)
		Config = Phobia:ProcessParams(Config , {
			Default = nil,
			Values = {},
			Multi = false,
			Callback = EmptyFunction,
			AutoUpdate = false,
			Flag = nil,
			Size = 100
		})

		Config.Default = Phobia.ProcessDropdown(Config.Default);

		local Dropdown = Instance.new("Frame")
		local DropdownIcon = Instance.new("TextLabel")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local BasedLabel = Instance.new("TextLabel")

		Dropdown.Name = Phobia.RandomString();
		Dropdown.Parent = Handler
		Dropdown.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		Dropdown.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Dropdown.BorderSizePixel = 0
		Dropdown.ClipsDescendants = true
		Dropdown.Size = UDim2.new(0, Config.Size, 0, 18)
		Dropdown.ZIndex = ZINdex + 13
		Dropdown.LayoutOrder = -(#Handler:GetChildren() + 5);

		DropdownIcon.Name = Phobia.RandomString();
		DropdownIcon.Parent = Dropdown
		DropdownIcon.AnchorPoint = Vector2.new(1, 0.5)
		DropdownIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		DropdownIcon.BackgroundTransparency = 1.000
		DropdownIcon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		DropdownIcon.BorderSizePixel = 0
		DropdownIcon.Position = UDim2.new(1, -2, 0.5, 0)
		DropdownIcon.Size = UDim2.new(0, 18, 0, 18)
		DropdownIcon.ZIndex = ZINdex + 14
		DropdownIcon.Text = ""
		DropdownIcon.TextColor3 = Color3.fromRGB(223, 223, 223)
		DropdownIcon.TextTransparency = 0.250
		DropdownIcon.TextWrapped = true
		Phobia:ApplyIcon(DropdownIcon , 'chevron-small-down' , { Size = 15 });

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = Dropdown

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = Dropdown

		BasedLabel.Name = Phobia.RandomString();
		BasedLabel.Parent = Dropdown
		BasedLabel.AnchorPoint = Vector2.new(0, 0.5)
		BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.BackgroundTransparency = 1.000
		BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedLabel.BorderSizePixel = 0
		BasedLabel.ClipsDescendants = true
		BasedLabel.Position = UDim2.new(0, 5, 0.5, 0)
		BasedLabel.Size = UDim2.new(1, -25, 0, 15)
		BasedLabel.ZIndex = ZINdex + 14
		BasedLabel.Font = Enum.Font.Gotham
		BasedLabel.Text = Phobia.ParseDropdown(Config.Default);
		BasedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.TextSize = 12.000
		BasedLabel.TextTransparency = 0.5
		BasedLabel.TextXAlignment = Enum.TextXAlignment.Left

		do
			local UIGradient = Instance.new("UIGradient")

			UIGradient.Transparency = NumberSequence.new{NumberSequenceKeypoint.new(0.00, 0.00), NumberSequenceKeypoint.new(0.85, 0.23), NumberSequenceKeypoint.new(1.00, 1.00)}
			UIGradient.Parent = BasedLabel;
		end;

		Phobia:AddSignal(Dropdown.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(BasedLabel , SlowyTween , {
				TextTransparency = 0.200
			})
		end)));

		Phobia:AddSignal(Dropdown.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(BasedLabel , SlowyTween , {
				TextTransparency = 0.5
			})
		end)));

		local DropdownLib = {
			OpenSignal = Phobia:CreateSignal(false),
			Signals = {},
			Refuse = {},
		};

		DropdownLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(Dropdown , SlowyTween , {
					BackgroundTransparency = 0
				});

				Phobia.PlayAnimate(DropdownIcon , SlowyTween , {
					TextTransparency = 0.250
				});

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 0.650
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 0.5
				});
			else
				Phobia.PlayAnimate(Dropdown , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(DropdownIcon , SlowyTween , {
					TextTransparency = 1
				});

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 1
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 1
				});
			end
		end);

		DropdownLib.SetRender(Signal:GetValue())
		Signal:Connect(DropdownLib.SetRender);
		DropdownLib.ExtentSize = 0;

		do
			local DropdownHandler = Instance.new("Frame")
			local UICorner = Instance.new("UICorner")
			local UIStroke = Instance.new("UIStroke")
			local DropdownScrollFrame = Instance.new("ScrollingFrame")
			local UIListLayout = Instance.new("UIListLayout")
			local Shadow = Phobia:CreateShadow(DropdownHandler);

			DropdownHandler.Name = Phobia.RandomString();
			DropdownHandler.Parent = Phobia.ScreenGui;
			DropdownHandler.AnchorPoint = Vector2.new(0.5, 0)
			DropdownHandler.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
			DropdownHandler.BackgroundTransparency = 0.5
			DropdownHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
			DropdownHandler.BorderSizePixel = 0
			DropdownHandler.ClipsDescendants = true
			DropdownHandler.Position = UDim2.new(255,255,255,255)
			DropdownHandler.Size = UDim2.new(0, 125, 0, 50)
			DropdownHandler.ZIndex = ZINdex + 125
			DropdownLib.BlockRoot = DropdownHandler;

			Phobia:AddSignal(DropdownHandler:GetPropertyChangedSignal('BackgroundTransparency'):Connect(function()
				if DropdownHandler.BackgroundTransparency > 0.9 then
					DropdownHandler.Visible = false;
					DropdownHandler.Parent = nil;
				else
					DropdownHandler.Visible = true;

					if Phobia.Global3DRenderMode then
						DropdownHandler.Parent = Phobia.GlobalSurfaceGui;
					else
						DropdownHandler.Parent = Phobia.ScreenGui;
					end;
				end;
			end));

			UICorner.CornerRadius = UDim.new(0, 10)
			UICorner.Parent = DropdownHandler

			UIStroke.Transparency = 0.650
			UIStroke.Color = Color3.fromRGB(45, 48, 58)
			UIStroke.Parent = DropdownHandler

			DropdownScrollFrame.Name = Phobia.RandomString();
			DropdownScrollFrame.Parent = DropdownHandler
			DropdownScrollFrame.Active = true
			DropdownScrollFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			DropdownScrollFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownScrollFrame.BackgroundTransparency = 1.000
			DropdownScrollFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
			DropdownScrollFrame.BorderSizePixel = 0
			DropdownScrollFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			DropdownScrollFrame.Size = UDim2.new(1, -5, 1, -5)
			DropdownScrollFrame.ZIndex = ZINdex + 127
			DropdownScrollFrame.ScrollBarThickness = 0

			DropdownLib.RootItem = DropdownScrollFrame;

			UIListLayout.Parent = DropdownScrollFrame
			UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

			Phobia:AddSignal(UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
				DropdownScrollFrame.CanvasSize = UDim2.fromOffset(0,UIListLayout.AbsoluteContentSize.Y)
				Phobia.PlayAnimate(DropdownHandler , SlowyTween , {
					Size = UDim2.new(0, (Dropdown.AbsoluteSize.X + 5) + DropdownLib.ExtentSize, 0, math.min(UIListLayout.AbsoluteContentSize.Y + 5, 250));
				})
			end)));

			local SetPosition = LPH_NO_VIRTUALIZE(function()
				if Phobia:MoreThanHalfY(Dropdown.AbsolutePosition.Y + 85) then
					DropdownHandler.AnchorPoint = Vector2.new(0.5,1)
				else
					DropdownHandler.AnchorPoint = Vector2.new(0.5,0)
				end;

				DropdownHandler.Position = UDim2.fromOffset(Dropdown.AbsolutePosition.X + (DropdownHandler.AbsoluteSize.X / 2), Dropdown.AbsolutePosition.Y + 85);

			end);

			DropdownLib.SetFrameRender = LPH_NO_VIRTUALIZE(function(value)
				DropdownLib.OpenSignal:SetValue(value);

				if value then
					Shadow:Render(true);

					DropdownHandler.Size = UDim2.new(0, (Dropdown.AbsoluteSize.X + 5) + DropdownLib.ExtentSize, 0, math.min(UIListLayout.AbsoluteContentSize.Y + 5, 250));

					SetPosition();

					Phobia.PlayAnimate(DropdownHandler , SlowyTween , {
						BackgroundTransparency = 0.035
					})

					if Config.AutoUpdate then
						DropdownLib:Generate();
					end;
				else

					Phobia.PlayAnimate(DropdownHandler , SlowyTween , {
						BackgroundTransparency = 1
					})

					Shadow:Render(false);
				end;
			end);

			DropdownLib.SetFrameRender(false);
		end;

		local SecureSignal;
		Phobia:CreateInput(Dropdown , LPH_NO_VIRTUALIZE(function()
			if SecureSignal then
				SecureSignal:Disconnect();
				SecureSignal = nil;
			end;

			DropdownLib.SetFrameRender(true);
			Phobia.IsMosueOverOtherFrame = true;

			SecureSignal = UserInputService.InputBegan:Connect(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					if not Phobia:IsMouseOverFrame(DropdownLib.BlockRoot) and not Phobia:IsMouseOverFrame(Dropdown) then
						if SecureSignal then
							SecureSignal:Disconnect();
							SecureSignal = nil;
						end;

						Phobia.IsMosueOverOtherFrame = false;
						DropdownLib.SetFrameRender(false);
					end;
				end
			end)
		end))

		DropdownLib.IsMatch = LPH_NO_VIRTUALIZE(function(v1)
			if typeof(Config.Default) =='table' then
				if Config.Default[v1] or table.find(Config.Default , v1) then
					return true;
				end
			end

			if Config.Default == v1 then
				return true;
			end;
		end);

		function DropdownLib:Generate()
			for i,v in next , DropdownLib.RootItem:GetChildren() do
				if v:IsA('Frame') then
					v:Destroy();
				end;
			end;

			for i,v in next , DropdownLib.Signals do
				v:Disconnect();
			end;

			table.clear(DropdownLib.Signals);
			table.clear(DropdownLib.Refuse);

			local Lastone;
			for i,Value in next , Config.Values do
				local isSec = (typeof(Value) == "table" and (Value.Section ~= nil or Value.Divider == true))
				if isSec then
					local SecFrame = Instance.new("Frame")
					SecFrame.Name = Phobia.RandomString();
					SecFrame.Parent = DropdownLib.RootItem
					SecFrame.BackgroundTransparency = 1.000
					SecFrame.BorderSizePixel = 0
					if Value.Divider then
						SecFrame.Size = UDim2.new(1, 0, 0, 7)
					else
						SecFrame.Size = UDim2.new(1, 0, 0, 14)
					end;
					SecFrame.ZIndex = ZINdex + 1258
					if Value.Divider then
						local Div = Instance.new("Frame")
						Div.Name = Phobia.RandomString();
						Div.Parent = SecFrame
						Div.AnchorPoint = Vector2.new(0, 0.5)
						Div.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
						Div.BackgroundTransparency = 1.000
						Div.BorderSizePixel = 0
						Div.Position = UDim2.new(0, 15, 0.5, 0)
						Div.Size = UDim2.new(1, -30, 0, 1)
						local DivGrad = Instance.new("UIGradient")
						DivGrad.Color = ColorSequence.new(Color3.fromRGB(105, 115, 140))
						DivGrad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.22, 0), NumberSequenceKeypoint.new(0.78, 0), NumberSequenceKeypoint.new(1, 1)})
						DivGrad.Parent = Div
						Div.ZIndex = ZINdex + 1258
						table.insert(DropdownLib.Signals, DropdownLib.OpenSignal:Connect(LPH_NO_VIRTUALIZE(function(val)
							if val then
								Phobia.PlayAnimate(Div, SlowyTween, { BackgroundTransparency = 0 })
							else
								Phobia.PlayAnimate(Div, SlowyTween, { BackgroundTransparency = 1 })
							end;
						end)));
					else
						local SecLabel = Instance.new("TextLabel")
						SecLabel.Name = Phobia.RandomString();
						SecLabel.Parent = SecFrame
						SecLabel.BackgroundTransparency = 1.000
						SecLabel.BorderSizePixel = 0
						SecLabel.Position = UDim2.new(0, 15, 0, 0)
						SecLabel.Size = UDim2.new(1, -20, 0, 10)
						SecLabel.ZIndex = ZINdex + 1258
						SecLabel.Font = Enum.Font.GothamBold
						SecLabel.Text = tostring(Value.Section);
						SecLabel.TextColor3 = Color3.fromRGB(140, 150, 175)
						SecLabel.TextSize = 9.000
						SecLabel.TextTransparency = 1.000
						SecLabel.TextXAlignment = Enum.TextXAlignment.Center
						local SecLine = Instance.new("Frame")
						SecLine.Name = Phobia.RandomString();
						SecLine.Parent = SecFrame
						SecLine.AnchorPoint = Vector2.new(0, 1)
						SecLine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
						SecLine.BackgroundTransparency = 1.000
						SecLine.BorderSizePixel = 0
						SecLine.Position = UDim2.new(0, 15, 1, -1)
						SecLine.Size = UDim2.new(1, -30, 0, 1)
						SecLine.ZIndex = ZINdex + 1258
						local SecGrad = Instance.new("UIGradient")
						SecGrad.Color = ColorSequence.new(Color3.fromRGB(105, 115, 140))
						SecGrad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.22, 0), NumberSequenceKeypoint.new(0.78, 0), NumberSequenceKeypoint.new(1, 1)})
						SecGrad.Parent = SecLine
						local secsize = TextService:GetTextSize(SecLabel.Text, SecLabel.TextSize, SecLabel.Font, Vector2.new(math.huge, math.huge));
						DropdownLib.ExtentSize = math.max(DropdownLib.ExtentSize, secsize.X);
						table.insert(DropdownLib.Signals, DropdownLib.OpenSignal:Connect(LPH_NO_VIRTUALIZE(function(val)
							if val then
								Phobia.PlayAnimate(SecLabel, SlowyTween, { TextTransparency = 0.200 })
								Phobia.PlayAnimate(SecLine, SlowyTween, { BackgroundTransparency = 0 })
							else
								Phobia.PlayAnimate(SecLabel, SlowyTween, { TextTransparency = 1 })
								Phobia.PlayAnimate(SecLine, SlowyTween, { BackgroundTransparency = 1 })
							end;
						end)));
					end;
				else
					local ItemFrame = Instance.new("Frame")
					local ItemLabel = Instance.new("TextLabel")
					local UICorner = Instance.new("UICorner")

					ItemFrame.Name = Phobia.RandomString();
					ItemFrame.Parent = DropdownLib.RootItem
					ItemFrame.BackgroundColor3 = Color3.fromRGB(29, 31, 38)
					ItemFrame.BackgroundTransparency = 1.000
					ItemFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
					ItemFrame.BorderSizePixel = 0
					ItemFrame.Size = UDim2.new(1, 0, 0, 25)
					ItemFrame.ZIndex = ZINdex + 1258

					ItemLabel.Name = Phobia.RandomString();
					ItemLabel.Parent = ItemFrame
					ItemLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
					ItemLabel.BackgroundTransparency = 1.000
					ItemLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
					ItemLabel.BorderSizePixel = 0
					ItemLabel.Position = UDim2.new(0, 15, 0, 4)
					ItemLabel.Size = UDim2.new(0,1, 0, 15)
					ItemLabel.ZIndex = ZINdex + 1258
					ItemLabel.Font = Enum.Font.Gotham
					ItemLabel.Text = tostring(Value);
					ItemLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
					ItemLabel.TextSize = 13.000
					ItemLabel.TextTransparency = 0.200
					ItemLabel.TextXAlignment = Enum.TextXAlignment.Left

					UICorner.CornerRadius = UDim.new(0, 10)
					UICorner.Parent = ItemFrame
					local sizetext = TextService:GetTextSize(ItemLabel.Text , ItemLabel.TextSize,ItemLabel.Font,Vector2.new(math.huge,math.huge));

					DropdownLib.ExtentSize = math.max(DropdownLib.ExtentSize , sizetext.X);

					local MIcon , MarkItem = nil , nil;

					if Config.Multi then
						local Icon = Instance.new("TextLabel")

						Icon.Parent = ItemFrame;
						Icon.AnchorPoint = Vector2.new(0, 0.5)
						Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
						Icon.BackgroundTransparency = 1.000
						Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
						Icon.BorderSizePixel = 0
						Icon.Position = UDim2.new(0, 5, 0.5, 0)
						Icon.Size = UDim2.new(0, 20, 0, 20)
						Icon.ZIndex = ZINdex + 1259
						Icon.Text = "";
						Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
						Icon.TextTransparency = 1
						Icon.TextWrapped = true;
						Phobia:ApplyIcon(Icon , 'check' , { Size = 17 });

						local VisiblewOfMult = LPH_NO_VIRTUALIZE(function()
							if DropdownLib.IsMatch(Value) then
								Phobia.PlayAnimate(ItemLabel , VSlowTween , {
									TextTransparency = 0.200,
									Position = UDim2.new(0, 30, 0, 4)
								})

								Phobia.PlayAnimate(Icon , vs , {
									TextTransparency = 0.250
								})

								Lastone = ItemLabel;
							else

								Phobia.PlayAnimate(Icon , SlowyTween , {
									TextTransparency = 1
								})

								Phobia.PlayAnimate(ItemLabel , VSlowTween , {
									TextTransparency = 0.5,
									Position = UDim2.new(0, 15, 0, 4)
								})
							end;
						end);

						MIcon = Icon;
						MarkItem = VisiblewOfMult;
					else
						local DefaultVisible = LPH_NO_VIRTUALIZE(function()
							if DropdownLib.IsMatch(Value) then
								Phobia.PlayAnimate(ItemLabel , SlowyTween , {
									TextTransparency = 0.200
								})

								Lastone = ItemLabel;
							else
								Phobia.PlayAnimate(ItemLabel , SlowyTween , {
									TextTransparency = 0.5
								})
							end;
						end);

						MarkItem = DefaultVisible;
					end;

					MarkItem();

					table.insert(DropdownLib.Refuse , MarkItem)

					table.insert(DropdownLib.Signals,ItemFrame.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
						Phobia.PlayAnimate(ItemFrame , SlowyTween , {
							BackgroundTransparency = 0.1
						})
					end)));

					table.insert(DropdownLib.Signals,ItemFrame.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
						Phobia.PlayAnimate(ItemFrame , SlowyTween , {
							BackgroundTransparency = 1
						})
					end)));

					table.insert(DropdownLib.Signals , DropdownLib.OpenSignal:Connect(LPH_NO_VIRTUALIZE(function(val)
						if val then
							MarkItem();
						else
							Phobia.PlayAnimate(ItemLabel , SlowyTween , {
								TextTransparency = 1
							})

							if MIcon then
								Phobia.PlayAnimate(MIcon , SlowyTween , {
									TextTransparency = 1
								})
							end;
						end;
					end)));

					if Config.Multi then
						local _,bth_signal = Phobia:CreateInput(ItemFrame , LPH_NO_VIRTUALIZE(function()
							Config.Default[Value] = not Config.Default[Value];

							MarkItem();

							BasedLabel.Text = Phobia.ParseDropdown(Config.Default);

							Config.Callback(Config.Default);
						end));

						table.insert(DropdownLib.Signals , bth_signal);
					else
						local _,bth_signal = Phobia:CreateInput(ItemFrame , LPH_NO_VIRTUALIZE(function()
							Config.Default = Value;

							for i,v in next , DropdownLib.Refuse do
								task.spawn(v);
							end;

							BasedLabel.Text = Phobia.ParseDropdown(Config.Default);

							Config.Callback(Config.Default);
						end));

						table.insert(DropdownLib.Signals , bth_signal);
					end;
				end
			end;
		end;

		DropdownLib:Generate();

		function DropdownLib:GetValue()
			return Config.Default;
		end;

		function DropdownLib:SetValue(v)
			Config.Default = v;

			BasedLabel.Text = Phobia.ParseDropdown(Config.Default);

			for i,v in next , DropdownLib.Refuse do
				task.spawn(v);
			end;

			Config.Callback(Config.Default);
		end;

		function DropdownLib:SetValues(a)
			Config.Values = a;

			if not Config.AutoUpdate then
				DropdownLib:Generate();
			end;
		end;

		if Config.Flag then
			Phobia.Flags[Config.Flag] = DropdownLib;
		end;

		return DropdownLib;
	end;

	return handle;
end;

Phobia.ProcessDropdown = LPH_NO_VIRTUALIZE(function(value)
	if typeof(value) == 'table' then
		local data = {};

		for i,v in next , value do
			if typeof(v) == 'boolean' and typeof(i) ~= 'number' then
				data[i] = v;
			else
				data[v] = true;
			end;
		end;

		return data;
	else
		return value;
	end;
end);

Phobia.ParseDropdown = LPH_NO_VIRTUALIZE(function(value)
	if not value then return 'Select'; end;

	local Out;

	if typeof(value) == 'table' then
		if #value > 0 then
			local x = {};

			for i,v in next , value do
				table.insert(x , tostring(v))
			end;

			Out = table.concat(x,' , ');

			table.clear(x);
		else
			local x = {};

			for i,v in next , value do
				if v == true then
					table.insert(x , tostring(i));
				end			
			end;

			Out = table.concat(x,' , ');

			table.clear(x)

			if not Out:byte() then
				Out = 'Select';
			end
		end;
	else
		Out = tostring(value or 'Select');
	end;

	return Out;
end);

function Phobia:ParseInput(Value , Numeric)
	if not Value then
		return (Numeric and nil) or "";	
	end;

	if Numeric then
		local out = string.gsub(tostring(Value), '[^0-9.%-]', '')

		if tonumber(out) then
			return tonumber(out);
		end;

		return nil;
	end;

	return Value;
end;

function Phobia:CreateToolTips(Container: Frame , Name: string , Content: string)
	local Tooltips = Instance.new("Frame")
	local UICorner = Instance.new("UICorner")
	local UIStroke = Instance.new("UIStroke")
	local TooltipName = Instance.new("TextLabel")
	local TooltipContent = Instance.new("TextLabel")
	local Shadow = Phobia:CreateShadow(Tooltips);

	Tooltips.Name = Phobia.RandomString();
	Tooltips.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
	Tooltips.BackgroundTransparency = 0.075
	Tooltips.BorderColor3 = Color3.fromRGB(0, 0, 0)
	Tooltips.BorderSizePixel = 0
	Tooltips.ClipsDescendants = true
	Tooltips.Position = UDim2.new(255,255,255,255)
	Tooltips.Size = UDim2.new(0,0,0,0)
	Tooltips.ZIndex = 130

	UICorner.CornerRadius = UDim.new(0, 10)
	UICorner.Parent = Tooltips

	UIStroke.Transparency = 0.650
	UIStroke.Color = Color3.fromRGB(45, 48, 58)
	UIStroke.Parent = Tooltips

	TooltipName.Name = Phobia.RandomString();
	TooltipName.Parent = Tooltips
	TooltipName.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	TooltipName.BackgroundTransparency = 1.000
	TooltipName.BorderColor3 = Color3.fromRGB(0, 0, 0)
	TooltipName.BorderSizePixel = 0
	TooltipName.Position = UDim2.new(0, 15, 0, 5)
	TooltipName.Size = UDim2.new(0, 1, 0, 20)
	TooltipName.ZIndex = 132
	TooltipName.Font = Enum.Font.GothamMedium
	TooltipName.Text = Name
	TooltipName.TextColor3 = Color3.fromRGB(255, 255, 255)
	TooltipName.TextSize = 15.000
	TooltipName.TextXAlignment = Enum.TextXAlignment.Left

	TooltipContent.Name = Phobia.RandomString();
	TooltipContent.Parent = Tooltips
	TooltipContent.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	TooltipContent.BackgroundTransparency = 1.000
	TooltipContent.BorderColor3 = Color3.fromRGB(0, 0, 0)
	TooltipContent.BorderSizePixel = 0
	TooltipContent.Position = UDim2.new(0, 15, 0, 30)
	TooltipContent.Size = UDim2.new(0, 1, 0, 15)
	TooltipContent.ZIndex = 132
	TooltipContent.Font = Enum.Font.GothamMedium
	TooltipContent.Text = Content
	TooltipContent.TextColor3 = Color3.fromRGB(255, 255, 255)
	TooltipContent.TextSize = 12.000
	TooltipContent.TextTransparency = 0.650
	TooltipContent.TextXAlignment = Enum.TextXAlignment.Left
	TooltipContent.TextYAlignment = Enum.TextYAlignment.Top

	local ToolTip = {};

	ToolTip.Update = LPH_NO_VIRTUALIZE(function()
		local SizeName = TextService:GetTextSize(TooltipName.Text , TooltipName.TextSize , TooltipName.Font , Vector2.new(math.huge,math.huge));
		local SizeContent = TextService:GetTextSize(TooltipContent.Text , TooltipContent.TextSize , TooltipContent.Font , Vector2.new(math.huge,math.huge));

		local MaxX = math.max(SizeName.X , SizeContent.X) + 65;
		local MaxY = SizeName.Y + SizeContent.Y + 30;

		Phobia.PlayAnimate(Tooltips,SlowyTween , {
			Size = UDim2.new(0,MaxX,0,MaxY)
		})
	end)

	Phobia:AddSignal(Tooltips:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
		if Tooltips.BackgroundTransparency > 0.9 then
			Tooltips.Visible = false;
			Tooltips.Parent = nil;
		else
			Tooltips.Visible = true;

			if Phobia.Global3DRenderMode then
				Tooltips.Parent = Phobia.GlobalSurfaceGui;
			else
				Tooltips.Parent = Phobia.ScreenGui;
			end;
		end
	end)));

	ToolTip.SetRender = LPH_NO_VIRTUALIZE(function(value)
		if value then
			Tooltips.Position = UDim2.fromOffset(Container.AbsolutePosition.X + Container.AbsoluteSize.X , Container.AbsolutePosition.Y + (Container.AbsoluteSize.Y + 25));

			Phobia.PlayAnimate(Tooltips , SlowyTween , {
				BackgroundTransparency = 0.075
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 0.650
			})

			Phobia.PlayAnimate(TooltipName , SlowyTween , {
				TextTransparency = 0
			})

			Phobia.PlayAnimate(TooltipContent , SlowyTween , {
				TextTransparency = 0.650
			})

			ToolTip.Update();
			Shadow:Render(true);
		else
			Phobia.PlayAnimate(Tooltips , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(TooltipName , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(TooltipContent , SlowyTween , {
				TextTransparency = 1
			})

			Shadow:Render(false);
		end;
	end);

	ToolTip.SetRender(false);
	ToolTip.Update();

	local DelayThread;
	Phobia:AddSignal(Container.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
		if DelayThread then
			task.cancel(DelayThread);
			DelayThread = nil;
		end;

		DelayThread = task.delay(1,ToolTip.SetRender,true);
	end)));

	Phobia:AddSignal(Container.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
		if DelayThread then
			task.cancel(DelayThread);
			DelayThread = nil;
		end;

		ToolTip.SetRender(false);
		ToolTip.Update();
	end)))

	return ToolTip;
end;

function Phobia:RegisiterItem(Frame: Frame , Signel)
	local idx = {};
	local LayerIndex = Frame.ZIndex;


	function idx:AddImage(Config)
		Config = Config or {}
		local BasedFrame = Instance.new("Frame")
		local Image = Instance.new("ImageLabel")
		local LineFrame = Instance.new("Frame")
		BasedFrame.Name = Phobia.RandomString();
		BasedFrame.Parent = Frame
		BasedFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		BasedFrame.BackgroundTransparency = 1.000
		BasedFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedFrame.BorderSizePixel = 0
		BasedFrame.Size = Config.Size or UDim2.new(1, 0, 0, 120)
		BasedFrame.ZIndex = LayerIndex + 8
		Phobia:AddQuery(BasedFrame , "Image");
		Image.Name = Phobia.RandomString();
		Image.Parent = BasedFrame
		Image.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Image.BackgroundTransparency = 1.000
		Image.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Image.BorderSizePixel = 0
		Image.Position = UDim2.new(0, 0, 0, 0)
		Image.Size = UDim2.new(1, 0, 1, 0)
		Image.ZIndex = LayerIndex + 9
		Image.Image = Config.Image or ""
		Image.ScaleType = Config.ScaleType or Enum.ScaleType.Fit
		Image.ImageTransparency = Config.Transparency or 0
		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = BasedFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = LayerIndex + 11
		return Image;
	end;

	function idx:AddColoredLabel(Name: string, Color: Color3)
		local BasedFrame = Instance.new("Frame")
		local BasedLabel = Instance.new("TextLabel")
		local LineFrame = Instance.new("Frame")
		BasedFrame.Name = Phobia.RandomString();
		BasedFrame.Parent = Frame
		BasedFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		BasedFrame.BackgroundTransparency = 1.000
		BasedFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedFrame.BorderSizePixel = 0
		BasedFrame.Size = UDim2.new(1, 0, 0, 32)
		BasedFrame.ZIndex = LayerIndex + 8
		Phobia:AddQuery(BasedFrame , Name);
		BasedLabel.Name = Phobia.RandomString();
		BasedLabel.Parent = BasedFrame
		BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.BackgroundTransparency = 1.000
		BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedLabel.BorderSizePixel = 0
		BasedLabel.Position = UDim2.new(0, 11, 0, 6)
		BasedLabel.Size = UDim2.new(0, 1, 0, 18)
		BasedLabel.ZIndex = LayerIndex + 9
		BasedLabel.Font = Enum.Font.GothamMedium
		BasedLabel.Text = Name
		BasedLabel.TextColor3 = Color or Color3.fromRGB(138, 116, 255)
		BasedLabel.TextSize = 16.000
		BasedLabel.TextTransparency = 0
		BasedLabel.TextXAlignment = Enum.TextXAlignment.Left
		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = BasedFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = LayerIndex + 11
		return BasedLabel;
	end;

	function idx:AddLabel(Name: string,Warp: boolean)
		local BasedFrame = Instance.new("Frame")
		local BasedLabel = Instance.new("TextLabel")
		local LineFrame = Instance.new("Frame")
		local BasedHandler = Instance.new("Frame")
		local UIListLayout = Instance.new("UIListLayout")
		local UICorner = Instance.new("UICorner")

		BasedFrame.Name = Phobia.RandomString();
		BasedFrame.Parent = Frame
		BasedFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		BasedFrame.BackgroundTransparency = 1.000
		BasedFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedFrame.BorderSizePixel = 0
		BasedFrame.Size = UDim2.new(1, 0, 0, 30)
		BasedFrame.ZIndex = LayerIndex + 8

		Phobia:AddQuery(BasedFrame , Name);

		BasedLabel.Name = Phobia.RandomString();
		BasedLabel.Parent = BasedFrame
		BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.BackgroundTransparency = 1.000
		BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedLabel.BorderSizePixel = 0
		BasedLabel.Position = UDim2.new(0, 11, 0, 6)
		BasedLabel.Size = UDim2.new(0,1, 0, 15)
		BasedLabel.ZIndex = LayerIndex + 9
		BasedLabel.Font = Enum.Font.Gotham
		BasedLabel.Text = Name
		BasedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.TextSize = 13.000
		BasedLabel.TextTransparency = 0.35
		BasedLabel.TextXAlignment = Enum.TextXAlignment.Left

		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = BasedFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = LayerIndex + 11

		BasedHandler.Name = Phobia.RandomString();
		BasedHandler.Parent = BasedFrame
		BasedHandler.AnchorPoint = Vector2.new(1, 0)
		BasedHandler.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedHandler.BackgroundTransparency = 1.000
		BasedHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedHandler.BorderSizePixel = 0
		BasedHandler.Position = UDim2.new(1, -11, 0, 2)
		BasedHandler.Size = UDim2.new(1, -20, 0, 25)
		BasedHandler.ZIndex = LayerIndex + 12

		UIListLayout.Parent = BasedHandler
		UIListLayout.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		UIListLayout.Padding = UDim.new(0, 5)

		UICorner.CornerRadius = UDim.new(0, 10)
		UICorner.Parent = BasedFrame

		local UpdateWarp = LPH_NO_VIRTUALIZE(function()
			local size = TextService:GetTextSize(BasedLabel.Text , BasedLabel.TextSize , BasedLabel.Font , Vector2.new(math.huge,math.huge));
			Phobia.PlayAnimate(BasedFrame , SlowyTween , {
				Size = UDim2.new(1, 0, 0, size.Y + 13);
			})

			BasedLabel.Size = UDim2.new(1, -35, 1, 0)
			BasedLabel.TextYAlignment = Enum.TextYAlignment.Top;
		end);

		if Warp then
			UpdateWarp();
		end;

		local handle = Phobia:RegisiterHandler(BasedHandler , Signel);

		handle.Root = BasedFrame;

		handle.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(BasedFrame , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 0.35
				})

				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 0.650
				})
			else
				Phobia.PlayAnimate(BasedFrame , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 1
				})

				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 1
				})
			end;
		end);

		function handle:SetVisible(val)
			BasedFrame.Visible = val;
		end;

		Phobia:AddSignal(BasedFrame.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(BasedFrame , SlowyTween , {
				BackgroundTransparency = 0.35
			});

			Phobia.PlayAnimate(BasedLabel , SlowyTween , {
				TextTransparency = 0.25
			})

		end)))

		Phobia:AddSignal(BasedFrame.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(BasedFrame , SlowyTween , {
				BackgroundTransparency = 1
			});

			Phobia.PlayAnimate(BasedLabel , SlowyTween , {
				TextTransparency = 0.35
			})
		end)))

		function handle:SetText(t)
			local oldtxt = BasedLabel.Text;

			BasedLabel.Text = t;

			if Warp and oldtxt ~= t then
				UpdateWarp();
			end;
		end;

		function handle:ToolTip(Content: string)
			handle.ToolTip = Phobia:CreateToolTips(BasedFrame , Name , Content);

			return handle;
		end;

		handle.SetRender(Signel:GetValue());
		Signel:Connect(handle.SetRender);

		return handle;
	end;

	function idx:AddButton(Config)
		Config = Phobia:ProcessParams(Config , {
			Icon = 'chevron-large-left',
			Name = "Button",
			Callback = EmptyFunction,
			ToolTip = nil,
		});

		local Button = {};
		local ButtonFrame = Instance.new("Frame")
		local BasedLabel = Instance.new("TextLabel")
		local LineFrame = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local Icon = Instance.new("TextLabel")

		Phobia:AddQuery(ButtonFrame , Config.Name);

		ButtonFrame.Name = Phobia.RandomString();
		ButtonFrame.Parent = Frame
		ButtonFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		ButtonFrame.BackgroundTransparency = 1.000
		ButtonFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ButtonFrame.BorderSizePixel = 0
		ButtonFrame.Size = UDim2.new(1, 0, 0, 30)
		ButtonFrame.ZIndex = LayerIndex + 8

		BasedLabel.Name = Phobia.RandomString();
		BasedLabel.Parent = ButtonFrame
		BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.BackgroundTransparency = 1.000
		BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedLabel.BorderSizePixel = 0
		BasedLabel.Position = UDim2.new(0, 35, 0, 6)
		BasedLabel.Size = UDim2.new(0,1, 0, 15)
		BasedLabel.ZIndex = LayerIndex + 9
		BasedLabel.Font = Enum.Font.Gotham
		BasedLabel.Text = Config.Name;
		BasedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.TextSize = 13.000
		BasedLabel.TextTransparency = 0.200
		BasedLabel.TextXAlignment = Enum.TextXAlignment.Left

		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = ButtonFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = LayerIndex + 11

		UICorner.CornerRadius = UDim.new(0, 10)
		UICorner.Parent = ButtonFrame

		Icon.Name = Phobia.RandomString();
		Icon.Parent = ButtonFrame
		Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Icon.BackgroundTransparency = 1.000
		Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Icon.BorderSizePixel = 0
		Icon.Position = UDim2.new(0, 11, 0, 5)
		Icon.Size = UDim2.new(0, 18, 0, 18)
		Icon.ZIndex = LayerIndex + 9
		Icon.Text = ""
		Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
		Icon.TextTransparency = 0.250
		Icon.TextWrapped = true
		Phobia:ApplyIcon(Icon , Config.Icon , { Size = 16 });

		function Button:SetText(t)
			BasedLabel.Text = t;
		end;

		function Button:SetIcon(t)
			Phobia:ApplyIcon(Icon , t , { Size = 16 });
		end;

		local bth = Phobia:CreateInput(ButtonFrame , LPH_NO_VIRTUALIZE(function()
			Config.Callback();
		end));

		Phobia:AddSignal(bth.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(ButtonFrame , SlowyTween , {
				BackgroundTransparency = 0.35
			});
		end)))

		Phobia:AddSignal(bth.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(ButtonFrame , SlowyTween , {
				BackgroundTransparency = 1
			});
		end)))

		Button.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(ButtonFrame , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 0.200
				});

				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 0.650
				});

				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 0.250
				});
			else
				Phobia.PlayAnimate(ButtonFrame , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 1
				});

				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 1
				});
			end;
		end);

		if Config.ToolTip then
			Button.ToolTip = Phobia:CreateToolTips(ButtonFrame , Config.Name , Config.ToolTip);
		end;

		Button.SetRender(Signel:GetValue())
		Signel:Connect(Button.SetRender);

		return Button;
	end;

	function idx:AddUserFrame(Name : string , Profile: string , Expires : string)
		local UserFrame = Instance.new("Frame")
		local UserLabel = Instance.new("TextLabel")
		local LineFrame = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local LogoImage = Instance.new("ImageLabel")
		local UICorner_2 = Instance.new("UICorner")
		local UserStatusLabel = Instance.new("TextLabel")

		UserFrame.Name = Phobia.RandomString();
		UserFrame.Parent = Frame
		UserFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		UserFrame.BackgroundTransparency = 1.000
		UserFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		UserFrame.BorderSizePixel = 0
		UserFrame.Size = UDim2.new(1, 0, 0, 60)
		UserFrame.ZIndex = LayerIndex + 8

		UserLabel.Name = Phobia.RandomString();
		UserLabel.Parent = UserFrame
		UserLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		UserLabel.BackgroundTransparency = 1.000
		UserLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		UserLabel.BorderSizePixel = 0
		UserLabel.Position = UDim2.new(0, 65, 0, 10)
		UserLabel.Size = UDim2.new(1, -35, 0, 15)
		UserLabel.ZIndex = LayerIndex + 9
		UserLabel.Font = Enum.Font.Gotham
		UserLabel.Text = Name or 'User'
		UserLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		UserLabel.TextSize = 13.000
		UserLabel.TextTransparency = 0.200
		UserLabel.TextXAlignment = Enum.TextXAlignment.Left

		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = UserFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = LayerIndex + 11

		UICorner.CornerRadius = UDim.new(0, 10)
		UICorner.Parent = UserFrame

		LogoImage.Name = Phobia.RandomString();
		LogoImage.Parent = UserFrame
		LogoImage.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		LogoImage.BackgroundTransparency = 1.000
		LogoImage.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LogoImage.BorderSizePixel = 0
		LogoImage.Position = UDim2.new(0, 10, 0, 5)
		LogoImage.Size = UDim2.new(0, 45, 0, 45)
		LogoImage.ZIndex = LayerIndex + 9
		LogoImage.ScaleType = Enum.ScaleType.Fit;
		if type(Profile) == 'string' and string.find(Profile , 'rbxasset' , 1 , true) then
			LogoImage.Image = Profile;
		else
			LogoImage.Image = '';
			Phobia:ApplyIcon(LogoImage , 'user' , { Size = 26 , Color = Color3.fromRGB(223, 223, 223) , Transparency = 0 });
		end;

		UICorner_2.CornerRadius = UDim.new(1, 0)
		UICorner_2.Parent = LogoImage

		UserStatusLabel.Name = Phobia.RandomString();
		UserStatusLabel.Parent = UserFrame
		UserStatusLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		UserStatusLabel.BackgroundTransparency = 1.000
		UserStatusLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		UserStatusLabel.BorderSizePixel = 0
		UserStatusLabel.Position = UDim2.new(0, 65, 0, 25)
		UserStatusLabel.Size = UDim2.new(1, -35, 0, 15)
		UserStatusLabel.ZIndex = LayerIndex + 9
		UserStatusLabel.Font = Enum.Font.Gotham
		UserStatusLabel.Text = Expires or 'Never'
		UserStatusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		UserStatusLabel.TextSize = 13.000
		UserStatusLabel.TextTransparency = 0.200
		UserStatusLabel.TextXAlignment = Enum.TextXAlignment.Left

		local UserFrameItem = {};

		UserFrameItem.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				Phobia.PlayAnimate(UserLabel,SlowyTween,{
					TextTransparency = 0.200
				})

				Phobia.PlayAnimate(LineFrame,SlowyTween,{
					BackgroundTransparency = 0.650
				})

				Phobia.PlayAnimate(LogoImage,SlowyTween,{
					ImageTransparency = 0
				})

				Phobia.PlayAnimate(UserStatusLabel,SlowyTween,{
					TextTransparency = 0.200
				})
			else
				Phobia.PlayAnimate(UserLabel,SlowyTween,{
					TextTransparency = 1
				})

				Phobia.PlayAnimate(LineFrame,SlowyTween,{
					BackgroundTransparency = 1
				})

				Phobia.PlayAnimate(LogoImage,SlowyTween,{
					ImageTransparency = 1
				})

				Phobia.PlayAnimate(UserStatusLabel,SlowyTween,{
					TextTransparency = 1
				})
			end;
		end);

		UserFrameItem.SetRender(Signel:GetValue())
		Signel:Connect(UserFrameItem.SetRender);

		function UserFrameItem:SetUsername(name)
			UserLabel.Text = name or 'User'
		end;

		function UserFrameItem:SetProfile(Profile)
			Phobia.Icons.Clear(LogoImage);
			LogoImage.ScaleType = Enum.ScaleType.Fit;
			if type(Profile) == 'string' and string.find(Profile , 'rbxasset' , 1 , true) then
				LogoImage.Image = Profile;
			else
				LogoImage.Image = '';
				Phobia:ApplyIcon(LogoImage , 'user' , { Size = 26 , Color = Color3.fromRGB(223, 223, 223) , Transparency = 0 });
			end;
		end;

		function UserFrameItem:SetExpires(Exp)
			UserStatusLabel.Text = Exp or 'Never';
		end;

		return UserFrameItem;
	end;

	return idx;
end;

function Phobia:CreateWindow(Config)
	Config = Phobia:ProcessParams(Config , {
		Logo = Phobia.GlobalLogo,
		Name = "Phobia",
		Content = "Roblox",
		Size = UDim2.new(0, 640, 0, 480),
		ConfigFolder = "Phobia/Configs",
		Enable3DRenderer = false,
		Keybind = "Insert"
	});

	local Window = {
		Logo = Config.Logo,
		Name = Config.Name,
		Content = Config.Content,
		Size = Config.Size,
		ConfigFolder = Config.ConfigFolder,
		Signal = Phobia:CreateSignal(true),
		Tabs = {},
		CurrentTab = 1,
		Keybind = Config.Keybind,
		Enable3DRenderer = Config.Enable3DRenderer
	};

	Phobia.GlobalLogo = Window.Logo;

	local Logging = Phobia:CreateLogger();
	if not isfolder(Window.ConfigFolder) then
		makefolder(Window.ConfigFolder);
	end;

	local WindowFrame = Instance.new("Frame")
	local UICorner = Instance.new("UICorner")
	local LeftMenuFrame = Instance.new("Frame")
	local HeadFrame = Instance.new("Frame")
	local LogoImage = Instance.new("ImageLabel")
	local UICorner_2 = Instance.new("UICorner")
	local WindowName = Instance.new("TextLabel")
	local WindowContent = Instance.new("TextLabel")
	local LineFrame = Instance.new("Frame")
	local LeftScrollingFrame = Instance.new("ScrollingFrame")
	local UIListLayout = Instance.new("UIListLayout")
	local BottomFrame = Instance.new("Frame")
	local AccountProfile = Instance.new("ImageLabel")
	local UICorner_3 = Instance.new("UICorner")
	local AccountName = Instance.new("TextLabel")
	local ExpireLabel = Instance.new("TextLabel")
	local LineFrame_2 = Instance.new("Frame")
	local UserSettingButton = Instance.new("TextLabel")
	local RightMenuFrame = Instance.new("Frame")
	local UIStroke = Instance.new("UIStroke")
	local UICorner_4 = Instance.new("UICorner")
	local RightHeader = Instance.new("Frame")
	local LineFrame_3 = Instance.new("Frame")
	local ConfigFrame = Instance.new("Frame")
	local UIStroke_2 = Instance.new("UIStroke")
	local UICorner_5 = Instance.new("UICorner")
	local ConfigIcon = Instance.new("TextLabel")
	local LineFrame_4 = Instance.new("Frame")
	local ConfigName = Instance.new("TextLabel")
	local ConfigBthIcon = Instance.new("TextLabel")
	local SearchFrame = Instance.new("Frame")
	local SearchIcon = Instance.new("TextLabel")
	local SearchBox = Instance.new("TextBox")
	local TabContainer = Instance.new("Frame")

	WindowFrame.Name = Phobia.RandomString();
	WindowFrame.Parent = Phobia.ScreenGui;  Window.Root = WindowFrame;
	WindowFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	WindowFrame.BackgroundColor3 = Phobia.MainColor
	WindowFrame.BackgroundTransparency = 0.055
	WindowFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	WindowFrame.BorderSizePixel = 0
	WindowFrame.ClipsDescendants = true
	WindowFrame.Position = UDim2.new(255, 0, 255, 0)
	WindowFrame.Size = Window.Size
	WindowFrame.Active = true;

	if not Phobia.EnabledBlur then
		WindowFrame.BackgroundTransparency = 0.0255
	end;

	local renderParentWindow = LPH_NO_VIRTUALIZE(function()
		if Window.__3DRender then
			if WindowFrame.BackgroundTransparency > 0.9 then
				WindowFrame.Visible = false;
				WindowFrame.Parent = nil
			else
				WindowFrame.Visible = true;

				Phobia.PlayAnimate(WindowFrame,VSlowTween , {
					Position = UDim2.fromScale(0.5,0.5);
				});

				WindowFrame.Parent = Window.SurfaceGui;
			end;
		else
			if WindowFrame.BackgroundTransparency > 0.9 then
				WindowFrame.Visible = false;
				WindowFrame.Parent = nil
			else
				WindowFrame.Visible = true;
				WindowFrame.Parent = Phobia.ScreenGui


			end;
		end;
	end);

	Phobia:AddSignal(WindowFrame:GetPropertyChangedSignal('BackgroundTransparency'):Connect(renderParentWindow))

	Window.SetRender = LPH_NO_VIRTUALIZE(function(self , value)
		if value then
			Phobia.PlayAnimate(WindowFrame , SlowyTween , {
				BackgroundTransparency = (Phobia.EnabledBlur and 0.055) or 0.0255,
				Size = Window.Size
			})

			Phobia.PlayAnimate(LogoImage , SlowyTween , {
				ImageTransparency = 0
			})

			Phobia.PlayAnimate(WindowName , SlowyTween , {
				TextTransparency = 0
			})

			Phobia.PlayAnimate(WindowContent , SlowyTween , {
				TextTransparency = 0.650
			})

			Phobia.PlayAnimate(LineFrame , SlowyTween , {
				BackgroundTransparency = 0.650
			})

			Phobia.PlayAnimate(AccountProfile , SlowyTween , {
				ImageTransparency = 0
			})

			Phobia.PlayAnimate(AccountName , SlowyTween , {
				TextTransparency = 0
			})

			Phobia.PlayAnimate(ExpireLabel , SlowyTween , {
				TextTransparency = 0.650
			})

			Phobia.PlayAnimate(LineFrame_2 , SlowyTween , {
				BackgroundTransparency = 0.650
			})

			Phobia.PlayAnimate(UserSettingButton , SlowyTween , {
				TextTransparency = 0.5
			})

			Phobia.PlayAnimate(RightMenuFrame , SlowyTween , {
				BackgroundTransparency = 0.600
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 0.650
			})

			Phobia.PlayAnimate(LineFrame_3 , SlowyTween , {
				BackgroundTransparency = 0.650
			})

			Phobia.PlayAnimate(ConfigFrame , SlowyTween , {
				BackgroundTransparency = 0.750
			})

			Phobia.PlayAnimate(UIStroke_2 , SlowyTween , {
				Transparency = 0.650
			})

			Phobia.PlayAnimate(ConfigIcon , SlowyTween , {
				TextTransparency = 0.250
			})

			Phobia.PlayAnimate(LineFrame_4 , SlowyTween , {
				BackgroundTransparency = 0.650
			})

			Phobia.PlayAnimate(ConfigName , SlowyTween , {
				TextTransparency = 0.350
			})

			Phobia.PlayAnimate(ConfigBthIcon , SlowyTween , {
				TextTransparency = 0.250
			})

			Phobia.PlayAnimate(SearchIcon , SlowyTween , {
				TextTransparency = 0.250
			})

			Phobia.PlayAnimate(SearchBox , SlowyTween , {
				TextTransparency = 0.350
			})

			Window.Shadow:Render(true);
		else

			Phobia.PlayAnimate(WindowFrame , SlowyTween , {
				BackgroundTransparency = 1,
				Size = Window.Size + UDim2.fromOffset(-15,-15)
			})

			Phobia.PlayAnimate(LogoImage , SlowyTween , {
				ImageTransparency = 1
			})

			Phobia.PlayAnimate(WindowName , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(WindowContent , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(LineFrame , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(AccountProfile , SlowyTween , {
				ImageTransparency = 1
			})

			Phobia.PlayAnimate(AccountName , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(ExpireLabel , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(LineFrame_2 , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UserSettingButton , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(RightMenuFrame , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(LineFrame_3 , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(ConfigFrame , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke_2 , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(ConfigIcon , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(LineFrame_4 , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(ConfigName , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(ConfigBthIcon , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(SearchIcon , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(SearchBox , SlowyTween , {
				TextTransparency = 1
			})

			Window.Shadow:Render(false);
		end;
	end);

	Window.Shadow = Phobia:CreateShadow(WindowFrame);
	Window.Shadow:Render(false);

	task.delay(0.25,function()
		WindowFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
		Window:SetRender(true);
		Phobia:AddSignal(Window.Signal:Connect(LPH_NO_VIRTUALIZE(function(...)
			Window:SetRender(...);
		end)))
	end)

	if Phobia.EnabledBlur then
		Phobia:CreateBlurModule(WindowFrame,Window.Signal);
	end;

	do
		local Frame = Instance.new("Frame")

		Frame.Parent = WindowFrame
		Frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Frame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Frame.BorderSizePixel = 0
		Frame.Size = UDim2.new(1, 0, 0, 50)
		Frame.ZIndex = 7
		Frame.BackgroundTransparency = 1;

		Phobia.Drag(Frame , WindowFrame , 0.15)
	end

	UICorner.Parent = WindowFrame

	LeftMenuFrame.Name = Phobia.RandomString();
	LeftMenuFrame.Parent = WindowFrame
	LeftMenuFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	LeftMenuFrame.BackgroundTransparency = 1.000
	LeftMenuFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LeftMenuFrame.BorderSizePixel = 0
	LeftMenuFrame.Size = UDim2.new(0, 175, 1, 0)

	HeadFrame.Name = Phobia.RandomString();
	HeadFrame.Parent = LeftMenuFrame
	HeadFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	HeadFrame.BackgroundTransparency = 1.000
	HeadFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	HeadFrame.BorderSizePixel = 0
	HeadFrame.Size = UDim2.new(1, 0, 0, 50)
	HeadFrame.ZIndex = 7

	LogoImage.Name = Phobia.RandomString();
	LogoImage.Parent = HeadFrame
	LogoImage.AnchorPoint = Vector2.new(0, 0.5)
	LogoImage.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	LogoImage.BackgroundTransparency = 1.000
	LogoImage.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LogoImage.BorderSizePixel = 0
	LogoImage.Position = UDim2.new(0, 10, 0.5, 0)
	LogoImage.Size = UDim2.new(0, 35, 0, 35)
	LogoImage.AnchorPoint = Vector2.new(0.5, 0.5); LogoImage.Position = UDim2.new(0, 32, 0.5, 0); LogoImage.Size = UDim2.new(0, 56, 0, 56)
	LogoImage.ZIndex = 7
	LogoImage.ScaleType = Enum.ScaleType.Fit;
	LogoImage.ImageColor3 = Phobia.IconColor
	if type(Window.Logo) == 'string' and string.find(Window.Logo , 'rbxasset' , 1 , true) then
		LogoImage.Image = Window.Logo;
	else
		LogoImage.Image = '';
		Phobia:ApplyIcon(LogoImage , (type(Window.Logo) == 'string' and Window.Logo) or 'phobia' , { Size = 36 , Color = Phobia.AccentColor , Transparency = 0 });
	end;

	UICorner_2.CornerRadius = UDim.new(0, 7)
	UICorner_2.Parent = LogoImage

	WindowName.Name = Phobia.RandomString();
	WindowName.Parent = HeadFrame
	WindowName.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	WindowName.BackgroundTransparency = 1.000
	WindowName.BorderColor3 = Color3.fromRGB(0, 0, 0)
	WindowName.BorderSizePixel = 0
	WindowName.Position = UDim2.new(0, 70, 0, 10)
	WindowName.Size = UDim2.new(0, 260, 0, 30)
	WindowName.ZIndex = 7
	WindowName.Font = Enum.Font.Gotham
	WindowName.Text = string.upper(tostring(Window.Name or "PHOBIA"))  Window.NameLabel = WindowName;
    local HeadSep = Instance.new("Frame")
    HeadSep.Name = Phobia.RandomString();
    HeadSep.Parent = HeadFrame
    HeadSep.BackgroundColor3 = Color3.fromRGB(140, 142, 150)
    HeadSep.BackgroundTransparency = 0.600
    HeadSep.BorderColor3 = Color3.fromRGB(0, 0, 0)
    HeadSep.BorderSizePixel = 0
    HeadSep.Position = UDim2.new(0, 62, 0, 19)
    HeadSep.Size = UDim2.new(0, 1, 0, 14)
    HeadSep.ZIndex = 7
	WindowName.TextColor3 = Phobia.AccentColor
	WindowName.TextSize = 24.000
	WindowName.TextXAlignment = Enum.TextXAlignment.Left
	local NameGrad = Instance.new("UIGradient")
	NameGrad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 180, 255), Color3.fromRGB(255, 255, 255))
	NameGrad.Parent = WindowName
	task.spawn(function()
		while WindowName and WindowName.Parent do
			NameGrad.Offset = Vector2.new(math.sin(tick() * 2) * 0.7, 0)
			task.wait(0.03)
		end
	end)

	WindowContent.Name = Phobia.RandomString();
	WindowContent.Parent = HeadFrame
	WindowContent.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	WindowContent.BackgroundTransparency = 1.000
	WindowContent.BorderColor3 = Color3.fromRGB(0, 0, 0)
	WindowContent.BorderSizePixel = 0
	WindowContent.Position = UDim2.new(0, 55, 0, 34)
	WindowContent.Size = UDim2.new(0, 220, 0, 13)
	WindowContent.ZIndex = 7
	WindowContent.Font = Enum.Font.GothamMedium
	WindowContent.Text = Window.Content
	WindowContent.TextColor3 = Color3.fromRGB(255, 255, 255)
	WindowContent.TextSize = 9.000
	WindowContent.TextTransparency = 0.650
	WindowContent.TextXAlignment = Enum.TextXAlignment.Left

	LineFrame.Name = Phobia.RandomString();
	LineFrame.Parent = HeadFrame
	LineFrame.AnchorPoint = Vector2.new(0.5, 1)
	LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	LineFrame.BackgroundTransparency = 0.650
	LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LineFrame.BorderSizePixel = 0
	LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
	LineFrame.Size = UDim2.new(1, -10, 0, 1)
	LineFrame.ZIndex = 5

	LeftScrollingFrame.Name = Phobia.RandomString();
	LeftScrollingFrame.Parent = LeftMenuFrame
	LeftScrollingFrame.Active = true
	LeftScrollingFrame.AnchorPoint = Vector2.new(0.5, 0)
	LeftScrollingFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	LeftScrollingFrame.BackgroundTransparency = 1.000
	LeftScrollingFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LeftScrollingFrame.BorderSizePixel = 0
	LeftScrollingFrame.Position = UDim2.new(0.5, 0, 0, 60)
	LeftScrollingFrame.Size = UDim2.new(1, -10, 1, -115)
	LeftScrollingFrame.ZIndex = 7
	LeftScrollingFrame.ScrollBarThickness = 0

	UIListLayout.Parent = LeftScrollingFrame
	UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout.Padding = UDim.new(0, 5)

	Phobia:AddSignal(UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
		LeftScrollingFrame.CanvasSize = UDim2.fromOffset(0,UIListLayout.AbsoluteContentSize.Y + 1)
	end)))

	BottomFrame.Name = Phobia.RandomString();
	BottomFrame.Parent = LeftMenuFrame
	BottomFrame.AnchorPoint = Vector2.new(0, 1)
	BottomFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	BottomFrame.BackgroundTransparency = 1.000
	BottomFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	BottomFrame.BorderSizePixel = 0
	BottomFrame.Position = UDim2.new(0, 0, 1, 0)
	BottomFrame.Size = UDim2.new(1, 0, 0, 50)
	BottomFrame.ZIndex = 7

	AccountProfile.Name = Phobia.RandomString();
	AccountProfile.Parent = BottomFrame
	AccountProfile.AnchorPoint = Vector2.new(0, 0.5)
	AccountProfile.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	AccountProfile.BackgroundTransparency = 1.000
	AccountProfile.BorderColor3 = Color3.fromRGB(0, 0, 0)
	AccountProfile.BorderSizePixel = 0
	AccountProfile.Position = UDim2.new(0, 10, 0.5, 0)
	AccountProfile.Size = UDim2.new(0, 35, 0, 35)
	AccountProfile.ZIndex = 7
	if type(Phobia.UserProfile) == 'string' then
		AccountProfile.Image = Phobia.UserProfile;
	else
		AccountProfile.Image = "";
		Phobia:ApplyIcon(AccountProfile , 'user' , { Size = 22 , Color = Color3.fromRGB(190, 190, 200) , Transparency = 0.25 });
	end;

	UICorner_3.CornerRadius = UDim.new(1, 0)
	UICorner_3.Parent = AccountProfile

	AccountName.Name = Phobia.RandomString();
	AccountName.Parent = BottomFrame
	AccountName.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	AccountName.BackgroundTransparency = 1.000
	AccountName.BorderColor3 = Color3.fromRGB(0, 0, 0)
	AccountName.BorderSizePixel = 0
	AccountName.Position = UDim2.new(0, 55, 0, 5)
	AccountName.Size = UDim2.new(0, 100, 0, 25)
	AccountName.ZIndex = 7
	AccountName.Font = Enum.Font.GothamMedium
	AccountName.Text = ""
	AccountName.TextColor3 = Color3.fromRGB(255, 255, 255)
	AccountName.TextSize = 14.000
	AccountName.TextXAlignment = Enum.TextXAlignment.Left
	AccountName.TextTruncate = Enum.TextTruncate.SplitWord;

	ExpireLabel.Name = Phobia.RandomString();
	ExpireLabel.Parent = BottomFrame
	ExpireLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ExpireLabel.BackgroundTransparency = 1.000
	ExpireLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ExpireLabel.BorderSizePixel = 0
	ExpireLabel.Position = UDim2.new(0, 55, 0, 25)
	ExpireLabel.Size = UDim2.new(0, 200, 0, 15)
	ExpireLabel.ZIndex = 7
	ExpireLabel.Font = Enum.Font.GothamMedium
	ExpireLabel.Text = "never"
	ExpireLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	ExpireLabel.TextSize = 10.000
	ExpireLabel.TextTransparency = 0.650
	ExpireLabel.TextXAlignment = Enum.TextXAlignment.Left

	LineFrame_2.Name = Phobia.RandomString();
	LineFrame_2.Parent = BottomFrame
	LineFrame_2.AnchorPoint = Vector2.new(0.5, 0)
	LineFrame_2.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	LineFrame_2.BackgroundTransparency = 0.650
	LineFrame_2.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LineFrame_2.BorderSizePixel = 0
	LineFrame_2.Position = UDim2.new(0.5, 0, 0, 0)
	LineFrame_2.Size = UDim2.new(1, -10, 0, 1)
	LineFrame_2.ZIndex = 5

	UserSettingButton.Name = Phobia.RandomString();
	UserSettingButton.Parent = BottomFrame
	UserSettingButton.AnchorPoint = Vector2.new(1, 0.5)
	UserSettingButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	UserSettingButton.BackgroundTransparency = 1.000
	UserSettingButton.BorderColor3 = Color3.fromRGB(0, 0, 0)
	UserSettingButton.BorderSizePixel = 0
	UserSettingButton.Position = UDim2.new(1, -7, 0.5, 0)
	UserSettingButton.Size = UDim2.new(0, 25, 0, 25)
	UserSettingButton.ZIndex = 7
	UserSettingButton.Text = ""
	UserSettingButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	UserSettingButton.TextTransparency = 0.5
	Phobia:ApplyIcon(UserSettingButton , 'chevron-large-right' , { Size = 14 });

	Phobia:AddSignal(BottomFrame.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
		Phobia.PlayAnimate(UserSettingButton,SlowyTween , {
			TextTransparency = 0.25
		})		
	end)))

	Phobia:AddSignal(BottomFrame.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
		Phobia.PlayAnimate(UserSettingButton,SlowyTween , {
			TextTransparency = 0.5
		})		
	end)))

	RightMenuFrame.Name = Phobia.RandomString();
	RightMenuFrame.Parent = WindowFrame
	RightMenuFrame.BackgroundColor3 = Phobia.MainColor
	RightMenuFrame.BackgroundTransparency = 0.600
	RightMenuFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	RightMenuFrame.BorderSizePixel = 0
	RightMenuFrame.ClipsDescendants = true
	RightMenuFrame.Position = UDim2.new(0, 176, 0, 0)
	RightMenuFrame.Size = UDim2.new(1, -176, 1, 0)
	RightMenuFrame.ZIndex = 8

	UIStroke.Transparency = 0.650
	UIStroke.Color = Color3.fromRGB(45, 48, 58)
	UIStroke.Parent = RightMenuFrame

	UICorner_4.CornerRadius = UDim.new(0, 13)
	UICorner_4.Parent = RightMenuFrame

	RightHeader.Name = Phobia.RandomString();
	RightHeader.Parent = RightMenuFrame
	RightHeader.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	RightHeader.BackgroundTransparency = 1.000
	RightHeader.BorderColor3 = Color3.fromRGB(0, 0, 0)
	RightHeader.BorderSizePixel = 0
	RightHeader.Size = UDim2.new(1, 0, 0, 50)
	RightHeader.ZIndex = 9

	LineFrame_3.Name = Phobia.RandomString();
	LineFrame_3.Parent = RightHeader
	LineFrame_3.AnchorPoint = Vector2.new(0.5, 1)
	LineFrame_3.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	LineFrame_3.BackgroundTransparency = 0.650
	LineFrame_3.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LineFrame_3.BorderSizePixel = 0
	LineFrame_3.Position = UDim2.new(0.5, 0, 1, 0)
	LineFrame_3.Size = UDim2.new(1, -10, 0, 1)
	LineFrame_3.ZIndex = 9

	ConfigFrame.Name = Phobia.RandomString();
	ConfigFrame.Parent = RightHeader
	ConfigFrame.AnchorPoint = Vector2.new(0, 0.5)
	ConfigFrame.BackgroundColor3 = Color3.fromRGB(13, 17, 22)
	ConfigFrame.BackgroundTransparency = 0.750
	ConfigFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ConfigFrame.BorderSizePixel = 0
	ConfigFrame.Position = UDim2.new(0, 10, 0.5, 0)
	ConfigFrame.Size = UDim2.new(0, 115, 0, 30)
	ConfigFrame.ZIndex = 9

	UIStroke_2.Transparency = 0.650
	UIStroke_2.Color = Color3.fromRGB(45, 48, 58)
	UIStroke_2.Parent = ConfigFrame

	UICorner_5.CornerRadius = UDim.new(0, 4)
	UICorner_5.Parent = ConfigFrame

	ConfigIcon.Name = Phobia.RandomString();
	ConfigIcon.Parent = ConfigFrame
	ConfigIcon.AnchorPoint = Vector2.new(0, 0.5)
	ConfigIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ConfigIcon.BackgroundTransparency = 1.000
	ConfigIcon.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ConfigIcon.BorderSizePixel = 0
	ConfigIcon.Position = UDim2.new(0, 2, 0.5, 0)
	ConfigIcon.Size = UDim2.new(0, 25, 0, 25)
	ConfigIcon.ZIndex = 9
	ConfigIcon.Text = ""
	ConfigIcon.TextColor3 = Color3.fromRGB(223, 223, 223)
	ConfigIcon.TextTransparency = 0.250
	ConfigIcon.TextWrapped = true
	Phobia:ApplyIcon(ConfigIcon , 'floppy-disk' , { Size = 16 });

	LineFrame_4.Name = Phobia.RandomString();
	LineFrame_4.Parent = ConfigFrame
	LineFrame_4.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	LineFrame_4.BackgroundTransparency = 0.650
	LineFrame_4.BorderColor3 = Color3.fromRGB(0, 0, 0)
	LineFrame_4.BorderSizePixel = 0
	LineFrame_4.Position = UDim2.new(0, 30, 0, 0)
	LineFrame_4.Size = UDim2.new(0, 1, 1, 0)

	ConfigName.Name = Phobia.RandomString();
	ConfigName.Parent = ConfigFrame
	ConfigName.AnchorPoint = Vector2.new(0, 0.5)
	ConfigName.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ConfigName.BackgroundTransparency = 1.000
	ConfigName.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ConfigName.BorderSizePixel = 0
	ConfigName.Position = UDim2.new(0, 40, 0.5, 0)
	ConfigName.Size = UDim2.new(1, -7, 0, 15)
	ConfigName.ZIndex = 9
	ConfigName.Font = Enum.Font.Gotham
	ConfigName.Text = "Default"
	ConfigName.TextColor3 = Color3.fromRGB(255, 255, 255)
	ConfigName.TextSize = 12.000
	ConfigName.TextTransparency = 0.350
	ConfigName.TextXAlignment = Enum.TextXAlignment.Left

	ConfigBthIcon.Name = Phobia.RandomString();
	ConfigBthIcon.Parent = ConfigFrame
	ConfigBthIcon.AnchorPoint = Vector2.new(1, 0.5)
	ConfigBthIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ConfigBthIcon.BackgroundTransparency = 1.000
	ConfigBthIcon.BorderColor3 = Color3.fromRGB(0, 0, 0)
	ConfigBthIcon.BorderSizePixel = 0
	ConfigBthIcon.Position = UDim2.new(1, -2, 0.5, 0)
	ConfigBthIcon.Size = UDim2.new(0, 25, 0, 25)
	ConfigBthIcon.ZIndex = 9
	ConfigBthIcon.Text = ""
	ConfigBthIcon.TextColor3 = Color3.fromRGB(223, 223, 223)
	ConfigBthIcon.TextTransparency = 0.250
	ConfigBthIcon.TextWrapped = true
	Phobia:ApplyIcon(ConfigBthIcon , 'chevron-small-down' , { Size = 14 });

	SearchFrame.Name = Phobia.RandomString();
	SearchFrame.Parent = RightHeader
	SearchFrame.AnchorPoint = Vector2.new(1, 0.5)
	SearchFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	SearchFrame.BackgroundTransparency = 1.000
	SearchFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	SearchFrame.BorderSizePixel = 0
	SearchFrame.ClipsDescendants = true
	SearchFrame.Position = UDim2.new(1, -10, 0.5, 0)
	SearchFrame.Size = UDim2.new(0, 30, 0, 30)
	SearchFrame.ZIndex = 12

	SearchIcon.Name = Phobia.RandomString();
	SearchIcon.Parent = SearchFrame
	SearchIcon.AnchorPoint = Vector2.new(0, 0.5)
	SearchIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	SearchIcon.BackgroundTransparency = 1.000
	SearchIcon.BorderColor3 = Color3.fromRGB(0, 0, 0)
	SearchIcon.BorderSizePixel = 0
	SearchIcon.Position = UDim2.new(0, 2, 0.5, 0)
	SearchIcon.Size = UDim2.new(0, 25, 0, 25)
	SearchIcon.ZIndex = 12
	SearchIcon.Text = ""
	SearchIcon.TextColor3 = Color3.fromRGB(223, 223, 223)
	SearchIcon.TextTransparency = 0.45
	SearchIcon.TextWrapped = true
	Phobia:ApplyIcon(SearchIcon , 'magnifying-glass' , { Size = 14 });

	SearchBox.Name = Phobia.RandomString();
	SearchBox.Parent = SearchFrame
	SearchBox.AnchorPoint = Vector2.new(0, 0.5)
	SearchBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	SearchBox.BackgroundTransparency = 1.000
	SearchBox.BorderColor3 = Color3.fromRGB(0, 0, 0)
	SearchBox.BorderSizePixel = 0
	SearchBox.Position = UDim2.new(0, 35, 0.5, 0)
	SearchBox.Size = UDim2.new(1, -35, 0, 25)
	SearchBox.ZIndex = 12
	SearchBox.ClearTextOnFocus = false
	SearchBox.Font = Enum.Font.Gotham
	SearchBox.PlaceholderText = "Search"
	SearchBox.Text = ""
	SearchBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	SearchBox.TextSize = 13.000
	SearchBox.TextTransparency = 1
	SearchBox.TextXAlignment = Enum.TextXAlignment.Left

	TabContainer.Name = Phobia.RandomString();
	TabContainer.Parent = RightMenuFrame
	TabContainer.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	TabContainer.BackgroundTransparency = 1.000
	TabContainer.BorderColor3 = Color3.fromRGB(0, 0, 0)
	TabContainer.BorderSizePixel = 0
	TabContainer.ClipsDescendants = true
	TabContainer.Position = UDim2.new(0, 0, 0, 50)
	TabContainer.Size = UDim2.new(1, 0, 1, -50)
	TabContainer.ZIndex = 5

	do
		Window.Searching = false;
		local Input = Phobia:CreateInput(SearchIcon , LPH_NO_VIRTUALIZE(function()
			Window.Searching = not Window.Searching;

			if Window.Searching then
				Phobia.PlayAnimate(SearchFrame , VSlowTween , {
					Size = UDim2.new(0, 220, 0, 30)
				})

				Phobia.PlayAnimate(SearchIcon , SlowyTween , {
					TextTransparency = 0.25
				})

				Phobia.PlayAnimate(SearchBox , VSlowTween , {
					TextTransparency = 0.350
				})
			else
				Phobia.PlayAnimate(SearchFrame , VSlowTween , {
					Size = UDim2.new(0, 30, 0, 30)
				})

				Phobia.PlayAnimate(SearchIcon , SlowyTween , {
					TextTransparency = 0.45
				})

				Phobia.PlayAnimate(SearchBox , SlowyTween , {
					TextTransparency = 1
				})

				SearchBox.Text = "";
			end;
		end));	

		local wati_for_finish = tick();
		local last_thread;
		local max_time = 0.2;

		Phobia:AddSignal(SearchBox:GetPropertyChangedSignal('Text'):Connect(LPH_NO_VIRTUALIZE(function()
			if not SearchBox.Text:byte() then
				for i,v in next , Phobia.NameRegisitry do
					v.Root.Visible = true;
				end;

				return;	
			end;

			wati_for_finish = tick();

			if last_thread then
				task.cancel(last_thread);
				last_thread = nil;
			end;

			last_thread = task.delay(max_time,function()
				if SearchBox.Text:byte() and (tick() - wati_for_finish) > max_time then
					for i,v in next , Phobia.NameRegisitry do
						if string.find(string.lower(v.Idx) , string.lower(SearchBox.Text), 1, true) then
							v.Root.Visible = true;
						else
							v.Root.Visible = false;
						end;
					end;
				end;
			end);
		end)));

		Phobia:AddSignal(Input.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(SearchIcon , SlowyTween , {
				TextTransparency = 0.25
			})
		end)))

		Phobia:AddSignal(Input.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			if Window.Searching then
				Phobia.PlayAnimate(SearchIcon , SlowyTween , {
					TextTransparency = 0.25
				})
			else
				Phobia.PlayAnimate(SearchIcon , SlowyTween , {
					TextTransparency = 0.45
				})
			end;
		end)));
	end;

	if Window.Enable3DRenderer then pcall(function()
		local Part = Instance.new('Part');

		Part.Name = Phobia.RandomString();
		Part.Anchored = true;
		Part.Transparency = 1;
		Part.CanCollide = false;
		Part.CanTouch = false;
		Part.AudioCanCollide = false;
		Part.CollisionGroup = Phobia.RandomString();
		Part.CFrame = CFrame.new(0,0,0);
		Part.Size = Vector3.zero;

		local SurfaceGui = Instance.new("SurfaceGui")

		SurfaceGui.Parent = Phobia.ScreenGui;
		SurfaceGui.Adornee = Part;
		SurfaceGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		SurfaceGui.AlwaysOnTop = true
		SurfaceGui.LightInfluence = 1.000
		SurfaceGui.ZIndexBehavior = Enum.ZIndexBehavior.Global;
		SurfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize;
		SurfaceGui.PixelsPerStud = 40;

		Window.SurfaceGui = SurfaceGui;
		Phobia.GlobalSurfaceGui = SurfaceGui;

		local PerfectScale = Vector2.new(1920 , 1080 + 300)

		Window.Load3DBlock = LPH_NO_VIRTUALIZE(function()
			if not Window.Signal:GetValue() then
				local _,OnScreen = CurrentCamera:WorldToViewportPoint(Part.Position);

				if OnScreen then
					Phobia.PlayAnimate(Part,VSlowTween , {
						CFrame = CurrentCamera.CFrame * CFrame.new(0,0,-15) * CFrame.Angles(0,math.rad(180),0);
					});
				end;

				return
			end;

			local Dimensions = 50;

			local XY_Incom = Vector2.new(PerfectScale.X + 5, PerfectScale.Y * 1.35) / (Dimensions / 2);
			local PerfectDistance = XY_Incom.Magnitude;
			local SizeIndicator = PerfectDistance / 1.35;

			Part.Parent = Phobia.BlurModuleParent or workspace;

			Phobia.PlayAnimate(Part,VSlowTween , {
				CFrame = (CurrentCamera.CFrame * CFrame.new(0,0,-25)) * CFrame.Angles(0,math.rad(180),0);
			});

			Part.Size = Vector3.new(PerfectScale.X / SizeIndicator,PerfectScale.Y / SizeIndicator,0);
		end);

		function Window:Set3DRender(val)
			Window.__3DRender = val;
			Phobia.Global3DRenderMode = val;

			if val then
				Window.Load3DBlock();
			else


				Part.Parent = nil;
			end;

			renderParentWindow();
		end;
	end);
	end;

	function Window:AddTabLabel(Name: string)
		local TabLabel = Instance.new("TextLabel")

		TabLabel.Name = Phobia.RandomString()
		TabLabel.Parent = LeftScrollingFrame
		TabLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabLabel.BackgroundTransparency = 1.000
		TabLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TabLabel.BorderSizePixel = 0
		TabLabel.Size = UDim2.new(1, -7, 0, 15)
		TabLabel.ZIndex = 8
		TabLabel.Font = Enum.Font.Gotham
		TabLabel.Text = Name
		TabLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		TabLabel.TextSize = 11.000
		TabLabel.TextTransparency = 0.500
		TabLabel.TextXAlignment = Enum.TextXAlignment.Left

		local SetRender = LPH_NO_VIRTUALIZE(function(val)
			if val then
				Phobia.PlayAnimate(TabLabel , SlowyTween,{
					TextTransparency = 0.500
				})
			else
				Phobia.PlayAnimate(TabLabel , SlowyTween,{
					TextTransparency = 1
				})
			end
		end)

		SetRender(Window.Signal:GetValue());

		return Window.Signal:Connect(SetRender);
	end;

	function Window:AddTab(Config)
		Config = Phobia:ProcessParams(Config , {
			Icon = "crosshairs",
			Name = "Tab",
			Type = "Double"
		});

		local Tab = {
			Signal = Phobia:CreateSignal(false);
		};

		local TabButton = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local TabIcon = Instance.new("TextLabel")
		local TabContentLabel = Instance.new("TextLabel")

		Tab.Idx = TabButton;

		TabButton.Name = Phobia.RandomString();
		TabButton.Parent = LeftScrollingFrame
		TabButton.BackgroundColor3 = Color3.fromRGB(41, 45, 49)
		TabButton.BackgroundTransparency = 0.500
		TabButton.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TabButton.BorderSizePixel = 0
		TabButton.Size = UDim2.new(1, -1, 0, 30)
		TabButton.ZIndex = 8

		UICorner.CornerRadius = UDim.new(0, 6)
		UICorner.Parent = TabButton

		TabIcon.Name = Phobia.RandomString();
		TabIcon.Parent = TabButton
		TabIcon.AnchorPoint = Vector2.new(0, 0.5)
		TabIcon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabIcon.BackgroundTransparency = 1.000
		TabIcon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TabIcon.BorderSizePixel = 0
		TabIcon.Position = UDim2.new(0, 2, 0.5, 0)
		TabIcon.Size = UDim2.new(0, 25, 0, 25)
		TabIcon.ZIndex = 9
		TabIcon.Text = "";
		TabIcon.TextColor3 = Phobia.AccentColor
		TabIcon.TextSize = 16.000
		TabIcon.TextWrapped = true
		if type(Config.Icon) == "string" and Phobia.Icons[Config.Icon] then
			-- built-in drawn icon (no asset ids)
			Phobia:ApplyIcon(TabIcon , Config.Icon , { Size = 16 , Color = Phobia.AccentColor });
		else
			TabIcon.Font = Enum.Font.GothamMedium;
			TabIcon.Text = string.upper(string.sub(tostring(Config.Name or "?"), 1, 1));
		end;

		TabContentLabel.Name = Phobia.RandomString();
		TabContentLabel.Parent = TabButton
		TabContentLabel.AnchorPoint = Vector2.new(0, 0.5)
		TabContentLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabContentLabel.BackgroundTransparency = 1.000
		TabContentLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TabContentLabel.BorderSizePixel = 0
		TabContentLabel.Position = UDim2.new(0, 30, 0.5, 0)
		TabContentLabel.Size = UDim2.new(1, -7, 0, 15)
		TabContentLabel.ZIndex = 9
		TabContentLabel.Font = Enum.Font.Gotham
		TabContentLabel.Text = Config.Name
		TabContentLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		TabContentLabel.TextSize = 12.000
		TabContentLabel.TextXAlignment = Enum.TextXAlignment.Left

		local TabFrame = Instance.new("Frame")
		local LeftScroll = Instance.new("ScrollingFrame")
		local UIListLayout = Instance.new("UIListLayout")
		local RightScroll = Instance.new("ScrollingFrame")
		local UIListLayout_2 = Instance.new("UIListLayout")

		TabFrame.Name = Phobia.RandomString();
		TabFrame.Parent = TabContainer
		TabFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		TabFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabFrame.BackgroundTransparency = 1.000
		TabFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TabFrame.BorderSizePixel = 0
		TabFrame.ClipsDescendants = true
		TabFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
		TabFrame.Size = UDim2.new(1, 0, 1, 0)
		TabFrame.Visible = true;

		LeftScroll.Name = Phobia.RandomString();
		LeftScroll.Parent = TabFrame
		LeftScroll.Active = true
		LeftScroll.AnchorPoint = Vector2.new(0.5, 0.5)
		LeftScroll.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		LeftScroll.BackgroundTransparency = 1.000
		LeftScroll.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LeftScroll.BorderSizePixel = 0
		LeftScroll.ClipsDescendants = false
		LeftScroll.Position = UDim2.new(0.25, 0, 0.5, 0)
		LeftScroll.Size = UDim2.new(0.5, 0, 1, -5)
		LeftScroll.ScrollBarThickness = 0

		UIListLayout.Parent = LeftScroll
		UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout.Padding = UDim.new(0, 5)

		Phobia:AddSignal(UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
			LeftScroll.CanvasSize = UDim2.fromOffset(0,UIListLayout.AbsoluteContentSize.Y + 1)
		end)))

		RightScroll.Name = Phobia.RandomString();
		RightScroll.Parent = TabFrame
		RightScroll.Active = true
		RightScroll.AnchorPoint = Vector2.new(0.5, 0.5)
		RightScroll.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		RightScroll.BackgroundTransparency = 1.000
		RightScroll.BorderColor3 = Color3.fromRGB(0, 0, 0)
		RightScroll.BorderSizePixel = 0
		RightScroll.ClipsDescendants = false
		RightScroll.Position = UDim2.new(0.75, 0, 0.5, 0)
		RightScroll.Size = UDim2.new(0.5, 0, 1, -5)
		RightScroll.ScrollBarThickness = 0

		UIListLayout_2.Parent = RightScroll
		UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_2.Padding = UDim.new(0, 5)

		if Config.Type == "Single" then
			UIListLayout_2:Destroy();
			RightScroll:Destroy();
			RightScroll = LeftScroll;
			UIListLayout_2 = UIListLayout;
			LeftScroll.Size = UDim2.new(1, 0, 1, -5);
			LeftScroll.Position = UDim2.new(0.5, 0, 0.5, 0)
		else
			Phobia:AddSignal(UIListLayout_2:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
				RightScroll.CanvasSize = UDim2.fromOffset(0,UIListLayout_2.AbsoluteContentSize.Y + 1)
			end)))
		end;

		Phobia:AddSignal(TabIcon:GetPropertyChangedSignal('TextTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
			if TabIcon.TextTransparency > 0.4 then
				UIListLayout.Parent = nil;
				UIListLayout_2.Parent = nil;
				TabFrame.Visible = false;
				TabFrame.Parent = nil
			else
				UIListLayout.Parent = LeftScroll;
				UIListLayout_2.Parent = RightScroll;
				TabFrame.Visible = true;
				TabFrame.Parent = TabContainer;
			end;
		end)));

		Tab.SetValue = LPH_NO_VIRTUALIZE(function(value)
			Tab.Signal:SetValue(value);

			if value then
				Phobia.PlayAnimate(TabButton , TabTween , {
					BackgroundTransparency = 0.750,
					BackgroundColor3 = Phobia.AccentColor
				})

				Phobia.PlayAnimate(TabIcon , TabTween , {
					TextTransparency = 0,
					TextColor3 = Phobia.AccentColor,
					Position = UDim2.new(0, 8, 0.5, 0)
				})
				Phobia.PlayAnimate(TabContentLabel , TabTween , {
					TextTransparency = 0,
					Position = UDim2.new(0, 36, 0.5, 0)
				})
			else
				Phobia.PlayAnimate(TabButton , TabTween , {
					BackgroundTransparency = 1,
					BackgroundColor3 = Color3.fromRGB(41, 45, 49)
				})

				Phobia.PlayAnimate(TabIcon , TabTween , {
					TextTransparency = 0.5,
					TextColor3 = Color3.fromRGB(252, 252, 252),
					Position = UDim2.new(0, 2, 0.5, 0)
				})
				Phobia.PlayAnimate(TabContentLabel , TabTween , {
					TextTransparency = 0.5,
					Position = UDim2.new(0, 30, 0.5, 0)
				})
			end;
		end);

		table.insert(Window.Tabs,Tab);

		if Window.Tabs[Window.CurrentTab] == Tab then
			Tab.SetValue(true)
		else
			Tab.SetValue(false);
		end;

		local over = Phobia:CreateInput(TabButton,LPH_NO_VIRTUALIZE(function()
			for i,v in next , Window.Tabs do
				if v.Idx == TabButton then
					v.SetValue(true);
					Window.CurrentTab = i;
				else
					v.SetValue(false);
				end;
			end;
		end));

		Phobia:AddSignal(over.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			if Window.Tabs[Window.CurrentTab] == Tab then
				Phobia.PlayAnimate(TabButton , SlowyTween , {
					BackgroundTransparency = 0.750
				})
			else
				Phobia.PlayAnimate(TabButton , SlowyTween , {
					BackgroundTransparency = 0.8
				})
			end;
		end)))

		Phobia:AddSignal(over.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			if Window.Tabs[Window.CurrentTab] == Tab then
				Phobia.PlayAnimate(TabButton , SlowyTween , {
					BackgroundTransparency = 0.750
				})
			else
				Phobia.PlayAnimate(TabButton , SlowyTween , {
					BackgroundTransparency = 1
				})
			end;
		end)))

		Window.Signal:Connect(LPH_NO_VIRTUALIZE(function(value)
			if value then
				if Window.Tabs[Window.CurrentTab] == Tab then
					Tab.SetValue(true)
				else
					Tab.SetValue(false);
				end;
			else
				Tab.SetValue(false);

				Phobia.PlayAnimate(TabButton , SlowyTween , {
					BackgroundTransparency = 1
				})

				Phobia.PlayAnimate(TabIcon , SlowyTween , {
					TextTransparency = 1,
				})

				Phobia.PlayAnimate(TabContentLabel , SlowyTween , {
					TextTransparency = 1
				})
			end;
		end));

		function Tab:AddSection(Config)
			Config = Phobia:ProcessParams(Config , {
				Name = "SECTION",
				Position = 'left'
			});

			local SectionFrame = Instance.new("Frame")
			local SectionLabel = Instance.new("TextLabel")
			local SectionHandler = Instance.new("Frame")
			local UIStroke = Instance.new("UIStroke")
			local UICorner = Instance.new("UICorner")
			local UIListLayout = Instance.new("UIListLayout")

			SectionFrame.Name = Phobia.RandomString();
			SectionFrame.Parent = (string.lower(Config.Position) == 'left' and LeftScroll) or RightScroll
			SectionFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			SectionFrame.BackgroundTransparency = 1.000
			SectionFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
			SectionFrame.BorderSizePixel = 0
			SectionFrame.ClipsDescendants = true
			SectionFrame.Size = UDim2.new(1, -5, 0, 0)
			SectionFrame.ZIndex = 9

			SectionLabel.Name = Phobia.RandomString();
			SectionLabel.Parent = SectionFrame
			SectionLabel.AnchorPoint = Vector2.new(0.5, 0)
			SectionLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			SectionLabel.BackgroundTransparency = 1.000
			SectionLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
			SectionLabel.BorderSizePixel = 0
			SectionLabel.Position = UDim2.new(0.5, 0, 0, 0)
			SectionLabel.Size = UDim2.new(1, -35, 0, 15)
			SectionLabel.ZIndex = 9
			SectionLabel.Font = Enum.Font.Gotham
			SectionLabel.Text = Config.Name
			SectionLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			SectionLabel.TextSize = 11.000
			SectionLabel.TextTransparency = 0.500
			SectionLabel.TextXAlignment = Enum.TextXAlignment.Left

			SectionHandler.Name = Phobia.RandomString();
			SectionHandler.Parent = SectionFrame
			SectionHandler.AnchorPoint = Vector2.new(0.5, 0)
			SectionHandler.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
			SectionHandler.BackgroundTransparency = 0.500
			SectionHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
			SectionHandler.BorderSizePixel = 0
			SectionHandler.ClipsDescendants = true
			SectionHandler.Position = UDim2.new(0.5, 0, 0, 20)
			SectionHandler.Size = UDim2.new(1, -10, 1, -21)
			SectionHandler.ZIndex = 9

			UIStroke.Transparency = 0.650
			UIStroke.Color = Color3.fromRGB(45, 48, 58)
			UIStroke.Parent = SectionHandler

			UICorner.CornerRadius = UDim.new(0, 10)
			UICorner.Parent = SectionHandler

			UIListLayout.Parent = SectionHandler
			UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

			UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()


				if UIListLayout.AbsoluteContentSize.Y <= 1 then
					Phobia.PlayAnimate(SectionFrame , VSlowTween , {
						Size = UDim2.new(1, -5, 0, 0)
					})
				else
					Phobia.PlayAnimate(SectionFrame , VSlowTween , {
						Size = UDim2.new(1, -5, 0, UIListLayout.AbsoluteContentSize.Y + 19.5)
					})
				end;
			end));

			local Section = Phobia:RegisiterItem(SectionHandler , Tab.Signal);

			Section.SetRender = LPH_NO_VIRTUALIZE(function(value)
				if value then
					Phobia.PlayAnimate(SectionLabel,SlowyTween,{
						TextTransparency = 0.500
					})

					Phobia.PlayAnimate(SectionHandler,SlowyTween,{
						BackgroundTransparency = 0.500
					})

					Phobia.PlayAnimate(UIStroke,SlowyTween,{
						Transparency = 0.650
					})
				else
					Phobia.PlayAnimate(SectionLabel,SlowyTween,{
						TextTransparency = 1
					})

					Phobia.PlayAnimate(SectionHandler,SlowyTween,{
						BackgroundTransparency = 1
					})

					Phobia.PlayAnimate(UIStroke,SlowyTween,{
						Transparency = 1
					})
				end;
			end);

			Section.SetRender(Tab.Signal:GetValue());
			Tab.Signal:Connect(Section.SetRender);

			return Section;
		end;

		return Tab;
	end;

	function Window:_InitConfig()
		local ConfigSignal = Phobia:CreateSignal(false);
		local ConfigLib = {
			Signals = {},
		};

		local ConfigMenu = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIListLayout = Instance.new("UIListLayout")
		local UIStroke = Instance.new("UIStroke")
		local InputFrame = Instance.new("Frame")
		local BasedLabel = Instance.new("TextLabel")
		local LineFrame = Instance.new("Frame")
		local BasedHandler = Instance.new("Frame")
		local UIListLayout_2 = Instance.new("UIListLayout")
		local TextInput = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local UIStroke_2 = Instance.new("UIStroke")
		local TextBox = Instance.new("TextBox")
		local LoadConfig = Instance.new("Frame")
		local Icon = Instance.new("TextLabel")
		local UICorner_3 = Instance.new("UICorner")
		local UICorner_4 = Instance.new("UICorner")

		local shadow = Phobia:CreateShadow(ConfigMenu);

		ConfigLib.SetRender = LPH_NO_VIRTUALIZE(function(value)
			if value then
				ConfigMenu.Position = UDim2.fromOffset(ConfigFrame.AbsolutePosition.X + 110 , ConfigFrame.AbsolutePosition.Y + 96)

				Phobia.PlayAnimate(ConfigMenu , SlowyTween , {
					BackgroundTransparency = 0.035,
					Position = UDim2.fromOffset(ConfigFrame.AbsolutePosition.X + 110 , ConfigFrame.AbsolutePosition.Y + 95)
				})	

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 0.650
				})
				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 0.200
				})	

				Phobia.PlayAnimate(UIStroke_2 , SlowyTween , {
					Transparency = 0.65
				})	

				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 0.650
				})	
				Phobia.PlayAnimate(TextInput , SlowyTween , {
					BackgroundTransparency = 0
				})	
				Phobia.PlayAnimate(TextBox , SlowyTween , {
					TextTransparency = 0.350
				})	
				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 0.350
				})	

				Phobia.PlayAnimate(ConfigBthIcon , SlowyTween , {
					Rotation = 180
				})	

				shadow:Render(true)
			else
				Phobia.PlayAnimate(ConfigBthIcon , SlowyTween , {
					Rotation = 0
				})

				Phobia.PlayAnimate(ConfigMenu , SlowyTween , {
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(ConfigFrame.AbsolutePosition.X + 110 , ConfigFrame.AbsolutePosition.Y + 96)
				})	

				Phobia.PlayAnimate(UIStroke_2 , SlowyTween , {
					Transparency = 1
				})	

				Phobia.PlayAnimate(UIStroke , SlowyTween , {
					Transparency = 1
				})
				Phobia.PlayAnimate(BasedLabel , SlowyTween , {
					TextTransparency = 1
				})	
				Phobia.PlayAnimate(LineFrame , SlowyTween , {
					BackgroundTransparency = 1
				})	
				Phobia.PlayAnimate(TextInput , SlowyTween , {
					BackgroundTransparency = 1
				})	
				Phobia.PlayAnimate(TextBox , SlowyTween , {
					TextTransparency = 1
				})	
				Phobia.PlayAnimate(Icon , SlowyTween , {
					TextTransparency = 1
				})	

				shadow:Render(false)
			end;
		end);

		Phobia:AddSignal(ConfigMenu:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
			if ConfigMenu.BackgroundTransparency > 0.9 then
				ConfigMenu.Visible = false;
				UIListLayout.Parent = nil;
				ConfigMenu.Parent = nil;
			else

				ConfigMenu.Visible = true;
				UIListLayout.Parent = ConfigMenu

				if Phobia.Global3DRenderMode then
					ConfigMenu.Parent = Phobia.GlobalSurfaceGui;
				else
					ConfigMenu.Parent = Phobia.ScreenGui;
				end;
			end
		end)))

		ConfigMenu.Name = Phobia.RandomString();
		ConfigMenu.Parent = Phobia.ScreenGui;
		ConfigMenu.AnchorPoint = Vector2.new(0.5, 0)
		ConfigMenu.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
		ConfigMenu.BackgroundTransparency = 0.035
		ConfigMenu.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ConfigMenu.BorderSizePixel = 0
		ConfigMenu.ClipsDescendants = true
		ConfigMenu.Position = UDim2.new(255,255,255,255)
		ConfigMenu.Size = UDim2.new(0, 220,0, 110)
		ConfigMenu.ZIndex = 151

		UICorner.CornerRadius = UDim.new(0, 10)
		UICorner.Parent = ConfigMenu

		UIListLayout.Parent = ConfigMenu
		UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout.Padding = UDim.new(0, 4)

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = ConfigMenu

		InputFrame.Name = Phobia.RandomString();
		InputFrame.Parent = ConfigMenu
		InputFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 33)
		InputFrame.BackgroundTransparency = 1.000
		InputFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		InputFrame.BorderSizePixel = 0
		InputFrame.Size = UDim2.new(1, 0, 0, 30)
		InputFrame.ZIndex = 154

		BasedLabel.Name = Phobia.RandomString();
		BasedLabel.Parent = InputFrame
		BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.BackgroundTransparency = 1.000
		BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedLabel.BorderSizePixel = 0
		BasedLabel.Position = UDim2.new(0, 11, 0, 6)
		BasedLabel.Size = UDim2.new(0,1, 0, 15)
		BasedLabel.ZIndex = 154
		BasedLabel.Font = Enum.Font.Gotham
		BasedLabel.Text = "Config"
		BasedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		BasedLabel.TextSize = 13.000
		BasedLabel.TextTransparency = 0.200
		BasedLabel.TextXAlignment = Enum.TextXAlignment.Left

		LineFrame.Name = Phobia.RandomString();
		LineFrame.Parent = InputFrame
		LineFrame.AnchorPoint = Vector2.new(0.5, 1)
		LineFrame.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		LineFrame.BackgroundTransparency = 0.650
		LineFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LineFrame.BorderSizePixel = 0
		LineFrame.Position = UDim2.new(0.5, 0, 1, 0)
		LineFrame.Size = UDim2.new(1, -20, 0, 1)
		LineFrame.ZIndex = 154

		BasedHandler.Name = Phobia.RandomString();
		BasedHandler.Parent = InputFrame
		BasedHandler.AnchorPoint = Vector2.new(1, 0)
		BasedHandler.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		BasedHandler.BackgroundTransparency = 1.000
		BasedHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
		BasedHandler.BorderSizePixel = 0
		BasedHandler.Position = UDim2.new(1, -11, 0, 2)
		BasedHandler.Size = UDim2.new(1, -20, 0, 25)
		BasedHandler.ZIndex = 154

		UIListLayout_2.Parent = BasedHandler
		UIListLayout_2.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout_2.HorizontalAlignment = Enum.HorizontalAlignment.Right
		UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_2.VerticalAlignment = Enum.VerticalAlignment.Center
		UIListLayout_2.Padding = UDim.new(0, 5)

		Phobia:AddSignal(UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
			if #ConfigLib.Signals <= 0 then
				Phobia.PlayAnimate(ConfigMenu , SlowyTween , {
					Size = UDim2.new(0, 220,0, UIListLayout.AbsoluteContentSize.Y + 0);
				})
			else
				Phobia.PlayAnimate(ConfigMenu , SlowyTween , {
					Size = UDim2.new(0, 220,0, UIListLayout.AbsoluteContentSize.Y + 5);
				})
			end;

		end)));

		TextInput.Name = Phobia.RandomString();
		TextInput.Parent = BasedHandler
		TextInput.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
		TextInput.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TextInput.BorderSizePixel = 0
		TextInput.ClipsDescendants = true
		TextInput.Size = UDim2.new(0, 100, 0, 18)
		TextInput.ZIndex = 154

		UICorner_2.CornerRadius = UDim.new(0, 4)
		UICorner_2.Parent = TextInput

		UIStroke_2.Transparency = 0.650
		UIStroke_2.Color = Color3.fromRGB(45, 48, 58)
		UIStroke_2.Parent = TextInput

		TextBox.Parent = TextInput
		TextBox.AnchorPoint = Vector2.new(0, 0.5)
		TextBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TextBox.BackgroundTransparency = 1.000
		TextBox.BorderColor3 = Color3.fromRGB(0, 0, 0)
		TextBox.BorderSizePixel = 0
		TextBox.Position = UDim2.new(0, 5, 0.5, 0)
		TextBox.Size = UDim2.new(1, -5, 0, 17)
		TextBox.ZIndex = 154
		TextBox.ClearTextOnFocus = false
		TextBox.Font = Enum.Font.Gotham
		TextBox.PlaceholderText = "Config Name ..."
		TextBox.Text = ""
		TextBox.TextColor3 = Color3.fromRGB(255, 255, 255)
		TextBox.TextSize = 11.000
		TextBox.TextTransparency = 0.350
		TextBox.TextXAlignment = Enum.TextXAlignment.Left

		LoadConfig.Name = Phobia.RandomString();
		LoadConfig.Parent = BasedHandler
		LoadConfig.BackgroundColor3 = Color3.fromRGB(39, 40, 49)
		LoadConfig.BackgroundTransparency = 1.000
		LoadConfig.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LoadConfig.BorderSizePixel = 0
		LoadConfig.ClipsDescendants = true
		LoadConfig.Size = UDim2.new(0, 20, 0, 18)
		LoadConfig.ZIndex = 153

		Icon.Name = Phobia.RandomString();
		Icon.Parent = LoadConfig
		Icon.AnchorPoint = Vector2.new(0.5, 0.5)
		Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Icon.BackgroundTransparency = 1.000
		Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Icon.BorderSizePixel = 0
		Icon.Position = UDim2.new(0.5, 0, 0.5, 0)
		Icon.Size = UDim2.new(1, 0, 1, 0)
		Icon.ZIndex = 153
		Icon.Text = ""
		Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
		Icon.TextTransparency = 0.350
		Icon.TextWrapped = true
		Phobia:ApplyIcon(Icon , 'plus-large' , { Size = 16 });

		UICorner_3.CornerRadius = UDim.new(0, 4)
		UICorner_3.Parent = LoadConfig

		UICorner_4.CornerRadius = UDim.new(0, 10)
		UICorner_4.Parent = InputFrame

		local OpenButton = Instance.new("TextButton")
		local UICorner = Instance.new("UICorner")

		OpenButton.Name = Phobia.RandomString();
		OpenButton.Parent = ConfigFrame
		OpenButton.AnchorPoint = Vector2.new(0, 0.5)
		OpenButton.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
		OpenButton.BackgroundTransparency = 1.000
		OpenButton.BorderColor3 = Color3.fromRGB(0, 0, 0)
		OpenButton.BorderSizePixel = 0
		OpenButton.Position = UDim2.new(0, 31, 0.5, 0)
		OpenButton.Size = UDim2.new(1, -31, 1, 0)
		OpenButton.ZIndex = 10
		OpenButton.Font = Enum.Font.SourceSans
		OpenButton.Text = ""
		OpenButton.TextColor3 = Color3.fromRGB(0, 0, 0)
		OpenButton.TextSize = 14.000

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = OpenButton

		ConfigLib.SetRender(false);
		ConfigSignal:Connect(ConfigLib.SetRender);
		ConfigLib.UnsafeThread = nil;
		ConfigLib.SelectedConfig = "Default";

		local UpdateSize = LPH_NO_VIRTUALIZE(function()
			local size = TextService:GetTextSize(ConfigName.Text , ConfigName.TextSize,ConfigName.Font,Vector2.new(math.huge,math.huge));

			Phobia.PlayAnimate(ConfigFrame,SlowyTween , {
				Size = UDim2.fromOffset(size.X + 75, 30)
			});
		end);

		UpdateSize();

		function ConfigLib:GetData(performance)
			local ikc = {};
			
			local cd = 0;
			for Flag,v in next , Phobia.Flags do
				if v and v.GetValue then
					local data = v:GetValue();

					if typeof(data) == 'Color3' then
						table.insert(ikc,{
							Idx = Flag,
							Value = data:ToHex(),
						});
					else
						table.insert(ikc,{
							Idx = Flag,
							Value = data
						});
					end;
				end;
				
				if performance then
					if cd % 35 == 1 then
						task.wait()
					end
				end;
				
				cd += 1;
			end;

			return Phobia.Base64Encode(Encryption.new(HttpService:JSONEncode(ikc)));
		end;

		function ConfigLib:LoadData(data)
			local coded = HttpService:JSONDecode(Encryption.reverse(Phobia.Base64Decode(data)));

			for i,v in next , coded do
				if v.Idx then
					if Phobia.Flags[v.Idx] then
						task.spawn(function()
							Phobia.Flags[v.Idx]:SetValue(v.Value)
						end)
					end;
				end;
			end;
		end;

		function ConfigLib:RefreshConfig()
			if not isfolder(Window.ConfigFolder) then
				makefolder(Window.ConfigFolder);
			end;
			
			if not isfile(Window.ConfigFolder..'/Default') then
				writefile(Window.ConfigFolder..'/Default',ConfigLib:GetData());
			end;
			
			for i,v in next,ConfigMenu:GetChildren() do
				if v:GetAttribute('ConfigItem') then
					v:Destroy();
				end;
			end;

			for i,v in next , ConfigLib.Signals do
				v:Disconnect();
			end

			table.clear(ConfigLib.Signals);

			local ConfigList = {};
			for i,v in next , listfiles(Window.ConfigFolder) do

				local name = string.sub(v , #Window.ConfigFolder + 2);

				table.insert(ConfigList , name)
			end;

			for i,ConfigNameStr in next , ConfigList do
				local ConfigItemFrame = Instance.new("Frame")
				local BasedHandler = Instance.new("Frame")
				local UIListLayout = Instance.new("UIListLayout")
				local DeleteConfig = Instance.new("Frame")
				local Icon = Instance.new("TextLabel")
				local UICorner = Instance.new("UICorner")
				local LoadConfig = Instance.new("Frame")
				local Icon_2 = Instance.new("TextLabel")
				local UICorner_2 = Instance.new("UICorner")
				local UICorner_3 = Instance.new("UICorner")
				local BasedLabel = Instance.new("TextLabel")
				local UIStroke = Instance.new("UIStroke")

				ConfigItemFrame.Name = Phobia.RandomString();
				ConfigItemFrame.Parent = ConfigMenu
				ConfigItemFrame.BackgroundColor3 = Color3.fromRGB(21, 20, 27)
				ConfigItemFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
				ConfigItemFrame.BorderSizePixel = 0
				ConfigItemFrame.Size = UDim2.new(1, -10, 0, 30)
				ConfigItemFrame.ZIndex = 153
				ConfigItemFrame:SetAttribute('ConfigItem',true);

				BasedHandler.Name = Phobia.RandomString();
				BasedHandler.Parent = ConfigItemFrame
				BasedHandler.AnchorPoint = Vector2.new(1, 0)
				BasedHandler.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				BasedHandler.BackgroundTransparency = 1.000
				BasedHandler.BorderColor3 = Color3.fromRGB(0, 0, 0)
				BasedHandler.BorderSizePixel = 0
				BasedHandler.Position = UDim2.new(1, -11, 0, 2)
				BasedHandler.Size = UDim2.new(1, -20, 0, 25)
				BasedHandler.ZIndex = 153

				UIListLayout.Parent = BasedHandler
				UIListLayout.FillDirection = Enum.FillDirection.Horizontal
				UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
				UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
				UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				UIListLayout.Padding = UDim.new(0, 5)

				DeleteConfig.Name = Phobia.RandomString();
				DeleteConfig.Parent = BasedHandler
				DeleteConfig.BackgroundColor3 = Color3.fromRGB(39, 40, 49)
				DeleteConfig.BackgroundTransparency = 1.000
				DeleteConfig.BorderColor3 = Color3.fromRGB(0, 0, 0)
				DeleteConfig.BorderSizePixel = 0
				DeleteConfig.ClipsDescendants = true
				DeleteConfig.Size = UDim2.new(0, 20, 0, 18)
				DeleteConfig.ZIndex = 153

				Icon.Name = Phobia.RandomString();
				Icon.Parent = DeleteConfig
				Icon.AnchorPoint = Vector2.new(0.5, 0.5)
				Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				Icon.BackgroundTransparency = 1.000
				Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
				Icon.BorderSizePixel = 0
				Icon.Position = UDim2.new(0.5, 0, 0.5, 0)
				Icon.Size = UDim2.new(1, 0, 1, 0)
				Icon.ZIndex = 153
				Icon.Text = ""
				Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
				Icon.TextTransparency = 0.400
				Icon.TextWrapped = true
				Phobia:ApplyIcon(Icon , 'trash-can' , { Size = 15 });

				UICorner.CornerRadius = UDim.new(0, 4)
				UICorner.Parent = DeleteConfig

				LoadConfig.Name = Phobia.RandomString();
				LoadConfig.Parent = BasedHandler
				LoadConfig.BackgroundColor3 = Color3.fromRGB(39, 40, 49)
				LoadConfig.BackgroundTransparency = 1.000
				LoadConfig.BorderColor3 = Color3.fromRGB(0, 0, 0)
				LoadConfig.BorderSizePixel = 0
				LoadConfig.ClipsDescendants = true
				LoadConfig.Size = UDim2.new(0, 20, 0, 18)
				LoadConfig.ZIndex = 153

				Icon_2.Name = Phobia.RandomString();
				Icon_2.Parent = LoadConfig
				Icon_2.AnchorPoint = Vector2.new(0.5, 0.5)
				Icon_2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				Icon_2.BackgroundTransparency = 1.000
				Icon_2.BorderColor3 = Color3.fromRGB(0, 0, 0)
				Icon_2.BorderSizePixel = 0
				Icon_2.Position = UDim2.new(0.5, 0, 0.5, 0)
				Icon_2.Size = UDim2.new(1, 0, 1, 0)
				Icon_2.ZIndex = 153
				Icon_2.Text = ""
				Icon_2.TextColor3 = Color3.fromRGB(223, 223, 223)
				Icon_2.TextTransparency = 0.400
				Icon_2.TextWrapped = true
				Phobia:ApplyIcon(Icon_2 , 'exit-rect' , { Size = 15 });

				UICorner_2.CornerRadius = UDim.new(0, 4)
				UICorner_2.Parent = LoadConfig

				UICorner_3.CornerRadius = UDim.new(0, 5)
				UICorner_3.Parent = ConfigItemFrame

				BasedLabel.Name = Phobia.RandomString();
				BasedLabel.Parent = ConfigItemFrame
				BasedLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				BasedLabel.BackgroundTransparency = 1.000
				BasedLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
				BasedLabel.BorderSizePixel = 0
				BasedLabel.Position = UDim2.new(0, 11, 0, 7)
				BasedLabel.Size = UDim2.new(0, 1, 0, 15)
				BasedLabel.ZIndex = 153
				BasedLabel.Font = Enum.Font.Gotham
				BasedLabel.Text = ConfigNameStr
				BasedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
				BasedLabel.TextSize = 13.000
				BasedLabel.TextTransparency = 0.200
				BasedLabel.TextXAlignment = Enum.TextXAlignment.Left

				UIStroke.Transparency = 0.500
				UIStroke.Color = Color3.fromRGB(45, 48, 58)
				UIStroke.Parent = ConfigItemFrame

				local Render = LPH_NO_VIRTUALIZE(function(rst)
					if rst then
						Phobia.PlayAnimate(ConfigItemFrame,SlowyTween,{
							BackgroundTransparency = 0
						})

						Phobia.PlayAnimate(Icon,SlowyTween,{
							TextTransparency = 0.400
						})

						Phobia.PlayAnimate(Icon_2,SlowyTween,{
							TextTransparency = 0.400
						})

						Phobia.PlayAnimate(BasedLabel,SlowyTween,{
							TextTransparency = 0.200
						})

						Phobia.PlayAnimate(UIStroke,SlowyTween,{
							Transparency = 0.500
						})
					else
						Phobia.PlayAnimate(ConfigItemFrame,SlowyTween,{
							BackgroundTransparency = 1
						})

						Phobia.PlayAnimate(Icon,SlowyTween,{
							TextTransparency = 1
						})

						Phobia.PlayAnimate(Icon_2,SlowyTween,{
							TextTransparency = 1
						})

						Phobia.PlayAnimate(BasedLabel,SlowyTween,{
							TextTransparency = 1
						})

						Phobia.PlayAnimate(UIStroke,SlowyTween,{
							Transparency = 1
						})
					end;
				end)

				Render(ConfigSignal:GetValue());
				table.insert(ConfigLib.Signals , ConfigSignal:Connect(Render));

				table.insert(ConfigLib.Signals , ConfigItemFrame.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(UIStroke,SlowyTween,{
						Transparency = 0.25
					})
				end)));

				table.insert(ConfigLib.Signals , ConfigItemFrame.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(UIStroke,SlowyTween,{
						Transparency = 0.500
					})
				end)));

				local deleter,signal = Phobia:CreateInput(DeleteConfig,function()
					if ConfigNameStr == "Default" then
						Logging.new("trash-can","You can't delete default config!",3.5)
						return;
					end;
					
					delfile(Window.ConfigFolder..'/'..ConfigNameStr);

					UpdateSize();

					ConfigLib:RefreshConfig();

					Logging.new("trash-can",'Deleted '..tostring(ConfigNameStr),3.5)
				end);


				local _,load_signal = Phobia:CreateInput(LoadConfig,function()
					local path = Window.ConfigFolder..'/'..ConfigNameStr;

					if isfile(path) then
						local data = readfile(path);

						pcall(function() ConfigLib:LoadData(data) end);

						ConfigLib.SelectedConfig = ConfigNameStr;
						ConfigName.Text = ConfigNameStr;

						UpdateSize();

						ConfigLib:RefreshConfig();

						Logging.new("folder",'Loaded '..tostring(ConfigNameStr),3.5)
					end
				end);

				table.insert(ConfigLib.Signals , signal);
				table.insert(ConfigLib.Signals , load_signal);

				table.insert(ConfigLib.Signals , deleter.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(Icon,SlowyTween,{
						TextTransparency = 0.2,
						TextColor3 = Color3.fromRGB(223, 125, 125)
					})
				end)))

				table.insert(ConfigLib.Signals , deleter.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(Icon,SlowyTween,{
						TextTransparency = 0.400,
						TextColor3 = Color3.fromRGB(223, 223, 223)
					})
				end)))

				table.insert(ConfigLib.Signals , LoadConfig.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(Icon_2,SlowyTween,{
						TextTransparency = 0.2,
						TextColor3 = Phobia.AccentColor
					})
				end)))

				table.insert(ConfigLib.Signals , LoadConfig.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
					Phobia.PlayAnimate(Icon_2,SlowyTween,{
						TextTransparency = 0.400,
						TextColor3 = Color3.fromRGB(223, 223, 223)
					})
				end)))
			end;

			table.clear(ConfigList);
		end;
		
		task.delay(1,function()
			if ConfigLib.SelectedConfig == "Default" then
				local path = Window.ConfigFolder..'/Default';
				local ConfigNameStr = "Default";
				
				if false then
					local data = readfile(path);

					pcall(function() ConfigLib:LoadData(data) end);

					ConfigLib.SelectedConfig = ConfigNameStr;
					ConfigName.Text = ConfigNameStr;

					UpdateSize();

					ConfigLib:RefreshConfig();

					Logging.new("folder","Loaded Default Config",3.5);
					
					task.spawn(function()
						while false do task.wait(5.75);
							if isfile(path) and ConfigLib.SelectedConfig == "Default" then
								writefile(Window.ConfigFolder..'/Default',ConfigLib:GetData(true));
							end;
						end;
					end);
				end;
			end;
		end);

		local hover_write = Phobia:CreateInput(ConfigIcon,function()
			local path = Window.ConfigFolder..'/'..(ConfigLib.SelectedConfig or "Default");

			if isfile(path) then
				writefile(Window.ConfigFolder..'/'..(ConfigLib.SelectedConfig or "Default"),ConfigLib:GetData());

				Logging.new("folder",'Saved '..tostring(ConfigLib.SelectedConfig),3.5)
			end;
		end);

		Phobia:AddSignal(hover_write.MouseEnter:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(ConfigIcon,SlowyTween,{
				TextTransparency = 0.1
			})
		end)));

		Phobia:AddSignal(hover_write.MouseLeave:Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(ConfigIcon,SlowyTween,{
				TextTransparency = 0.25
			})
		end)));


		local mv = Phobia:CreateInput(LoadConfig , function()
			local cfg_name = TextBox.Text;

			if cfg_name and cfg_name:byte() and not cfg_name:find('/',1,true) and not cfg_name:find('\\',1,true) then
				cfg_name = string.sub(cfg_name , 1 , 24);

				writefile(Window.ConfigFolder..'/'..cfg_name,ConfigLib:GetData());
				ConfigLib.SelectedConfig = cfg_name;
				ConfigName.Text = cfg_name;

				Logging.new("folder",'Created '..tostring(cfg_name),3.5)

				TextBox.Text = "";

				UpdateSize();

				ConfigLib:RefreshConfig();
			end;
		end);

		Phobia:AddSignal(mv.MouseEnter:Connect(function()
			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 0.1
			})
		end))

		Phobia:AddSignal(mv.MouseLeave:Connect(function()
			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 0.35
			})
		end))

		ConfigLib:RefreshConfig();

		OpenButton.MouseButton1Click:Connect(LPH_NO_VIRTUALIZE(function()
			if ConfigLib.UnsafeThread then
				ConfigLib.UnsafeThread:Disconnect();
				ConfigLib.UnsafeThread = nil;
			end;

			ConfigSignal:SetValue(true);

			ConfigLib.UnsafeThread = UserInputService.InputBegan:Connect(function(Input)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					if not Phobia:IsMouseOverFrame(ConfigMenu) then
						if ConfigLib.UnsafeThread then
							ConfigLib.UnsafeThread:Disconnect();
							ConfigLib.UnsafeThread = nil;
						end;

						ConfigSignal:SetValue(false);
					end;
				end;
			end)
		end));

		return ConfigLib;
	end;

	Window:_InitConfig();

	local UserSettings = Phobia:CreateOptionWindow(BottomFrame , BottomFrame.ZIndex + 13);
	local reciveSignal;
	Phobia:CreateInput(BottomFrame , LPH_NO_VIRTUALIZE(function()
		if reciveSignal then
			reciveSignal:Disconnect();
			reciveSignal = nil;	
		end;

		UserSettings.Signal:SetValue(true);

		reciveSignal = UserInputService.InputBegan:Connect(function(Input)
			if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
				if not Phobia:IsMouseOverFrame(UserSettings.Root) and not Phobia:IsMouseOverFrame(BottomFrame) and not Phobia.IsMosueOverOtherFrame then
					if reciveSignal then
						reciveSignal:Disconnect();
						reciveSignal = nil;	
					end;

					UserSettings.Signal:SetValue(false);
				end
			end
		end);
	end))

	-- [v19.7] АВТО-ПРИМЕНЕНИЕ КОНФИГА ОТКЛЮЧЕНО (запрос пользователя).
	-- Это жило ВНУТРИ встроенной UI-библиотеки, а не в коде хаба: через 2с
	-- после инжекта она сама читала Phobia/Configs/Default и применяла все
	-- флаги, поэтому тумблеры включались сами. Авто-СОХРАНЕНИЕ ниже оставлено.
	-- (загрузка теперь только вручную кнопкой Load Config)
	task.spawn(function()
		while false do
			pcall(function()
				writefile(Window.ConfigFolder..'/Default', ConfigLib:GetData());
			end);
		end;
	end);
	LocalPlayer.AncestryChanged:Connect(function()
		if false then
			pcall(function()
				writefile(Window.ConfigFolder..'/Default', ConfigLib:GetData());
			end);
		end;
	end);

	Window.UserSettings = UserSettings;

	function Window:SetAccount(Config)
		Config = Phobia:ProcessParams(Config , {
			Profile = Phobia.UserProfile,
			Username = LocalPlayer.DisplayName,
			Expires = "Never",
		});

		AccountName.Text = Config.Username;
		AccountProfile.Image = Config.Profile;
		ExpireLabel.Text = Config.Expires;

		Window.Username = Config.Username or Window.Username;
		Window.Profile = Config.Profile or Window.Profile;
		Window.Expires = Config.Expires or Window.Expires;

		if Window.UserSettings.UserFrame then
			Window.UserSettings.UserFrame:SetUsername(Window.Username);
			Window.UserSettings.UserFrame:SetProfile(Window.Profile);
			Window.UserSettings.UserFrame:SetExpires(Window.Expires);
		else
			Window.UserSettings.UserFrame = UserSettings:AddUserFrame(Window.Username , Window.Profile , Window.Expires);
		end;
	end;

	function Window:SetSize(newsize)
		Window.Size = newsize;

		if Window.Signal:GetValue() then
			Phobia.PlayAnimate(WindowFrame , VSlowTween , {
				Size = Window.Size
			})
		end
	end;

	Window:SetAccount();

	Phobia:AddSignal(UserInputService.InputBegan:Connect(LPH_NO_VIRTUALIZE(function(value,ISTYPING)
		if value.KeyCode == Window.Keybind or value.KeyCode.Name == Window.Keybind then
			if not ISTYPING then
				Window:ToggleInterface()
			end
		end;
	end)));

	function Window:ToggleInterface()
		Window.Signal:SetValue(not Window.Signal:GetValue());

		if Window.__3DRender then
			Window.Load3DBlock();
		end;
	end;

	function Window:Watermark()
		if Phobia.__WatermarkCache then
			return Phobia.__WatermarkCache;
		end;

		local Watermark_lb = {};
		local Watermark = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIListLayout = Instance.new("UIListLayout")
		local Shadow = Phobia:CreateShadow(Watermark);

		Watermark.Name = Phobia.RandomString();
		Watermark.Parent = Phobia.ScreenGui
		Watermark.AnchorPoint = Vector2.new(1, 0)
		Watermark.BackgroundColor3 = Phobia.MainColor
		Watermark.BackgroundTransparency = 0.200
		Watermark.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Watermark.BorderSizePixel = 0
		Watermark.ClipsDescendants = true
		Watermark.Position = UDim2.new(1, -10, 0, 10)
		Watermark.Size = UDim2.new(0, 120, 0, 30)
		Watermark.ZIndex = 16

		UICorner.CornerRadius = UDim.new(0, 25)
		UICorner.Parent = Watermark

		UIListLayout.Parent = Watermark
		UIListLayout.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right

		local empty_space = Instance.new('Frame');

		empty_space.Size = UDim2.fromOffset(15,0);
		empty_space.BackgroundTransparency = 1;
		empty_space.Parent = Watermark;
		empty_space.LayoutOrder = 5;

		Watermark:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
			if Watermark.BackgroundTransparency > 0.9 then
				Watermark.Visible = false;
				Watermark.Parent = nil;
			else
				Watermark.Parent = Phobia.ScreenGui
				Watermark.Visible = true;
			end;
		end));

		UIListLayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(LPH_NO_VIRTUALIZE(function()
			Phobia.PlayAnimate(Watermark , SlowyTween , {
				Size = UDim2.new(0, UIListLayout.AbsoluteContentSize.X + 5, 0, 30)
			})
		end));

		Phobia.__WatermarkCache = Watermark_lb;

		Shadow:Render(true);

		Watermark_lb.Renders = {};
		Watermark_lb.Status = true;

		function Watermark_lb:SetRender(value)
			Watermark_lb.Status = value;

			if value then
				Phobia.PlayAnimate(Watermark,SlowyTween , {
					BackgroundTransparency = 0.200
				})

				Shadow:Render(true);

				for i,v in next , Watermark_lb.Renders do
					pcall(v,true);
				end;
			else
				Phobia.PlayAnimate(Watermark,SlowyTween , {
					BackgroundTransparency = 1
				})

				Shadow:Render(false);

				for i,v in next , Watermark_lb.Renders do
					pcall(v,false);
				end;
			end
		end;

		function Watermark_lb:AddBlock(IconStr , Name)
			local InnerBlock = {};

			local Frame = Instance.new("Frame")
			local Content = Instance.new("TextLabel")
			local Icon = Instance.new("TextLabel")

			Frame.Parent = Watermark
			Frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Frame.BackgroundTransparency = 1.000
			Frame.BorderColor3 = Color3.fromRGB(0, 0, 0)
			Frame.BorderSizePixel = 0
			Frame.Size = UDim2.new(0, 50, 0, 30)

			Content.Name = Phobia.RandomString();
			Content.Parent = Frame
			Content.AnchorPoint = Vector2.new(0, 0.5)
			Content.BackgroundColor3 = Color3.fromRGB(186, 186, 186)
			Content.BackgroundTransparency = 1.000
			Content.BorderColor3 = Color3.fromRGB(0, 0, 0)
			Content.BorderSizePixel = 0
			Content.Position = UDim2.new(0, 35, 0.5, 0)
			Content.Size = UDim2.new(0, 1, 0, 25)
			Content.ZIndex = 17
			Content.Font = Enum.Font.GothamMedium
			Content.Text = Name
			Content.TextColor3 = Color3.fromRGB(186, 186, 186)
			Content.TextSize = 15.000
			Content.TextTransparency = 0.200
			Content.TextXAlignment = Enum.TextXAlignment.Left

			Icon.Name = Phobia.RandomString();
			Icon.Parent = Frame
			Icon.AnchorPoint = Vector2.new(0, 0.5)
			Icon.BackgroundColor3 = Color3.fromRGB(186, 186, 186)
			Icon.BackgroundTransparency = 1.000
			Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
			Icon.BorderSizePixel = 0
			Icon.Position = UDim2.new(0, 10, 0.5, 0)
			Icon.Size = UDim2.new(0, 20, 0, 20)
			Icon.ZIndex = 17
			Icon.Text = "";
			Icon.TextColor3 = Phobia.AccentColor
			Icon.TextTransparency = 0.250
			Icon.TextWrapped = true
			Phobia:ApplyIcon(Icon , IconStr , { Size = 17 });

			InnerBlock.Update = LPH_NO_VIRTUALIZE(function(value)
				local size = TextService:GetTextSize(Content.Text , Content.TextSize,Content.Font,Vector2.new(math.huge,math.huge))

				if InnerBlock.Visible then
					Phobia.PlayAnimate(Frame,VSlowTween,{
						Size = UDim2.new(0, size.X + 35, 0, 30)
					})
				else
					Phobia.PlayAnimate(Frame,VSlowTween,{
						Size = UDim2.new(0, 0, 0, 30)
					})
				end;
			end);

			InnerBlock.Visible = true;

			InnerBlock.Update();

			function InnerBlock:SetVisible(v)
				InnerBlock.Visible = v;

				if Watermark_lb.Status then
					InnerBlock.SetRender(v);
				end;

				InnerBlock.Update();
			end;

			InnerBlock.SetRender = LPH_NO_VIRTUALIZE(function(value)
				if value and InnerBlock.Visible then
					Phobia.PlayAnimate(Content,SlowyTween , {
						TextTransparency = 0.200
					})

					Phobia.PlayAnimate(Icon,SlowyTween , {
						TextTransparency = 0.250
					})
				else

					Phobia.PlayAnimate(Content,SlowyTween , {
						TextTransparency = 1
					})

					Phobia.PlayAnimate(Icon,SlowyTween , {
						TextTransparency = 1
					})
				end;
			end);

			table.insert(Watermark_lb.Renders,InnerBlock.SetRender);

			function InnerBlock:SetText(t)
				Content.Text = t;

				InnerBlock.Update();
			end;

			function InnerBlock:Input(func)
				local c,s = Phobia:CreateInput(Frame,func);

				return s;
			end;

			return InnerBlock;
		end;

		return Watermark_lb;
	end;

	Window:SetRender(false);

	return Window;
end;

function Phobia:CreateNotification()
	if Phobia.__Notification_Cache then
		return Phobia.__Notification_Cache;
	end;

	local Notifier = {};
	local Notification = Instance.new("Frame")
	local UIListLayout = Instance.new("UIListLayout")

	Notification.Name = Phobia.RandomString();
	Notification.Parent = Phobia.ScreenGui;
	Notification.AnchorPoint = Vector2.new(1, 0)
	Notification.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	Notification.BackgroundTransparency = 1.000
	Notification.BorderColor3 = Color3.fromRGB(0, 0, 0)
	Notification.BorderSizePixel = 0
	Notification.Position = UDim2.new(1, -25, 0, 25)
	Notification.Size = UDim2.new(0, 25, 0, 25)

	UIListLayout.Parent = Notification
	UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout.Padding = UDim.new(0, 0)

	Phobia.__Notification_Cache = Notifier;

	function Notifier.new(Config)
		Config = Phobia:ProcessParams(Config , {
			Title = "Notification",
			Content = "Hello World!",
			Logo = Phobia.GlobalLogo or 'phobia',
			Duration = 5,
		});

		if Phobia.__WatermarkCache then
			Phobia.PlayAnimate(Notification,SlowyTween , {
				Position = UDim2.new(1, -25, 0, 55)
			});
		end;

		local ContainerFrame = Instance.new("Frame")
		local NotifyFrame = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local LogoImage = Instance.new("ImageLabel")
		local UICorner_2 = Instance.new("UICorner")
		local NotifyName = Instance.new("TextLabel")
		local NotifyContent = Instance.new("TextLabel");
		local shadow = Phobia:CreateShadow(NotifyFrame , true);

		ContainerFrame.Name = Phobia.RandomString();
		ContainerFrame.Parent = Notification
		ContainerFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ContainerFrame.BackgroundTransparency = 1.000
		ContainerFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		ContainerFrame.BorderSizePixel = 0
		ContainerFrame.Size = UDim2.new(0, 0, 0, 100)

		NotifyFrame.Name = Phobia.RandomString();
		NotifyFrame.Parent = ContainerFrame
		NotifyFrame.AnchorPoint = Vector2.new(1, 0)
		NotifyFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
		NotifyFrame.BackgroundTransparency = 0.075
		NotifyFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		NotifyFrame.BorderSizePixel = 0
		NotifyFrame.ClipsDescendants = true
		NotifyFrame.Position = UDim2.new(0, 750, 0, 0)
		NotifyFrame.Size = UDim2.new(0, 220, 0, 55)
		NotifyFrame.ZIndex = 130

		UICorner.CornerRadius = UDim.new(0, 10)
		UICorner.Parent = NotifyFrame

		UIStroke.Transparency = 0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = NotifyFrame

		LogoImage.Name = Phobia.RandomString();
		LogoImage.Parent = NotifyFrame
		LogoImage.AnchorPoint = Vector2.new(0, 0.5)
		LogoImage.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		LogoImage.BackgroundTransparency = 1.000
		LogoImage.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LogoImage.BorderSizePixel = 0
		LogoImage.Position = UDim2.new(0, 10, 0.5, 0)
		LogoImage.Size = UDim2.new(0, 30, 0, 30)
		LogoImage.ZIndex = 131
		LogoImage.ImageColor3 = Phobia.IconColor;
		if type(Config.Logo) == 'string' and string.find(Config.Logo , 'rbxasset' , 1 , true) then
			LogoImage.Image = Config.Logo;
		else
			LogoImage.Image = '';
			Phobia:ApplyIcon(LogoImage , (type(Config.Logo) == 'string' and Config.Logo) or 'phobia' , { Size = 22 , Color = Phobia.AccentColor , Transparency = 0 });
		end;

		UICorner_2.CornerRadius = UDim.new(0, 7)
		UICorner_2.Parent = LogoImage

		NotifyName.Name = Phobia.RandomString();
		NotifyName.Parent = NotifyFrame
		NotifyName.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		NotifyName.BackgroundTransparency = 1.000
		NotifyName.BorderColor3 = Color3.fromRGB(0, 0, 0)
		NotifyName.BorderSizePixel = 0
		NotifyName.Position = UDim2.new(0, 50, 0, 7)
		NotifyName.Size = UDim2.new(0, 200, 0, 20)
		NotifyName.ZIndex = 132
		NotifyName.Font = Enum.Font.GothamMedium
		NotifyName.Text = Config.Title
		NotifyName.TextColor3 = Color3.fromRGB(255, 255, 255)
		NotifyName.TextSize = 17.000
		NotifyName.TextXAlignment = Enum.TextXAlignment.Left

		NotifyContent.Name = Phobia.RandomString();
		NotifyContent.Parent = NotifyFrame
		NotifyContent.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		NotifyContent.BackgroundTransparency = 1.000
		NotifyContent.BorderColor3 = Color3.fromRGB(0, 0, 0)
		NotifyContent.BorderSizePixel = 0
		NotifyContent.Position = UDim2.new(0, 50, 0, 28)
		NotifyContent.Size = UDim2.new(0, 200, 0, 15)
		NotifyContent.ZIndex = 132
		NotifyContent.Font = Enum.Font.GothamMedium
		NotifyContent.Text = Config.Content
		NotifyContent.TextColor3 = Color3.fromRGB(255, 255, 255)
		NotifyContent.TextSize = 12.000
		NotifyContent.TextTransparency = 0.650
		NotifyContent.TextXAlignment = Enum.TextXAlignment.Left

		local Size1 = TextService:GetTextSize(NotifyName.Text,NotifyName.TextSize,NotifyName.Font,Vector2.new(math.huge,math.huge));
		local Size2 = TextService:GetTextSize(NotifyContent.Text,NotifyContent.TextSize,NotifyContent.Font,Vector2.new(math.huge,math.huge));

		local MainSize = math.max(Size1.X , Size2.X);

		NotifyFrame.Size = UDim2.new(0, MainSize + 65, 0, 55);

		shadow:Render(true)
		Phobia.PlayAnimate(NotifyFrame , VSlowTween , {
			Position = UDim2.new(1, 0, 0, 0)
		})

		ContainerFrame.Size = UDim2.new(0, 0, 0, 65)

		task.delay(Config.Duration or 5 , LPH_NO_VIRTUALIZE(function()

			if Phobia.__WatermarkCache then
				Phobia.PlayAnimate(Notification,SlowyTween , {
					Position = UDim2.new(1, -25, 0, 55)
				});
			end;

			shadow:Render(false)

			Phobia.PlayAnimate(NotifyFrame , SlowyTween , {
				BackgroundTransparency = 1
			})

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 1
			})

			Phobia.PlayAnimate(LogoImage , SlowyTween , {
				ImageTransparency = 1
			})

			Phobia.PlayAnimate(NotifyName , SlowyTween , {
				TextTransparency = 1
			})

			Phobia.PlayAnimate(NotifyContent , SlowyTween , {
				TextTransparency = 1
			})

			task.wait(0.125);

			Phobia.PlayAnimate(ContainerFrame , SlowyTween , {
				Size = UDim2.new(0, 0, 0, 0)
			})

			task.wait(0.125);

			ContainerFrame:Destroy();
		end))
	end;

	return Notifier;
end;

function Phobia:CreateLogger()
	if Phobia.__LogSystem then
		return 	Phobia.__LogSystem;
	end;

	local Logging = {};
	local Log = Instance.new("Frame")
	local UIListLayout = Instance.new("UIListLayout")

	Log.Name = Phobia.RandomString();
	Log.Parent = Phobia.ScreenGui
	Log.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	Log.BackgroundTransparency = 1.000
	Log.BorderColor3 = Color3.fromRGB(0, 0, 0)
	Log.BorderSizePixel = 0
	Log.Position = UDim2.new(0, 25, 0, 5 + math.abs(Phobia.ScreenGui.AbsolutePosition.Y))
	Log.Size = UDim2.new(0, 25, 0, 25)

	UIListLayout.Parent = Log
	UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout.Padding = UDim.new(0, 12)

	Phobia.__LogSystem = Logging;

	function Logging.new(IconStr: string , Message: string , Duration: number)
		Duration = Duration or 3;
		Message = Message or "Log";
		IconStr = IconStr or "crosshairs";

		local LogFrame = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local UIStroke = Instance.new("UIStroke")
		local LogContent = Instance.new("TextLabel")
		local Line = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local Icon = Instance.new("TextLabel")
		local Shadow = Phobia:CreateShadow(LogFrame , true);

		LogFrame.Name = Phobia.RandomString();
		LogFrame.Parent = Log
		LogFrame.AnchorPoint = Vector2.new(0.5, 0)
		LogFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
		LogFrame.BackgroundTransparency =  1--0.075
		LogFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LogFrame.BorderSizePixel = 0
		LogFrame.ClipsDescendants = true
		LogFrame.Position = UDim2.new(0,0,0,0)
		LogFrame.Size = UDim2.new(0, 0, 0, 20)
		LogFrame.ZIndex = 130

		UICorner.CornerRadius = UDim.new(0, 4)
		UICorner.Parent = LogFrame

		UIStroke.Transparency = 1--0.650
		UIStroke.Color = Color3.fromRGB(45, 48, 58)
		UIStroke.Parent = LogFrame

		LogContent.Name = Phobia.RandomString();
		LogContent.Parent = LogFrame
		LogContent.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		LogContent.BackgroundTransparency = 1.000
		LogContent.BorderColor3 = Color3.fromRGB(0, 0, 0)
		LogContent.BorderSizePixel = 0
		LogContent.Position = UDim2.new(0, 25, 0, 2)
		LogContent.Size = UDim2.new(0, 200, 0, 15)
		LogContent.ZIndex = 132
		LogContent.Font = Enum.Font.GothamMedium
		LogContent.Text = Message
		LogContent.TextColor3 = Color3.fromRGB(255, 255, 255)
		LogContent.TextSize = 12.000
		LogContent.TextTransparency = 1--0.250
		LogContent.TextXAlignment = Enum.TextXAlignment.Left

		Line.Name = Phobia.RandomString();
		Line.Parent = LogFrame
		Line.AnchorPoint = Vector2.new(0, 0.5)
		Line.BackgroundColor3 = Phobia.AccentColor
		Line.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Line.BackgroundTransparency = 1 --0
		Line.BorderSizePixel = 0
		Line.Position = UDim2.new(0, -2, 0.5, 0)
		Line.Size = UDim2.new(0, 5, 1, 0)
		Line.ZIndex = 131

		UICorner_2.CornerRadius = UDim.new(0, 4)
		UICorner_2.Parent = Line

		Icon.Name = Phobia.RandomString();
		Icon.Parent = LogFrame
		Icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Icon.BackgroundTransparency = 1.000
		Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Icon.BorderSizePixel = 0
		Icon.Position = UDim2.new(0, 7, 0, 3)
		Icon.Size = UDim2.new(0, 15, 0, 15)
		Icon.ZIndex = 133
		Icon.Text = ""
		Icon.TextColor3 = Color3.fromRGB(223, 223, 223)
		Icon.TextTransparency = 1--0.250
		Icon.TextWrapped = true
		Phobia:ApplyIcon(Icon , IconStr , { Size = 13 });

		local size = TextService:GetTextSize(LogContent.Text,LogContent.TextSize,LogContent.Font,Vector2.new(math.huge,math.huge));

		Phobia.PlayAnimate(LogFrame , SlowyTween , {
			Size = UDim2.new(0, size.X + 35, 0, 20),
			BackgroundTransparency =  0.075
		});

		task.delay(0.15,LPH_NO_VIRTUALIZE(function()
			Shadow:Render(true);

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 0.650
			});

			Phobia.PlayAnimate(LogContent , SlowyTween , {
				TextTransparency = 0.25
			});

			Phobia.PlayAnimate(Line , SlowyTween , {
				BackgroundTransparency = 0
			});

			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 0.25
			});

			task.wait(Duration + 0.1);

			Shadow:Render(false);

			Phobia.PlayAnimate(LogFrame , SlowyTween , {
				BackgroundTransparency =  1
			});

			Phobia.PlayAnimate(UIStroke , SlowyTween , {
				Transparency = 1
			});

			Phobia.PlayAnimate(LogContent , SlowyTween , {
				TextTransparency = 1
			});

			Phobia.PlayAnimate(Line , SlowyTween , {
				BackgroundTransparency = 1
			});

			Phobia.PlayAnimate(Icon , SlowyTween , {
				TextTransparency = 1
			});

			task.wait(0.25);

			LogFrame:Destroy();
		end))
	end;

	return Logging
end;

function Phobia:CreateIndicator()
	local IndicatorFrame = Instance.new("Frame")
	local UIListLayout = Instance.new("UIListLayout")

	IndicatorFrame.Name = Phobia.RandomString();
	IndicatorFrame.Parent = Phobia.ScreenGui;
	IndicatorFrame.AnchorPoint = Vector2.new(0, 0.5)
	IndicatorFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	IndicatorFrame.BackgroundTransparency = 1.000
	IndicatorFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
	IndicatorFrame.BorderSizePixel = 0
	IndicatorFrame.Position = UDim2.new(0, 15, 0.5, 0)
	IndicatorFrame.Size = UDim2.new(0, 100, 0, 100)
	IndicatorFrame.ZIndex = 15

	UIListLayout.Parent = IndicatorFrame
	UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout.Padding = UDim.new(0, 10)

	local Indicators = {};

	Indicators.Color = {
		Red = Color3.fromRGB(255, 102, 105),
		Green = Color3.fromRGB(135, 255, 143),
		White = Color3.fromRGB(186, 186, 186),
	};

	Indicators.Root = IndicatorFrame;

	function Indicators.new(Config)
		Config = Phobia:ProcessParams(Config , {
			Name = "Indicator",
			Icon = 'crosshairs',
			Color = 'Red',
		});

		local Indicator = {
			CurrentColor = Config.Color,	
			Visible = false,
		};

		local IndicatorItem = Instance.new("Frame")
		local UICorner = Instance.new("UICorner")
		local Line = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local UIGradient = Instance.new("UIGradient")
		local Icon = Instance.new("TextLabel")
		local Content = Instance.new("TextLabel")
		local Shadow = Phobia:CreateShadow(IndicatorItem);

		IndicatorItem.Name = Phobia.RandomString();
		IndicatorItem.BackgroundColor3 = Phobia.MainColor
		IndicatorItem.BackgroundTransparency = 1
		IndicatorItem.BorderColor3 = Color3.fromRGB(0, 0, 0)
		IndicatorItem.BorderSizePixel = 0
		IndicatorItem.ClipsDescendants = true
		IndicatorItem.Size = UDim2.new(0, 85, 0, 40)
		IndicatorItem.ZIndex = 16
		IndicatorItem.Visible = false;

		IndicatorItem:GetPropertyChangedSignal('BackgroundTransparency'):Connect(LPH_NO_VIRTUALIZE(function()
			if IndicatorItem.BackgroundTransparency > 0.9 then
				IndicatorItem.Parent = nil;
				IndicatorItem.Visible = false;
			else
				IndicatorItem.Parent = IndicatorFrame;
				IndicatorItem.Visible = true;
			end;
		end))

		UICorner.CornerRadius = UDim.new(0, 25)
		UICorner.Parent = IndicatorItem

		Line.Name = Phobia.RandomString();
		Line.Parent = IndicatorItem
		Line.AnchorPoint = Vector2.new(0, 0.5)
		Line.BackgroundColor3 = Color3.fromRGB(186, 186, 186)
		Line.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Line.BorderSizePixel = 0
		Line.Position = UDim2.new(0, 2, 0.5, 0)
		Line.BackgroundTransparency = 1;
		Line.Size = UDim2.new(0, 3, 0.649999976, 0)
		Line.ZIndex = 17

		UICorner_2.CornerRadius = UDim.new(0, 25)
		UICorner_2.Parent = Line

		UIGradient.Rotation = 90
		UIGradient.Transparency = NumberSequence.new{NumberSequenceKeypoint.new(0.00, 1.00), NumberSequenceKeypoint.new(0.50, 0.00), NumberSequenceKeypoint.new(1.00, 1.00)}
		UIGradient.Parent = Line

		Icon.Name = Phobia.RandomString();
		Icon.Parent = IndicatorItem
		Icon.AnchorPoint = Vector2.new(0, 0.5)
		Icon.BackgroundColor3 = Color3.fromRGB(186, 186, 186)
		Icon.BackgroundTransparency = 1.000
		Icon.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Icon.BorderSizePixel = 0
		Icon.Position = UDim2.new(0, 10, 0.5, 0)
		Icon.Size = UDim2.new(0, 25, 0, 25)
		Icon.ZIndex = 17
		Icon.Text = "";
		Icon.TextColor3 = Color3.fromRGB(186, 186, 186)
		Icon.TextTransparency = 1
		Icon.TextWrapped = true
		Phobia:ApplyIcon(Icon , Config.Icon , { Size = 20 });

		Content.Name = Phobia.RandomString();
		Content.Parent = IndicatorItem
		Content.AnchorPoint = Vector2.new(0, 0.5)
		Content.BackgroundColor3 = Color3.fromRGB(186, 186, 186)
		Content.BackgroundTransparency = 1.000
		Content.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Content.BorderSizePixel = 0
		Content.Position = UDim2.new(0, 40, 0.5, 0)
		Content.Size = UDim2.new(1, -40, 0, 25)
		Content.ZIndex = 17
		Content.Font = Enum.Font.GothamMedium
		Content.Text = Config.Name
		Content.TextColor3 = Color3.fromRGB(186, 186, 186)
		Content.TextSize = 20.000
		Content.TextTransparency = 1
		Content.TextXAlignment = Enum.TextXAlignment.Left

		Indicator.Update = LPH_NO_VIRTUALIZE(function()
			local text = TextService:GetTextSize(Content.Text,Content.TextSize , Content.Font , Vector2.new(math.huge,math.huge));

			Phobia.PlayAnimate(IndicatorItem , SlowyTween , {
				Size = UDim2.new(0, text.X + 60, 0, 40);
			})
		end);

		Indicator.SetRender = LPH_NO_VIRTUALIZE(function(self , value)
			Indicator.Visible = value;

			if value then
				Phobia.PlayAnimate(IndicatorItem , SlowyTween , {
					BackgroundTransparency = 0.200
				});

				Phobia.PlayAnimate(Line , SlowyTween , {
					BackgroundTransparency = 0,
					BackgroundColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Phobia.PlayAnimate(Icon , VSlowTween , {
					TextTransparency = 0.250,
					TextColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Phobia.PlayAnimate(Content , VSlowTween , {
					TextTransparency = 0.2,
					TextColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Shadow:Render(true);
			else
				Phobia.PlayAnimate(IndicatorItem , SlowyTween , {
					BackgroundTransparency = 1
				});

				Phobia.PlayAnimate(Line , SlowyTween , {
					BackgroundTransparency = 1,
					BackgroundColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Phobia.PlayAnimate(Icon , VSlowTween , {
					TextTransparency = 1,
					TextColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Phobia.PlayAnimate(Content , VSlowTween , {
					TextTransparency = 1,
					TextColor3 = Indicators.Color[Indicator.CurrentColor]
				});

				Shadow:Render(false);
			end;

			Indicator.Update();
		end);

		Indicator.Update();
		Indicator:SetRender(false);

		function Indicator:SetColor(new_color)
			Indicator.CurrentColor = new_color;

			if Indicator.Visible then
				Indicator:SetRender(true);
			end;
		end;

		function Indicator:SetText(name)
			Config.Name = name;

			Content.Text = Config.Name;

			Indicator.Update();
		end;

		return Indicator;
	end;

	return Indicators;
end;

function Phobia:Unload()
	if not Phobia.UnloadEnabled then
		return;	
	end;

	Phobia.ScreenGui:Destroy();

	for i,v in next , Phobia.GlobalSignals do
		pcall(v.Disconnect,v)
	end;
end;

getgenv().Phobia = Phobia;

return Phobia;
