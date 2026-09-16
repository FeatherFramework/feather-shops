fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

name 'feather-shops'
description 'Authoritative commerce workflows for the Feather Framework'
author 'Feather Framework'
version '0.1.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/main.lua',
    'server/quotes.lua',
    'server/orders.lua',
    'server/fulfillment.lua',
    'server/purchases.lua',
    'server/purchase_tests.lua',
    'server/compensation_tests.lua',
    'server/reconciliation.lua'
}

dependencies { 'oxmysql', 'feather-core', 'feather-economy', 'feather-inventory' }
