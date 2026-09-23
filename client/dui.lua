-- DUI helpers.
--  * Dui            : the floating/pinned panel (html/index.html) drawn as a world quad
--  * Dui.Textures   : DUIs that REPLACE a pump model's real texture (html/pump_*.html)
local counter = 0

local function newDui(page, w, h)
    counter = counter + 1
    local self = {
        ready = false,
        txd = ('as_fuel_txd_%d_%d'):format(counter, GetGameTimer()),
        tex = 'as_fuel_tex',
    }
    local obj, last, onReady

    function self.init(cb)
        if obj then return end
        onReady = cb
        obj = CreateDui(('nui://%s/%s'):format(GetCurrentResourceName(), page), w, h)
        CreateThread(function()
            local started = GetGameTimer()
            while obj and not IsDuiAvailable(obj) do
                if GetGameTimer() - started > 10000 then return end
                Wait(50)
            end
            if not obj then return end
            local txd = CreateRuntimeTxd(self.txd)
            CreateRuntimeTextureFromDuiHandle(txd, self.tex, GetDuiHandle(obj))
            self.ready = true
            if last then SendDuiMessage(obj, last) end
            if onReady then onReady(self) end
        end)
    end

    function self.send(data)
        last = json.encode(data)
        if obj and self.ready then SendDuiMessage(obj, last) end
    end

    function self.destroy()
        if obj then DestroyDui(obj) end
        obj, self.ready = nil, false
    end

    return self
end

-- ── world quad panel ────────────────────────────────────────────────────
local panel = newDui('html/index.html', Config.Dui.width, Config.Dui.height)
Dui = { ready = false }

function Dui.Init() panel.init(function() Dui.ready = true end) end

local function tri(a, ua, b, ub, c, uc)
    DrawSpritePoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z,
        255, 255, 255, 255, panel.txd, panel.tex,
        ua[1], ua[2], 1.0, ub[1], ub[2], 1.0, uc[1], uc[2], 1.0)
end

-- center: vec3, dir: horizontal unit vec pointing from the panel towards the viewer
function Dui.DrawQuad(center, dir, width, height)
    if not panel.ready then return end

    local r  = vec3(-dir.y, dir.x, 0.0) * (width / 2.0)
    local up = vec3(0.0, 0.0, height / 2.0)

    local tl, tr = center - r + up, center + r + up
    local bl, br = center - r - up, center + r - up
    local uTL, uTR, uBL, uBR = {0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}

    -- each triangle is drawn with both windings so it shows regardless of facing
    tri(tl, uTL, tr, uTR, bl, uBL)
    tri(tl, uTL, bl, uBL, tr, uTR)
    tri(tr, uTR, br, uBR, bl, uBL)
    tri(tr, uTR, bl, uBL, br, uBR)
end

-- ── texture replacement (real pump screens) ─────────────────────────────
Dui.Textures = {}

CreateThread(function()
    for _, def in ipairs(Config.PumpTextures or {}) do
        local d = newDui(def.page, def.size, def.size)
        d.def = def
        Dui.Textures[#Dui.Textures + 1] = d
        d.init(function(inst)
            AddReplaceTexture(def.txd, def.texture, inst.txd, inst.tex)
        end)
    end
end)

function Dui.SendAll(data)
    panel.send(data)
    for _, d in ipairs(Dui.Textures) do d.send(data) end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, d in ipairs(Dui.Textures) do
        RemoveReplaceTexture(d.def.txd, d.def.texture)
        d.destroy()
    end
    panel.destroy()
end)
