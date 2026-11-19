local _, ns = ...
local Inventory = {}
ns.Inventory = Inventory

-- Data-only candidate filtering. The client still decides whether Disenchant
-- can be cast on an item; this module never casts or uses an item.
local function readable(value, wanted)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    return wanted == nil or type(value) == wanted
end

local function integer(value, minimum, maximum)
    return readable(value, "number") and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function lastBag()
    if integer(NUM_TOTAL_EQUIPPED_BAG_SLOTS, 0, 10) then return NUM_TOTAL_EQUIPPED_BAG_SLOTS end
    if integer(NUM_BAG_SLOTS, 0, 10) then return NUM_BAG_SLOTS end
    return 4
end

local function hasAPI()
    return type(C_Container) == "table" and type(C_Item) == "table"
        and type(ItemLocation) == "table"
        and type(ItemLocation.CreateFromBagAndSlot) == "function"
        and type(C_Container.GetContainerNumSlots) == "function"
        and type(C_Container.GetContainerItemInfo) == "function"
        and type(C_Container.GetContainerItemQuestInfo) == "function"
        and type(C_Item.GetItemGUID) == "function"
        and type(C_Item.GetItemInfo) == "function"
end

local function currentGUID(bag, slot)
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local guid = C_Item.GetItemGUID(location)
    if not readable(guid, "string") or guid == "" then return nil end
    return guid
end

local function protectionInput(protectedGUID, keepTable)
    if not readable(protectedGUID) then return false, "item_identity_missing" end
    if protectedGUID ~= nil and (type(protectedGUID) ~= "string" or protectedGUID == "") then
        return false, "item_identity_missing"
    end
    if not readable(keepTable) or (keepTable ~= nil and type(keepTable) ~= "table") then
        return false, "keep_data_unavailable"
    end
    return true
end

local function equipmentGUIDs()
    if type(C_EquipmentSet) ~= "table"
        or type(C_EquipmentSet.GetNumEquipmentSets) ~= "function"
        or type(C_EquipmentSet.GetEquipmentSetIDs) ~= "function"
        or type(C_EquipmentSet.GetEquipmentSetInfo) ~= "function"
        or type(C_EquipmentSet.GetItemIDs) ~= "function"
        or type(C_EquipmentSet.GetItemLocations) ~= "function" then
        return nil, "equipment_sets_unavailable"
    end
    local numSets = C_EquipmentSet.GetNumEquipmentSets()
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not integer(numSets, 0, 2147483647) or not readable(setIDs, "table") then
        return nil, "equipment_set_data_pending"
    end
    local seen, foundSets = {}, 0
    for index, setID in pairs(setIDs) do
        if not integer(index, 1, numSets) or not integer(setID, 0, 2147483647) or seen[setID] then
            return nil, "equipment_set_data_pending"
        end
        seen[setID], foundSets = true, foundSets + 1
    end
    if foundSets ~= numSets then return nil, "equipment_set_data_pending" end
    local protected = {}
    for _, setID in pairs(setIDs) do
        if type(EquipmentManager_GetLocationData) ~= "function" then
            return nil, "equipment_sets_unavailable"
        end
        local name, icon, summaryID, isEquipped, numItems, numEquipped,
            numInInventory, numLost, numIgnored = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if not integer(summaryID, 0, 2147483647) or summaryID ~= setID
            or not integer(numItems, 0, 32) or not integer(numEquipped, 0, 32)
            or not integer(numInInventory, 0, 32) or not integer(numLost, 0, 32)
            or not integer(numIgnored, 0, 32) then
            return nil, "equipment_set_data_pending"
        end
        local summarizedItems = numEquipped + numInInventory + numLost
        if summarizedItems > numItems or numLost > 0 then return nil, "equipment_set_data_pending" end
        -- Ignored slots need no item identity. The categorized item counts
        -- remain a lower bound even if the total also includes ignored slots.
        local requiredItems = math.max(summarizedItems, numItems - numIgnored)
        local ids = C_EquipmentSet.GetItemIDs(setID)
        local locations = C_EquipmentSet.GetItemLocations(setID)
        if not readable(ids, "table") or not readable(locations, "table") then
            return nil, "equipment_set_data_pending"
        end
        -- A partially loaded item-ID table must not erase protection for a
        -- location that the set still reports as occupied.
        for equipmentSlot, packed in pairs(locations) do
            if not integer(equipmentSlot, 1, 32) or not integer(packed, 0, 2147483647) then
                return nil, "equipment_set_data_pending"
            end
            if packed > 1 and not integer(ids[equipmentSlot], 1, 2147483647) then
                return nil, "equipment_set_data_pending"
            end
        end
        local foundItems = 0
        for equipmentSlot, itemID in pairs(ids) do
            if not integer(itemID, -1, 2147483647) then return nil, "equipment_set_data_pending" end
            if itemID > 0 then
                foundItems = foundItems + 1
                if not integer(equipmentSlot, 1, 32) then return nil, "equipment_set_data_pending" end
                local packed = locations[equipmentSlot]
                if not integer(packed, 0, 2147483647) then return nil, "equipment_set_data_pending" end
                local data = EquipmentManager_GetLocationData(packed)
                if not readable(data, "table") or not readable(data.isPlayer, "boolean")
                    or not readable(data.isBank, "boolean") or not readable(data.isBags, "boolean") then
                    return nil, "equipment_set_data_pending"
                end
                if data.isPlayer and data.isBags and not data.isBank then
                    if not integer(data.bag, 0, lastBag()) or not integer(data.slot, 1, 200) then
                        return nil, "equipment_set_data_pending"
                    end
                    local info = C_Container.GetContainerItemInfo(data.bag, data.slot)
                    if not readable(info, "table") or not readable(info.itemID, "number")
                        or info.itemID ~= itemID then return nil, "equipment_set_data_pending" end
                    local guid = currentGUID(data.bag, data.slot)
                    if not guid then return nil, "equipment_set_data_pending" end
                    protected[guid] = true
                elseif data.isBank then
                    -- A known bank location cannot be one of our bag candidates.
                elseif data.isPlayer and not data.isBags and integer(data.slot, 1, 32) then
                    -- Equipped items are never scanned. Do not block a spare by ID.
                else
                    return nil, "equipment_set_data_pending"
                end
            end
        end
        if foundItems < requiredItems then return nil, "equipment_set_data_pending" end
    end
    return protected
end

local function requestData(itemID)
    if type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local function readCandidate(bag, slot, protectedGUID, keepTable, includeRare, includeEpic, setGUIDs, expected)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not readable(info) then return nil, "item_data_pending" end
    if info == nil then return nil, expected and "item_changed" or "empty" end
    if not readable(info, "table") then return nil, "item_data_pending" end
    local guid = currentGUID(bag, slot)
    if not guid then return nil, "item_identity_missing" end
    if expected and guid ~= expected.guid then return nil, "item_changed" end
    if not integer(info.itemID, 1, 2147483647) or not readable(info.hyperlink, "string")
        or info.hyperlink == "" then return nil, "item_data_pending" end
    if expected and info.itemID ~= expected.itemID then return nil, "item_changed" end
    if not readable(info.isLocked, "boolean") then return nil, "item_data_pending" end
    if info.isLocked then return nil, "item_locked" end
    if guid == protectedGUID then return nil, "enchant_target" end
    local kept = keepTable and keepTable[guid]
    if not readable(kept) then return nil, "keep_data_unavailable" end
    if kept then return nil, "kept" end
    if setGUIDs[guid] then return nil, "equipment_set" end

    local quest = C_Container.GetContainerItemQuestInfo(bag, slot)
    if not readable(quest, "table") or not readable(quest.isQuestItem, "boolean")
        or not readable(quest.questID) then return nil, "item_data_pending" end
    if quest.isQuestItem or (quest.questID ~= nil and quest.questID ~= 0) then return nil, "quest_item" end

    local name, link, quality, itemLevel, minLevel, itemType, subtype, stack,
        equipLoc, icon, sellPrice, classID, subclassID, bindType = C_Item.GetItemInfo(info.hyperlink)
    if not readable(name, "string") or name == "" or not readable(link, "string")
        or not readable(quality, "number") or not readable(equipLoc, "string")
        or not readable(classID, "number") or not readable(bindType, "number")
        or not readable(sellPrice, "number") or not readable(icon, "number") then
        requestData(info.itemID)
        return nil, "item_data_pending"
    end
    if bindType == 4 or classID == 12 then return nil, "quest_item" end
    if classID ~= 2 and classID ~= 4 then return nil, "not_equipment" end
    if equipLoc == "" or equipLoc == "INVTYPE_BAG" then return nil, "not_equipment" end
    if quality ~= 2 and not (quality == 3 and includeRare == true)
        and not (quality == 4 and includeEpic == true) then return nil, "quality_blocked" end
    if not readable(info.quality, "number") or info.quality ~= quality then return nil, "item_data_pending" end
    return {
        guid = guid, bag = bag, slot = slot, itemID = info.itemID,
        link = link, name = name, icon = icon, quality = quality, sellPrice = sellPrice,
        classID = classID, itemLevel = readable(itemLevel, "number") and itemLevel or nil,
        auctionable = readable(info.isBound, "boolean") and not info.isBound
            and (bindType == 0 or bindType == 2 or bindType == 3),
    }
end

function Inventory.Scan(protectedGUID, keepTable, includeRare, includeEpic)
    local items = {}
    local stats = {scanned = 0, eligible = 0, blocked = 0, reasons = {}}
    if not hasAPI() then stats.reason = "inventory_api_unavailable"; return items, stats end
    local inputOK, inputReason = protectionInput(protectedGUID, keepTable)
    if not inputOK then stats.reason = inputReason; return items, stats end
    local ok, setGUIDs, reason = pcall(equipmentGUIDs)
    if not ok or not setGUIDs then
        stats.reason = ok and reason or "equipment_set_data_pending"
        return items, stats
    end
    for bag = 0, lastBag() do
        local gotSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if not gotSlots or not integer(slots, 0, 200) then
            stats.reason = "inventory_api_unavailable"
            stats.eligible = 0
            return {}, stats
        end
        for slot = 1, slots do
            local readOK, item, blockedReason = pcall(readCandidate, bag, slot, protectedGUID,
                keepTable, includeRare, includeEpic, setGUIDs)
            if not readOK then item, blockedReason = nil, "item_data_pending" end
            if blockedReason ~= "empty" then stats.scanned = stats.scanned + 1 end
            if item then
                items[#items + 1] = item
            elseif blockedReason ~= "empty" then
                stats.blocked = stats.blocked + 1
                stats.reasons[blockedReason] = (stats.reasons[blockedReason] or 0) + 1
            end
        end
    end
    stats.eligible = #items
    return items, stats
end

function Inventory.Validate(item, protectedGUID, keepTable, includeRare, includeEpic)
    if not readable(item, "table") or not readable(item.guid, "string") or item.guid == ""
        or not integer(item.bag, 0, lastBag()) or not integer(item.slot, 1, 200)
        or not integer(item.itemID, 1, 2147483647) then return false, "item_changed" end
    if not hasAPI() then return false, "inventory_api_unavailable" end
    local inputOK, inputReason = protectionInput(protectedGUID, keepTable)
    if not inputOK then return false, inputReason end
    local ok, setGUIDs, reason = pcall(equipmentGUIDs)
    if not ok or not setGUIDs then return false, ok and reason or "equipment_set_data_pending" end
    local readOK, current, blockedReason = pcall(readCandidate, item.bag, item.slot, protectedGUID,
        keepTable, includeRare, includeEpic, setGUIDs, item)
    if not readOK then return false, "item_data_pending" end
    return current ~= nil, blockedReason
end

function Inventory.SetKeep(keepTable, guid, value)
    if not readable(keepTable, "table") or not readable(guid, "string") or guid == ""
        or not readable(value, "boolean") then return false, "item_identity_missing" end
    keepTable[guid] = value and true or nil
    return true
end
