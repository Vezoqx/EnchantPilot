-- Original, native-frame UI. All game-changing actions belong to Core.
local _, ns = ...
local U = {recipePage = 1, inventoryPage = 1, recipeMode = "all", recipesDirty = true}
ns.UI = U
local L = ns.L
local unpackValues = unpack or table.unpack
local C = {
    background = {0.035, 0.052, 0.068, 0.98}, card = {0.065, 0.088, 0.108, 1},
    button = {0.10, 0.14, 0.17, 1}, selected = {0.11, 0.25, 0.25, 1},
    teal = {0.43, 0.86, 0.77, 1}, text = {0.90, 0.94, 0.95, 1},
    muted = {0.60, 0.69, 0.73, 1}, amber = {1, 0.76, 0.43, 1},
    locked = {0.14, 0.36, 0.22, 1}, casting = {0.53, 0.17, 0.20, 1},
    paused = {0.40, 0.30, 0.12, 1},
}
local movedPopups = {}
local RECIPE_ROWS, INVENTORY_ROWS = 9, 5

local function finite(value)
    if issecretvalue and issecretvalue(value) then return false end
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function translated(key)
    return ns.Reason and ns.Reason(key) or L[key] or key or ""
end

local function auctionSummary()
    local summary = ns.Auction and ns.Auction.GetSummary and ns.Auction.GetSummary()
    if type(summary) == "table" and type(summary.prices) == "table"
        and finite(summary.scannedAt) and finite(summary.count) then return summary end
end

local function renderAuctionSummary(summary)
    if not summary then U.auctionSummary:SetText(""); return end
    local now = GetServerTime and GetServerTime()
    local fresh = finite(now) and summary.scannedAt <= now and now - summary.scannedAt <= 900
    U.auctionSummary:SetText(string.format(L.auction_summary_source, summary.count,
        date("%d.%m.%Y %H:%M", summary.scannedAt)))
    if fresh then U.auctionSummary:SetTextColor(0.47, 0.87, 0.57)
    else U.auctionSummary:SetTextColor(1, 0.46, 0.46) end
    return fresh
end

local function money(copper)
    local parts = {}
    local function add(amount, coin)
        parts[#parts+1] = string.format("%d|TInterface\\MoneyFrame\\UI-%sIcon:11:11|t", amount, coin)
    end
    local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
    local remainder = copper % 100
    if gold > 0 then add(gold, "Gold") end
    if silver > 0 then add(silver, "Silver") end
    if remainder > 0 or #parts == 0 then add(remainder, "Copper") end
    return table.concat(parts, "  ")
end

local function estimatedCost(quote, section, summary)
    if not quote or quote.issue then return end
    local result = quote[section]
    if not result.issue and not quote.stale then return result.total end
    if summary then
        local total = ns.PriceModel.SummaryBuyEstimate(quote.shopping, summary.prices, section == "full")
        if total then return total, true end
    end
    if not result.issue then return result.total, true end
end

local function singleCraft(recipe)
    local materials = ns.Adapter.RecipeReagents(recipe.recipeID)
    if not materials then return end
    local rows = {}
    for i, mat in ipairs(materials) do
        rows[i] = {itemID=mat.itemID, per=mat.per, have=ns.Adapter.ReagentCount(mat.itemID)}
    end
    return ns.QuoteMaterials(rows, 1, 0)
end

local function text(parent, x, y, width, height, value, size, color, singleLine)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    label:SetSize(width, height)
    label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 11)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetTextColor(unpackValues(color or C.text))
    label:SetWordWrap(not singleLine)
    if label.SetNonSpaceWrap then label:SetNonSpaceWrap(false) end
    if singleLine and label.SetMaxLines then label:SetMaxLines(1) end
    label:SetText(value or "")
    return label
end

local function fill(parent, x, y, width, height, color, layer)
    local texture = parent:CreateTexture(nil, layer or "BACKGROUND")
    texture:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    texture:SetSize(width, height)
    texture:SetColorTexture(unpackValues(color))
    return texture
end

local function tooltip(frame, value, details)
    frame.tooltip = value
    frame:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.link and GameTooltip.SetHyperlink then
            local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, self.link)
            if ok then GameTooltip:Show(); return end
        end
        local body = details and details(self) or self.tooltip
        if body and body ~= "" then
            GameTooltip:SetText(body, 0.90, 0.94, 0.95, 1, true)
            GameTooltip:Show()
        end
    end)
    frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function button(parent, x, y, width, height, title, onClick, accent, template, name)
    local control = CreateFrame("Button", name, parent, template)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    control:SetSize(width, height)
    control.background = fill(control, 0, 0, width, height, accent and C.selected or C.button)
    if accent then control.accent = fill(control, 0, height - 2, width, 2, C.teal, "BORDER") end
    control.label = text(control, 5, 0, width - 10, height, title, accent and 12 or 10.5, C.text, true)
    control.label:SetJustifyH("CENTER")
    control.label:SetJustifyV("MIDDLE")
    control:SetFontString(control.label)
    control:SetText(title or "")
    control:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    control:GetHighlightTexture():SetVertexColor(0.45, 0.9, 0.85, 0.12)
    -- In particular, do not replace the inherited disenchant OnClick handler.
    if onClick then control:SetScript("OnClick", onClick) end
    return control
end

local function enabled(control, value)
    if value then control:Enable(); control:SetAlpha(1)
    else control:Disable(); control:SetAlpha(0.42) end
end

local function checkbox(parent, x, y, width, title, key, fullText, changed)
    local control = CreateFrame("CheckButton", nil, parent)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    control:SetSize(width, 20)
    local box = fill(control, 0, 2, 16, 16, C.button)
    control:SetNormalTexture(box)
    local mark = fill(control, 4, 6, 8, 8, C.teal, "ARTWORK")
    control:SetCheckedTexture(mark)
    control.label = text(control, 23, 3, width - 23, 16, title, 10, C.text, true)
    control:SetChecked(ns.db[key] == true)
    control:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() == true
        if changed then changed() end
    end)
    tooltip(control, fullText or title)
    return control
end

local function settingsChanged()
    ns.notice = "sessionChanged"
    U.Render(ns.current, ns.snapshotReason)
end

local function input(parent, x, y, width, title, key, hint, changed, maximum)
    local function update(value)
        ns.db[key] = value
        if changed then changed() else settingsChanged() end
    end
    local inset = maximum and 38 or 5
    if maximum then
        fill(parent, x, y, width, 39, C.card)
        text(parent, x + 7, y + 2, width - 14, 14, title, 11, C.text, true)
    else
        text(parent, x, y, width, 14, title, 9.5, C.muted, true)
    end
    local edit = CreateFrame("EditBox", nil, parent)
    edit:SetPoint("TOPLEFT", parent, "TOPLEFT", x + inset, -y - (maximum and 16 or 17))
    local editWidth, editHeight = maximum and width - 72 or width - 6, maximum and 21 or 24
    edit:SetSize(editWidth, editHeight)
    local outline = fill(edit, 0, 0, editWidth, editHeight, C.selected)
    fill(edit, 1, 1, editWidth - 2, editHeight - 2, C.background, "BORDER")
    edit:SetTextInsets(4, 4, 0, 0)
    if maximum then edit:SetJustifyH("CENTER") end
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    edit:SetMaxLetters(key == "skillGoal" and 5 or 3)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetText(tostring(ns.db[key] or 0))
    edit:SetScript("OnEditFocusGained", function() outline:SetColorTexture(unpackValues(C.teal)) end)
    edit:SetScript("OnEditFocusLost", function() outline:SetColorTexture(unpackValues(C.selected)) end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            update(tonumber(self:GetText()) or 0)
        end
    end)
    tooltip(edit, title .. "\n" .. hint)
    if maximum then
        local function step(offset, delta)
            local control = button(parent, x + offset, y + 16, 26, 21, "", function()
                local value = math.max(key == "count" and 1 or 0,
                    math.min(maximum, (tonumber(edit:GetText()) or 0) + delta))
                edit:SetText(tostring(value))
                update(value)
            end)
            for _, side in ipairs({-1, 1}) do
                local stroke = control:CreateTexture(nil, "ARTWORK")
                stroke:SetColorTexture(unpackValues(C.teal))
                stroke:SetSize(6, 1.5)
                stroke:SetPoint("CENTER", control, "CENTER", side * 2, 0)
                stroke:SetRotation(-side * delta * math.pi / 4)
            end
            tooltip(control, delta < 0 and L.numberDecrease or L.numberIncrease)
            return control
        end
        edit.decrease = step(5, -1)
        edit.increase = step(width - 31, 1)
    end
    return edit
end

local function framedIcon(parent, x, y, size)
    fill(parent, x - 1, y - 1, size + 2, size + 2, C.selected, "BORDER")
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    icon:SetSize(size, size)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return icon
end

local function selectionCard(parent, x, title)
    local card = CreateFrame("Button", nil, parent)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
    card:SetSize(198, 64)
    fill(card, 0, 0, 198, 64, C.card)
    card.caption = text(card, 8, 6, 182, 12, title, 9, C.muted, true)
    card.icon = framedIcon(card, 8, 22, 20)
    card.name = text(card, 35, 22, 154, 17, "", 11, C.text, true)
    card.target = text(card, 8, 45, 182, 15, "", 10, C.muted, true)
    tooltip(card)
    return card
end

local function renderSelection(card, snapshot)
    card.name:SetText(snapshot and snapshot.name or L.emptyRecipe)
    card.target:SetText(snapshot and snapshot.targetLink or L.emptyTarget)
    card.icon:SetTexture(snapshot and snapshot.icon or 136244)
    card.link = snapshot and snapshot.targetLink or nil
    card.tooltip = snapshot and ((snapshot.name or L.emptyRecipe) .. "\n" .. (snapshot.targetLink or L.emptyTarget)) or L.selectionHint
end

local function pageRange(page, size, count)
    local pages = math.max(1, math.ceil(count / size))
    page = math.max(1, math.min(page, pages))
    local first = count > 0 and (page - 1) * size + 1 or 0
    return page, first, math.min(page * size, count), pages
end

local function setTab(key)
    if key ~= "recipes" then U.pickingPriceRecipe, U.pickingEnchant, U.pickingPlan = nil, nil, nil end
    U.activeTab = key
    for name, panel in pairs(U.panels) do
        if name == key then panel:Show() else panel:Hide() end
        if U.tabs[name] then
            local selected = name == key or (key == "targets" and name == "enchant")
                or ((key == "budget" or key == "annora") and name == "leveling")
            U.tabs[name].background:SetColorTexture(unpackValues(selected and C.selected or C.button))
            U.tabs[name].label:SetTextColor(unpackValues(selected and C.teal or C.muted))
        end
    end
    if key == "recipes" then U.RenderRecipes()
    elseif key == "plan" then U.RenderPlan()
    elseif key == "budget" then U.RenderBudget()
    elseif key == "annora" then U.RenderAnnora()
    elseif key == "history" then U.RenderHistory()
    elseif key == "leveling" then
        U.guidePage = ns.Leveling.Stage(ns.Leveling.Skill())
        U.RenderGuide()
    elseif key == "disenchant" then
        if ns.RefreshInventory then ns.RefreshInventory() end
        U.RenderInventory()
    else U.Render(ns.current, ns.snapshotReason) end
end

local function createEnchant(panel)
    U.currentCard = selectionCard(panel, 0, L.currentSelection or L.selected)
    U.lockedCard = selectionCard(panel, 206, L.lockedSelection or L.capture)
    U.pickEnchant = button(panel, 0, 70, 99, 24, L.enchant_pick, function()
        U.pickingEnchant = true
        U.recipeMode, U.recipePage = "learned", 1
        setTab("recipes")
    end)
    tooltip(U.pickEnchant, L.enchant_pick_hint)
    U.pickTarget = button(panel, 103, 70, 99, 24, L.enchant_target_pick, function()
        local recipe = ns.enchantRecipe or ns.current or ns.locked
        if not recipe or not ns.Adapter.EnchantTargets then return end
        U.targetRecipe, U.targetPage = recipe, 1
        U.targetSearch:SetText("")
        U.targets = ns.Adapter.EnchantTargets(recipe.recipeID)
        U.RenderTargets()
        setTab("targets")
    end)
    tooltip(U.pickTarget, L.enchant_target_hint)
    U.capture = button(panel, 206, 70, 198, 24, L.capture, function()
        if ns.CaptureEnchant then
            local ok, reason = ns.CaptureEnchant()
            if not ok then U.Render(ns.current, reason) end
        elseif ns.Arm then ns.Arm() end
    end)
    tooltip(U.capture, L.selectionHint .. "\n" .. L.sessionChanged)
    U.inputs = {
        count = input(panel, 0, 102, 128, L.count, "count", L.countHint, nil, 500),
        reserve = input(panel, 138, 102, 128, L.reserveLabel, "reserve", L.reserveHint, nil, 500),
        skillGoal = input(panel, 276, 102, 128, L.skillGoalLabel, "skillGoal", L.skillGoalHint, nil, 99999),
    }
    U.presetButtons = {}
    for i, amount in ipairs({1, 5, 10, 25, "max"}) do
        local value = amount
        U.presetButtons[i] = button(panel, (i - 1) * 82, 149, 76, 20,
            value == "max" and L.max or tostring(value), function()
                local count = value
                if count == "max" then
                    local available = ns.current and ns.current.available or 0
                    count = math.max(1, math.min(500, math.floor(available - (tonumber(U.inputs.reserve:GetText()) or 0))))
                end
                U.inputs.count:SetText(tostring(count))
                U.inputs.count:ClearFocus()
                ns.db.count = count
                settingsChanged()
            end)
    end
    U.checks = {}
    U.checks.stopOnGray = checkbox(panel, 0, 174, 404, L.stopGray, "stopOnGray", nil, settingsChanged)
    text(panel, 0, 198, 404, 22, L.goalHint, 9.5, C.muted)
    U.progress = text(panel, 0, 224, 198, 17, "", 13, C.teal, true)
    U.skill = text(panel, 206, 226, 198, 15, "", 10, C.muted, true)
    U.skill:SetJustifyH("RIGHT")
    U.castBar = CreateFrame("StatusBar", nil, panel)
    U.castBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -246)
    U.castBar:SetSize(404, 14)
    fill(U.castBar, 0, 0, 404, 14, C.card)
    U.castBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    U.castBar:SetStatusBarColor(0.18, 0.58, 0.51, 1)
    U.castBar:SetMinMaxValues(0, 1)
    U.castText = text(U.castBar, 3, 0, 398, 14, "", 9, C.text, true)
    U.castText:SetJustifyH("CENTER")
    U.castText:SetJustifyV("MIDDLE")
    U.materialSummary = text(panel, 0, 267, 236, 24, "", 10, C.muted)
    U.estimate = text(panel, 244, 267, 160, 24, "", 9.5, C.muted)
    U.estimate:SetJustifyH("RIGHT")
    text(panel, 0, 294, 404, 14, L.materials, 10, C.text, true)
    U.materialScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    U.materialScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -312)
    U.materialScroll:SetSize(384, 48)
    U.materialContent = CreateFrame("Frame", nil, U.materialScroll)
    U.materialContent:SetSize(382, 48)
    U.materialScroll:SetScrollChild(U.materialContent)
    U.materialRows = {}
    U.materialEmpty = text(U.materialContent, 0, 2, 376, 32, L.noMaterials, 10, C.muted)
    U.nativeConfirmMode = text(panel, 0, 370, 140, 16, L.native_confirm_mode, 10, C.muted, true)
    U.checks.nearConfirm = checkbox(panel, 145, 367, 159, L.nearShort or L.near, "nearConfirm", L.near)
    U.checks.sound = checkbox(panel, 315, 367, 89, L.soundShort or L.sound, "sound", L.sound)
    text(panel, 0, 392, 404, 26, L.nativeConfirmHint, 9.5, C.muted)
    U.status = text(panel, 0, 422, 404, 31, "", 10.5, C.amber)
    U.action = button(panel, 0, 460, 226, 36, L.start, function() if ns.Act then ns.Act() end end, true)
    U.pause = button(panel, 232, 460, 62, 36, L.pause, function() if ns.Pause then ns.Pause("user_pause") end end)
    U.reset = button(panel, 300, 460, 104, 36, L.reset, function() if ns.Reset then ns.Reset() end end)
    tooltip(U.pause, L.user_pause)
    tooltip(U.reset, L.sessionChanged)
end

local function openShareMenu(owner, recipeID, rememberName)
    U.shareMessagePanel:Hide()
    local getLink = recipeID and ns.Catalog.GetRecipeShareLink or ns.Catalog.GetShareLink
    if rememberName then
        local link = getLink(recipeID, rememberName)
        if link then U.shareSavedRecipe.tooltip = L.recipeShareSingleHint .. "\n" .. rememberName end
    end
    if not MenuUtil or not Menu or not AnchorUtil or not MenuVariants
        or not ChatFrameUtil or not ChatFrameUtil.OpenChat then
        U.recipeStatus:SetText(L.recipe_share_unavailable)
        return
    end
    local menu = MenuUtil.CreateRootMenuDescription(MenuVariants.GetDefaultContextMenuMixin())
    Menu.PopulateDescription(function(_, menu)
        local function edit(slot)
            U.activeShareSlot = slot
            local saved = slot and ns.db.shareTemplates[slot]
            U.shareMessage:SetText((saved and saved.message or not saved and ns.db.shareMessage) or "")
            U.shareMessagePanel:Show()
            U.shareMessage:SetFocus()
        end
        local function channels(parent, linkFor, id, slot)
            local function channel(label, command, available)
                parent:CreateButton(label, function()
                    local current, why = linkFor(id)
                    local message = slot and slot.message or not slot and ns.db.shareMessage
                    if current then
                        local draft = command .. " " .. current
                        if type(message) == "string" and message ~= "" then draft = draft .. " " .. message end
                        ChatFrameUtil.OpenChat(draft, DEFAULT_CHAT_FRAME)
                    else U.recipeStatus:SetText(translated(why)) end
                end):SetEnabled(available)
            end
            channel(GUILD, SLASH_GUILD1, IsInGuild())
            channel(PARTY, SLASH_PARTY1, GetNumSubgroupMembers() > 0)
            channel(RAID, SLASH_RAID1, IsInRaid())
            local all = {GetChannelList()}
            for i = 1, #all, 3 do
                channel(ChatFrameUtil.ResolveChannelName(all[i+1]), "/" .. all[i], not all[i+2])
            end
        end
        menu:CreateTitle(recipeID and L.recipeShareSingle or L.recipeShare)
        menu:CreateButton(L.recipeShareEdit, function() edit() end)
        if recipeID or owner == U.shareSavedRecipe then
            for i=1,3 do
                local slot = ns.db.shareTemplates[i]
                local label = string.format(L.share_template, i)
                local entry = menu:CreateButton(slot and slot.name and (label .. ": " .. slot.name) or label, function() end)
                if recipeID then
                    entry:CreateButton(L.share_bind_template, function()
                        ns.db.shareTemplates[i] = {recipeID=recipeID, name=rememberName or
                            (ns.db.shareRecipe and ns.db.shareRecipe.name) or label, message=slot and slot.message}
                        edit(i)
                    end)
                end
                if slot then
                    entry:CreateButton(L.recipeShareEdit, function() edit(i) end)
                    channels(entry, ns.Catalog.GetRecipeShareLink, slot.recipeID, slot)
                end
            end
        end
        if recipeID or owner ~= U.shareSavedRecipe then channels(menu, getLink, recipeID) end
    end, owner, menu)
    local anchor = AnchorUtil.CreateAnchor("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -3)
    Menu.GetManager():OpenMenu(owner, menu, anchor)
end

local function recipeTooltip(row)
    if not row.recipe then return end
    local materials = ns.Adapter and ns.Adapter.RecipeReagents and ns.Adapter.RecipeReagents(row.recipe.recipeID)
    local lines = {row.tooltip or row.recipe.name, L.recipeMaterialsTitle}
    if not materials then
        lines[#lines+1] = L.recipeMaterialsUnknown
    else
        local auction, prices, summary = ns.Auction, {}, nil
        if auction and auction.GetPrices and auction.MarketKey then
            local ids = {}
            for _, material in ipairs(materials) do ids[#ids+1] = material.itemID end
            prices = auction.GetPrices(ids, auction.MarketKey())
            summary = auction.GetSummary and auction.GetSummary()
        end
        local now = GetServerTime and GetServerTime()
        local minutes = tonumber(ns.db.priceStaleMinutes) or 30
        local maxAge = (minutes > 0 and minutes or 30) * 60
        for _, material in ipairs(materials) do
            local id = material.itemID
            local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
            local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
            if not finite(icon) or icon == 134400 then
                icon = (ns.ReagentIcons and ns.ReagentIcons[id]) or material.icon or 134400
            end
            local have = ns.Adapter.ReagentCount and ns.Adapter.ReagentCount(id)
            local stock = finite(have) and tostring(have) or "?"
            lines[#lines+1] = string.format("|T%d:13|t %s x%d", icon, name or material.name, material.per)
            local price = L.recipeReagentNoPrice
            if ns.PriceModel then
                local exact = ns.PriceModel.CheapestUnitBuyout(prices[id], now, maxAge)
                if exact then
                    price = string.format(L.recipeReagentBuyout, money(math.floor(exact + 0.5)))
                elseif summary then
                    local minimum = ns.PriceModel.SummaryUnitPrice(summary, id, now, maxAge)
                    if minimum then price = string.format(L.recipeReagentSummary, money(minimum)) end
                end
            end
            lines[#lines+1] = string.format(L.recipeReagentStock, stock, price)
        end
    end
    if not row.recipe.learned then
        local required = ns.Catalog.LearningRequirements(row.recipe.recipeID)
        if required then
            local requirement = string.format(L.learn_skill, required[1])
            if required[2] and required[2] > 0 then
                local faction = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(required[2])
                local standing = _G["FACTION_STANDING_LABEL" .. (required[3]+1)]
                requirement = requirement .. "\n" .. string.format(L.learn_rep,
                    faction and faction.name or ("#" .. required[2]), standing or tostring(required[3]+1))
            end
            lines[#lines+1] = requirement
        end
    end
    return table.concat(lines, "\n")
end

local function createRecipes(panel)
    U.search = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    U.search:SetPoint("TOPLEFT", panel, "TOPLEFT", 5, 0)
    U.search:SetSize(160, 28)
    U.search:SetAutoFocus(false)
    U.search:SetFontObject("GameFontHighlightSmall")
    U.search:SetMaxLetters(120)
    U.searchHint = text(U.search, 5, 7, 148, 18, L.search, 11, C.muted, true)
    U.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    U.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    U.search:SetScript("OnTextChanged", function(self)
        if self:GetText() == "" then U.searchHint:Show() else U.searchHint:Hide() end
        U.recipePage = 1
        U.RenderRecipes()
    end)
    U.shareRecipes = button(panel, 174, 0, 111, 28, L.recipeShare, function(self) openShareMenu(self) end)
    tooltip(U.shareRecipes, L.recipeShareHint)
    U.shareSavedRecipe = button(panel, 292, 0, 112, 28, L.recipeShareSingle, function(self)
        local saved = ns.db.shareRecipe
        if type(saved) == "table" and type(saved.id) == "number" then openShareMenu(self, saved.id)
        else openShareMenu(self) end
    end)
    local saved = ns.db.shareRecipe
    tooltip(U.shareSavedRecipe, type(saved) == "table" and type(saved.name) == "string"
        and (L.recipeShareSingleHint .. "\n" .. saved.name) or L.recipeSharePick)
    local editor = CreateFrame("Frame", nil, panel)
    U.shareMessagePanel = editor
    editor:SetPoint("TOPRIGHT", U.shareRecipes, "BOTTOMRIGHT", 0, -3)
    editor:SetSize(350, 90)
    editor:SetFrameStrata("DIALOG")
    editor:EnableMouse(true)
    fill(editor, 0, 0, 350, 90, C.background)
    text(editor, 12, 7, 326, 18, L.recipeShareEdit, 11, C.text)
    local field = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
    U.shareMessage = field
    field:SetPoint("TOPLEFT", editor, "TOPLEFT", 15, -27)
    field:SetSize(320, 23)
    field:SetAutoFocus(false)
    field:SetFontObject("GameFontHighlightSmall")
    field:SetMaxLetters(120)
    local function saveMessage()
        local message = field:GetText():gsub("[%c]", " "):match("^%s*(.-)%s*$")
        local slot = U.activeShareSlot and ns.db.shareTemplates[U.activeShareSlot]
        if slot then slot.message = message ~= "" and message or nil
        else ns.db.shareMessage = message ~= "" and message or nil end
        editor:Hide()
    end
    button(editor, 220, 58, 116, 23, L.recipeShareSave, saveMessage)
    field:SetScript("OnEnterPressed", saveMessage)
    field:SetScript("OnEscapePressed", function() editor:Hide() end)
    editor:SetScript("OnHide", function() field:ClearFocus() end)
    editor:Hide()
    U.modeButtons = {}
    local filterX = 0
    local filterWidths = {51, 72, 83, 86, 104}
    for i, mode in ipairs({"all", "learned", "unlearned", "favorites", "learnable"}) do
        local selectedMode = mode
        U.modeButtons[mode] = button(panel, filterX, 37, filterWidths[i], 23, L[mode], function()
            U.recipeMode, U.recipePage = selectedMode, 1
            U.RenderRecipes()
        end)
        filterX = filterX + filterWidths[i] + 2
    end
    tooltip(U.modeButtons.learnable, L.learnable_hint)
    U.recipeRows = {}
    for i = 1, RECIPE_ROWS do
        local row = button(panel, 0, 72 + (i - 1) * 40, 404, 38, "", nil)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 7, -5)
        row.icon:SetSize(28, 28)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.name = text(row, 43, 5, 328, 16, "", 11, C.text, true)
        row.detail = text(row, 43, 22, 328, 12, "", 9, C.muted, true)
        row.star = row:CreateTexture(nil, "OVERLAY")
        row.star:SetPoint("RIGHT", row, "RIGHT", -9, 0)
        row.star:SetSize(18, 18)
        row.star:SetAtlas("auctionhouse-icon-favorite")
        row:SetScript("OnClick", function(self, mouse)
            local recipe = self.recipe
            if not recipe then return end
            if mouse == "RightButton" then
                ns.db.favorites[recipe.recipeID] = not ns.db.favorites[recipe.recipeID] or nil
                U.RenderRecipes()
            elseif mouse == "LeftButton" and IsAltKeyDown and IsAltKeyDown() then
                openShareMenu(self, recipe.recipeID, recipe.name)
            elseif mouse == "LeftButton" and self.sourceURL and IsShiftKeyDown and IsShiftKeyDown() then
                U.ShowDiagnostics(self.sourceURL, L.sourceWowhead)
            elseif mouse == "LeftButton" and U.pickingPlan then
                local selection, reason = ns.Adapter.PriceRecipe(recipe)
                if not selection then U.recipeStatus:SetText(translated(reason)); return end
                for _, entry in ipairs(ns.db.shoppingPlan) do
                    if entry.recipeID == recipe.recipeID then setTab("plan"); return end
                end
                selection.count = 1
                table.insert(ns.db.shoppingPlan, selection)
                U.planPage = math.ceil(#ns.db.shoppingPlan / 8)
                setTab("plan")
            elseif mouse == "LeftButton" and (U.pickingPriceRecipe
                or (not U.pickingEnchant and ns.Auction and ns.Auction.GetStatus().open)) then
                local ok, reason = ns.ChoosePriceRecipe(recipe)
                if ok then ns.combinedPlan=nil; U.reagentIndex=0; setTab("prices") else U.recipeStatus:SetText(translated(reason)) end
            elseif mouse == "LeftButton" and U.pickingEnchant then
                if recipe.learned and recipe.isEnchantingRecipe then
                    if not ns.enchantRecipe or ns.enchantRecipe.recipeID ~= recipe.recipeID then ns.enchantTarget = nil end
                    ns.enchantRecipe = recipe
                    setTab("enchant")
                end
            elseif mouse == "LeftButton" and not U.catalogCached then
                if ns.Pause then ns.Pause("recipe_changed") end
                local ok, reason = ns.Catalog.Select(recipe.recipeID)
                if not ok then ns.notice = reason; U.recipeStatus:SetText(translated(reason)) end
            end
        end)
        tooltip(row, nil, recipeTooltip)
        U.recipeRows[i] = row
    end
    U.recipeEmpty = text(panel, 24, 145, 356, 80, L.noRecipes, 12, C.muted)
    U.recipeEmpty:SetJustifyH("CENTER")
    U.recipeBack = button(panel, 0, 442, 88, 25, L.previous, function() U.recipePage = U.recipePage - 1; U.RenderRecipes() end)
    U.recipeNext = button(panel, 316, 442, 88, 25, L.nextPage, function() U.recipePage = U.recipePage + 1; U.RenderRecipes() end)
    U.recipePagination = text(panel, 96, 449, 212, 18, "", 10, C.muted, true)
    U.recipePagination:SetJustifyH("CENTER")
    U.recipeStatus = text(panel, 0, 476, 369, 24, L.recipeHint, 10, C.muted)
    local hints = table.concat({L.recipeHint, L.recipeShareSingleHint, L.sourceCopyHint}, "\n")
    U.recipeHelp = button(panel, 378, 474, 26, 23, "?", function()
        U.ShowDiagnostics(hints, L.recipeHelpTitle)
    end)
    tooltip(U.recipeHelp, hints)
end

local SHOPPING_ROWS, SHOPPING_ROW_HEIGHT = 5, 54

local function reagentName(material)
    local name = material.name
    if name:match("^#%d+$") and C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(material.itemID) or name
    end
    return name
end

local function searchAuction(query)
    local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
    if not bar or not bar:IsVisible() or not bar.SetSearchText or not bar.SearchBox then
        U.priceStatus:SetText(L.auction_search_unavailable)
        return
    end
    bar:SetSearchText(query)
    bar.SearchBox:SetFocus()
    return true
end

local function createGuide(panel)
    local guide = {}
    U.guide = guide
    text(panel, 0, 0, 254, 23, L.route_title, 16, C.teal)
    button(panel, 260, 0, 144, 25, L.budget_title, function() setTab("budget") end)
    guide.stage = text(panel, 0, 35, 404, 19, "", 13, {0.70, 0.81, 1, 1}, true)
    guide.name = text(panel, 0, 61, 404, 19, "", 14, C.amber, true)
    guide.source = text(panel, 0, 87, 366, 32, "", 11, C.amber)
    local function markTrainer(self)
        local ok, marked = pcall(ns.Leveling.MarkTrainer, self.trainer)
        guide.notice:SetText(ok and marked and "" or L.route_no_pin)
    end
    guide.pin = button(panel, 376, 83, 28, 26, "", markTrainer)
    local pinIcon = guide.pin:CreateTexture(nil, "ARTWORK")
    pinIcon:SetPoint("CENTER")
    pinIcon:SetSize(18, 18)
    pinIcon:SetAtlas("Waypoint-MapPin-ChatIcon")
    tooltip(guide.pin)
    guide.materials = {}
    for i=1,6 do
        local y = 122+(i-1)*28
        local row = CreateFrame("Frame", nil, panel)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -y)
        row:SetSize(404, 25)
        fill(row, 0, 0, 404, 25, C.card)
        row.icon = framedIcon(row, 4, 3, 19)
        row.label = text(row, 30, 5, 369, 16, "", 11, C.text, true)
        guide.materials[i] = row
    end
    guide.hint = text(panel, 0, 123, 404, 43, "", 11, C.muted)
    guide.previous = button(panel, 0, 293, 98, 27, L.previous, function()
        U.guidePage=U.guidePage-1; U.RenderGuide()
    end)
    guide.next = button(panel, 306, 293, 98, 27, L.nextPage, function()
        U.guidePage=U.guidePage+1; U.RenderGuide()
    end)
    guide.add = button(panel, 105, 293, 194, 27, L.route_add, function()
        local step = ns.Leveling.steps[U.guidePage]
        local entry = {recipeID=step[3], guideStage=step[1], name=guide.name:GetText(),
            count=guide.crafts, materials=guide.items}
        for i, saved in ipairs(ns.db.shoppingPlan) do
            if saved.guideStage == entry.guideStage then
                ns.db.shoppingPlan[i]=entry
                U.planPage=math.ceil(i/8); setTab("plan"); return
            end
        end
        table.insert(ns.db.shoppingPlan, entry)
        U.planPage=math.ceil(#ns.db.shoppingPlan/8); setTab("plan")
    end, true)
    text(panel, 0, 335, 280, 20, L.route_trainers, 13, C.teal)
    button(panel, 282, 332, 122, 25, L.annora_title, function() setTab("annora") end)
    guide.trainers = {}
    for rank=1,3 do
        guide.trainers[rank] = button(panel, 0, 363+(rank-1)*31, 404, 27, "", markTrainer)
        tooltip(guide.trainers[rank])
    end
    guide.notice = text(panel, 0, 465, 404, 31, "", 11, C.amber)
end

function U.RenderGuide()
    local guide, step = U.guide, ns.Leveling.steps[U.guidePage]
    local ru = GetLocale and GetLocale() == "ruRU"
    local horde = UnitFactionGroup and UnitFactionGroup("player") == "Horde"
    local vendor = step[6] and step[6][(ru and 0 or 2)+(horde and 2 or 1)]
    local skill = ns.Leveling.Skill()
    local crafts = ns.Leveling.Crafts(step, skill)
    guide.crafts, guide.items = crafts, {}
    guide.stage:SetText(string.format(L.route_stage, step[1], step[2], crafts))
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(step[3])
    guide.name:SetText(name or ("#" .. step[3]))
    local trainer, available, requiredSkill, requiredLevel = ns.Leveling.Lesson(step[3], skill, horde)
    guide.pin.trainer = trainer
    if trainer then
        local trainerName = trainer[ru and 4 or 5]
        local state = available == true and L.route_available or available == false and L.route_unavailable or L.route_unknown
        guide.source:SetText(string.format(L.route_trainer_named, trainerName, state))
        local color = available == true and {0.47, 0.87, 0.57} or available == false and {1, 0.46, 0.46} or C.amber
        guide.source:SetTextColor(unpackValues(color))
        guide.pin.tooltip = string.format(L.route_pin_hint, trainerName, trainer[2], trainer[3], requiredSkill, requiredLevel)
        guide.pin:Show()
    else
        guide.source:SetText(vendor and string.format(L.route_vendor, vendor) or (step[1] == 1 and L.route_first_rod or ""))
        guide.source:SetTextColor(unpackValues(C.amber))
        guide.pin:Hide()
    end
    guide.hint:SetText(step[1] == 2 and L.route_disenchant or "")
    for i, row in ipairs(guide.materials) do
        local id, per = step[5][2*i-1], step[5][2*i]
        if id then
            local itemName = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
            if not itemName and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            local icon = (ns.ReagentIcons and ns.ReagentIcons[id])
                or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or 134400
            local material = {itemID=id, per=per, name=itemName or ("#" .. id), icon=icon}
            guide.items[#guide.items+1] = material
            row.icon:SetTexture(icon)
            row.label:SetText(string.format(L.route_material, material.name, crafts*per, ns.Adapter.ReagentCount(id) or "?"))
            row:Show()
        else row:Hide() end
    end
    enabled(guide.add, #guide.items>0)
    enabled(guide.previous, U.guidePage>1)
    enabled(guide.next, U.guidePage<#ns.Leveling.steps)
    for rank, control in ipairs(guide.trainers) do
        local trainer = ns.Leveling.Trainer(rank,horde)
        local map = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(trainer[1])
        local trainerName = trainer[ru and 4 or 5]
        control.trainer = trainer
        control:SetText(string.format(L["route_rank" .. rank], trainerName))
        control.tooltip = string.format("%s  %.1f, %.1f\n%s", map and map.name or trainerName,
            trainer[2], trainer[3], L["route_rank_hint" .. rank])
        if rank == 2 and not horde then control.tooltip = control.tooltip .. "\n" .. L.route_kitta end
        local stageRank = step[1] < 150 and 1 or step[1] < 225 and 2 or 3
        control.background:SetColorTexture(unpackValues(stageRank == rank and C.selected or C.button))
    end
end

local function createPrices(panel)
    fill(panel, 0, 0, 404, 47, C.card)
    U.priceRecipeIcon = framedIcon(panel, 8, 7, 33)
    U.priceRecipeCaption = text(panel, 49, 4, 346, 13, "", 10, C.muted, true)
    U.priceRecipe = text(panel, 49, 16, 346, 19, "", 14, C.amber, true)
    U.formulaCost = text(panel, 49, 34, 346, 12, "", 9, C.muted, true)
    U.scanPrices = button(panel, 0, 52, 132, 29, L.auction_scan, function()
        if ns.ScanPrices then ns.ScanPrices() end
        U.RenderPrices()
    end, true)
    U.scanSummary = button(panel, 136, 52, 132, 29, L.auction_summary_scan, function()
        ns.ScanAuctionSummary()
        U.RenderPrices()
    end)
    tooltip(U.scanSummary, L.auction_summary_hint)
    U.pickPriceRecipe = button(panel, 272, 52, 132, 29, L.auction_pick_recipe, function()
        U.pickingPriceRecipe = true
        U.recipeMode, U.recipePage = "all", 1
        setTab("recipes")
    end)
    tooltip(U.scanPrices, L.auction_scan_hint)
    button(panel, 244, 86, 78, 21, L.plan_short, function() setTab("plan") end)
    button(panel, 326, 86, 78, 21, L.budget_short, function() setTab("budget") end)
    U.priceStatus = text(panel, 0, 86, 239, 24, "", 10, C.amber)
    U.pricePlanCount = input(panel, 0, 111, 198, L.auction_plan_count, "pricePlanCount", L.auction_plan_count_hint, function()
        U.shoppingPage = 1
        U.RenderPrices()
    end, 500)
    U.priceStaleMinutes = input(panel, 206, 111, 198, L.auction_stale_setting, "priceStaleMinutes", L.auction_stale_hint,
        U.RenderPrices, 999)
    U.shoppingOnlyBuy = checkbox(panel, 301, 152, 103, L.auction_only_buy, "priceOnlyBuy", L.auction_only_buy_hint, function()
        U.shoppingPage = 1
        U.RenderPrices()
    end)
    U.nextReagent = button(panel, 164, 151, 129, 21, L.next_reagent, function()
        local queries = U.missingQueries
        if #queries == 0 then return end
        local index = (U.reagentIndex or 0) % #queries + 1
        if searchAuction(queries[index]) then U.reagentIndex = index end
    end)
    tooltip(U.nextReagent, L.auction_find_hint)
    text(panel, 0, 153, 404, 18, L.auction_shopping, 14, C.teal)
    U.shoppingPanel = panel
    U.shoppingPage = 1
    U.shoppingText = text(panel, 0, 174, 404, 40, "", 13, C.text)
    U.shoppingRows = {}
    U.shoppingBack = button(panel, 0, 447, 88, 24, L.previous, function()
        U.shoppingPage = U.shoppingPage - 1
        U.RenderPrices()
    end)
    U.shoppingNext = button(panel, 316, 447, 88, 24, L.nextPage, function()
        U.shoppingPage = U.shoppingPage + 1
        U.RenderPrices()
    end)
    U.shoppingPagination = text(panel, 96, 451, 212, 18, "", 11, C.muted, true)
    U.shoppingPagination:SetJustifyH("CENTER")
    U.priceTotalBar = CreateFrame("Frame", nil, panel)
    U.priceTotalBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -475)
    U.priceTotalBar:SetSize(404, 25)
    U.priceTotalBar:EnableMouse(true)
    fill(U.priceTotalBar, 0, 0, 404, 25, C.card)
    U.priceTotals = text(U.priceTotalBar, 7, 4, 390, 19, "", 13, C.text, true)
    tooltip(U.priceTotalBar)
end

function U.RenderPrices()
    local quote = ns.GetPriceQuote and ns.GetPriceQuote(U.GetSettings())
    local selection = ns.combinedPlan or ns.priceSelection
    U.priceRecipeIcon:SetTexture(selection and selection.icon or 136244)
    U.priceRecipeCaption:SetText(selection and not selection.shoppingOnly and not ns.priceSelectionLive
        and L.auction_saved_recipe or L.auction_plan_recipe)
    U.priceRecipe:SetText(selection and selection.name or L.auction_choose_recipe)
    U.pricePlanCount:EnableMouse(not ns.combinedPlan)
    enabled(U.pricePlanCount.decrease, not ns.combinedPlan)
    enabled(U.pricePlanCount.increase, not ns.combinedPlan)
    local status = ns.Auction and ns.Auction.GetStatus()
    local scanning = status and status.state == "auction_scanning"
    enabled(U.scanPrices, not scanning)
    enabled(U.scanSummary, status and status.open and not scanning)
    U.priceStatus:SetText(status and (status.reason and translated(status.reason)
        or (not status.open and L.auction_open_first or translated(status.state))) or "")
    U.priceTotals:SetText(quote and quote.issue and translated(quote.issue) or "")
    local summary = auctionSummary()
    local summaryFresh = renderAuctionSummary(summary)
    U.formulaCost:SetText("")
    local formula = selection and not ns.combinedPlan and ns.Catalog.FormulaItemID(selection.recipeID)
    if formula and selection.learned == false then
        local formulaPrice, formulaEstimate = estimatedCost(ns.QuoteMaterials({{itemID=formula, per=1}}, 1, 0), "full", summary)
        local craftPrice, craftEstimate = estimatedCost(singleCraft(selection), "full", summary)
        U.formulaCost:SetText(string.format(L.formula_and_craft,
            formulaPrice and ((formulaEstimate and "~" or "") .. money(formulaPrice)) or "?",
            craftPrice and ((craftEstimate and "~" or "") .. money(craftPrice)) or "?"))
    elseif ns.combinedPlan then U.formulaCost:SetText(L.plan_stock_once) end
    local details = {}
    U.priceTotalBar.tooltip = nil
    U.shoppingText:SetText(selection and #selection.materials == 0 and L.recipeMaterialsUnknown
        or (quote and quote.issue and translated(quote.issue) or L.auction_choose_recipe))
    local materials = {}
    U.missingQueries = {}
    if quote and not quote.issue then
        for _, material in ipairs(selection.materials) do
            local needed = quote.shopping[material.itemID].needed
            if not ns.db.priceOnlyBuy or needed ~= 0 then materials[#materials+1] = material end
            if needed and needed > 0 then
                local name = reagentName(material)
                if not name:match("^#%d+$") then U.missingQueries[#U.missingQueries+1] = name end
            end
        end
    end
    enabled(U.nextReagent, status and status.open and #U.missingQueries > 0)
    local count = #materials
    local recipeID = selection and selection.recipeID
    if U.shoppingRecipeID ~= recipeID then
        U.shoppingRecipeID, U.shoppingPage = recipeID, 1
    end
    local first, last, pages
    U.shoppingPage, first, last, pages = pageRange(U.shoppingPage, SHOPPING_ROWS, count)
    U.shoppingPagination:SetText(count > 0 and string.format(L.page, first, last, count) or "")
    enabled(U.shoppingBack, U.shoppingPage > 1)
    enabled(U.shoppingNext, U.shoppingPage < pages)
    local visible = count > 0 and last - first + 1 or 0
    for i = visible+1, #U.shoppingRows do U.shoppingRows[i]:Hide() end
    if not quote or quote.issue then return end
    U.shoppingText:SetText(count == 0 and L.auction_nothing_to_buy or "")
    local function amount(row)
        if row.issue then return translated(row.issue) end
        return money(row.total)
    end
    local section = ns.combinedPlan and quote.buy or quote.full
    local total = amount(section)
    if section.issue and summary and ns.PriceModel then
        local estimate = ns.PriceModel.SummaryBuyEstimate(quote.shopping, summary.prices, not ns.combinedPlan)
        if estimate then total = money(estimate) end
    end
    U.priceTotals:SetText(string.format(summaryFresh and L.auction_totals or L.auction_approximate_total, total))
    if quote.scannedAt then
        details[#details+1] = string.format(L.auction_source, quote.source or "C_AuctionHouse", date("%d.%m.%Y %H:%M", quote.scannedAt))
        if quote.latestAt ~= quote.scannedAt then
            details[#details+1] = string.format(L.auction_latest, date("%d.%m.%Y %H:%M", quote.latestAt))
        end
    end
    if quote.stale then details[#details+1] = "|cffffbc60" .. L.auction_stale .. "|r" end
    if quote.whole then details[#details+1] = L.auction_whole end
    if quote.buy.extra > 0 then details[#details+1] = string.format(L.auction_extra, quote.buy.extra) end
    U.priceTotalBar.tooltip = table.concat(details, "\n")
    for i = 1, visible do
        local material = materials[first + i - 1]
        local row = U.shoppingRows[i]
        if not row then
            row = CreateFrame("Frame", nil, U.shoppingPanel)
            row:SetPoint("TOPLEFT", U.shoppingPanel, "TOPLEFT", 0, -174-(i-1)*SHOPPING_ROW_HEIGHT)
            row:SetSize(404, SHOPPING_ROW_HEIGHT)
            fill(row, 0, 0, 404, SHOPPING_ROW_HEIGHT-4, C.card)
            row.icon = framedIcon(row, 8, 9, 34)
            row.name = text(row, 50, 4, 260, 16, "", 13, C.text, true)
            row.details = text(row, 50, 19, 346, 34, "", 11, C.text)
            row.search = button(row, 319, 3, 77, 17, L.auction_find, function()
                searchAuction(row.query)
            end)
            tooltip(row.search, L.auction_find_hint)
            U.shoppingRows[i] = row
        end
        local item = quote.shopping[material.itemID]
        local name = reagentName(material)
        local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(material.itemID)
        row.icon:SetTexture(icon or material.icon or 134400)
        row.name:SetText(name)
        row.query = name
        local details = string.format(L.auction_shopping_row, item.have or "?", item.required, item.needed or "?", amount(item))
        if item.extra and item.extra > 0 then details = details .. "\n" .. string.format(L.auction_extra, item.extra) end
        local minimum = summary and summary.prices[material.itemID]
        if finite(minimum) and minimum > 0 and minimum == math.floor(minimum) and (not item.extra or item.extra == 0) then
            details = details .. "\n" .. string.format(L.auction_summary_min, money(minimum))
        end
        row.details:SetText(details)
        enabled(row.search, status and status.open and not name:match("^#%d+$"))
        row:Show()
    end
end

local function createInventory(panel)
    text(panel, 0, 0, 260, 36, L.deHint, 10.5, C.muted)
    button(panel, 271, 0, 133, 23, L.de_history, function() setTab("history") end)
    U.inventoryRefresh = button(panel, 0, 44, 152, 25, L.deRefresh, function()
        U.inventoryPage = 1
        if ns.RefreshInventory then ns.RefreshInventory() end
    end)
    local function refreshQuality()
        U.inventoryPage = 1
        if ns.RefreshInventory then ns.RefreshInventory() end
    end
    U.rare = checkbox(panel, 163, 46, 96, L.rare, "includeRare", L.rare, refreshQuality)
    U.epic = checkbox(panel, 267, 46, 137, L.epic, "includeEpic", L.epic, refreshQuality)
    U.inventorySummary = text(panel, 0, 77, 258, 16, "", 10, C.muted, true)
    U.sortValue = button(panel, 271, 73, 133, 21, L.de_sort, function()
        ns.db.deSortValue = not ns.db.deSortValue
        U.inventoryPage = 1
        ns.RefreshInventory()
    end)
    tooltip(U.sortValue, L.de_sort_hint)
    U.inventoryRows = {}
    for i = 1, INVENTORY_ROWS do
        local row = button(panel, 0, 98 + (i - 1) * 33, 404, 31, "", function(self)
            if self.item and ns.SelectDE then ns.SelectDE(self.item) end
        end)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 33, -4)
        row.icon:SetSize(23, 23)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.name = text(row, 63, 3, 332, 15, "", 11, C.text, true)
        row.location = text(row, 63, 18, 332, 11, "", 9, C.muted, true)
        row.mark = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.mark:SetPoint("LEFT", row, "LEFT", 3, 0)
        row.mark:SetSize(26, 26)
        row.mark:SetScript("OnClick", function()
            if row.item then ns.ToggleDEMark(row.item) end
        end)
        tooltip(row.mark, L.deMark)
        tooltip(row)
        U.inventoryRows[i] = row
    end
    U.inventoryEmpty = text(panel, 18, 157, 368, 72, L.deEmpty, 11, C.muted)
    U.inventoryEmpty:SetJustifyH("CENTER")
    U.inventoryBack = button(panel, 0, 267, 88, 25, L.previous, function() U.inventoryPage = U.inventoryPage - 1; U.RenderInventory() end)
    U.inventoryNext = button(panel, 316, 267, 88, 25, L.nextPage, function() U.inventoryPage = U.inventoryPage + 1; U.RenderInventory() end)
    U.inventoryPagination = text(panel, 96, 274, 212, 18, "", 10, C.muted, true)
    U.inventoryPagination:SetJustifyH("CENTER")
    fill(panel, 0, 298, 404, 32, C.card)
    U.dePreviewIcon = panel:CreateTexture(nil, "ARTWORK")
    U.dePreviewIcon:SetPoint("TOPLEFT", panel, "TOPLEFT", 5, -301)
    U.dePreviewIcon:SetSize(26, 26)
    U.dePreviewCaption = text(panel, 38, 299, 358, 12, "", 9, C.muted, true)
    U.selectedItem = text(panel, 38, 311, 358, 16, L.deSelect, 12, C.text, true)
    U.deLootTitle = text(panel, 0, 335, 245, 15, "", 12, C.teal, true)
    U.deLootScan = button(panel, 254, 332, 150, 19, L.deLootScan, function()
        local ok, reason = ns.Auction.Start(U.deLootIDs)
        if ok then ns.priceScanSelection = nil end
        U.deLootScanError = not ok and reason or nil
        U.RenderInventory()
    end)
    tooltip(U.deLootScan, L.deLootScanHint)
    U.deLootRows = {}
    for i = 1, 3 do
        U.deLootRows[i] = text(panel, 2, 351 + (i - 1) * 14, 402, 14, "", 11, C.text, true)
    end
    U.deLootValue = text(panel, 0, 395, 404, 14, "", 11, C.amber, true)
    U.deVendorValue = text(panel, 0, 410, 404, 14, "", 11, C.muted, true)
    U.keep = button(panel, 0, 425, 198, 25, L.keep, function() if ns.KeepSelected then ns.KeepSelected() end end)
    tooltip(U.keep)
    U.clearKeep = button(panel, 206, 425, 198, 25, L.restore, function() if ns.ClearKeep then ns.ClearKeep() end end)
    text(panel, 0, 451, 404, 13, L.deWarning, 10.5, C.amber, true)
    U.deButton = button(panel, 0, 465, 404, 31, L.deAction, nil, true,
        "InsecureActionButtonTemplate", "EnchantPilotDisenchantButton")
    U.deButton:RegisterForClicks("LeftButtonUp")
    U.deButton:SetAttribute("useOnKeyDown", false)
    U.deButton:SetScript("PreClick", function(self, mouse, down)
        if ns.PreDisenchant then ns.PreDisenchant(self, mouse, down) end
    end)
    U.deButton:SetScript("PostClick", function(self)
        if ns.PostDisenchant then ns.PostDisenchant(self) end
    end)
    tooltip(U.deButton, L.deWarning .. "\n" .. L.deHint)
end

local function restorePopup(dialog)
    local saved = movedPopups[dialog]
    if not saved or saved.restoring then return end
    saved.restoring = true
    local ok = pcall(function()
        dialog:ClearAllPoints()
        for _, point in ipairs(saved.points) do dialog:SetPoint(unpackValues(point)) end
    end)
    saved.restoring = false
    if ok then movedPopups[dialog] = nil end
end

local function restoreHiddenPopups(all)
    for dialog, saved in pairs(movedPopups) do
        if all or not dialog:IsShown() or dialog.which ~= saved.which then restorePopup(dialog) end
    end
end

function U.RestorePopups()
    restoreHiddenPopups(true)
end

local function updateCast()
    if not U.castBar or not ns.engine then return end
    local view = ns.engine:GetView(ns.current)
    local startAt, endAt, spellID
    if ns.Adapter and ns.Adapter.CastProgress then startAt, endAt, spellID = ns.Adapter.CastProgress() end
    local matches = ns.locked and ns.locked.spellIDs and ns.locked.spellIDs[spellID]
    if not matches then matches = spellID ~= nil and spellID == view.recipeID end
    local now = GetTime and GetTime()
    if matches and finite(startAt) and finite(endAt) and finite(now) and endAt > startAt then
        local left = math.max(0, endAt - now)
        U.castBar:SetValue(math.max(0, math.min(1, (now - startAt) / (endAt - startAt))))
        U.castText:SetText(string.format("%s  %.1f s", L.casting, left))
    else
        U.castBar:SetValue(view.goal > 0 and view.completed / view.goal or 0)
        U.castText:SetText("")
    end
end

local function createList(panel, title, hint, tab, render, closeTab)
    text(panel, 0, 0, 404, 24, title, 16, C.teal)
    text(panel, 0, 30, 404, 34, hint, 11, C.muted)
    local list = {page=1, rows={}}
    for i=1,8 do
        local row = button(panel, 0, 74+(i-1)*43, 404, 40, "", function(self)
            if self.pick then self.pick() end
        end)
        row.name = text(row, 8, 4, 295, 15, "", 12, C.text, true)
        row.detail = text(row, 8, 21, 388, 15, "", 10, C.muted, true)
        tooltip(row)
        list.rows[i] = row
    end
    list.back = button(panel, 0, 426, 82, 24, L.previous, function() list.page=list.page-1; render() end)
    list.next = button(panel, 322, 426, 82, 24, L.nextPage, function() list.page=list.page+1; render() end)
    list.pageText = text(panel, 88, 429, 228, 18, "", 11, C.muted, true)
    list.pageText:SetJustifyH("CENTER")
    button(panel, 0, 465, 106, 29, L.previous, function() setTab(closeTab) end)
    U[tab] = list
    return list
end

local function listPage(list, entries)
    local first, last, pages
    list.page, first, last, pages = pageRange(list.page, #list.rows, #entries)
    list.pageText:SetText(string.format(L.page, first, last, #entries))
    enabled(list.back, list.page > 1)
    enabled(list.next, list.page < pages)
    for i, row in ipairs(list.rows) do
        row.entry, row.pick, row.tooltip = entries[first+i-1], nil, nil
        if row.entry then row:Show() else row:Hide() end
    end
end

function U.RenderPlan()
    local list, entries = U.planList, ns.db.shoppingPlan
    list.page = U.planPage or list.page
    U.planPage = nil
    listPage(list, entries)
    for _, row in ipairs(list.rows) do
        if row.entry then
            row.name:SetText(row.entry.name)
            row.detail:SetText("")
            row.count:SetText(tostring(row.entry.count))
        end
    end
    enabled(list.view, #entries > 0)
end

function U.RenderAnnora()
    local list = U.annoraList
    local skill, maximum = ns.Leveling.Skill()
    local level = UnitLevel and UnitLevel("player")
    local known = {}
    for _, recipe in ipairs(ns.Catalog.List("", "all", ns.db.favorites)) do
        known[recipe.recipeID] = recipe
    end
    listPage(list, ns.Leveling.annoraRecipes)
    for _, row in ipairs(list.rows) do
        local entry = row.entry
        if entry then
            local id, required = entry[1], entry[2]
            local recipe = known[id]
            local name = recipe and recipe.name or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id))
            local learned = recipe and recipe.learned
            if learned == nil and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
                local info = C_TradeSkillUI.GetRecipeInfo(id)
                if info then learned = info.learned end
            end
            local status = ns.Leveling.AnnoraStatus(required, learned, skill, maximum, level)
            row.name:SetText(name or ("#" .. id))
            row.detail:SetText(string.format(L.annora_row, required, L[status]))
            local color = status == "learned" and C.muted or status == "route_available" and {0.47,0.87,0.57}
                or status == "route_unknown" and C.amber or {1,0.46,0.46}
            row.detail:SetTextColor(unpackValues(color))
        end
    end
    list.note:SetText(string.format(L.annora_progress, skill or "?", maximum or "?"))
end

function U.RenderBudget()
    local list = U.budgetList
    local rows, cacheReason = ns.Catalog.List("", "learned", ns.db.favorites)
    local summary = auctionSummary()
    local entries = {}
    for _, recipe in ipairs(rows) do
        if recipe.canSkillUp then
            local quote = singleCraft(recipe)
            local cost, approximate = estimatedCost(quote, "buy", summary)
            entries[#entries+1] = {recipe=recipe, cost=cost, approximate=approximate}
        end
    end
    table.sort(entries, function(a,b)
        local x,y = a.cost or math.huge,b.cost or math.huge
        if x ~= y then return x < y end
        return a.recipe.recipeID < b.recipe.recipeID
    end)
    list.note:SetText(cacheReason == "catalog_cached" and L.budget_cached or "")
    listPage(list, entries)
    for _, row in ipairs(list.rows) do
        local entry = row.entry
        if entry then
            row.name:SetText(entry.recipe.name)
            row.detail:SetText(entry.cost and ((entry.approximate and "~" or "") .. money(entry.cost)) or L.budget_no_price)
            row.pick = function()
                if ns.ChoosePriceRecipe(entry.recipe) then ns.combinedPlan=nil; setTab("prices") end
            end
        end
    end
end

function U.RenderHistory()
    local list = U.historyList
    listPage(list, ns.db.deHistory)
    for _, row in ipairs(list.rows) do
        local entry = row.entry
        if entry then
            local drops = {}
            for _, drop in ipairs(entry.drops or {}) do drops[#drops+1] = drop.link .. " x" .. drop.count end
            local result = #drops > 0 and table.concat(drops, ", ") or L.de_untracked
            row.name:SetText(entry.link or L.unknownItem)
            row.detail:SetText((entry.time and date("%d.%m %H:%M", entry.time) .. "  " or "") .. result)
            row.tooltip = (entry.link or L.unknownItem) .. "\n" .. result
        end
    end
end

function U.Create()
    if U.frame then return U.frame end
    ns.db = ns.db or {}
    ns.db.favorites, ns.db.keep = ns.db.favorites or {}, ns.db.keep or {}
    local frame = CreateFrame("Frame", "EnchantPilotFrame", UIParent)
    U.frame = frame
    frame:SetSize(440, 650)
    -- Native confirmation dialogs must remain above our action controls.
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:Hide()
    fill(frame, 0, 0, 440, 650, C.background)
    fill(frame, 0, 0, 440, 2, C.teal, "BORDER")
    fill(frame, 0, 605, 440, 1, C.button, "BORDER")
    local height = UIParent.GetHeight and UIParent:GetHeight()
    if finite(height) and height < 680 then frame:SetScale(math.max(0.5, (height - 30) / 650)) end
    local position = ns.db.position
    local anchors = {TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
        RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true}
    if type(position) == "table" and anchors[position.point] and anchors[position.relativePoint]
        and finite(position.x) and finite(position.y) then
        frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    else frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    header:SetSize(400, 57)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relativePoint, x, y = frame:GetPoint(1)
        ns.db.position = {point = point, relativePoint = relativePoint, x = x, y = y}
    end)
    text(header, 18, 13, 190, 25, L.title, 20, C.teal, true)
    text(header, 213, 20, 184, 16, L.beta, 8.8, C.muted, true)
    text(header, 19, 40, 376, 16, L.subtitle, 10, C.muted, true)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
    close:SetSize(32, 32)
    close:SetScript("OnClick", function() frame:Hide() end)
    U.tabs, U.panels = {}, {}
    local x = 18
    local widths = {102, 75, 80, 63, 76}
    for i, key in ipairs({"enchant", "recipes", "disenchant", "prices", "leveling"}) do
        local tabKey = key
        U.tabs[key] = button(frame, x, 64, widths[i], 28, L[key], function() setTab(tabKey) end)
        x = x + widths[i] + 2
        local panel = CreateFrame("Frame", nil, frame)
        panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -102)
        panel:SetSize(404, 500)
        U.panels[key] = panel
    end
    local targets = CreateFrame("Frame", nil, frame)
    targets:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -102)
    targets:SetSize(404, 500)
    U.panels.targets = targets
    U.targetTitle = text(targets, 0, 3, 404, 21, L.enchant_target_pick, 14, C.teal, true)
    local targetSearch = CreateFrame("EditBox", nil, targets, "InputBoxTemplate")
    U.targetSearch = targetSearch
    targetSearch:SetPoint("TOPLEFT", targets, "TOPLEFT", 5, -29)
    targetSearch:SetSize(390, 24)
    targetSearch:SetAutoFocus(false)
    targetSearch:SetFontObject("GameFontHighlightSmall")
    targetSearch:SetMaxLetters(80)
    local targetHint = text(targetSearch, 5, 5, 380, 16, L.target_search, 11, C.muted, true)
    targetSearch:SetScript("OnTextChanged", function(self)
        if self:GetText() == "" then targetHint:Show() else targetHint:Hide() end
        U.targetPage = 1
        if U.targets then U.RenderTargets() end
    end)
    targetSearch:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    targetSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    U.targetEmpty = text(targets, 0, 60, 404, 42, L.enchant_target_empty, 12, C.muted)
    U.targetRows = {}
    for i = 1, 9 do
        local row = button(targets, 0, 59 + (i - 1) * 40, 404, 36, "", function(self)
            if not self.item then return end
            ns.enchantRecipe, ns.enchantTarget = U.targetRecipe, self.item
            setTab("enchant")
        end)
        row.icon = framedIcon(row, 7, 6, 24)
        row.name = text(row, 39, 3, 355, 16, "", 12, C.text, true)
        row.location = text(row, 39, 19, 355, 13, "", 10, C.muted, true)
        tooltip(row)
        U.targetRows[i] = row
    end
    U.targetBack = button(targets, 0, 425, 88, 24, L.previous, function()
        U.targetPage = U.targetPage - 1; U.RenderTargets()
    end)
    U.targetNext = button(targets, 316, 425, 88, 24, L.nextPage, function()
        U.targetPage = U.targetPage + 1; U.RenderTargets()
    end)
    button(targets, 0, 460, 404, 25, L.enchant_target_back, function() setTab("enchant") end)
    createEnchant(U.panels.enchant)
    createRecipes(U.panels.recipes)
    createInventory(U.panels.disenchant)
    createPrices(U.panels.prices)
    createGuide(U.panels.leveling)
    for _, key in ipairs({"plan", "budget", "history", "annora"}) do
        local panel = CreateFrame("Frame", nil, frame)
        panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -102)
        panel:SetSize(404, 500)
        U.panels[key] = panel
    end
    local plan = createList(U.panels.plan, L.plan_title, L.plan_hint, "planList", U.RenderPlan, "prices")
    button(U.panels.plan, 112, 465, 132, 29, L.plan_add, function()
        U.pickingPlan, U.recipeMode, U.recipePage = true, "all", 1
        setTab("recipes")
    end)
    plan.view = button(U.panels.plan, 250, 465, 154, 29, L.plan_view, function()
        if ns.RebuildShoppingPlan(true) then U.reagentIndex=0; setTab("prices") end
    end, true)
    for _, row in ipairs(plan.rows) do
        local count = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.count = count
        count:SetPoint("RIGHT", row, "RIGHT", -43, 0)
        count:SetSize(49, 23)
        count:SetAutoFocus(false)
        count:SetNumeric(true)
        count:SetMaxLetters(3)
        count:SetFontObject("GameFontHighlightSmall")
        count:SetJustifyH("CENTER")
        count:SetScript("OnEditFocusLost", function(self)
            if not row.entry then return end
            row.entry.count = math.min(500, math.max(1, tonumber(self:GetText()) or 1))
            self:SetText(tostring(row.entry.count))
            if ns.combinedPlan then ns.RebuildShoppingPlan(true) end
        end)
        count:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        count:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        button(row, 371, 8, 26, 24, "X", function()
            for i, entry in ipairs(ns.db.shoppingPlan) do
                if entry == row.entry then table.remove(ns.db.shoppingPlan, i); break end
            end
            if ns.combinedPlan then ns.RebuildShoppingPlan(true) end
            U.RenderPlan()
        end)
    end
    local budget = createList(U.panels.budget, L.budget_title, L.budget_hint, "budgetList", U.RenderBudget, "leveling")
    local annora = createList(U.panels.annora, L.annora_title, L.annora_hint, "annoraList", U.RenderAnnora, "leveling")
    annora.note = text(U.panels.annora, 115, 470, 289, 25, "", 11, C.muted)
    budget.note = text(U.panels.budget, 112, 468, 290, 22, "", 10, C.amber)
    createList(U.panels.history, L.de_history, L.de_history_hint, "historyList", U.RenderHistory, "disenchant")
    text(frame, 18, 614, 286, 29, L.keyHelp, 9, C.muted)
    U.auctionSummary = text(frame, 18, 630, 291, 15, "", 10, C.muted, true)
    button(frame, 316, 616, 106, 24, L.diagnosis, function() if ns.Debug then ns.Debug() end end)
    frame:SetScript("OnHide", function()
        restoreHiddenPopups(true)
        if ns.Pause then ns.Pause("user_pause") end
    end)
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.05 then return end
        elapsed = 0
        restoreHiddenPopups(false)
        updateCast()
    end)
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "EnchantPilotFrame" end
    setTab("enchant")
    U.RenderInventory()
    return frame
end

function U.RenderTargets()
    local query = ns.Catalog.Fold(U.targetSearch:GetText())
    local matches = {}
    for _, item in ipairs(U.targets) do
        local name = item.link:match("%[(.-)%]") or item.link
        if query == "" or ns.Catalog.Fold(name):find(query, 1, true) then matches[#matches+1] = item end
    end
    local first, last, pages
    U.targetPage, first, last, pages = pageRange(U.targetPage, #U.targetRows, #matches)
    U.targetTitle:SetText(U.targetRecipe.name or L.enchant_target_pick)
    if last == 0 then U.targetEmpty:Show() else U.targetEmpty:Hide() end
    for i, row in ipairs(U.targetRows) do
        local item = matches[first + i - 1]
        row.item, row.link = item, item and item.link
        if item then
            row.icon:SetTexture(item.icon or 134400)
            row.name:SetText(item.link)
            local location = item.bag and string.format(L.bagSlot, item.bag, item.slot) or L.enchant_target_equipped
            row.location:SetText(location .. "  /  " .. string.format(L.target_level, item.level or "?")
                .. "  /  " .. (item.enchant and item.enchant > 0 and string.format(L.target_enchant, item.enchant) or L.target_no_enchant))
            row:Show()
        else row:Hide() end
    end
    enabled(U.targetBack, U.targetPage > 1)
    enabled(U.targetNext, U.targetPage < pages)
end

function U.GetSettings()
    if not U.inputs then
        return {count = tonumber(ns.db.count) or 0, reserve = tonumber(ns.db.reserve) or 0,
            skillGoal = tonumber(ns.db.skillGoal) or 0, stopOnGray = ns.db.stopOnGray == true}
    end
    return {count = tonumber(U.inputs.count:GetText()) or 0,
        reserve = tonumber(U.inputs.reserve:GetText()) or 0,
        skillGoal = tonumber(U.inputs.skillGoal:GetText()) or 0,
        stopOnGray = U.checks.stopOnGray:GetChecked() == true}
end

local function renderMaterials(snapshot, view)
    local materials = snapshot and snapshot.materials or {}
    local plannedCasts = view.goal > 0 and view.remaining or U.GetSettings().count
    for i, material in ipairs(materials) do
        local row = U.materialRows[i]
        if not row then
            row = CreateFrame("Button", nil, U.materialContent)
            row:SetPoint("TOPLEFT", U.materialContent, "TOPLEFT", 0, -(i - 1) * 16)
            row:SetSize(378, 16)
            row.name = text(row, 0, 0, 211, 15, "", 10, C.muted, true)
            row.counts = text(row, 217, 0, 161, 15, "", 10, C.text, true)
            row.counts:SetJustifyH("RIGHT")
            tooltip(row)
            U.materialRows[i] = row
        end
        local have, per = material.have, material.per
        row.name:SetText(material.name or ("#" .. tostring(material.itemID)))
        if finite(have) and finite(per) then
            local planned = math.max(0, plannedCasts) * per
            row.counts:SetText(string.format("%d / %d / %d", have, planned, have - planned))
            row.counts:SetTextColor(unpackValues(have < planned and C.amber or C.text))
        else row.counts:SetText("? / ? / ?") end
        row.link = material.link
        row.tooltip = material.name
        row:Show()
    end
    for i = #materials + 1, #U.materialRows do U.materialRows[i]:Hide() end
    U.materialContent:SetHeight(math.max(48, #materials * 16))
    if #materials == 0 then U.materialEmpty:Show() else U.materialEmpty:Hide() end
end

function U.Render(snapshot, reason)
    if not U.frame then return end
    if U.activeTab ~= "prices" then renderAuctionSummary(auctionSummary()) end
    local view = ns.engine:GetView(snapshot)
    local planned = ns.enchantRecipe
    U.currentCard.caption:SetText(planned and L.enchant_planned or (L.currentSelection or L.selected))
    renderSelection(U.currentCard, planned and (snapshot and snapshot.recipeID == planned.recipeID and snapshot or planned) or snapshot)
    if ns.enchantTarget then
        U.currentCard.target:SetText(ns.enchantTarget.link)
        U.currentCard.link = ns.enchantTarget.link
    end
    renderSelection(U.lockedCard, ns.locked or ns.engine.session)
    U.progress:SetText(string.format(L.progress, view.completed, view.goal))
    U.skill:SetText(string.format(L.skill, view.skillRank and tostring(view.skillRank) or "?",
        view.skillDelta and string.format("%+d", view.skillDelta) or "?"))
    local live = snapshot
    if live and ns.locked and (live.recipeID ~= ns.locked.recipeID or live.targetGUID ~= ns.locked.targetGUID
        or live.allocationKey ~= ns.locked.allocationKey) then live = nil end
    U.materialSummary:SetText(string.format(L.remaining, live and live.available or "?", view.remaining))
    local estimate = live and view.estimatedSeconds
    if estimate then
        local timeText = estimate >= 60 and string.format("%d:%02d", math.floor(estimate / 60), math.floor(estimate % 60))
            or string.format(L.seconds, math.ceil(estimate))
        U.estimate:SetText(string.format(L.estimate, timeText))
    else U.estimate:SetText(L.noEstimate) end
    renderMaterials(live, view)
    local phase = view.phase or view.state
    local code = view.reason == "session_restored" and "session_restored" or reason
    if not code then
        if view.state == "paused" or view.state == "complete" then code = view.reason
        elseif view.inFlight then code = phase
        else code = ns.notice or view.reason or "idle" end
    end
    if planned and (not reason or reason == "profession_closed" or reason == "not_enchant" or reason == "choose_recipe"
        or (reason == "choose_target" and ns.enchantTarget))
        and not view.inFlight then code = ns.enchantTarget and "enchant_target_ready" or "enchant_pick_target" end
    U.status:SetText(translated(code))
    local calm = code == "ready" or code == "idle" or code == "requesting" or code == "confirming" or code == "sessionChanged"
    U.status:SetTextColor(unpackValues((code == "complete" or code == "skill_goal") and C.teal or (calm and C.muted or C.amber)))
    local title = L.start
    if phase == "confirming" then title = L.nativeYes
    elseif phase == "casting" then title = L.casting
    elseif phase == "requesting" then title = L.waiting
    elseif phase == "paused" then title = L.resume
    elseif phase == "ready" then title = L.next
    elseif phase == "complete" then title = L.done end
    U.action:SetText(title)
    local paused = view.state == "paused"
    U.action.background:SetColorTexture(unpackValues(view.inFlight and C.casting or paused and C.paused or C.selected))
    U.action.accent:SetColorTexture(unpackValues(view.inFlight and C.casting or paused and C.amber or C.teal))
    local locked = ns.locked and not planned
    U.capture:SetText(locked and L.captureLocked or L.capture)
    U.capture.background:SetColorTexture(unpackValues(locked and C.locked or C.button))
    enabled(U.action, not planned and not ns.dePending and view.state ~= "complete" and not view.inFlight)
    enabled(U.pickEnchant, not view.inFlight and not ns.dePending)
    enabled(U.pickTarget, (planned or snapshot or ns.locked) and not view.inFlight and not ns.dePending)
    if view.inFlight then U.action:SetAlpha(1) end
    enabled(U.capture, not view.inFlight and not ns.dePending)
    local canPause = ns.engine.session ~= nil and view.state ~= "complete" and not paused
    U.pause.background:SetColorTexture(unpackValues((canPause or paused) and C.paused or C.button))
    U.pause.label:SetTextColor(unpackValues((canPause or paused) and C.amber or C.text))
    enabled(U.pause, canPause)
    enabled(U.reset, not view.inFlight and not ns.dePending)
    updateCast()
    if U.activeTab == "recipes" and U.recipesDirty then U.RenderRecipes() end
    if U.activeTab == "disenchant" then U.RenderInventory() end
    if U.activeTab == "prices" then U.RenderPrices() end
end

function U.InvalidateRecipes() U.recipesDirty = true end

function U.RenderRecipes()
    if not U.recipeRows then return end
    U.recipesDirty = false
    local list, reason = ns.Catalog.List(U.search:GetText(), U.recipeMode, ns.db.favorites)
    U.recipeList = list or {}
    if U.pickingEnchant then
        U.recipeList = {}
        for _, recipe in ipairs(list or {}) do
            if recipe.learned and recipe.isEnchantingRecipe then U.recipeList[#U.recipeList+1] = recipe end
        end
    end
    U.catalogCached = reason == "catalog_cached"
    local auctionOpen = ns.Auction and ns.Auction.GetStatus().open
    U.recipeStatus:SetText(U.pickingEnchant and L.enchant_pick_hint
        or U.pickingPlan and L.plan_pick
        or U.pickingPriceRecipe and #U.recipeList > 0 and L.auction_pick_hint
        or auctionOpen and L.auction_recipe_click
        or (U.catalogCached and L.catalog_cached or L.recipeHint))
    local first, last, pages
    U.recipePage, first, last, pages = pageRange(U.recipePage, RECIPE_ROWS, #U.recipeList)
    for mode, control in pairs(U.modeButtons) do
        control.background:SetColorTexture(unpackValues(mode == U.recipeMode and C.selected or C.button))
        control.label:SetTextColor(unpackValues(mode == U.recipeMode and C.teal or C.muted))
    end
    for i, row in ipairs(U.recipeRows) do
        local recipe = U.recipeList[first + i - 1]
        row.recipe = recipe
        row.sourceURL = nil
        if recipe then
            row.icon:SetTexture(recipe.icon or 136244)
            row.name:SetText(recipe.name)
            row.detail:SetText(recipe.learned and L.learned or L.unlearned)
            row.detail:SetTextColor(unpackValues(recipe.learned and C.muted or C.amber))
            if recipe.favorite then row.star:Show() else row.star:Hide() end
            local lines = {recipe.name}
            if not recipe.learned then
                local source, url, fallback = ns.Catalog.Acquisition(recipe)
                row.sourceURL = url
                lines[#lines + 1] = L.sourceLabel
                local acquisition = source or (fallback and L[fallback])
                lines[#lines + 1] = acquisition and ("|cffffcf67" .. acquisition .. "|r") or L.sourceUnknown
            end
            row.tooltip = table.concat(lines, "\n")
            row:Show()
        else row:Hide() end
    end
    U.recipePagination:SetText(string.format(L.page, first, last, #U.recipeList))
    enabled(U.recipeBack, U.recipePage > 1)
    enabled(U.recipeNext, U.recipePage < pages)
    if #U.recipeList == 0 then
        U.recipeEmpty:SetText(reason and not U.catalogCached and translated(reason) or L.noMatches)
        U.recipeEmpty:Show()
    else U.recipeEmpty:Hide() end
end

local function renderDisenchantLoot(target)
    local vendor = target and target.sellPrice
    U.deVendorValue:SetText(finite(vendor) and vendor > 0 and string.format(L.deVendorValue, money(vendor)) or "")
    local outcomes, samples, partial
    if ns.Disenchant then outcomes, samples, partial = ns.Disenchant.Outcomes(target) end
    U.deLootTitle:SetText(outcomes and (partial and L.deLootPartial
        or (samples and string.format(L.deLootTitle, samples) or L.deLootEstimated)) or "")
    if outcomes then U.deLootScan:Show() else U.deLootScan:Hide() end
    if U.deLootTarget ~= (target and target.guid) then
        U.deLootTarget = target and target.guid
        U.deLootScanError = nil
    end
    local ids = {}
    for i, label in ipairs(U.deLootRows) do
        local drop = outcomes and outcomes[i]
        if drop then
            local id, minimum, maximum, chance = unpackValues(drop)
            local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
            local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
            if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            local line = string.format("|T%d:13|t %s", icon or 134400, name or ("#" .. id))
            if minimum then
                local count = minimum == maximum and tostring(minimum) or (minimum .. "-" .. maximum)
                line = line .. string.format(" x%s (~%d%%)", count, chance)
            end
            label:SetText(line)
            ids[#ids + 1] = id
        else
            label:SetText("")
        end
    end
    U.deLootIDs = ids
    U.deLootValue:SetText("")
    if not outcomes then return end
    local auction = ns.Auction
    local status = auction.GetStatus()
    local scanning = status.state == "auction_scanning"
    enabled(U.deLootScan, status.open and not scanning)
    local market = auction.MarketKey()
    local prices = auction.GetPrices(ids, market)
    local now, maxAge = GetServerTime and GetServerTime(), (tonumber(ns.db.priceStaleMinutes) or 30) * 60
    if maxAge == 0 then maxAge = 1800 end
    local value, valueLabel
    if partial then
        local unit = ns.PriceModel.CheapestUnitBuyout(prices[ids[1]], now, maxAge)
        if unit then value = math.floor(unit + 0.5) end
        valueLabel = L.deLootUnit
    else
        value = ns.PriceModel.DisenchantValue(outcomes, prices, now, maxAge)
        valueLabel = L.deLootValue
    end
    if not value and auction.GetSummary then
        value = ns.PriceModel.DisenchantSummaryValue(outcomes, auction.GetSummary(), now, maxAge, partial)
        valueLabel = partial and L.deLootSummaryUnit or L.deLootSummaryValue
    end
    local reason = U.deLootScanError or status.reason
    U.deLootValue:SetText(scanning and translated(status.state)
        or (value and string.format(valueLabel, money(value)))
        or (reason and status.open and translated(reason))
        or (status.open and L.deLootNoPrice or L.deLootNoCachedPrice))
end

function U.RenderInventory()
    if not U.inventoryRows then return end
    local items, stats = ns.items or {}, ns.inventoryStats or {}
    local nextItem, marked
    if ns.DisenchantQueue then nextItem, marked = ns.DisenchantQueue() end
    local inFlight = ns.engine and ns.engine:GetView(ns.current).inFlight
    local busy = ns.dePending ~= nil or inFlight
    U.sortValue.background:SetColorTexture(unpackValues(ns.db.deSortValue and C.selected or C.button))
    local first, last, pages
    U.inventoryPage, first, last, pages = pageRange(U.inventoryPage, INVENTORY_ROWS, #items)
    U.inventorySummary:SetText(stats.reason and translated(stats.reason) or string.format(L.deStats, #items, stats.blocked or 0))
    for i, row in ipairs(U.inventoryRows) do
        local item = items[first + i - 1]
        row.item = item
        if item then
            row.icon:SetTexture(item.icon or 134400)
            row.name:SetText(item.link or item.name or L.unknownItem)
            local margin = ns.db.deSortValue and ns.DisenchantMargin(item)
            row.location:SetText(string.format(L.bagSlot, item.bag, item.slot)
                .. (margin and ("  /  " .. (margin < 0 and "-" or "+") .. money(math.abs(margin))) or ""))
            row.link, row.tooltip = item.link, item.name
            row.mark:SetChecked(ns.deMarked and ns.deMarked[item.guid] == true)
            enabled(row.mark, not busy)
            local selected = ns.selectedDE and ns.selectedDE.guid == item.guid
            row.background:SetColorTexture(unpackValues(selected and C.selected or C.button))
            row:Show()
        else row:Hide() end
    end
    U.inventoryPagination:SetText(string.format(L.page, first, last, #items))
    enabled(U.inventoryBack, U.inventoryPage > 1)
    enabled(U.inventoryNext, U.inventoryPage < pages)
    if #items == 0 then U.inventoryEmpty:Show() else U.inventoryEmpty:Hide() end
    local target = nextItem or ns.selectedDE
    U.dePreviewIcon:SetTexture(target and (target.icon or 134400) or nil)
    U.dePreviewCaption:SetText(target and L.dePreview or "")
    U.selectedItem:SetText(target and (target.link or target.name or L.unknownItem) or L.deSelect)
    renderDisenchantLoot(target)
    U.keep.tooltip = ns.selectedDE and (ns.selectedDE.link or ns.selectedDE.name) or nil
    local combat = InCombatLockdown and InCombatLockdown()
    U.deButton:SetText(nextItem and string.format(L.deNext, marked) or L.deAction)
    U.deButton.tooltip = nextItem and ((nextItem.link or nextItem.name or L.unknownItem) .. "\n" .. L.deWarning)
        or (L.deWarning .. "\n" .. L.deHint)
    enabled(U.deButton, (nextItem or ns.selectedDE) and not busy and not combat)
    enabled(U.keep, ns.selectedDE ~= nil and not ns.dePending)
    enabled(U.clearKeep, not ns.dePending)
end

function U.IsVisible() return U.frame ~= nil and U.frame:IsShown() end
function U.Show()
    U.Create()
    U.frame:Show()
    U.Render(ns.current, ns.snapshotReason)
end
function U.Toggle()
    if U.IsVisible() then U.frame:Hide() else U.Show() end
end

function U.MovePopup(dialog)
    if not dialog or not U.IsVisible() or U.activeTab ~= "enchant" or not ns.db.nearConfirm then return false end
    if ns.ownedPopup ~= dialog then return false end
    if dialog.which ~= "REPLACE_TRADESKILL_ENCHANT" and dialog.which ~= "REPLACE_ENCHANT" then return false end
    if not dialog.IsShown or not dialog:IsShown() or not dialog.GetButton1 or not dialog.GetCenter
        or not dialog.GetNumPoints or not dialog.GetPoint or not dialog.GetEffectiveScale then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    local yes = dialog:GetButton1()
    if not yes or not yes.GetCenter or not yes.GetEffectiveScale then return false end
    if movedPopups[dialog] then return true end
    local x, y = dialog:GetCenter()
    local yesX, yesY = yes:GetCenter()
    local scale, yesScale = dialog:GetEffectiveScale(), yes:GetEffectiveScale()
    if not finite(x) or not finite(y) or not finite(yesX) or not finite(yesY)
        or not finite(scale) or not finite(yesScale) or scale <= 0 then return false end
    local points = {}
    for i = 1, dialog:GetNumPoints() do points[i] = {dialog:GetPoint(i)} end
    if #points == 0 then return false end
    movedPopups[dialog] = {points = points, which = dialog.which}
    local ok = pcall(function()
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", U.action, "CENTER", x - yesX * yesScale / scale, y - yesY * yesScale / scale)
    end)
    if not ok then restorePopup(dialog); return false end
    -- No parent, attribute, or native script is changed. Our own update observes
    -- dismissal/reuse and restores the previous anchors without an OnHide hook.
    return true
end

function U.ShowDiagnostics(value, title)
    if not U.diagnosticFrame then
        local frame = CreateFrame("Frame", "EnchantPilotDiagnostics", UIParent)
        U.diagnosticFrame = frame
        frame:SetSize(480, 420)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:SetFrameStrata("DIALOG")
        frame:SetClampedToScreen(true)
        frame:EnableMouse(true)
        fill(frame, 0, 0, 480, 420, C.background)
        fill(frame, 0, 0, 480, 2, C.teal, "BORDER")
        U.diagnosticTitle = text(frame, 18, 15, 420, 24, L.diagnosis, 18, C.teal, true)
        text(frame, 18, 46, 444, 30, L.copy, 11, C.muted)
        local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
        close:SetSize(32, 32)
        close:SetScript("OnClick", function() frame:Hide() end)
        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -82)
        scroll:SetSize(426, 316)
        U.diagnosticScroll = scroll
        local edit = CreateFrame("EditBox", nil, scroll)
        U.diagnosticEdit = edit
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject("ChatFontNormal")
        edit:SetSize(420, 316)
        edit:SetTextInsets(2, 2, 2, 2)
        edit:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(edit)
        if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "EnchantPilotDiagnostics" end
    end
    local output = tostring(value or "")
    U.diagnosticTitle:SetText(title or L.diagnosis)
    local _, lines = output:gsub("\n", "\n")
    U.diagnosticEdit:SetHeight(math.max(316, (lines + 2) * 15))
    U.diagnosticEdit:SetText(output)
    U.diagnosticFrame:Show()
    U.diagnosticScroll:SetVerticalScroll(0)
    U.diagnosticEdit:SetFocus()
    U.diagnosticEdit:HighlightText()
end
