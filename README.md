# Feather Shops

Feather-native commerce service. Original BCC Shops is reference only; this
resource has no VORP compatibility layer or legacy table dependency.

## Foundation slice

- Contract 1 result envelopes, health, capabilities, and bounded readiness.
- Core and Economy readiness/contract validation.
- Checksummed schema migration and UUID shop/offer identities.
- Server-configured NPC catalog persisted with integer minor-unit prices.
- Public read-only catalog snapshots. No client mutation or payment route yet.
- Durable prepared orders with buyer/quote-bound request IDs and restart replay.

Config is authoritative for the initial catalog. Startup synchronizes configured
shops and offers and disables rows removed from configuration. Do not edit these
tables manually. Catalog reads return copies, not mutable service state.

The initial Valentine apple offer costs 100 dollars minor units ($1.00).
Quote validation checks the active Inventory definition and rejects weapons and
unique items. Foundation readiness does not claim fulfillment is available.

## Load order

Start oxmysql, feather-core, feather-economy, feather-inventory, then feather-shops.

## Server exports

`GetCapabilities()`, `GetHealth()`, `AwaitReady(timeoutMs)`,
`ListShops()`, and `GetCatalog(shopId)` return Contract 1 envelopes.
Catalog snapshots contain public offer data, not owner balances or credentials.

Trusted server callers may use `CreateQuote(request, actorSource)` and
`ValidateQuote(quoteId, actorSource)`. Quote requests accept only `shopId`,
`offerId`, and a numeric integer `quantity`. No client route exists yet; a future
RPC handler must supply its actual Core-bound source, not a request field.

Quotes have a UUID, authoritative integer total, material catalog revision,
Inventory definition ID, expiry, and server-only buyer/session identity. Never
forward the entire server quote to a client. A buyer has one outstanding quote;
creating another replaces it. Quotes expire after 30 seconds and do not survive
resource restart. Payment will require a durable order, not this temporary quote.
Validation rechecks the session, proximity, currency, definition, and revision.

`PrepareOrder({ requestId = stableId, quoteId = quoteUuid }, actorSource)` is
restricted to the same trusted server callers. It snapshots the quote and buyer
in `shop_orders`, with one order per caller/request ID. A different quote or buyer
using that ID receives `idempotency_conflict`. An exact retry returns the original
order with `replayed=true`, including after restart or quote expiry. Receipt
replay requires a current session belonging to the original account/character;
it does not authorize payment or fulfillment using expired quoted terms.

Orders currently remain `prepared`. No production payment, grant, refund, or automatic
reconciliation runs. Future states will be introduced through a new migration.
These records intentionally remain as development receipts; do not delete them
to retry an operation. Like quotes, order snapshots contain server-only identity.

## Purchase coordinator acceptance

The immutable prepared receipt remains in `shop_orders`. Migration 003 adds
`shop_order_executions` for `payment_pending`, `paid`, `fulfilled`, and `rejected`.
This preserves the applied catalog/order migrations. The coordinator is internal
only: no payment export or client route is available before compensation passes.

Payment intent fixes the buyer wallet, currency, amount, and Economy system sink
before charging. Economy resolves the sink through its trusted `GetSystemAccount`
export; Shops stores no independent ledger balance or system-owner configuration.
NPC purchases currently settle to the system sink, not a merchant/business wallet.

Recovery reuses `shop-payment:<order UUID>` and `shop-fulfillment:<order UUID>`.
Exact payment/grant receipts replay after restart. Only definitive insufficient
funds is terminal; uncertain payment errors remain `payment_pending`, and failed
delivery remains `paid` with an operator-visible error. State updates are
conditional and do not regress completed executions. Runtime concurrent calls
for one order are rejected; downstream durable keys protect interrupted calls.
The reconciliation worker retries existing incomplete payment/delivery intents
and existing compensation requests. It never automatically chooses compensation.

Run the first dev-only acceptance test with the buyer near the test shop:

```text
ShopPurchaseInsufficientTest 1 purchase-insufficient-001
```

Use a fresh request ID. This requires a wallet below the two-item purchase price
and otherwise aborts before attempting a purchase. Expect `PASS state=rejected
balancesUnchanged=true retryRejected=true`, with no Inventory grant.
`ShopPurchaseState <order UUID>` prints the durable execution for operators.
Successful-purchase and interruption tests follow this rejection gate.

### Funded purchase test

Economy's dev-only server-console command `EconomyShopFundingTest <source>
<stable fundingId>` issues exactly 200 dollars minor units. Funding retries are
payload-bound and durable. Shops is not added to Economy's trusted suppliers.
The test funds are spent into the system sink; this is not a balance-restoring
round trip. These commands may create real development balances and items.

```text
EconomyShopFundingTest 1 shop-fund-001
ShopPurchaseLiveTest 1 purchase-live-001
```

The buyer must be near the shop for the first purchase. Expect state=fulfilled,
amount=200, chargedOnce=true, replayed=true, fulfillmentReplayed=true,
sameInstances=true. Two apples are delivered. Repeat the purchase command using
the same request ID after restarting Shops; there must be no additional charge
or grant. Do not fund again with a new ID just to retry a completed purchase.
The live test refuses existing incomplete orders; they need explicit recovery,
not another order ID. Payment remains internal until compensation passes.

### Interrupted purchase tests

`ShopPurchaseRecoveryTest <source> <requestId> payment|grant|retry` is dev-only.
Both preparation modes use a fresh funded two-apple order near the test shop.
`payment` stops after Economy commits, before Shops records the transaction ID.
`grant` stops after Inventory commits, before Shops stores its fulfillment result.
The respective execution states remain `payment_pending` and `paid`.

```text
EconomyShopFundingTest 1 recovery-fund-payment-001
ShopPurchaseRecoveryTest 1 recovery-payment-001 payment
# restart Shops, without funding again
ShopPurchaseRecoveryTest 1 recovery-payment-001 retry

EconomyShopFundingTest 1 recovery-fund-grant-001
ShopPurchaseRecoveryTest 1 recovery-grant-001 grant
# restart Inventory and manually start Shops; do not fund again
ShopPurchaseRecoveryTest 1 recovery-grant-001 retry
```

Retry expects state=fulfilled, noSecondCharge=true, paymentReplayed=true,
grantReplayed=true, and unchanged balances. After-grant retry additionally
requires grantRecovered=true from the coordinator's persisted Inventory result.
Payment interruption delivers two apples on recovery; grant interruption delivers
them before the restart, and retry must deliver none. Each scenario spends its
200 minor-unit test funding. Retain the order request ID if any stage fails.

### Cancellation fence acceptance

Inventory's trusted `CancelCharacterItemGrant` accepts the same payload and caller
namespace as `GrantCharacterItemOnce`. Both serialize on the same durable receipt.
Cancellation commits a terminal no-delivery outcome; later grants return
`grant_cancelled`. Exact cancellation retries replay, and altered payloads return
`idempotency_conflict`. A previously committed delivery blocks cancellation with
`grant_already_delivered`, even if its items were subsequently consumed or moved.
This reuses Inventory's transaction runner and receipt table, not a second grant
or reservation system.

Migration 004 adds separate compensation states: cancellation_pending,
refund_pending, refunded, and delivery_committed. Internal compensation accepts
only recorded paid orders, persists intent before cancellation, and reverses
the original payment only after Inventory confirms durable no-delivery. Purchase
retries block while compensation is pending or refunded. If Inventory reports
committed delivery, refund is refused and fulfillment recovery remains allowed.
Refund errors retain the same pending intent and payment UUID for retry. No client
refund route exists.

### Background reconciliation

`Config.Reconciliation` enables bounded recovery (5-second polling, 15-second
minimum retry age, at most 10 sequential attempts per batch). Accepted payment
intents use their stored buyer and account identities, including while the buyer
is offline. No fresh session, proximity, or expired quote is used to retarget an
accepted payment. Prepared orders without payment intent are excluded. Refund
recovery requires existing compensation intent and keeps the cancellation fence.
Permanent dependency failures remain visible and retry at the configured pace;
attempt timestamps advance to prevent repeatedly failing orders starving others.
`ShopReconciliationState` prints worker state and counters. Attempt logs include
the order UUID, workflow, success, and error code. No new compensation decision or
client mutation route is introduced.

Dev interruption tests are no longer guaranteed to remain pending indefinitely:
the worker can complete eligible intents once they reach the configured age.
Restart recovery acceptance should inspect `ShopPurchaseState` and worker logs,
then replay the original test request to verify no duplicate charge or grant.

Committed-but-unacknowledged delivery acceptance uses a fresh funded order:

```text
ShopPurchaseRecoveryTest 1 refund-delivered-001 grant
# restart Shops
ShopRefundDeliveredTest 1 refund-delivered-001
```

The grant checkpoint delivers two apples while leaving execution paid. The
delivered test requires an existing committed Inventory receipt before attempting
compensation, verifies repeated refund refusal and unchanged balances, then
recovers fulfillment with the same instance IDs and no additional grants.
Expect refundRefused=true, balancesUnchanged=true, state=fulfilled,
sameInstances=true. Use existing 200 test funding if still available, not new
funding. The purchase consumes that balance; it is deliberately not refundable.

For initial acceptance, fund a fresh two-apple order near the test shop:

```text
EconomyShopFundingTest 1 refund-fund-001
ShopPurchaseRecoveryTest 1 refund-live-001 undelivered
ShopRefundLiveTest 1 refund-live-001 refund
```

The undelivered checkpoint records payment without attempting an item grant.
Refund expects state=refunded, refundedOnce=true, replayed=true,
deliveryBlocked=true. Funding remains in the buyer wallet after reversal; this
test does not destroy the test funding. For restart replay, repeat the refund
command with mode retry, without new funding. For the acknowledgement-interruption
scenario use a fresh funded undelivered order and mode interrupt, restart Shops,
then use mode retry. Never use a new order/request ID to recover an uncertain refund.

```text
ShopCompensationFenceTest 1 purchase-live-001
```

Expect 5/5 passes and cancellationFirstReplayed=false. The test cancels an isolated
`dev-cancel:<order UUID>` key and verifies the actual fulfilled purchase cannot be
cancelled. It moves no funds and grants no items. Restart Inventory, manually
start Shops if stopped by dependency shutdown, and repeat the same command;
cancellationFirstReplayed must become true.

## Inventory fulfillment acceptance

Inventory's trusted `GrantCharacterItemOnce` export atomically commits ordinary
item grants and a payload-bound durable receipt in `inventory_grant_receipts`.
Its request contains `grantId`, `characterId`, `definitionId`, `itemName`, and
integer `quantity`. Exact retries return the original instance IDs; altered
payloads fail with `idempotency_conflict`. Capacity failures roll back the receipt
and items together. Unique items still require their owning issuer.

With Shops `DevMode=true`, the server-console-only `ShopFulfillmentLiveTest`
grants a prepared order's items once using `dev-order:<order UUID>`. This is a
free acceptance grant, isolated from future production payment keys. It neither
changes the order state nor moves money. Nothing fulfills automatically.

```text
InventoryFulfillmentContractSmokeTest
ShopFulfillmentLiveTest 1 order-test-001
```

The first command expects 6/6 passes and grants nothing. The second expects
quantity=2, firstReplayed=false, replayed=true, sameInstances=true, and
mismatchRejected=true. It creates two apples. Restart Inventory (then manually
start Shops if dependency shutdown stopped it) and rerun the same command;
firstReplayed must now be true and no additional apples should appear. These
are server Lua changes; no Inventory UI build or generated assets are involved.

## Tests

Run in the server console:

```text
ShopFoundationSmokeTest
ShopQuoteContractSmokeTest
ShopQuoteLiveTest <active source near Valentine test shop>
ShopOrderContractSmokeTest
ShopOrderPersistenceTest <active source> <fresh requestId> prepare
# restart feather-shops, then:
ShopOrderPersistenceTest <active source> <same requestId> retry
```

Restart feather-shops and repeat. UUIDs and configured prices must remain
unchanged; startup should report zero migrations applied on subsequent runs.

The quote contract test expects 11/11 passes. The live test requires the player
within four metres of the configured shop at -322.13, 803.65, 117.88 and expects
quantity=2, total=200. Outside that range it must reject with `out_of_range`.
Neither test moves funds, provisions wallets, or grants items.

The order contract test expects 7/7 passes. Prepare requires proximity to the
test shop; retry is a stored receipt lookup and does not require proximity.
Persistence tests expect status=prepared, replayed=true, mismatchRejected=true,
count=1 and an unchanged order UUID after restart. They create no inventory items
and make no Economy calls.

## Next slice

Durable orders, authoritative session-bound quotes, Economy payment,
idempotent Inventory fulfillment, compensation, and restart reconciliation.
Player-owned shops, selling, management UI, and NPC buying are deferred.
