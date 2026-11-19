local _, ns = ...
local G = {}
ns.Leveling = G

-- Wowhead Forever route. Skill endpoints, spell ID, estimated crafts, and item quantities per craft.
G.steps = {
    {1, 2, 7421, 1, {6217,1, 247786,1}},
    {2, 20, 13262, 18, {}},
    {20, 79, 14293, 59, {4470,1, 10938,1}},
    {79, 90, 7426, 11, {10938,1}},
    {90, 100, 7457, 10, {10940,2}},
    {100, 101, 7795, 1, {6338,1, 10940,3, 10938,4, 1210,1}},
    {101, 110, 14807, 9, {4470,1, 10938,2}},
    {110, 135, 13419, 25, {10998,1}, {"Дальрия", "Кульвия", "Dalria", "Kulwia"}},
    {135, 155, 13501, 20, {11083,1}},
    {155, 156, 13628, 1, {11128,1, 5500,1, 11082,1, 11083,1}},
    {156, 185, 13536, 36, {11083,1}, {"Дальрия", "Кульвия", "Dalria", "Kulwia"}},
    {185, 200, 13661, 15, {11137,1}},
    {200, 201, 13702, 1, {11144,1, 7971,1, 11135,1, 11137,1}},
    {201, 220, 13661, 26, {11137,1}},
    {220, 225, 13746, 5, {11137,1}},
    {225, 230, 13815, 5, {11137,1}},
    {230, 235, 13836, 5, {11137,2}},
    {235, 250, 13858, 16, {11137,3}},
    {250, 265, 25127, 15, {11176,1, 8831,1, 8925,1}, {"Локтос", "Локтос", "Lokhtos", "Lokhtos"}},
    {265, 294, 20017, 30, {11176,6}, {"Митрин'дир", "Даниэль Бартлетт", "Mythrin'dir", "Daniel Bartlett"}},
    {294, 295, 20051, 1, {16206,1, 13926,1, 16204,10, 16203,4, 14343,4, 14344,2},
        {"Лорелея Песнь Зимы", "Лорелея Песнь Зимы", "Lorelae Wintersong", "Lorelae Wintersong"}},
    {295, 300, 20015, 5, {16204,8},
        {"Лорелея Песнь Зимы", "Лорелея Песнь Зимы", "Lorelae Wintersong", "Lorelae Wintersong"}},
}

local trainers = {
    {{1453,43,64.2,"Лукан Корделл","Lucan Cordell"}, {1454,53.8,38.4,"Годан","Godan"}},
    {{1429,64.8,70.6,"Китта Огневетер","Kitta Firewind"}, {1442,49.2,57.2,"Хгарт","Hgarth"}},
    {{1418,41,11,"Аннора (вход в Ульдаман)","Annora (Uldaman entrance)"}},
}

-- Wowhead Forever NPC 11073, confirmed spells (not profession rank services).
G.annoraRecipes = {
    {14293,10}, {7420,15}, {7426,40}, {7454,45}, {7457,50}, {7748,60},
    {7771,70}, {14807,70}, {7779,80}, {7788,90}, {7745,100}, {7795,100},
    {13378,105}, {13421,115}, {7857,120}, {7861,125}, {7863,125}, {13485,130},
    {13501,130}, {13503,140}, {13538,140}, {13529,145}, {13607,145}, {13622,150},
    {13626,150}, {13628,150}, {13631,155}, {13635,155}, {14809,155}, {13637,160},
    {13640,160}, {13642,165}, {13644,170}, {13648,170}, {13657,175}, {14810,175},
    {13659,180}, {13661,180}, {13663,185}, {13693,195}, {13695,200}, {13700,200},
    {13702,200}, {13746,205}, {13794,205}, {13815,210}, {13822,210}, {13836,215},
    {13858,220}, {13887,225}, {13890,225}, {13905,230}, {13917,230}, {13935,235},
    {13937,240}, {13939,240}, {13941,245}, {13943,245}, {13948,250}, {17180,250},
    {17181,250},
}

function G.AnnoraStatus(required, learned, skill, maximum, level)
    if learned == true then return "learned" end
    if required > 225 and level and level < 35 then return "annora_level" end
    if maximum and maximum < required then return "annora_rank" end
    if skill and skill < required then return "annora_skill" end
    if learned == false and skill and skill >= required and (required <= 225 or level) then
        return "route_available"
    end
    return "route_unknown"
end

-- Minimum skill for the recipe and the guide's teaching NPC group.
local lessons = {
    [14293]={10,1}, [7426]={40,1}, [7457]={50,1}, [7795]={100,1}, [14807]={70,1},
    [13501]={130,1}, [13628]={150,2}, [13661]={180,2}, [13702]={200,2},
    [13746]={205,2}, [13815]={210,3}, [13836]={215,3}, [13858]={220,3},
}

function G.Lesson(id, skill, horde)
    local lesson = lessons[id]
    if not lesson then return end
    local level = UnitLevel and UnitLevel("player")
    local minimumLevel = lesson[2] == 3 and 35 or lesson[2] == 2 and 20 or lesson[1] > 75 and 10 or 1
    local minimumSkill = lesson[2] == 3 and math.max(225, lesson[1]) or lesson[1]
    local status = ns.Catalog.TrainerStatus(id)
    if status == nil then
        if skill and skill < minimumSkill or level and level < minimumLevel then status = false
        elseif skill and level then status = true end
    end
    return G.Trainer(lesson[2], horde), status, minimumSkill, minimumLevel
end

function G.Trainer(rank, horde)
    return trainers[rank][horde and 2 or 1] or trainers[rank][1]
end

function G.MarkTrainer(trainer)
    local map, x, y = trainer[1], trainer[2], trainer[3]
    if not C_Map or not C_Map.CanSetUserWaypointOnMap or not C_Map.CanSetUserWaypointOnMap(map)
        or not C_Map.SetUserWaypoint or not UiMapPoint or not UiMapPoint.CreateFromCoordinates then return false end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map,x/100,y/100))
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    if WorldMapFrame and WorldMapFrame.SetMapID then WorldMapFrame:Show(); WorldMapFrame:SetMapID(map) end
    return true
end

function G.Stage(skill)
    if skill then
        for i, step in ipairs(G.steps) do if skill < step[2] then return i end end
        return #G.steps
    end
    return 1
end

function G.Skill()
    local skill, maximum = ns.Adapter.Skill(7421)
    if skill then return skill, maximum end
    return ns.db.lastEnchantingSkill, ns.db.lastEnchantingCap
end

function G.Crafts(step, skill)
    local remaining = step[2] - math.max(step[1], skill or step[1])
    if remaining <= 0 then return step[4] end
    return math.ceil(step[4] * remaining / (step[2] - step[1]))
end

function G.GoalPlan(skill, goal)
    local entries = {}
    if type(skill) ~= "number" or skill < 1 then return entries, "goal_no_skill" end
    if type(goal) ~= "number" or goal < 1 or goal > 300 or goal ~= math.floor(goal) then
        return entries, "goal_invalid"
    end
    if skill >= goal then return entries, "goal_reached" end
    for _, step in ipairs(G.steps) do
        local span = math.min(goal, step[2]) - math.max(skill, step[1])
        if span > 0 and #step[5] > 0 then
            local materials = {}
            for i = 1, #step[5], 2 do
                local id = step[5][i]
                materials[#materials+1] = {itemID=id, per=step[5][i+1], name="#" .. id}
            end
            entries[#entries+1] = {count=math.ceil(step[4] * span / (step[2]-step[1])), materials=materials}
        end
    end
    return entries, #entries == 0 and "goal_disenchant" or nil
end
