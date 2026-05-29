--[[
* Optional Horizon XI AH pricing: reads config/addons/ClammyHorizon/data/ah_prices.json (written by scripts/update_ah_prices.ps1)
* and optional config/addons/ClammyHorizon/data/ah_prices_overrides.json merged on top.
--]]

local json = require('libs.json');

local ahpricing = T{
	LAST_ERROR = nil,
	OVERRIDE_COUNT = 0,
	OVERRIDES_ONLY_BASE = false,
};

local function boolish(v)
	if (v == true) then
		return true;
	end
	if (v == false) then
		return false;
	end
	if (type(v) == 'string') then
		local s = v:lower();
		if (s == 'true' or s == '1') then
			return true;
		end
		if (s == 'false' or s == '0') then
			return false;
		end
	end
	return nil;
end

local function clammyConfigPath(filename)
	return ('%sconfig/addons/ClammyHorizon/data/%s'):fmt(AshitaCore:GetInstallPath(), filename);
end

local function pathAhJson()
	return clammyConfigPath('ah_prices.json');
end

local function pathOverridesJson()
	return clammyConfigPath('ah_prices_overrides.json');
end

local function loadOverridesLookup()
	local path = pathOverridesJson();
	if (ashita.fs == nil) or (ashita.fs.exists == nil) or (ashita.fs.exists(path) ~= true) then
		return nil;
	end
	local f = io.open(path, 'r');
	if (f == nil) then
		return nil;
	end
	local body = f:read('*a');
	f:close();
	if (body == nil) or (body == '') then
		return nil;
	end
	local ok, data = pcall(json.decode, body);
	if (ok ~= true) or (type(data) ~= 'table') then
		return nil;
	end
	local ov = data.items;
	if (type(ov) ~= 'table') then
		return nil;
	end
	return ov;
end

local function numberish(v)
	if (type(v) == 'number') then
		return v;
	end
	if (type(v) == 'string') then
		local n = tonumber(v);
		if (n ~= nil) then
			return n;
		end
	end
	return nil;
end

--[[
* @return count of item rows updated from the file
--]]
ahpricing.applyFromFile = function(config)
	ahpricing.LAST_ERROR = nil;
	if (config == nil) or (config.useAhPricingFromFile == nil) or (config.useAhPricingFromFile[1] ~= true) then
		ahpricing.LAST_ERROR = 'use_off';
		return 0;
	end
	local itemsList = config.items;
	if (itemsList == nil) then
		ahpricing.LAST_ERROR = 'no_items';
		return 0;
	end
	local pathMain = pathAhJson();
	local ovItemsStored = loadOverridesLookup();
	local data;
	local blob;
	ahpricing.OVERRIDES_ONLY_BASE = false;

	local fsOk = (ashita.fs ~= nil) and (ashita.fs.exists ~= nil);
	local mainExists = fsOk and (ashita.fs.exists(pathMain) == true);

	if (mainExists == true) then
		local f = io.open(pathMain, 'r');
		if (f == nil) then
			ahpricing.LAST_ERROR = 'open_fail';
			return 0;
		end
		local body = f:read('*a');
		f:close();
		if (body == nil) or (body == '') then
			ahpricing.LAST_ERROR = 'empty_file';
			return 0;
		end
		local okDecode, decoded = pcall(json.decode, body);
		if (okDecode ~= true) or (type(decoded) ~= 'table') then
			ahpricing.LAST_ERROR = 'bad_json';
			return 0;
		end
		data = decoded;
		blob = data.items;
		if (type(blob) ~= 'table') then
			ahpricing.LAST_ERROR = 'bad_schema';
			return 0;
		end
	else
		if (ovItemsStored == nil) then
			ahpricing.LAST_ERROR = 'missing_file';
			return 0;
		end
		ahpricing.OVERRIDES_ONLY_BASE = true;
		data = { };
		blob = { };
	end

	local ovItems = ovItemsStored;
	ahpricing.OVERRIDE_COUNT = 0;
	local n = 0;
	for _, def in ipairs(itemsList) do
		if (def.item ~= nil) then
			local nm = def.item;
			local row = blob[nm];
			local ovr = (ovItems ~= nil) and ovItems[nm] or nil;
			local eg = nil;
			if (type(row) == 'table') then
				eg = row.effective_gil;
				if ((numberish(eg) == nil) and (numberish(row.vendor_gil) ~= nil)) then
					eg = row.vendor_gil;
				end
				eg = numberish(eg);
			end

			local pv = nil;
			if (type(row) == 'table') then
				pv = boolish(row.prefer_vendor);
			end

			local overrideUsed = false;
			if (type(ovr) == 'table') then
				local ovrGil = numberish(ovr.effective_gil);
				if (ovrGil == nil) then
					ovrGil = numberish(ovr.ah_net_per_unit);
				end
				if (ovrGil ~= nil) then
					eg = ovrGil;
					overrideUsed = true;
				end
				local pov = boolish(ovr.prefer_vendor);
				if (pov ~= nil) then
					pv = pov;
					overrideUsed = true;
				end
				if (overrideUsed) then
					ahpricing.OVERRIDE_COUNT = ahpricing.OVERRIDE_COUNT + 1;
				end
			end

			if (eg ~= nil) then
				def.gil[1] = math.floor(eg + 0.5);
				if (pv ~= nil) then
					def.vendor[1] = pv;
				end
				n = n + 1;
			end
		end
	end

	if ((n == 0) and (ahpricing.OVERRIDES_ONLY_BASE == true)) then
		ahpricing.LAST_ERROR = 'overrides_no_match';
		return 0;
	end

	local g = data.generated_utc;
	if (ahpricing.OVERRIDES_ONLY_BASE ~= true) and (config.ahPricesGeneratedUtc ~= nil) and (type(g) == 'string') then
		config.ahPricesGeneratedUtc[1] = g;
	end
	return n;
end

ahpricing.readGeneratedUtcFromFile = function()
	local path = pathAhJson();
	if (ashita.fs == nil) or (ashita.fs.exists == nil) or (ashita.fs.exists(path) ~= true) then
		return nil;
	end
	local f = io.open(path, 'r');
	if (f == nil) then
		return nil;
	end
	local body = f:read('*a');
	f:close();
	if (body == nil) or (body == '') then
		return nil;
	end
	local ok, data = pcall(json.decode, body);
	if (ok ~= true) or (type(data) ~= 'table') then
		return nil;
	end
	local g = data.generated_utc;
	if (type(g) == 'string') and (g ~= '') then
		return g;
	end
	return nil;
end

ahpricing.dataFilePath = pathAhJson;
ahpricing.overridesFilePath = pathOverridesJson;

return ahpricing;
