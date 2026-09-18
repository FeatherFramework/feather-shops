if not Config.DevMode then return end
RegisterCommand('ShopPurchaseRecoveryTest', function(source, args)
    if source ~= 0 then return end
    if not ShopService.IsReady() then print('[ShopPurchaseRecoveryTest] FAIL service not ready'); return end
    local target, requestId, operation = tonumber(args[1]), args[2], args[3]
    if not target or type(requestId) ~= 'string' or #requestId > 128
        or not requestId:match('^[A-Za-z0-9][A-Za-z0-9._:%-]*$')
        or (operation ~= 'payment' and operation ~= 'grant' and operation ~= 'undelivered' and operation ~= 'retry') then
        print('[ShopPurchaseRecoveryTest] usage: ShopPurchaseRecoveryTest <source> <requestId> payment|grant|undelivered|retry'); return
    end
    local session = exports['feather-core']:GetSessionContext(target)
    if type(session) ~= 'table' or not session.ok then print('[ShopPurchaseRecoveryTest] FAIL buyer session required'); return end
    local order = MySQL.single.await([[SELECT * FROM `shop_orders`
        WHERE `source_resource`='feather-shops' AND `request_id`=?]], { requestId })
    if operation ~= 'retry' and order then print('[ShopPurchaseRecoveryTest] FAIL fresh request ID required'); return end
    if operation == 'retry' and not order then print('[ShopPurchaseRecoveryTest] FAIL prepared recovery order missing'); return end
    if order and (order.buyer_character_id ~= session.value.characterId or order.buyer_account_id ~= session.value.accountId) then
        print('[ShopPurchaseRecoveryTest] FAIL order belongs to another buyer'); return
    end
    local shop, offer = Config.Shops[1], Config.Shops[1].offers[1]
    local currency = order and order.currency_code or offer.currency
    local wallets = exports['feather-economy']:EnsureCharacterWallets({ characterId = session.value.characterId })
    local wallet
    for _, account in ipairs(wallets.ok and wallets.value or {}) do
        if account.currency == currency then wallet = account; break end
    end
    local sink = ShopOrganizations.Settlement(order and order.shop_id or shop.id, currency, order and order.order_id)
    if not wallet or not sink.ok then print('[ShopPurchaseRecoveryTest] FAIL wallet/settlement unavailable'); return end
    if not order then
        if wallet.balance < offer.unitPrice * 2 then print('[ShopPurchaseRecoveryTest] FAIL fund wallet first'); return end
        local quoted = ShopQuotes.Create({ shopId = shop.id, offerId = offer.id, quantity = 2 }, target)
        if not quoted.ok then print('[ShopPurchaseRecoveryTest] FAIL quote=' .. quoted.code); return end
        local prepared = ShopOrders.Prepare({ requestId = requestId, quoteId = quoted.value.id }, target, 'feather-shops')
        if not prepared.ok then print('[ShopPurchaseRecoveryTest] FAIL order=' .. prepared.code); return end
        order = MySQL.single.await('SELECT * FROM `shop_orders` WHERE `order_id`=?', { prepared.value.id })
    end
    local beforeExecution = MySQL.single.await('SELECT * FROM `shop_order_executions` WHERE `order_id`=?', { order.order_id })
    if operation == 'retry' and (not beforeExecution or
        (beforeExecution.state ~= 'payment_pending' and beforeExecution.state ~= 'paid' and beforeExecution.state ~= 'fulfilled')) then
        print('[ShopPurchaseRecoveryTest] FAIL execution is not recoverable'); return
    end
    local checkpoint = operation == 'payment' and 'after_payment' or operation == 'grant' and 'after_grant'
        or operation == 'undelivered' and 'before_grant' or nil
    local result = ShopPurchases.Purchase(order.order_id, target, checkpoint)
    local after = exports['feather-economy']:GetAccount({ accountId = wallet.accountId })
    local sinkAfter = exports['feather-economy']:GetAccount({ accountId = sink.value.accountId })
    local stored = MySQL.single.await('SELECT * FROM `shop_order_executions` WHERE `order_id`=?', { order.order_id })
    if operation ~= 'retry' then
        local expected = operation == 'payment' and 'payment_pending' or 'paid'
        local passed = not result.ok and result.code == 'test_interrupted' and stored and stored.state == expected
            and stored.fulfillment_json == nil and after.ok and sinkAfter.ok
            and after.value.balance == wallet.balance - tonumber(order.total_amount)
            and sinkAfter.value.balance == sink.value.balance + tonumber(order.total_amount)
            and (operation ~= 'payment' or stored.payment_transaction_id == nil)
        print(('[ShopPurchaseRecoveryTest] %s interrupted=%s order=%s state=%s walletFinal=%s; restart Shops then retry same request ID'):format(
            passed and 'PASS' or 'FAIL', operation, order.order_id,
            tostring(stored and stored.state), tostring(after.ok and after.value.balance)))
        return
    end
    if not result.ok then print('[ShopPurchaseRecoveryTest] FAIL order=' .. order.order_id .. ' code=' .. result.code); return end
    local unchanged = after.ok and sinkAfter.ok and after.value.balance == wallet.balance
        and sinkAfter.value.balance == sink.value.balance
    local payment = exports['feather-economy']:Transfer({
        fromAccountId = stored.from_account_id, toAccountId = stored.to_account_id,
        currency = stored.currency_code, amount = tonumber(stored.amount), reasonCode = 'shop.purchase',
        referenceType = 'shop_order', referenceId = order.order_id, idempotencyKey = 'shop-payment:' .. order.order_id
    }, { actorSource = target, actorAccountId = order.buyer_account_id,
        actorCharacterId = order.buyer_character_id, correlationId = order.order_id })
    local grant = exports['feather-inventory']:GrantCharacterItemOnce({
        grantId = 'shop-fulfillment:' .. order.order_id, characterId = order.buyer_character_id,
        itemName = order.item_name, definitionId = tonumber(order.definition_id), quantity = tonumber(order.quantity) })
    local decoded, fulfillment = pcall(json.decode, stored.fulfillment_json or '')
    local sameIds = grant.ok and decoded and type(fulfillment) == 'table'
        and json.encode(grant.value.instanceIds) == json.encode(fulfillment.instanceIds)
    local paymentReplayed = payment.ok and payment.value.replayed == true
        and payment.value.transactionId == stored.payment_transaction_id
    local grantReplayed = grant.ok and grant.value.replayed == true and sameIds
    local grantRecovered = decoded and type(fulfillment) == 'table' and fulfillment.replayed == true
    local passed = stored.state == 'fulfilled' and unchanged and paymentReplayed and grantReplayed
        and (beforeExecution.state ~= 'paid' or grantRecovered)
    print(('[ShopPurchaseRecoveryTest] %s order=%s state=%s noSecondCharge=%s paymentReplayed=%s grantReplayed=%s grantRecovered=%s walletFinal=%s'):format(
        passed and 'PASS' or 'FAIL', order.order_id, stored.state, tostring(unchanged),
        tostring(paymentReplayed), tostring(grantReplayed), tostring(grantRecovered), tostring(after.value.balance)))
end, true)
RegisterCommand('ShopPurchaseLiveTest', function(source, args)
    if source ~= 0 then return end
    if not ShopService.IsReady() then print('[ShopPurchaseLiveTest] FAIL service not ready'); return end
    local target, requestId = tonumber(args[1]), args[2]
    if not target or type(requestId) ~= 'string' or #requestId > 128
        or not requestId:match('^[A-Za-z0-9][A-Za-z0-9._:%-]*$') then
        print('[ShopPurchaseLiveTest] usage: ShopPurchaseLiveTest <active source near shop> <requestId>'); return
    end
    local session = exports['feather-core']:GetSessionContext(target)
    if type(session) ~= 'table' or not session.ok then print('[ShopPurchaseLiveTest] FAIL active buyer required'); return end
    local order = MySQL.single.await([[SELECT * FROM `shop_orders`
        WHERE `source_resource`='feather-shops' AND `request_id`=?]], { requestId })
    if order and (order.buyer_character_id ~= session.value.characterId or order.buyer_account_id ~= session.value.accountId) then
        print('[ShopPurchaseLiveTest] FAIL request belongs to another buyer'); return
    end
    local execution = order and MySQL.single.await('SELECT * FROM `shop_order_executions` WHERE `order_id`=?', { order.order_id })
    if order and (not execution or execution.state ~= 'fulfilled') then
        print('[ShopPurchaseLiveTest] FAIL existing incomplete order requires recovery; do not use a new request ID'); return
    end
    local shop, offer = Config.Shops[1], Config.Shops[1].offers[1]
    local currency = order and order.currency_code or offer.currency
    local total = order and tonumber(order.total_amount) or offer.unitPrice * 2
    local wallets = exports['feather-economy']:EnsureCharacterWallets({ characterId = session.value.characterId })
    local wallet
    for _, account in ipairs(wallets.ok and wallets.value or {}) do
        if account.currency == currency then wallet = account; break end
    end
    if not wallet then print('[ShopPurchaseLiveTest] FAIL wallet unavailable'); return end
    local sink = ShopOrganizations.Settlement(order and order.shop_id or shop.id, currency, order and order.order_id)
    if not sink.ok then print('[ShopPurchaseLiveTest] FAIL settlement unavailable'); return end
    if not order and (sink.value.accountType ~= 'treasury' or sink.value.ownerType ~= 'organization'
        or sink.value.ownerId ~= ShopOrganizations.GetId(shop.id)) then
        print('[ShopPurchaseLiveTest] FAIL new purchase must settle to canonical business treasury'); return
    end
    local existing = order ~= nil
    if not order then
        if wallet.balance < total then print('[ShopPurchaseLiveTest] FAIL fund wallet first; no order created'); return end
        local quoted = ShopQuotes.Create({ shopId = shop.id, offerId = offer.id, quantity = 2 }, target)
        if not quoted.ok then print('[ShopPurchaseLiveTest] FAIL quote=' .. quoted.code); return end
        local prepared = ShopOrders.Prepare({ requestId = requestId, quoteId = quoted.value.id }, target, 'feather-shops')
        if not prepared.ok then print('[ShopPurchaseLiveTest] FAIL prepare=' .. prepared.code); return end
        order = MySQL.single.await('SELECT * FROM `shop_orders` WHERE `order_id`=?', { prepared.value.id })
    end
    local result = ShopPurchases.Purchase(order.order_id, target)
    if not result.ok then
        print('[ShopPurchaseLiveTest] FAIL order=' .. order.order_id .. ' code=' .. result.code .. '; retain request ID for recovery'); return
    end
    local replayed = ShopPurchases.Purchase(order.order_id, target)
    local walletAfter = exports['feather-economy']:GetAccount({ accountId = wallet.accountId })
    local sinkAfter = exports['feather-economy']:GetAccount({ accountId = sink.value.accountId })
    local chargedOnce = walletAfter.ok and sinkAfter.ok
        and walletAfter.value.balance == wallet.balance - (existing and 0 or total)
        and sinkAfter.value.balance == sink.value.balance + (existing and 0 or total)
    -- A fulfilled receipt must already exist. This exact grant retry checks that
    -- Inventory returns it rather than creating another delivery.
    local delivered = exports['feather-inventory']:GrantCharacterItemOnce({
        grantId = 'shop-fulfillment:' .. order.order_id, characterId = order.buyer_character_id,
        definitionId = tonumber(order.definition_id), itemName = order.item_name, quantity = tonumber(order.quantity) })
    local stored = MySQL.single.await('SELECT * FROM `shop_order_executions` WHERE `order_id`=?', { order.order_id })
    chargedOnce = chargedOnce and stored and stored.to_account_id == sink.value.accountId
    local sameDelivery = false
    if stored and stored.fulfillment_json and delivered.ok then
        local decoded, original = pcall(json.decode, stored.fulfillment_json)
        sameDelivery = decoded and json.encode(original.instanceIds) == json.encode(delivered.value.instanceIds)
    end
    local passed = result.value.state == 'fulfilled' and replayed.ok and replayed.value.replayed == true
        and replayed.value.transactionId == result.value.transactionId and chargedOnce
        and delivered.ok and delivered.value.replayed == true and sameDelivery
    print(('[ShopPurchaseLiveTest] %s order=%s state=%s amount=%s chargedOnce=%s replayed=%s fulfillmentReplayed=%s sameInstances=%s walletFinal=%s settlementType=%s settlementOwner=%s settlementFinal=%s'):format(
        passed and 'PASS' or 'FAIL', order.order_id, result.value.state, tostring(total),
        tostring(chargedOnce), tostring(replayed.ok and replayed.value.replayed),
        tostring(delivered.ok and delivered.value.replayed), tostring(sameDelivery),
        tostring(walletAfter.ok and walletAfter.value.balance), tostring(sink.value.accountType),
        tostring(sink.value.ownerId), tostring(sinkAfter.ok and sinkAfter.value.balance)))
end, true)
