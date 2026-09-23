-- Inventory bridge: change this file if you use a different inventory.
Bridge = {}

local QBCore = exports['qb-core']:GetCoreObject()

function Bridge.GiveJerryCan(src)
    if GetResourceState('ox_inventory') == 'started' then
        local ok = exports.ox_inventory:AddItem(src, 'WEAPON_PETROLCAN', 1)
        return ok and true or false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    local added = Player.Functions.AddItem(Config.JerryCan.item, 1)
    if added then
        local item = QBCore.Shared.Items[Config.JerryCan.item]
        if item then TriggerClientEvent('inventory:client:ItemBox', src, item, 'add') end
    end
    return added and true or false
end
