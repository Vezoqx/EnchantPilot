local _, ns = ...
local A = {}
ns.Auction = A

local open, scan, generation, lastSend = false, nil, 0, -math.huge
local state, reason = 'auction_idle', nil
local abandoned, foreignItems, hooks = {}, {}, {}
local sending, foreignAt, foreignBrowse = false, -math.huge, false
local foreignReplicate = false
local abandonedSummary = false
local resultAt = {}
local events = {
    COMMODITY_SEARCH_RESULTS_UPDATED=true, COMMODITY_SEARCH_RESULTS_ADDED=true,
    ITEM_SEARCH_RESULTS_UPDATED=true, ITEM_SEARCH_RESULTS_ADDED=true,
}
A.Events = {'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED', 'AUCTION_HOUSE_THROTTLED_SYSTEM_READY',
    'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED', 'AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED',
    'AUCTION_HOUSE_BROWSE_RESULTS_UPDATED', 'AUCTION_HOUSE_BROWSE_RESULTS_ADDED', 'AUCTION_HOUSE_BROWSE_FAILURE',
    'REPLICATE_ITEM_LIST_UPDATE'}
for event in pairs(events) do A.Events[#A.Events+1] = event end

local function validID(id)
    return type(id) == 'number' and id > 0 and id <= 2147483647 and id == math.floor(id)
end

local function variant(link)
    if (issecretvalue and issecretvalue(link)) or type(link) ~= 'string' then return end
    local payload = link:match('item:([^|]+)')
    if not payload or #payload > 512 or not payload:match('^[%d:-]+$') then return end
    local parts = {}
    for field in (payload .. ':'):gmatch('(.-):') do
        if field ~= '' and not field:match('^%-?%d+$') then return end
        parts[#parts+1] = tonumber(field) or 0
    end
    if not validID(parts[1]) then return end
    -- Fields 8 through 10 describe the link's owner and viewing context.
    for i=8,math.min(#parts,10) do parts[i]=0 end
    while parts[#parts] == 0 do parts[#parts]=nil end
    return table.concat(parts, ':')
end

local function equipmentCacheKey(item)
    local signature = item and item.auctionable and variant(item.link)
    if signature and validID(item.itemLevel) then return 'gear:' .. item.itemLevel .. ':' .. signature end
end

function A.MarketKey()
    local version, build, _, interface = GetBuildInfo()
    if version ~= '1.60.1' or tostring(build) ~= '70959' or interface ~= 16001 then return nil end
    local region = GetCurrentRegion and GetCurrentRegion()
    local realm = GetRealmName and GetRealmName()
    if validID(region) and type(realm) == 'string' and realm ~= '' then
        return 'wowf:' .. region .. ':' .. realm
    end
end

local function marketRows(market, create)
    local cache = ns.db.auctionCache
    if type(cache) ~= 'table' or cache.schema ~= 1 or type(cache.markets) ~= 'table' then
        if not create then return end
        cache = {schema=1, markets={}}
        ns.db.auctionCache = cache
    end
    local rows = cache.markets[market]
    if type(rows) ~= 'table' and create then rows = {}; cache.markets[market] = rows end
    if type(rows) == 'table' then return rows end
end

function A.EquipmentPrice(item)
    local key, market = equipmentCacheKey(item), A.MarketKey()
    local rows = key and market and marketRows(market)
    local row = rows and rows[key]
    if type(row) == 'table' and row.marketKey == market then return row end
end

function A.GetPrices(itemIDs, marketKey)
    local prices = {}
    if not marketKey or marketKey ~= A.MarketKey() then return prices end
    local rows = marketRows(marketKey)
    if rows then
        for _, id in ipairs(itemIDs) do
            local row = rows[id]
            if type(row) == 'table' and row.marketKey == marketKey and row.itemID == id then prices[id] = row end
        end
    end
    return prices
end

local function summaryMarket()
    local market = A.MarketKey()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if market and (faction == "Alliance" or faction == "Horde") then return market .. ":" .. faction end
end

function A.GetSummary()
    local market = summaryMarket()
    local cache = ns.db.auctionSummaries
    return market and type(cache) == 'table' and cache[market] or nil
end

function A.GetStatus(includeSnapshot)
    local market = A.MarketKey()
    local latest
    if includeSnapshot and market then
        for _, row in pairs(marketRows(market) or {}) do
            if type(row) == 'table' and row.complete and row.marketKey == market and type(row.scannedAt) == 'number' then
                latest = math.max(latest or row.scannedAt, row.scannedAt)
            end
        end
    end
    return {state=state, reason=reason, generation=generation, marketKey=market,
        scannedAt=latest, current=scan and scan.id, open=open}
end

local function save(complete, offers)
    local rows = marketRows(scan.market, true)
    local cacheKey = scan.equipment and scan.equipment.key.itemID == scan.id and scan.equipment.cacheKey or scan.id
    local existing = rows[cacheKey]
    if not complete and type(existing) == 'table' and existing.complete then return end
    local stamp = GetServerTime()
    if type(stamp) ~= 'number' or stamp <= 0 or stamp >= math.huge or stamp ~= math.floor(stamp) then return end
    rows[cacheKey] = {itemID=scan.id, itemKey=scan.key, marketKey=scan.market, source='C_AuctionHouse',
        scannedAt=stamp, complete=complete, whole=scan.commodity == false, offers=offers}
    if complete and scan.report then
        local key = #offers > 0 and 'priced' or 'empty'
        scan.report[key] = scan.report[key] + 1
    end
end

function A.Stop(why)
    local report = scan and scan.report
    local awaiting = scan and scan.awaiting
    local summary = scan and scan.summary and scan
    if scan and scan.awaiting then
        -- Result events carry a key only. An unresolved request cannot safely reuse that key this UI session.
        if summary then abandonedSummary = true else abandoned[scan.id] = true end
    end
    scan = nil
    state, reason = why and 'auction_stopped' or 'auction_done', why
    if report then report.done(report.priced, report.empty, report.total, why, awaiting) end
    if summary and summary.done then summary.done(summary.count, why, awaiting) end
end

local function observe(method, keyed)
    if hooks[method] or type(C_AuctionHouse[method]) ~= 'function' then return end
    hooksecurefunc(C_AuctionHouse, method, function(key)
        if sending then return end
        foreignAt = GetTime()
        if keyed then
            local id = type(key) == 'table' and key.itemID or key
            if validID(id) then foreignItems[id] = true end
        else
            foreignBrowse = method ~= 'ReplicateItems' or foreignBrowse
            if method == 'ReplicateItems' then foreignReplicate = true end
        end
        if scan then A.Stop('auction_conflict') end
    end)
    hooks[method] = true
end

local function installObservers()
    if not C_AuctionHouse or type(hooksecurefunc) ~= 'function' then return false end
    for _, method in ipairs({'SendSearchQuery','SendSellSearchQuery','RequestMoreCommoditySearchResults','RequestMoreItemSearchResults'}) do
        observe(method, true)
    end
    for _, method in ipairs({'SendBrowseQuery','RequestMoreBrowseResults','SearchForItemKeys','SearchForFavorites','ReplicateItems'}) do observe(method, false) end
    return true
end

function A.StartSummary(onDone, automatic)
    if scan then return false, 'auction_busy' end
    if not open then return false, 'auction_open_first' end
    if abandonedSummary then return false, 'auction_summary_unresolved' end
    if foreignBrowse or foreignReplicate or next(foreignItems) or GetTime() - foreignAt < (automatic and 3 or 1) then
        return false, 'auction_wait_external'
    end
    local api, market = C_AuctionHouse, summaryMarket()
    local ok, observing = pcall(installObservers)
    if not market or not ok or not observing or not GetServerTime or not api.SendBrowseQuery
        or not api.GetBrowseResults or not api.HasFullBrowseResults or not api.RequestMoreBrowseResults
        or not api.IsThrottledMessageSystemReady then return false, 'auction_unavailable' end
    local now = GetTime()
    generation = generation + 1
    scan = {summary=true, paging=false, market=market, done=onDone, rows={}, count=0, deadline=now+25, endAt=now+300}
    state, reason = 'auction_scanning', 'auction_summary_scanning'
    return true
end

function A.Start(itemIDs, onDone, equipment)
    if scan then return false, 'auction_busy' end
    local market = A.MarketKey()
    local api = C_AuctionHouse
    if not open then A.Stop('auction_open_first'); return false, reason end
    local ok, observing = pcall(installObservers)
    if not ok or not observing or not market or not api.SendSearchQuery or not api.IsThrottledMessageSystemReady
        or not api.MakeItemKey or not api.GetItemKeyInfo or not api.HasSearchResults or not GetServerTime then
        A.Stop('auction_unavailable'); return false, reason
    end
    if onDone and (foreignBrowse or foreignReplicate or GetTime() - foreignAt < 3) then
        return false, 'auction_wait_external'
    end
    local requested, gear = {}, nil
    if equipment then
        local cacheKey = equipmentCacheKey(equipment)
        if not cacheKey or not ItemLocation or not api.GetItemKeyFromItem or not C_Item or not C_Item.GetItemGUID then
            return false, 'de_item_unavailable'
        end
        local location = ItemLocation:CreateFromBagAndSlot(equipment.bag, equipment.slot)
        local valid, key = pcall(function()
            local guid = C_Item.GetItemGUID(location)
            if (issecretvalue and issecretvalue(guid)) or guid ~= equipment.guid then return end
            return api.GetItemKeyFromItem(location)
        end)
        if not valid or (issecretvalue and issecretvalue(key)) or type(key) ~= 'table' then
            return false, 'de_item_unavailable'
        end
        for _, field in ipairs({'itemID','itemLevel','itemSuffix','battlePetSpeciesID'}) do
            local value = key[field]
            if (issecretvalue and issecretvalue(value)) or type(value) ~= 'number'
                or value ~= math.floor(value) or math.abs(value) > 2147483647 then return false, 'de_item_unavailable' end
        end
        if key.itemID ~= equipment.itemID then return false, 'de_item_unavailable' end
        gear = {key=key, cacheKey=cacheKey, signature=variant(equipment.link)}
        requested[#requested+1] = key.itemID
    end
    for _, id in ipairs(type(itemIDs) == 'table' and itemIDs or {}) do requested[#requested+1] = id end
    local ids, seen = {}, {}
    for _, id in ipairs(requested) do
        if validID(id) and not seen[id] then
            if abandoned[id] then A.Stop('auction_pending_old'); return false, reason end
            if foreignItems[id] then
                if onDone then return false, 'auction_wait_external' end
                A.Stop('auction_conflict'); return false, reason
            end
            seen[id] = true
            ids[#ids+1] = id
        end
    end
    if #ids == 0 then A.Stop('auction_choose_recipe'); return false, reason end
    generation = generation + 1
    scan = {ids=ids, index=1, market=market, deadline=GetTime()+25, endAt=GetTime()+120, equipment=gear}
    if onDone then scan.report = {priced=0, empty=0, total=#ids, done=onDone} end
    state, reason = 'auction_scanning', nil
    return true
end

local function sameKey(a, b)
    return type(a) == 'table' and a.itemID == b.itemID and a.itemLevel == b.itemLevel
        and a.itemSuffix == b.itemSuffix and a.battlePetSpeciesID == b.battlePetSpeciesID
end

local function collectSummary(results)
    if type(results) ~= 'table' then return false end
    for _, row in ipairs(results) do
        local id = row.itemKey and row.itemKey.itemID
        local price = row.minPrice
        if validID(id) and type(price) == 'number' and price > 0 and price < math.huge
            and price == math.floor(price) and type(row.totalQuantity) == 'number' and row.totalQuantity > 0 then
            local old = scan.rows[id]
            if not old then scan.count = scan.count + 1 end
            scan.rows[id] = math.min(old or price, price)
        end
    end
    return true
end

function A.OnEvent(event, key, newAuctionID)
    if event == 'AUCTION_HOUSE_SHOW' then
        open = true
        pcall(installObservers)
    elseif event == 'AUCTION_HOUSE_THROTTLED_SYSTEM_READY' then
        if scan then scan.ready = true end
    elseif event == 'AUCTION_HOUSE_CLOSED' then
        open, foreignBrowse, foreignReplicate = false, false, false
        if scan then A.Stop('auction_closed') end
    elseif event == 'REPLICATE_ITEM_LIST_UPDATE' then
        foreignReplicate = false
        foreignAt = GetTime()
    elseif event == 'AUCTION_HOUSE_BROWSE_RESULTS_UPDATED' or event == 'AUCTION_HOUSE_BROWSE_RESULTS_ADDED'
        or event == 'AUCTION_HOUSE_BROWSE_FAILURE' then
        if scan and scan.summary then
            if not scan.awaiting then return end
            if event == 'AUCTION_HOUSE_BROWSE_FAILURE' then
                scan.awaiting = false
                A.Stop('auction_conflict')
                return
            end
            if (event == 'AUCTION_HOUSE_BROWSE_RESULTS_ADDED') ~= scan.paging then return end
            local ok, collected = pcall(function()
                return collectSummary(scan.paging and key or C_AuctionHouse.GetBrowseResults())
            end)
            scan.awaiting = false
            if ok and collected then scan.event = true else A.Stop('auction_partial') end
            return
        end
        if event == 'AUCTION_HOUSE_BROWSE_FAILURE' or not C_AuctionHouse.HasFullBrowseResults
            or C_AuctionHouse.HasFullBrowseResults() then foreignBrowse = false end
        foreignAt = GetTime()
        if scan and scan.awaiting then A.Stop('auction_conflict') end
    elseif event == 'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED' and scan then
        A.Stop('auction_conflict')
    elseif event == 'AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED' and not sending then
        foreignAt = GetTime()
        if scan then A.Stop('auction_conflict') end
    elseif events[event] then
        local id = type(key) == 'table' and key.itemID or key
        if validID(id) then
            foreignItems[id] = nil
            resultAt[id] = GetTime()
        end
        if scan and scan.summary then A.Stop('auction_conflict'); return end
        if not scan or not scan.awaiting then return end
        local commodity = event:sub(1, 9) == 'COMMODITY'
        if not ((commodity and id == scan.id) or (not commodity and sameKey(key, scan.key))) then return end
        if newAuctionID ~= nil or (scan.commodity ~= nil and scan.commodity ~= commodity) then return end
        if event:sub(-5) == 'ADDED' and not scan.pages then return end
        scan.commodity, scan.event = commodity, true
    end
end

local function offersFrom(api, key, commodity)
    local count = commodity and api.GetNumCommoditySearchResults(key) or api.GetNumItemSearchResults(key)
    local offers = {}
    for i = 1, count do
        local row
        if commodity then row = api.GetCommoditySearchResultInfo(key, i)
        else row = api.GetItemSearchResultInfo(key, i) end
        if not row or not validID(row.quantity) then return nil end
        local quantity = row.quantity
        local price
        if commodity then
            price = row.unitPrice
            if type(row.numOwnerItems) ~= 'number' or row.numOwnerItems < 0 or row.numOwnerItems > quantity
                or row.numOwnerItems ~= math.floor(row.numOwnerItems) then return nil end
            quantity = quantity - row.numOwnerItems
            if row.containsAccountItem then quantity = 0 end
        elseif not row.containsOwnerItem and not row.containsAccountItem
            and (not scan.equipment or scan.equipment.key.itemID ~= key.itemID
                or variant(row.itemLink) == scan.equipment.signature) then
            price = row.buyoutAmount
        end
        if price ~= nil and (type(price) ~= 'number' or price < 0 or price >= math.huge or price ~= math.floor(price)) then
            return nil
        end
        if commodity and (not price or price == 0) then return nil end
        if price and price > 0 and quantity > 0 then offers[#offers+1] = {price=price, quantity=quantity} end
    end
    return offers
end

local function send(fn, ...)
    sending, lastSend = true, GetTime()
    local ok, value = pcall(fn, ...)
    sending = false
    if not ok then error(value) end
    return value
end

local function complete(api, key)
    local offers = offersFrom(api, key, scan.commodity)
    save(offers ~= nil, offers)
    if not offers then A.Stop('auction_partial'); return end
    local ids, index, market, endAt = scan.ids, scan.index+1, scan.market, scan.endAt
    if not ids[index] then A.Stop(); return end
    scan = {ids=ids, index=index, market=market, deadline=GetTime()+25, endAt=endAt, report=scan.report,
        equipment=scan.equipment}
end

local function pulseSummary(api, now)
    if scan.awaiting then return end
    if scan.event and api.HasFullBrowseResults() then
        local stamp = GetServerTime()
        if type(stamp) ~= 'number' or stamp <= 0 or stamp >= math.huge or stamp ~= math.floor(stamp) then
            A.Stop('auction_unavailable')
            return
        end
        if type(ns.db.auctionSummaries) ~= 'table' then ns.db.auctionSummaries = {} end
        ns.db.auctionSummaries[scan.market] = {prices=scan.rows, scannedAt=stamp, count=scan.count}
        A.Stop()
    elseif now - lastSend >= 0.65 then
        scan.awaiting, scan.deadline = true, now + 25
        if scan.event then
            scan.event, scan.paging = false, true
            send(api.RequestMoreBrowseResults)
        else
            send(api.SendBrowseQuery, {searchString="", sorts={}, filters={}, itemClassFilters={}})
        end
    end
end

local function pulse()
    if not scan then return end
    local market = scan.summary and summaryMarket() or A.MarketKey()
    if not open or market ~= scan.market then A.Stop('auction_context'); return end
    local now, api = GetTime(), C_AuctionHouse
    if now >= math.min(scan.deadline, scan.endAt) then
        if scan.id then save(false) end
        A.Stop('auction_timeout')
        return
    end
    if foreignBrowse or foreignReplicate or now - foreignAt < 1 then return end
    if not scan.ready and now < (scan.throttleAt or 0) then return end
    scan.ready, scan.throttleAt = false, now + 0.25
    if not api.IsThrottledMessageSystemReady() then return end
    if scan.summary then pulseSummary(api, now); return end
    if scan.event then
        local key, hasFull, more = scan.key, api.HasFullItemSearchResults, api.RequestMoreItemSearchResults
        if scan.commodity then
            key, hasFull, more = scan.id, api.HasFullCommoditySearchResults, api.RequestMoreCommoditySearchResults
        end
        if not api.HasSearchResults(scan.key) then
            scan.event = false
        elseif hasFull(key) then
            scan.awaiting = false
            complete(api, key)
        elseif now - lastSend >= 0.65 then
            if (scan.pages or 0) >= 40 then save(false); A.Stop('auction_partial'); return end
            scan.event, scan.pages = false, (scan.pages or 0) + 1
            local alreadyFull = send(more, key)
            if alreadyFull and scan then scan.event = true end
        end
    elseif not scan.awaiting and now - lastSend >= 0.65 then
        local id = scan.ids[scan.index]
        if foreignItems[id] then A.Stop('auction_conflict'); return end
        if now - (resultAt[id] or -math.huge) < 1 or now < (scan.metadataAt or 0) then return end
        scan.id, scan.key = id, scan.key or (scan.equipment and scan.equipment.key.itemID == id and scan.equipment.key)
            or api.MakeItemKey(id, 0, 0, 0)
        scan.metadataAt = now + 0.5
        local info = api.GetItemKeyInfo(scan.key)
        if not info or type(info.isCommodity) ~= 'boolean' then return end
        if scan.equipment and scan.equipment.key.itemID == id and info.isCommodity then
            A.Stop('de_item_unavailable'); return
        end
        scan.commodity = info.isCommodity
        scan.awaiting = true
        send(api.SendSearchQuery, scan.key, {}, true, 0, 0)
    end
end

function A.Pulse()
    if not scan then return end
    local ok = pcall(pulse)
    if not ok then A.Stop('auction_unavailable') end
end
