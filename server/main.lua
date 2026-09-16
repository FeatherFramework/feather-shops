local function Ok(value) return { ok = true, value = value } end
local function Err(code, message, details)
    return { ok = false, code = code, message = message, details = details }
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local copied = {}
    for key, child in pairs(value) do copied[key] = Copy(child) end
    return copied
end
local function Log(event, fields)
    print(('[feather-shops] event=%s %s'):format(event, json.encode(fields or {})))
end
local health = { state = 'booting', phase = 'configuration', contract = 1,
    version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0), checks = {} }
local catalog = {}
local function Uuid(value)
    return type(value) == 'string' and value:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end
local function Integer(value, minimum, maximum)
    return type(value) == 'number' and value == math.floor(value)
        and value >= minimum and value <= maximum
end
local function Text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= maximum
end
local function Finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < 100000
end
local function Validate()
    if Config.Contract ~= 1 or not Integer(Config.ReadinessTimeoutMs, 0, 60000)
        or not Integer(Config.MaximumOffersPerShop, 1, 100)
        or type(Config.Shops) ~= 'table' or #Config.Shops > 100 then
        return Err('invalid_config', 'Shop service configuration is invalid.')
    end
    if type(Config.Quotes) ~= 'table'
        or not Integer(Config.Quotes.lifetimeSeconds, 5, 120)
        or not Finite(Config.Quotes.maximumDistance)
        or Config.Quotes.maximumDistance < 1 or Config.Quotes.maximumDistance > 10
        or type(Config.Quotes.trustedCallers) ~= 'table' then
        return Err('invalid_config', 'Quote configuration is invalid.')
    end
    local ids, offerIds = {}, {}
    for _, shop in ipairs(Config.Shops) do
        if type(shop) ~= 'table' or not Uuid(shop.id) or ids[shop.id]
            or shop.id ~= shop.id:lower() or not Text(shop.label, 100)
            or type(shop.position) ~= 'table' or not Finite(shop.position.x)
            or not Finite(shop.position.y) or not Finite(shop.position.z)
            or not Finite(shop.heading) or shop.heading < 0 or shop.heading >= 360
            or type(shop.offers) ~= 'table' or #shop.offers > Config.MaximumOffersPerShop then
            return Err('invalid_config', 'A configured shop is invalid.')
        end
        ids[shop.id] = true
        for _, offer in ipairs(shop.offers) do
            if type(offer) ~= 'table' or not Uuid(offer.id) or offerIds[offer.id]
                or offer.id ~= offer.id:lower() or not Text(offer.label, 100)
                or not Text(offer.itemName, 100) or not offer.itemName:match('^[a-z0-9_]+$')
                or not Text(offer.currency, 32)
                or not Integer(offer.unitPrice, 1, 1000000000000)
                or not Integer(offer.maximumQuantity, 1, 100) then
                return Err('invalid_config', 'A configured offer is invalid.')
            end
            offerIds[offer.id] = true
        end
    end
    return Ok(true)
end

local statements = {
    [[CREATE TABLE IF NOT EXISTS `shop_locations` (
        `shop_id` CHAR(36) NOT NULL, `label` VARCHAR(100) NOT NULL,
        `pos_x` DOUBLE NOT NULL, `pos_y` DOUBLE NOT NULL, `pos_z` DOUBLE NOT NULL,
        `heading` DOUBLE NOT NULL, `enabled` TINYINT(1) NOT NULL DEFAULT 1,
        PRIMARY KEY (`shop_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS `shop_offers` (
        `offer_id` CHAR(36) NOT NULL, `shop_id` CHAR(36) NOT NULL,
        `item_name` VARCHAR(100) NOT NULL, `label` VARCHAR(100) NOT NULL,
        `currency_code` VARCHAR(32) NOT NULL, `unit_price` BIGINT UNSIGNED NOT NULL,
        `maximum_quantity` INT UNSIGNED NOT NULL,
        `enabled` TINYINT(1) NOT NULL DEFAULT 1,
        PRIMARY KEY (`offer_id`), KEY `idx_shop_offers_shop` (`shop_id`),
        CONSTRAINT `fk_shop_offer_location` FOREIGN KEY (`shop_id`)
            REFERENCES `shop_locations` (`shop_id`),
        CONSTRAINT `chk_shop_offer_price` CHECK (`unit_price` > 0),
        CONSTRAINT `chk_shop_offer_quantity` CHECK (`maximum_quantity` BETWEEN 1 AND 100)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]
}
local function Migrate()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `shop_schema_migrations` (
        `id` VARCHAR(100) NOT NULL, `checksum` VARCHAR(64) NOT NULL,
        `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
    local hash = 2166136261
    local text = table.concat(statements, '\n')
    for index = 1, #text do hash = ((hash ~ text:byte(index)) * 16777619) & 0xffffffff end
    local checksum = ('fnv1a32:%08x'):format(hash)
    local stored = MySQL.scalar.await(
        'SELECT `checksum` FROM `shop_schema_migrations` WHERE `id`=?', { '001_shop_catalog' })
    if stored and stored ~= checksum then
        return Err('migration_checksum_mismatch', 'Applied shop catalog migration has changed.')
    end
    if not stored then
        for _, statement in ipairs(statements) do MySQL.query.await(statement) end
        MySQL.insert.await('INSERT INTO `shop_schema_migrations` (`id`,`checksum`) VALUES (?,?)',
            { '001_shop_catalog', checksum })
    end
    return Ok({ applied = stored and 0 or 1 })
end

local function Synchronize()
    local committed = MySQL.startTransaction(function(query)
        query('UPDATE `shop_offers` SET `enabled`=0')
        query('UPDATE `shop_locations` SET `enabled`=0')
        for _, shop in ipairs(Config.Shops) do
            query([[INSERT INTO `shop_locations`
                (`shop_id`,`label`,`pos_x`,`pos_y`,`pos_z`,`heading`,`enabled`)
                VALUES (?,?,?,?,?,?,1) ON DUPLICATE KEY UPDATE
                `label`=VALUES(`label`),`pos_x`=VALUES(`pos_x`),`pos_y`=VALUES(`pos_y`),
                `pos_z`=VALUES(`pos_z`),`heading`=VALUES(`heading`),`enabled`=1]],
                { shop.id, shop.label, shop.position.x, shop.position.y, shop.position.z, shop.heading })
            for _, offer in ipairs(shop.offers) do
                query([[INSERT INTO `shop_offers`
                    (`offer_id`,`shop_id`,`item_name`,`label`,`currency_code`,`unit_price`,`maximum_quantity`,`enabled`)
                    VALUES (?,?,?,?,?,?,?,1) ON DUPLICATE KEY UPDATE
                    `shop_id`=VALUES(`shop_id`),`item_name`=VALUES(`item_name`),`label`=VALUES(`label`),
                    `currency_code`=VALUES(`currency_code`),`unit_price`=VALUES(`unit_price`),
                    `maximum_quantity`=VALUES(`maximum_quantity`),`enabled`=1]],
                    { offer.id, shop.id, offer.itemName, offer.label, offer.currency,
                        offer.unitPrice, offer.maximumQuantity })
            end
        end
        return true
    end)
    if committed ~= true then return Err('catalog_failed', 'Shop catalog synchronization failed.') end
    for _, shop in ipairs(Config.Shops) do catalog[shop.id] = Copy(shop) end
    return Ok(true)
end

local function ReadyRead()
    if health.state ~= 'ready' then return Err('not_ready', 'Feather Shops is not ready.') end
end
local function ListShops()
    local failure = ReadyRead()
    if failure then return failure end
    local shops = {}
    for _, shop in pairs(catalog) do
        shops[#shops + 1] = { id = shop.id, label = shop.label,
            position = Copy(shop.position), heading = shop.heading }
    end
    table.sort(shops, function(a, b) return a.id < b.id end)
    return Ok(shops)
end
local function GetCatalog(shopId)
    local failure = ReadyRead()
    if failure then return failure end
    if not Uuid(shopId) then return Err('invalid_input', 'A UUID shop ID is required.') end
    if not catalog[shopId] then return Err('shop_not_found', 'Shop was not found.') end
    return Ok(Copy(catalog[shopId]))
end
ShopService = { Ok = Ok, Err = Err, Copy = Copy, Integer = Integer,
    Uuid = Uuid, GetCatalog = GetCatalog, IsReady = function() return health.state == 'ready' end }
exports('GetHealth', function() return Ok(Copy(health)) end)
exports('GetCapabilities', function()
    return Ok({ resource = 'feather-shops', contract = 1, state = health.state,
        version = health.version, features = { lifecycle = 1, migrations = 1,
            catalog = 1, quotes = 1, durableOrders = 1,
            payments = 0, fulfillment = 0, playerShops = 0 } })
end)
exports('ListShops', ListShops)
exports('GetCatalog', GetCatalog)
exports('AwaitReady', function(timeoutMs)
    timeoutMs = timeoutMs == nil and 10000 or timeoutMs
    if not Integer(timeoutMs, 0, 60000) then return Err('invalid_input', 'Invalid readiness timeout.') end
    local deadline = GetGameTimer() + timeoutMs
    while health.state ~= 'ready' and health.state ~= 'failed' and GetGameTimer() < deadline do Wait(0) end
    if health.state == 'ready' then return Ok(Copy(health)) end
    return Err(health.state == 'failed' and 'not_ready' or 'timeout', 'Feather Shops is not ready.', Copy(health))
end)

CreateThread(function()
    local called, result = xpcall(function()
        local configured = Validate()
        if not configured.ok then return configured end
        health.checks.configuration = true
        for _, dependency in ipairs({ 'feather-core', 'feather-economy' }) do
            health.phase = 'waiting_for_' .. dependency
            local ready = exports[dependency]:AwaitReady(Config.ReadinessTimeoutMs)
            if type(ready) ~= 'table' or not ready.ok then
                return Err('dependency_unavailable', dependency .. ' did not become ready.')
            end
            local capabilities = exports[dependency]:GetCapabilities()
            if type(capabilities) ~= 'table' or not capabilities.ok
                or type(capabilities.value) ~= 'table' or capabilities.value.contract ~= 1 then
                return Err('dependency_unavailable', dependency .. ' Contract 1 is required.')
            end
            health.checks[dependency] = true
        end
        for _, shop in ipairs(Config.Shops) do
            for _, offer in ipairs(shop.offers) do
                local currency = exports['feather-economy']:GetCurrency(offer.currency)
                if type(currency) ~= 'table' or not currency.ok or not currency.value.enabled then
                    return Err('invalid_config', 'Offer currency is missing or disabled.', { offerId = offer.id })
                end
            end
        end
        health.phase = 'migrations'
        local migrated = Migrate()
        if not migrated.ok then return migrated end
        health.checks.migrations = migrated.value
        health.phase = 'catalog'
        local synchronized = Synchronize()
        if not synchronized.ok then return synchronized end
        health.phase = 'order_migrations'
        local moduleDeadline = GetGameTimer() + Config.ReadinessTimeoutMs
        while not ShopOrders and GetGameTimer() < moduleDeadline do Wait(0) end
        if not ShopOrders then return Err('startup_failed', 'Order service did not load.') end
        local orders = ShopOrders.Start()
        if orders.ok then
            health.checks.migrations.applied = health.checks.migrations.applied + orders.value.applied
            health.checks.orders = true
        end
        return orders
    end, debug.traceback)
    if not called then result = Err('startup_failed', 'Shop startup failed.', { reason = tostring(result) }) end
    if not result.ok then
        health.state, health.phase, health.failure = 'failed', 'startup_failed', result
        Log('startup.failed', result)
        return
    end
    health.state, health.phase = 'ready', 'ready'
    Log('startup.ready', { shops = #Config.Shops, migrationsApplied = health.checks.migrations.applied })
end)

RegisterCommand('ShopFoundationSmokeTest', function(source)
    if source ~= 0 then return end
    if health.state ~= 'ready' then
        print('[ShopFoundationSmokeTest] FAIL service not ready ' .. json.encode(health))
        return
    end
    local listed = ListShops()
    local persistedShops = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM `shop_locations` WHERE `enabled`=1'))
    local persistedOffers = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM `shop_offers` WHERE `enabled`=1'))
    local expectedOffers, pricesValid = 0, true
    for _, shop in ipairs(Config.Shops) do
        for _, offer in ipairs(shop.offers) do
            expectedOffers = expectedOffers + 1
            local price = tonumber(MySQL.scalar.await('SELECT `unit_price` FROM `shop_offers` WHERE `offer_id`=?', { offer.id }))
            pricesValid = pricesValid and price == offer.unitPrice
        end
    end
    local copied = true
    if listed.ok and listed.value[1] then
        local first = GetCatalog(listed.value[1].id)
        first.value.label = 'modified snapshot'
        copied = GetCatalog(listed.value[1].id).value.label ~= 'modified snapshot'
    end
    local invalid = GetCatalog('invalid')
    local unknown = GetCatalog('ffffffff-ffff-4fff-8fff-ffffffffffff')
    local tests = {
        { 'service ready', health.state == 'ready' },
        { 'dependency contracts', health.checks['feather-core'] and health.checks['feather-economy'] },
        { 'catalog persisted', listed.ok and persistedShops == #listed.value and persistedOffers == expectedOffers },
        { 'integer prices persisted', pricesValid },
        { 'snapshot isolated', copied },
        { 'invalid id rejected', not invalid.ok and invalid.code == 'invalid_input' },
        { 'unknown shop rejected', not unknown.ok and unknown.code == 'shop_not_found' }
    }
    local passed = 0
    for _, test in ipairs(tests) do
        if test[2] then passed = passed + 1 end
        print(('[ShopFoundationSmokeTest] %-25s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
    end
    print(('[ShopFoundationSmokeTest] done %d/%d passed (read-only)'):format(passed, #tests))
end, true)
