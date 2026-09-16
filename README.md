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

Orders currently remain `prepared`. No payment, grant, refund, or automatic
reconciliation runs. Future states will be introduced through a new migration.
These records intentionally remain as development receipts; do not delete them
to retry an operation. Like quotes, order snapshots contain server-only identity.

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
