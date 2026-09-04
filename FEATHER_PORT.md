# BCC Banks Feather port

Status: Feather port implemented; runtime smoke testing required before release

The player-facing menus, branches, NPCs, prompts, translations, checks, loans,
gold exchange, and safety-deposit gameplay remain BCC Banks responsibilities.
Feather services replace framework plumbing and authoritative shared state.

## Completed foundation

- `bcc-utils` is no longer loaded. RPC call sites use Feather Core named
  exports directly; prompt call sites use Feather Toolkit named exports directly.
- Character identity resolves from Feather Core sessions and Character profiles;
  money is backed by temporary Economy wallets.
- Notifications use Feather Notify through Core/client exports.
- BCC character-reference columns are upgraded to Feather `CHAR(36)` UUIDs.
- BCC displayed bank accounts link to separate dollars and gold Economy accounts.
- Existing BCC account balances are lazily imported through idempotent issuance.
- The temporary Economy implementation uses integer units, a balanced journal,
  caller-scoped idempotency, account locks, and a durable pending Audit outbox.
- Player menus use Feather Menu v2 Contract 1 through the local compatibility
  layer in `client/feather/menu_v2.lua`, preserving the existing BCC menu/page
  code structure. Raw HTML is reduced to safe text because v2 does not
  expose an HTML element contract.

## Temporary boundaries

`server/feather/economy.lua` owns tables prefixed
`bcc_banks_temp_economy_`. Audit delivery is disabled. These tables require a
reconciled migration before the file is removed.

Physical checks, gold-bar exchange, lockpick durability, and safety-deposit
containers use Feather Inventory's published contracts.

## Remaining work

1. Replace the temporary Economy file with the shared Feather Economy resource when published.
2. Vendor the final Audit producer kit, validate pending facts, and enable delivery.
3. Reconcile existing balances and run concurrency/restart/idempotency tests.
4. Revalidate the menu adapter when Feather Menu v2 moves beyond `2.0.0-alpha.2`.
