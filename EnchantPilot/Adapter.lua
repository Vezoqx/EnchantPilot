local _, ns = ...
local A = {}
ns.Adapter = A

local function public(value)
    return not (issecretvalue and issecretvalue(value))
end
A.IsPublic = public
local function number(value)
    return public(value) and type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end
local function stringValue(value)
    return public(value) and type(value) == 'string'
end
local function call(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, ...)
    if ok and public(value) then return value end
end

function A.Page()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage
end

function A.NativeTarget()
    local ok,guid,reason=pcall(function()
        local page=A.Page()
        local form=page and page.SchematicForm
        if not form or not form.GetTransaction then return nil end
        local transaction=form:GetTransaction()
        if not transaction or not transaction.GetEnchantAllocation then return nil end
        local item=transaction:GetEnchantAllocation()
        if not item then return nil end
        local value=item:GetItemGUID()
        if not stringValue(value) or value=='' then return nil,'unknown_target' end
        return value
    end)
    if not ok then return nil,'unknown_target' end
    return guid,reason
end

function A.IsBusy()
    local casting = UnitCastingInfo and UnitCastingInfo('player')
    local channeling = UnitChannelInfo and UnitChannelInfo('player')
    return not public(casting) or not public(channeling) or casting ~= nil or channeling ~= nil
end

function A.IsMoving()
    if type(GetUnitSpeed)=='function' then
        local speed=call(GetUnitSpeed,'player')
        if not number(speed) then return nil,'restricted_data' end
        return speed>0
    end
    if type(IsPlayerMoving)=='function' then
        local moving=call(IsPlayerMoving)
        if type(moving)=='boolean' then return moving end
    end
    return nil,'api_unavailable'
end

local popupKinds = {'REPLACE_TRADESKILL_ENCHANT', 'REPLACE_ENCHANT', 'BIND_ENCHANT', 'TRADE_REPLACE_ENCHANT', 'TRADE_POTENTIAL_BIND_ENCHANT'}
function A.AnyPopup()
    if StaticPopup_ForEachShownDialog then
        local first
        StaticPopup_ForEachShownDialog(function(frame) if not first then first = frame end end)
        if first then return first end
    end
    if StaticPopup_FindVisible then
        for _, kind in ipairs(popupKinds) do
            local frame = StaticPopup_FindVisible(kind)
            if frame then return frame end
        end
    end
    for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local frame = _G['StaticPopup' .. i]
        if frame and frame.IsShown and frame:IsShown() then return frame end
    end
end

function A.ReplacementPopup()
    if not StaticPopup_FindVisible then return nil end
    return StaticPopup_FindVisible('REPLACE_TRADESKILL_ENCHANT') or StaticPopup_FindVisible('REPLACE_ENCHANT')
end

local function materialData(transaction, schematic)
    local infos = transaction and transaction:GetCraftingReagentInfos() or {}
    local tokens, quantities, bySlot = {}, {}, {}
    for _, info in ipairs(infos) do
        local reagent = info.reagent or {}
        local id, currency, quantity, index = reagent.itemID, reagent.currencyID, info.quantity, info.dataSlotIndex
        if not public(id) or not public(currency) or not number(quantity) or not number(index) then return nil, 'restricted_data' end
        if quantity > 0 then
            if not number(id) or currency ~= nil then return nil, 'unsupported_reagents' end
            tokens[#tokens + 1] = index .. ':' .. id .. ':' .. quantity
            quantities[id] = (quantities[id] or 0) + quantity
            bySlot[index] = true
        end
    end
    for i, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local quantity, index = slot.quantityRequired, slot.dataSlotIndex or i
        if not number(quantity) or not number(index) or not public(slot.required) then return nil, 'restricted_data' end
        local required = slot.required or (Enum and Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
        if required and quantity > 0 and not bySlot[index] then
            local choices = slot.reagents or {}
            if #choices ~= 1 or not number(choices[1].itemID) then return nil, 'unsupported_reagents' end
            local id = choices[1].itemID
            quantities[id] = (quantities[id] or 0) + quantity
            tokens[#tokens + 1] = index .. ':' .. id .. ':' .. quantity
        end
    end
    local concentration = transaction and transaction.IsApplyingConcentration and transaction:IsApplyingConcentration()
    if not public(concentration) then return nil, 'restricted_data' end
    tokens[#tokens + 1] = 'concentration:' .. (concentration and '1' or '0')
    table.sort(tokens)
    local materials, maximum = {}, nil
    for id, quantity in pairs(quantities) do
        -- Bag-only quantities: do not promise a batch using inaccessible bank stock.
        local count = A.ReagentCount(id)
        if not number(count) then return nil, 'unknown_materials' end
        local name, link, _, _, _, _, _, _, _, icon
        if C_Item.GetItemInfo then name, link, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(id) end
        materials[#materials + 1] = {itemID=id, per=quantity, have=count,
            name=stringValue(name) and name or ('#' .. id), link=stringValue(link) and link or nil,
            icon=number(icon) and icon or 134400}
        local countForReagent = math.floor(count / quantity)
        maximum = maximum and math.min(maximum, countForReagent) or countForReagent
    end
    table.sort(materials, function(a,b) return a.itemID < b.itemID end)
    return {key=table.concat(tokens, ';'), materials=materials, maximum=maximum}
end

local function currentRecipe(forPrices)
    if InCombatLockdown and InCombatLockdown() then return nil, 'combat' end
    local page = A.Page()
    if not page or not ProfessionsFrame.IsShown or not ProfessionsFrame:IsShown() or (page.IsShown and not page:IsShown()) then return nil, 'profession_closed' end
    local form = page.SchematicForm
    if not form or not form.GetRecipeInfo or not form.GetTransaction or not C_Item or not C_TradeSkillUI then return nil, 'api_unavailable' end
    if call(C_TradeSkillUI.IsTradeSkillLinked) or call(C_TradeSkillUI.IsTradeSkillGuild) or call(C_TradeSkillUI.IsTradeSkillGuildMember) then return nil, 'foreign_profession' end
    if forPrices then
        local profession = call(C_TradeSkillUI.GetBaseProfessionInfo)
        if type(profession) ~= 'table' or not number(profession.professionID) or profession.professionID ~= 333 then
            return nil, 'not_enchanting'
        end
    end
    local selected = form:GetRecipeInfo()
    if type(selected) ~= 'table' then return nil, 'choose_recipe' end
    if not number(selected.recipeID) then return nil,'restricted_data' end
    local recipeLevel = form.GetCurrentRecipeLevel and form:GetCurrentRecipeLevel() or nil
    if not public(recipeLevel) then return nil,'restricted_data' end
    -- SchematicForm retains currentRecipeInfo across refreshes. Re-read live
    -- difficulty/learned state so a gray recipe cannot stay falsely skillable.
    if type(C_TradeSkillUI.GetRecipeInfo)~='function' then return nil,'api_unavailable' end
    local info = call(C_TradeSkillUI.GetRecipeInfo,selected.recipeID,recipeLevel)
    if type(info)~='table' then return nil,'unknown_recipe' end
    if not number(info.recipeID) or not public(info.learned) or not public(info.disabled) or not public(info.canSkillUp) then return nil, 'restricted_data' end
    if info.recipeID~=selected.recipeID then return nil,'recipe_changed' end
    if not info.learned or info.disabled then return nil, 'recipe_unavailable' end
    local transaction = form:GetTransaction()
    if not transaction or (not forPrices and not transaction.GetEnchantAllocation)
        or not transaction.GetCraftingReagentInfos or not transaction.GetRecipeSchematic then return nil, 'api_unavailable' end
    local schematic = transaction:GetRecipeSchematic()
    if type(schematic) ~= 'table' or not number(schematic.recipeType) then return nil, 'unknown_recipe' end
    local isEnchant = Enum and Enum.TradeskillRecipeType and schematic.recipeType == Enum.TradeskillRecipeType.Enchant
    if not forPrices and not isEnchant then return nil, 'not_enchant' end
    return {page=page, info=info, recipeLevel=recipeLevel, transaction=transaction, schematic=schematic, isEnchant=isEnchant}
end

function A.ReagentCount(id)
    local count = C_Item and call(C_Item.GetItemCount, id, false, false, false, false)
    if number(count) and count >= 0 and count == math.floor(count) then return count end
end

function A.PersonalBankCounts()
    local bank = Enum and Enum.BankType and Enum.BankType.Character
    local containers = C_Container
    if bank == nil or not C_Bank or not containers
        or not containers.GetContainerItemID or not containers.GetContainerItemInfo
        or call(C_Bank.CanViewBank, bank) ~= true then return end
    local tabs = call(C_Bank.FetchPurchasedBankTabIDs, bank)
    local purchased = call(C_Bank.FetchNumPurchasedBankTabs, bank)
    if not public(tabs) or type(tabs) ~= "table" or not number(purchased)
        or purchased < 1 or #tabs ~= purchased then return end
    local counts, seen = {}, {}
    for _, tab in ipairs(tabs) do
        if not number(tab) or seen[tab] then return end
        seen[tab] = true
        local slots = call(containers.GetContainerNumSlots, tab)
        if not number(slots) or slots < 1 then return end
        for slot=1,slots do
            local ok, info = pcall(containers.GetContainerItemInfo, tab, slot)
            if not ok or not public(info) then return end
            if type(info) == "table" then
                local id, count = info.itemID, info.stackCount
                if not number(id) or id < 1 or not number(count) or count < 1 then return end
                counts[id] = (counts[id] or 0)+count
            else
                local read, id = pcall(containers.GetContainerItemID, tab, slot)
                if info ~= nil or not read or not public(id) or id ~= nil then return end
            end
        end
    end
    return counts
end

local function recipeMaterials(recipeID)
    local schematic = C_TradeSkillUI and call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        return nil, "auction_recipe_materials_pending"
    end
    local data, reason = materialData(nil, schematic)
    if not data then return nil, reason end
    if #data.materials == 0 then return nil, "auction_recipe_materials_pending" end
    return data
end

local function priceRecipeCache()
    local _, build = GetBuildInfo()
    local key = tostring(build) .. ":" .. GetLocale()
    local cache = ns.db.priceRecipeCache
    if type(cache) ~= "table" or cache.key ~= key or type(cache.rows) ~= "table" then
        cache = {key=key, rows={}}
        ns.db.priceRecipeCache = cache
    end
    return cache.rows
end

function A.CachePriceRecipes(recipes)
    local cache = priceRecipeCache()
    for _, recipe in ipairs(recipes) do
        if recipe.learned and not cache[recipe.recipeID] then
            local ok, data = pcall(recipeMaterials, recipe.recipeID)
            if ok and data then cache[recipe.recipeID] = data.materials end
        end
    end
end

function A.PriceRecipe(recipe)
    local cache = priceRecipeCache()
    local ok, data, reason = pcall(recipeMaterials, recipe.recipeID)
    if ok and data then cache[recipe.recipeID] = data.materials end
    local materials = cache[recipe.recipeID]
    if not materials then return nil, reason or "auction_recipe_materials_pending" end
    return {recipeID=recipe.recipeID, name=recipe.name, icon=recipe.icon, materials=materials, shoppingOnly=true}
end

function A.RecipeReagents(id)
    if not ns.db or not number(id) then return end
    local cache = priceRecipeCache()
    if not cache[id] then
        local ok, data = pcall(recipeMaterials, id)
        if ok and data then cache[id] = data.materials end
    end
    return cache[id]
end

function A.PrepareEnchantRecipe(id)
    if not number(id) or id < 1 or id ~= math.floor(id) then return false, 'recipe_unavailable' end
    if InCombatLockdown and InCombatLockdown() then return false, 'combat' end
    local ok, recipe = pcall(currentRecipe)
    if ok and recipe and recipe.info.recipeID == id then return true end
    if not C_TradeSkillUI or type(C_TradeSkillUI.OpenRecipe) ~= 'function' then return false, 'api_unavailable' end
    if not pcall(C_TradeSkillUI.OpenRecipe, id) then return false, 'recipe_select_failed' end
    return false, 'choose_target'
end

local function enchantTargetGUIDs(recipeID, reagents)
    local allowed = C_TradeSkillUI and call(C_TradeSkillUI.GetEnchantItems, recipeID, reagents)
    local guids = {}
    if type(allowed) == 'table' then
        for _, guid in ipairs(allowed) do
            if stringValue(guid) and guid ~= '' then guids[guid] = true end
        end
    end
    return guids
end

local function matchesItemMask(mask, index)
    return mask == 0 or (number(index) and index >= 0 and index <= 31 and math.floor(mask / 2^index) % 2 == 1)
end

local function eligibleEnchantTarget(recipeID, allowed, item)
    if not item or not C_Item or not C_TradeSkillUI then return end
    local guid = call(item.GetItemGUID, item)
    if not stringValue(guid) or guid == '' then return end
    local rule = ns.EnchantTargetRules and ns.EnchantTargetRules[recipeID]
    if not allowed[guid] and (next(allowed) or not rule
        or call(C_TradeSkillUI.IsEnchantTargetValid, recipeID, guid) ~= true) then return end
    local location = call(item.GetItemLocation, item)
    if not location or call(C_Item.DoesItemExist, location) ~= true
        or call(C_Item.IsLocked, location) ~= false or call(item.IsStackable, item) ~= false then return end
    local inventoryType = call(C_Item.GetItemInventoryType, location)
    if not number(inventoryType) or inventoryType <= 0 then return end
    local link = call(item.GetItemLink, item)
    if rule then
        if not stringValue(link) or not C_Item.GetItemInfoInstant then return end
        local ok, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, link)
        if not ok or not number(classID) or classID ~= rule[1]
            or not matchesItemMask(rule[2], inventoryType) or not matchesItemMask(rule[3], subclassID) then return end
    end
    if stringValue(link) then return guid, link end
end

function A.EnchantTargets(recipeID)
    local targets = {}
    if not Item or not C_Container or not number(recipeID) then return targets end
    local allowed = enchantTargetGUIDs(recipeID)
    local function add(item, bag, slot)
        local guid, link = eligibleEnchantTarget(recipeID, allowed, item)
        if guid then
            local level = C_Item and call(C_Item.GetDetailedItemLevelInfo,link)
            targets[#targets+1] = {guid=guid,link=link,bag=bag,slot=slot,icon=call(item.GetItemIcon,item),
                level=number(level) and level or nil, enchant=tonumber(link:match('item:%d+:(%d+)'))}
        end
    end
    for bag = 0, (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0) do
        local count = call(C_Container.GetContainerNumSlots, bag)
        if number(count) then
            for slot = 1, count do add(call(Item.CreateFromBagAndSlot, Item, bag, slot), bag, slot) end
        end
    end
    for slot = 1, 19 do add(call(Item.CreateFromEquipmentSlot, Item, slot), nil, slot) end
    return targets
end

function A.ApplyEnchantTarget(recipeID, target)
    local recipe, reason = currentRecipe()
    if not recipe then return false, reason end
    if recipe.info.recipeID ~= recipeID then return false, 'recipe_changed' end
    local item = Item and (target.bag and call(Item.CreateFromBagAndSlot, Item, target.bag, target.slot)
        or (target.bag == nil and call(Item.CreateFromEquipmentSlot, Item, target.slot)))
    local reagents = call(recipe.transaction.CreateCraftingReagentInfoTbl, recipe.transaction)
    if eligibleEnchantTarget(recipeID, enchantTargetGUIDs(recipeID, reagents), item) ~= target.guid then
        return false, 'target_changed'
    end
    local form = recipe.page.SchematicForm
    local event = ProfessionsRecipeSchematicFormMixin and ProfessionsRecipeSchematicFormMixin.Event
    if not form.enchantSlot or not event or not event.AllocationsModified then return false, 'api_unavailable' end
    local ok = pcall(function()
        recipe.transaction:SetEnchantAllocation(item)
        form.enchantSlot:SetItem(item)
        form:TriggerEvent(event.AllocationsModified)
    end)
    if not ok then return false, 'api_error' end
    return true
end

function A.PriceSelection()
    local ok, selection, reason = pcall(function()
        local recipe, why = currentRecipe(true)
        if not recipe then return nil, why end
        local reagents, errorCode = materialData(recipe.transaction, recipe.schematic)
        if not reagents then return nil, errorCode end
        if #reagents.materials == 0 then return nil, 'auction_recipe_materials_pending' end
        local info = recipe.info
        return {recipeID=info.recipeID, recipeLevel=recipe.recipeLevel, allocationKey=reagents.key, icon=number(info.icon) and info.icon or nil,
            name=stringValue(info.name) and info.name or ('#' .. info.recipeID), materials=reagents.materials,
            isItemCraft=not recipe.isEnchant}
    end)
    if not ok then return nil, 'api_error' end
    return selection, reason
end

local function snapshotInternal()
    local recipe, reason = currentRecipe()
    if not recipe then return nil, reason end
    local page, info, recipeLevel = recipe.page, recipe.info, recipe.recipeLevel
    local transaction, schematic = recipe.transaction, recipe.schematic
    local target = transaction:GetEnchantAllocation()
    if not target then return nil, 'choose_target' end
    local guid = target:GetItemGUID()
    if not stringValue(guid) or guid == '' then return nil, 'unknown_target' end
    local location = target:GetItemLocation()
    if not location or not C_Item.GetItemLocation or not C_Item.DoesItemExist or not C_Item.GetItemGUID then return nil, 'api_unavailable' end
    if not C_Item.DoesItemExist(location) then return nil, 'unknown_target' end
    local actualGUID = C_Item.GetItemGUID(location)
    if not public(actualGUID) then return nil, 'restricted_data' end
    if actualGUID ~= guid then return nil, 'target_changed' end
    local currentLocation = C_Item.GetItemLocation(guid)
    if not currentLocation or not C_Item.DoesItemExist(currentLocation) then return nil, 'unknown_target' end
    local currentGUID = C_Item.GetItemGUID(currentLocation)
    if not public(currentGUID) or currentGUID ~= guid then return nil, 'target_changed' end
    local stackable=call(target.IsStackable,target)
    if stackable==true then return nil,'stackable_target' end
    if stackable~=false then return nil,'item_data_pending' end
    local locked = call(C_Item.IsLocked, currentLocation)
    if locked==true then return nil, 'item_locked' end
    if locked~=false then return nil,'item_data_pending' end
    local reagents, errorCode = materialData(transaction, schematic)
    if not reagents then return nil, errorCode end
    local available = call(C_TradeSkillUI.GetCraftableCount, info.recipeID, recipeLevel)
    if not number(available) then return nil, 'unknown_materials' end
    if reagents.maximum then available = math.min(available, reagents.maximum) end
    available = math.max(0, math.floor(available))
    local profession = call(C_TradeSkillUI.GetProfessionInfoByRecipeID, info.recipeID) or call(C_TradeSkillUI.GetBaseProfessionInfo)
    local spell = C_Spell and call(C_Spell.GetSpellInfo, info.recipeID)
    local link = C_Item.GetItemLink and C_Item.GetItemLink(currentLocation)
    local castTime = spell and spell.castTime
    local canSkillUp
    if type(info.canSkillUp)=='boolean' then canSkillUp=info.canSkillUp end
    local snapshot = {recipeID=info.recipeID, name=stringValue(info.name) and info.name or ('#' .. info.recipeID),
        icon=number(info.icon) and info.icon or 136244, targetGUID=guid,
        targetLink=stringValue(link) and link or (ns.L and ns.L.unknownItem or 'Item'),
        allocationKey=reagents.key, materials=reagents.materials, available=available,
        skillRank=profession and number(profession.skillLevel) and profession.skillLevel or nil,
        maxSkill=profession and number(profession.maxSkillLevel) and profession.maxSkillLevel or nil,
        canSkillUp=canSkillUp,
        castSeconds=number(castTime) and castTime/1000 or nil, recipeLevel=recipeLevel,
        buttonEnabled=page.CreateButton and call(page.CreateButton.IsVisible,page.CreateButton)==true and call(page.CreateButton.IsEnabled,page.CreateButton)==true or false,
        spellIDs={[info.recipeID]=true}}
    if C_Spell then
        local base = call(C_Spell.GetBaseSpell, info.recipeID)
        local override = call(C_Spell.GetOverrideSpell, info.recipeID)
        if number(base) then snapshot.spellIDs[base] = true end
        if number(override) then snapshot.spellIDs[override] = true end
    end
    return snapshot
end

function A.Snapshot()
    local ok, snapshot, reason = pcall(snapshotInternal)
    if not ok then return nil, 'api_error' end
    return snapshot, reason
end

function A.Match(locked, current)
    if not locked or not current then return false, 'invalid_snapshot' end
    if locked.recipeID ~= current.recipeID then return false, 'recipe_changed' end
    if locked.targetGUID ~= current.targetGUID then return false, 'target_changed' end
    if locked.allocationKey ~= current.allocationKey then return false, 'allocation_changed' end
    return true
end

-- Public only to the addon controller. Call this from a physical input handler.
-- No timer, passive event or queue continuation calls this function.
function A.Cast(locked)
    local current, reason = A.Snapshot()
    if not current then return false, reason end
    local matches, mismatch = A.Match(locked, current)
    if not matches then return false, mismatch end
    if A.AnyPopup() then return false, 'existing_popup' end
    if A.IsBusy() then return false, 'busy' end
    local moving,moveReason=A.IsMoving()
    if moving~=false then return false,moveReason or 'moving' end
    if current.available < 1 then return false, 'no_materials' end
    if not current.buttonEnabled then return false, 'native_disabled' end
    local page = A.Page()
    if not page.CreateInternal then return false, 'api_unavailable' end
    local ok = pcall(page.CreateInternal, page, current.recipeID, 1, current.recipeLevel)
    if not ok then return false, 'action_blocked' end
    return true
end

function A.Confirm(locked, dialog)
    -- Retained as a non-action compatibility boundary. Native input owns Yes.
    -- In build 70959 a blocked protected callback can still hide its dialog;
    -- neither pcall success nor a hidden prompt proves an accepted enchant.
    return false, 'confirm_manually'
end

function A.Skill(recipeID)
    local info = C_TradeSkillUI and (call(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID) or call(C_TradeSkillUI.GetBaseProfessionInfo))
    if info and number(info.skillLevel) then
        return info.skillLevel, number(info.maxSkillLevel) and info.maxSkillLevel or nil
    end
end

function A.CastProgress()
    if not UnitCastingInfo then return nil end
    local _, _, _, startMS, endMS, _, _, _, spellID = UnitCastingInfo('player')
    if number(startMS) and number(endMS) and number(spellID) then return startMS/1000, endMS/1000, spellID end
end
