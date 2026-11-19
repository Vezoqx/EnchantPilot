local _, ns = ...
local D = {}
ns.Disenchant = D

-- Each row is item ID, min, max, rounded observed percentage.
-- https://everloot.app/tools/disenchanting
-- Other estimates are from the observed tiers in:
-- https://bootybaybroker.com/forever/crafting/disenchant?page=3
local armor = {
    {5, 15, 103, {{10940, 1, 2, 82}, {10938, 1, 2, 18}}},
    {16, 20, 53, {{10940, 2, 3, 62}, {10939, 1, 2, 28}, {10978, 1, 1, 9}}},
    {21, 25, nil, {{10940, 4, 6, 75}, {10998, 1, 2, 15}, {10978, 1, 1, 10}}},
    {26, 30, 43, {{11083, 1, 2, 67}, {11082, 1, 2, 21}, {11084, 1, 1, 12}}},
    {31, 35, nil, {{11083, 2, 5, 75}, {11134, 1, 2, 20}, {11138, 1, 1, 5}}},
    {36, 40, nil, {{11137, 1, 2, 75}, {11135, 1, 2, 20}, {11139, 1, 1, 5}}},
    {41, 45, nil, {{11137, 2, 5, 75}, {11174, 1, 2, 20}, {11177, 1, 1, 5}}},
    {46, 50, nil, {{11176, 1, 2, 75}, {11175, 1, 2, 20}, {11178, 1, 1, 5}}},
    {51, 55, nil, {{11176, 2, 5, 75}, {16202, 1, 2, 22}, {14343, 1, 1, 3}}},
    {56, 60, nil, {{16204, 1, 2, 75}, {16203, 1, 2, 22}, {14344, 1, 1, 3}}},
    {61, 99, nil, {{16204, 2, 5, 75}, {16203, 2, 3, 22}, {14344, 1, 1, 3}}},
}
local weapons = {
    {5, 15, nil, {{10938, 1, 2, 80}, {10940, 1, 2, 20}}},
    {16, 20, nil, {{10939, 1, 2, 75}, {10940, 2, 3, 20}, {10978, 1, 1, 5}}},
    {21, 25, nil, {{10939, 1, 2, 75}, {10940, 4, 6, 15}, {10978, 1, 1, 10}}},
    {26, 30, nil, {{10939, 1, 2, 75}, {11083, 1, 2, 20}, {11084, 1, 1, 5}}},
    {31, 35, nil, {{11134, 1, 2, 75}, {11083, 2, 5, 20}, {11138, 1, 1, 5}}},
    {36, 40, nil, {{11135, 1, 2, 75}, {11137, 1, 2, 20}, {11139, 1, 1, 5}}},
    {41, 45, nil, {{11174, 1, 2, 75}, {11137, 2, 5, 20}, {11177, 1, 1, 5}}},
    {46, 50, nil, {{11175, 1, 2, 75}, {11176, 1, 2, 20}, {11178, 1, 1, 5}}},
    {51, 55, nil, {{16202, 1, 2, 75}, {11176, 2, 5, 22}, {14343, 1, 1, 3}}},
    {56, 60, nil, {{16203, 1, 2, 75}, {16204, 1, 2, 22}, {14344, 1, 1, 3}}},
    {61, 99, nil, {{16203, 2, 3, 75}, {16204, 2, 5, 22}, {14344, 1, 1, 3}}},
}
local rare = {
    {21, 25, nil, {{10978, 1, 1, 100}}},
    {26, 30, nil, {{11084, 1, 1, 100}}},
    {31, 35, nil, {{11138, 1, 1, 100}}},
    {36, 40, nil, {{11139, 1, 1, 100}}},
    {41, 45, nil, {{11177, 1, 1, 100}}},
    {46, 50, nil, {{11178, 1, 1, 100}}},
    {51, 55, nil, {{14343, 1, 1, 100}}},
    {56, 99, nil, {{14344, 1, 1, 100}}},
}
local epic = {
    {40, 45, nil, {{11177, 2, 4, 100}}},
    {46, 50, nil, {{11178, 2, 4, 100}}},
    {51, 55, nil, {{14343, 2, 4, 100}}},
}
local bandsByQuality = {[3] = rare, [4] = epic}
-- Live observations at https://maxdps.com/forever/professions/enchanting
local observedCrystal = {{20725}}

function D.Outcomes(item)
    if not item or (item.classID ~= 4 and item.classID ~= 2) or type(item.itemLevel) ~= "number" then return end
    local _, build = GetBuildInfo()
    if tostring(build) ~= "70959" then return end
    local bands = item.quality == 2 and (item.classID == 4 and armor or weapons) or bandsByQuality[item.quality]
    if not bands then return end
    for _, band in ipairs(bands) do
        if item.itemLevel >= band[1] and item.itemLevel <= band[2] then return band[4], band[3] end
    end
    local level = item.itemLevel
    if item.quality == 4 and ((item.classID == 4 and level >= 62 and level <= 83)
        or (item.classID == 2 and level >= 57 and level <= 66)) then
        return observedCrystal, nil, true
    end
end
