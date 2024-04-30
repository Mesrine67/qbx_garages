local config = require 'config.server'
local sharedConfig = require 'config.shared'
local VEHICLES = exports.qbx_core:GetVehiclesByName()
local outsideVehicles = {}

---@alias VehicleEntity table

---@param source number
---@param garage string
---@param type GarageType
---@param category VehicleType
---@return VehicleEntity[] | false
lib.callback.register('qb-garage:server:GetGarageVehicles', function(source, garage, type, category)
    local player = exports.qbx_core:GetPlayer(source)
    if type == GarageType.PUBLIC then -- Public garages give player cars in the garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ?', {player.PlayerData.citizenid, garage})
        return result[1] and result
    elseif type == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND state = ?', {player.PlayerData.citizenid, 0})
        local toSend = {}
        if not result[1] then return false end
        for _, vehicle in pairs(result) do -- Check vehicle type against depot type
            if not outsideVehicles[vehicle.id] or not DoesEntityExist(outsideVehicles[vehicle.id].entity) then
                if (category == VehicleType.AIR and (VEHICLES[vehicle.vehicle].category == 'helicopters' or VEHICLES[vehicle.vehicle].category == 'planes')) or
                   (category == VehicleType.SEA and VEHICLES[vehicle.vehicle].category == 'boats') or
                   (category == VehicleType.CAR and VEHICLES[vehicle.vehicle].category ~= 'helicopters' and VEHICLES[vehicle.vehicle].category ~= 'planes' and VEHICLES[vehicle.vehicle].category ~= 'boats') then
                    toSend[#toSend + 1] = vehicle
                end
            end
        end
        return toSend
    else -- House give all cars in the garage, Job and Gang depend of config
        local shared = config.sharedGarages and type ~= 'house' and '' or " AND citizenid = '"..player.PlayerData.citizenid.."'"
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ?'..shared, {garage, VehicleState.GARAGED})
        return result[1] and result
    end
end)

---@param source number
---@param garage string
---@param type GarageType
---@param plate string
---@return VehicleEntity
local function validateGarageVehicle(source, garage, type, plate)
    local player = exports.qbx_core:GetPlayer(source)
    if type == GarageType.PUBLIC then -- Public garages give player cars in the garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ? AND state = ? AND plate = ?', {player.PlayerData.citizenid, garage, VehicleState.GARAGED, plate})
        return result[1]
    elseif type == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND (state = ? OR state = ?) AND plate = ?', {player.PlayerData.citizenid, VehicleState.OUT, VehicleState.IMPOUNDED, plate})
        return result[1]
    else
        local shared = config.sharedGarages and type ~= 'house' and '' or " AND citizenid = '"..player.PlayerData.citizenid.."'"
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ? AND plate = ?'..shared, {garage, VehicleState.OUT, plate})
        return result[1]
    end
end

---@param source number
---@param plate string
---@param type GarageType
---@param garage string
---@param gang string
---@return VehicleEntity | boolean
local function checkOwnership(source, plate, type, garage, gang)
    local player = exports.qbx_core:GetPlayer(source)
    if type == GarageType.PUBLIC then -- Public garages only for player cars
         local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', {plate, player.PlayerData.citizenid})
         return result[1] or false
    elseif type == 'house' then -- House garages only for player cars that have keys of the house
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate = ?', {plate})
        return result[1] and exports['qb-houses']:hasKey(result[1].license, result[1].citizenid, garage)
    elseif type == GarageType.GANG then -- Gang garages only for gang members cars (for sharing)
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate = ?', {plate})
        if not result[1] then return false end
        -- Check if found owner is part of the gang
        local resultplayer = MySQL.single.await('SELECT * FROM players WHERE citizenid = ?', { result[1].citizenid })
        if not resultplayer then return false end
        return json.decode(resultplayer.gang)?.name == gang
    else -- Job garages only for cars that are owned by someone (for sharing and service) or only by player depending of config
        local shared = config.sharedGarages and '' or " AND citizenid = '"..player.PlayerData.citizenid.."'"
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate = ?'..shared, {plate})
        return result[1]
    end
end

lib.callback.register('qb-garage:server:checkOwnership', checkOwnership)

---@param source number
---@param vehicleEntity VehicleEntity
---@param coords vector4
---@param garageType GarageType
---@return number? netId
lib.callback.register('qb-garage:server:spawnvehicle', function (source, vehicleEntity, coords, garageType)
    local props = {}

    local result = MySQL.query.await('SELECT id, mods FROM player_vehicles WHERE plate = ?', {vehicleEntity.plate})

    if result[1] then
        if garageType == GarageType.DEPOT and (not outsideVehicles[result[1].id] or not DoesEntityExist(outsideVehicles[result[1].id].entity)) then -- If depot, check if vehicle is not already spawned on the map
            exports.qbx_core:Notify(source, Lang:t('error.not_impound'), 'error', 5000)
            return
        end
        props = json.decode(result[1].mods)
    end

    local warpPed = sharedConfig.takeOut.warpInVehicle and GetPlayerPed(source)
    local netId = qbx.spawnVehicle({ spawnSource = coords, model = vehicleEntity.vehicle, props = props, warp = warpPed})

    local veh = NetworkGetEntityFromNetworkId(netId)

    if sharedConfig.takeOut.doorsLocked then
        SetVehicleDoorsLocked(veh, 2)
    end

    TriggerClientEvent('vehiclekeys:client:SetOwner', source, vehicleEntity.plate)

    Entity(veh).state:set('vehicleid', result[1].id, false)
    outsideVehicles[result[1].id] = {netID = netId, entity = veh}
    return netId
end)

---@param source number
---@param netId number
---@param props table ox_lib vehicle props https://github.com/overextended/ox_lib/blob/master/resource/vehicleProperties/client.lua#L3
---@param garage string
---@param type GarageType
---@param gang string
lib.callback.register('qbx_garages:server:parkVehicle', function(source, netId, props, garage, type, gang)
    local owned = checkOwnership(source, props.plate, type, garage, gang) --Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    if type ~= 'house' and not sharedConfig.garages[garage] then return end

    MySQL.update('UPDATE player_vehicles SET state = ?, garage = ?, fuel = ?, engine = ?, body = ?, mods = ? WHERE plate = ?', {VehicleState.GARAGED, garage, props.fuelLevel, props.engineHealth, props.bodyHealth, json.encode(props), props.plate})

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local vehicleId = Entity(vehicle).state.vehicleid
    if vehicleId then
        outsideVehicles[vehicleId] = nil
    end
    DeleteEntity(vehicle)
end)

---@param state VehicleState
---@param plate string
---@param garage string
RegisterNetEvent('qb-garage:server:updateVehicleState', function(state, plate, garage)
    local type
    if sharedConfig.garages[garage] then
        type = sharedConfig.garages[garage].type
    else
        type = 'house'
    end

    local owned = validateGarageVehicle(source, garage, type, plate) -- Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    if state ~= VehicleState.OUT then return end -- Check state value

    local carInfo = MySQL.single.await('SELECT vehicle, depotprice FROM player_vehicles WHERE plate = ?', {plate})
    if not carInfo then return end

    local vehCost = VEHICLES[carInfo.vehicle].price
    local newPrice = qbx.math.round(vehCost * (config.impoundFee.percentage / 100))
    if config.impoundFee.enable then
        if carInfo.depotprice ~= newPrice then
            MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = ? WHERE plate = ?', {state, newPrice, plate})
        else
            MySQL.update('UPDATE player_vehicles SET state = ? WHERE plate = ?', {state, plate})
        end
    else
        MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = 0 WHERE plate = ?', {state, plate})
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)
    if not config.autoRespawn then return end

    MySQL.update('UPDATE player_vehicles SET state = ? WHERE state = ?', {VehicleState.GARAGED, VehicleState.OUT})
end)

---@param data {vehicle: VehicleEntity, garageInfo: GarageConfig, garageName: string}
RegisterNetEvent('qb-garage:server:PayDepotPrice', function(data)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    local cashBalance = player.PlayerData.money.cash
    local bankBalance = player.PlayerData.money.bank
    local vehicle = data.vehicle

    MySQL.query('SELECT * FROM player_vehicles WHERE plate = ?', {vehicle.plate}, function(result)
        if result[1] then
            if cashBalance >= result[1].depotprice then
                player.Functions.RemoveMoney('cash', result[1].depotprice, 'paid-depot')
                TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
            elseif bankBalance >= result[1].depotprice then
                player.Functions.RemoveMoney('bank', result[1].depotprice, 'paid-depot')
                TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
            else
                exports.qbx_core:Notify(src, Lang:t('error.not_enough'), 'error')
            end
        end
    end)
end)