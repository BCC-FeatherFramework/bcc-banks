# BCC Banks Feather port

Status: 3.0.0, Feather port on the Feather Economy ledger, with loans owed through
feather-contracts and bank actions recorded in feather-audit. `BanksReleaseSmokeTest` is the
read-only release check; `BanksAcceptanceTest` runs the live acceptance with nobody connected
(48 passed, 0 failed on the development server, 18 October 2026), and the in-game restart in the
middle of a menu passed the same day. The one-time balance
migration is not needed on this server: no temporary-economy data exists.

The player-facing menus, branches, NPCs, prompts, translations, checks, loans,
gold exchange, and safety-deposit gameplay remain BCC Banks responsibilities.
Feather services replace framework plumbing and authoritative shared state.

## Completed foundation

- `bcc-utils` is no longer loaded. RPC call sites use Feather Core named
  exports directly; prompt call sites use Feather Toolkit named exports directly.
- Character identity resolves from Feather Core sessions and Character profiles;
  money lives in feather-economy (see Economy below).
- Notifications use Feather Notify through Core/client exports.
- BCC character-reference columns are upgraded to Feather `CHAR(36)` UUIDs.
- BCC displayed bank accounts link to separate dollars and gold Economy accounts.
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
  `Config.OperatorSupply` of feather-economy allows bcc-banks to create currency only for
  `bank.migration.import` and operator `bank.reserve.funding`.
- Economy does not know these codes in advance: bcc-banks registers each `bank.*` code and the
  movement shapes it may use with `RegisterOperatedReasons` on every start (`REASONS` in
  `server/feather/economy.lua`). Any other code, or a registered code in another shape, is refused.

## Bank administration (Authority)

feather-roles is no longer used. `IsBankAdmin` resolves the player's active Core character and asks
`exports['feather-authority']:Evaluate`; any failure denies. It does not go through
`feather-core:Authorize`, because Core's default policy provider is feather-admin, which denies actions it does not
define. The server console is always allowed (`Config.Admin.allowConsole`).

Allowed, in order:

1. The server console.
2. Feather Admin administrators and owners: characters holding a capability listed in
   `Config.Admin.staffCapabilities` (default `staff.admin.audit.search`, which Admin grants only to
   administrators and owners). Moderators are excluded. (Before 2.0.0 this called a feather-admin
   `GetStaffRole` export that does not exist, so Admin staff were silently denied.)
3. Characters holding `staff.banks.manage` through the bank role (`BccBanksAdminGrant`).
4. Characters holding a feather-jobs job in `Config.Admin.jobs` (default `banker`; on duty when
   `Config.Admin.jobRequireOnDuty`). Needs `bcc-banks` in feather-jobs `trustedReaders`. The job must be
   registered by its owner, for example as a bcc-society job type; until then nobody matches.

- On start (and whenever feather-authority restarts) `server/feather/authority.lua` registers the bcc-banks-owned
  capability `staff.banks.manage`, creates the staff role `staff.banks.admin`, and grants the capability to it.
  All steps are idempotent.
- `BccBanksAdminGrant <server id|character uuid>` / `BccBanksAdminRevoke <server id|character uuid>` (console only)
  assign or clear that role through `ReplaceOwnedStaffAssignment`, which only touches roles bcc-banks owns. A character
  UUID works while the character is offline. `BankAuthority.IsAllowedForCharacter` makes the same decision by UUID.
- This needs `bcc-banks` in every `Config.Access` trust list of `feather-authority/config.lua` (reader, capability
  registrar, role creator, grantor, assigner). Authority's grantor/assigner trust is not limited to owned roles, so
  bank-specific console commands remain restricted to bank-owned roles. Old account assignments are not used; grant the role again for the desired character. Revoking a bank-specific assignment does not remove access granted by an accepted Feather Admin role.

## Branch organizations and reserves

Every row in `bcc_banks` is a Feather Organization (type `business`, key `bcc_bank_<id>`), linked through
`bcc_banks.organization_id`. `server/feather/organizations.lua` creates, activates and links the organization on start
(and for banks created in game), then calls Economy `EnsureOperatedTreasury`, which permanently binds that organization's
treasuries to bcc-banks as the branch reserve.

Bank products move money between customers and their branch reserve with ordinary Economy transfers:

| Product | Into reserve | Out of reserve |
|---|---|---|
| Loans | installments settled by feather-contracts (`contracts.settlement`, see Loans) | `bank.loan.disbursement` |
| Checks | `bank.check.issue` (writer's account) | `bank.check.cash` (from the writer's branch), void refund |
| Safety-deposit boxes | `bank.box.fee` | `bank.box.refund` |
| Gold exchange (branch the player stands at) | `bank.gold.exchange` | `bank.gold.exchange` |
| Staff (Branch Reserve page) | `bank.reserve.deposit` (own wallet) | `bank.reserve.withdraw` (own wallet) |
| Rollbacks | | `bank.compensation` |

Economy accepts these reasons only against a treasury bound to the calling resource, so bcc-banks cannot touch a shop or
government treasury. A reserve starts empty and cannot pay out more than it holds. Capitalize a branch from the console:

```text
BccBanksReserveStatus                                 list branches, organizations and reserve balances
BccBanksReserveFund <bank id> <dollars|gold> <amount> create funds in a branch reserve (bank.reserve.funding)
```

Trust entries this needs: `bcc-banks` in feather-organizations `trustedCreators`/`trustedMutators`/`trustedReaders`,
and `Config.servicePolicy['feather-organizations']['bcc-banks']` (create, update) in feather-admin.

### Branch Reserve page

`/bankadmin` → a branch → **Branch Reserve** shows the reserve's dollar and gold balance and its last ten movements,
and moves money between the reserve and the staff member's own wallet with a required reason (audit event and
character transaction history). `BankAuthority.CanManageReserve` decides who may: bank administrators (Admin staff or
the bank role) manage every branch; a banker job holder only the branch whose organization is the job's employer
(`employerType = 'organization'`, `employerId` = the branch organization in feather-jobs). The Economy reasons are
limited to one direction each: `bank.reserve.deposit` (`actor_wallet_to_operated`) and `bank.reserve.withdraw`
(`operated_to_wallet`). `BankReserve.Status` / `Move` (`server/services/reserve.lua`) are shared with the test.

## Loans (feather-contracts)

An approved loan's amount plus interest is owed in equal installments, one feather-contracts obligation each
(type `bank_loan_installment`, owned by bcc-banks): debtor the borrower, creditor the branch organization, issuer the
system. Settling an installment pays the borrower's wallet into the branch reserve (the organization's treasury).
`server/feather/contracts.lua` is the boundary.

- A loan of N months has N installments; installment k falls due k × `Config.LoanContracts.SecondsPerMonth` real
  seconds after approval (default one day), the last one absorbing the rounding. An installment still unpaid
  `DefaultAfterSeconds` after its due date defaults (Contracts does this).
- Approval (or a claim, for a loan approved without an account) opens the installments first and pays the
  principal second; a failed payout cancels them. Request IDs derive from the loan and the installment number, so a
  repeated approval never opens a second debt.
- Repay pays whole installments, oldest first, from the wallet as the player (`actorSource`); an amount below the
  next installment is refused with that installment's amount. There are no part payments.
- Contracts' `due`, `defaulted` and `settled` events, plus a one-minute sync for events missed while bcc-banks was
  stopped, send the reminder or default mail (`Config.LoanTiming.DailyReminders`), freeze the borrower's accounts on a
  default, and mark the loan paid (unfreezing when no other loan is defaulted) once every installment is settled.
- Installments are rows of `bcc_loans_payments` (`seq`, `obligation_id`, `status`, `paid_at`). An account or a staff
  deletion is refused while the account has an open loan, because deleting it cascades to the loan.

Trust entries: `bcc-banks` in feather-contracts `Config.Access.trustedIssuers`, and
`Config.servicePolicy['feather-contracts']['bcc-banks']` (`contracts.obligation.issue`, `contracts.obligation.cancel`)
in feather-admin.

## Audit (feather-audit)

Every bank action records one `bank.action.recorded` event (version 1, schema `schemas/banks/action_recorded_v1.lua`
in feather-audit): the action as a snake-case key, a bounded summary of its facts (restricted), and the acting
character. `server/helpers/audit.lua` writes it to `bcc_banks_audit_outbox`; a publisher leases batches every
`Config.Audit.pollMilliseconds`, calls `Ingest`, and marks each row delivered (accepted or duplicate), retried with
backoff, or quarantined (kept for operators). This is feather-admin's producer pattern. `BanksAuditOutboxStatus`
prints the outbox by state. `Config.Audit.sourceInstance` must equal feather-audit's `Config.SourceInstance`.

Recorded actions: accounts created, closed, deleted by staff, frozen and unfrozen; account and box access granted and
removed; cash and gold deposits and withdrawals; transfers; checks written, cashed and voided; loan applications,
approvals, rejections, claims and repayments; boxes created, deleted and opened by staff; gold bought, sold and
exchanged from bars; branch reserve deposits and withdrawals; branches created; interest rates and opening hours set.

Known limit: the event is written right after the action, not in the same database transaction. Most bank actions
are feather-economy transfers, which bcc-banks cannot join, so a crash between the two can lose that one event.
Economy's own journal remains the authoritative record of every money movement.

Trust entries: `Config.Producers['bcc-banks']` in feather-audit (`eventPrefixes = { 'bank.action.' }`) and the schema
file in its manifest.

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

## Trust entries (summary)

| Resource | Entries for `bcc-banks` |
|---|---|
| feather-economy `config.lua` | `trustedReaders`, `trustedProvisioners`, `trustedBankProvisioners`, `trustedBankTransactors`, `trustedTreasuryOperators`, `trustedTransactors`; `Config.OperatorSupply['bcc-banks']` |
| feather-organizations `config.lua` | `trustedCreators`, `trustedMutators`, `trustedReaders` |
| feather-authority `config.lua` | `trustedReaders`, `trustedCapabilityRegistrars`, `trustedRoleCreators`, `trustedGrantors`, `trustedAssigners` |
| feather-jobs `config.lua` | `trustedReaders` (bank administration by job) |
| feather-contracts `config.lua` | `Config.Access.trustedIssuers` |
| feather-audit `config.lua` | `Config.Producers['bcc-banks']` (`bank.action.`), schema `schemas/banks/action_recorded_v1.lua` |
| feather-admin `configs/service_policy.lua` | `['feather-organizations']['bcc-banks']` create/update; `['feather-economy']['bcc-banks']['economy.currency.issue']`; `['feather-contracts']['bcc-banks']` obligation issue/cancel |

## Live acceptance

`BanksAcceptanceTest <character A> <character B> [bank id]` (server console) runs items 2 to 8 and 10 with characters
named by UUID, through the same `BankOps` functions and controllers as the menus, then closes its test accounts. It
prints a second command, `BanksAcceptanceTest box <A> <box id>`, to run after a restart: it checks the stored item
survived, empties and deletes the box and refunds it. A needs the cheapest box price plus about $55; B gains $1.00.

| # | Check | Result (18 October 2026) |
|---|---|---|
| 1 | `BanksReleaseSmokeTest`: every line PASS | run before release (fails "development disabled" while `devMode` is on) |
| 2 | Reserve funding and status | PASS |
| 3 | Account: open, deposit, withdraw, frozen, gold, cross-branch transfer with fee | PASS |
| 4 | Sharing at every access level | PASS |
| 5 | Loan: apply, approve, installments in Contracts, repay, reserve down then up | PASS |
| 6 | Check: write, cash by the recipient, void | PASS |
| 7 | Box: buy, store, restart, item still there, delete | PASS |
| 8 | Gold exchange both ways | PASS |
| 9 | Restart bcc-banks in the middle of a menu: no duplicate teller, no money lost | PASS (in game: menu closed, account lock released, one teller, balances unchanged) |
| 10 | Admin access by role; branch reserve by role; job holder reported | PASS (job holder needs a `banker` assignment) |
| | Branch Reserve page; audit delivery and duplicate replay | PASS |

Offline specs (Lua 5.4, no server): `tests/loan_installments_spec.lua` (from the resource folder),
`tests/audit_event_spec.lua` and `tests/chat_suggestion_spec.lua` (from the resources folder).

## Remaining work

1. Before release: `devMode = false`, then `BanksReleaseSmokeTest` (item 1).
2. Feather Menu v2 is checked up to `2.0.0-alpha.8` (alpha.5 to alpha.8 only added elements); recheck when it leaves alpha.
