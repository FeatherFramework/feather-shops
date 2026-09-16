fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

name 'feather-shops'
description 'Authoritative commerce workflows for the Feather Framework'
author 'Feather Framework'
version '0.1.0'
shops_dev_tests 'true'

client_script 'client/quote_tests.lua'
client_script 'client/purchase_tests.lua'
client_script 'client/shop.lua'

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
    'server/reconciliation.lua',
    'server/player_routes.lua'
}

dependencies { 'oxmysql', 'feather-core', 'feather-economy', 'feather-inventory', 'feather-toolkit', 'feather-menu-v2' }
