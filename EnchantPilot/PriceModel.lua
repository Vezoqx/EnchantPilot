local _, ns = ...
local P = {}
ns.PriceModel = P

local function integer(n, minimum)
    return type(n) == 'number' and n >= minimum and n < math.huge and n == math.floor(n)
end

function P.CombineRecipes(plan, getCount)
    local materials, byID = {}, {}
    for _, entry in ipairs(plan) do
        if not integer(entry.count, 1) or entry.count > 500 then return end
        for _, material in ipairs(entry.materials) do
            local row = byID[material.itemID]
            if not row then
                row = {itemID=material.itemID, name=material.name, icon=material.icon,
                    per=0, have=getCount(material.itemID)}
                byID[material.itemID] = row
                materials[#materials+1] = row
            end
            row.per = row.per + material.per * entry.count
        end
    end
    return materials
end

function P.CheapestUnitBuyout(price, now, maxAge)
    if not integer(now, 1) or not integer(maxAge, 0) then return end
    if not price or price.complete ~= true or not integer(price.scannedAt, 1)
        or price.scannedAt > now or now - price.scannedAt > maxAge
        or type(price.offers) ~= "table" then return end
    local cheapest
    for _, offer in ipairs(price.offers) do
        if type(offer) ~= "table" or not integer(offer.price, 1) or not integer(offer.quantity, 1) then return end
        local unit = price.whole and offer.price / offer.quantity or offer.price
        cheapest = math.min(cheapest or unit, unit)
    end
    return cheapest
end

local function disenchantAverage(outcomes, unitPrice)
    local total, weight = 0, 0
    for _, row in ipairs(outcomes) do
        local cheapest = unitPrice(row[1])
        if not cheapest then return end
        -- shortcut: use the midpoint until observed mean quantities are available.
        total = total + cheapest * (row[2] + row[3]) / 2 * row[4]
        weight = weight + row[4]
    end
    if weight > 0 then return math.floor(total / weight + 0.5) end
end

function P.DisenchantValue(outcomes, prices, now, maxAge)
    return disenchantAverage(outcomes, function(id) return P.CheapestUnitBuyout(prices[id], now, maxAge) end)
end

function P.DisenchantSummaryValue(outcomes, summary, now, maxAge, partial)
    if type(summary) ~= "table" or type(summary.prices) ~= "table"
        or not integer(now, 1) or not integer(maxAge, 0) or not integer(summary.scannedAt, 1)
        or summary.scannedAt > now or now - summary.scannedAt > maxAge then return end
    local function unit(id)
        local price = summary.prices[id]
        if integer(price, 1) then return price end
    end
    if partial then return unit(outcomes[1][1]) end
    return disenchantAverage(outcomes, unit)
end

function P.SummaryUnitPrice(summary, id, now, maxAge)
    return P.DisenchantSummaryValue({{id}}, summary, now, maxAge, true)
end

local function cost(offers, needed, whole)
    if type(offers) ~= 'table' then return nil, 'auction_partial' end
    if #offers == 0 then return nil, 'auction_missing' end
    local ordered, total, lots = {}, 0, 0
    for _, offer in ipairs(offers) do
        if type(offer) ~= 'table' or not integer(offer.quantity, 1) or not integer(offer.price, 1) then
            return nil, 'auction_partial'
        end
        ordered[#ordered+1] = offer
    end
    -- shortcut: whole lots are estimated by unit price, upgrade if exact basket optimization is required.
    table.sort(ordered, function(a, b)
        local left = whole and a.price * b.quantity or a.price
        local right = whole and b.price * a.quantity or b.price
        if left == right then return a.quantity < b.quantity end
        return left < right
    end)
    for _, offer in ipairs(ordered) do
        local quantity = whole and offer.quantity or math.min(offer.quantity, needed)
        lots = lots + 1
        total = total + (whole and offer.price or offer.price * quantity)
        needed = needed - quantity
        if needed <= 0 then return total, nil, -needed, whole and lots or nil end
    end
    return nil, 'auction_volume'
end

local function addCost(result, needed, record, itemID, missing)
    if needed == 0 then return 0, nil, 0 end
    local value, issue, extra, lots
    if record == nil then issue = 'auction_missing'
    elseif not record.complete then issue = 'auction_partial'
    else value, issue, extra, lots = cost(record.offers, needed, record.whole == true) end
    if issue then
        result.total, result.issue = nil, result.issue or issue
        missing[itemID] = issue
    elseif result.total then
        result.total, result.extra = result.total + value, result.extra + extra
    end
    return value, issue, extra, lots
end

function P.SummaryBuyEstimate(shopping, prices, fromScratch)
    local total = 0
    for id, row in pairs(shopping) do
        local quantity = row.needed
        if fromScratch then quantity = row.required end
        if not integer(quantity, 0) then return end
        if quantity > 0 then
            local minimum = prices[id]
            if not integer(minimum, 1) then return end
            total = total + quantity * minimum
        end
    end
    if integer(total, 0) then return total end
end

function P.Quote(materials, casts, reserveCasts, prices, context)
    if type(materials) ~= 'table' or #materials == 0 or not integer(casts, 0) or not integer(reserveCasts, 0) then
        return {issue='auction_invalid_plan'}
    end
    local result = {one={total=0, extra=0}, series={total=0, extra=0}, buy={total=0, extra=0},
        full={total=0, extra=0}, missing={}, shopping={}}
    local seen = {}
    for _, mat in ipairs(materials) do
        if type(mat) ~= 'table' or not integer(mat.itemID, 1) or not integer(mat.per, 1)
            or seen[mat.itemID] or (mat.have ~= nil and not integer(mat.have, 0))
            or (mat.bank ~= nil and not integer(mat.bank, 0)) then
            return {issue='auction_invalid_plan'}
        end
        seen[mat.itemID] = true
        local record = prices and prices[mat.itemID]
        if type(record) ~= 'table' or not context or not context.marketKey or record.marketKey ~= context.marketKey then
            record = nil
        end
        if record then
            result.whole = result.whole or record.whole == true
            result.source = result.source or record.source
            if integer(record.scannedAt, 1) then
                result.scannedAt = math.min(result.scannedAt or record.scannedAt, record.scannedAt)
                result.latestAt = math.max(result.latestAt or record.scannedAt, record.scannedAt)
            end
        end
        addCost(result.one, mat.per, record, mat.itemID, result.missing)
        addCost(result.series, mat.per * casts, record, mat.itemID, result.missing)
        local required = mat.per * (casts + reserveCasts)
        addCost(result.full, required, record, mat.itemID, result.missing)
        local row = {have=mat.have, bank=mat.bank, required=required}
        result.shopping[mat.itemID] = row
        if mat.have == nil and required > 0 then
            row.issue = 'auction_stock_unknown'
            result.buy.total, result.buy.issue = nil, row.issue
        else
            row.needed = math.max(0, required - (mat.have or 0) - (mat.bank or 0))
            row.total, row.issue, row.extra, row.lots = addCost(result.buy, row.needed, record, mat.itemID, result.missing)
        end
    end
    if result.scannedAt and integer(context.now, 1) then
        result.age = math.max(0, context.now - result.scannedAt)
        result.stale = result.age >= (integer(context.staleAfter, 1) and context.staleAfter or 1800)
    end
    return result
end
