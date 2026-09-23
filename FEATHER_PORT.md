# BCC Banks Feather port

Status: Feather port implemented on the real Feather Economy ledger; runtime smoke testing and the one-time balance migration are still required before release

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

## Economy

Money lives only in Feather Economy (Contract 1 with bank accounts). bcc-banks keeps
no balances and no money tables; `server/feather/economy.lua` only shapes requests and
checks results.

- Each BCC bank account has one Economy `bank` account per currency, referenced by the
  BCC account id, so a character can hold several accounts (for example one per branch).
- Cash deposits and withdrawals at a branch are one atomic wallet <-> account transfer
  (`bank.deposit`, `bank.withdraw`). Joint holders use their own wallet; account access
  rules stay in bcc-banks.
- Account-to-account transfers use `bank.transfer`; transfer fees move to the system
  sink as `bank.fee`.
- Loans, checks, gold exchange and safety-deposit boxes have no counterparty account yet,
  so they still create or destroy currency, but only under the allow-listed reason codes
  in `Config.BankSupply` of feather-economy (Economy 0.1.4 requires a Core policy decision for
  supply; `Config.Authorization.exemptBankSupply = true` exempts exactly these allow-listed
  bank reasons, and setting it to false makes them need policy too) (`bank.loan.disbursement`,
  `bank.loan.repayment`, `bank.check.issue`, `bank.check.cash`, `bank.gold.exchange`,
  `bank.box.fee`, `bank.box.refund`, `bank.compensation`). This is an interim bridge.

## One-time migration from the temporary economy

The retired `bcc_banks_temp_economy_*` tables are left untouched as the record. With
`feather-economy` running, from the server console:

```text
BccBanksEconomyMigrationReport        read-only plan and current state
BccBanksEconomyMigrate confirm        issue the balances, relink bcc_accounts
```

Back up the database first. The migration issues each balance under a fixed key derived
from the temporary account, so it is safe to repeat: a second run issues nothing and
relinks nothing. It refuses to run if a temporary account with money is not linked to a
bank account, if a closed account still holds money, or if the temporary supply does not
balance. Until it has run, accounts show no balance and money operations fail closed.

## Remaining work

1. Give loans, checks and gold exchange real counterparty accounts (a bank reserve or
   organization treasury) and remove the interim supply reasons.
2. Vendor the Audit producer kit, validate pending facts, and enable delivery.
3. Run the live concurrency, restart and idempotency tests against the real ledger.
4. Revalidate the menu adapter when Feather Menu v2 moves beyond `2.0.0-alpha.4`.
