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
- Loans, checks, gold exchange and safety-deposit boxes settle against the branch reserve (see below).
  `Config.BankSupply` of feather-economy now allows bcc-banks to create currency only for
  `bank.migration.import` and operator `bank.reserve.funding`.

## Bank administration (Authority)

feather-roles is no longer used. `IsBankAdmin` resolves the player's active Core character and asks
`exports['feather-authority']:Evaluate` for `staff.banks.manage`; any failure denies. It does not go through
`feather-core:Authorize`, because Core's default policy provider is feather-admin, which denies actions it does not
define. The server console is always allowed (`Config.Admin.allowConsole`).

- Feather Admin Owners and Administrators are allowed through `GetStaffRole`, which reads the active character's current Authority assignment. Configure accepted role keys in `Config.Admin.staffRoles`; moderators are excluded by default.
- On start (and whenever feather-authority restarts) `server/feather/authority.lua` registers the bcc-banks-owned
  capability `staff.banks.manage`, creates the staff role `staff.banks.admin`, and grants the capability to it.
  All steps are idempotent.
- `BccBanksAdminGrant <server id>` / `BccBanksAdminRevoke <server id>` (console only) assign or clear that role for
  the player's active character through `ReplaceOwnedStaffAssignment`, which only touches roles bcc-banks owns.
- This needs `bcc-banks` in every `Config.Access` trust list of `feather-authority/config.lua` (reader, capability
  registrar, role creator, grantor, assigner). Authority's grantor/assigner trust is not limited to owned roles, so
  bank-specific console commands remain restricted to bank-owned roles. Old account assignments are not used; grant the role again for the desired character. Revoking a bank-specific assignment does not remove access granted by an accepted Feather Admin role.

## Branch organizations and reserves

Every row in `bcc_banks` is a Feather Organization (type `business`, key `bcc_bank_<id>`), linked through
`bcc_banks.organization_id`. `server/feather/organizations.lua` creates, activates and links the organization on start
(and for banks created in game), then calls Economy `EnsureBankReserve`, which permanently binds that organization's
treasuries as a bcc-banks reserve.

Bank products move money between customers and their branch reserve with ordinary Economy transfers:

| Product | Into reserve | Out of reserve |
|---|---|---|
| Loans | `bank.loan.repayment` (account or wallet) | `bank.loan.disbursement` |
| Checks | `bank.check.issue` (writer's account) | `bank.check.cash` (from the writer's branch), void refund |
| Safety-deposit boxes | `bank.box.fee` | `bank.box.refund` |
| Gold exchange (branch the player stands at) | `bank.gold.exchange` | `bank.gold.exchange` |
| Rollbacks | | `bank.compensation` |

Economy accepts these reasons only against a treasury bound to the calling resource, so bcc-banks cannot touch a shop or
government treasury. A reserve starts empty and cannot pay out more than it holds. Capitalize a branch from the console:

```text
BccBanksReserveStatus                                 list branches, organizations and reserve balances
BccBanksReserveFund <bank id> <dollars|gold> <amount> create funds in a branch reserve (bank.reserve.funding)
```

Trust entries this needs: `bcc-banks` in feather-organizations `trustedCreators`/`trustedMutators`/`trustedReaders`,
and `Config.servicePolicy['feather-organizations']['bcc-banks']` (create, update) in feather-admin.

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

1. Done: branch reserves replace the interim supply reasons. Next: let bank staff manage their
   branch reserve in game, and move loan obligations to feather-contracts when it exists.
2. Vendor the Audit producer kit, validate pending facts, and enable delivery.
3. Run the live concurrency, restart and idempotency tests against the real ledger.
4. Revalidate the menu adapter when Feather Menu v2 moves beyond `2.0.0-alpha.4`.
