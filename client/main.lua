local QBCore = exports['qb-core']:GetCoreObject()

local CAN_HASH = joaat('WEAPON_PETROLCAN')
local AMMO_MAX = 4500.0
local AMMO_PER_LITRE = AMMO_MAX / Config.JerryCan.capacity

local pumpHashes, screens, noFuelModels = {}, {}, {}
for _, m in ipairs(Config.PumpModels) do pumpHashes[#pumpHashes + 1] = joaat(m) end
for m, v in pairs(Config.PumpScreens) do screens[joaat(m)] = v end
for _, m in ipairs(Config.NoFuelModels) do noFuelModels[joaat(m)] = true end
local texModels = {}
for _, t in ipairs(Config.PumpTextures or {}) do texModels[joaat(t.model)] = true end

-- runtime state
local S = {
    mode = 'idle',          -- idle | fuel | pour
    grade = 1, hover = nil, cursor = false,
    pump = nil, veh = nil, hasCan = false,
    unpaid = 0.0, session = 0.0, balance = 0.0, lastCharge = 0,
    canLitres = 0.0,
    summary = nil,
    nozzle = nil,
}
local touch, touchDefault = {}, Config.PumpTouch.default
for name, v in pairs(Config.PumpTouch) do
    if name ~= 'default' then touch[joaat(name)] = v end
end

local livePrices = {}
for i, g in ipairs(Config.Grades) do livePrices[i] = g.price end
local jobPrice = nil   -- set by the server when this player's job has a fixed rate

local function price() return jobPrice or livePrices[S.grade] or Config.Grades[S.grade].price end

RegisterNetEvent('as_fuel:prices', function(prices)
    if type(prices) == 'table' then livePrices = prices end
end)
local targetMode = 'keys'   -- 'ox' | 'qb' | 'keys' (set at start)
local localFuel = {}
local lastPayload = ''
local lastPush = 0

AddTextEntry('AS_FUEL_INSERT', 'Press ~INPUT_PICKUP~ to put the nozzle in the vehicle  (~INPUT_VEH_DUCK~ to put it back)')
AddTextEntry('AS_FUEL_REMOVE', 'Press ~INPUT_PICKUP~ to take the nozzle out  (~INPUT_VEH_DUCK~ to stop)')
AddTextEntry('AS_FUEL_RETURN', 'Press ~INPUT_PICKUP~ to return the nozzle')
AddTextEntry('AS_FUEL_POUR', 'Press ~INPUT_PICKUP~ to pour from the jerry can (~INPUT_VEH_DUCK~ to stop)')

-- ─────────────────────────────── Helpers ───────────────────────────────

local function notify(msg, kind)
    QBCore.Functions.Notify(msg, kind or 'primary')
end

local function sound(key)
    if not Config.Sounds.enabled then return end
    local s = Config.Sounds[key]
    if not s then return end
    PlaySoundFrontend(-1, s.name, s.set, true)
end

local function await(name, ...)
    local p = promise.new()
    QBCore.Functions.TriggerCallback(name, function(r) p:resolve(r) end, ...)
    return Citizen.Await(p)
end

local function requestControl(ent)
    if not NetworkGetEntityIsNetworked(ent) or NetworkHasControlOfEntity(ent) then return true end
    local t = GetGameTimer()
    NetworkRequestControlOfEntity(ent)
    while not NetworkHasControlOfEntity(ent) and GetGameTimer() - t < 1500 do
        Wait(0)
        NetworkRequestControlOfEntity(ent)
    end
    return NetworkHasControlOfEntity(ent)
end

local function canUseFuel(veh)
    if not DoesEntityExist(veh) then return false end
    if Config.NoFuelClasses[GetVehicleClass(veh)] then return false end
    if noFuelModels[GetEntityModel(veh)] then return false end
    return true
end

local function tankLitres(veh)
    return Config.TankSizes[GetVehicleClass(veh)] or Config.DefaultTank
end

local bigClasses = { [9] = true, [14] = true, [15] = true, [16] = true }
local function vehRange(veh)
    return bigClasses[GetVehicleClass(veh)] and Config.AircraftVehicleRange or Config.VehicleRange
end

local function getFuel(veh)
    if not DoesEntityExist(veh) then return 0.0 end
    local st = Entity(veh).state.fuel
    if st ~= nil then return st + 0.0 end
    if not localFuel[veh] then
        localFuel[veh] = math.random(Config.SpawnFuel.min, Config.SpawnFuel.max) + 0.0
    end
    return localFuel[veh]
end

local function setFuel(veh, value)
    if not DoesEntityExist(veh) then return end
    value = math.max(0.0, math.min(100.0, (value or 0.0) + 0.0))
    value = math.floor(value * 10.0 + 0.5) / 10.0
    localFuel[veh] = value
    SetVehicleFuelLevel(veh, value)
    if NetworkGetEntityIsNetworked(veh) and NetworkHasControlOfEntity(veh) then
        if Entity(veh).state.fuel ~= value then
            Entity(veh).state:set('fuel', value, true)
        end
    end
end

exports('GetFuel', getFuel)
exports('SetFuel', setFuel)

-- fuelling / pouring toggles on, and X stops it (after a short grace period)
local function shouldStop()
    return GetGameTimer() - (S.startedAt or 0) > 400 and IsControlJustPressed(0, Config.Keys.stop.id)
end

-- ─────────────────────────────── Consumption ───────────────────────────

local ranDry = {}      -- [veh] = true once a vehicle has hit 0%, until it's successfully restarted
local cranking = {}    -- [veh] = true while the one-time restart delay is playing out

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local wait = 1500

        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and canUseFuel(veh) then
            local fuel = getFuel(veh)
            wait = 1000

            if fuel > 0.0 and GetIsVehicleEngineRunning(veh) then
                local rpm = GetVehicleCurrentRpm(veh)
                local mult = Config.ClassDrain[GetVehicleClass(veh)] or 1.0
                local drain = (Config.IdleDrain + rpm * rpm * Config.RpmDrain) * mult * Config.ConsumptionMultiplier
                fuel = math.max(0.0, fuel - drain * (wait / 1000.0))
            end

            if Entity(veh).state.fuel == nil then
                -- seed the state bag for vehicles that never had one
                setFuel(veh, fuel)
            elseif math.abs(fuel - getFuel(veh)) > 0.0 then
                setFuel(veh, fuel)
            end

            if fuel <= 0.0 then
                wait = 100
                ranDry[veh] = true
                SetVehicleEngineOn(veh, false, true, true)
            elseif ranDry[veh] and not cranking[veh] and GetIsVehicleEngineRunning(veh) then
                -- first start attempt after running dry: a short crank before it catches.
                -- holds the engine off every frame for the duration, since the outer loop's
                -- own tick rate is too slow to stop a quick restart attempt on its own.
                cranking[veh] = true
                CreateThread(function()
                    local until_ = GetGameTimer() + Config.RestartDelay
                    while GetGameTimer() < until_ and DoesEntityExist(veh) do
                        SetVehicleEngineOn(veh, false, true, true)
                        Wait(0)
                    end
                    cranking[veh] = nil
                    if DoesEntityExist(veh) and getFuel(veh) > 0.0 then
                        ranDry[veh] = nil
                        if GetVehiclePedIsIn(PlayerPedId(), false) == veh then
                            SetVehicleEngineOn(veh, true, true, true)
                        end
                    end
                end)
            end
        end

        Wait(wait)
    end
end)

-- ─────────────────────────────── Pump helpers ──────────────────────────

local function scan()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)

    local best, bestDist = nil, Config.ScreenRange
    for _, hash in ipairs(pumpHashes) do
        local obj = GetClosestObjectOfType(pos.x, pos.y, pos.z, Config.ScreenRange, hash, false, false, false)
        if obj ~= 0 then
            local d = #(GetEntityCoords(obj) - pos)
            if d <= bestDist then best, bestDist = obj, d end
        end
    end

    S.pump = best
    S.near = best ~= nil and bestDist <= Config.PumpRange
    S.hasCan = GetSelectedPedWeapon(ped) == CAN_HASH
    S.veh = nil

    if ((best and S.near) or S.hasCan or S.mode == 'nozzle') and not IsPedInAnyVehicle(ped, false) then
        local v = GetClosestVehicle(pos.x, pos.y, pos.z, Config.AircraftVehicleRange, 0, 71)
        if v ~= 0 and canUseFuel(v) and #(GetEntityCoords(v) - pos) <= vehRange(v) then S.veh = v end
    end
end

local tune = nil   -- live tuner state (see /fuelscreen)

local function getScreen(model)
    if tune and tune.model == model then return tune end
    return screens[model]
end

local function drawPanel()
    local model = GetEntityModel(S.pump)
    local scr = getScreen(model)
    local center, dir, width, height

    if scr then
        center = GetOffsetFromEntityInWorldCoords(S.pump, scr.offset.x, scr.offset.y, scr.offset.z)
        local h = math.rad(GetEntityHeading(S.pump) + (scr.heading or 0.0))
        dir = vec3(-math.sin(h), math.cos(h), 0.0)
        width = scr.width or Config.Panel.width
        height = width * Config.Dui.height / Config.Dui.width

        -- only draw when the camera is in front of the screen
        local toCam = GetGameplayCamCoord() - center
        if toCam.x * dir.x + toCam.y * dir.y <= 0.0 then return end
    else
        local pc = GetEntityCoords(S.pump)
        center = vec3(pc.x, pc.y, pc.z + Config.Panel.zOffset)
        local d = GetGameplayCamCoord() - center
        local len = math.sqrt(d.x * d.x + d.y * d.y)
        if len < 0.001 then return end
        dir = vec3(d.x / len, d.y / len, 0.0)
        width = Config.Panel.width
        height = width * Config.Dui.height / Config.Dui.width
    end

    Dui.DrawQuad(center, dir, width, height)
end

local function loadAnim(dict)
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 3000 do Wait(0) end
end

-- ── nozzle: S.nozzle (local object), S.nozzlePump (pump entity), S.rope, S.nozzleIn = 'hand' | 'vehicle'

local function attachToHand(obj)
    local n, ped = Config.Nozzle, PlayerPedId()
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, n.bone), n.pos.x, n.pos.y, n.pos.z,
        n.rot.x, n.rot.y, n.rot.z, true, true, false, true, 1, true)
end

local function attachNozzleToHand()
    attachToHand(S.nozzle)
    S.nozzleIn = 'hand'
end

local capBones = { 'petrolcap', 'petroltank', 'petroltank_l', 'petroltank_r' }

local function attachToVehicle(obj, veh)
    local n = Config.Nozzle.vehicle
    local lx, ly, lz
    local bone = -1
    for _, name in ipairs(capBones) do
        bone = GetEntityBoneIndexByName(veh, name)
        if bone ~= -1 then break end
    end

    if bone ~= -1 then
        local wp = GetWorldPositionOfEntityBone(veh, bone)
        local lp = GetOffsetFromEntityGivenWorldCoords(veh, wp.x, wp.y, wp.z)
        lx, ly, lz = lp.x, lp.y, lp.z
    else
        local mn, mx = GetModelDimensions(GetEntityModel(veh))
        lx, ly, lz = mn.x, mn.y + (mx.y - mn.y) * 0.2, mn.z + (mx.z - mn.z) * 0.45
    end

    local px, py, rz = n.pos.x, n.pos.y, n.rot.z
    if lx > 0.05 then   -- cap on the right side: rotate the whole pose 180 degrees around the cap
        px, py, rz = -px, -py, rz + 180.0
    end
    AttachEntityToEntity(obj, veh, 0, lx + px, ly + py, lz + n.pos.z, n.rot.x, n.rot.y, rz,
        true, true, false, false, 2, true)
end

local function attachNozzleToVehicle(veh)
    attachToVehicle(S.nozzle, veh)
    S.nozzleIn = 'vehicle'
end

local function makeRope()
    if not Config.Nozzle.rope or not S.nozzlePump then return end
    RopeLoadTextures()
    local t = GetGameTimer()
    while not RopeAreTexturesLoaded() and GetGameTimer() - t < 2000 do Wait(0) end

    local o = Config.Nozzle.ropeOffset
    local pc = GetOffsetFromEntityInWorldCoords(S.nozzlePump, o.x, o.y, o.z)
    S.rope = AddRope(pc.x, pc.y, pc.z, 0.0, 0.0, 0.0, 3.0, 1, 1000.0, 0.0, 1.0, false, false, false, 1.0, true, 0)
    if not S.rope then return end
    ActivatePhysics(S.rope)
    Wait(100)
    local np = GetOffsetFromEntityInWorldCoords(S.nozzle, 0.0, -0.033, -0.195)
    AttachEntitiesToRope(S.rope, S.nozzlePump, S.nozzle, pc.x, pc.y, pc.z, np.x, np.y, np.z, 5.0, false, false, '', '')
end

local function clearNozzle()
    if S.rope then
        DeleteRope(S.rope)
        S.rope = nil
    end
    if S.nozzle and DoesEntityExist(S.nozzle) then
        DetachEntity(S.nozzle, true, true)
        DeleteEntity(S.nozzle)
    end
    S.nozzle, S.nozzlePump, S.nozzleIn = nil, nil, nil
end

local function playAnim()
    local a = Config.RefuelAnim
    loadAnim(a.dict)
    TaskPlayAnim(PlayerPedId(), a.dict, a.name, 2.0, 2.0, -1, 49, 0.0, false, false, false)
end

local function stopAnim()
    local a = Config.RefuelAnim
    StopAnimTask(PlayerPedId(), a.dict, a.name, 1.0)
end

-- ─────────────────────────────── Nozzle + refuel ──────────────────────

local function returnNozzle(msg)
    sound('nozzleClick')
    clearNozzle()
    S.mode = 'idle'
    lastPush = 0
    if msg then notify(msg, 'primary') end
end

-- take the nozzle from a pump (S.mode -> 'nozzle')
local function takeNozzle(pump)
    if S.mode ~= 'idle' or not pump or not DoesEntityExist(pump) then return end

    local balance, prices, job = await('as_fuel:balance')
    if type(prices) == 'table' then livePrices = prices end
    jobPrice = job
    if not balance or balance < price() then
        return notify('You cannot afford any fuel.', 'error')
    end

    local model = joaat(Config.Nozzle.model)
    RequestModel(model)
    local t = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - t < 3000 do Wait(0) end
    if not HasModelLoaded(model) then return notify('Could not load the nozzle.', 'error') end

    S.nozzle = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    SetModelAsNoLongerNeeded(model)
    S.nozzlePump = pump
    S.balance = balance
    S.summary = nil
    attachNozzleToHand()
    makeRope()
    sound('nozzleClick')
    SetCurrentPedWeapon(PlayerPedId(), joaat('WEAPON_UNARMED'), true)
    S.startedAt = GetGameTimer()
    S.mode = 'nozzle'
    lastPush = 0
    notify('Nozzle taken. Put it in a vehicle to fuel up.', 'primary')
end

-- plug the nozzle into a vehicle and start fuelling (S.mode -> 'fuel')
local function insertNozzle(veh)
    if S.mode ~= 'nozzle' or not veh or not DoesEntityExist(veh) then return end
    if not canUseFuel(veh) then return notify('This vehicle does not take fuel.', 'error') end
    if getFuel(veh) >= 99.5 then return notify('The tank is already full.', 'error') end

    local balance, prices, job = await('as_fuel:balance')
    if type(prices) == 'table' then livePrices = prices end
    jobPrice = job
    if not balance or balance < price() then
        return notify('You cannot afford any fuel.', 'error')
    end
    if not requestControl(veh) then
        return notify('Could not connect the nozzle. Try again.', 'error')
    end

    if Config.EngineOffToRefuel then SetVehicleEngineOn(veh, false, true, true) end

    S.veh = veh
    S.balance, S.session, S.lastProgress = balance, 0.0, 0
    S.rawFuel = getFuel(veh)
    S.startedAt = GetGameTimer()
    attachNozzleToVehicle(veh)
    sound('nozzleClick')
    TriggerServerEvent('as_fuel:progress', 0.0, S.grade)
    S.mode = 'fuel'
    lastPush = 0
end

-- charges once for the whole session, when fuelling ends
local function flushCharge()
    if S.session <= 0.0 then
        TriggerServerEvent('as_fuel:progress', 0.0, S.grade)   -- clears the safety-net record
        return true
    end
    local coords = S.nozzlePump and DoesEntityExist(S.nozzlePump) and GetEntityCoords(S.nozzlePump) or GetEntityCoords(PlayerPedId())
    return await('as_fuel:charge', S.session, S.grade, { x = coords.x, y = coords.y, z = coords.z })
end

-- ends fuelling. Normally the nozzle goes back to the player's hand; if they left, it snaps back to the pump.
local function stopFuel(reason)
    local ok = flushCharge()

    if S.session > 0.0 then
        S.summary = {
            litres = S.session,
            cost = math.ceil(S.session * price()),
            until_ = GetGameTimer() + 3500,
        }
    end
    if reason == 'poor' or not ok then notify('You ran out of money.', 'error')
    elseif S.session > 0.0 then sound('saleDone') end

    if reason == 'left' or not S.nozzle or not DoesEntityExist(S.nozzle) then
        clearNozzle()
        S.mode = 'idle'
    else
        attachNozzleToHand()
        S.mode = 'nozzle'
        S.startedAt = GetGameTimer()
    end
    lastPush = 0
end

local function stepFuel(dt)
    local ped = PlayerPedId()
    local veh = S.veh

    if not DoesEntityExist(veh) or not S.nozzlePump or not DoesEntityExist(S.nozzlePump) or IsEntityDead(ped) then
        return stopFuel('left')
    end

    local pumpPos = GetEntityCoords(S.nozzlePump)
    if #(pumpPos - GetEntityCoords(ped)) > Config.Nozzle.maxDistance
        or #(pumpPos - GetEntityCoords(veh)) > Config.Nozzle.maxDistance + 2.0 then
        notify('You moved too far away. The nozzle snapped back to the pump.', 'error')
        return stopFuel('left')
    end

    if shouldStop() then return stopFuel('release') end

    if targetMode == 'keys' and #(GetEntityCoords(veh) - GetEntityCoords(ped)) <= vehRange(veh) then
        BeginTextCommandDisplayHelp('AS_FUEL_REMOVE')
        EndTextCommandDisplayHelp(0, false, false, -1)
        if GetGameTimer() - (S.startedAt or 0) > 400 and IsControlJustPressed(0, Config.Keys.refuel.id) then
            return stopFuel('release')
        end
    end

    local tank = tankLitres(veh)
    local fuel = S.rawFuel or getFuel(veh)   -- our own running total, not re-read from the vehicle
    local litres = Config.FlowRate * dt
    local room = (100.0 - fuel) / 100.0 * tank
    local full = false

    if room <= 0.0 then return stopFuel('full') end
    if litres >= room then litres, full = room, true end

    if math.ceil((S.session + litres) * price()) > S.balance then
        return stopFuel('poor')
    end

    S.rawFuel = fuel + litres / tank * 100.0
    setFuel(veh, S.rawFuel)
    if math.floor(S.session + litres) > math.floor(S.session) then sound('pumpTick') end
    S.session = S.session + litres

    -- tells the server roughly how much is owed so far, purely as a safety net if this
    -- client disconnects mid-fill; it does not charge anything by itself
    if GetGameTimer() - (S.lastProgress or 0) >= 3000 then
        S.lastProgress = GetGameTimer()
        TriggerServerEvent('as_fuel:progress', S.session, S.grade)
    end

    if full then stopFuel('full') end
end

-- holding the nozzle, not fuelling yet
local function stepNozzle()
    local ped = PlayerPedId()

    if IsEntityDead(ped) or not S.nozzlePump or not DoesEntityExist(S.nozzlePump) then
        return returnNozzle()
    end

    local pumpPos = GetEntityCoords(S.nozzlePump)
    local pedPos = GetEntityCoords(ped)
    if #(pumpPos - pedPos) > Config.Nozzle.maxDistance then
        return returnNozzle('You moved too far away. The nozzle snapped back to the pump.')
    end

    for _, ctl in ipairs({ 24, 25, 37, 140, 141, 142, 257 }) do DisableControlAction(0, ctl, true) end

    if shouldStop() then return returnNozzle('You put the nozzle back.') end

    if targetMode == 'keys' then
        if S.veh then
            BeginTextCommandDisplayHelp('AS_FUEL_INSERT')
            EndTextCommandDisplayHelp(0, false, false, -1)
            if IsControlJustPressed(0, Config.Keys.refuel.id) then insertNozzle(S.veh) end
        elseif #(pumpPos - pedPos) <= Config.PumpRange + 0.5 then
            BeginTextCommandDisplayHelp('AS_FUEL_RETURN')
            EndTextCommandDisplayHelp(0, false, false, -1)
            if IsControlJustPressed(0, Config.Keys.refuel.id) then returnNozzle('You put the nozzle back.') end
        end
    end
end

-- ─────────────────────────────── Jerry can ─────────────────────────────

local function startPour()
    local ammo = GetAmmoInPedWeapon(PlayerPedId(), CAN_HASH)
    if ammo <= 0 then return notify('The jerry can is empty.', 'error') end
    if not S.veh then return end
    if getFuel(S.veh) >= 99.5 then return notify('The tank is already full.', 'error') end
    if not requestControl(S.veh) then return notify('Could not reach the vehicle.', 'error') end

    S.canLitres = ammo / AMMO_PER_LITRE
    S.startedAt = GetGameTimer()
    S.mode = 'pour'
    playAnim()
end

local function stopPour()
    stopAnim()
    S.mode = 'idle'
end

local function stepPour(dt)
    local ped = PlayerPedId()
    local veh = S.veh

    if not DoesEntityExist(veh) or GetSelectedPedWeapon(ped) ~= CAN_HASH
        or shouldStop()
        or #(GetEntityCoords(veh) - GetEntityCoords(ped)) > vehRange(veh) + 1.5 then
        return stopPour()
    end

    DisableControlAction(0, 24, true)
    DisableControlAction(0, 25, true)

    local tank = tankLitres(veh)
    local fuel = getFuel(veh)
    local room = (100.0 - fuel) / 100.0 * tank
    local litres = math.min(Config.JerryCan.flowRate * dt, S.canLitres, room)

    setFuel(veh, fuel + litres / tank * 100.0)
    S.canLitres = S.canLitres - litres
    SetPedAmmo(ped, CAN_HASH, math.max(0, math.floor(S.canLitres * AMMO_PER_LITRE + 0.5)))

    if S.canLitres <= 0.01 or litres >= room then stopPour() end
end

local function buyCan()
    local ok = await('as_fuel:buyCan')
    if ok then notify('You bought a jerry can.', 'success')
    else notify('You cannot buy a jerry can.', 'error') end
end

local function refillCan()
    local ped = PlayerPedId()
    local have = GetAmmoInPedWeapon(ped, CAN_HASH) / AMMO_PER_LITRE
    local missing = Config.JerryCan.capacity - have
    if missing < 0.5 then return notify('The jerry can is already full.', 'error') end

    local ok = await('as_fuel:charge', missing, S.grade)
    if ok then
        SetPedAmmo(ped, CAN_HASH, math.floor(AMMO_MAX))
        notify(('Jerry can refilled (%.1f L).'):format(missing), 'success')
    else
        notify('You cannot afford that.', 'error')
    end
end


-- ─────────────────────────────── Siphoning ──────────────────────────────
-- draws fuel from an unlocked vehicle's tank into a jerry can; slower than pouring, and a slice
-- of what's drawn is wasted, as the risk/reward tradeoff for stealing someone else's fuel.

local function isUnlocked(veh)
    local lock = GetVehicleDoorLockStatus(veh)
    return lock == 0 or lock == 1
end

local function startSiphon(veh)
    if not Config.Siphon.enabled then return end
    local ammo = GetAmmoInPedWeapon(PlayerPedId(), CAN_HASH)
    if ammo >= AMMO_MAX then return notify('The jerry can is already full.', 'error') end
    if not isUnlocked(veh) then return notify('That vehicle is locked.', 'error') end
    if getFuel(veh) < Config.Siphon.minFuel then return notify('That tank is basically empty.', 'error') end
    if not requestControl(veh) then return notify('Could not reach the vehicle.', 'error') end

    S.veh = veh
    S.canRoom = (AMMO_MAX - ammo) / AMMO_PER_LITRE
    S.startedAt = GetGameTimer()
    S.mode = 'siphon'
    playAnim()
    notify('Siphoning fuel...', 'primary')
end

local function stopSiphon()
    stopAnim()
    S.mode = 'idle'
end

local function stepSiphon(dt)
    local ped = PlayerPedId()
    local veh = S.veh

    if not DoesEntityExist(veh) or GetSelectedPedWeapon(ped) ~= CAN_HASH or not isUnlocked(veh)
        or shouldStop()
        or #(GetEntityCoords(veh) - GetEntityCoords(ped)) > vehRange(veh) + 1.5 then
        return stopSiphon()
    end

    DisableControlAction(0, 24, true)
    DisableControlAction(0, 25, true)

    local tank = tankLitres(veh)
    local fuel = getFuel(veh)
    if fuel <= 0.0 or S.canRoom <= 0.0 then return stopSiphon() end

    local drawn = math.min(Config.Siphon.flowRate * dt, fuel / 100.0 * tank)
    local gained = math.min(drawn * (1.0 - Config.Siphon.wastePercent), S.canRoom)

    setFuel(veh, fuel - drawn / tank * 100.0)
    S.canRoom = S.canRoom - gained
    SetPedAmmo(ped, CAN_HASH, math.min(math.floor(AMMO_MAX), GetAmmoInPedWeapon(ped, CAN_HASH) + math.floor(gained * AMMO_PER_LITRE + 0.5)))
end

local closeScreen   -- forward-declared: assigned in the pump-screen section below, used by the hazard handler above it

-- ─────────────────────────────── Pump hazard ────────────────────────────
-- Gunfire, a hard vehicle hit, or nearby explosives close to a pump can set it off. Detection
-- runs locally (each client watches its own actions near whichever pump it's near) and reports
-- to the server, which is the shared source of truth for the cooldown so it's the same for
-- everyone regardless of who caused it.

local pumpCooldowns = {}   -- [key] = GetGameTimer() value this client considers it "until"
local lastHazardReport = 0

local function pumpKeyOf(coords)
    return ('%.0f:%.0f:%.0f'):format(coords.x, coords.y, coords.z)
end

local function pumpBroken(pump)
    if not pump or not DoesEntityExist(pump) then return false end
    local until_ = pumpCooldowns[pumpKeyOf(GetEntityCoords(pump))]
    return until_ ~= nil and until_ > GetGameTimer()
end

local explosionTypes = { 0, 1, 2, 4, 6, 9, 19, 20 }  -- grenade/sticky/rpg/molotov/etc — the common "something blew up" set

local function checkPumpHazard()
    if not Config.PumpExplosion.enabled or not S.pump or not S.near then return end
    if GetGameTimer() - lastHazardReport < Config.PumpExplosion.checkEvery then return end
    lastHazardReport = GetGameTimer()

    if pumpBroken(S.pump) then return end

    local ped = PlayerPedId()
    local pumpPos = GetEntityCoords(S.pump)
    local dist = #(GetEntityCoords(ped) - pumpPos)
    if dist > Config.PumpExplosion.radius then return end

    local reason = nil
    if IsPedShooting(ped) then
        reason = 'gunfire'
    else
        for _, t in ipairs(explosionTypes) do
            if IsExplosionInSphere(t, pumpPos.x, pumpPos.y, pumpPos.z, Config.PumpExplosion.radius) then
                reason = 'explosive'
                break
            end
        end
    end

    if not reason then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
            and GetEntitySpeed(veh) >= Config.PumpExplosion.crashSpeed
            and #(GetEntityCoords(veh) - pumpPos) <= 2.0 then
            reason = 'collision'
        end
    end

    if reason then
        TriggerServerEvent('as_fuel:pumpExplode', { x = pumpPos.x, y = pumpPos.y, z = pumpPos.z }, reason)
    end
end

RegisterNetEvent('as_fuel:pumpExplode', function(coords, cooldownMs)
    local key = pumpKeyOf(coords)
    pumpCooldowns[key] = GetGameTimer() + (cooldownMs or Config.PumpExplosion.cooldown)

    -- every client renders the blast itself so it's visible everywhere, not just to whoever caused it
    AddExplosion(coords.x, coords.y, coords.z, 22, 0.85, true, false, 0.0)

    if S.pump and pumpKeyOf(GetEntityCoords(S.pump)) == key then
        if S.mode == 'screen' then closeScreen() end
        if S.mode == 'nozzle' or S.mode == 'fuel' then returnNozzle() end
        lastPush = 0
    end
end)

-- ─────────────────────────────── DUI state ─────────────────────────────

local function pushUi(now)
    if now - lastPush < 100 then return end
    lastPush = now

    local g = Config.Grades[S.grade]
    local data = {
        brand = Config.Brand, price = price(), grade = g.id, gradeLabel = g.label,
        hover = S.hover and Config.Grades[S.hover].id or nil,
        grades = Config.Grades,
    }

    if S.pump and pumpBroken(S.pump) and S.mode ~= 'fuel' then
        data.mode = 'idle'
        data.prompts = { { label = 'OUT OF SERVICE' } }
        local encoded = json.encode(data)
        if encoded ~= lastPayload then
            lastPayload = encoded
            Dui.SendAll(data)
        end
        return
    end

    if S.mode == 'fuel' then
        data.mode = 'fuel'
        data.litres = S.session
        data.cost = math.ceil(S.session * price())
        data.tank = S.veh and getFuel(S.veh) or 0
        data.prompts = { { key = Config.Keys.stop.label, label = 'Stop and take nozzle out' } }
    elseif S.mode == 'nozzle' then
        data.mode = 'idle'
        data.tank = S.veh and getFuel(S.veh) or nil
        if S.summary and now < S.summary.until_ then
            data.mode = 'done'
            data.litres = S.summary.litres
            data.cost = S.summary.cost
        end
        if targetMode == 'keys' then
            data.prompts = { { key = Config.Keys.refuel.label, label = 'Insert or return nozzle' } }
        else
            data.prompts = { { label = 'Target a vehicle to fuel it' }, { label = 'Target the pump to return the nozzle' } }
        end
        data.prompts[#data.prompts + 1] = { key = Config.Keys.stop.label, label = 'Put the nozzle back' }
    elseif S.mode == 'screen' then
        data.mode = 'idle'
        data.screen = true
        data.hoverBtn = S.hoverBtn
        data.tank = S.veh and getFuel(S.veh) or nil
        local btns = {}
        for _, b in ipairs(Config.PumpButtons) do
            local label, disabled = b.label, false
            if b.id == 'can' then
                if GetSelectedPedWeapon(PlayerPedId()) == CAN_HASH then
                    label = 'REFILL JERRY CAN'
                else
                    label = ('BUY JERRY CAN  £%d'):format(Config.JerryCan.price)
                end
            end
            btns[#btns + 1] = { id = b.id, label = label, rect = b.rect, disabled = disabled }
        end
        data.buttons = btns
    elseif S.summary and now < S.summary.until_ then
        data.mode = 'done'
        data.litres = S.summary.litres
        data.cost = S.summary.cost
    else
        data.mode = 'idle'
        data.tank = S.veh and getFuel(S.veh) or nil
        local prompts = {}
        if S.pump and not IsPedInAnyVehicle(PlayerPedId(), false) then
            if not S.near then
                prompts[1] = { label = 'Step closer to use the pump' }
            elseif targetMode == 'keys' then
                prompts[1] = { key = Config.Keys.refuel.label, label = 'Use pump' }
            else
                prompts[1] = { label = 'Target the pump to use it' }
            end
        end
        data.prompts = prompts
    end

    local encoded = json.encode(data)
    if encoded ~= lastPayload then
        lastPayload = encoded
        Dui.SendAll(data)
    end
end


-- ─────────────────────────────── Screen tuner ──────────────────────────
-- /fuelscreen  : toggle, stand next to a pump. Arrows = move (x / depth), PageUp/PageDown = height,
--                Numpad 4/6 = rotate, Numpad +/- = size, Shift = fine steps. Toggle off to print the line.

local function text2d(x, y, str)
    SetTextFont(4); SetTextScale(0.0, 0.38); SetTextColour(255, 255, 255, 255); SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

local function tuneLine()
    return ('%s = { offset = vec3(%.3f, %.3f, %.3f), heading = %.1f, width = %.3f },'):format(
        tune.name, tune.offset.x, tune.offset.y, tune.offset.z, tune.heading, tune.width)
end

local function tuneInput()
    local fine = IsControlPressed(0, 21)
    local step = fine and 0.002 or 0.01
    local o = tune.offset
    local dx, dy, dz = 0.0, 0.0, 0.0

    if IsControlPressed(0, 175) then dx = step end
    if IsControlPressed(0, 174) then dx = -step end
    if IsControlPressed(0, 172) then dy = step end
    if IsControlPressed(0, 173) then dy = -step end
    if IsControlPressed(0, 10) then dz = step end
    if IsControlPressed(0, 11) then dz = -step end
    tune.offset = vec3(o.x + dx, o.y + dy, o.z + dz)

    if IsControlPressed(0, 109) then tune.heading = tune.heading + (fine and 0.25 or 1.0) end
    if IsControlPressed(0, 108) then tune.heading = tune.heading - (fine and 0.25 or 1.0) end
    if IsControlPressed(0, 314) then tune.width = tune.width + (fine and 0.002 or 0.005) end
    if IsControlPressed(0, 315) then tune.width = math.max(0.05, tune.width - (fine and 0.002 or 0.005)) end

    text2d(0.02, 0.57, tune.touch and '~y~PUMP TOUCH TUNER~w~  align the amber outline with the top control panel'
        or '~y~FUEL SCREEN TUNER')
    text2d(0.02, 0.63, 'Arrows: move x / depth   PgUp/PgDn: height   Num4/6: rotate   Num+/-: size   Shift: fine')
    text2d(0.02, 0.66, tuneLine())
end

RegisterCommand('fuelscreen', function()
    if not Config.Tuner then return end

    if tune then
        local line = tuneLine()
        local wasTouch = tune.touch
        tune = nil
        if wasTouch then
            print('^2[as-fuel]^7 paste into Config.PumpTouch (use "default" if all pumps share the same layout):\n' .. line)
        else
            print('^2[as-fuel]^7 paste into Config.PumpScreens:\n' .. line)
        end
        notify('Tuner off. Line printed to the F8 console.', 'success')
        return
    end

    scan()
    if not S.pump then return notify('Stand next to a pump first.', 'error') end

    local model = GetEntityModel(S.pump)
    local isTex = texModels[model]
    local base = isTex and (touch[model] or touchDefault)
        or screens[model] or { offset = vec3(0.0, -0.2, 1.3), heading = 180.0, width = 0.6 }
    local name = 'this_pump_model'
    for _, n in ipairs(Config.PumpModels) do if joaat(n) == model then name = n end end

    tune = { model = model, name = name, touch = isTex and true or false, offset = base.offset, heading = base.heading or 0.0, width = base.width or 0.6 }
    notify('Tuner on. Use /fuelscreen again to finish.', 'primary')
end, false)

-- ─────────────────────────────── Hand tuner ────────────────────────────
-- /fuelnozzle : toggle. Arrows = move, PageUp/PageDown = up/down, Numpad 4/6 = rotate X,
-- Numpad 8/5 = rotate Y, Numpad 7/9 = rotate Z, Shift = fine. Toggle off to print the line.

local handTune = nil

RegisterCommand('fuelnozzle', function()
    if not Config.Tuner then return end

    if handTune then
        local n = Config.Nozzle
        print(('^2[as-fuel]^7 paste into Config.Nozzle:\n    pos = vec3(%.3f, %.3f, %.3f),\n    rot = vec3(%.1f, %.1f, %.1f),'):format(
            n.pos.x, n.pos.y, n.pos.z, n.rot.x, n.rot.y, n.rot.z))
        if handTune.own and DoesEntityExist(handTune.obj) then DeleteEntity(handTune.obj) end
        handTune = nil
        notify('Hand tuner off. Values printed to the F8 console.', 'success')
        return
    end

    local obj, own = S.nozzle, false
    if not obj then
        local model = joaat(Config.Nozzle.model)
        RequestModel(model)
        local t = GetGameTimer()
        while not HasModelLoaded(model) and GetGameTimer() - t < 3000 do Wait(0) end
        obj = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
        own = true
    end
    handTune = { obj = obj, own = own }
    attachToHand(obj)
    notify('Hand tuner on. Use /fuelnozzle again to finish.', 'primary')

    CreateThread(function()
        while handTune do
            Wait(0)
            local fine = IsControlPressed(0, 21)
            local ps, rs = fine and 0.002 or 0.01, fine and 1.0 or 5.0
            local p, r = Config.Nozzle.pos, Config.Nozzle.rot
            local dx, dy, dz, rx, ry, rz = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0

            if IsControlPressed(0, 175) then dx = ps end
            if IsControlPressed(0, 174) then dx = -ps end
            if IsControlPressed(0, 172) then dy = ps end
            if IsControlPressed(0, 173) then dy = -ps end
            if IsControlPressed(0, 10) then dz = ps end
            if IsControlPressed(0, 11) then dz = -ps end
            if IsControlPressed(0, 109) then rx = rs end
            if IsControlPressed(0, 108) then rx = -rs end
            if IsControlPressed(0, 111) then ry = rs end
            if IsControlPressed(0, 110) then ry = -rs end
            if IsControlPressed(0, 118) then rz = rs end
            if IsControlPressed(0, 117) then rz = -rs end

            if dx ~= 0.0 or dy ~= 0.0 or dz ~= 0.0 or rx ~= 0.0 or ry ~= 0.0 or rz ~= 0.0 then
                Config.Nozzle.pos = vec3(p.x + dx, p.y + dy, p.z + dz)
                Config.Nozzle.rot = vec3(r.x + rx, r.y + ry, r.z + rz)
                if DoesEntityExist(handTune.obj) then attachToHand(handTune.obj) end
            end

            local n = Config.Nozzle
            text2d(0.02, 0.57, '~y~NOZZLE HAND TUNER')
            text2d(0.02, 0.60, 'Arrows/PgUp/PgDn: move   Num 4/6: rot X   Num 8/5: rot Y   Num 7/9: rot Z   Shift: fine')
            text2d(0.02, 0.63, ('pos = vec3(%.3f, %.3f, %.3f)   rot = vec3(%.1f, %.1f, %.1f)'):format(
                n.pos.x, n.pos.y, n.pos.z, n.rot.x, n.rot.y, n.rot.z))
        end
    end)
end, false)

-- ─────────────────────────────── Vehicle tuner ─────────────────────────
-- /fuelvehicle : stand next to a car, toggle. Same keys as /fuelnozzle. Toggle off to print the line.

local vehTune = nil

RegisterCommand('fuelvehicle', function()
    if not Config.Tuner then return end

    if vehTune then
        local n = Config.Nozzle.vehicle
        print(('^2[as-fuel]^7 paste into Config.Nozzle:\n    vehicle = { pos = vec3(%.3f, %.3f, %.3f), rot = vec3(%.1f, %.1f, %.1f) },'):format(
            n.pos.x, n.pos.y, n.pos.z, n.rot.x, n.rot.y, n.rot.z))
        if DoesEntityExist(vehTune.obj) then DeleteEntity(vehTune.obj) end
        vehTune = nil
        notify('Vehicle tuner off. Values printed to the F8 console.', 'success')
        return
    end

    local pos = GetEntityCoords(PlayerPedId())
    local veh = GetClosestVehicle(pos.x, pos.y, pos.z, Config.AircraftVehicleRange, 0, 71)
    if veh == 0 then return notify('Stand next to a vehicle first.', 'error') end

    local model = joaat(Config.Nozzle.model)
    RequestModel(model)
    local t = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - t < 3000 do Wait(0) end
    local obj = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    vehTune = { obj = obj, veh = veh }
    attachToVehicle(obj, veh)
    notify('Vehicle tuner on. Use /fuelvehicle again to finish.', 'primary')

    CreateThread(function()
        while vehTune do
            Wait(0)
            local fine = IsControlPressed(0, 21)
            local ps, rs = fine and 0.005 or 0.02, fine and 1.0 or 5.0
            local p, r = Config.Nozzle.vehicle.pos, Config.Nozzle.vehicle.rot
            local dx, dy, dz, rx, ry, rz = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0

            if IsControlPressed(0, 175) then dx = ps end
            if IsControlPressed(0, 174) then dx = -ps end
            if IsControlPressed(0, 172) then dy = ps end
            if IsControlPressed(0, 173) then dy = -ps end
            if IsControlPressed(0, 10) then dz = ps end
            if IsControlPressed(0, 11) then dz = -ps end
            if IsControlPressed(0, 109) then rx = rs end
            if IsControlPressed(0, 108) then rx = -rs end
            if IsControlPressed(0, 111) then ry = rs end
            if IsControlPressed(0, 110) then ry = -rs end
            if IsControlPressed(0, 118) then rz = rs end
            if IsControlPressed(0, 117) then rz = -rs end

            if dx ~= 0.0 or dy ~= 0.0 or dz ~= 0.0 or rx ~= 0.0 or ry ~= 0.0 or rz ~= 0.0 then
                Config.Nozzle.vehicle = {
                    pos = vec3(p.x + dx, p.y + dy, p.z + dz),
                    rot = vec3(r.x + rx, r.y + ry, r.z + rz),
                }
            end
            if DoesEntityExist(vehTune.obj) and DoesEntityExist(vehTune.veh) then
                attachToVehicle(vehTune.obj, vehTune.veh)
            end

            local n = Config.Nozzle.vehicle
            text2d(0.02, 0.57, '~y~NOZZLE VEHICLE TUNER  ~w~(pose is for a LEFT-side cap, mirrored on the right)')
            text2d(0.02, 0.60, 'Arrows/PgUp/PgDn: move   Num 4/6: rot X   Num 8/5: rot Y   Num 7/9: rot Z   Shift: fine')
            text2d(0.02, 0.63, ('pos = vec3(%.3f, %.3f, %.3f)   rot = vec3(%.1f, %.1f, %.1f)'):format(
                n.pos.x, n.pos.y, n.pos.z, n.rot.x, n.rot.y, n.rot.z))
        end
    end)
end, false)

-- ─────────────────────────────── Pump screen (camera + mouse) ──────────

local RW, RH = Config.TouchRegion.w, Config.TouchRegion.h

local function getTouch(model)
    if tune and tune.touch and tune.model == model then return tune end
    return touch[model] or touchDefault
end

local function touchFrame(pump, def)
    local center = GetOffsetFromEntityInWorldCoords(pump, def.offset.x, def.offset.y, def.offset.z)
    local h = math.rad(GetEntityHeading(pump) + (def.heading or 0.0))
    local dir = vec3(-math.sin(h), math.cos(h), 0.0)
    local r = vec3(-dir.y, dir.x, 0.0)
    local w = def.width
    return center, dir, r, w, w * RH / RW
end

local function texToWorld(center, r, w, hh, tx, ty)
    return center + r * ((tx / RW - 0.5) * w) + vec3(0.0, 0.0, (0.5 - ty / RH) * hh)
end

local function screenRay(nx, ny, cam)
    local o, rot, fovDeg
    if cam then
        o, rot, fovDeg = GetCamCoord(cam), GetCamRot(cam, 2), GetCamFov(cam)
    else
        o, rot, fovDeg = GetGameplayCamCoord(), GetGameplayCamRot(2), GetGameplayCamFov()
    end
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cosx = math.abs(math.cos(rx))
    local fwd = vec3(-math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx))
    local right = vec3(fwd.y, -fwd.x, 0.0)
    local rl = math.sqrt(right.x * right.x + right.y * right.y)
    if rl < 1e-5 then return o, fwd end
    right = right / rl
    local up = vec3(right.y * fwd.z - right.z * fwd.y, right.z * fwd.x - right.x * fwd.z, right.x * fwd.y - right.y * fwd.x)

    local th = math.tan(math.rad(fovDeg) / 2.0)
    local d = fwd + right * ((nx - 0.5) * 2.0 * th * GetAspectRatio(false)) + up * (-(ny - 0.5) * 2.0 * th)
    return o, d / #d
end

local function cursorToTex(pump, def, nx, ny, cam)
    local center, dir, r, w, hh = touchFrame(pump, def)
    local o, d = screenRay(nx, ny, cam)
    local denom = d.x * dir.x + d.y * dir.y + d.z * dir.z
    if math.abs(denom) < 1e-4 then return end
    local t = ((center.x - o.x) * dir.x + (center.y - o.y) * dir.y + (center.z - o.z) * dir.z) / denom
    if t <= 0.0 then return end
    local p = o + d * t - center
    return (((p.x * r.x + p.y * r.y) / w) + 0.5) * RW, (0.5 - p.z / hh) * RH
end

local function inRect(tx, ty, r)
    return tx >= r[1] and tx <= r[3] and ty >= r[2] and ty <= r[4]
end

-- returns 'grade', index  or  'button', id
local function hitTest(tx, ty)
    for i, g in ipairs(Config.Grades) do
        for _, z in ipairs(g.zones) do
            if inRect(tx, ty, z) then return 'grade', i end
        end
    end
    for _, b in ipairs(Config.PumpButtons) do
        if inRect(tx, ty, b.rect) then return 'button', b.id end
    end
end

local function line3d(a, b, r, g, bl)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, 255)
end

local function drawTouchDebug(pump, def)
    local center, _, r, w, hh = touchFrame(pump, def)
    local function rect(x1, y1, x2, y2, cr, cg, cb)
        local a, b = texToWorld(center, r, w, hh, x1, y1), texToWorld(center, r, w, hh, x2, y1)
        local c, d = texToWorld(center, r, w, hh, x2, y2), texToWorld(center, r, w, hh, x1, y2)
        line3d(a, b, cr, cg, cb); line3d(b, c, cr, cg, cb); line3d(c, d, cr, cg, cb); line3d(d, a, cr, cg, cb)
    end
    rect(0, 0, RW, RH, 255, 176, 0)
    for _, g in ipairs(Config.Grades) do
        for _, z in ipairs(g.zones) do rect(z[1], z[2], z[3], z[4], 80, 220, 255) end
    end
    for _, b in ipairs(Config.PumpButtons) do
        rect(b.rect[1], b.rect[2], b.rect[3], b.rect[4], 90, 255, 120)
    end
end

local function driving() return IsPedInAnyVehicle(PlayerPedId(), false) end
local function idleOnFoot() return S.mode == 'idle' and not driving() end
local function holdingCan() return GetSelectedPedWeapon(PlayerPedId()) == CAN_HASH end

local function refreshFor(pump)
    scan()
    if pump and DoesEntityExist(pump) then S.pump, S.near = pump, true end
    if not S.veh then
        local pos = GetEntityCoords(PlayerPedId())
        local v = GetClosestVehicle(pos.x, pos.y, pos.z, Config.AircraftVehicleRange, 0, 71)
        if v ~= 0 and canUseFuel(v) and #(GetEntityCoords(v) - pos) <= vehRange(v) then S.veh = v end
    end
end

local function selectGrade(i)
    local g = Config.Grades[i]
    S.grade, lastPush = i, 0
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    notify(('Selected %s  (£%.2f/L)'):format(g.label, g.price), 'success')
end

local screenCam

closeScreen = function()
    RenderScriptCams(false, true, 500, true, false)
    if screenCam then DestroyCam(screenCam, false) end
    screenCam = nil
    FreezeEntityPosition(PlayerPedId(), false)
    S.mode, S.hover, S.hoverBtn = 'idle', nil, nil
    lastPush = 0
    TriggerEvent('as-fuel:screen', false)   -- hook for HUD scripts to show themselves again
end

local function openScreen(entity)
    if not idleOnFoot() then return end
    refreshFor(entity)
    if not S.pump then return end
    if pumpBroken(S.pump) then return notify('That pump is out of service.', 'error') end

    local model = GetEntityModel(S.pump)
    if not texModels[model] then
        -- pumps without a texture screen: take the nozzle straight away with the current grade
        return takeNozzle(S.pump)
    end

    local center, dir, _, w = touchFrame(S.pump, getTouch(model))
    local fov = Config.Screen.fov
    local dist = w / (Config.Screen.fill * 2.0 * math.tan(math.rad(fov) / 2.0) * GetAspectRatio(false))
    local pos = center + dir * dist

    screenCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(screenCam, pos.x, pos.y, pos.z)
    PointCamAtCoord(screenCam, center.x, center.y, center.z)
    SetCamFov(screenCam, fov)
    SetCamActive(screenCam, true)
    RenderScriptCams(true, true, 700, true, false)

    FreezeEntityPosition(PlayerPedId(), true)
    S.mode, S.startedAt, S.hover, S.hoverBtn = 'screen', GetGameTimer(), nil, nil
    TriggerEvent('as-fuel:screen', true)    -- hook for HUD scripts to hide themselves
end

local function stepScreen()
    local ped = PlayerPedId()
    DisableAllControlActions(0)
    SetMouseCursorActiveThisFrame()
    HideHudAndRadarThisFrame()
    SetEntityLocallyInvisible(ped)

    if IsEntityDead(ped) or not S.pump or not DoesEntityExist(S.pump) then return closeScreen() end
    if IsDisabledControlJustPressed(0, 177) then return closeScreen() end   -- backspace / right click

    S.hover, S.hoverBtn = nil, nil
    if GetGameTimer() - S.startedAt < 800 then return end   -- camera is still moving in

    local model = GetEntityModel(S.pump)
    local tx, ty = cursorToTex(S.pump, getTouch(model),
        GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240), screenCam)
    if not tx then return end

    local kind, id = hitTest(tx, ty)
    if kind == 'grade' then S.hover = id elseif kind == 'button' then S.hoverBtn = id end

    if kind and IsDisabledControlJustPressed(0, 24) then
        if kind == 'grade' then
            if S.grade ~= id then selectGrade(id) end
        elseif id == 'fuel' then
            closeScreen()
            takeNozzle(S.pump)
        elseif id == 'can' then
            if holdingCan() then refillCan() else buyCan() end
        elseif id == 'exit' then
            closeScreen()
        end
    end
end

-- ─────────────────────────────── Targeting (ox_target / qb-target) ─────

local function detectTarget()
    local pref = Config.Target
    if pref == 'ox' or pref == 'auto' then
        if GetResourceState('ox_target') == 'started' then return 'ox' end
    end
    if pref == 'qb' or pref == 'auto' then
        if GetResourceState('qb-target') == 'started' then return 'qb' end
    end
    return 'keys'
end

-- one table of actions, shared by both target systems
local pumpActions = {
    {
        name = 'as_fuel_use', label = 'Use pump',
        can = idleOnFoot,
        run = function(entity) CreateThread(function() openScreen(entity) end) end,
    },
    {
        name = 'as_fuel_return', label = 'Return nozzle',
        can = function() return (S.mode == 'nozzle' or S.mode == 'fuel') and not driving() end,
        run = function()
            CreateThread(function()
                if S.mode == 'fuel' then stopFuel('release') end
                returnNozzle('You put the nozzle back.')
            end)
        end,
    },
}
local vehicleActions = {
    {
        name = 'as_fuel_siphon', label = 'Siphon fuel',
        can = function(entity)
            return Config.Siphon.enabled and idleOnFoot() and holdingCan() and canUseFuel(entity)
                and isUnlocked(entity) and getFuel(entity) >= Config.Siphon.minFuel
                and GetAmmoInPedWeapon(PlayerPedId(), CAN_HASH) < AMMO_MAX
        end,
        run = function(entity) CreateThread(function() startSiphon(entity) end) end,
    },
    {
        name = 'as_fuel_remove', label = 'Take nozzle out',
        can = function(entity) return S.mode == 'fuel' and entity == S.veh end,
        run = function() CreateThread(function() stopFuel('release') end) end,
    },
    {
        name = 'as_fuel_insert', label = 'Put nozzle in vehicle',
        can = function(entity) return S.mode == 'nozzle' and not driving() and canUseFuel(entity) end,
        run = function(entity) CreateThread(function() insertNozzle(entity) end) end,
    },
    {
        name = 'as_fuel_pour', label = 'Pour jerry can into tank',
        can = function(entity)
            return idleOnFoot() and holdingCan() and canUseFuel(entity)
                and GetAmmoInPedWeapon(PlayerPedId(), CAN_HASH) > 0
        end,
        run = function(entity)
            CreateThread(function()
                S.veh, S.hasCan = entity, true
                startPour()
            end)
        end,
    },
}

local registered = nil

local function unregisterTargets()
    if registered == 'ox' and GetResourceState('ox_target') == 'started' then
        local p, v = {}, {}
        for _, a in ipairs(pumpActions) do p[#p + 1] = a.name end
        for _, a in ipairs(vehicleActions) do v[#v + 1] = a.name end
        exports.ox_target:removeModel(pumpHashes, p)
        exports.ox_target:removeGlobalVehicle(v)
    elseif registered == 'qb' and GetResourceState('qb-target') == 'started' then
        local p, v = {}, {}
        for _, a in ipairs(pumpActions) do p[#p + 1] = a.label end
        for _, a in ipairs(vehicleActions) do v[#v + 1] = a.label end
        exports['qb-target']:RemoveTargetModel(pumpHashes, p)
        exports['qb-target']:RemoveGlobalVehicle(v)
    end
    registered = nil
end

local function registerTargets()
    unregisterTargets()
    targetMode = detectTarget()

    if targetMode == 'ox' then
        local function convert(list)
            local out = {}
            for _, a in ipairs(list) do
                out[#out + 1] = {
                    name = a.name, label = a.label, icon = 'fa-solid fa-gas-pump',
                    distance = Config.TargetDistance,
                    canInteract = function(entity) return a.can(entity) end,
                    onSelect = function(data) a.run(data.entity) end,
                }
            end
            return out
        end
        exports.ox_target:addModel(pumpHashes, convert(pumpActions))
        exports.ox_target:addGlobalVehicle(convert(vehicleActions))
        registered = 'ox'
    elseif targetMode == 'qb' then
        local function convert(list)
            local out = {}
            for _, a in ipairs(list) do
                out[#out + 1] = {
                    type = 'client', icon = 'fas fa-gas-pump', label = a.label,
                    canInteract = function(entity) return a.can(entity) end,
                    action = function(entity) a.run(entity) end,
                }
            end
            return out
        end
        exports['qb-target']:AddTargetModel(pumpHashes, { options = convert(pumpActions), distance = Config.TargetDistance })
        exports['qb-target']:AddGlobalVehicle({ options = convert(vehicleActions), distance = Config.TargetDistance })
        registered = 'qb'
    end

    print(('^2[as-fuel]^7 interaction mode: %s'):format(targetMode))
end

CreateThread(function()
    Wait(1000)
    registerTargets()
end)

AddEventHandler('onClientResourceStart', function(res)
    if res == 'ox_target' or res == 'qb-target' then
        Wait(500)
        registerTargets()
    end
end)

-- ─────────────────────────────── Main loop ─────────────────────────────

CreateThread(function()
    local nextScan = 0

    while true do
        local now = GetGameTimer()
        local ped = PlayerPedId()

        if (S.mode == 'idle' or S.mode == 'nozzle') and now >= nextScan then
            scan()
            nextScan = now + 400
        end

        local inVeh = IsPedInAnyVehicle(ped, false)
        local active = not inVeh and (S.pump ~= nil or (S.hasCan and S.veh ~= nil)
            or S.mode == 'nozzle' or S.mode == 'fuel' or S.mode == 'siphon')

        if active then
            local dt = GetFrameTime()
            if tune then tuneInput() end

            if S.mode == 'nozzle' or S.mode == 'fuel' then pushUi(now) end

            if S.pump then
                pushUi(now)
                checkPumpHazard()
                if tune and tune.touch then
                    drawTouchDebug(S.pump, tune)
                elseif tune or not texModels[GetEntityModel(S.pump)] then
                    Dui.Init()
                    drawPanel()
                end
            end

            if S.mode == 'fuel' then
                stepFuel(dt)
            elseif S.mode == 'pour' then
                stepPour(dt)
            elseif S.mode == 'siphon' then
                stepSiphon(dt)
            elseif S.mode == 'screen' then
                stepScreen()
            elseif S.mode == 'nozzle' then
                stepNozzle()
            elseif targetMode == 'keys' then
                if S.pump and S.near then
                    if IsControlJustPressed(0, Config.Keys.refuel.id) then openScreen(S.pump) end
                elseif S.hasCan and S.veh then
                    BeginTextCommandDisplayHelp('AS_FUEL_POUR')
                    EndTextCommandDisplayHelp(0, false, false, -1)
                    if IsControlJustPressed(0, Config.Keys.refuel.id) then startPour() end
                end
            end
            Wait(0)
        else
            if S.mode == 'fuel' then stopFuel('left')
            elseif S.mode == 'pour' then stopPour()
            elseif S.mode == 'siphon' then stopSiphon()
            elseif S.mode == 'screen' then closeScreen()
            elseif S.mode == 'nozzle' then returnNozzle('You put the nozzle back.') end
            pushUi(now)
            Wait(inVeh and 800 or 300)
        end
    end
end)

-- ─────────────────────────────── Blips ─────────────────────────────────

CreateThread(function()
    if not Config.Blips.enabled then return end
    for _, pos in ipairs(Config.Stations) do
        local blip = AddBlipForCoord(pos.x, pos.y, pos.z)
        SetBlipSprite(blip, Config.Blips.sprite)
        SetBlipColour(blip, Config.Blips.colour)
        SetBlipScale(blip, Config.Blips.scale)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Config.Blips.label)
        EndTextCommandSetBlipName(blip)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    unregisterTargets()
    if S.mode == 'screen' then closeScreen() end
    clearNozzle()
end)
