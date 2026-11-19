local _, ns = ...
local PREFIX = "EnchantPilotVer"
local URL = "https://github.com/Vezoqx/EnchantPilot/releases"
local channels = {PARTY=true, RAID=true, GUILD=true, INSTANCE_CHAT=true}
local sent, queued = {}, {}
local started, notified
local V = {url=URL}
ns.VersionNotice = V

local function parse(value)
    if type(value) ~= "string" or #value > 24 then return end
    local a, b, c, suffix = value:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return end
    local beta = suffix:match("^%-beta%.(%d+)$")
    if suffix == "-beta" then beta = "0"
    elseif suffix ~= "" and not beta then return end
    return {tonumber(a), tonumber(b), tonumber(c), suffix == "" and 1 or 0, tonumber(beta) or 0}
end

local current = parse(ns.VERSION)
local function compare(a, b)
    for i = 1, #a do
        if a[i] ~= b[i] then return a[i] > b[i] and 1 or -1 end
    end
    return 0
end

local function joined(channel)
    if channel == "GUILD" then return IsInGuild() end
    if channel == "INSTANCE_CHAT" then return LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) end
    return IsInGroup(LE_PARTY_CATEGORY_HOME)
        and channel == (IsInRaid(LE_PARTY_CATEGORY_HOME) and "RAID" or "PARTY")
end

local function queue(channel, hello)
    if not joined(channel) then return end
    if queued[channel] ~= nil then
        queued[channel] = queued[channel] or hello
        return
    end
    queued[channel] = hello
    C_Timer.After(sent[channel] and math.max(1, sent[channel] + 30 - GetTime()) or 1, function()
        local request = queued[channel]
        queued[channel] = nil
        if not joined(channel) then return end
        sent[channel] = GetTime()
        C_ChatInfo.SendAddonMessage(PREFIX, (request and "Q:" or "V:") .. ns.VERSION, channel)
    end)
end

function V.OnEvent(event, prefix, payload, channel)
    if not started then return end
    if event == "CHAT_MSG_ADDON" then
        if issecretvalue and (issecretvalue(prefix) or issecretvalue(payload) or issecretvalue(channel)) then return end
        if prefix ~= PREFIX or not channels[channel] or not joined(channel)
            or type(payload) ~= "string" or #payload > 26 then return end
        local kind, version = payload:match("^([QV]):(.+)$")
        local remote = parse(version)
        if not remote then return end
        local order = compare(remote, current)
        if order > 0 and not notified and DEFAULT_CHAT_FRAME then
            notified = true
            DEFAULT_CHAT_FRAME:AddMessage(string.format(ns.L.version_notice, ns.VERSION, version, URL))
        elseif order < 0 and kind == "Q" then
            queue(channel, false)
        end
    elseif event == "PLAYER_GUILD_UPDATE" then
        queue("GUILD", true)
    else
        queue("PARTY", true)
        queue("RAID", true)
        queue("INSTANCE_CHAT", true)
    end
end

function V.Start()
    if started or not current or not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
        and C_ChatInfo.SendAddonMessage and C_Timer and C_Timer.After) then return end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    started = true
    V.OnEvent("PLAYER_GUILD_UPDATE")
    V.OnEvent("GROUP_ROSTER_UPDATE")
end
