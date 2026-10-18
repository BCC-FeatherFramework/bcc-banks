-- Offline check of server/feather/contracts.lua with a fake DB and Contracts.
-- Run from the resource folder: lua tests/loan_installments_spec.lua
local root = arg and arg[1] or "."
local rows, loans, frozen, tx, calls, wallet = {}, {}, {}, {}, {}, 1000
local obligations, nextOb = {}, 0
Config = { LoanContracts = { SecondsPerMonth = 86400, DefaultAfterSeconds = 86400 } }
BccBanksDatabaseReady = true
function CreateThread() end
function AddEventHandler() end
function Wait() end
function GetResourceState() return 'started' end
function SetOwnerAccountsFrozen(id, f) frozen[id] = f end
function AddLoanTransaction(l, c, a, t, d) tx[#tx + 1] = a end
function GetLoan(id) return loans[id] end
BankOrganizations = { GetReserve = function() return { organizationId = 'org-1' } end }
exports = setmetatable({}, { __index = function(_, name)
  if name == 'feather-contracts' then return setmetatable({}, { __index = function(_, op)
    return function(_, req, ctx)
      calls[#calls + 1] = op
      if op == 'CreateDraft' then nextOb = nextOb + 1; obligations['ob' .. nextOb] = { status = 'draft', amount = req.amount }
        return { ok = true, value = { obligationId = 'ob' .. nextOb } } end
      if op == 'IssueObligation' then obligations[req.obligationId].status = 'issued'; return { ok = true, value = {} } end
      if op == 'SettleObligation' then local o = obligations[req.obligationId]
        if wallet < o.amount then return { ok = false, code = 'insufficient_funds' } end
        wallet = wallet - o.amount; o.status = 'settled'; return { ok = true, value = { status = 'settled' } } end
      if op == 'GetObligation' then return { ok = true, value = obligations[req.obligationId] } end
      return { ok = true, value = {} }
    end end }) end
  return setmetatable({}, { __index = function() return function() return { ok = true, value = {} } end end })
end })
DB = {
  query = function(sql, id) if sql:match('FROM `bcc_loans_payments` WHERE `loan_id`') then
      local out = {} for _, r in ipairs(rows) do if r.loan_id == id then out[#out + 1] = r end end
      table.sort(out, function(a, b) return a.seq < b.seq end) return out end return {} end,
  exec = function(sql, a, b, c, d, e)
    if sql:match('^INSERT INTO `bcc_loans_payments`') then
      rows[#rows + 1] = { id = 'r' .. #rows + 1, loan_id = a, seq = b, amount = c, date_due = 'later', obligation_id = e, status = 'open' }
    elseif sql:match("SET `status` = 'paid'") then for _, r in ipairs(rows) do if r.id == a then r.status = 'paid' end end
    elseif sql:match('SET `status` = "paid"') then loans[a].status = 'paid'
    elseif sql:match('SET `status` = "defaulted"') then loans[a].status = 'defaulted'
    elseif sql:match('SET `status` = %?') then for _, r in ipairs(rows) do if r.id == c then r.status = a end end end
    return 1 end,
  value = function(sql) if sql:match('UUID') then return 'attempt' end return 0 end,
}
dofile(root .. '/server/feather/contracts.lua')
BankLoanContracts.ready = true

loans.L = { id = 'L', bank_id = 'b', character_id = 'C', duration = 3, status = 'approved' }
local opened = BankLoanContracts.OpenInstallments(loans.L, 10.00)
assert(opened.ok and opened.value.count == 3)
assert(rows[1].amount == 3.33 and rows[2].amount == 3.33 and math.abs(rows[3].amount - 3.34) < 1e-9, 'split with remainder on the last')
local low = BankLoanContracts.Pay(loans.L, 3.00)
assert(not low.ok and low.code == 'below_installment' and low.next == 3.33)
local two = BankLoanContracts.Pay(loans.L, 7.00)
assert(two.ok and two.paid == 2 and math.abs(two.amount - 6.66) < 1e-9 and loans.L.status == 'approved', 'pays whole installments only')
wallet = 1
local broke = BankLoanContracts.Pay(loans.L, 5)
assert(not broke.ok and broke.code == 'insufficient_funds' and rows[3].status == 'open')
wallet = 10000 -- minor units
local last = BankLoanContracts.Pay(loans.L, 5)
assert(last.ok and last.paid == 1 and loans.L.status == 'paid' and frozen.C == false, 'last installment closes and unfreezes')
local summary = BankLoanContracts.Summary('L')
assert(summary.total == 3 and summary.paid == 3 and not summary.nextAmount)

loans.M = { id = 'M', bank_id = 'b', character_id = 'D', duration = 1, status = 'approved' }
BankLoanContracts.OpenInstallments(loans.M, 5)
obligations[rows[4].obligation_id].status = 'defaulted'
local changed = BankLoanContracts.Sync('M')
assert(#changed == 1 and changed[1].status == 'defaulted' and loans.M.status == 'defaulted' and frozen.D == true, 'default freezes')
print('loan installment spec PASS')
