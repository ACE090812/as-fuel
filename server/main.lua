local QBCore = exports['qb-core']:GetCoreObject()

local pending = {}   -- [source] = { litres, gradeIdx } — best-effort record for the disconnect safety net

local function getMoney(Player)
    return Player.PlayerData.money[Config.PayAccount] or 0
end

-- ─────────────────────────────── Pricing ────────────────────────────────
-- livePrices drifts slowly around each grade's base price; this table is the source of truth
-- for what a player is actually charged. A job in Config.JobPrices overrides it entirely.

local livePrices = {}
for i, g in ipairs(Config.Grades) do livePrices[i] = g.price end

local function jobOverride(Player)
    local job = Player.PlayerData.job and Player.PlayerData.job.name
    if not job then return nil end
    local p = Config.JobPrices[job]
    if p == false or p == nil then return nil end
    return tonumber(p)
end

-- the price this player actually pays per litre for this grade, right now
local function priceFor(Player, gradeIdx)
    local override = jobOverride(Player)
    if override then return override end
    return livePrices[tonumber(gradeIdx) or 1] or livePrices[1]
end

local function broadcastPrices()
    TriggerClientEvent('as_fuel:prices', -1, livePrices)
end

if Config.PriceDrift.enabled then
    CreateThread(function()
        while true do
            Wait(Config.PriceDrift.interval)
            for i, g in ipairs(Config.Grades) do
                local step = g.price * Config.PriceDrift.stepPercent
                local delta = (math.random() * 2.0 - 1.0) * step
                local lo, hi = g.price * (1.0 - Config.PriceDrift.bandPercent), g.price * (1.0 + Config.PriceDrift.bandPercent)
                livePrices[i] = math.max(lo, math.min(hi, livePrices[i] + delta))
            end
            broadcastPrices()
        end
    end)
end

QBCore.Functions.CreateCallback('as_fuel:balance', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(0, livePrices) end
    cb(getMoney(Player), livePrices, jobOverride(Player))
end)

AddEventHandler('playerJoined', function()
    TriggerClientEvent('as_fuel:prices', source, livePrices)
end)

-- ─────────────────────────────── Discord webhook ────────────────────────

local function logPurchase(Player, litres, grade, amount, coords)
    if not Config.Webhook.url or Config.Webhook.url == '' then return end

    local charinfo = Player.PlayerData.charinfo or {}
    local name = (charinfo.firstname or '?') .. ' ' .. (charinfo.lastname or '?')
    local loc = coords and ('%.1f, %.1f, %.1f'):format(coords.x or 0.0, coords.y or 0.0, coords.z or 0.0) or 'unknown'

    PerformHttpRequest(Config.Webhook.url, function() end, 'POST', json.encode({
        username = Config.Webhook.username,
        embeds = { {
            title = 'Fuel purchase',
            color = Config.Webhook.color,
            fields = {
                { name = 'Player', value = ('%s (%s)'):format(name, Player.PlayerData.citizenid or '?'), inline = true },
                { name = 'Grade', value = grade.label, inline = true },
                { name = 'Litres', value = ('%.1f L'):format(litres), inline = true },
                { name = 'Cost', value = ('£%d'):format(amount), inline = true },
                { name = 'Location', value = loc, inline = true },
            },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        } },
    }), { ['Content-Type'] = 'application/json' })
end

-- ─────────────────────────────── Charging ───────────────────────────────

-- Charges once, for the full amount of fuel taken in one session.
QBCore.Functions.CreateCallback('as_fuel:charge', function(source, cb, litres, gradeIdx, coords)
    pending[source] = nil   -- this charge supersedes whatever the safety net had recorded

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(false) end

    litres = tonumber(litres) or 0.0
    if litres <= 0.0 or litres > 500.0 then return cb(true) end

    local grade = Config.Grades[tonumber(gradeIdx) or 1] or Config.Grades[1]
    local perLitre = priceFor(Player, gradeIdx)
    local amount = math.ceil(litres * perLitre - 1e-6)
    if amount <= 0 then return cb(true) end

    if getMoney(Player) < amount then return cb(false) end

    Player.Functions.RemoveMoney(Config.PayAccount, amount, 'fuel')
    logPurchase(Player, litres, grade, amount, coords)
    cb(true)
end)

-- Safety net: while fuelling, the client pings its running total every few seconds (no money
-- changes hands here). If the client vanishes mid-fill — crash, disconnect, /relog — this is
-- what the disconnect handler below charges for, so a dropped connection isn't free fuel.
RegisterNetEvent('as_fuel:progress', function(litres, gradeIdx)
    local source = source
    litres = tonumber(litres) or 0.0
    if litres <= 0.0 then
        pending[source] = nil
        return
    end
    if litres > 500.0 then return end
    pending[source] = { litres = litres, gradeIdx = tonumber(gradeIdx) or 1 }
end)

AddEventHandler('playerDropped', function()
    local source = source
    local p = pending[source]
    pending[source] = nil
    if not p then return end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local perLitre = priceFor(Player, p.gradeIdx)
    local amount = math.min(math.ceil(p.litres * perLitre - 1e-6), getMoney(Player))
    if amount > 0 then
        Player.Functions.RemoveMoney(Config.PayAccount, amount, 'fuel (disconnect)')
    end
end)

QBCore.Functions.CreateCallback('as_fuel:buyCan', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(false) end

    local price = Config.JerryCan.price
    if getMoney(Player) < price then return cb(false) end

    if not Bridge.GiveJerryCan(source) then return cb(false) end
    Player.Functions.RemoveMoney(Config.PayAccount, price, 'jerry-can')
    cb(true)
end)

-- ─────────────────────────────── Pump hazard ────────────────────────────
-- Clients detect the trigger (gunfire/collision/fire near a pump) themselves and report it here.
-- This is the shared source of truth for which pumps are on cooldown, keyed by rounded world
-- coords since map-placed pumps aren't networked entities with a shared id.

local pumpCooldowns = {}   -- [key] = gameTimer-style timestamp this server considers it "until"

local function pumpKey(coords)
    return ('%.0f:%.0f:%.0f'):format(coords.x, coords.y, coords.z)
end

RegisterNetEvent('as_fuel:pumpExplode', function(coords, reason)
    if not Config.PumpExplosion.enabled then return end
    if type(coords) ~= 'table' or not coords.x then return end

    local key = pumpKey(coords)
    local now = GetGameTimer()
    if pumpCooldowns[key] and pumpCooldowns[key] > now then return end   -- already on cooldown, ignore repeats

    pumpCooldowns[key] = now + Config.PumpExplosion.cooldown
    TriggerClientEvent('as_fuel:pumpExplode', -1, coords, Config.PumpExplosion.cooldown)
end)
