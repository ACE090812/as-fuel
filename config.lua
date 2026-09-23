Config = {}

-- ─────────────────────────────── General ───────────────────────────────
Config.Brand      = 'ACE Studios'
Config.PayAccount = 'cash'      -- 'cash' or 'bank'
Config.FlowRate   = 2.0         -- litres per second at the pump

Config.Keys = {
    refuel = { id = 38, label = 'E' },   -- INPUT_PICKUP: 'keys' mode only (opens the pump screen / pours a jerry can)
    stop   = { id = 73, label = 'X' },   -- INPUT_VEH_DUCK: stops refuelling / pouring
}

-- Interaction style:
--   'auto' = ox_target if running, else qb-target if running, else 'keys' (press E at the pump)
--   'ox' / 'qb' = force one target system, 'keys' = no target system
-- Third-eye the pump, pick "Use pump" and the camera moves onto the pump screen.
Config.Target         = 'auto'
Config.TargetDistance = 2.0   -- keep below Config.PumpRange

-- Camera used while looking at the pump screen
Config.Screen = { fov = 35.0, fill = 0.85 }   -- fill = how much of the screen width the panel covers

-- Clickable buttons drawn on the pump's left panel (rects are in original texture pixels).
-- Keep these in sync with the space available in html/pump.html.
Config.PumpButtons = {
    { id = 'fuel', label = 'TAKE NOZZLE', rect = { 12,  72, 138,  88 } },
    { id = 'can',  label = 'JERRY CAN',    rect = { 12,  90, 138, 106 } },
    { id = 'exit', label = 'EXIT',         rect = { 12, 108, 138, 124 } },
}


-- Fuel grades. zones are clickable rectangles in ORIGINAL pump texture pixels (512x512) that
-- select the grade: [1] the coloured button, [2] the Regular/Plus/Premium strip below it.
Config.Grades = {
    { id = 'regular', label = 'REGULAR', price = 3.5, zones = { { 150, 94, 178, 127 }, {   0, 135, 128, 160 } } },
    { id = 'plus',    label = 'PLUS',    price = 4.2, zones = { { 196, 94, 224, 127 }, { 128, 135, 252, 160 } } },
    { id = 'premium', label = 'PREMIUM', price = 5.0, zones = { { 242, 94, 270, 127 }, { 252, 135, 370, 160 } } },
}

Config.PumpRange           = 2.2   -- how close the player must be to use a pump
Config.ScreenRange         = 6.0   -- how close before the pump screen is drawn
Config.VehicleRange        = 4.5   -- how close the vehicle must be to the player
Config.AircraftVehicleRange = 9.0  -- used instead of VehicleRange for boats/helis/planes/off-road (bigger vehicles)
Config.EngineOffToRefuel   = true  -- switch the engine off when the nozzle goes in
Config.RefuelAnim          = { dict = 'timetable@gardener@filling_can', name = 'gar_ig_5_filling_can' }
Config.RestartDelay        = 2500  -- ms of "cranking" the first time the engine restarts after running dry

-- ─────────────────────────────── Pricing ────────────────────────────────
-- The server drifts each grade's price slowly over time, wandering within a band around the
-- base price set in Config.Grades above. Silent — nothing is announced, it just shows on the pump.
Config.PriceDrift = {
    enabled      = true,
    interval     = 10 * 60 * 1000,  -- how often the price can move (ms)
    stepPercent  = 0.03,            -- max change per tick, as a fraction of the base price
    bandPercent  = 0.15,            -- price is kept within +/- this fraction of the base price
}

-- Per-job pricing. A job listed here pays this price per litre for EVERY grade, ignoring both
-- the grade price and the drift above. Remove a job, or set its price to false, to charge it
-- normally. This does not need ox_target/qb-target — it works with any interaction mode.
Config.JobPrices = {
    police    = 0.0,   -- free fuel for police
    ambulance = 0.0,   -- free fuel for EMS
    -- mechanic = 2.00,
}

-- ─────────────────────────────── Consumption ───────────────────────────
Config.ConsumptionMultiplier = 1.0
Config.IdleDrain = 0.010        -- % of tank per second with the engine idling
Config.RpmDrain  = 0.090        -- extra % per second at full RPM (scaled by rpm^2)
Config.SpawnFuel = { min = 35, max = 85 }  -- random level for vehicles with no fuel state yet

-- tank size in litres per vehicle class (used to convert litres <-> %)
Config.DefaultTank = 60.0
Config.TankSizes = {
    [0] = 50.0,  -- compacts
    [1] = 65.0,  -- sedans
    [2] = 80.0,  -- SUVs
    [3] = 60.0,  -- coupes
    [4] = 70.0,  -- muscle
    [5] = 60.0,  -- sports classics
    [6] = 65.0,  -- sports
    [7] = 70.0,  -- super
    [8] = 15.0,  -- motorcycles
    [9] = 90.0,  -- off-road
    [10] = 120.0, -- industrial
    [11] = 90.0, -- utility
    [12] = 80.0, -- vans
    [14] = 200.0, -- boats
    [15] = 300.0, -- helicopters
    [16] = 500.0, -- planes
    [17] = 80.0, -- service
    [18] = 80.0, -- emergency
    [19] = 120.0, -- military
    [20] = 300.0, -- commercial
}

-- drain multiplier per class (optional)
Config.ClassDrain = {
    [8]  = 0.6,
    [10] = 1.6,
    [20] = 1.8,
    [15] = 2.0,
    [16] = 2.5,
}

Config.NoFuelClasses = { [13] = true }  -- 13 = cycles
Config.NoFuelModels  = {                -- model names that never use fuel
    -- 'my_custom_vehicle',
}

-- ─────────────────────────────── Jerry can ─────────────────────────────
Config.JerryCan = {
    price    = 40,      -- price of a new can (item / weapon given by server/bridge.lua)
    capacity = 20.0,    -- litres
    flowRate = 1.5,     -- litres per second when pouring into a vehicle
    item     = 'weapon_petrolcan',   -- QB item name (ox_inventory uses WEAPON_PETROLCAN)
}

-- Siphoning fuel out of someone else's UNLOCKED vehicle into your jerry can. Slower than a
-- normal pour, and a slice of what you draw is wasted (spilled) as a risk/reward penalty.
Config.Siphon = {
    enabled      = true,
    flowRate     = 0.7,    -- litres per second drawn from the vehicle's tank
    wastePercent = 0.15,   -- fraction of what's drawn that's lost and never reaches the can
    minFuel      = 1.0,    -- vehicle needs at least this much fuel (%) to bother siphoning
}

-- ─────────────────────────────── Pump hazard ────────────────────────────
-- Gunfire, a hard vehicle collision, or fire/explosives close to a pump can set it off. It
-- resets itself after the cooldown rather than staying broken.
Config.PumpExplosion = {
    enabled      = true,
    radius       = 4.0,      -- metres from the pump that counts as "close"
    cooldown     = 180000,   -- ms the pump stays out of service after exploding
    checkEvery   = 500,      -- ms between hazard checks while near an active pump
    crashSpeed   = 8.0,      -- m/s a vehicle needs to be doing to count as a collision, not a bump
}

-- ─────────────────────────────── Sounds ─────────────────────────────────
-- Personal only (PlaySoundFrontend) — nobody else hears these. If a sound doesn't play, the
-- name/set pair is wrong for your game build; swap in any other native GTA sound.
Config.Sounds = {
    enabled     = true,
    nozzleClick = { name = 'Place_Prop_Down', set = 'DLC_Dmod_Prop_Editor_Sounds' },   -- take/insert/return nozzle
    pumpTick    = { name = 'Hack_Success',    set = 'DLC_HEIST_HACKING_SNAKE_SOUNDSET' }, -- once per whole litre
    saleDone    = { name = 'PICK_UP_WEAPON',  set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },  -- fuelling finished
}

-- ─────────────────────────────── Discord webhook ────────────────────────
-- Logs every completed sale (player, litres/grade/cost, station location, time). Leave the URL
-- blank to disable; nothing is sent until you paste one in.
Config.Webhook = {
    url      = '',   -- e.g. 'https://discord.com/api/webhooks/XXXXXXXX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    username = 'Fuel Log',
    color    = 15105570,  -- amber, decimal
}

-- ─────────────────────────────── Pumps ─────────────────────────────────
Config.PumpModels = {
    'prop_gas_pump_1a',
    'prop_gas_pump_1b',
    'prop_gas_pump_1c',
    'prop_gas_pump_1d',
    'prop_gas_pump_old2',
    'prop_gas_pump_old3',
    'prop_vintage_pump',
}

Config.Nozzle = {
    model       = 'prop_cs_fuel_nozle',
    -- in the player's hand
    bone        = 18905,
    pos         = vec3(0.11, 0.02, 0.02),      -- tune live with /fuelnozzle
    rot         = vec3(-80.0, -90.0, 15.0),
    -- when plugged into a vehicle, relative to the fuel cap. Written for a cap on the LEFT side
    -- (x negative = outward); cars with the cap on the right get the same pose mirrored automatically.
    -- Tune live with /fuelvehicle next to a car.
    vehicle     = { pos = vec3(-0.18, 0.0, 0.05), rot = vec3(-125.0, -90.0, -90.0) },
    -- hose between the pump and the nozzle (set rope = false if it misbehaves)
    rope        = true,
    ropeOffset  = vec3(0.0, 0.0, 1.45),   -- where the hose leaves the pump
    maxDistance = 6.0,                    -- walk further than this from the pump and the nozzle snaps back
}

-- ─────────────────────────────── DUI ───────────────────────────────────
Config.Dui = { width = 640, height = 460 }   -- aspect ratio = shape of the pump screen

-- Default: a panel floating above the pump that turns to face the player.
Config.Panel = {
    width   = 0.80,     -- world metres
    height  = 0.50,
    zOffset = 2.05,     -- above the pump origin
}

-- The DUI is pinned over the pump's face panel. offset is relative to the pump model,
-- heading is extra rotation in degrees (use 180 to flip to the other side), width is in metres
-- (height follows the DUI aspect ratio). Models with no entry use the floating panel above.
-- Tune live with /fuelscreen (see Config.Tuner) and paste the printed line here.
-- (Only needed for models that are NOT in Config.PumpTextures.)
Config.PumpScreens = {
    -- prop_gas_pump_1b = { offset = vec3(0.0, -0.20, 1.30), heading = 180.0, width = 0.60 },
}

-- Texture mode: replaces a pump's REAL texture with a DUI page (html/pump_*.html is the
-- original texture + live overlays), so the UI sits exactly on the pump's own screen.
-- It applies to every pump of that model. Models listed here don't use the quad above.
-- The bg image must be the pump's original 512x512 texture (export from OpenIV) placed in html/.
-- If a pump shows the wrong artwork, swap the bg names (check the .ytd name in OpenIV's title bar).
Config.PumpTextures = {
    { model = 'prop_gas_pump_1a', txd = 'prop_gas_pump_1a', texture = 'prop_gas_pump_1a', page = 'html/pump.html?bg=pump_1a.png', size = 1024 }, -- Ron
    { model = 'prop_gas_pump_1b', txd = 'prop_gas_pump_1b', texture = 'prop_gas_pump_1b', page = 'html/pump.html?bg=pump_1b.png', size = 1024 }, -- Xero
    { model = 'prop_gas_pump_1c', txd = 'prop_gas_pump_1c', texture = 'prop_gas_pump_1c', page = 'html/pump.html?bg=pump_1c.png', size = 1024 }, -- LTD
    { model = 'prop_gas_pump_1d', txd = 'prop_gas_pump_1d', texture = 'prop_gas_pump_1d', page = 'html/pump.html?bg=pump_1d.png', size = 1024 }, -- Globe Oil
}

-- Where the pump's top control panel (texture area 0,0 -> 370,160 px) sits in the world, used to
-- turn the mouse cursor into a click on the texture. Calibrate with /fuelscreen: line the
-- outline up with the panel, then paste the printed line. 'default' is used by any pump
-- model without its own entry.
Config.TouchRegion = { w = 370, h = 160 }
Config.PumpTouch = {
    default = { offset = vec3(0.0, -0.20, 1.214), heading = 180.0, width = 1.06 },
    -- prop_gas_pump_1b = { offset = vec3(0.0, -0.20, 1.30), heading = 180.0, width = 0.60 },
}

Config.Tuner = false     -- enables /fuelscreen (turn off in production)

-- ─────────────────────────────── Blips ─────────────────────────────────
Config.Blips = {
    enabled = true,
    sprite  = 361,
    colour  = 1,
    scale   = 0.7,
    label   = 'Gas Station',
}

-- Blips only: pumps work anywhere a pump model exists. Adjust / add as needed.
Config.Stations = {
    vec3(265.0, -1261.3, 29.3),
    vec3(-70.2, -1761.8, 29.5),
    vec3(818.0, -1040.0, 26.7),
    vec3(1181.4, -330.8, 69.3),
    vec3(620.8, 269.1, 103.1),
    vec3(-724.6, -935.2, 19.2),
    vec3(-526.0, -1211.0, 18.2),
    vec3(-1437.6, -276.7, 46.2),
    vec3(-2096.2, -320.3, 13.2),
    vec3(2581.3, 362.0, 108.5),
    vec3(2539.7, 2594.2, 37.9),
    vec3(1207.3, 2660.2, 37.9),
    vec3(1039.9, 2671.1, 39.5),
    vec3(263.9, 2606.5, 44.9),
    vec3(49.4, 2778.8, 58.0),
    vec3(2679.9, 3263.9, 55.2),
    vec3(2005.0, 3773.9, 32.4),
    vec3(1687.2, 4929.4, 42.1),
    vec3(1701.3, 6416.0, 32.8),
    vec3(179.9, 6602.8, 31.9),
    vec3(-94.5, 6419.6, 31.5),
}
