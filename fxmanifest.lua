fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'as-fuel'
author 'ACE Studios'
description 'Fuel system with a world-space DUI pump display (QBCore / Qbox)'
version '1.0.0'

dependency 'qb-core'

shared_scripts {
    'config.lua',
}

client_scripts {
    'client/dui.lua',
    'client/main.lua',
}

server_scripts {
    'server/bridge.lua',
    'server/main.lua',
}

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/pump.html',
    'html/pump_1a.png',
    'html/pump_1b.png',
    'html/pump_1c.png',
    'html/pump_1d.png',
}
