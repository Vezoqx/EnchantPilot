local addonName, ns = ...
local A = ns.Adapter
local eventFrame = CreateFrame('Frame')
local clockAccumulator = 0
local snapshotAccumulator = 0
local nextAuctionRefresh
local openingAuctionRefresh
local bankRefreshAt
local AUCTION_REFRESH_INTERVAL = 15 * 60
local deSeen = {}
ns.deMarked = {}
local logs = {}
local watchedPopups=setmetatable({},{__mode='k'})
local defaults = {count=10,reserve=0,skillGoal=0,stopOnGray=true,quickConfirm=false,nearConfirm=true,sound=true,includeRare=false,priceStaleMinutes=30}

local function now() return GetTime() end
local function log(code)
    logs[#logs+1] = string.format('%.1f %s', now(), code)
    if #logs > 50 then table.remove(logs,1) end
end
local function notify(code)
    ns.notice = code
    log(code)
end
local function printMessage(text)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff70dcc5EnchantPilot|r: '..text) end
end
local function copy(source)
    local out={}
    for key,value in pairs(source) do out[key]=value end
    return out
end
local function protectedTarget()
    if ns.locked then return ns.locked.targetGUID end
    local s=A.Snapshot()
    return s and s.targetGUID
end
local function validateDE(item)
    if not item then return false,'no_selection' end
    if ns.locked and item.guid==ns.locked.targetGUID then return false,'enchant_target' end
    if ns.enchantTarget and item.guid==ns.enchantTarget.guid then return false,'enchant_target' end
    local current,reason=A.NativeTarget()
    if reason then return false,reason end
    if current and item.guid==current then return false,'enchant_target' end
    return ns.Inventory.Validate(item,protectedTarget(),ns.db.keep,ns.db.includeRare,ns.db.includeEpic)
end
local function clearPopup()
    ns.ownedPopup=nil
    ns.popupLostAt=nil
end

local function visibleReplacement()
    local dialog=A.ReplacementPopup()
    if not dialog then return nil end
    local visibility=dialog.IsVisible or dialog.IsShown
    if visibility then
        local ok,shown=pcall(visibility,dialog)
        -- Inconclusive visibility must not release an unresolved request.
        if not ok or not A.IsPublic(shown) then return dialog end
        if shown==false then return nil end
    end
    return dialog
end

local function targeting()
    if not SpellIsTargeting then return false end
    local ok,value=pcall(SpellIsTargeting)
    return not ok or not A.IsPublic(value) or value~=false
end

local function observePopup(dialog)
    local token={frame=dialog,intentAt=ns.engine.session.intentAt,hidden=false}
    ns.popupToken=token
    if not dialog.HookScript then return end
    if watchedPopups[dialog] then return end
    watchedPopups[dialog]=true
    -- Observe only the dialog lifecycle. Native keyboard/gamepad acceptance can
    -- bypass the button's PreClick, so it cannot be evidence of acceptance.
    dialog:HookScript('OnHide',function()
        local current=ns.popupToken
        if not current or current.frame~=dialog then return end
        current.hidden=true
        clearPopup()
        ns.popupLostAt=now()
    end)
    dialog:HookScript('OnShow',function()
        local current=ns.popupToken
        if not current or current.frame~=dialog then return end
        -- Pooled frames can show a new same-kind dialog without a game event.
        current.invalid=true
        clearPopup()
        if not (ns.engine.session and ns.engine.session.castGUID) then ns.engine:Fail('popup_cancelled') end
    end)
end

local function samePriceRecipe(a,b)
    return a and b and a.recipeID==b.recipeID and a.recipeLevel==b.recipeLevel and a.allocationKey==b.allocationKey
end

local function refreshPriceSelection()
    if ns.priceSelection and ns.priceSelection.shoppingOnly then return end
    local selection, why=A.PriceSelection()
    ns.priceSelectionLive=selection~=nil
    if selection or why~='profession_closed' then
        if ns.priceScanSelection and not samePriceRecipe(selection,ns.priceScanSelection)
            and ns.Auction.GetStatus().state=='auction_scanning' then
            ns.Auction.Stop('auction_context')
        end
        ns.priceSelection=selection
    end
end

function ns.ChoosePriceRecipe(recipe)
    local live = recipe.learned and A.PriceSelection()
    local selection, reason
    if live and live.recipeID == recipe.recipeID then
        selection = live
    else
        selection, reason = A.PriceRecipe(recipe)
    end
    if not selection and not recipe.learned and ns.Catalog and ns.Catalog.FormulaItemID(recipe.recipeID) then
        selection = {recipeID=recipe.recipeID, name=recipe.name, icon=recipe.icon, materials={}, shoppingOnly=true}
    end
    if not selection then return false, reason end
    if ns.priceScanSelection and not samePriceRecipe(selection, ns.priceScanSelection)
        and ns.Auction.GetStatus().state == "auction_scanning" then
        ns.Auction.Stop("auction_context")
    end
    selection.learned = recipe.learned
    ns.priceSelection, ns.priceSelectionLive = selection, not selection.shoppingOnly
    return true
end

local function priceItemIDs(selection)
    local ids={}
    for _,material in ipairs(selection and selection.materials or {}) do ids[#ids+1]=material.itemID end
    return ids
end

function ns.ScanPrices()
    refreshPriceSelection()
    if ns.combinedPlan and ns.combinedPlan.goal then ns.RebuildShoppingPlan(true, ns.combinedPlan.goal) end
    local ids = priceItemIDs(ns.combinedPlan or ns.priceSelection)
    if ns.combinedPlan and ns.combinedPlan.original then
        for _, material in ipairs(ns.combinedPlan.original) do ids[#ids+1]=material.itemID end
    end
    local formula = ns.priceSelection and ns.priceSelection.learned == false and ns.Catalog
        and ns.Catalog.FormulaItemID(ns.priceSelection.recipeID)
    if formula and not ns.combinedPlan then ids[#ids+1] = formula end
    local ok, why=ns.Auction.Start(ids)
    if ok then ns.priceScanSelection=not ns.combinedPlan and ns.priceSelection or nil end
    return ok, why
end

function ns.GoalMaterials(scope, original)
    local skill, maximum = ns.Leveling.Skill()
    local replacements = not original and ns.db.routeReplacements or nil
    local plan, issue, limit, changed, blocked = ns.Leveling.GoalPlan(skill, ns.db.levelingGoal, maximum, scope, replacements)
    local materials = ns.PriceModel.CombineRecipes(plan, A.ReagentCount)
    local bank = ns.db.personalBank
    if type(bank) == 'table' and type(bank.counts) == 'table' then
        for _, row in ipairs(materials) do row.bank = bank.counts[row.itemID] or 0 end
    end
    return materials, issue, maximum, limit, changed, blocked
end

function ns.RebuildShoppingPlan(active, goal)
    if active and goal then
        local materials, issue, _, limit, changed, blocked = ns.GoalMaterials(goal)
        local name = goal == 'trainer'
            and (limit and string.format(ns.L.goal_trainer_title, limit) or ns.L.goal_trainer)
            or string.format(ns.L.goal_title, ns.db.levelingGoal)
        ns.combinedPlan = {name=name, materials=materials, limit=limit,
            original=changed and ns.GoalMaterials(goal, true) or nil, blocked=blocked,
            issue=issue, shoppingOnly=true, goal=goal}
        return ns.combinedPlan
    end
    local plan = ns.db.shoppingPlan
    local materials = ns.PriceModel.CombineRecipes(plan, A.ReagentCount)
    ns.combinedPlan = active and materials and #materials > 0
        and {name=ns.L.plan_title, materials=materials, shoppingOnly=true} or nil
    return ns.combinedPlan
end

function ns.QuoteMaterials(materials, casts, reserve)
    local auction = ns.Auction
    local market = auction.MarketKey()
    local prices = auction.GetPrices(priceItemIDs({materials=materials}), market)
    return ns.PriceModel.Quote(materials, casts, reserve, prices, {marketKey=market,
        now=GetServerTime and GetServerTime(), staleAfter=(tonumber(ns.db.priceStaleMinutes) or 30)*60})
end

function ns.ScanAuctionSummary(automatic)
    local ok, reason = ns.Auction.StartSummary(function(count, stopped, awaiting)
        if automatic and stopped == 'auction_conflict' and not awaiting then nextAuctionRefresh = now() + 3 end
        printMessage(stopped and ns.Reason(stopped) or string.format(ns.L.auction_summary_done, count))
    end, automatic)
    if ok then
        nextAuctionRefresh, openingAuctionRefresh = now() + AUCTION_REFRESH_INTERVAL, nil
        ns.priceScanSelection = nil
        printMessage(automatic and ns.L.auction_auto_started or ns.L.auction_summary_scanning)
    elseif not automatic then
        printMessage(ns.Reason(reason))
    end
    return ok, reason
end

local function refreshAuctionAutomatically(opening)
    local status = ns.Auction.GetStatus()
    if not status.open then nextAuctionRefresh = nil; return end
    if status.state == 'auction_scanning' then
        nextAuctionRefresh = now() + 1
        return
    end
    nextAuctionRefresh = now() + AUCTION_REFRESH_INTERVAL
    local ok, reason = ns.ScanAuctionSummary(true)
    if reason == 'auction_wait_external' then
        nextAuctionRefresh = now() + 3
        if opening then printMessage(ns.L.auction_auto_wait) end
    elseif not ok and opening then
        printMessage(ns.Reason(reason))
    end
end

function ns.GetPriceQuote(settings)
    if ns.combinedPlan then
        ns.RebuildShoppingPlan(true, ns.combinedPlan.goal)
        if ns.combinedPlan and ns.combinedPlan.issue then return {issue=ns.combinedPlan.issue} end
        if not ns.combinedPlan then return end
        return ns.QuoteMaterials(ns.combinedPlan.materials, 1, 0)
    end
    local selection=ns.priceSelection
    if not selection then return end
    local view=ns.engine:GetView()
    local casts,reserve=settings.count,settings.reserve
    local planCount = tonumber(ns.db.pricePlanCount) or 0
    local draft = planCount > 0 or selection.isItemCraft or (selection.shoppingOnly and not samePriceRecipe(selection, ns.locked))
    if planCount > 0 then casts = planCount end
    if ns.engine.session and view.state~='complete' and not draft then
        if not samePriceRecipe(selection,ns.locked) then return {issue='auction_session_recipe'} end
        casts,reserve=view.remaining,view.reserve
    elseif casts<1 or casts>500 or reserve>500 then
        return {issue='auction_invalid_plan'}
    end
    local materials={}
    for i,material in ipairs(selection.materials) do
        materials[i]={itemID=material.itemID,per=material.per,have=A.ReagentCount(material.itemID)}
    end
    local quote = ns.QuoteMaterials(materials,casts,reserve)
    quote.draft = draft
    return quote
end

function ns.DisenchantMargin(item)
    local outcomes, _, partial = ns.Disenchant.Outcomes(item)
    if not outcomes or partial or type(item.sellPrice) ~= 'number' then return end
    local ids = {}
    for _, drop in ipairs(outcomes) do ids[#ids+1] = drop[1] end
    local auction = ns.Auction
    local time = GetServerTime and GetServerTime()
    local age = math.max(1, tonumber(ns.db.priceStaleMinutes) or 30) * 60
    local value = ns.PriceModel.DisenchantValue(outcomes, auction.GetPrices(ids, auction.MarketKey()), time, age)
        or ns.PriceModel.DisenchantSummaryValue(outcomes, auction.GetSummary(), time, age)
    if value then return value - item.sellPrice end
end

function ns.Refresh()
    if not ns.initialized then return end
    local current,reason=A.Snapshot()
    ns.current=current
    ns.snapshotReason=reason
    if A.PriceSelection then refreshPriceSelection() end
    if ns.UI then ns.UI.Render(current,reason) end
end

function ns.Arm(expectedRecipe, expectedTarget)
    local snapshot,reason=A.Snapshot()
    if not snapshot then notify(reason);return false,reason end
    if expectedRecipe and snapshot.recipeID~=expectedRecipe then notify('recipe_changed');return false,'recipe_changed' end
    if expectedTarget and snapshot.targetGUID~=expectedTarget then notify('target_changed');return false,'target_changed' end
    if A.AnyPopup() then notify('existing_popup');return false,'existing_popup' end
    if ns.dePending or A.IsBusy() then notify('busy');return false,'busy' end
    local settings=ns.UI.GetSettings()
    local count,reserve=tonumber(settings.count),tonumber(settings.reserve)
    local clamped=false
    if count and count>=1 and count<=500 and count==math.floor(count) and reserve and reserve>=0 and reserve<=500 and reserve==math.floor(reserve) then
        local capacity=math.max(0,snapshot.available-reserve)
        if capacity<1 then local why=snapshot.available==0 and 'no_materials' or 'reserve';notify(why);return false,why end
        if count>capacity then count=capacity;clamped=true end
    end
    local ok,errorCode=ns.engine:Arm(snapshot,count,{reserve=reserve,skillGoal=tonumber(settings.skillGoal),stopOnGray=settings.stopOnGray})
    if not ok then notify(errorCode);return false,errorCode end
    ns.locked=copy(snapshot)
    ns.enchantRecipe=nil
    ns.enchantTarget=nil
    ns.quickBlocked=true
    ns.pendingHadPopup=false
    ns.pendingProgrammatic=false
    ns.popupToken=nil
    ns.blockedIntentAt=nil
    clearPopup()
    for _,key in ipairs({'count','reserve','skillGoal','stopOnGray'}) do ns.db[key]=settings[key] end
    notify(clamped and 'plan_clamped' or 'ready')
    ns.Refresh()
    return true
end

function ns.CaptureEnchant()
    local recipe = ns.enchantRecipe
    if not recipe then return ns.Arm() end
    if ns.dePending or ns.engine:GetView(ns.current).inFlight or A.IsBusy() then return false, 'busy' end
    local ready, reason = A.PrepareEnchantRecipe(recipe.recipeID)
    if not ready then return false, reason end
    local target = ns.enchantTarget
    if target then
        local applied
        applied, reason = A.ApplyEnchantTarget(recipe.recipeID, target)
        if not applied then return false, reason end
    end
    return ns.Arm(recipe.recipeID, target and target.guid)
end

local function ownPopupStillVisible()
    return ns.ownedPopup and visibleReplacement()==ns.ownedPopup
end

local function inputAction()
    if not ns.initialized then return false end
    if not ns.UI.IsVisible() then ns.UI.Show();return false end
    if ns.enchantRecipe then notify('enchant_pick_target');return false end
    if ns.dePending then notify('busy');return false end
    local view=ns.engine:GetView(ns.current)
    if view.inFlight then
        notify(ownPopupStillVisible() and 'confirm_manually' or 'busy')
        return false
    end
    if A.AnyPopup() then notify('existing_popup');return false end
    if A.IsBusy() then notify('busy');return false end
    if targeting() then notify('targeting');return false end
    if ns.engine.state=='complete' then notify(ns.engine.reason);return false end
    if not ns.engine.session then
        local ok=ns.Arm()
        if not ok then return false end
    end
    local current,reason=A.Snapshot()
    if not current then ns.engine:Pause(reason);notify(reason);return false end
    ns.current=current
    local ok,errorCode=ns.engine:Request(current,now())
    if not ok then notify(errorCode);return false end
    clearPopup()
    ns.pendingHadPopup=false
    ns.pendingProgrammatic=false
    ns.popupToken=nil
    ns.blockedIntentAt=nil
    local castOK,castError=A.Cast(ns.locked)
    if not castOK then
        if ns.engine.session and ns.engine.session.castGUID then ns.engine:Pause(castError) else ns.engine:Fail(castError) end
        notify(castError);return false
    end
    -- With no preexisting prompt, a synchronous replacement dialog generated
    -- by this one request belongs to this input. Async prompts retain native UI.
    local popup=visibleReplacement()
    if popup and ns.engine:GetView(current).inFlight then
        ns.ownedPopup=popup
        ns.pendingHadPopup=true
        observePopup(popup)
        ns.engine:ConfirmPending()
        -- Replacement is confirmed exclusively by the actual native button.
        -- A scripted click can hide the prompt even when the protected action
        -- is blocked, so popup disappearance is never treated as acceptance.
        if ns.ownedPopup and ns.db.nearConfirm and ns.UI.MovePopup then ns.UI.MovePopup(ns.ownedPopup) end
    end
    notify(ns.engine.reason)
    return true
end

function ns.Act()
    if ns.inAction then return false end
    ns.inAction=true
    local ok,result=pcall(inputAction)
    ns.inAction=false
    if not ok then
        if ns.engine then ns.engine:Pause('api_error') end
        notify('api_error')
    end
    ns.Refresh()
    return ok and result or false
end

function ns.Pause(reason)
    if not ns.initialized then return end
    reason=reason or 'user_pause'
    ns.engine:Pause(reason)
    notify(reason)
    ns.Refresh()
end

function ns.Reset()
    if ns.dePending then notify('busy');return false end
    local ok,reason=ns.engine:Reset()
    if not ok then notify(reason);return false end
    ns.locked=nil
    ns.enchantRecipe=nil
    ns.enchantTarget=nil
    ns.popupToken=nil
    clearPopup()
    notify('idle')
    ns.Refresh()
    return true
end

function ns.DisenchantQueue()
    local first, count = nil, 0
    for _, item in ipairs(ns.items or {}) do
        if ns.deMarked[item.guid] then
            first = first or item
            count = count + 1
        end
    end
    return first, count
end

function ns.RefreshInventory()
    if not ns.initialized then return end
    ns.items,ns.inventoryStats=ns.Inventory.Scan(protectedTarget(),ns.db.keep,ns.db.includeRare,ns.db.includeEpic)
    local nativeTarget,targetReason=A.NativeTarget()
    if targetReason then
        ns.items={};ns.inventoryStats.reason=targetReason;ns.inventoryStats.eligible=0
    elseif nativeTarget then
        for i=#ns.items,1,-1 do
            if ns.items[i].guid==nativeTarget then
                table.remove(ns.items,i)
                ns.inventoryStats.blocked=(ns.inventoryStats.blocked or 0)+1
                ns.inventoryStats.reasons=ns.inventoryStats.reasons or {}
                ns.inventoryStats.reasons.enchant_target=(ns.inventoryStats.reasons.enchant_target or 0)+1
            end
        end
        ns.inventoryStats.eligible=#ns.items
    end
    if ns.db.deSortValue then
        local margins, order = {}, {}
        for i, item in ipairs(ns.items) do
            margins[item.guid], order[item.guid] = ns.DisenchantMargin(item), i
        end
        table.sort(ns.items, function(a,b)
            local x,y = margins[a.guid] or -math.huge, margins[b.guid] or -math.huge
            if x == y then return order[a.guid] < order[b.guid] end
            return x > y
        end)
    end
    local marked = {}
    for _, item in ipairs(ns.items) do
        if ns.deMarked[item.guid] then marked[item.guid] = true end
    end
    ns.deMarked = marked
    if ns.selectedDE then
        local valid=validateDE(ns.selectedDE)
        if not valid then ns.selectedDE=nil end
    end
    if ns.UI then ns.UI.RenderInventory() end
end

function ns.ToggleDEMark(item)
    if ns.dePending or ns.engine:GetView(ns.current).inFlight then return end
    if not ns.deMarked[item.guid] then
        local ok, reason = validateDE(item)
        if not ok then notify(reason);ns.RefreshInventory();return end
    end
    ns.deMarked[item.guid] = not ns.deMarked[item.guid] or nil
    ns.UI.RenderInventory()
end

function ns.SelectDE(item)
    if ns.dePending or ns.engine:GetView(ns.current).inFlight then notify('busy');return false end
    local ok,reason=validateDE(item)
    if not ok then notify(reason);ns.RefreshInventory();return false end
    ns.selectedDE=item
    ns.UI.RenderInventory()
    return true
end

function ns.KeepSelected()
    if not ns.selectedDE or ns.dePending then return end
    ns.Inventory.SetKeep(ns.db.keep,ns.selectedDE.guid,true)
    ns.selectedDE=nil
    ns.RefreshInventory()
end

function ns.ClearKeep()
    if ns.dePending then return end
    ns.db.keep={}
    ns.RefreshInventory()
end

local actionAttributes={'type','spell','macro','macrotext','target-bag','target-slot','target-item'}
local function disarm(button)
    for _,attribute in ipairs(actionAttributes) do button:SetAttribute(attribute,nil) end
end

function ns.PreDisenchant(button,mouseButton,down)
    -- The native secure handler applies item targeting after action dispatch,
    -- even with no action type. Always clear the targeting attributes as well.
    disarm(button)
    if mouseButton~='LeftButton' or down then return end
    if button.IsVisible and not button:IsVisible() then return end
    if InCombatLockdown and InCombatLockdown() then notify('combat');return end
    if ns.dePending or ns.engine:GetView(ns.current).inFlight or A.IsBusy() then notify('busy');return end
    local moving,moveReason=A.IsMoving()
    if moving~=false then notify(moveReason or 'moving');return end
    if SpellIsTargeting and SpellIsTargeting() then notify('targeting');return end
    if A.AnyPopup() then notify('existing_popup');return end
    local selected=ns.DisenchantQueue() or ns.selectedDE
    if not selected then notify('no_selection');return end
    local valid,reason=validateDE(selected)
    if not valid then notify(reason);ns.selectedDE=nil;ns.RefreshInventory();return end
    ns.engine:Pause('user_pause')
    ns.dePending={guid=selected.guid,link=selected.link,startedAt=now()}
    button:SetAttribute('useOnKeyDown',false)
    button:SetAttribute('pressAndHoldAction',false)
    button:SetAttribute('spell',13262)
    button:SetAttribute('target-bag',selected.bag)
    button:SetAttribute('target-slot',selected.slot)
    button:SetAttribute('type','spell')
    notify('casting')
end

function ns.PostDisenchant(button)
    disarm(button)
end

local function normalSpellID(spellID)
    local session=ns.engine.session
    if session and ns.locked and ns.locked.spellIDs and ns.locked.spellIDs[spellID] then return session.recipeID end
    return spellID
end

local function captureDisenchantLoot()
    if not GetNumLootItems or not GetLootSourceInfo or not GetLootSlotLink then return end
    local targets, matches = {}, {}
    local function track(entry)
        if entry and not entry.drops and now()-entry.startedAt <= 20 then targets[entry.guid]=entry end
    end
    track(ns.lastDisenchant)
    track(ns.dePending)
    if not next(targets) then return end
    for slot=1,GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        if A.IsPublic(link) and type(link)=='string' then
            local sources = {GetLootSourceInfo(slot)}
            for i=1,#sources,2 do
                local guid, amount = sources[i], sources[i+1]
                if A.IsPublic(guid) and targets[guid] and A.IsPublic(amount)
                    and type(amount)=='number' and amount>0 then
                    local drops = matches[guid] or {}
                    drops[#drops+1] = {link=link, count=amount}
                    matches[guid] = drops
                end
            end
        end
    end
    for guid, drops in pairs(matches) do targets[guid].drops = drops end
end

local function handleCast(event,unit,castGUID,spellID)
    if not A.IsPublic(unit) or not A.IsPublic(castGUID) or not A.IsPublic(spellID) then return end
    if unit~='player' or type(castGUID)~='string' or type(spellID)~='number' then return end
    if ns.dePending and spellID==13262 and not deSeen[castGUID] then
        local pending=ns.dePending
        if not pending.castGUID or pending.castGUID==castGUID then
            if event=='UNIT_SPELLCAST_START' then pending.castGUID=castGUID
            elseif event=='UNIT_SPELLCAST_SUCCEEDED' then
                deSeen[castGUID]=true;ns.dePending=nil;ns.selectedDE=nil
                pending.time = GetServerTime and GetServerTime()
                local history = ns.db.deHistory
                table.insert(history, 1, pending)
                history[31] = nil
                ns.lastDisenchant = pending
                ns.deMarked[pending.guid]=nil
                ns.RefreshInventory();notify('ready')
            elseif event=='UNIT_SPELLCAST_FAILED' or event=='UNIT_SPELLCAST_FAILED_QUIET' or event=='UNIT_SPELLCAST_INTERRUPTED' then
                deSeen[castGUID]=true;ns.dePending=nil;notify('cast_failed')
            end
        end
        return
    end
    local id=normalSpellID(spellID)
    local session=ns.engine.session
    if session and id==session.recipeID and not session.castGUID and (event=='UNIT_SPELLCAST_START' or event=='UNIT_SPELLCAST_SUCCEEDED') then
        local nativeTarget=A.NativeTarget()
        if nativeTarget and nativeTarget~=session.targetGUID then
            ns.engine:Fail('target_changed');clearPopup();notify('target_changed');return
        end
    end
    if event=='UNIT_SPELLCAST_START' then
        local ok=ns.engine:CastStart(id,castGUID,now())
        if ok then clearPopup();notify(ns.engine.reason) end
    elseif event=='UNIT_SPELLCAST_SUCCEEDED' then
        local ok=ns.engine:Success(id,castGUID,now(),A.Skill(id))
        if ok then
            ns.popupToken=nil
            ns.blockedIntentAt=nil
            ns.pendingHadPopup=false
            ns.pendingProgrammatic=false
            clearPopup();notify(ns.engine.reason)
            if ns.engine.state=='complete' and ns.db.sound and PlaySound then pcall(PlaySound,12867,'Master') end
        end
    elseif event=='UNIT_SPELLCAST_FAILED' or event=='UNIT_SPELLCAST_FAILED_QUIET' or event=='UNIT_SPELLCAST_INTERRUPTED' then
        local session=ns.engine.session
        if session and id==session.recipeID and (not session.castGUID or session.castGUID==castGUID) then
            local reason=event=='UNIT_SPELLCAST_INTERRUPTED' and 'cast_interrupted' or 'cast_failed'
            local changed=ns.engine:FailCast(id,castGUID,now(),reason)
            if changed then clearPopup();ns.pendingHadPopup=false;ns.pendingProgrammatic=false;notify(reason) end
        end
    end
end

function ns.OnEvent(event,...)
    if event=='PLAYER_LOGIN' then ns.Initialize();return end
    if not ns.initialized then return end
    if event=='BANKFRAME_OPENED' then
        ns.bankOpen, ns.bankCurrent = true, false
    elseif event=='BANKFRAME_CLOSED' then
        ns.bankOpen, ns.bankCurrent, bankRefreshAt = false, false, nil
    end
    if ns.bankOpen and (event=='BANKFRAME_OPENED' or event=='BAG_UPDATE_DELAYED'
        or event=='PLAYERBANKSLOTS_CHANGED' or event=='BANK_TABS_CHANGED') then
        bankRefreshAt = bankRefreshAt or now()+0.2
    end
    if event=='CHAT_MSG_ADDON' or event=='GROUP_ROSTER_UPDATE' or event=='PLAYER_GUILD_UPDATE' then
        if ns.VersionNotice then ns.VersionNotice.OnEvent(event,...) end
        return
    end
    if event=='LOOT_READY' or event=='LOOT_OPENED' then captureDisenchantLoot();return end
    if event=='PLAYER_LOGOUT' then
        local view=ns.engine:GetView(ns.current)
        ns.db.savedSession = ns.locked and view.remaining>0 and not view.inFlight
            and ns.engine.state~='complete' and {snapshot=ns.locked, progress=ns.engine.session} or nil
        return
    end
    if event=='TRAINER_SHOW' or event=='TRAINER_UPDATE' or event=='TRAINER_CLOSED' then
        ns.Catalog.UpdateTrainer(event=='TRAINER_CLOSED')
        ns.UI.InvalidateRecipes()
    end
    if ns.auctionEvents and ns.auctionEvents[event] then
        local wasScanning = ns.db.deSortValue and ns.Auction.GetStatus().state == 'auction_scanning'
        ns.Auction.OnEvent(event,...)
        if wasScanning and ns.Auction.GetStatus().state ~= 'auction_scanning' then ns.inventoryDirty=true end
        if (event=='AUCTION_HOUSE_SHOW' or event=='AUCTION_HOUSE_CLOSED') and ns.UI.InvalidateRecipes then
            ns.UI.InvalidateRecipes()
        end
        if event=='AUCTION_HOUSE_SHOW' and not nextAuctionRefresh then
            nextAuctionRefresh,openingAuctionRefresh=now()+3,true
        elseif event=='AUCTION_HOUSE_CLOSED' then nextAuctionRefresh,openingAuctionRefresh=nil,nil end
        return
    end
    if ns.Catalog and ns.Catalog.RefreshCache and (event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_LIST_UPDATE'
        or event=='TRADE_SKILL_DATA_SOURCE_CHANGED' or event=='NEW_RECIPE_LEARNED' or event=='SKILL_LINES_CHANGED') then
        -- Capture the character's own recipe data even if our Recipes tab was
        -- never visited. Closing a profession never erases a complete cache.
        local ok=pcall(ns.Catalog.RefreshCache)
        if not ok then log('catalog_refresh_failed') end
    end
    if ns.UI.InvalidateRecipes and (event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_CLOSE' or event=='TRADE_SKILL_DATA_SOURCE_CHANGED' or event=='TRADE_SKILL_LIST_UPDATE' or event=='NEW_RECIPE_LEARNED' or event=='SKILL_LINES_CHANGED') then
        ns.UI.InvalidateRecipes()
    end
    if event=='UNIT_SPELLCAST_START' or event=='UNIT_SPELLCAST_SUCCEEDED' or event=='UNIT_SPELLCAST_FAILED' or event=='UNIT_SPELLCAST_FAILED_QUIET' or event=='UNIT_SPELLCAST_INTERRUPTED' then
        handleCast(event,...)
    elseif event=='PLAYER_REGEN_DISABLED' then ns.Pause('combat')
    elseif event=='PLAYER_STARTED_MOVING' then ns.Pause('moving')
    elseif event=='TRADE_SKILL_CLOSE' then ns.Pause('profession_closed')
    elseif event=='REPLACE_TRADESKILL_ENCHANT' or event=='REPLACE_ENCHANT' then
        -- Events may describe another addon or native action. They never accept
        -- dialogs and never grant ownership outside our originating click.
        if not ns.inAction then clearPopup() end
    elseif event=='ADDON_ACTION_BLOCKED' or event=='ADDON_ACTION_FORBIDDEN' then
        local name,blockedFunction=...
        if A.IsPublic(name) and name==addonName then
            ns.quickBlocked=true
            ns.db.quickConfirm=false
            ns.lastBlockedFunction=A.IsPublic(blockedFunction) and type(blockedFunction)=='string'
                and blockedFunction:gsub('[%c]',' '):sub(1,160) or 'unknown'
            ns.lastBlockedAt=now()
            ns.blockedIntentAt=ns.engine.session and ns.engine.session.intentAt
            log('blocked: '..ns.lastBlockedFunction)
            notify('action_blocked')
            if not visibleReplacement() then ns.engine:Pause('action_blocked') end
            if ns.UI.RestorePopups and not ns.restoringPopups then
                ns.restoringPopups=true;pcall(ns.UI.RestorePopups);ns.restoringPopups=false
            end
        end
    elseif event=='BAG_UPDATE_DELAYED' or event=='GET_ITEM_INFO_RECEIVED' or event=='EQUIPMENT_SETS_CHANGED' or event=='PLAYER_EQUIPMENT_CHANGED' then
        ns.inventoryDirty=true
    end
    ns.Refresh()
    if next(ns.db.routeReplacements) and (event=='SKILL_LINES_CHANGED' or event=='TRADE_SKILL_LIST_UPDATE'
        or event=='TRADE_SKILL_SHOW') then
        local skill = ns.Leveling.Skill()
        local step = ns.Leveling.steps[ns.Leveling.Stage(skill)]
        ns.Leveling.ReplacementExhausted(step, ns.db.routeReplacements[step[1]], skill)
        if ns.UI.activeTab == 'replacements' then ns.UI.RenderReplacements() end
        if ns.UI.activeTab == 'goal' then ns.UI.RenderGoal() end
        if ns.UI.activeTab == 'budget' then ns.UI.RenderBudget() end
    end
    if ns.UI.activeTab == 'leveling' and (event=='GET_ITEM_INFO_RECEIVED' or event=='BAG_UPDATE_DELAYED'
        or event=='SKILL_LINES_CHANGED' or event=='TRAINER_SHOW' or event=='TRAINER_UPDATE'
        or event=='TRAINER_CLOSED' or event=='PLAYER_LEVEL_UP' or event=='NEW_RECIPE_LEARNED'
        or event=='TRADE_SKILL_LIST_UPDATE') then ns.UI.RenderGuide() end
    if ns.UI.activeTab == 'annora' and (event=='NEW_RECIPE_LEARNED' or event=='SKILL_LINES_CHANGED'
        or event=='TRADE_SKILL_LIST_UPDATE' or event=='PLAYER_LEVEL_UP') then ns.UI.RenderAnnora() end
    if ns.UI.RenderTracker and (event=='BAG_UPDATE_DELAYED' or event=='GET_ITEM_INFO_RECEIVED'
        or event=='SKILL_LINES_CHANGED' or event=='TRADE_SKILL_LIST_UPDATE') then ns.UI.RenderTracker() end
end

function ns.Pulse(elapsed)
    if not ns.initialized then return end
    if bankRefreshAt and now() >= bankRefreshAt then
        bankRefreshAt = nil
        local counts = A.PersonalBankCounts()
        local time = GetServerTime and GetServerTime()
        ns.bankCurrent = counts and time and true or false
        if ns.bankCurrent then ns.db.personalBank = {counts=counts, time=time} end
        if ns.UI.RenderTracker then ns.UI.RenderTracker() end
    end
    clockAccumulator=clockAccumulator+elapsed
    snapshotAccumulator=snapshotAccumulator+elapsed
    if clockAccumulator<0.1 then return end
    clockAccumulator=0
    if ns.Auction then ns.Auction.Pulse() end
    if nextAuctionRefresh and now() >= nextAuctionRefresh then
        local opening = openingAuctionRefresh
        openingAuctionRefresh = nil
        refreshAuctionAutomatically(opening)
    end
    local changed,reason=ns.engine:Tick(now())
    if changed then clearPopup();notify(reason) end
    if ns.dePending and now()-ns.dePending.startedAt>20 then ns.dePending=nil;notify('request_timeout') end
    local view=ns.engine:GetView(ns.current)
    local blocked=view.intentAt and ns.blockedIntentAt==view.intentAt
    if view.inFlight and not view.castGUID and (view.phase=='confirming' or blocked) then
        if visibleReplacement() then
            ns.popupLostAt=nil
        else
            ns.popupLostAt=ns.popupLostAt or now()
            -- Native Yes can hide before START arrives. Observe for a short
            -- grace period even when the original popup pointer was cleared.
            if now()-ns.popupLostAt>=2 and not A.IsBusy() and not targeting() then
                local lostReason=blocked and 'action_blocked' or 'confirmation_lost'
                ns.engine:Fail(lostReason)
                ns.popupToken=nil;ns.pendingHadPopup=false;ns.pendingProgrammatic=false;ns.blockedIntentAt=nil
                clearPopup();notify(lostReason)
            end
        end
    end
    if snapshotAccumulator>=0.5 then
        snapshotAccumulator=0
        ns.Refresh()
        if ns.inventoryDirty and not (InCombatLockdown and InCombatLockdown()) then
            ns.inventoryDirty=false;ns.RefreshInventory()
            if ns.UI.recipeMode=='learnable' then ns.UI.InvalidateRecipes() end
        end
    elseif ns.UI.IsVisible() and ns.UI.activeTab~='prices' then ns.UI.Render(ns.current,ns.snapshotReason) end
    -- Deliberately no cast, confirmation, item-use, or queue continuation here.
end

function ns.Debug()
    local version,build,_,interface=GetBuildInfo()
    local view=ns.engine:GetView(ns.current)
    local lines={'EnchantPilot '..ns.VERSION,'Client '..tostring(version)..' / '..tostring(build)..' / Interface '..tostring(interface),
        'State: '..view.state,'Reason: '..tostring(view.reason),'Snapshot: '..tostring(ns.snapshotReason or 'ok'),
        'In flight: '..tostring(view.inFlight),'Phase: '..tostring(view.phase or 'none'),
        'Request age: '..(view.intentAt and string.format('%.1fs',math.max(0,now()-view.intentAt)) or 'none'),
        'Cast GUID: '..tostring(view.castGUID or 'none'),
        'Native replacement visible: '..tostring(visibleReplacement()~=nil),
        'Native cast busy: '..tostring(A.IsBusy()),'Targeting cursor: '..tostring(targeting()),
        'Progress: '..view.completed..'/'..view.goal,'Recipe: '..tostring(view.recipeID),
        'Target GUID: '..tostring(view.targetGUID),'Available: '..tostring(view.available),'Reserve: '..tostring(view.reserve),
        'Confirmation mode: native button only',
        'Last blocked function: '..tostring(ns.lastBlockedFunction or 'none'),
        'Disenchant pending: '..tostring(ns.dePending~=nil),
        'Native CraftEnchant API: '..tostring(C_TradeSkillUI and type(C_TradeSkillUI.CraftEnchant)=='function'),
        '--- Recent transitions (no chat data) ---'}
    if ns.Auction then
        local auction=ns.Auction.GetStatus(true)
        table.insert(lines,#lines,string.format('Auction: %s / %s / generation %d / snapshot %s / reason %s',
            auction.state,tostring(auction.marketKey),auction.generation,tostring(auction.scannedAt),tostring(auction.reason)))
    end
    for _,line in ipairs(logs) do lines[#lines+1]=line end
    ns.UI.ShowDiagnostics(table.concat(lines,'\n'))
end

function ns.Initialize()
    if ns.initialized then return end
    EnchantPilotDB=type(EnchantPilotDB)=='table' and EnchantPilotDB or {}
    ns.db=EnchantPilotDB
    if type(ns.db.routeReplacements)~='table' then ns.db.routeReplacements={} end
    if type(ns.db.levelingGoal)~='number' or ns.db.levelingGoal<1 or ns.db.levelingGoal>300
        or ns.db.levelingGoal~=math.floor(ns.db.levelingGoal) then ns.db.levelingGoal=300 end
    for key,value in pairs(defaults) do if ns.db[key]==nil then ns.db[key]=value end end
    -- Migrate 0.1.0 preferences: every replacement now uses real native input.
    ns.db.quickConfirm=false
    ns.quickBlocked=true
    ns.db.favorites=type(ns.db.favorites)=='table' and ns.db.favorites or {}
    ns.db.keep=type(ns.db.keep)=='table' and ns.db.keep or {}
    ns.engine=ns.Engine.New()
    for _, key in ipairs({'shoppingPlan','deHistory','shareTemplates'}) do
        if type(ns.db[key])~='table' then ns.db[key]={} end
    end
    local saved=ns.db.savedSession
    if type(saved)=='table' and ns.engine:Restore(saved.snapshot,saved.progress) then
        ns.locked=saved.snapshot
        notify('session_restored')
    end
    ns.db.savedSession=nil
    ns.items={};ns.inventoryStats={eligible=0,blocked=0}
    ns.initialized=true
    if ns.Catalog and ns.Catalog.RefreshCache then pcall(ns.Catalog.RefreshCache) end
    ns.UI.Create()
    if ns.VersionNotice then ns.VersionNotice.Start() end
    ns.Refresh()
    printMessage(ns.L.loaded)
end

function EnchantPilot_Action() ns.Act() end
function EnchantPilot_Toggle() if ns.initialized then ns.UI.Toggle() end end
function EnchantPilot_Pause() ns.Pause('user_pause') end

SLASH_ENCHANTPILOT1='/ep'
SLASH_ENCHANTPILOT2='/enchantpilot'
SlashCmdList=SlashCmdList or {}
SlashCmdList.ENCHANTPILOT=function(command)
    if not ns.initialized then ns.Initialize() end
    local cmd=(command or ''):lower():match('^%s*(%S*)')
    if cmd=='debug' then ns.Debug()
    elseif cmd=='update' and ns.VersionNotice then ns.UI.ShowDiagnostics(ns.VersionNotice.url, ns.L.version_link)
    elseif cmd=='help' then printMessage(ns.L.help)
    elseif cmd=='resetposition' then
        ns.db.position=nil
        if ns.UI.frame then ns.UI.frame:ClearAllPoints();ns.UI.frame:SetPoint('CENTER') end
        ns.UI.Show()
    else ns.UI.Toggle() end
end

for _,event in ipairs({'PLAYER_LOGIN','PLAYER_LOGOUT','PLAYER_LEVEL_UP','CHAT_MSG_ADDON','GROUP_ROSTER_UPDATE','PLAYER_GUILD_UPDATE',
    'BANKFRAME_OPENED','BANKFRAME_CLOSED','PLAYERBANKSLOTS_CHANGED','BANK_TABS_CHANGED',
    'LOOT_READY','LOOT_OPENED','TRAINER_SHOW','TRAINER_UPDATE','TRAINER_CLOSED',
    'PLAYER_REGEN_DISABLED','PLAYER_STARTED_MOVING','TRADE_SKILL_SHOW','TRADE_SKILL_CLOSE',
    'TRADE_SKILL_LIST_UPDATE','TRADE_SKILL_DATA_SOURCE_CHANGED','SKILL_LINES_CHANGED','NEW_RECIPE_LEARNED','BAG_UPDATE_DELAYED','GET_ITEM_INFO_RECEIVED',
    'EQUIPMENT_SETS_CHANGED','PLAYER_EQUIPMENT_CHANGED','REPLACE_TRADESKILL_ENCHANT','REPLACE_ENCHANT',
    'UNIT_SPELLCAST_START','UNIT_SPELLCAST_SUCCEEDED','UNIT_SPELLCAST_FAILED','UNIT_SPELLCAST_FAILED_QUIET','UNIT_SPELLCAST_INTERRUPTED',
    'ADDON_ACTION_BLOCKED','ADDON_ACTION_FORBIDDEN'}) do
    pcall(eventFrame.RegisterEvent,eventFrame,event)
end
if ns.Auction then
    ns.auctionEvents={}
    for _,event in ipairs(ns.Auction.Events) do
        ns.auctionEvents[event]=true
        eventFrame:RegisterEvent(event)
    end
end
eventFrame:SetScript('OnEvent',function(_,event,...)ns.OnEvent(event,...)end)
eventFrame:SetScript('OnUpdate',function(_,elapsed)ns.Pulse(elapsed)end)
if IsLoggedIn and IsLoggedIn() then ns.Initialize() end
