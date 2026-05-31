--[[
* Addons - Copyright (c) 2021 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.

--]]

addon.author   = 'Ferris (Original Designers: MathMatic/DrifterX)';
addon.name     = 'clammyh';
addon.desc     = 'Clamming calculator; AH: /clammyh reloadah (Chrome extension captures token automatically). reloadah token | local | unlock.';
addon.version  = '1.9.4';
local CURRENT_VERSION = addon.version;

require('common');
local const = require('constants');
local func = require('functions');
local ahpricing = require('ahpricing');
Settings = require('settings');

-- One-time migration: copy settings from old 'ClammyHorizon' config dir to new 'clammyh' dir.
do
    local _base  = AshitaCore:GetInstallPath():gsub('/', '\\');
    local _old   = _base .. 'config\\addons\\ClammyHorizon';
    local _new   = _base .. 'config\\addons\\clammyh';
    if (ashita.fs.exists(_old) == true) and (ashita.fs.exists(_new) ~= true) then
        os.execute('cmd /c xcopy /s /e /i /y "' .. _old .. '" "' .. _new .. '" >nul 2>&1');
    end
end

--------------------------------------------------------------------
-- Auto-update  (github.com/ferrisaj87/clammyh)
--------------------------------------------------------------------
local _ok_https, _https = pcall(require, 'socket.ssl.https');
if not _ok_https then _https = nil; end

local _REPO_RAW           = 'https://raw.githubusercontent.com/ferrisaj87/clammyh/master/';
local _UPDATE_VERSION_URL = _REPO_RAW .. 'clammyh.lua';
local _addonDir           = ('%saddons\\clammyh\\'):fmt(AshitaCore:GetInstallPath());
local _UPDATE_FILES = {
    { url = _REPO_RAW .. 'clammyh.lua',   path = _addonDir .. 'clammyh.lua',   label = 'clammyh.lua'   },
    { url = _REPO_RAW .. 'functions.lua',  path = _addonDir .. 'functions.lua',  label = 'functions.lua'  },
    { url = _REPO_RAW .. 'constants.lua',  path = _addonDir .. 'constants.lua',  label = 'constants.lua'  },
    { url = _REPO_RAW .. 'ahpricing.lua',  path = _addonDir .. 'ahpricing.lua',  label = 'ahpricing.lua'  },
};

local _updateMsgDelay = nil;
local _latestVersion  = nil;

local function _clammyEcho(msg)
    AshitaCore:GetChatManager():QueueCommand(1, '/echo [ClammyHorizon] ' .. tostring(msg));
end

local function _parseVer(s)
    local t = {};
    for n in tostring(s):gmatch('%d+') do t[#t+1] = tonumber(n); end
    return t;
end

local function _verGt(a, b)
    local pa, pb = _parseVer(a), _parseVer(b);
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0;
        if x > y then return true; end
        if x < y then return false; end
    end
    return false;
end

local function _fetchRemoteVersion()
    if (_https == nil) then return nil; end
    local ok, body, code = pcall(function()
        return _https.request(_UPDATE_VERSION_URL .. '?t=' .. os.time());
    end);
    if (not ok) or (code ~= 200) or (not body) then return nil; end
    return (body:match("addon%.version%s*=%s*'([^']+)'")
         or body:match('addon%.version%s*=%s*"([^"]+)"'));
end

local function _checkForUpdate()
    local remote = _fetchRemoteVersion();
    if (not remote) then return; end
    if _verGt(remote, CURRENT_VERSION) then
        _latestVersion  = remote;
        _updateMsgDelay = os.clock() + 2;
    end
end

local function _performUpdate()
    if (_https == nil) then
        _clammyEcho('Cannot update: socket.ssl.https is not available.');
        return;
    end
    _clammyEcho('Checking for updates...');
    local remote = _fetchRemoteVersion();
    if (not remote) then
        _clammyEcho('Could not reach GitHub to check for updates.');
        return;
    end
    if not _verGt(remote, CURRENT_VERSION) then
        _clammyEcho('Already up to date. (v' .. CURRENT_VERSION .. ')');
        return;
    end
    _clammyEcho('Downloading v' .. remote .. '...');
    for _, f in ipairs(_UPDATE_FILES) do
        local fok, fbody, fcode = pcall(function()
            return _https.request(f.url .. '?t=' .. os.time());
        end);
        if (not fok) or (fcode ~= 200) or (not fbody) or (fbody == '') then
            _clammyEcho('Failed to download ' .. f.label .. ' (HTTP ' .. tostring(fcode) .. '). Update aborted.');
            return;
        end
        local out = io.open(f.path, 'wb');
        if (out == nil) then
            _clammyEcho('Failed to write ' .. f.label .. '. Update aborted.');
            return;
        end
        out:write(fbody);
        out:close();
        _clammyEcho('Updated ' .. f.label .. '.');
    end
    _updateMsgDelay = nil;
    _latestVersion  = nil;
    _clammyEcho('Update to v' .. remote .. ' complete! Type: /addon reload clammyh');
end
--------------------------------------------------------------------


local defaultConfig = T{
	showItems = T{ true, },
	showValue = T{ true, },
	showSessionInfo = T{ true, },
	log = T{ true, },
	sessionLog = T{ true, },
	tone = T{ false, },
	useStopTone = T{ true, },
	trackMoonPhase = T{ true, },
	colorWeightBasedOnValue = T{ true, },
	hideInDifferentZone = T{ true, },
	autoResetLog = T{ true, },
	resetFullSession = T{ false, },
	minutesBeforeAutoReset = T{ 120, },
	highValue = T{ 5000 },
	midValue = T{ 1000 },
	lowValue = T{ 500 },
	items = const.clammingItems,
	splitItemsBySellType = T{ true, },
	subtractBucketCostFromGilEarned = T{ true, },
	showAverageTimePerBucket = T{ true, },
	showPercentChanceToBreak = T{ true, },
	legacyLog = T{ false, },
	alwaysStopAtThirdBucket = T{ true, },
	checkEquippedItem = T{ true, },
	windowScaling = T{ 1.0, },
	showDayOfWeek = T{ true, },
	showClammyHealth = T{ true, },
	showClammingAttempts = T{ true, },
	gilPerHourStabilizeMinutes = T{ 10, },
	useAhPricingFromFile = T{ true, },
	ahPricesGeneratedUtc = T{ '', },
}
Config = Settings.load(defaultConfig);

-- Remove items that no longer exist on HorizonXI from any saved settings.
do
    local _removed = { ['Elshimo coconut']=true, ['Igneous rock']=true, ['Pamamas']=true };
    if (Config.items ~= nil) then
        for i = #Config.items, 1, -1 do
            if (_removed[Config.items[i].item] == true) then
                table.remove(Config.items, i);
            end
        end
    end
end

local clammy = T{
	bucketSize = 50,
	relativeWeight = 50,
	percentRemaining = 0,
	weight = 0,
	money  = 0,
	sessionValue = 0,
	sessionValueNPC = 0,
	sessionValueAH = 0,
	bucketsPurchased = 0,
	bucketsReceived = 0,
	bucket = {},
	trackingBucket = {},
	cooldown = 0,
	startingTime = os.clock(),
	sessionStarted = false,
	clammingAttempts = 0,
	bucketStartTime = 0,
	lastClammingAction = os.clock(),
	sessionWasReset = false,
	bucketAverageTime = 0,
	bucketTimeWith = 0,
	gilPerHour = 0,
	gilPerHourNPC = 0,
	gilPerHourAH = 0,
	gilPerHourMinusBucket = 0,
	clammingAttemptsPerHour = 0,
	trueSessionValue = 0,
	trueSessionValueNPC = 0,
	trueSessionValueAH = 0,
	hasBucket = false,
	bucketIsBroke = false,
	bucketShouldBeTurnedIn = false,
	editorIsOpen = T{ false, },
	browserIsOpen = T{ false, },
	hasHQLegs = false,
	hasHQBody = false,
	bodyItemId = 0,
	legItemId = 0,
	moonTable = T{
		moonPhase = "",
		moonPercent = 0,
	},
	vanaTime = T{
		dayName = "",
		dayOfWeekColor = T{
			0, 0, 0, 0,
		},
		hourInt = 0,
	},
	bucketColor = {1.0,1.0,1.0,1.0},
	stopSound = false,
	items = Config.items,
	hideInDifferentZone = Config.hideInDifferentZone,
	fileName = ('log_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S')),
	fileNameBroken = ('log_broken_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S')),
	-- final path: Game\config\addons\ClammyHorizon\<CharName>\logs\
	fileDir = ('%sconfig\\addons\\ClammyHorizon\\player\\logs\\'):fmt(AshitaCore:GetInstallPath()),
	playTone = false,
	showItemSeparator = false,
	sessionDropTotals = T{},
	sessionBreakLossGil = 0,
	sessionBreakLossByItem = T{},
	sessionReportFileName = ('session_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S')),
	sessionReportStartWall = os.date('%Y-%m-%d %H:%M:%S'),
	sessionReportLogStarted = false,
	-- throttled in render: gil/hr + dpm refresh at most once/minute or on bucket turn-in/break
	forceSessionMetricsRefresh = false,
	-- Horizon helper: lock file created before spawn; polled every frame (throttled)
	horizonRefreshPending = false,
	horizonBgLastCheck = 0,
}
clammy.filePath = clammy.fileDir .. clammy.fileName;
clammy.filePathBroken = clammy.fileDir .. clammy.fileNameBroken;
clammy.sessionReportPath = clammy.fileDir .. clammy.sessionReportFileName;

-- Character switch reloads merged settings into a **new** table; keep globals in sync + re-run AH overlay.
Settings.register('settings', 'clammy_pricing_resync', function(s)
	Config = s;
	ahpricing.applyFromFile(s);
	clammy.items = Config.items;
	func.resetBrowserAhCache();
end);

--------------------------------------------------------------------
ashita.events.register('load', 'load_cb', function()
	ashita.fs.create_directory(func.clammyConfigLogsDirectory());
	ahpricing.applyFromFile(Config);
	clammy = func.refreshLogPaths(clammy);
	clammy.sessionReportFileName = ('session_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.sessionReportPath = clammy.fileDir .. clammy.sessionReportFileName;
	clammy.sessionReportStartWall = os.date('%Y-%m-%d %H:%M:%S');
	clammy.sessionReportLogStarted = false;
	clammy.sessionDropTotals = T{};
	clammy.sessionBreakLossGil = 0;
	clammy.sessionBreakLossByItem = T{};
	clammy = func.emptyBucket(clammy, true, true);

	if (ashita.fs ~= nil) and (ashita.fs.exists ~= nil) then
		local lk = func.clammyConfigDataDirectory() .. 'horizon_helper.lock';
		if (ashita.fs.exists(lk) == true) then
			clammy.horizonRefreshPending = true;
			clammy.horizonBgLastCheck = 0;
		end
	end

	pcall(_checkForUpdate);
end);

--------------------------------------------------------------------
ashita.events.register('unload', 'unload_cb', function()
	if (Config.sessionLog[1] == true) then
		clammy = func.writeSessionReport(clammy, 'unload');
	end
end);

--------------------------------------------------------------------
ashita.events.register('command', 'command_cb', function (e)
    -- Parse the command arguments..
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/clammyh')) then
		return;
    end

    -- Block all related commands..
    e.blocked = true;

	if (#args >= 2 and args[2]:any('update')) then
		_performUpdate();
		return;
	end

	clammy = func.handleChatCommands(args, clammy);
end);

--------------------------------------------------------------------
ashita.events.register('text_in', 'Clammy_HandleText', function (e)

    if (e.injected == true) then
        return;
    end

	clammy = func.handleTextIn(e, clammy);

end);

--------------------------------------------------------------------
--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
	if (_updateMsgDelay ~= nil) and (os.clock() >= _updateMsgDelay) then
		_clammyEcho(('Update available!  Current: v%s  |  Latest: v%s  --  Type /clammyh update to install.'):fmt(
			CURRENT_VERSION, tostring(_latestVersion)));
		_updateMsgDelay = nil;
	end

	clammy = func.pollHorizonBackgroundHelper(clammy);
	if (clammy.editorIsOpen[1] == true) then
		clammy = func.renderEditor(clammy);
	end

	clammy = func.renderItemBrowser(clammy);
	clammy = func.renderClammy(clammy);
end);