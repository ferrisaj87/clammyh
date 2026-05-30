local const = require("constants");
require('common');
local ahpricing = require('ahpricing');
local chat = require('chat');
local imgui = require('imgui');
local json  = require('libs.json');
local ffi   = require('ffi');
local d3d8  = require('d3d8');
require('d3d8.d3dx8');
local func = T{};
local colorConverter = imgui.ColorConvertU32ToFloat4;

-- Arrow textures for AH price change indicator (lazy-loaded on first render).
local _arrowTextures = nil;
local function _loadArrowTextures()
	local ok, device = pcall(d3d8.get_device);
	if (not ok) or (device == nil) then return nil; end
	local imgDir = ('%saddons\\clammyh\\images\\'):fmt(AshitaCore:GetInstallPath():gsub('/', '\\'));
	local function loadTex(filename)
		local fullPath = imgDir .. filename;
		local ptr = ffi.new('IDirect3DTexture8*[1]');
		local res = ffi.C.D3DXCreateTextureFromFileA(device, fullPath, ptr);
		if (res ~= ffi.C.S_OK) then return nil; end
		local tex = ffi.new('IDirect3DTexture8*', ptr[0]);
		d3d8.gc_safe_release(tex);
		return tex;
	end
	local okU, up   = pcall(loadTex, 'Up.png');
	local okD, down = pcall(loadTex, 'Down.png');
	return { up = okU and up or nil, down = okD and down or nil };
end

local BUCKET_COST_GIL = 500;

local ITEM_STACK_SIZE = {
	['Bibiki slug']               = 12,
	['Bibiki urchin']             = 12,
	['Broken willow fishing rod'] = 1,
	['Coral fragment']            = 12,
	['Quality crab shell']        = 12,
	['Crab shell']                = 12,
	['Elm log']                   = 12,
	['Fish scales']               = 12,
	['Goblin armor']              = 12,
	['Goblin mail']               = 12,
	['Goblin mask']               = 12,
	['Hobgoblin bread']           = 12,
	['Hobgoblin pie']             = 12,
	['Jacknife']                  = 12,
	['Lacquer tree log']          = 12,
	['Maple log']                 = 12,
	['Nebimonite']                = 12,
	['Oxblood']                   = 12,
	['Pamtam kelp']               = 12,
	['Pebble']                    = 99,
	['Petrified log']             = 12,
	['Quality pugil scales']      = 12,
	['Pugil scales']              = 12,
	['Rock salt']                 = 12,
	['Seashell']                  = 12,
	['Shall shell']               = 12,
	['Titanictus shell']          = 12,
	['Tropical clam']             = 12,
	['Turtle shell']              = 12,
	['Uragnite shell']            = 12,
	['Vongola clam']              = 12,
	['White sand']                = 12,
};

-- NPC vendor prices (gil/unit) — items that NPCs won't buy have 0.
local ITEM_VENDOR_GIL = {
	['Bibiki slug']               = 9,
	['Bibiki urchin']             = 750,
	['Broken willow fishing rod'] = 0,
	['Coral fragment']            = 1750,
	['Quality crab shell']        = 3125,
	['Crab shell']                = 371,
	['Elm log']                   = 384,
	['Fish scales']               = 23,
	['Goblin armor']              = 0,
	['Goblin mail']               = 0,
	['Goblin mask']               = 0,
	['Hobgoblin bread']           = 90,
	['Hobgoblin pie']             = 150,
	['Jacknife']                  = 53,
	['Lacquer tree log']          = 3500,
	['Maple log']                 = 15,
	['Nebimonite']                = 52,
	['Oxblood']                   = 13250,
	['Pamtam kelp']               = 8,
	['Pebble']                    = 1,
	['Petrified log']             = 2150,
	['Quality pugil scales']      = 260,
	['Pugil scales']              = 23,
	['Rock salt']                 = 3,
	['Seashell']                  = 33,
	['Shall shell']               = 293,
	['Titanictus shell']          = 350,
	['Tropical clam']             = 5100,
	['Turtle shell']              = 1200,
	['Uragnite shell']            = 1455,
	['Vongola clam']              = 192,
	['White sand']                = 250,
};

local function findItemDefByName(name)
	if (name == nil) then
		return nil;
	end
	for _, it in ipairs(Config.items) do
		if (it.item == name) then
			return it;
		end
	end
	return nil;
end

-- Shared addon data (AH prices, bearer token, helper IPC files).
-- path: Game\config\addons\ClammyHorizon\data\
func.clammyConfigDataDirectory = function()
	return ('%sconfig\\addons\\ClammyHorizon\\data\\'):fmt(AshitaCore:GetInstallPath());
end

-- Per-character session logs (dig CSV, session reports).
-- path: Game\config\addons\ClammyHorizon\<CharName>\logs\
-- Falls back to "player" if the character name is not yet available.
func.clammyCharLogsDirectory = function()
	local name = '';
	local mm = AshitaCore:GetMemoryManager();
	if (mm ~= nil) then
		local party = mm:GetParty();
		if (party ~= nil) then
			local n = party:GetMemberName(0);
			if (n ~= nil) then name = n; end
		end
	end
	if (name == '') then name = 'player'; end
	return ('%sconfig\\addons\\ClammyHorizon\\%s\\logs\\'):fmt(AshitaCore:GetInstallPath(), name);
end

-- Legacy alias kept so external callers still compile (points to char logs dir).
func.clammyConfigLogsDirectory = func.clammyCharLogsDirectory;

func.refreshLogPaths = function(clammy)
	local newDir = func.clammyCharLogsDirectory();
	if (newDir == clammy.fileDir) then
		return clammy;
	end
	clammy.fileDir = newDir;
	clammy.filePath = clammy.fileDir .. clammy.fileName;
	clammy.filePathBroken = clammy.fileDir .. clammy.fileNameBroken;
	clammy.sessionReportPath = clammy.fileDir .. clammy.sessionReportFileName;
	return clammy;
end

local openLogFile = function(clammy, notBroken)
	func.refreshLogPaths(clammy);
	if (ashita.fs.create_directory(clammy.fileDir) ~= false) then
        local file;
		if notBroken == false then
			local fileExists = io.open(clammy.filePathBroken, 'r');
			if (fileExists == nil) then
				file = io.open(clammy.filePathBroken, 'a');
				-- DateTime (String), Item Name(String), Configured Item Sell price when placed in bucket(Int), Whether or not the item is sold to a vendor(Bool),
				-- Percentage of moon phase (Signed Int), Number of buckets paid for(Int), Number of buckets received including transfer buckets (Int), 
				-- Whether or not HQ clamming legs are equipped (Bool), Current vana'diel day of the week(String), Current vana'diel hour (Int)
				local headers = 'Date, Item, Gil, Vendor, MoonPhase, BucketsPurchased, BucketsReceived, WearingHQGear, VanaDay, VanaHour\n'
				if (file ~= nil) then
					file:write(headers);
					io.close(file);
				end
			else
				io.close(fileExists);
			end
			file = io.open(clammy.filePathBroken, 'a');
		else
			local fileExists = io.open(clammy.filePath, 'r');
			if (fileExists == nil) then
				file = io.open(clammy.filePath, 'a');
				local headers = 'Date, Item, Gil, Vendor, MoonPhase, BucketsPurchased, BucketsReceived, WearingHQGear, VanaDay, VanaHour\n'
				if (file ~= nil) then
					file:write(headers);
					io.close(file);
				end
			else
				io.close(fileExists);
			end
			file = io.open(clammy.filePath, 'a');
		end

		if (file == nil) then
			print("Clammy: Could not open log file.")
		else
			return file;
		end
	end
end

local closeLogFile = function(file)
	if (file ~= nil) then
		io.close(file)
	end
end

local writeLogFile = function(clammy, item)
	local file = openLogFile(clammy, true);

	if (file ~= nil) then
		local fdata = ('%s, %s %s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S'), item.item, item.gil[1]);
		file:write(fdata);
	end

	closeLogFile(file);
end

local updateGilPerHour = function(clammy)
	local now = os.clock();
	local elapsed = now - clammy.startingTime;
	if (elapsed > 0) then
		local minStabilizeSec = (Config.gilPerHourStabilizeMinutes[1] or 10) * 60;
		clammy.gilPerHourStabilizeReady = (elapsed >= minStabilizeSec);
		local scale = 3600 / elapsed;
		clammy.gilPerHourMinusBucket = math.floor(clammy.trueSessionValue * scale);
		clammy.gilPerHour = math.floor(clammy.sessionValue * scale);
		clammy.gilPerHourNPC = math.floor(clammy.trueSessionValueNPC * scale);
		clammy.gilPerHourAH = math.floor(clammy.trueSessionValueAH * scale);
	else
		clammy.gilPerHourStabilizeReady = false;
		clammy.gilPerHourMinusBucket = 0;
		clammy.gilPerHour = 0;
		clammy.gilPerHourNPC = 0;
		clammy.gilPerHourAH = 0;
	end
	return clammy;
end

local calcRarityDifference = function()
	local rarityHQ = T{
		threeWeightPercent = 0,
		sixWeightPercent = 0,
		sevenWeightPercent = 0,
		elevenWeightPercent = 0,
		twentyWeightPercent = 0,
	};
	local rarityNoHQ = T{
		threeWeightPercent = 0,
		sixWeightPercent = 0,
		sevenWeightPercent = 0,
		elevenWeightPercent = 0,
		twentyWeightPercent = 0,
	};

	local tableToUse = Config.items;
	for _, item in ipairs(tableToUse) do
		if (item.weight == 20) then
			rarityHQ.twentyWeightPercent = rarityHQ.twentyWeightPercent + item.rarity[1];
		elseif (item.weight == 11) then
			rarityHQ.elevenWeightPercent = rarityHQ.elevenWeightPercent + item.rarity[1];
		elseif (item.weight == 7) then
			rarityHQ.sevenWeightPercent = rarityHQ.sevenWeightPercent + item.rarity[1];
		elseif (item.weight == 6) then
			rarityHQ.sixWeightPercent = rarityHQ.sixWeightPercent + item.rarity[1];
		elseif (item.weight == 3) then
			rarityHQ.threeWeightPercent = rarityHQ.threeWeightPercent + item.rarity[1];
		end
	end

	tableToUse = const.clammingRarityNoHQGear;
	for _, item in ipairs(tableToUse) do
		if (item.weight == 20) then
			rarityNoHQ.twentyWeightPercent = rarityNoHQ.twentyWeightPercent + item.rarity[1];
		elseif (item.weight == 11) then
			rarityNoHQ.elevenWeightPercent = rarityNoHQ.elevenWeightPercent + item.rarity[1];
		elseif (item.weight == 7) then
			rarityNoHQ.sevenWeightPercent = rarityNoHQ.sevenWeightPercent + item.rarity[1];
		elseif (item.weight == 6) then
			rarityNoHQ.sixWeightPercent = rarityNoHQ.sixWeightPercent + item.rarity[1];
		elseif (item.weight == 3) then
			rarityNoHQ.threeWeightPercent = rarityNoHQ.threeWeightPercent + item.rarity[1];
		end
	end

	local rarityDifference = T{
		threeWeightPercent = rarityNoHQ.threeWeightPercent - rarityHQ.threeWeightPercent,
		sixWeightPercent = rarityNoHQ.sixWeightPercent - rarityHQ.sixWeightPercent,
		sevenWeightPercent = rarityNoHQ.sevenWeightPercent - rarityHQ.sevenWeightPercent,
		elevenWeightPercent = rarityNoHQ.elevenWeightPercent - rarityHQ.elevenWeightPercent,
		twentyWeightPercent = rarityNoHQ.twentyWeightPercent - rarityHQ.twentyWeightPercent,
	};
	return rarityDifference;
end

local calculateTimePerBucket = function(clammy)
	local now = os.clock();
	local thisBucketTime = now - clammy.bucketStartTime;
	clammy.bucketTimeWith = clammy.bucketTimeWith + thisBucketTime;
	if clammy.bucketAverageTime == 0 then
		clammy.bucketAverageTime = thisBucketTime;
	else
		clammy.bucketAverageTime = (clammy.bucketTimeWith / clammy.bucketsReceived);
	end
	return clammy
end

local calcRedBucket = function(clammy)
	local rarityModifiers = 1;
	if (clammy.hasHQLegs == false) then
		rarityModifiers = calcRarityDifference();
	end
	if  (clammy.relativeWeight < 6) or
		(clammy.money >= Config.lowValue[1] and clammy.relativeWeight < 7) or
		(clammy.money >= Config.midValue[1] and clammy.relativeWeight < 11) or
		(clammy.money >= Config.highValue[1] and clammy.relativeWeight < 20) or
		(clammy.weight > 130) then
		if (Config.alwaysStopAtThirdBucket[1] == true) then
			clammy.bucketColor = {1.0, 0.1, 0.0, 1.0};
			clammy.bucketShouldBeTurnedIn = true;
			if (Config.useStopTone[1] == true) then
				clammy.stopSound = true;
			end
		elseif (Config.alwaysStopAtThirdBucket[1] == false) then
			local clammingIncidentModifier = 0.9;
			if (clammy.hasHQBody == true) then
				clammingIncidentModifier = 0.95;
			end
			local modifiedLowValue = math.floor(Config.lowValue[1] * clammingIncidentModifier);
			local modifiedMidValue = math.floor(Config.midValue[1] * clammingIncidentModifier);
			local modifiedHighValue = math.floor(Config.highValue[1] * clammingIncidentModifier);
			if (clammy.relativeWeight < 6) or
				(clammy.money >= modifiedLowValue and clammy.relativeWeight < 7) or
				(clammy.money >= modifiedMidValue and clammy.relativeWeight < 11) or
				(clammy.money >= modifiedHighValue and clammy.relativeWeight < 20) or
				(clammy.money >=  Config.highValue[1] and clammy.bucketSize == 200) then
				clammy.bucketColor = {1.0, 0.1, 0.0, 1.0};
				clammy.bucketShouldBeTurnedIn = true;
				if (Config.useStopTone[1] == true) then
					clammy.stopSound = true;
				end
			else
				clammy.bucketColor = {1.0, 1.0, 1.0, 1.0};
				clammy.bucketShouldBeTurnedIn = false;
			end
		end
	else
		clammy.bucketColor = {1.0, 1.0, 1.0, 1.0};
		clammy.bucketShouldBeTurnedIn = false;
	end
	return clammy;
end

local writeBucket = function(clammy, item)
	local fdata = {
		datetime = os.date('%Y-%m-%d %H:%M:%S'),
		item = item.item,
		gil = item.gil[1],
		vendor = item.vendor[1],
		moonPercent = clammy.moonTable.moonPercent,
		bucketsPurchased = clammy.bucketsPurchased,
		bucketsReceived = clammy.bucketsReceived,
		hasHQLegs = clammy.hasHQLegs,
		dayOfWeek = clammy.vanaTime.dayName,
		currentHour = clammy.vanaTime.hourInt,
	}
	table.insert(clammy.trackingBucket, fdata);
	return clammy;
end

local playSound = function(clammy)
	local waveFile = 'clam.wav';
	if (clammy.stopSound == true) then
		waveFile = 'stop.wav';
		clammy.stopSound = false;
	end
	if (Config.tone[1] == true) and (clammy.playTone == true) then
		ashita.misc.play_sound(addon.path:append(waveFile));
		clammy.playTone = false;
	end
    return clammy;
end

local getClammingBucket = function(clammy)
	clammy.bucketsPurchased = clammy.bucketsPurchased + 1;
	clammy.bucketsReceived = clammy.bucketsReceived + 1;
	clammy.percentRemaining = 1;
	clammy.hasBucket = true;
	clammy.bucketIsBroke = false;
	clammy.bucketStartTime = os.clock();
	if (clammy.sessionStarted ~= true) then
		clammy.startingTime = os.clock();
		clammy.sessionStarted = true;
	end
    return clammy;
end

local sessionTimeout = function(clammy)
	clammy = func.refreshLogPaths(clammy);
	if (Config.resetFullSession[1] == true) and (Config.sessionLog[1] == true) then
		clammy = func.writeSessionReport(clammy, 'auto_reset');
	end
	if(Config.resetFullSession[1] == true) then
		local hasBucketKI = AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(511);
		if hasBucketKI == true then
			clammy.bucketsPurchased = 1;
			clammy.bucketsReceived = 1;
		else
			clammy.bucketsPurchased = 0;
			clammy.bucketsReceived = 0;
		end
		clammy.sessionValue = 0;
		clammy.sessionValueAH = 0;
		clammy.sessionValueNPC = 0;
		clammy.trueSessionValue = 0;
		clammy.trueSessionValueNPC = 0;
		clammy.trueSessionValueAH = 0;
		clammy.sessionReportFileName = ('session_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
		clammy.sessionReportPath = clammy.fileDir .. clammy.sessionReportFileName;
		clammy.sessionReportStartWall = os.date('%Y-%m-%d %H:%M:%S');
		clammy.sessionReportLogStarted = false;
		clammy.sessionDropTotals = T{};
		clammy.sessionBreakLossGil = 0;
		clammy.sessionBreakLossByItem = T{};
	end
	-- NOTE: startingTime and sessionStarted are intentionally NOT reset here.
	-- The session clock starts on the first bucket grab and runs until logout/manual reset.
	clammy.lastClammingAction = os.clock();
	clammy.fileName = ('log_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.fileNameBroken = ('log_broken_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.filePath = clammy.fileDir .. clammy.fileName;
	clammy.filePathBroken = clammy.fileDir .. clammy.fileNameBroken;
	clammy.gilPerHour = 0;
	clammy.gilPerHourMinusBucket = 0;
	clammy.clammingAttemptsPerHour = 0;
	clammy.clammingAttempts = 0;
	clammy.gilPerHourAH = 0;
	clammy.gilPerHourNPC = 0;
	clammy.bucketAverageTime = 0;
	clammy.bucketTimeWith = 0;
	clammy.sessionWasReset = false;
	return clammy;
end

local updateLastClammingAction = function(clammy)
	clammy.lastClammingAction = os.clock();
	if (clammy.sessionWasReset == true) then
		clammy = sessionTimeout(clammy);
	end
	return clammy;
end

local handleBucket = function(clammy)
	local hasBucketKI = AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(511);
	if (hasBucketKI == true) then
		if (clammy.hasBucket == false) and (clammy.bucketIsBroke == false) then
			return getClammingBucket(clammy);
		end
		if (clammy.hasBucket == true) and (clammy.bucketIsBroke == true) then
			clammy = func.emptyBucket(clammy, false, false);
			clammy = calculateTimePerBucket(clammy);
			clammy.playTone = true;
			clammy.stopSound = true;
			return clammy;
		end
		return clammy;
	else
		if (clammy.hasBucket == true) and (clammy.bucketIsBroke == false) then
			clammy = func.emptyBucket(clammy, true, false);
			clammy = calculateTimePerBucket(clammy);
			clammy = updateLastClammingAction(clammy);
			return clammy;
		end
		if (clammy.hasBucket == false) and (clammy.bucketIsBroke == true) then
			clammy.bucketIsBroke = false;
			clammy = calcRedBucket(clammy);
			return clammy;
		end
		return clammy;
	end
end

local calculateChanceOfBreak = function(clammy, remainingWeight)
	local sixWeightPercent = 0;
	local sevenWeightPercent = 0;
	local elevenWeightPercent = 0;
	local twentyWeightPercent = 0;
	local tableToUse = Config.items;
	if (clammy.hasHQLegs == false) then
		tableToUse = const.clammingRarityNoHQGear;
	end
	for _, item in ipairs(tableToUse) do
		if (item.weight == 20) then
			twentyWeightPercent = twentyWeightPercent + item.rarity[1];
		elseif (item.weight == 11) then
			elevenWeightPercent = elevenWeightPercent + item.rarity[1];
		elseif (item.weight == 7) then
			sevenWeightPercent = sevenWeightPercent + item.rarity[1];
		elseif (item.weight == 6) then
			sixWeightPercent = sixWeightPercent + item.rarity[1];
		end
	end
	local returnData = T{ };
	if remainingWeight < 3 then
	returnData = T {
			color = {1.0, 0.0, 0.0, 1.0},
			percentWeight = 100,
		}
	elseif remainingWeight < 6 then
		returnData = T {
			color = {1.0, 0.05, 0.0, 1.0},
			percentWeight = (twentyWeightPercent + elevenWeightPercent + sevenWeightPercent + sixWeightPercent),
		};
	elseif remainingWeight < 7 then
		returnData = T {
			color = {1.0, 0.32, 0.0, 1.0},
			percentWeight = (twentyWeightPercent + elevenWeightPercent + sevenWeightPercent),
		};
	elseif remainingWeight < 11 then
		returnData = T {
			color = {1.0, 0.98, 0.0, 1.0},
			percentWeight = (twentyWeightPercent + elevenWeightPercent),
		};
	elseif remainingWeight < 20 then
		returnData = T {
			color = {0.0, 1.0, 0.098, 1.0},
			percentWeight = twentyWeightPercent,
		};
	else
		returnData = T {
			color = {1.0, 1.0, 1.0, 1.0},
			percentWeight = 0,
		};
	end
	if (clammy.bucketSize == 200) then
		local clammingIncidentModifier = 0.9;
		if (clammy.hasHQBody == true) then
			clammingIncidentModifier = 0.95;
		end
		if (returnData.percentWeight == 100) then
			returnData.percentWeight = 100;
		else
			returnData.percentWeight = 1 - ((1 - returnData.percentWeight) * clammingIncidentModifier);
		end
	end
	return returnData;
end

local formatChanceBreak = function(percentWeight)
	if (percentWeight == 0) or (percentWeight == 100) then
		percentWeight = ("%0.0f"):fmt(percentWeight);
	else
		percentWeight = ("%.2f"):fmt(percentWeight * 100);
	end
	return percentWeight;
end

local renderGeneralConfig = function(settingsTabHeight)
    imgui.Text('General Settings');
    imgui.BeginChild('settings_general', { 0, settingsTabHeight, }, true);
		imgui.SliderFloat('Window Scale', Config.windowScaling, 0.1, 2.0, '%.2f');
		imgui.ShowHelp('Scale the window bigger/smaller.');
        imgui.Checkbox('Items in Bucket', Config.showItems);
        imgui.ShowHelp('Toggles whether items in current bucket should be shown.');
        imgui.Checkbox('Show Session Info', Config.showSessionInfo);
        imgui.ShowHelp('Toggles whether total clamming value, gil earned per hour, and buckets purchased should be shown.');
		imgui.Checkbox('Split gil/hr and total session value by Vendor/AH', Config.splitItemsBySellType);
		imgui.ShowHelp('Toggles whether session info should show split between items sold to vendor and items sold to AH.');
		imgui.Checkbox('Apply AH JSON (data/ah_prices.json + optional overrides)', Config.useAhPricingFromFile);
		imgui.ShowHelp('Pricing from config/ClammyHorizon/data/ah_prices.json. /clammyh reloadah = fetch + apply (Chrome extension auto-captures token); reloadah token = saved file only; reloadah local = disk only, no network. HORIZON_SESSION_TOKEN.md.');
		imgui.SetNextItemWidth(100);
		imgui.InputInt('Min minutes for est. gil/hr', Config.gilPerHourStabilizeMinutes);
		imgui.ShowHelp('Est. gil/hr and dig "dpm" stay as -- until the session is at least this long. Set 0 to always show rates (early totals can be extreme).');
        imgui.Checkbox('Show Moon Info', Config.trackMoonPhase);
        imgui.ShowHelp('Toggles if moon phase should be shown in window.');
		imgui.Checkbox('Show day of week', Config.showDayOfWeek);
		imgui.ShowHelp('Show the day of the week in Vana\'diel time.');
        imgui.Checkbox('Set Weight Color Based On Value', Config.colorWeightBasedOnValue);
        imgui.ShowHelp('Toggles if the weight in the window should be based on value of the bucket.');
		imgui.Checkbox('Show Profit', Config.subtractBucketCostFromGilEarned);
		imgui.ShowHelp('Subtract cost of buckets from total clamming value amount.');
		imgui.Checkbox('Show Time per Bucket', Config.showAverageTimePerBucket);
		imgui.ShowHelp('Calculate and show average time per bucket received.');
		imgui.Checkbox('Show # of clamming tries', Config.showClammingAttempts);
		imgui.ShowHelp('Show how many times you\'ve dug and digs per minute.');
		imgui.Checkbox('Show % chance bucket break', Config.showPercentChanceToBreak);
		imgui.ShowHelp('Calculates the chance that the next clamming attempt will break your bucket.');
		imgui.Checkbox('Show Bucket Health', Config.showClammyHealth);
		imgui.ShowHelp('Show bar representing how much weight remains before your bucket breaks');
		imgui.Checkbox('Show equipment status', Config.checkEquippedItem);
		imgui.ShowHelp('Shows whether you are wearing the HQ clamming set.');
		imgui.Checkbox('No clammy outside the bay', Config.hideInDifferentZone);
        imgui.ShowHelp('What happens in Bibiki Bay stays in Bibiki Bay?');
		imgui.Checkbox('Always Stop After 3rd Bucket', Config.alwaysStopAtThirdBucket);
		imgui.ShowHelp('Always turns the bucket color red at 131 or more weight.');
		imgui.Checkbox('Log Results', Config.log);
        imgui.ShowHelp('Toggles if Clammy should create a log file.');
		if (Config.log[1] == true) then
			imgui.SetCursorPosX(20); imgui.Checkbox('Legacy logging', Config.legacyLog);
        	imgui.ShowHelp('Use if you want to maintain consistent logging with 0.4 version or earlier.');
		end
		imgui.Checkbox('Session summary log', Config.sessionLog);
		imgui.ShowHelp('session_*.txt: appends a snapshot after each turn-in, break, unload, reset, etc. Earlier snapshots stay in the file; a new file starts each new session (load/reset).');
        imgui.Checkbox('Play Tone', Config.tone);
        imgui.ShowHelp('Toggles if Clammy should play a tone when you can clam again.');
		if (Config.tone[1] == true) then
			imgui.SetCursorPosX(20); imgui.Checkbox('Stop Tone', Config.useStopTone);
			imgui.ShowHelp('Play separate tone when at recommended turn in weight.')
		end
		imgui.Checkbox('Auto Reset Log', Config.autoResetLog);
		imgui.ShowHelp('Automatically resets log file after no clamming actions are taken for some time.');
		if (Config.autoResetLog[1] == true) then
			imgui.SetCursorPosX(20); imgui.Checkbox('Reset Session', Config.resetFullSession);
			imgui.ShowHelp('Reset just log file or full session.');
			imgui.SetCursorPosX(20); imgui.SetNextItemWidth(100); imgui.InputInt('Minutes Before Reset', Config.minutesBeforeAutoReset);
			imgui.ShowHelp('Time in minutes before automatically resetting log file.');
		end
		imgui.SetNextItemWidth(100);
		imgui.InputInt('High value amount', Config.highValue);
		imgui.ShowHelp('Indicates when bucket weight turns red at less than 20 ponze of space remaining.');
		imgui.SetNextItemWidth(100);
		imgui.InputInt('Medium value amount', Config.midValue);
		imgui.ShowHelp('Indicates when bucket weight turns red at less than 11 ponze of space remaining.');
		imgui.SetNextItemWidth(100);
		imgui.InputInt('Low value amount', Config.lowValue);
		imgui.ShowHelp('Indicates when bucket weight turns red at less than 7 ponze of space remaining.');
    imgui.EndChild();
end

local renderItemListConfig = function(settingsTabHeight)
    imgui.BeginChild("settings_items", {0, settingsTabHeight, }, true);
		imgui.Text('    Item Value:');
		imgui.ShowHelp('Set sale price of item.');
		imgui.SameLine();
		imgui.Text('                Vendor:')
		imgui.ShowHelp('Check whether to sell to a vendor or the AH.');
		imgui.Separator();
		imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[1].item .. '      ', Config.items[1].gil); -- Bibiki slug      -- 17
		imgui.SameLine();
		imgui.Checkbox(Config.items[1].item, Config.items[1].vendor);
		imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[2].item .. '    ', Config.items[2].gil); -- Bibiki urchin
		imgui.SameLine();
		imgui.Checkbox(Config.items[2].item, Config.items[2].vendor);
		imgui.SetNextItemWidth(100);
        imgui.InputInt('Bkn. willow rod  ', Config.items[3].gil); -- Broken willow fishing rod
		imgui.SameLine();
		imgui.Checkbox('Bkn. willow rod', Config.items[3].vendor, 'Bkn. willow rod');
		imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[4].item .. '   ', Config.items[4].gil); -- Coral fragment
		imgui.SameLine();
		imgui.Checkbox(Config.items[4].item, Config.items[4].vendor, Config.items[4].item);
		imgui.SetNextItemWidth(100);
        imgui.InputInt('H.Q. crab shell  ', Config.items[5].gil); -- Quality crab shell
        imgui.SameLine();
		imgui.Checkbox(Config.items[5].item, Config.items[5].vendor, 'H.Q. crab shell');
		imgui.SetNextItemWidth(100);
		imgui.InputInt(Config.items[6].item .. '       ', Config.items[6].gil); -- Crab shell
		imgui.SameLine();
		imgui.Checkbox(Config.items[6].item, Config.items[6].vendor, Config.items[6].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[7].item .. '          ', Config.items[7].gil); -- Elm log
		imgui.SameLine();
		imgui.Checkbox(Config.items[7].item, Config.items[7].vendor, Config.items[7].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[8].item .. '      ', Config.items[8].gil); -- Fish scales
		imgui.SameLine();
		imgui.Checkbox(Config.items[8].item, Config.items[8].vendor, Config.items[8].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[9].item .. '     ', Config.items[9].gil); -- Goblin armor
		imgui.SameLine();
		imgui.Checkbox(Config.items[9].item, Config.items[9].vendor, Config.items[9].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[10].item .. '      ', Config.items[10].gil); -- Goblin mail
		imgui.SameLine();
		imgui.Checkbox(Config.items[10].item, Config.items[10].vendor, Config.items[10].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[11].item .. '      ', Config.items[11].gil); -- Goblin mask
		imgui.SameLine();
		imgui.Checkbox(Config.items[11].item, Config.items[11].vendor, Config.items[11].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[12].item .. '  ', Config.items[12].gil); -- Hobgoblin bread
		imgui.SameLine();
		imgui.Checkbox(Config.items[12].item, Config.items[12].vendor, Config.items[12].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[13].item .. '    ', Config.items[13].gil); -- Hobgoblin pie
		imgui.SameLine();
		imgui.Checkbox(Config.items[13].item, Config.items[13].vendor, Config.items[13].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[14].item .. '         ', Config.items[14].gil); -- Jacknife
		imgui.SameLine();
		imgui.Checkbox(Config.items[14].item, Config.items[14].vendor, Config.items[14].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[15].item .. ' ', Config.items[15].gil); -- Lacquer tree log
		imgui.SameLine();
		imgui.Checkbox(Config.items[15].item, Config.items[15].vendor, Config.items[15].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[16].item .. '        ', Config.items[16].gil); -- Maple log
		imgui.SameLine();
		imgui.Checkbox(Config.items[16].item, Config.items[16].vendor, Config.items[16].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[17].item .. '       ', Config.items[17].gil); -- Nebimonite
		imgui.SameLine();
		imgui.Checkbox(Config.items[17].item, Config.items[17].vendor, Config.items[17].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[18].item .. '          ', Config.items[18].gil); -- Oxblood
		imgui.SameLine();
		imgui.Checkbox(Config.items[18].item, Config.items[18].vendor, Config.items[18].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[19].item .. '      ', Config.items[19].gil); -- Pamtam kelp
		imgui.SameLine();
		imgui.Checkbox(Config.items[19].item, Config.items[19].vendor, Config.items[19].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[20].item .. '           ', Config.items[20].gil); -- Pebble
		imgui.SameLine();
		imgui.Checkbox(Config.items[20].item, Config.items[20].vendor, Config.items[20].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[21].item .. '    ', Config.items[21].gil); -- Petrified log
		imgui.SameLine();
		imgui.Checkbox(Config.items[21].item, Config.items[21].vendor, Config.items[21].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt('H.Q. pugil Scls. ', Config.items[22].gil); -- Quality pugil scales
		imgui.SameLine();
		imgui.Checkbox('H.Q. pugil Scls.', Config.items[22].vendor, Config.items[22].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[23].item .. '     ', Config.items[23].gil); -- Pugil scales
		imgui.SameLine();
		imgui.Checkbox(Config.items[23].item, Config.items[23].vendor, Config.items[23].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[24].item .. '        ', Config.items[24].gil); -- Rock salt
		imgui.SameLine();
		imgui.Checkbox(Config.items[24].item, Config.items[24].vendor, Config.items[24].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[25].item .. '         ', Config.items[25].gil); -- Seashell
		imgui.SameLine();
		imgui.Checkbox(Config.items[25].item, Config.items[25].vendor, Config.items[25].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[26].item .. '      ', Config.items[26].gil); -- Shall shell
		imgui.SameLine();
		imgui.Checkbox(Config.items[26].item, Config.items[26].vendor, Config.items[26].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[27].item .. ' ', Config.items[27].gil); -- Titanictus shell
		imgui.SameLine();
		imgui.Checkbox(Config.items[27].item, Config.items[27].vendor, Config.items[27].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[28].item .. '    ', Config.items[28].gil); -- Tropical clam
		imgui.SameLine();
		imgui.Checkbox(Config.items[28].item, Config.items[28].vendor, Config.items[28].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[29].item .. '     ', Config.items[29].gil); -- Turtle shell
		imgui.SameLine();
		imgui.Checkbox(Config.items[29].item, Config.items[29].vendor, Config.items[29].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[30].item .. '   ', Config.items[30].gil); -- Uragnite shell
		imgui.SameLine();
		imgui.Checkbox(Config.items[30].item, Config.items[30].vendor, Config.items[30].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[31].item .. '     ', Config.items[31].gil); -- Vongola clam
		imgui.SameLine();
		imgui.Checkbox(Config.items[31].item, Config.items[31].vendor, Config.items[31].item);
        imgui.SetNextItemWidth(100);
        imgui.InputInt(Config.items[32].item .. '       ', Config.items[32].gil); -- White sand
		imgui.SameLine();
		imgui.Checkbox(Config.items[32].item, Config.items[32].vendor, Config.items[32].item);
    imgui.EndChild();
end

local resetSession = function(clammy)
	clammy = func.refreshLogPaths(clammy);
	if (Config.sessionLog[1] == true) then
		clammy = func.writeSessionReport(clammy, 'reset_session');
	end
	local hasBucketKI = AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(511);

	clammy.startingTime = os.clock();
	clammy = updateLastClammingAction(clammy);
	clammy.bucketStartTime = 0;
	clammy.fileName = ('log_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.fileNameBroken = ('log_broken_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.filePath = clammy.fileDir .. clammy.fileName;
	clammy.filePathBroken = clammy.fileDir .. clammy.fileNameBroken;
	clammy.sessionReportFileName = ('session_%s.txt'):fmt(os.date('%Y_%m_%d__%H_%M_%S'));
	clammy.sessionReportPath = clammy.fileDir .. clammy.sessionReportFileName;
	clammy.sessionReportStartWall = os.date('%Y-%m-%d %H:%M:%S');
	clammy.sessionReportLogStarted = false;
	clammy.sessionDropTotals = T{};
	clammy.sessionBreakLossGil = 0;
	clammy.sessionBreakLossByItem = T{};
	clammy.lastSessionMetricsRefresh = nil;
	clammy = func.emptyBucket(clammy, false, true);
	clammy.gilPerHour = 0;
	clammy.gilPerHourMinusBucket = 0;
	clammy.gilPerHourAH = 0;
	clammy.gilPerHourNPC = 0;
	clammy.clammingAttemptsPerHour = 0;
	clammy.clammingAttempts = 0;
	if hasBucketKI == true then
		clammy.bucketsPurchased = 1;
		clammy.bucketsReceived = 1;
	else
		clammy.bucketsPurchased = 0;
		clammy.bucketsReceived = 0;
	end
	clammy.sessionValue = 0;
	clammy.sessionValueAH = 0;
	clammy.sessionValueNPC = 0;
	clammy.bucketIsBroke = false;
	clammy.sessionWasReset = false;
	clammy.sessionStarted = false;
	return clammy;
end

local getCurrentEquip = function(clammy)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local bodyEquip = inv:GetEquippedItem(5);
	if (bodyEquip == nil) then
		return clammy;
	end
    local bodyIndex = bit.band(bodyEquip.Index, 0x00FF);
    local bodyContainer = bit.band(bodyEquip.Index, 0xFF00) / 256;
    local bodyItem = inv:GetContainerItem(bodyContainer, bodyIndex);
	local bodyItemId = bodyItem.Id;

	clammy.hasHQBody = false;
	clammy.bodyItemId = bodyItemId;

	local legEquip = inv:GetEquippedItem(7);
	local legIndex = bit.band(legEquip.Index, 0x00FF);
	local legContainer = bit.band(legEquip.Index, 0xFF00) / 256;
	local legItem = inv:GetContainerItem(legContainer, legIndex);
	local legItemId = legItem.Id;

	clammy.hasHQLegs = false;
	clammy.legItemId = legItemId;

	for _, item in ipairs(const.hqGearIndexes) do
		if item.id == bodyItemId then
			clammy.hasHQBody = true;
		end
		if item.id == legItemId then
			clammy.hasHQLegs = true;
		end
	end
	return clammy;
end

local formatInt = function(number)
	if (type(number) == 'string') then
		number = tonumber(number);
	end
	if (number == nil) then
		return '0';
	end
	-- must always return a string (e.g. for imgui.Text); small values used to return raw numbers
	if (type(number) == 'number' and math.abs(number) < 1000) then
		return tostring(math.floor(number + 0.5));
	end
    if (number ~= nil and number ~= '' and type(number) == 'number') then
        local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)');

        if (int == nil) then
            return tostring(number);
        end

        -- reverse the int-string and append a comma to all blocks of 3 digits
        int = int:reverse():gsub("(%d%d%d)", "%1,");
  
        -- reverse the int-string back remove an optional comma and put the 
        -- optional minus and fractional part back
        return minus .. int:reverse():gsub("^,", "") .. fraction;
    else
        return 'NaN';
    end
end

-- byte-length cap (FFXI item names are typically ASCII); overflow shows "..."
local truncateItemDisplayName = function(name, maxLen)
	if (name == nil) or (name == "") then
		return "";
	end
	maxLen = maxLen or 18;
	if (#name <= maxLen) then
		return name;
	end
	if (maxLen <= 3) then
		return name:sub(1, maxLen);
	end
	return name:sub(1, maxLen - 3) .. "...";
end

local getTimestamp = function()
    local pVanaTime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0);
    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34);
    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960;
    local timestamp = {};
	timestamp.day = math.floor(rawTime / 3456);
    timestamp.hour = math.floor(rawTime / 144) % 24;
    timestamp.minute = math.floor((rawTime % 144) / 2.4);
	timestamp.dayOfWeekInt = (math.floor(rawTime / 3456) % 8);
    return timestamp;
end

local getMoon = function(clammy)
    local timestamp = getTimestamp();
    local moonIndex = ((timestamp.day + 26) % 84) + 1;
    if (moonIndex < 43) then
		clammy.moonTable.moonPercent = const.moonPhasePercent[moonIndex]  * -1;
	else
		clammy.moonTable.moonPercent = const.moonPhasePercent[moonIndex];
	end
    clammy.moonTable.moonPhase = const.moonPhase[moonIndex];
    return clammy;
end

local getVanaTime = function(clammy)
	local timestamp = getTimestamp();
	local daysOfWeekColorTable = T{
		Firesday = {colorConverter(255), colorConverter(40), colorConverter(40), 1},
		Earthsday = {colorConverter(200), colorConverter(200), colorConverter(0), 1},
		Watersday = {colorConverter(0), colorConverter(109), colorConverter(160), 1},
		Windsday = {colorConverter(48), colorConverter(200), colorConverter(48), 1},
		Iceday = {colorConverter(150), colorConverter(150), colorConverter(240), 1},
		Lightningday = {colorConverter(255), colorConverter(181), colorConverter(255), 1},
		Lightsday = {colorConverter(227), colorConverter(227), colorConverter(227), 1},
		Darksday = {colorConverter(15), colorConverter(15), colorConverter(16), 1},
	}
	for _, day in ipairs(const.daysOfWeek) do
		if timestamp.dayOfWeekInt == day.dayInt then
			clammy.vanaTime.dayName = day.Name;
			clammy.vanaTime.dayOfWeekColor = daysOfWeekColorTable[day.Name];
		end
	end
	if clammy.vanaTime.dayOfWeekColor == nil then
		clammy.vanaTime.dayName = 'Unknown day!?';
		clammy.vanaTime.dayOfWeekColor = {colorConverter(255), colorConverter(255), colorConverter(255), 1};
	end
	clammy.vanaTime.hourInt = timestamp.hour;
	return clammy;
end

local formatTimestamp = function(timer)
    local hours = math.floor(timer / 3600);
    local minutes = math.floor((timer / 60) - (hours * 60));
    local seconds = math.floor(timer - (hours * 3600) - (minutes * 60));

    return ('%0.2i:%0.2i:%0.2i'):fmt(hours, minutes, seconds);
end

local writeSessionReportPreamble = function(file, clammy, path)
	file:write("================================================================================\n");
	file:write("Clammy session log  (v" .. tostring(addon.version) .. ")\n");
	file:write("================================================================================\n");
	file:write("File:    " .. tostring(clammy.sessionReportFileName) .. "\n");
	file:write("Path:    " .. tostring(path) .. "\n");
	file:write("Session start (wall): " .. tostring(clammy.sessionReportStartWall) .. "\n");
	file:write("\n");
	file:write("Snapshots below are APPENDED as you play. Older entries are not deleted.\n");
	file:write("================================================================================\n\n");
end

local writeSessionSnapshotBody = function(file, clammy, sessionSeconds, nowWall, reason, gilSpent, estNet)
	file:write("--------------------------------------------------------------------------------\n");
	file:write("Snapshot: " .. nowWall .. "  |  " .. tostring(reason) .. "\n");
	file:write("  (Cumulative session totals at this moment.)\n");
	file:write("--------------------------------------------------------------------------------\n");
	file:write("\n");
	file:write("Time\n");
	file:write("----\n");
	file:write("Session length: " .. formatTimestamp(sessionSeconds) .. "\n");
	file:write("\n");
	file:write("Buckets & gil\n");
	file:write("-------------\n");
	file:write("Buckets received (all buckets this session, incl. size upgrades / transfers): " .. tostring(clammy.bucketsReceived) .. "\n");
	file:write("Buckets purchased (counter used for 500g cost): " .. tostring(clammy.bucketsPurchased) .. "\n");
	file:write("Gil spent on buckets (purchased x " .. tostring(BUCKET_COST_GIL) .. "): " .. tostring(gilSpent) .. "\n");
	file:write("Note: Talking to the NPC when within 5 ponze of your capacity can grant a free bucket; " ..
		"this addon does not detect free buckets, so gil spent may be overstated.\n");
	file:write("\n");
	file:write("Drops (cashed in only - items from broken buckets are not listed here)\n");
	file:write("-----------------------------------------------------------------------\n");
	local names = {};
	for itemName, _ in pairs(clammy.sessionDropTotals) do
		names[#names + 1] = itemName;
	end
	table.sort(names);
	if (#names == 0) then
		file:write("(none)\n");
	else
		for _, itemName in ipairs(names) do
			local n = clammy.sessionDropTotals[itemName];
			local def = findItemDefByName(itemName);
			local w = (def and def.weight) or 0;
			local eachGil = (def and def.gil and def.gil[1]) or 0;
			local totalGil = n * eachGil;
			local totalWt = n * w;
			local vlabel = (def and def.vendor and def.vendor[1]) and "V" or "AH";
			file:write('  - ' .. itemName .. '  x' .. tostring(n) .. '  ' .. tostring(totalWt) .. 'p  ' ..
				formatInt(totalGil) .. ' g  @ ' .. tostring(eachGil) .. '  [' .. vlabel .. ']\n');
		end
	end
	file:write("\n");
	file:write("Economy (from your Clammy item values)\n");
	file:write("--------------------------------------\n");
	file:write("Estimated gil (cashed-in items, raw):  " .. formatInt(clammy.sessionValue) .. "\n");
	if (Config.splitItemsBySellType[1] == true) then
		file:write("  NPC (vendor) subtotal:              " .. formatInt(clammy.sessionValueNPC) .. "\n");
		file:write("  AH (auction) subtotal:              " .. formatInt(clammy.sessionValueAH) .. "\n");
	end
	if (Config.subtractBucketCostFromGilEarned[1] == true) then
		file:write("Net after bucket cost (value - " .. tostring(gilSpent) .. " g): " .. formatInt(estNet) .. "\n");
	else
		file:write("Net (bucket cost not subtracted in this summary; subtract " .. tostring(gilSpent) ..
			" g manually for loaded buckets): " .. formatInt(clammy.sessionValue) .. "\n");
	end
	file:write("Estimated value lost to broken buckets (total): " .. formatInt(clammy.sessionBreakLossGil) .. "\n");
	local brkNames = {};
	for itemName, _ in pairs(clammy.sessionBreakLossByItem) do
		brkNames[#brkNames + 1] = itemName;
	end
	table.sort(brkNames);
	if (#brkNames == 0) then
		file:write("  (no itemized breaks this session)\n");
	else
		file:write("Lost to sea by item (est.):\n");
		for _, itemName in ipairs(brkNames) do
			local agg = clammy.sessionBreakLossByItem[itemName];
			if (agg ~= nil) then
				file:write("  - " .. itemName .. "  x" .. tostring(agg.c) .. "  " .. formatInt(agg.g) .. " g\n");
			end
		end
	end
	file:write("Clamming attempts (digs): " .. tostring(clammy.clammingAttempts) .. "\n");
	file:write("\n");
end

func.writeSessionReport = function(clammy, reason)
	if (Config.sessionLog[1] ~= true) then
		return clammy;
	end
	func.refreshLogPaths(clammy);
	if (ashita.fs.create_directory(clammy.fileDir) == false) then
		print("Clammy: Could not create log directory for session report.");
		return clammy;
	end
	local path = clammy.fileDir .. clammy.sessionReportFileName;
	local file = io.open(path, 'a');
	if (file == nil) then
		print("Clammy: Could not write session report: " .. tostring(path));
		return clammy;
	end
	if (clammy.sessionReportLogStarted ~= true) then
		writeSessionReportPreamble(file, clammy, path);
		clammy.sessionReportLogStarted = true;
	end
	local now = os.clock();
	local sessionSeconds = now - clammy.startingTime;
	if (sessionSeconds < 0) then
		sessionSeconds = 0;
	end
	local nowWall = os.date('%Y-%m-%d %H:%M:%S');
	local gilSpent = clammy.bucketsPurchased * BUCKET_COST_GIL;
	local estNet = clammy.sessionValue - gilSpent;
	if (Config.subtractBucketCostFromGilEarned[1] ~= true) then
		estNet = clammy.sessionValue;
	end
	writeSessionSnapshotBody(file, clammy, sessionSeconds, nowWall, reason, gilSpent, estNet);
	file:close();
	return clammy;
end

local toggleShowValue = function(shouldShowValue)
	if (shouldShowValue == "true") or (shouldShowValue == nil and Config.showValue[1] == false) then
		Config.showValue[1] = true;
		print(chat.header(addon.name):append(chat.message('Show value turned on.')));
	else
		Config.showValue[1] = false;
		print(chat.header(addon.name):append(chat.message('Show value turned off.')));
	end
	Settings.save();
end

local toggleLogAllResults = function(shouldLogAllResults)
	if (shouldLogAllResults == "true") or
        (shouldLogAllResults == nil and Config.legacyLog[1] == false) then
		Config.legacyLog[1] = true;
		print(chat.header(addon.name):append(chat.message('Logging all items.')));
	elseif(shouldLogAllResults == "false") or
        (shouldLogAllResults == nil and Config.legacyLog[1] == true) then
		Config.legacyLog[1] = false;
		print(chat.header(addon.name):append(chat.message('Logging only items actually received.')));
	end

	Settings.save();
end

local toggleShowSessionInfo = function(shouldShowSessionInfo)
	if (shouldShowSessionInfo == "true") or (shouldShowSessionInfo == nil and Config.showSessionInfo[1] == false) then
		Config.showSessionInfo[1] = true;
		print(chat.header(addon.name):append(chat.message('Showing gil earned and gil per hour.')));
	elseif(shouldShowSessionInfo == "false") or (shouldShowSessionInfo == nil and Config.showSessionInfo[1] == true) then
		Config.showSessionInfo[1] = false;
		print(chat.header(addon.name):append(chat.message('Not showing gil earned and gil per hour.')));
	end

	Settings.save();
end

local toggleUseBucketValueForWeightColor = function(shouldUseBucketValueForWeightColor)
	if (shouldUseBucketValueForWeightColor == 'true') or
        (shouldUseBucketValueForWeightColor == nil and Config.colorWeightBasedOnValue[1] == false) then
		Config.colorWeightBasedOnValue[1] = true;
		print(chat.header(addon.name):append(chat.message('Bucket weight color based on value of items in bucket.')));

	elseif (shouldUseBucketValueForWeightColor == 'false') or
         (shouldUseBucketValueForWeightColor == nil and Config.colorWeightBasedOnValue[1] == true) then
		Config.colorWeightBasedOnValue[1] = false;
		print(chat.header(addon.name):append(chat.message('Bucket weight color based on odds of breaking bucket.')));
	end

	Settings.save();
end

local setWeightValues = function(weightLevel, value)
	if(weightLevel == 'highvalue') then
		Config.highValue[1] = tonumber(value);
		HighValue = tonumber(value);
		print(chat.header(addon.name):append(chat.message(('highvalue setweightvalues set to %s.'):fmt(Config.highValue[1]))));
	elseif (weightLevel == 'midvalue') then
		Config.midValue[1] = tonumber(value);
		MidValue = tonumber(value);
		print(chat.header(addon.name):append(chat.message(('midvalue setweightvalues set to %s.'):fmt(Config.midValue[1]))));
	elseif (weightLevel == 'lowvalue') then
		Config.lowValue[1] = tonumber(value);
		LowValue = tonumber(value);
		print(chat.header(addon.name):append(chat.message(('lowvalue setweightvalues set to %s.'):fmt(Config.lowValue[1]))));
	elseif (weightLevel == 'showvalues') then
		print(chat.header(addon.name):append(chat.message(('Low value is set to %s.'):fmt(Config.lowValue[1]))));
		print(chat.header(addon.name):append(chat.message(('Mid value is set to %s.'):fmt(Config.midValue[1]))));
		print(chat.header(addon.name):append(chat.message(('High value is set to %s.'):fmt(Config.highValue[1]))));
	else
		print(chat.header(addon.name):append(chat.message('Invalid setweightvalues parameter passed.')));
	end

	Settings.save();
end

local toggleShowItems = function(shouldShowItems)
	if (shouldShowItems == "true") or
        (shouldShowItems == nil and Config.showItems[1] == false) then
		Config.showItems[1] = true;
		print(chat.header(addon.name):append(chat.message('Show items turned on.')));
	elseif (shouldShowItems == "false") or
        (shouldShowItems == nil and Config.showItems[1] == true) then
		Config.showItems[1] = false;
		print(chat.header(addon.name):append(chat.message('Show items turned off.')));
	end

	Settings.save();
end

local toggleLogItems = function(shouldLogItems)
	if (shouldLogItems == "true") or (shouldLogItems == nil and Config.log[1] == false) then
		Config.log[1] = true;
		print(chat.header(addon.name):append(chat.message('Logging items turned on.')));
	elseif (shouldLogItems == "false") or (shouldLogItems == nil and Config.log[1] == true) then
		Config.log[1] = false;
		print(chat.header(addon.name):append(chat.message('Logging items turned off.')));
	end

	Settings.save();
end

local togglePlayTone = function(shouldPlayTone)
	if (shouldPlayTone == "true") or (shouldPlayTone == nil and Config.tone[1] == false) then
		Config.tone[1] = true;
		print(chat.header(addon.name):append(chat.message('Play tone turned on.')));
	elseif (shouldPlayTone == "false") or (shouldPlayTone == nil and Config.tone[1] == true) then
		Config.tone[1] = false;
		print(chat.header(addon.name):append(chat.message('Play tone turned off.')));
	end

	Settings.save();
end

local toggleTrackMoon = function(shouldShowMoon)
    if (shouldShowMoon == "true") or (shouldShowMoon == nil and Config.trackMoonPhase[1] == false) then
        Config.trackMoonPhase[1] = true;
        print(chat.header(addon.name):append(chat.message('Display Moon turned on.')));
    elseif (shouldShowMoon == "false") or (shouldShowMoon == nil and Config.trackMoonPhase == true) then
        Config.trackMoonPhase[1] = false;
        print(chat.header(addon.name):append(chat.message('Display Moon turned off.')));
    end

    Settings.save();
end

func.emptyBucket = function(clammy, turnedIn, isReset)
    clammy.bucketSize = 50;
	clammy.weight = 0;
	clammy.relativeWeight = 50;
	clammy.percentRemaining = 0;
	clammy.money = 0;
	clammy.hasBucket = false;
	clammy.showItemSeparator = false;

	for idx,citem in ipairs(clammy.items) do
		clammy.bucket[idx] = 0;
	end
	if (isReset == false) then
		if (#clammy.trackingBucket > 0) then
			for _, row in ipairs(clammy.trackingBucket) do
				if (turnedIn == true) then
					local key = row.item;
					local prev = clammy.sessionDropTotals[key] or 0;
					clammy.sessionDropTotals[key] = prev + 1;
					local g = row.gil or 0;
					clammy.sessionValue = clammy.sessionValue + g;
					if (row.vendor == true) then
						clammy.sessionValueNPC = clammy.sessionValueNPC + g;
					else
						clammy.sessionValueAH = clammy.sessionValueAH + g;
					end
				else
					local g = row.gil;
					if (g ~= nil) then
						clammy.sessionBreakLossGil = clammy.sessionBreakLossGil + g;
						local key = row.item or "?";
						local agg = clammy.sessionBreakLossByItem[key];
						if (agg == nil) then
							agg = { c = 0, g = 0 };
							clammy.sessionBreakLossByItem[key] = agg;
						end
						agg.c = agg.c + 1;
						agg.g = agg.g + g;
					end
				end
			end
		end
        if (Config.log[1] == true) and (Config.legacyLog[1] == false) then
            local file = openLogFile(clammy, turnedIn);
            if (file ~= nil) then
            for _,row in ipairs(clammy.trackingBucket) do
				-- CSV columns (logging only; session gil is always tallied above when cashed in):
				-- DateTime (String), Item Name(String), Configured Item Sell price when placed in bucket(Int), Whether or not the item is sold to a vendor(Bool),
				-- Percentage of moon phase (Signed Int), Number of buckets paid for(Int), Number of buckets received including transfer buckets (Int), 
				-- Whether or not HQ clamming legs are equipped (Bool), Current vana'diel day of the week(String), Current vana'diel hour (Int) 
                local fdata = ('%s, %s, %s, %s, %s, %s, %s, %s, %s, %s\n'):fmt(
                    row.datetime,
                    row.item,
                    row.gil,
                    row.vendor,
                    row.moonPercent,
                    row.bucketsPurchased,
					row.bucketsReceived,
					row.hasHQLegs,
					row.dayOfWeek,
					row.currentHour
                );
                file:write(fdata);
            end
            closeLogFile(file);
            end
        end
    end

	clammy.trackingBucket = {};
	if Config.subtractBucketCostFromGilEarned[1] == true then
		clammy.trueSessionValue = clammy.sessionValue - (clammy.bucketsPurchased * 500);
	else
		clammy.trueSessionValue = clammy.sessionValue;
	end
	clammy.trueSessionValueNPC = clammy.sessionValueNPC;
	clammy.trueSessionValueAH = clammy.sessionValueAH;
	clammy = updateGilPerHour(clammy);
	if isReset == true then
		clammy.bucketAverageTime = 0;
	end
	if (isReset == false) and (Config.sessionLog[1] == true) then
		local wreason = (turnedIn == true) and 'turn_in' or 'break';
		clammy = func.writeSessionReport(clammy, wreason);
	end
	if (isReset == false) then
		clammy.forceSessionMetricsRefresh = true;
	end
	return clammy;
end


local function clammyLogsLastHelperExitPath()
	return func.clammyConfigDataDirectory() .. 'last_helper_exitcode.txt';
end

--[[
* @return 0 success, 1 failure, nil if file missing/unreadable
--]]
local function readClammyHelperExitCodeFile()
	local p = clammyLogsLastHelperExitPath();
	local f = io.open(p, 'r');
	if (f == nil) then
		return nil;
	end
	local s = f:read('*a');
	f:close();
	if (s == nil) then
		return nil;
	end
	s = tostring(s):gsub('[\r\n]', ''):gsub('^%s+', ''):gsub('%s+$', '');
	return tonumber(s);
end

local function ahApplyFailureChatWhy()
	local err = ahpricing.LAST_ERROR;
	local why = 'No rows applied.';
	if (err == 'use_off') then
		why = 'Turn on Apply AH JSON in /clammyh settings.';
	elseif (err == 'missing_file') then
		why = 'Missing data/ah_prices.json (and no usable overrides).';
	elseif (err == 'overrides_no_match') then
		why = 'Overrides exist but item names did not match.';
	elseif (err == 'bad_json') or (err == 'bad_schema') then
		why = 'Invalid ah_prices.json.';
	elseif (err == 'empty_file') or (err == 'open_fail') then
		why = 'Could not read data/ah_prices.json.';
	end
	return why;
end

local function clammyLogsHelperLockPath()
	return func.clammyConfigDataDirectory() .. 'horizon_helper.lock';
end

local function applyHorizonHelperResultToGame()
	local code = readClammyHelperExitCodeFile();
	if (code == nil) or (code ~= 0) then
		print(chat.header(addon.name):append(chat.message('Clammy: Failed to pull AH data. Check Game\\config\\addons\\ClammyHorizon\\data\\horizon_helper.log')));
		return;
	end
	local n = ahpricing.applyFromFile(Config);
	if (n > 0) then
		_browserAhCache = nil;
		print(chat.header(addon.name):append(chat.message(('Clammy: Successfully updated AH pricing (%d items).'):fmt(n))));
		if (Config.ahPricesGeneratedUtc ~= nil) and (Config.ahPricesGeneratedUtc[1] ~= nil) and (Config.ahPricesGeneratedUtc[1] ~= '') then
			print(chat.header(addon.name):append(chat.message(('Generated (UTC): %s'):fmt(Config.ahPricesGeneratedUtc[1]))));
		end
		if ((ahpricing.OVERRIDE_COUNT ~= nil) and (ahpricing.OVERRIDE_COUNT > 0)) then
			print(chat.header(addon.name):append(chat.message(('Overrides layered: %d rows.'):fmt(ahpricing.OVERRIDE_COUNT))));
		end
	else
		print(chat.header(addon.name):append(chat.message(('Clammy: Horizon refresh finished but gil was not updated. %s'):fmt(ahApplyFailureChatWhy()))));
	end
end

func.resetHorizonReloadahState = function(clammy)
	clammy.horizonRefreshPending = false;
	clammy.horizonBgLastCheck = 0;
	local lockPath = clammyLogsHelperLockPath();
	pcall(os.remove, lockPath);
	local killHs = tostring(addon.path:append('scripts/kill_clammy_horizon_helper.ps1'));
	killHs = killHs:gsub('/', '\\');
	os.execute(('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%s"'):fmt(killHs));
	print(chat.header(addon.name):append(chat.message('Clammy: Cleared reloadah state and asked any stale Horizon helper PowerShell window to close. Run /clammyh reloadah when ready.')));
	return clammy;
end

--[[
* Starts PowerShell helper detached: browser assist (default), token file, or Playwright capture.
* Completion is detected via horizon_helper.lock removal; apply runs from pollHorizonBackgroundHelper on the render thread.
* noKillPrevious: pass true for /clammyh reloadah nokill — do not ask the new helper to terminate prior helper windows.
--]]
func.runHorizonFullRefreshFromGame = function(clammy, noKillPrevious, horizonMode)
	if (clammy.horizonRefreshPending == true) then
		local lk = clammyLogsHelperLockPath();
		local lockThere = (ashita.fs ~= nil) and (ashita.fs.exists ~= nil) and (ashita.fs.exists(lk) == true);
		if (lockThere == true) then
			print(chat.header(addon.name):append(chat.message('Clammy: Horizon refresh still active (helper running). Wait for a result or /clammyh reloadah unlock')));
			return clammy;
		end
		print(chat.header(addon.name):append(chat.message('Clammy: Stuck pending flag with no lock file; clearing. Retry /clammyh reloadah if needed.')));
		clammy.horizonRefreshPending = false;
	end
	local lockPath = clammyLogsHelperLockPath();
	if (ashita.fs ~= nil) and (ashita.fs.exists ~= nil) and (ashita.fs.exists(lockPath) == true) then
		if (noKillPrevious == true) then
			print(chat.header(addon.name):append(chat.message('Clammy: horizon_helper.lock exists — run /clammyh reloadah unlock, or retry without nokill to force-close a stale helper.')));
			return clammy;
		end
		local killHs = tostring(addon.path:append('scripts/kill_clammy_horizon_helper.ps1'));
		killHs = killHs:gsub('/', '\\');
		print(chat.header(addon.name):append(chat.message('Clammy: horizon_helper.lock present — stopping stale helper PowerShell windows, then starting a fresh run.')));
		local kcmd = ('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%s"'):fmt(killHs);
		os.execute(kcmd);
		pcall(os.remove, lockPath);
	end
	if (ashita.fs ~= nil) and (ashita.fs.create_directory ~= nil) then
		ashita.fs.create_directory(func.clammyConfigDataDirectory());
		ashita.fs.create_directory(func.clammyCharLogsDirectory());
	end
	local lwf = io.open(lockPath, 'w');
	if (lwf == nil) then
		print(chat.header(addon.name):append(chat.message('Clammy: Could not create horizon_helper.lock (check addons/ClammyHorizon/data permissions).')));
		return clammy;
	end
	lwf:write('queued');
	lwf:close();

	local ps = tostring(addon.path:append('scripts/clammy_horizon_capture_and_update.ps1'));
	ps = ps:gsub('/', '\\');
	print(chat.header(addon.name):append(chat.message('Clammy: Starting Horizon refresh in the background (game stays responsive to the server).')));
	local extra = '';
	if (noKillPrevious == true) then
		extra = ' -NoKillPreviousHelpers';
	end
	if (horizonMode == nil) or (horizonMode == '') then
		horizonMode = 'auto';
	end
	if (horizonMode == 'token') then
		extra = extra .. ' -UseSavedBearer';
	elseif (horizonMode == 'paste') then
		extra = extra .. ' -BrowserAssist';
	elseif (horizonMode == 'capture') then
		extra = extra .. ' -PlaywrightCapture';
	end
	-- default 'auto' passes no flag: PS1 uses CDP auto-capture with Y/N Chrome-close prompt
	local cmd = ('cmd /c set "CLAMMY_FROM_GAME=1" && start "Clammy Horizon helper" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%s"%s'):fmt(ps, extra);
	os.execute(cmd);
	clammy.horizonRefreshPending = true;
	clammy.horizonBgLastCheck = 0;
	return clammy;
end

func.pollHorizonBackgroundHelper = function(clammy)
	if (clammy.horizonRefreshPending ~= true) then
		return clammy;
	end
	local now = os.clock();
	if ((clammy.horizonBgLastCheck ~= nil) and (now - clammy.horizonBgLastCheck < 0.25)) then
		return clammy;
	end
	clammy.horizonBgLastCheck = now;

	local lockPath = clammyLogsHelperLockPath();
	local fsOk = (ashita.fs ~= nil) and (ashita.fs.exists ~= nil);
	if (fsOk and ashita.fs.exists(lockPath) == true) then
		return clammy;
	end

	clammy.horizonRefreshPending = false;
	applyHorizonHelperResultToGame();
	return clammy;
end

func.logAhPricingApplyOutcome = function()
	local n = ahpricing.applyFromFile(Config);
	if (n > 0) then
		_browserAhCache = nil;
		if (ahpricing.OVERRIDES_ONLY_BASE == true) then
			print(chat.header(addon.name):append(chat.message(('AH pricing: applied %d entries (no ah_prices.json; overrides file only).'):fmt(n))));
		else
			print(chat.header(addon.name):append(chat.message(('AH pricing: applied %d entries from disk.'):fmt(n))));
			if ((ahpricing.OVERRIDE_COUNT ~= nil) and (ahpricing.OVERRIDE_COUNT > 0)) then
				print(chat.header(addon.name):append(chat.message(('AH pricing: %d rows from overrides layered on ah_prices.json.'):fmt(ahpricing.OVERRIDE_COUNT))));
			end
		end
		if (Config.ahPricesGeneratedUtc ~= nil) and (Config.ahPricesGeneratedUtc[1] ~= nil) and (Config.ahPricesGeneratedUtc[1] ~= '') then
			print(chat.header(addon.name):append(chat.message(('Generated (UTC): %s'):fmt(Config.ahPricesGeneratedUtc[1]))));
		end
	else
		print(chat.header(addon.name):append(chat.message(ahApplyFailureChatWhy())));
	end
	return n;
end

func.handleChatCommands = function(args, clammy)
	if (#args >= 2 and (args[2]:any('reloadah') or args[2]:any('horizonauth'))) then
		if (args[2]:any('reloadah') and (#args >= 3) and args[3]:any('local')) then
			func.logAhPricingApplyOutcome();
			return clammy;
		end
		if ((#args >= 3) and args[3]:any('unlock')) then
			return func.resetHorizonReloadahState(clammy);
		end
		local noKill = false;
		local horizonMode = 'auto';
		for i = 3, #args do
			if (args[i]:any('nokill')) then
				noKill = true;
			end
			if (args[i]:any('token')) then
				horizonMode = 'token';
			end
			if (args[i]:any('paste')) then
				horizonMode = 'paste';
			end
			if (args[i]:any('capture')) then
				horizonMode = 'capture';
			end
		end
		if (horizonMode == 'token') then
			print(chat.header(addon.name):append(chat.message(
				'Clammy: /clammyh reloadah token -- uses saved horizon_bearer.txt only (no browser).'
			)));
		elseif (horizonMode == 'paste') then
			print(chat.header(addon.name):append(chat.message(
				'Clammy: /clammyh reloadah paste -- opens horizonxi.com in your browser; paste the JWT in the helper window.'
			)));
		elseif (horizonMode == 'capture') then
			print(chat.header(addon.name):append(chat.message(
				'Clammy: /clammyh reloadah capture -- same as reloadah but forces a fresh CDP capture.'
			)));
		else
			print(chat.header(addon.name):append(chat.message(
				'Clammy: /clammyh reloadah -- fetching live AH prices (Chrome extension handles token automatically).'
			)));
		end
		func.runHorizonFullRefreshFromGame(clammy, noKill, horizonMode);
		return clammy;
	end

    if (#args == 1) then
		if (clammy.editorIsOpen[1] == false) then
			clammy.editorIsOpen[1] = true;
		else
			clammy.editorIsOpen[1] = false;
		end
        return clammy;
	end

    if (#args == 2 and args[2]:any('reset')) then --manually empty the bucket
		clammy = func.emptyBucket(clammy, false, true);
		print(chat.header(addon.name):append(chat.message('Bucket reset.')));
        return clammy;
    end

	if (#args == 2 and args[2]:any('resetsession')) then
		clammy = resetSession(clammy);
		print(chat.header(addon.name):append(chat.message('Session reset.')));
		return clammy;
	end

    if (#args == 3 and args[2]:any('weight')) then --manually overide the bucket's weight
        clammy.weight = tonumber(args[3]);
		print(chat.header(addon.name):append(chat.message(('Weight manually set to %s.'):fmt(clammy.weight))));
        return clammy;
    end

	if (args[2]:any('debug')) then
		if(args[3]:any('additem')) then
			
		elseif (args[3]:any('setbucketsize')) then
			clammy.bucketSize = tonumber(args[4]);

		elseif (args[3]:any('breakbucket')) then
			clammy.bucketIsBroke = true;
		end
		return clammy;
	end

    if (args[2]:any('showvalue')) then --turns loggin on/off
        toggleShowValue(args[3])
        return clammy;
    end

	if(args[2]:any('logbrokenbucketitems')) then
		toggleLogAllResults(args[3]);
        return clammy;
	end

	if(args[2]:any('showsessioninfo')) then
		toggleShowSessionInfo(args[3]);
        return clammy;
	end

	if(args[2]:any('usebucketvalueforweightcolor')) then
		toggleUseBucketValueForWeightColor(args[3]);
		return clammy;
	end

	if(args[2]:any('setweightvalues')) then
		setWeightValues(args[3], args[4]);
		return clammy;
	end

	if(args[2]:any('showmoon')) then
		toggleTrackMoon(args[3]);
		return clammy;
	end

	if (#args == 3 and args[2]:any('showitems')) then --turns loggin on/off
        toggleShowItems(args[3]);
        return clammy;
    end

	if (#args == 3 and args[2]:any('log')) then --turns loggin on/off
    	toggleLogItems(args[3]);
        return clammy;
    end

	if (#args == 3 and args[2]:any('tone')) then --turns ready tone on/off
        togglePlayTone(args[3]);
        return clammy;
    end

	if (#args >= 2 and (args[2]:any('browse') or args[2]:any('itemstatus'))) then
		clammy.browserIsOpen[1] = not clammy.browserIsOpen[1];
		return clammy;
	end

    print(chat.header(addon.name):append(chat.message('Invalid command passed, try /clammyh for config menu.')));
    return clammy;
end

func.handleTextIn = function(e, clammy)

	local hasBucketKI = AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(511);
	local areaId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
	if (areaId ~= 4) then
		return clammy;
	end

    local weightColor = {
        {diff=200, color={1.0, 1.0, 1.0, 1.0}},
        {diff=35, color={1.0, 1.0, 0.8, 1.0}},
        {diff=20, color={1.0, 1.0, 0.4, 1.0}},
        {diff=11, color={1.0, 1.0, 0.0, 1.0}},
        {diff=7, color={1.0, 0.6, 0.0, 1.0}},
        {diff=6, color={1.0, 0.4, 0.0, 1.0}},
        {diff=3, color={1.0, 0.3, 0.0, 1.0}},
    }

	--Your clamming capacity has increased to XXX ponzes!
	if (string.match(e.message, "Your clamming capacity has increased to")) then
		clammy.bucketSize = clammy.bucketSize + 50;
		clammy.percentRemaining = 1;
		clammy.bucketsReceived = clammy.bucketsReceived + 1;
		clammy.bucketColor = {1.0, 1.0, 1.0, 1.0};
		clammy.bucketShouldBeTurnedIn = false;
		clammy = calculateTimePerBucket(clammy);
		clammy.bucketStartTime = os.clock();
		clammy.relativeWeight = clammy.relativeWeight + 50;
		clammy = updateLastClammingAction(clammy);
		return clammy;
	end

	if (string.match(e.message, "You find a") and (hasBucketKI == true)) then
		for idx,citem in ipairs(clammy.items) do
			if (string.match(string.lower(e.message), string.lower(citem.item)) ~= nil) then
				clammy = writeBucket(clammy, citem);
				clammy = updateLastClammingAction(clammy);
				clammy.weight = clammy.weight + citem.weight;
				clammy.money = clammy.money + citem.gil[1];
				clammy.bucket[idx] = clammy.bucket[idx] + 1;
				clammy.cooldown =  os.clock() + 10.5;
				clammy.clammingAttempts = clammy.clammingAttempts + 1;
				if Config.colorWeightBasedOnValue[1] == false then
					for _, item in ipairs(weightColor) do
						if ((clammy.bucketSize - clammy.weight) < item.diff) then
							clammy.bucketColor = item.color;
						end
					end
				end
				clammy.relativeWeight = clammy.bucketSize - clammy.weight;
				local bucketScalar = clammy.bucketSize / 50;
				local relativeBucketSize = clammy.bucketSize / bucketScalar;
				if (clammy.relativeWeight > 50) then
					clammy.percentRemaining = 1;
				else
					clammy.percentRemaining = (clammy.relativeWeight % 50) / relativeBucketSize;
				end
				clammy.hasBucket = true;
				clammy.playTone = true;

				if (Config.log[1] == true) and (Config.legacyLog[1] == true) then
					writeLogFile(citem);
				end
				if (string.match(e.message, "All your shellfish are washed back into the sea")) then
					clammy.stopSound = true;
					clammy.bucketIsBroke = true;
				end
				return clammy;
			end
		end
	end
    return clammy;
end

func.renderEditor = function(clammy)
    if (not clammy.editorIsOpen[1]) then
        return clammy;
    end
	local settingsTabHeight = 548;
	local settingsWindowHeight = 673;
	if (Config.log[1] == true) then
		settingsTabHeight = settingsTabHeight + 25;
		settingsWindowHeight = settingsWindowHeight + 25;
	end
	if (Config.tone[1] == true) then
		settingsTabHeight = settingsTabHeight + 25;
		settingsWindowHeight = settingsWindowHeight + 25;
	end
	if (Config.autoResetLog[1] == true) then
		settingsTabHeight = settingsTabHeight + 50;
		settingsWindowHeight = settingsWindowHeight + 50;
	end
    imgui.SetNextWindowSize({ 500, settingsWindowHeight, });
    imgui.SetNextWindowSizeConstraints({ 0, 0, }, { FLT_MAX, FLT_MAX, });
    if (imgui.Begin('ClammyHorizon##Config', clammy.editorIsOpen)) then

        if (imgui.Button('Save Settings')) then
            Settings.save();
            if (Config.useAhPricingFromFile[1] == true) then
                ahpricing.applyFromFile(Config);
            end
            print(chat.header(addon.name):append(chat.message('Settings saved.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reset Settings')) then
            Settings.reset();
            print(chat.header(addon.name):append(chat.message('Settings reset to defaults.')));
        end
        imgui.SameLine();
        if (imgui.Button('Reset Session')) then
            clammy = resetSession(clammy);
            print(chat.header(addon.name):append(chat.message('Reset session.')));
        end

        imgui.Separator();

        if (imgui.BeginTabBar('##clammy_tabbar', ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)) then
            if (imgui.BeginTabItem('General', nil)) then
                renderGeneralConfig(settingsTabHeight);
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Items', nil)) then
                renderItemListConfig(settingsTabHeight);
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end

    end
    imgui.End();
    return clammy;
end

func.renderClammy = function(clammy)
	clammy = func.refreshLogPaths(clammy);
	-- handling if player is nil zoning
	local player = GetPlayerEntity();
	local areaId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
	if ((areaId ~= 4) and (Config.hideInDifferentZone[1] == true)) then -- when zoning or outside Bibiki Bay
		return clammy;
	end
	if (player ~= nil) then
		clammy = getCurrentEquip(clammy);
	end

	-- 
	clammy = handleBucket(clammy);
	clammy = getVanaTime(clammy);
	clammy = getMoon(clammy);
	local bucketBreakChance = calculateChanceOfBreak(clammy, (clammy.bucketSize - clammy.weight));

	-- Handling auto reset of session
	local now = os.clock();
	local timeBeforeReset = now - (Config.minutesBeforeAutoReset[1] * 60);
	if (clammy.lastClammingAction < timeBeforeReset) and
		(Config.autoResetLog[1] == true) and
		(clammy.hasBucket == false) then
		clammy.lastClammingAction = now;
		clammy.sessionWasReset = true;
	end
	local needSessionMetricsRefresh = (clammy.forceSessionMetricsRefresh == true)
		or (clammy.lastSessionMetricsRefresh == nil)
		or ((now - (clammy.lastSessionMetricsRefresh or 0)) >= 60);

	local windowSize = (300 * Config.windowScaling[1]);
    imgui.SetNextWindowBgAlpha(0.8);
    imgui.SetNextWindowSize({ windowSize, -1, }, ImGuiCond_Always);
	if (imgui.Begin('ClammyHorizon', true, bit.bor(ImGuiWindowFlags_NoDecoration))) then

		local normalFontSize = 1 * Config.windowScaling[1];
		local noteFont = 0.78 * normalFontSize;
		local enlargedFontSize = 1.3 * Config.windowScaling[1];
		if (clammy.hasBucket == true) then
			imgui.TextColored({0.0, 1.0, 0.0, 1.0}, "Bucket")
		elseif(clammy.bucketIsBroke == true) then
			imgui.TextColored({0.1, 0.1, 0.1, 1.0}, "Bucket")
		else
			imgui.TextColored({0.9, 0.9, 0.0, 1.0}, "Bucket")
		end
		clammy = calcRedBucket(clammy);
		imgui.SameLine()
		imgui.Text("Weight [" .. clammy.bucketSize .. "]:");
		imgui.SameLine();
		imgui.SetWindowFontScale(enlargedFontSize);
		imgui.SetCursorPosY(imgui.GetCursorPosY() - (2 * Config.windowScaling[1]));
		imgui.TextColored(clammy.bucketColor, tostring(clammy.weight));
		imgui.SetWindowFontScale(normalFontSize);
		imgui.SameLine();
		imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetColumnWidth() - imgui.GetStyle().FramePadding.x - imgui.CalcTextSize("[999]"));
		local cdTime = math.floor(clammy.cooldown - os.clock());
		if (Config.useStopTone[1] == true and (clammy.stopSound == true or clammy.bucketIsBroke == true)) then
			cdTime = cdTime - 9;
		end
		if (cdTime <= 0) then
			imgui.TextColored({ 0.5, 1.0, 0.5, 1.0 }, "  [*]");
			clammy = playSound(clammy);
		else
			imgui.TextColored({ 1.0, 1.0, 0.5, 1.0 }, "  [" .. cdTime .. "]");
		end
		if (Config.showValue[1] == true) then
			imgui.Text("Estimated Value: " .. formatInt(clammy.money));
		end
		if (Config.showClammyHealth[1] == true) then
			local barcolor = T{0, 0.75, 0, 1};
			if (clammy.bucketShouldBeTurnedIn == true) then
				barcolor = {1, 0.1, 0, 1};
			elseif (bucketBreakChance.percentWeight > 0) then
				barcolor = bucketBreakChance.color;
			end
			imgui.PushStyleColor(ImGuiCol_PlotHistogram, barcolor);
			imgui.ProgressBar(clammy.percentRemaining, {-1.0, 0}, "Bucket Health ".. (clammy.percentRemaining * 100).. "%");
			imgui.PopStyleColor(1);
		end
		if (Config.showPercentChanceToBreak[1] == true) then
			imgui.Text("Percent chance to break: "); imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize("Percent chance to break:  "));
			imgui.SetWindowFontScale(enlargedFontSize); imgui.SetCursorPosY(imgui.GetCursorPosY() - (2 * Config.windowScaling[1]));
			imgui.TextColored(bucketBreakChance.color, formatChanceBreak(bucketBreakChance.percentWeight)); imgui.SameLine();
			imgui.SetWindowFontScale(normalFontSize); imgui.SetCursorPosY(imgui.GetCursorPosY() + (2 * Config.windowScaling[1]));
			if (string.len(bucketBreakChance.percentWeight) == 1) then
				imgui.SetCursorPosX(imgui.CalcTextSize("Percent chance to break:   " .. bucketBreakChance.percentWeight));
			elseif (string.len(bucketBreakChance.percentWeight) == 3) then
				imgui.SetCursorPosX(imgui.CalcTextSize("Percent chance to break:    " .. bucketBreakChance.percentWeight));
			elseif (string.len(bucketBreakChance.percentWeight) == 4) then
				imgui.SetCursorPosX(imgui.CalcTextSize("Percent chance to break:    " .. bucketBreakChance.percentWeight));
			elseif (string.len(bucketBreakChance.percentWeight) == 5) then
				imgui.SetCursorPosX(imgui.CalcTextSize("Percent chance to break:    " .. bucketBreakChance.percentWeight));
			end
			imgui.Text("%");
		end
		local textColor = {0.0, 0.75, 0.60, 1};
		if (Config.showSessionInfo[1] == true) then
			if Config.subtractBucketCostFromGilEarned[1] == true then
				clammy.trueSessionValue = clammy.sessionValue - (clammy.bucketsPurchased * 500);
			else
				clammy.trueSessionValue = clammy.sessionValue
			end
			clammy.trueSessionValueNPC = clammy.sessionValueNPC;
			clammy.trueSessionValueAH = clammy.sessionValueAH;
			if (needSessionMetricsRefresh) then
				clammy = updateGilPerHour(clammy);
			end
			local rateOk = (clammy.gilPerHourStabilizeReady == true) and (clammy.sessionStarted == true);
			local function rateStr(n)
				if (rateOk) then
					return formatInt(n);
				end
				return "--";
			end
		imgui.Separator();
			if(Config.subtractBucketCostFromGilEarned[1] == true) then
				imgui.Text("Est. gil ");
				imgui.SameLine(0, 0);
				imgui.TextColored(textColor, "(Profit)");
				imgui.SameLine(0, 0);
				imgui.Text(": ");
				imgui.SameLine(0, 0);
				imgui.Text(formatInt(clammy.sessionValue));
				imgui.SameLine(0, 4);
				imgui.TextColored(textColor, "(" .. formatInt(clammy.trueSessionValue) .. ")");
			else
				imgui.Text("Est. gil: " .. formatInt(clammy.trueSessionValue));
			end

			if (Config.splitItemsBySellType[1] == true) then
				imgui.Text("Total gil earned(NPC): ");
				imgui.SameLine(0, 0);
				imgui.Text(formatInt(clammy.trueSessionValueNPC));
				imgui.Text("Total gil earned(AH): ");
				imgui.SameLine(0, 0);
				imgui.Text(formatInt(clammy.trueSessionValueAH));
			end
			if(Config.subtractBucketCostFromGilEarned[1] == true) then
				imgui.Text("Est. gil/hr ");
				imgui.SameLine(0, 0);
				imgui.TextColored(textColor, "(Profit)");
				imgui.SameLine(0, 0);
				imgui.Text(": ");
				imgui.SameLine(0, 0);
				imgui.Text(rateStr(clammy.gilPerHour));
				imgui.SameLine(0, 4);
				imgui.TextColored(textColor, "(" .. rateStr(clammy.gilPerHourMinusBucket) .. ")");
			else
				imgui.Text("Est. gil/hr: ");
				imgui.SameLine(0, 0);
				imgui.Text(rateStr(clammy.gilPerHour));
			end
			if (not rateOk) then
				imgui.SetWindowFontScale(noteFont);
				local waitNote = "--/hr & dpm until " .. tostring(Config.gilPerHourStabilizeMinutes[1] or 10) .. "+ min (early session).";
				if (imgui.TextWrapped) then
					if (imgui.PushStyleColor) then
						imgui.PushStyleColor(ImGuiCol_Text, { 0.45, 0.45, 0.5, 1.0 });
					end
					imgui.TextWrapped(waitNote);
					if (imgui.PopStyleColor) then
						imgui.PopStyleColor(1);
					end
				else
					imgui.TextColored({ 0.45, 0.45, 0.5, 1.0 }, waitNote);
				end
				imgui.SetWindowFontScale(normalFontSize);
			end
			if (Config.splitItemsBySellType[1] == true) then
				imgui.Text("Est. gil/hr [V]: ");
				imgui.SameLine(0, 0);
				imgui.Text(rateStr(clammy.gilPerHourNPC));
				imgui.Text("Est. gil/hr [AH]: ");
				imgui.SameLine(0, 0);
				imgui.Text(rateStr(clammy.gilPerHourAH));
			end
			local lostNames = {};
			if (clammy.sessionBreakLossByItem ~= nil) then
				for iname, _ in pairs(clammy.sessionBreakLossByItem) do
					lostNames[#lostNames + 1] = iname;
				end
				table.sort(lostNames);
			end
			imgui.Text("Lost to sea (est.): " .. formatInt(clammy.sessionBreakLossGil or 0));
			imgui.SameLine(0, 8);
			if (imgui.Button("Open logs##lostSeaLog")) then
				local dir = clammy.fileDir;
				if (dir ~= nil) and (dir ~= "") then
					dir = dir:gsub("/", "\\");
					os.execute('cmd /c start "" "' .. dir:gsub('"', '""') .. '"');
				end
			end
			if (#lostNames > 0) then
				local function drawLostItemLines()
					imgui.SetWindowFontScale(noteFont);
					for _, iname in ipairs(lostNames) do
						local ag = clammy.sessionBreakLossByItem[iname];
						if (ag ~= nil) then
							imgui.TextColored({ 0.65, 0.5, 0.45, 1.0 },
								"  " .. iname .. "  x" .. tostring(ag.c) .. "  " .. formatInt(ag.g) .. "g");
						end
					end
					imgui.SetWindowFontScale(normalFontSize);
				end
				if (type(imgui.CollapsingHeader) == "function") then
					if (imgui.CollapsingHeader("Item breakdown (lost)##lostSea", 0)) then
						drawLostItemLines();
					end
				else
					drawLostItemLines();
				end
			end
			imgui.Separator();

			if (Config.subtractBucketCostFromGilEarned[1] == true) then
				local bucketCost = clammy.bucketsPurchased * 500;
				imgui.Text("Buckets ");
				imgui.SameLine(0, 0);
				imgui.TextColored(textColor, "(Bought)(Spent)");
				imgui.SameLine(0, 0);
				imgui.Text(": " .. clammy.bucketsReceived .. "  ");
				imgui.SameLine(0, 0);
				imgui.TextColored(textColor, "(-" .. formatInt(clammy.bucketsPurchased) .. ")(-" .. formatInt(bucketCost) .. ")");
			else
				imgui.Text("Buckets : " .. clammy.bucketsPurchased);
			end
			imgui.Text("Session length: " .. (clammy.sessionStarted and formatTimestamp(now - clammy.startingTime) or "--:--:--"));
			if Config.showAverageTimePerBucket[1] == true then
				imgui.Text("Avg time/bucket: " .. formatTimestamp(clammy.bucketAverageTime));
			end
		end
		if (needSessionMetricsRefresh) then
			local elapsedSess = now - (clammy.startingTime or now);
			if (elapsedSess > 0) then
				clammy.clammingAttemptsPerHour = (clammy.clammingAttempts / (elapsedSess / 60));
			else
				clammy.clammingAttemptsPerHour = 0;
			end
			clammy.lastSessionMetricsRefresh = now;
			clammy.forceSessionMetricsRefresh = false;
		end
		if (Config.showClammingAttempts[1] == true) then
			local dpmPart;
			if (Config.showSessionInfo[1] == true) and (clammy.gilPerHourStabilizeReady ~= true) then
				dpmPart = "--";
			else
				dpmPart = tostring(math.round(clammy.clammingAttemptsPerHour, 1)) .. " dpm";
			end
			imgui.Text("Clamming digs:          " .. clammy.clammingAttempts .. " (est. " .. dpmPart .. ")");
		end
		if (Config.trackMoonPhase[1] == true) then
			imgui.Separator();
			imgui.Text("Current moon phase is: " .. clammy.moonTable.moonPhase);
			imgui.Text("Current moon phase percentage is: " .. clammy.moonTable.moonPercent .. "%");
		end
		if (Config.showDayOfWeek[1] == true) then
			imgui.Separator();
			imgui.Text("The current day is: "); imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize("The current day is:  "))
			imgui.TextColored(clammy.vanaTime.dayOfWeekColor, "".. clammy.vanaTime.dayName);
		end

		if (Config.checkEquippedItem[1] == true) then
			imgui.Separator();
			imgui.Text('HQ legs: ') imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize('HQ legs:  '));
			if clammy.hasHQLegs == true then
				imgui.TextColored({0, 1, 0, 1}, tostring(clammy.hasHQLegs)); imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize('HQ legs:  '.. tostring(clammy.hasHQLegs)));
			else
				imgui.TextColored({1, 0, 0, 1}, tostring(clammy.hasHQLegs)); imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize('HQ legs:  '.. tostring(clammy.hasHQLegs)));
			end
			imgui.Text(' HQ body: ');  imgui.SameLine(); imgui.SetCursorPosX(imgui.CalcTextSize('HQ legs:  '.. tostring(clammy.hasHQLegs) .. ' HQ body: '));
			if clammy.hasHQBody == true then
				imgui.TextColored({0, 1, 0, 1}, tostring(clammy.hasHQBody));
			else
				imgui.TextColored({1, 0, 0, 1}, tostring(clammy.hasHQBody));
			end
		end

		if (Config.showItems[1] == true) then
			if clammy.showItemSeparator == true then
				imgui.Separator();
			end
			for idx,citem in ipairs(Config.items) do
				if (clammy.bucket[idx] ~= 0) then
					clammy.showItemSeparator = true;
					local n = clammy.bucket[idx];
					local wEach = citem.weight;
					local wTotal = wEach * n;
					local priceKind = citem.vendor[1] and "V" or "AH";
					local displayName = truncateItemDisplayName(citem.item, 18);
					local leftTxt = ("[%d] %s  (%dp)   "):fmt(n, displayName, wTotal);
					imgui.Text(leftTxt);
					imgui.SameLine(0, 0);
					imgui.TextColored({ 1.0, 1.0, 0.0, 1.0 }, formatInt(citem.gil[1] * n) .. "g");
					imgui.SameLine(0, 0);
					imgui.Text(" [" .. priceKind .. "]");

				end
			end
		end
		imgui.Separator();
		if (imgui.SmallButton('Browse Items##clammyh_browse_btn')) then
			clammy.browserIsOpen[1] = not clammy.browserIsOpen[1];
		end
    end
    imgui.End();
	return clammy;
end

-- AH price cache for item browser (lazy-loaded from ah_prices.json).
local _browserAhCache = nil;
-- Previous AH net-per-unit snapshot (from ah_prices_prev.json, written by update_ah_prices.ps1).
local _browserAhPrevCache = nil;

func.resetBrowserAhCache = function()
	_browserAhCache = nil;
	_browserAhPrevCache = nil;
end

func.releaseArrowTextures = function()
	_arrowTextures = nil;
end

local function _clammyAhDataPath()
	return ('%sconfig/addons/ClammyHorizon/data/ah_prices.json'):fmt(AshitaCore:GetInstallPath());
end

local function _clammyAhPrevDataPath()
	return ('%sconfig/addons/ClammyHorizon/data/ah_prices_prev.json'):fmt(AshitaCore:GetInstallPath());
end

local function _loadBrowserAhCache()
	local path = _clammyAhDataPath();
	local fsOk = (ashita.fs ~= nil) and (ashita.fs.exists ~= nil);
	if (not fsOk) or (ashita.fs.exists(path) ~= true) then
		_browserAhCache = {};
		return;
	end
	local f = io.open(path, 'r');
	if (f == nil) then _browserAhCache = {}; return; end
	local body = f:read('*a'); f:close();
	if (body == nil) or (body == '') then _browserAhCache = {}; return; end
	local ok, data = pcall(json.decode, body);
	if (not ok) or (type(data) ~= 'table') or (type(data.items) ~= 'table') then
		_browserAhCache = {};
		return;
	end
	_browserAhCache = data.items;

	-- Load previous-price snapshot for change arrows (ah_prices_prev.json).
	local prevPath = _clammyAhPrevDataPath();
	_browserAhPrevCache = {};
	if (fsOk) and (ashita.fs.exists(prevPath) == true) then
		local pf = io.open(prevPath, 'r');
		if (pf ~= nil) then
			local pbody = pf:read('*a'); pf:close();
			if (pbody ~= nil) and (pbody ~= '') then
				local pok, pdata = pcall(json.decode, pbody);
				if (pok) and (type(pdata) == 'table') then
					_browserAhPrevCache = pdata;
				end
			end
		end
	end
end

-- Returns a tooltip string explaining the routing decision for an item.
local function _browserRouteTooltip(row)
	if (row == nil) then
		return 'No AH data -- run /clammyh reloadah to fetch prices.';
	end
	local reason = row.route_reason or '';
	local liq    = row.liquidity or '';
	local rate   = row.estimated_sales_rate_per_day;
	local pct    = row.pct_gain_ah_over_vendor;
	local sc     = row.sample_count or 0;
	local lines  = {};

	if (reason == 'npc_ah_below_vendor') then
		lines[#lines+1] = 'AH net is below NPC vendor price.';
		if (type(pct) == 'number') then
			lines[#lines+1] = ('AH pays %.1f%% less than vendor.'):fmt(math.abs(pct));
		end
	elseif (reason == 'npc_liquidity') then
		if (liq == 'below_min_ah_net') then
			lines[#lines+1] = 'AH stack price is below minimum listing threshold (900g).';
			lines[#lines+1] = 'Not worth the listing time -- vendor instead.';
		elseif (liq == 'slow_market_liquidity') then
			lines[#lines+1] = 'Slow-selling market -- items may sit on AH.';
			if (type(rate) == 'number') then
				lines[#lines+1] = ('Est. ~%.2f sales/day.'):fmt(rate);
			end
		else
			lines[#lines+1] = 'Liquidity too low for reliable AH selling.';
		end
		if (type(pct) == 'number') and (pct > 0) then
			lines[#lines+1] = ('AH offers +%.1f%% vs vendor, but risk outweighs reward.'):fmt(pct);
		end
	elseif (row.prefer_vendor == false) then
		lines[#lines+1] = 'Routed to AH -- better returns than vendor.';
		if (type(pct) == 'number') and (pct > 0) then
			lines[#lines+1] = ('AH returns +%.1f%% more than vendor.'):fmt(pct);
		end
		if (type(rate) == 'number') then
			lines[#lines+1] = ('Est. ~%.2f sales/day.'):fmt(rate);
		end
	else
		lines[#lines+1] = (reason ~= '') and ('Route: ' .. reason) or 'No routing detail available.';
	end
	if (sc > 0) then
		lines[#lines+1] = ('Based on %d recent sales.'):fmt(sc);
	end
	return table.concat(lines, '\n');
end

func.renderItemBrowser = function(clammy)
	if (not clammy.browserIsOpen[1]) then
		return clammy;
	end

	if (_browserAhCache == nil) then
		_loadBrowserAhCache();
	end

	local sc          = Config.windowScaling[1];
	local winW        = math.floor(530 * sc);
	local winH        = math.floor(570 * sc);
	local COL_ROUTE   = math.floor(162 * sc);
	local COL_VSTACK  = math.floor(215 * sc);
	local COL_AHSTACK = math.floor(345 * sc);
	local COL_HELP    = math.floor(465 * sc);

	local VEN_COLOR  = {0.35, 1.0, 0.35, 1.0};
	local AH_COLOR   = {1.0, 0.65, 0.1, 1.0};
	local GOOD_COLOR = {1.0, 0.92, 0.35, 1.0};
	local DIM_COLOR  = {0.48, 0.48, 0.48, 1.0};
	local HINT_COLOR = {0.45, 0.72, 1.0, 0.85};

	local firstUseEver = ImGuiCond_FirstUseEver or 4;
	imgui.SetNextWindowSize({ winW, winH }, firstUseEver);
	imgui.SetNextWindowSizeConstraints({ math.floor(380 * sc), math.floor(250 * sc) }, { FLT_MAX, FLT_MAX });
	imgui.SetNextWindowBgAlpha(0.93);

	if (imgui.Begin('Item Browser##clammyh_browse', clammy.browserIsOpen)) then
		local normalFont = 1.0 * sc;
		local labelFont  = 0.80 * sc;

		-- Legend
		imgui.TextColored(VEN_COLOR, '[V] Vendor');
		imgui.SameLine(0, 12);
		imgui.TextColored(AH_COLOR, '[AH] Auction House');
		imgui.SameLine(0, 12);
		imgui.TextColored(HINT_COLOR, '(?) AH details');
		imgui.Separator();

		-- Column headers
		imgui.SetWindowFontScale(labelFont);
		imgui.Text('Item Name');
		imgui.SameLine(); imgui.SetCursorPosX(COL_ROUTE);
		imgui.Text('Route');
		imgui.SameLine(); imgui.SetCursorPosX(COL_VSTACK);
		imgui.Text('Stack (V)');
		imgui.SameLine(); imgui.SetCursorPosX(COL_AHSTACK);
		imgui.Text('Stack (AH)');
		imgui.SetWindowFontScale(normalFont);
		imgui.Separator();

		-- Sort: AH items first (by stack value desc), then Vendor (by stack value desc)
		local sorted = {};
		for _, citem in ipairs(Config.items) do
			sorted[#sorted + 1] = citem;
		end
		table.sort(sorted, function(a, b)
			local aV = a.vendor[1];
			local bV = b.vendor[1];
			if (aV ~= bV) then return not aV; end
			return a.item:lower() < b.item:lower();
		end);

		imgui.BeginChild('##browse_list', {0, 0}, false);
		local prevGroup = nil;
		for _, citem in ipairs(sorted) do
			local isVendor = citem.vendor[1];
			local group    = isVendor and 'V' or 'AH';
			if (prevGroup ~= nil) and (prevGroup ~= group) then
				imgui.Separator();
			end
			prevGroup = group;

			local routeColor = isVendor and VEN_COLOR or AH_COLOR;
			local routeLabel = isVendor and 'V' or 'AH';
			local stackSize  = ITEM_STACK_SIZE[citem.item] or 12;
			local vendorUnit = ITEM_VENDOR_GIL[citem.item] or 0;
			local vStack     = vendorUnit * stackSize;
			local ahRow      = (_browserAhCache ~= nil) and _browserAhCache[citem.item] or nil;
			local ahNetUnit  = (ahRow ~= nil) and ahRow.ah_net_per_unit or nil;
			local ahStack    = (ahNetUnit ~= nil) and (ahNetUnit * stackSize) or nil;
			local ahBetter   = (ahStack ~= nil) and (vendorUnit > 0) and (ahStack > vStack);
			local tooltip    = _browserRouteTooltip(ahRow);
			local dispName   = truncateItemDisplayName(citem.item, 20);

			-- Price change arrow: compare current AH unit price to previous snapshot.
			local prevUnit   = (_browserAhPrevCache ~= nil) and _browserAhPrevCache[citem.item] or nil;
			local arrowDir   = nil;
			local prevStack  = nil;
			if (prevUnit ~= nil) and (ahNetUnit ~= nil) and (prevUnit > 0) then
				local pct = 100.0 * (ahNetUnit - prevUnit) / prevUnit;
				prevStack = prevUnit * stackSize;
				if     (pct >  3) then arrowDir = 'up';
				elseif (pct < -3) then arrowDir = 'down';
				end
			end

			-- Name
			imgui.TextColored(routeColor, dispName);
			imgui.SameLine(); imgui.SetCursorPosX(COL_ROUTE);
			-- Route badge
			imgui.TextColored(routeColor, routeLabel);
			imgui.SameLine(); imgui.SetCursorPosX(COL_VSTACK);
			-- Stack (V)
			if (vendorUnit == 0) then
				imgui.TextColored(DIM_COLOR, '--');
			else
				imgui.Text(formatInt(vStack) .. 'g');
			end
			imgui.SameLine(); imgui.SetCursorPosX(COL_AHSTACK);
			-- Stack (AH): gold when better than vendor, dim otherwise
			if (ahStack == nil) then
				imgui.TextColored(DIM_COLOR, 'n/a');
			elseif (ahBetter) then
				imgui.TextColored(GOOD_COLOR, formatInt(ahStack) .. 'g');
			else
				imgui.TextColored(DIM_COLOR, formatInt(ahStack) .. 'g');
			end
			-- Price change arrow (>3% move since last reloadah)
			if (arrowDir ~= nil) then
				if (_arrowTextures == nil) then _arrowTextures = _loadArrowTextures(); end
				local tex = (_arrowTextures ~= nil) and _arrowTextures[arrowDir] or nil;
				if (tex ~= nil) then
					imgui.SameLine(0, 3);
					local arrowSz = math.floor(11 * sc);
					imgui.Image(tonumber(ffi.cast('uint32_t', tex)), { arrowSz, arrowSz });
					if (imgui.IsItemHovered()) and (prevStack ~= nil) then
						imgui.BeginTooltip();
						imgui.Text(('Previous value: %sg'):fmt(formatInt(prevStack)));
						imgui.EndTooltip();
					end
				end
			end
			-- (?) tooltip hint — only when AH data exists
			if (ahRow ~= nil) then
				imgui.SameLine(); imgui.SetCursorPosX(COL_HELP);
				imgui.SetWindowFontScale(labelFont);
				imgui.TextColored(HINT_COLOR, '(?)');
				imgui.SetWindowFontScale(normalFont);
				if (imgui.IsItemHovered()) then
					imgui.BeginTooltip();
					for line in tooltip:gmatch('[^\n]+') do imgui.Text(line); end
					imgui.EndTooltip();
				end
			end
		end
		imgui.EndChild();
	end
	imgui.End();
	return clammy;
end

return func;