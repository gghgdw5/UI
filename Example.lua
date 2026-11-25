--[[
    Phobia UI — пример использования
    ~ penablox RECODE Lua API ~

    Скрипт собирает полноценное HvH-меню (Rage / Anti-Aim / Visuals / Misc),
    привязывает элементы к cheat-API (`aa`, `rage`, `chams`, `sounds`,
    `clantag`, `notify`) и показывает работу индикаторов, нотификаций,
    логгера и конфигов.

    Все обращения к cheat-API обёрнуты в проверки `if aa and aa.override_pitch`,
    поэтому пример без ошибок работает и там, где этих глобалов нет —
    просто интерфейс будет без привязок.

    Управление:  Insert — показать/скрыть окно.
]]

--========================================================================================
--  1. Загрузка библиотеки
--========================================================================================

-- Если библиотека уже загружена этим же инжектом — переиспользуем её
local Phobia = getgenv().Phobia;

if not Phobia then
	-- вариант 1: локальный файл рядом (некоторые окружения отдают readfile)
	local __loaded = false;

	if type(readfile) == 'function' and pcall(function() return readfile('Phobia.lua') end) then
		local __fn = loadstring(readfile('Phobia.lua'));

		if __fn then
			Phobia = __fn();
			__loaded = true;
		end;
	end;

	-- вариант 2: подгрузка с хоста (поменяйте URL на свой)
	if not __loaded then
		Phobia = loadstring(game:HttpGet('https://raw.githubusercontent.com/gghgdw5/UI/refs/heads/arena%2F22825e17-ui/Phobia.lua'))();
	end;
end;

-- повторный инжект: выгружаем прошлый запуск (окно, события, индикаторы)
if getgenv().PhobiaExample then
	pcall(getgenv().PhobiaExample);
end;

--========================================================================================
--  2. Окно
--========================================================================================

local Window = Phobia:CreateWindow({
	Name = 'Phobia',                        -- заголовок (шрифт-лого "P" рисуется автоматически)
	Content = 'penablox recode',            -- подпись под заголовком
	Size = Phobia.Scales.Default,           -- 640x480 (есть Small/Mobile/Large)
	ConfigFolder = 'Phobia/Configs',        -- папка конфигов (виртуальная ФС поддерживается)
	Keybind = 'Insert',                     -- клавиша показа/скрытия окна
	-- Enable3DRenderer = true,             -- рендер окна в 3D-мире (опционально)
});

-- правое меню пользователя (кнопка профиля внизу слева)
Window.UserSettings:AddUserFrame('User', nil, 'premium forever');

-- текстовые разделители в списке табов
Window:AddTabLabel('-- hvh setup --');

--========================================================================================
--  3. Общие флаги состояния
--========================================================================================

local State = {
	DesyncLeft = 58,
	DesyncRight = 58,

	Hitsound = 'skeet',
	HitsoundVolume = 100,
	HitsoundPitch = 100,

	ClantagOn = false,
	ClantagSpeed = 0.25,
};

local function ApplyChams(VisColor, OccColor, Material, Transparency)
	if not (chams and chams.set_enabled) then
		return;
	end;

	-- цвет пикеры отдают Color3
	chams.set_enabled(true);
	chams.override_visible(VisColor, Material, Transparency);
	chams.override_occluded(OccColor, Material, Transparency);
end;

local function ApplyHitsound()
	if not (sounds and sounds.override_hitsound) then
		return;
	end;

	sounds.override_hitsound(State.Hitsound, State.HitsoundVolume / 100, State.HitsoundPitch / 100);
end;

local function ApplyDesync()
	if not (aa and aa.override_desync_limits) then
		return;
	end;

	-- до 86 градусов на каждую сторону
	aa.override_desync_limits(State.DesyncLeft, State.DesyncRight);
end;

local function ApplyClantag()
	if not (clantag and clantag.set_frames) then
		return;
	end;

	if State.ClantagOn then
		clantag.set_frames({ 'p', 'ph', 'pho', 'phob', 'phobi', 'phobia', 'phobi', 'phob', 'pho', 'ph' }, State.ClantagSpeed);
	else
		clantag.reset();
	end;
end;

--========================================================================================
--  4. Таб "Rage" — аим и резольвер
--========================================================================================

local RageTab = Window:AddTab({ Name = 'rage', Icon = 'crosshair' });
local RageLeft = RageTab:AddSection({ Name = 'aimbot', Position = 'left' });
local RageRight = RageTab:AddSection({ Name = 'resolver', Position = 'right' });

-- паттерн: AddLabel создаёт строку с названием, а Add* прикрепляет контролы к ней.
-- На одной строке можно разместить несколько контролов (тоггл + кейбинд и т.д.)

local RageRow = RageLeft:AddLabel('ragebot');
RageRow:AddToggle({
	Default = true,
	Flag = 'Rage.Enabled',                  -- Phobia.Flags['Rage.Enabled']:GetValue/SetValue
	Callback = function(v)
		if rage and rage.override_enabled then
			rage.override_enabled(v);
		end;
	end,
});
RageRow:AddOption(1);                       -- иконка-шестерёнка с доп. меню строки

RageLeft:AddLabel('aim key'):AddKeybind({
	Flag = 'Rage.AimKey',
	Default = 'F',                          -- имя клавиши (см. Phobia.KeyEnum)
	Callback = function(down)               -- down = true при нажатии, false при отпускании
		if rage and rage.override_enabled then
			rage.override_enabled(down);
		end;
	end,
});

RageLeft:AddLabel('target selection'):AddDropdown({
	Flag = 'Rage.TargetSelection',
	Values = { 'Highest damage', 'Near crosshair', 'Best hitchance', 'Cycle' },
	Default = 'Highest damage',
	Callback = function(v)
		if rage and rage.override_target_selection then
			rage.override_target_selection(v);
		end;
	end,
});

RageLeft:AddLabel('hitboxes'):AddDropdown({
	Flag = 'Rage.Hitboxes',
	Multi = true,                           -- мультивыбор: коллбек получает таблицу {name=true,...}
	Values = { 'head', 'chest', 'pelvis', 'arms', 'legs' },
	Default = { 'head', 'chest' },
	Callback = function(selected)
		if rage and rage.override_hitboxes then
			local List = {};

			for Name , On in pairs(selected) do
				if On then
					List[#List + 1] = Name;
				end;
			end;

			rage.override_hitboxes(List);
		end;
	end,
});

RageLeft:AddLabel('min damage'):AddSlider({
	Flag = 'Rage.MinDamage',
	Min = 0, Max = 100, Default = 72,
	Type = ' dmg',                          -- суффикс значения
	Callback = function(v)
		if rage and rage.override_min_damage then
			rage.override_min_damage(v);
		end;
	end,
});

RageLeft:AddLabel('hitchance'):AddSlider({
	Flag = 'Rage.Hitchance',
	Min = 0, Max = 100, Default = 80,
	Type = '%',
	Callback = function(v)
		if rage and rage.override_hitchance then
			rage.override_hitchance(v);
		end;
	end,
});

RageLeft:AddLabel('force body aim'):AddToggle({
	Flag = 'Rage.ForceBaim',
	Callback = function(v)
		if rage and rage.override_force_baim then
			rage.override_force_baim(v);
		end;
	end,
});

RageLeft:AddLabel('force safe point'):AddToggle({
	Flag = 'Rage.ForceSafePoint',
	Callback = function(v)
		if rage and rage.override_force_safe_point then
			rage.override_force_safe_point(v);
		end;
	end,
});

RageRight:AddLabel('resolver mode'):AddDropdown({
	Flag = 'Rage.ResolverMode',
	Values = { 'Brute-force', 'Adaptive', 'Freestanding' },
	Default = 'Adaptive',
	Callback = function(v)
		if rage and rage.set_resolver_mode then
			rage.set_resolver_mode(v);
		end;
	end,
});

RageRight:AddLabel('miss limit'):AddSlider({
	Flag = 'Rage.MissLimit',
	Min = 1, Max = 5, Default = 2,
	Callback = function(v)
		if rage and rage.set_resolver_miss_limit then
			rage.set_resolver_miss_limit(v);
		end;
	end,
});

RageRight:AddLabel('baim after misses'):AddSlider({
	Flag = 'Rage.BaimAfterMisses',
	Min = 0, Max = 5, Default = 2,
	Callback = function(v)
		if rage and rage.set_resolver_baim_after_misses then
			rage.set_resolver_baim_after_misses(v);
		end;
	end,
});

RageRight:AddButton({
	Name = 'reset resolver',
	Icon = 'refresh',                       -- встроенная рисованная иконка
	Callback = function()
		if rage and rage.reset_resolver_state then
			rage.reset_resolver_state();
		end;

		Phobia:CreateLogger().new('refresh', 'Resolver state reset', 3);
	end,
});

--========================================================================================
--  5. Таб "Anti-Aim"
--========================================================================================

local AATab = Window:AddTab({ Name = 'anti-aim', Icon = 'shield' });
local AALeft = AATab:AddSection({ Name = 'angles', Position = 'left' });
local AARight = AATab:AddSection({ Name = 'fake lag & jitter', Position = 'right' });

AALeft:AddLabel('pitch'):AddDropdown({
	Flag = 'AA.Pitch',
	Values = { 'Down', 'Up', 'Zero', 'Random' },
	Default = 'Down',
	Callback = function(v)
		if aa and aa.override_pitch then
			aa.override_pitch(v == 'Down' and -89 or v == 'Up' and 89 or v == 'Zero' and 0 or 'Random');
		end;
	end,
});

AALeft:AddLabel('yaw offset'):AddSlider({
	Flag = 'AA.YawOffset',
	Min = -180, Max = 180, Default = 180,
	Type = '°',
	Callback = function(v)
		if aa and aa.override_yaw_offset then
			aa.override_yaw_offset(v);
		end;
	end,
});

AALeft:AddLabel('desync left'):AddSlider({
	Flag = 'AA.DesyncLeft',
	Min = 0, Max = 86, Default = State.DesyncLeft,
	Type = '°',
	Callback = function(v)
		State.DesyncLeft = v;
		ApplyDesync();
	end,
});

AALeft:AddLabel('desync right'):AddSlider({
	Flag = 'AA.DesyncRight',
	Min = 0, Max = 86, Default = State.DesyncRight,
	Type = '°',
	Callback = function(v)
		State.DesyncRight = v;
		ApplyDesync();
	end,
});

AALeft:AddLabel('inverter'):AddToggle({
	Flag = 'AA.Inverter',
	Callback = function(v)
		if aa and aa.override_inverter then
			aa.override_inverter(v);
		end;
	end,
});

AALeft:AddLabel('show fake'):AddToggle({
	Flag = 'AA.ShowFake',
	Default = true,
	Callback = function(v)
		if aa and aa.override_show_fake then
			aa.override_show_fake(v);
		end;
	end,
});

AARight:AddLabel('fake lag'):AddToggle({
	Flag = 'AA.FakeLag',
	Callback = function(v)
		if aa and aa.override_fake_lag then
			aa.override_fake_lag(v);
		end;
	end,
});

AARight:AddLabel('choke limit'):AddSlider({
	Flag = 'AA.ChokeLimit',
	Min = 0, Max = 14, Default = 14,
	Type = ' ticks',
	Callback = function(v)
		if aa and aa.override_fake_lag_limit then
			aa.override_fake_lag_limit(v);
		end;
	end,
});

AARight:AddLabel('variability'):AddSlider({
	Flag = 'AA.Variability',
	Min = 0, Max = 100, Default = 25,
	Type = '%',
	Callback = function(v)
		if aa and aa.override_fake_lag_variability then
			aa.override_fake_lag_variability(v);
		end;
	end,
});

AARight:AddLabel('jitter'):AddDropdown({
	Flag = 'AA.Jitter',
	Values = { 'Disabled', 'Spin', 'Random', 'Center', '3-Way', '5-Way' },
	Default = 'Disabled',
	Callback = function(v)
		if aa and aa.override_yaw_modifier then
			aa.override_yaw_modifier(v);
		end;
	end,
});

AARight:AddLabel('freestand'):AddKeybind({
	Flag = 'AA.Freestand',
	Default = 'C',
	Callback = function(down)
		if aa and aa.override_yaw_offset then
			-- на удержание уводим yaw на 180 от камеры, при отпускании возвращаем слайдер
			if down then
				aa.override_yaw_offset(180, 'camera');
			else
				aa.override_yaw_offset(180);
			end;
		end;
	end,
});

--========================================================================================
--  6. Таб "Visuals" — чамсы и звук
--========================================================================================

local VisTab = Window:AddTab({ Name = 'visuals', Icon = 'eye' });
local VisLeft = VisTab:AddSection({ Name = 'chams', Position = 'left' });
local VisRight = VisTab:AddSection({ Name = 'audio', Position = 'right' });

local ChamVisColor = Color3.fromRGB(120, 132, 255);
local ChamOccColor = Color3.fromRGB(255, 60, 90);
local ChamMaterial = 'Neon';
local ChamTransparency = 0.2;

VisLeft:AddLabel('enabled'):AddToggle({
	Flag = 'Vis.Chams',
	Default = true,
	Callback = function(v)
		if chams and chams.set_enabled then
			chams.set_enabled(v);
		end;
	end,
});

VisLeft:AddLabel('visible color'):AddColorPicker({
	Flag = 'Vis.VisibleColor',
	Default = ChamVisColor,                 -- можно и hex-строкой: '#7884ff'
	Callback = function(c)
		ChamVisColor = c;
		ApplyChams(ChamVisColor, ChamOccColor, ChamMaterial, ChamTransparency);
	end,
});

VisLeft:AddLabel('occluded color'):AddColorPicker({
	Flag = 'Vis.OccludedColor',
	Default = ChamOccColor,
	Callback = function(c)
		ChamOccColor = c;
		ApplyChams(ChamVisColor, ChamOccColor, ChamMaterial, ChamTransparency);
	end,
});

VisLeft:AddLabel('material'):AddDropdown({
	Flag = 'Vis.Material',
	-- список материалов можно взять движком: chams.get_materials()
	Values = (chams and chams.get_materials and chams.get_materials())
		or { 'Solid', 'Flat', 'Glow', 'Wireframe', 'Glass', 'ForceField', 'Neon', 'Metalic', 'Bubble', 'Pulse' },
	Default = ChamMaterial,
	Callback = function(v)
		ChamMaterial = v;
		ApplyChams(ChamVisColor, ChamOccColor, ChamMaterial, ChamTransparency);
	end,
});

VisLeft:AddLabel('transparency'):AddSlider({
	Flag = 'Vis.Transparency',
	Min = 0, Max = 100, Default = 20,
	Type = '%',
	Callback = function(v)
		ChamTransparency = v / 100;
		ApplyChams(ChamVisColor, ChamOccColor, ChamMaterial, ChamTransparency);
	end,
});

-- дропдаун из встроенных пресетов движка
local HitNames = (sounds and sounds.get_hitsound_names and sounds.get_hitsound_names()) or { 'skeet', 'neverlose', 'bell', 'bubble', 'zap', 'retro' };

VisRight:AddLabel('hitsound'):AddDropdown({
	Flag = 'Vis.Hitsound',
	Values = HitNames,
	Default = State.Hitsound,
	Callback = function(v)
		State.Hitsound = v;
		ApplyHitsound();
	end,
});

VisRight:AddLabel('volume'):AddSlider({
	Flag = 'Vis.Volume',
	Min = 10, Max = 200, Default = 100,
	Type = '%',
	Callback = function(v)
		State.HitsoundVolume = v;
		ApplyHitsound();
	end,
});

VisRight:AddLabel('pitch'):AddSlider({
	Flag = 'Vis.Pitch',
	Min = 50, Max = 200, Default = 100,
	Type = '%',
	Callback = function(v)
		State.HitsoundPitch = v;
		ApplyHitsound();
	end,
});

VisRight:AddButton({
	Name = 'test hitsound',
	Icon = 'play',
	Callback = function()
		if sounds and sounds.play_hitsound then
			sounds.play_hitsound();
		end;
	end,
});

VisRight:AddButton({
	Name = 'reset hitsound',
	Icon = 'rotate-cw',
	Callback = function()
		if sounds and sounds.reset_hitsound then
			sounds.reset_hitsound();
		end;
	end,
});

-- картинка-блок (пустое поле с разделителем; Image можно задать rbxasset-строкой)
VisRight:AddImage({ Size = UDim2.new(1, 0, 0, 45) });

--========================================================================================
--  7. Таб "Misc" — клантег и система
--========================================================================================

local MiscTab = Window:AddTab({ Name = 'misc', Icon = 'flame' });
local MiscLeft = MiscTab:AddSection({ Name = 'identity', Position = 'left' });
local MiscRight = MiscTab:AddSection({ Name = 'system', Position = 'right' });

MiscLeft:AddLabel('phobia clantag'):AddToggle({
	Flag = 'Misc.Clantag',
	Callback = function(v)
		State.ClantagOn = v;
		ApplyClantag();
	end,
});

MiscLeft:AddLabel('tag speed'):AddSlider({
	Flag = 'Misc.TagSpeed',
	Min = 1, Max = 10, Default = 4,
	Type = 'x',
	Callback = function(v)
		State.ClantagSpeed = 1.25 / v;      -- движок ждёт интервал в секундах
		ApplyClantag();
	end,
});

MiscRight:AddButton({
	Name = 'notify test',
	Icon = 'bell',
	Callback = function()
		-- встроенные тосты Phobia
		Phobia:CreateNotification():new({
			Title = 'Phobia',
			Content = 'Notification from example script',
			Duration = 3,
		});

		-- и нативные нотификации движка, если доступны
		if notify then
			notify({ Title = 'Phobia', Text = 'engine notify() works too', Duration = 2.5 });
		end;
	end,
});

MiscRight:AddButton({
	Name = 'unload',
	Icon = 'logout',
	ToolTip = 'Unloads the UI and restores all cheat settings',
	Callback = function()
		if getgenv().PhobiaExample then
			getgenv().PhobiaExample();
		end;
	end,
});

--========================================================================================
--  8. Индикаторы (нижний левый угол)
--========================================================================================

local Indicators = Phobia:CreateIndicator();

local IndDT = Indicators.new({ Name = 'DT', Icon = 'zap', Color = 'Green' });
local IndFS = Indicators.new({ Name = 'FREESTAND', Icon = 'shield', Color = 'White' });
local IndBA = Indicators.new({ Name = 'BAIM', Icon = 'skull', Color = 'Red' });

IndDT:SetRender(false);
IndFS:SetRender(false);
IndBA:SetRender(false);

--========================================================================================
--  9. Кейбинды-тумблеры (левый верхний угол — логгер + индикаторы)
--========================================================================================

local Logger = Phobia:CreateLogger();

Window:AddTab({ Name = 'keybinds', Icon = 'lock' }):AddSection({ Name = 'binds', Position = 'left' })
	:AddLabel('double tap'):AddKeybind({
		Flag = 'Binds.DoubleTap',
		Default = 'E',
		Callback = function(down)
			IndDT:SetRender(down);

			if rage and rage.force_shift then
				if down then
					rage.force_shift(14);
				end;
			end;

			Logger.new(down and 'zap' or 'x', down and 'Double tap charged' or 'Double tap released', 2);
		end,
	});

Window.Tabs[#Window.Tabs]:AddSection({ Name = 'binds', Position = 'right' })
	:AddLabel('force baim'):AddKeybind({
		Flag = 'Binds.ForceBaim',
		Default = 'V',
		Callback = function(down)
			IndBA:SetRender(down);

			if rage and rage.override_force_baim then
				rage.override_force_baim(down);
			end;
		end,
	});

-- индикатор freestand обновляется из кейбинда выше (раздел Anti-Aim)
-- пример смены цвета и текста:
-- IndFS:SetText('FS'); IndFS:SetColor('Green'); IndFS:SetRender(true);

--========================================================================================
--  10. Приветствие и очистка
--========================================================================================

Logger.new('phobia', 'Welcome to Phobia', 3.5);      -- лого-"P" как иконка логгера

Phobia:CreateNotification():new({
	Title = 'Phobia loaded',
	Content = 'Press Insert to open the menu',
	Duration = 4,
});

-- применяем стартовые значения
ApplyDesync();
ApplyChams(ChamVisColor, ChamOccColor, ChamMaterial, ChamTransparency);
ApplyHitsound();

-- пример работы с флагами напрямую:
-- Phobia.Flags['Rage.Enabled']:SetValue(false)    -- выключит тоггл + вызовет коллбек
-- Phobia.Flags['Rage.Enabled']:GetValue()         -- текущее состояние

-- движок вызывает 'shutdown' при выгрузке скрипта — снимаем переопределения
if client and client.set_event_callback then
	client.set_event_callback('shutdown', function()
		pcall(function()
			if aa and aa.reset then aa.reset(); end;
			if rage and rage.reset then rage.reset(); end;
			if chams and chams.clear_overrides then chams.clear_overrides(); end;
			if sounds and sounds.reset_hitsound then sounds.reset_hitsound(); sounds.reset_killsound(); end;
			if clantag and clantag.reset then clantag.reset(); end;
		end);
	end);
end;

-- функция полной выгрузки (доступна и снаружи: getgenv().PhobiaExample())
getgenv().PhobiaExample = function()
	pcall(function()
		if aa and aa.reset then aa.reset(); end;
		if rage and rage.reset then rage.reset(); end;
		if chams and chams.clear_overrides then chams.clear_overrides(); end;
		if sounds and sounds.reset_hitsound then sounds.reset_hitsound(); sounds.reset_killsound(); end;
		if clantag and clantag.reset then clantag.reset(); end;
	end);

	pcall(function()
		Phobia:Unload();
	end);

	getgenv().PhobiaExample = nil;
end;
