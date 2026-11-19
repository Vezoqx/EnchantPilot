local _, ns = ...
local Catalog = {}
ns.Catalog = Catalog
local CACHE_SCHEMA = 1
local MAX_RECIPES = 10000
-- Forever spell ID -> teaching item ID and verified fallback. See docs/FEATURES_AND_SOURCES.md.
local formulaSources = {
    [7766] = {6344},
    [7776] = {6346, "sourceAshenvaleDrop"},
    [7782] = {6347},
    [7786] = {6348},
    [7793] = {6349, "sourceFollowup7793"},
    [7859] = {6375},
    [7867] = {6377, "sourceFollowup7867"},
    [13380] = {11038},
    [13419] = {11039, "sourceFollowup13419"},
    [13464] = {11081},
    [13522] = {11098},
    [13536] = {11101, "sourceFormulaVendor"},
    [13612] = {11150},
    [13617] = {11151},
    [13620] = {11152},
    [13646] = {11163, "sourceFollowup13646"},
    [13653] = {11164},
    [13655] = {11165},
    [13687] = {11167},
    [13689] = {11168},
    [13698] = {11166},
    [13817] = {11202},
    [13841] = {11203, "sourceVentureMiner"},
    [13846] = {11204},
    [13868] = {11205},
    [13882] = {11206},
    [13898] = {11207, "sourceLoregrain"},
    [13905] = {false, "sourceAnnora"},
    [13915] = {11208},
    [13917] = {false, "sourceAnnora"},
    [13931] = {11223, "sourceFollowup13931"},
    [13933] = {11224},
    [13935] = {false, "sourceAnnora"},
    [13937] = {false, "sourceAnnora"},
    [13939] = {false, "sourceTrainer"},
    [13941] = {false, "sourceAnnora"},
    [13943] = {false, "sourceAnnora"},
    [13945] = {11225},
    [13947] = {11226},
    [13948] = {false, "sourceAnnora250"},
    [15596] = {11813},
    [17180] = {false, "sourceAnnora250"},
    [17181] = {false, "sourceAnnora250"},
    [20008] = {16214, "sourceVilebranch"},
    [20009] = {16218},
    [20010] = {16246, "sourceDeadwind"},
    [20011] = {16251, "sourceFollowup20011"},
    [20012] = {16219, "sourceAzshara"},
    [20013] = {16244, "sourceFollowup20013"},
    [20014] = {16216, "sourceFollowup20014"},
    [20015] = {16224, "sourceLorelae"},
    [20016] = {16222, "sourceFollowup20016"},
    [20017] = {16217, "sourceFormulaVendor"},
    [20020] = {16215},
    [20023] = {16245},
    [20024] = {16220},
    [20025] = {16253, "sourceFormulaDrop"},
    [20026] = {16221, "sourceQia"},
    [20028] = {16242, "sourceFollowup20028"},
    [20029] = {16223},
    [20030] = {16247, "sourceFollowup20030"},
    [20031] = {16250},
    [20032] = {16254},
    [20033] = {16248},
    [20034] = {16252, "sourceScarletSpellbinder"},
    [20035] = {16255, "sourceFollowup20035"},
    [20036] = {16249, "sourceFollowup20036"},
    [20051] = {16243, "sourceLorelae"},
    [21931] = {17725},
    [22749] = {18259},
    [22750] = {18260},
    [23799] = {19444},
    [23800] = {19445},
    [23801] = {19446, "sourceFollowup23801"},
    [23802] = {19447, "sourceFollowup23802"},
    [23803] = {19448},
    [23804] = {19449, "sourceFollowup23804"},
    [25072] = {20726},
    [25073] = {20727},
    [25074] = {20728},
    [25078] = {20729},
    [25079] = {20730},
    [25080] = {20731},
    [25081] = {20732, "sourceFollowup25081"},
    [25082] = {20733, "sourceFollowup25082"},
    [25083] = {20734},
    [25084] = {20735, "sourceFollowup25084"},
    [25086] = {20736},
    [25125] = {20752, "sourceFormulaVendor"},
    [25126] = {20753, "sourceKania"},
    [25127] = {20754, "sourceKania"},
    [25128] = {20755, "sourceFormulaVendor"},
    [25129] = {20756, "sourceFollowup25129"},
    [25130] = {20757, "sourceFollowup25130"},
    [27837] = {22392, "sourceFollowup27837"},
    [435481] = {215129, "sourceFollowup435481"},
    [435903] = {215138, "sourceFollowup435903"},
    [439156] = {215141},
    [448624] = {223163},
    [463866] = {228979},
    [463869] = {228981, "sourceFollowup463869"},
    [463871] = {228982, "sourceFollowup463871"},
    [471400] = {232610, "sourceFollowup471400"},
    [1213622] = {249536, "sourceFavorHonored"},
    [1213626] = {249534, "sourceFavorHonored"},
    [1219577] = {274391},
    [1219578] = {274392},
    [1219579] = {274393, "sourceFavorHonored"},
    [1219580] = {274394, "sourceFavorHonored"},
    [1219581] = {274395},
    [1219587] = {274399, "sourceFavorHonored"},
    [1220623] = {274400},
    [1220624] = {274401, "sourceFavorHonored"},
    [1230643] = {false, "sourceLuteTrainer"},
    [1231128] = {241191},
    [1231139] = {241195},
    [1231164] = {241201},
    [1232172] = {242361},
    [1248458] = {249474, "sourceVileFin"},
    [1248459] = {249475, "sourceDarkStrand"},
    [1248460] = {249486, "sourceGorhak"},
    [1248461] = {249487, "sourceBoulderfist"},
    [1248497] = {249488, "sourceMageHunter"},
    [1248498] = {249489, "sourceGorhak"},
    [1248500] = {249514, "sourceDeadwood"},
    [1248505] = {249515, "sourceFollowup1248505"},
    [1248509] = {249512, "sourceDustbelcher"},
    [1248510] = {249511, "sourceDustwallowDrop"},
    [1248511] = {249513, "sourceFollowup1248511"},
    [1248515] = {249522},
    [1248528] = {249516, "sourceAzsharaDrop"},
    [1248599] = {249524, "sourceThuzadin"},
    [1248607] = {249525, "sourceFavorHonored"},
    [1248636] = {249526, "sourceFavorHonored"},
    [1248640] = {274398, "sourceFavorHonored"},
    [1248645] = {249535, "sourceFavorHonored"},
    [1248650] = {249537, "sourceFavor180"},
    [1248661] = {249538, "sourceFavorHonored"},
    [1248665] = {249539, "sourceFavorHonored"},
    [1248668] = {249523, "sourceFollowup1248668"},
    [1248703] = {249482, "sourceFavor45"},
    [1248739] = {249483, "sourceFavor45"},
    [1248745] = {249484, "sourceFavor45"},
    [1248748] = {249485, "sourceFavor45"},
    [1248752] = {249476, "sourceFavor45"},
    [1248754] = {249477, "sourceFavor45"},
    [1248755] = {249478, "sourceFavor45"},
    [1248757] = {249479, "sourceFavor45"},
    [1248760] = {249480, "sourceFavor45"},
    [1248805] = {249481, "sourceFavor45"},
    [1248974] = {249493, "sourceFavorFriendly"},
    [1249006] = {249494, "sourceFavorFriendly"},
    [1249015] = {249495, "sourceFavorFriendly"},
    [1249019] = {249496, "sourceFavorFriendly"},
    [1249057] = {249502, "sourceFavorFriendly"},
    [1249058] = {249503, "sourceFavorFriendly"},
    [1249059] = {249504, "sourceFavorFriendly"},
    [1249060] = {249505, "sourceFavorFriendly"},
    [1249061] = {249506, "sourceFavorFriendly"},
    [1249064] = {249507, "sourceFavorFriendly"},
    [1249069] = {249508, "sourceFavorFriendly"},
    [1249070] = {249509, "sourceFavorFriendly"},
    [1249071] = {249510, "sourceFavorFriendly"},
    [1249107] = {249519},
    [1249112] = {249520, "sourceFollowup1249112"},
    [1249114] = {249521, "sourceFollowup1249114"},
    [1249128] = {249529, "sourceFavorHonored"},
    [1249152] = {249530, "sourceFavorHonored"},
    [1249154] = {249532, "sourceFavorHonored"},
    [1263056] = {273103, "sourceArcaneSalvager"},
    [1263082] = {273116, "sourceFollowup1263082"},
    [1294054] = {274424, "sourceFollowup1294054"},
    [1306520] = {279295},
    [1306521] = {279296},
    [1306522] = {279297},
    [1306523] = {279298},
    [1306524] = {279299},
    [1306525] = {279300},
    [1328948] = {289560, "sourceFavor180"},
}

local function readable(value, wanted)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    return wanted == nil or type(value) == wanted
end

local function recipeID(value)
    return readable(value, "number") and value > 0 and value <= 2147483647 and value == math.floor(value)
end

function Catalog.Acquisition(recipe)
    if recipe.learned or not recipeID(recipe.recipeID) then return end
    local formula = formulaSources[recipe.recipeID]
    local source = recipe.sourceText
    if not readable(source, "string") or not source:find("%S") then source = nil end
    local item = formula and formula[1]
    local url = "https://www.wowhead.com/forever/" .. (item and ("item=" .. item) or ("spell=" .. recipe.recipeID))
    return source, url, not source and formula and (formula[2] or (item and "sourceFormulaKnown")) or nil
end

function Catalog.FormulaItemID(id)
    return formulaSources[id] and formulaSources[id][1] or nil
end

local function scalarIcon(value)
    return value == nil or (readable(value, "number") and value > 0 and value < math.huge and value == math.floor(value))
        or (readable(value, "string") and #value > 0 and #value <= 1024)
end

local function localeName()
    if type(GetLocale) ~= "function" then return nil end
    local ok, value = pcall(GetLocale)
    if ok and readable(value, "string") and value:match("^%l%l%u%u$") then return value end
end

local function plainRow(info)
    if not readable(info, "table") or not recipeID(info.recipeID)
        or not readable(info.name, "string") or info.name == "" or #info.name > 1024
        or not readable(info.learned, "boolean") or not readable(info.canSkillUp, "boolean")
        or not readable(info.isEnchantingRecipe, "boolean") or not readable(info.icon) or not scalarIcon(info.icon)
        or not readable(info.relativeDifficulty) or (info.relativeDifficulty ~= nil
            and (type(info.relativeDifficulty) ~= "number" or info.relativeDifficulty < 0
                or info.relativeDifficulty > 10000 or info.relativeDifficulty ~= math.floor(info.relativeDifficulty)))
        or not readable(info.sourceText) or (info.sourceText ~= nil
            and (type(info.sourceText) ~= "string" or #info.sourceText == 0 or #info.sourceText > 16384)) then
        return nil
    end
    return {
        recipeID = info.recipeID, name = info.name, icon = info.icon, learned = info.learned,
        canSkillUp = info.canSkillUp, isEnchantingRecipe = info.isEnchantingRecipe,
        relativeDifficulty = info.relativeDifficulty, sourceText = info.sourceText,
        maxTrivialLevel = readable(info.maxTrivialLevel, "number") and info.maxTrivialLevel > 0
            and info.maxTrivialLevel <= 1000 and math.floor(info.maxTrivialLevel) == info.maxTrivialLevel
            and info.maxTrivialLevel or nil,
    }
end

local function shownProfession()
    local frame = ProfessionsFrame
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and readable(shown, "boolean") and shown
end

local function folded(text)
    text = string.lower(text)
    -- Lua 5.1 lower() does not fold UTF-8 Cyrillic. Cover the Russian UI
    -- alphabet explicitly without treating query text as a Lua pattern.
    text = text:gsub("\208[\144-\175]", function(letter)
        local second = string.byte(letter, 2)
        if second < 160 then return "\208" .. string.char(second + 32) end
        return "\209" .. string.char(second - 32)
    end)
    return (text:gsub("\208\129", "\209\145"))
end

Catalog.Fold = folded

local trainable = {}
function Catalog.UpdateTrainer(closed)
    trainable = {}
    if closed or not GetNumTrainerServices or not GetTrainerServiceInfo or not C_TooltipInfo
        or not C_TooltipInfo.GetTrainerService then return end
    for i = 1, GetNumTrainerServices() do
        local _, status = GetTrainerServiceInfo(i)
        if status == "available" or status == "unavailable" then
            local data = C_TooltipInfo.GetTrainerService(i)
            if data and recipeID(data.id) then
                local _, rank
                if GetTrainerServiceSkillReq then _, rank = GetTrainerServiceSkillReq(i) end
                trainable[data.id] = {available=status=="available", rank=readable(rank, "number") and rank or nil}
            end
        end
    end
end

function Catalog.LearningRequirements(id)
    local item = Catalog.FormulaItemID(id)
    local formula = item and ns.FormulaRequirements and ns.FormulaRequirements[item]
    local trainer = trainable[id]
    return formula or (trainer and trainer.rank and {trainer.rank}), item
end

function Catalog.TrainerStatus(id)
    local service = trainable[id]
    if service then return service.available end
end

function Catalog.CanLearn(recipe)
    if recipe.learned then return false end
    if trainable[recipe.recipeID] and trainable[recipe.recipeID].available then return true end
    local req, item = Catalog.LearningRequirements(recipe.recipeID)
    if not item or not req or (ns.Adapter.ReagentCount(item) or 0) == 0
        or (ns.Adapter.Skill(recipe.recipeID) or 0) < req[1] then return false end
    if req[4] and req[4] > 0 and (not UnitLevel or UnitLevel("player") < req[4]) then return false end
    if req[5] and req[5] > 0 and (not IsPlayerSpell or not IsPlayerSpell(req[5])) then return false end
    if req[2] and req[2] > 0 then
        local faction = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(req[2])
        if not faction or not readable(faction.reaction, "number") or faction.reaction < req[3] + 1 then return false end
    end
    return true
end

local function currentProfession()
    if not shownProfession() then return nil, "profession_closed" end
    if type(C_TradeSkillUI) ~= "table"
        or type(C_TradeSkillUI.GetBaseProfessionInfo) ~= "function" then
        return nil, "catalog_unavailable"
    end
    for _, name in ipairs({"IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting"}) do
        local fn = C_TradeSkillUI[name]
        if type(fn) == "function" then
            local external = fn()
            if not readable(external, "boolean") then return nil, "catalog_unavailable" end
            if external then return nil, "foreign_profession" end
        elseif name ~= "IsNPCCrafting" then
            return nil, "catalog_unavailable"
        end
    end
    if type(C_TradeSkillUI.IsDataSourceChanging) == "function" then
        local changing = C_TradeSkillUI.IsDataSourceChanging()
        if not readable(changing, "boolean") or changing then return nil, "recipe_data_pending" end
    end
    if type(C_TradeSkillUI.IsTradeSkillReady) == "function" then
        local ready = C_TradeSkillUI.IsTradeSkillReady()
        if not readable(ready, "boolean") or not ready then return nil, "recipe_data_pending" end
    end
    local profession = C_TradeSkillUI.GetBaseProfessionInfo()
    if not readable(profession, "table") or not readable(profession.professionID, "number") then
        return nil, "catalog_unavailable"
    end
    if profession.professionID ~= 333 then return nil, "not_enchanting" end
    return true
end

function Catalog.GetRecipeShareLink(id, rememberName)
    if recipeID(id) then
        local ok, link = pcall(C_TradeSkillUI and C_TradeSkillUI.GetRecipeLink, id)
        if ok and readable(link, "string") and link ~= "" then
            if rememberName then ns.db.shareRecipe = {id=id, name=rememberName, link=link} end
            return link
        end
        local saved = ns.db.shareRecipe
        if type(saved) == "table" and saved.id == id and type(saved.link) == "string" and saved.link ~= "" then
            return saved.link
        end
    end
    return nil, "recipe_share_link_unavailable"
end

function Catalog.GetShareLink()
    local ok, available, reason = pcall(currentProfession)
    if not ok then return nil, "recipe_share_unavailable" end
    if reason == "profession_closed" then
        local cached = readable(ns.db, "table") and ns.db.enchantingShareLink
        if readable(cached, "string") and cached:find("|Htrade:", 1, true) then return cached end
        return nil, "recipe_share_first_open"
    end
    if not available then return nil, reason end
    local allowed, canLink = pcall(C_TradeSkillUI.CanTradeSkillListLink)
    if allowed and readable(canLink, "boolean") and canLink then
        local gotLink, link = pcall(C_TradeSkillUI.GetTradeSkillListLink)
        if gotLink and readable(link, "string") and link:find("|Htrade:", 1, true) then
            if readable(ns.db, "table") then ns.db.enchantingShareLink = link end
            return link
        end
    end
    return nil, "recipe_share_unavailable"
end

local function currentIDs()
    local available, reason = currentProfession()
    if not available then return nil, reason end
    if type(C_TradeSkillUI.GetAllRecipeIDs) ~= "function" or type(C_TradeSkillUI.GetRecipeInfo) ~= "function"
        or type(C_TradeSkillUI.IsRecipeInSkillLine) ~= "function" then
        return nil, "catalog_unavailable"
    end
    local ids = C_TradeSkillUI.GetAllRecipeIDs()
    if not readable(ids, "table") then return nil, "catalog_unavailable" end
    return ids
end

local function entry(id)
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    local row = plainRow(info)
    if not row or row.recipeID ~= id then return nil end
    if not row.learned and type(C_TradeSkillUI.GetRecipeSourceText) == "function" then
        local ok, source = pcall(C_TradeSkillUI.GetRecipeSourceText, id)
        if ok and readable(source, "string") and source ~= "" and #source <= 16384 then row.sourceText = source end
    end
    return row, info
end

local function currentRows()
    local ids, reason = currentIDs()
    if not ids then return nil, reason end
    local list, seen = {}, {}
    local pending, count, highest = false, 0, 0
    for index, id in pairs(ids) do
        if not recipeID(index) or index > MAX_RECIPES then
            pending = true
        else
            count, highest = count + 1, math.max(highest, index)
        end
        if not recipeID(id) then
            pending = true
        elseif not seen[id] then
            seen[id] = true
            local belongs = C_TradeSkillUI.IsRecipeInSkillLine(id, 333)
            if not readable(belongs, "boolean") then
                pending = true
            elseif belongs then
                local row = entry(id)
                if row then list[#list + 1] = row else pending = true end
            end
        end
    end
    if count ~= highest or #list == 0 then pending = true end
    return list, pending and "recipe_data_pending" or nil
end

local function cachedRows()
    if not readable(ns.db, "table") then return nil end
    local cached = ns.db.recipeCache
    if cached == nil then return nil end
    local function invalid() ns.db.recipeCache = nil; return nil end
    if not readable(cached, "table") or not readable(cached.schema, "number") or cached.schema ~= CACHE_SCHEMA
        or not readable(cached.professionID, "number") or cached.professionID ~= 333
        or not readable(cached.locale, "string") or cached.locale ~= localeName()
        or not readable(cached.recipes, "table") then return invalid() end
    local rows, seen, count, highest = {}, {}, 0, 0
    for index, value in pairs(cached.recipes) do
        if not recipeID(index) or index > MAX_RECIPES then return invalid() end
        local row = plainRow(value)
        if not row or seen[row.recipeID] then return invalid() end
        seen[row.recipeID] = true
        rows[index], count, highest = row, count + 1, math.max(highest, index)
    end
    if count == 0 or count ~= highest then return invalid() end
    -- Rewrite only plain scalar fields, stripping any unrelated saved contents.
    ns.db.recipeCache = {schema = CACHE_SCHEMA, professionID = 333, locale = cached.locale, recipes = rows}
    return rows
end

function Catalog.IsLearned(id)
    if currentProfession() and C_TradeSkillUI.GetRecipeInfo then
        local info = C_TradeSkillUI.GetRecipeInfo(id)
        if readable(info, "table") and readable(info.learned, "boolean") then return info.learned end
    end
    for _, recipe in ipairs(cachedRows() or {}) do
        if recipe.recipeID == id then return recipe.learned end
    end
end

function Catalog.CanSkillUp(id, skill)
    if currentProfession() and C_TradeSkillUI.GetRecipeInfo then
        local info = C_TradeSkillUI.GetRecipeInfo(id)
        if readable(info, "table") and readable(info.learned, "boolean") and info.learned
            and readable(info.canSkillUp, "boolean") then return info.canSkillUp end
    end
    if skill ~= ns.db.lastEnchantingSkill then return end
    for _, recipe in ipairs(cachedRows() or {}) do
        if recipe.recipeID == id and recipe.learned then return recipe.canSkillUp end
    end
end

function Catalog.RefreshCache()
    local ok, rows, reason = pcall(currentRows)
    if not ok then return false, "catalog_unavailable" end
    if not rows or reason then return false, reason, rows end
    Catalog.GetShareLink()
    local locale = localeName()
    local previousByID = {}
    for _, previous in ipairs(cachedRows() or {}) do previousByID[previous.recipeID] = previous end
    for _, row in ipairs(rows) do
        local previous = previousByID[row.recipeID]
        if row.learned then
            row.sourceText = nil
        elseif not row.sourceText and previous and not previous.learned then
            -- Source tooltips may load later than the otherwise complete recipe
            -- data. Keep known text only from this locale's unlearned record.
            row.sourceText = previous.sourceText
        end
    end
    if readable(ns.db, "table") and locale then
        ns.db.recipeCache = {schema = CACHE_SCHEMA, professionID = 333, locale = locale, recipes = rows}
        if ns.Adapter and ns.Adapter.Skill then
            local skill, maximum = ns.Adapter.Skill(7421)
            if skill then ns.db.lastEnchantingSkill, ns.db.lastEnchantingCap = skill, maximum end
        end
        if ns.Adapter and ns.Adapter.CachePriceRecipes then ns.Adapter.CachePriceRecipes(rows) end
    end
    return true, nil, rows
end

local function buildList(query, mode, favorites)
    local refreshed, reason, rows = Catalog.RefreshCache()
    if not refreshed then
        local cached = cachedRows()
        if cached then rows, reason = cached, "catalog_cached" end
    end
    if not rows then return {}, reason end
    if not readable(query, "string") then query = "" end
    if not readable(favorites, "table") then favorites = {} end
    if not readable(mode, "string") then mode = "all" end
    query = folded(query:match("^%s*(.-)%s*$"))
    if mode ~= "learned" and mode ~= "unlearned" and mode ~= "favorites" and mode ~= "learnable" then mode = "all" end
    local list = {}
    for _, saved in ipairs(rows) do
        local row = plainRow(saved)
        local favorite = row and favorites[row.recipeID]
        if row and readable(favorite) then
            row.favorite = favorite == true
            local matchesMode = mode == "all" or (mode == "learned" and row.learned)
                or (mode == "unlearned" and not row.learned) or (mode == "favorites" and row.favorite)
                or (mode == "learnable" and Catalog.CanLearn(row))
            if matchesMode and (query == "" or folded(row.name):find(query, 1, true)) then list[#list + 1] = row end
        end
    end
    table.sort(list, function(a, b)
        local aName, bName = folded(a.name), folded(b.name)
        if aName == bName then return a.recipeID < b.recipeID end
        return aName < bName
    end)
    return list, reason
end

function Catalog.List(query, mode, favorites)
    local ok, list, reason = pcall(buildList, query, mode, favorites)
    if not ok then return {}, "catalog_unavailable" end
    return list, reason
end

-- The caller invokes this only from a user click. This uses the native
-- CraftingPage selection method; it never creates a cast or changes filters.
function Catalog.Select(id)
    if not recipeID(id) then return false, "recipe_unavailable" end
    if type(InCombatLockdown) ~= "function" then return false, "catalog_unavailable" end
    local combatOK, combat = pcall(InCombatLockdown)
    if not combatOK or not readable(combat, "boolean") or combat then return false, "combat" end
    local frame = ProfessionsFrame
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false, "profession_closed" end
    local shownOK, shown = pcall(frame.IsShown, frame)
    if not shownOK or not readable(shown, "boolean") or not shown then return false, "profession_closed" end
    local page = frame.CraftingPage
    if type(page) ~= "table" or type(page.SelectRecipe) ~= "function" then return false, "catalog_unavailable" end
    local idsOK, ids, reason = pcall(currentIDs)
    if not idsOK or not ids then return false, idsOK and reason or "catalog_unavailable" end
    local found = false
    for _, current in ipairs(ids) do
        if recipeID(current) and current == id then found = true; break end
    end
    if not found then return false, "recipe_unavailable" end
    local membershipOK, belongs = pcall(C_TradeSkillUI.IsRecipeInSkillLine, id, 333)
    if not membershipOK or not readable(belongs, "boolean") or not belongs then return false, "recipe_unavailable" end
    local infoOK, row, info = pcall(entry, id)
    if not infoOK or not row then return false, "recipe_data_pending" end
    local selected = pcall(page.SelectRecipe, page, info)
    if not selected then return false, "recipe_select_failed" end
    return true
end
