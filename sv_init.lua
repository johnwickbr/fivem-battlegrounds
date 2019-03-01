SetGameType("Battle Royale")
SetMapName("Sandy Shore")

BR.Kills = {}
BR.MaxZones = 5
BR.ZoneCount = 0
BR.Players = {}
BR.Pickups = {}

-- Local stuff
local _time
local connectedPlayers = {}

function SQL_Query(...)
	return MySQL.Sync.execute(...)
end

function SQL_QueryResult(...)
	return MySQL.Sync.fetchAll(...)
end

function SQL_QueryScalar(...)
	return MySQL.Sync.fetchScalar(...)
end

function SQL_AQuery(...)
	return MySQL.Async.execute(...)
end

function SQL_AQueryResult(...)
	return MySQL.Async.fetchAll(...)
end

function SQL_AQueryScalar(...)
	return MySQL.Async.fetchScalar(...)
end

function MySQL_Ready(...)
	return MySQL.ready(...)
end

-- onesync
GetHostId = function()
	local playerID
	for k,v in pairs(connectedPlayers) do
		playerID = k
		break
	end

	return playerID
end

-- Core
function BR:PlayerJoined(intSource)
	local identifiers, playerName = GetPlayerIdentifiers(intSource), GetPlayerName(intSource)
	local hex, rockstarID, IP, userPack = identifiers[1], identifiers[2], GetPlayerEndpoint(intSource), {}

	local userExist = SQL_QueryResult("SELECT * FROM br_players WHERE hex = @hex", { ["hex"] = hex })
	userExist = userExist and userExist[1]

	if not userExist then
		print(intSource .. " does not exist.")
		SQL_Query("INSERT INTO br_players (`hex`, `rid`, `ip`, `name`) VALUES(@hex, @rid, @ip, @name)", {
			["hex"] = hex,
			["rid"] = rockstarID,
			["ip"] = IP,
			["name"] = playerName
		})

		userExist = { hex = hex, rid = rockstarID, ip = IP, name = playerName }
	end

	userPack.model = userExist.model

	print("User exist -> " .. json.encode(userExist))
	connectedPlayers[intSource] = true
	TriggerClientEvent("postJoin", intSource, userPack)
end

function BR:PlayerDropped(intSource)
	self:PlayerKilled(intSource)
	for k,v in pairs(BR.Players) do
		if v == intSource or not GetPlayerName(v) then
			table.remove(BR.Players, k)
		end
	end

	if connectedPlayers[intSource] then
		connectedPlayers[intSource] = nil
	end

	for k,v in pairs(connectedPlayers) do
		if not GetPlayerEndpoint(k) then
			connectedPlayers[k] = nil
		end
	end
end

function BR:UpdateSharedVar(_tbl)
	for k,v in pairs(_tbl) do
		if self[k] ~= nil then
			self[k] = v
		end
	end
end

function BR:PlayerKilled(intSource, intKiller)
	if not self.Players[intSource] then return end
	self.Players[intSource] = nil
	TriggerClientEvent("BR:Event", -1, 4, { killed = intSource, killer = intKiller })
	print(intKiller)
	if intKiller and self.Players[intKiller] then
		print('updated')
		SQL_Query("UPDATE br_players SET br_players.kills = br_players.kills + 1 WHERE br_players.hex = @hex", { ["hex"] = GetPlayerIdentifiers(intKiller)[1] })
	end

	if tableCount(self.Players) <= 1 then
		local winner = intSource
		for k,_ in pairs(self.Players) do winner = k end
		if winner and self.Players[winner] then
			SQL_Query("UPDATE br_players SET br_players.victory = br_players.victory + 1 WHERE br_players.hex = @hex", { ["hex"] = GetPlayerIdentifiers(winner)[1] })
		end
		TriggerClientEvent("BR:Event", -1, 7, winner)
		self:ResetGame()
	end

end

function BR:ResetGame()
	self.PlaneNet = 0
	self.Players = {}
	self.StartTime = 0
	self.Status = 0
	self.Kills = {}
	self.Host = 0
	self.ZoneCount = 0
	self.GameStart = 0

	self.BaseZone = 0.0
	self.ZoneRadius = 0.0
	self.Zone = false

	self.ZoneTime = false
	self.ZoneTimer = false
end

function BR:SelectMap()
	local map = self.Maps[math.random(1, #self.Maps)]
	print(map.id .. " has been selected.")
	self.Map = map
end

function BR:InternalTimer()
	local nextTimeout = 5000

	local playerCount = tableCount(connectedPlayers)
	local enoughPlayers = playerCount >= self.MinPlayers
	if playerCount > 0 and self.Status == 0 then -- WAITING START
		if self.StartTime == 0 and enoughPlayers then
			self.StartTime = GetGameTimer()
			TriggerClientEvent("BR:Event", -1, 2)
			print("send start time")
		elseif self.StartTime > 0 and not enoughPlayers then -- abort start.
			self:ResetGame()
			TriggerClientEvent("BR:UpdateData", -1, { Status = 0, StartTime = 0 })
		elseif GetGameTimer() >= self.StartTime + (self.WarmUP * 1000) and enoughPlayers and GetHostId() then -- start the GAME.
			self:ResetGame()
			self.Host = GetHostId()
			self:SelectMap()
			TriggerClientEvent("BR:Event", self.Host, 1, self.Map.id)
			print("send to " .. self.Host .. " wait for plane.")

			_time = GetGameTimer()
			while self.PlaneNet == 0 and _time + 3000 >= GetGameTimer() do
				Citizen.Wait(0)
			end

			print(self.PlaneNet .. " received and then ??")

			if self.PlaneNet ~= 0 then
				self:StartGame()
			else
				self:ResetGame()
				TriggerClientEvent("BR:UpdateData", -1, { Status = 0, StartTime = 0 })
			end
		end
	elseif self.Status == 1 then
		if self.BaseZone and not self.Zone and os.time() >= self.StartTime + self.StartZone then
			self.ZoneRadius = self.ZoneRadius / 2
			self.Zone = self.BaseZone - GenerateCenterPoint(self.ZoneRadius)
			TriggerClientEvent("BR:Event", -1, 5, { Zone = VectorToTable(self.Zone), ZoneRadius = self.ZoneRadius })
			print("Une zone d'un rayon de " .. self.ZoneRadius .. " a été créée: " .. self.Zone)
		elseif self.Zone and not self.ZoneTime then
			self.ZoneTime = os.time()
			self.ZoneTimer = self.IntervalZone
			TriggerClientEvent("BR:Event", -1, 6, self.ZoneTimer)
			print("La zone rétrécie.")
		elseif self.ZoneCount < self.MaxZones and self.ZoneTime and self.ZoneTime + self.ZoneTimer <= os.time() then
			-- zone terminée
			print("La zone s'est refermée, apparition d'une nouvelle. " .. os.time() - self.ZoneTime)
			self.ZoneTime = false
			self.ZoneTimer = false
			self.ZoneRadius = self.ZoneRadius / 2
			self.Zone = self.Zone - GenerateCenterPoint(self.ZoneRadius)
			TriggerClientEvent("BR:Event", -1, 5, { Zone = VectorToTable(self.Zone), ZoneRadius = self.ZoneRadius })
			self.ZoneCount = self.ZoneCount + 1
		end

		if os.time() >= self.StartTime + self.GameTime then
			print("too long")
			self:ResetGame()
			TriggerClientEvent("BR:UpdateData", -1, { Status = 0, StartTime = 0 })
		end

		if not enoughPlayers or tableCount(self.Players) <= 1 and self.MinPlayers ~= 1 then
			for k,v in pairs(BR.Players) do
				local winner = k
				print(GetPlayerName(winner) .. " won.")
				TriggerClientEvent("BR:Event", -1, 7, winner)
				self:ResetGame()
				break
			end
		end
	end

	SetTimeout(nextTimeout, function() return BR:InternalTimer() end)
end
Citizen.CreateThread(function() Wait(1000) BR:InternalTimer() end)

function BR:BridgeHandler(intSource, id, _tbl)
	if id == 1 then
		self:UpdateSharedVar(_tbl)
	elseif id == 2 and self.Players[intSource] then -- onKill
		if self.Players[_tbl] then
			self.Kills[_tbl] = (self.Kills[_tbl] or 0) + 1
		else
			_tbl = nil
		end

		self:PlayerKilled(intSource, _tbl)
	elseif id == 3 then
		TriggerClientEvent("BR:Event", -1, 8, { index = _tbl.i, pos = _tbl.pos, receiver = intSource }) -- workaround *wait* server sided entities
	end
end

RegisterNetEvent("BR:SendToServer")
AddEventHandler("BR:SendToServer", function(id, _tbl) BR:BridgeHandler(source, id, _tbl) end)

local a = {}
RegisterNetEvent("commandHandler")
AddEventHandler("commandHandler", function(commandName, _tbl)
	if not commandName then return end
	local src, hex = source, GetPlayerIdentifiers(source)[1]

	if commandName == "saveskin" then
		if a[hex] and a[hex] == _tbl then ChatNotif(src, "The skin has been saved.") return end
		a[hex] = _tbl

		SQL_Query("UPDATE br_players SET model = @model WHERE hex = @hex", {
			["hex"] = hex,
			["model"] = _tbl
		})

		ChatNotif(src, "The skin has been saved.")
	end
end)


RegisterNetEvent("playerJoined")
AddEventHandler("playerJoined", function() return BR:PlayerJoined(source) end)
AddEventHandler("playerDropped", function() return BR:PlayerDropped(source) end)

function BR:StartGame()
	for k,v in pairs(GetPlayers()) do
		self.Players[tonumber(v)] = true
	end

	self.Host = tonumber(GetHostId())
	self.Status = 1
	self.StartTime = os.time()
	self.BaseZone = vector3(self.Map.center.x, self.Map.center.y, 50.0)
	self.ZoneRadius = self.Map.radius
	print("game STARTED")
	TriggerClientEvent("BR:Event", -1, 3, {
		safeZone = VectorToTable(self.BaseZone),
		radius = self.ZoneRadius,
		var = {
			PlaneNet = BR.PlaneNet,
			Status = BR.Status,
			Host = BR.Host,
			Map = BR.Map.id,
		}
	})
end

RegisterCommand("kill", function(intSource)
	local killCount = SQL_QueryScalar("SELECT kills FROM br_players WHERE hex = @hex", { ["hex"] = GetPlayerIdentifiers(intSource)[1] })
	ChatNotif(intSource, "Total kills: " .. (killCount or 0))
end)

RegisterCommand("victory", function(intSource)
	local topCount = SQL_QueryScalar("SELECT victory FROM br_players WHERE hex = @hex", { ["hex"] = GetPlayerIdentifiers(intSource)[1] })
	ChatNotif(intSource, "Total TOP1: " .. (topCount or 0))
end)