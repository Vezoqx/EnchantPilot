local _, ns = ...
local W = {}
ns.Workshop = W

function W.Settings()
    local saved = ns.db.workshop
    if type(saved) ~= "table" then saved = {}; ns.db.workshop = saved end
    for _, key in ipairs({"limits", "prices", "series", "orders", "groups"}) do
        if type(saved[key]) ~= "table" then saved[key] = {} end
    end
    return saved
end

function W.RecordPrice(row)
    if not row.complete then return end
    local history = W.Settings().prices
    local market = history[row.marketKey]
    if not market then market = {}; history[row.marketKey] = market end
    local series = market[row.itemID] or {}
    market[row.itemID] = series
    local volume = 0
    for _, offer in ipairs(row.offers) do volume = volume + offer.quantity end
    local price = ns.PriceModel.CheapestUnitBuyout(row, row.scannedAt, 0)
    if #series > 0 and series[1].time == row.scannedAt then table.remove(series, 1) end
    table.insert(series, 1, {time=row.scannedAt, unit=price, volume=volume})
    series[31] = nil
end

function W.Series(session, reason, materials)
    if not session or session.completed == 0 then return end
    local settings = W.Settings()
    local history, row = settings.series
    for _, entry in ipairs(history) do
        if entry.serial == session.workshopSerial then row=entry; break end
    end
    if not row then
        settings.serial = (settings.serial or 0)+1
        row = {serial=settings.serial,name=session.name,id=session.recipeID,time=GetServerTime and GetServerTime()}
        session.workshopSerial = row.serial
        table.insert(history, 1, row)
        history[31] = nil
    end
    row.count, row.goal = session.completed, session.goal
    if reason ~= "ready" and reason ~= "requesting" and reason ~= "confirming" and reason ~= "casting" then
        row.reason = reason
    end
    if session.startSkill and session.currentSkill then row.skill = session.currentSkill - session.startSkill end
    if materials then
        row.materials = {}
        for _, reagent in ipairs(materials) do
            row.materials[#row.materials+1] = {itemID=reagent.itemID, count=reagent.per*row.count, name=reagent.name}
        end
    end
end

function W.BankNeeds(plan, count, bank)
    local rows = ns.PriceModel.CombineRecipes(plan, count) or {}
    local results = {}
    for _, row in ipairs(rows) do
        local available = bank and bank[row.itemID] or 0
        if row.have ~= nil and available > 0 and row.per > row.have then
            row.take = math.min(row.per-row.have, available)
            results[#results+1] = row
        end
    end
    return results
end

function W.Value(item, now, maxAge, cut)
    local auction = ns.Auction
    local outcomes, _, partial = ns.Disenchant.Outcomes(item)
    local loot
    if outcomes and not partial then
        local ids = {}
        for _, outcome in ipairs(outcomes) do ids[#ids+1] = outcome[1] end
        loot = ns.PriceModel.DisenchantValue(outcomes, auction.GetPrices(ids, auction.MarketKey()), now, maxAge)
            or ns.PriceModel.DisenchantSummaryValue(outcomes, auction.GetSummary(), now, maxAge)
    end
    local unit = item.auctionable and ns.PriceModel.CheapestUnitBuyout(auction.EquipmentPrice(item), now, maxAge)
    local factor = (100-cut)/100
    return loot and math.floor(loot*factor), item.sellPrice, unit and math.floor(unit*factor) or nil
end

function W.Deposit(item, duration)
    if not item.auctionable or not C_AuctionHouse or not C_AuctionHouse.CalculateItemDeposit
        or not ItemLocation or not ItemLocation.CreateFromBagAndSlot then return end
    local location = ItemLocation:CreateFromBagAndSlot(item.bag, item.slot)
    local ok, cost = pcall(C_AuctionHouse.CalculateItemDeposit, location, duration, 1)
    if ok and ns.Adapter.IsPublic(cost) and type(cost) == "number" and cost >= 0 and cost < math.huge then return cost end
end

function W.RecipeTools(recipe)
    local api = C_TradeSkillUI
    if not api or not api.GetRecipeRequirements then return end
    local ok, requirements = pcall(api.GetRecipeRequirements, recipe)
    if not ok or not ns.Adapter.IsPublic(requirements) or type(requirements) ~= "table" then return end
    local names, missing = {}, false
    for _, requirement in ipairs(requirements) do
        if not ns.Adapter.IsPublic(requirement) or type(requirement) ~= "table"
            or not ns.Adapter.IsPublic(requirement.name) or not ns.Adapter.IsPublic(requirement.met)
            or type(requirement.name) ~= "string" or type(requirement.met) ~= "boolean" then return end
        names[#names+1] = requirement.name
        if not requirement.met then missing = true end
    end
    return names, not missing
end

function W.Affordable(skill, goal, budget, stageCost)
    local reached, cost = skill, 0
    for target = skill+1, goal do
        local total = stageCost(target)
        if total == nil then return reached, cost, "unknown" end
        if total > budget then return reached, cost, "budget" end
        reached, cost = target, total
    end
    return reached, cost
end

function W.RouteCost(target, preview, reserve)
    local materials, issue, _, _, _, blocked = ns.GoalMaterials("goal", false, preview, target)
    if issue or blocked then return end
    if reserve and reserve > 0 then
        for _, row in ipairs(materials) do
            row.per = math.ceil(row.per * (100+reserve)/100)
        end
    end
    if #materials == 0 then return 0 end
    local quote = ns.QuoteMaterials(materials, 1, 0)
    if not quote.issue and not quote.stale and not quote.buy.issue then return quote.buy.total end
    local summary = ns.Auction.GetSummary()
    local now = GetServerTime and GetServerTime()
    local age = math.max(1,tonumber(ns.db.priceStaleMinutes) or 30)*60
    if not quote.issue and summary and type(summary.scannedAt) == "number" and now
        and now-summary.scannedAt >= 0 and now-summary.scannedAt <= age then
        return ns.PriceModel.SummaryBuyEstimate(quote.shopping, summary.prices)
    end
end

function W.Alternatives(skill, goal, recipes, used, cost)
    local candidates, changes, route = {}, {}, {}
    for first, recipe in pairs(used) do route[first] = recipe end
    local baseline = cost(route)
    if baseline == nil then return changes end
    for _, recipe in ipairs(recipes) do
        if recipe.learned and recipe.canSkillUp and recipe.maxTrivialLevel and recipe.maxTrivialLevel > skill then
            local materials = ns.Adapter.RecipeReagents(recipe.recipeID)
            if materials and #materials > 0 then
                candidates[#candidates+1] = {recipeID=recipe.recipeID, name=recipe.name,
                    materials=materials, gray=recipe.maxTrivialLevel}
            end
        end
    end
    local best = baseline
    -- shortcut: carry the best change into each next stage, use a wider search if cross-stage tradeoffs need global optimization.
    for _, step in ipairs(ns.Leveling.steps) do
        local finish = math.min(goal,step[2])
        if math.max(skill,step[1]) < finish and #step[5] > 0 and step[4] > 1 then
            local previous = route[step[1]]
            local pick, saved = previous, best
            for _, candidate in ipairs(candidates) do
                if candidate.recipeID ~= step[3] and candidate.gray >= finish then
                    route[step[1]] = candidate
                    local value = cost(route)
                    if value and value < saved then pick, saved = candidate, value end
                end
            end
            route[step[1]] = pick
            if pick ~= previous then
                best = saved
                changes[#changes+1] = {first=step[1], last=finish, recipe=pick}
            end
        end
    end
    return changes, baseline, best
end

function W.CanCraft(recipe)
    if not recipe.learned then return false end
    local _, ready = W.RecipeTools(recipe.recipeID)
    if not ready then return false end
    local materials = ns.Adapter.RecipeReagents(recipe.recipeID)
    if not materials then return false end
    for _, reagent in ipairs(materials) do
        if (ns.Adapter.ReagentCount(reagent.itemID) or 0) < reagent.per then return false end
    end
    return true
end

function W.CraftProfit(recipe, now, age, cut)
    local api = C_TradeSkillUI
    if recipe.isEnchantingRecipe or not api or not api.GetRecipeSchematic then return end
    local ok, schematic = pcall(api.GetRecipeSchematic, recipe.recipeID, false)
    if not ok or not ns.Adapter.IsPublic(schematic) or type(schematic) ~= "table" then return end
    local id, amount = schematic.outputItemID, schematic.quantityMin
    if not ns.Adapter.IsPublic(id) or not ns.Adapter.IsPublic(amount)
        or type(id) ~= "number" or id <= 0 or type(amount) ~= "number" or amount < 1 then return end
    if not C_Item or not C_Item.GetItemInfo then return end
    local _, _, _, _, _, _, _, _, _, _, _, _, _, bind = C_Item.GetItemInfo(id)
    if not ns.Adapter.IsPublic(bind) or (bind ~= 0 and bind ~= 2 and bind ~= 3) then return end
    local materials = ns.Adapter.RecipeReagents(recipe.recipeID)
    if not materials or #materials == 0 then return end
    local quote = ns.QuoteMaterials(materials, 1, 0)
    if not quote.full then return end
    local ah, prices = ns.Auction, ns.PriceModel
    local record = ah.GetPrices({id},ah.MarketKey())[id]
    local unit = prices.CheapestUnitBuyout(record, now, age) or prices.SummaryUnitPrice(ah.GetSummary(), id, now, age)
    local cost = not quote.stale and quote.full.total or nil
    if not cost then
        local summary = ah.GetSummary()
        if summary and summary.scannedAt and now and now-summary.scannedAt <= age then
            cost = prices.SummaryBuyEstimate(quote.shopping, summary.prices, true)
        end
    end
    return id, cost, unit and math.floor(unit*amount*(100-cut)/100) or nil
end
