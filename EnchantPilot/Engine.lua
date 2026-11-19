-- Pure session bookkeeping. This module neither reads game globals nor performs
-- game actions. Only an explicit input handler may call Request and then cast.
local _, ns = ...
local Engine = {}
Engine.__index = Engine
ns.Engine = Engine

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finiteNumber(value) and value >= minimum
        and (not maximum or value <= maximum) and value == math.floor(value)
end

local function nonempty(value)
    return type(value) == "string" and value ~= ""
end

local function duration(value)
    if finiteNumber(value) and value >= 0 then return value end
    return 0 -- Missing timing information still gets a finite 15-second watchdog.
end

local function reasonOr(value, fallback)
    if nonempty(value) then return value end
    return fallback
end

-- The adapter must supply ordinary readable values. Secret/protected game
-- values must be screened in the adapter before reaching this pure module.
local function validateSnapshot(snapshot, skillGoal, stopOnGray)
    if type(snapshot) ~= "table" then return false, "invalid_snapshot" end
    if not integer(snapshot.recipeID, 1) then return false, "unknown_recipe" end
    if not nonempty(snapshot.targetGUID) then return false, "unknown_target" end
    if not nonempty(snapshot.allocationKey) then return false, "unknown_allocation" end
    if not integer(snapshot.available, 0) then return false, "unknown_materials" end
    if skillGoal and not integer(snapshot.skillRank, 0) then
        return false, "unknown_skill"
    end
    if stopOnGray and type(snapshot.canSkillUp) ~= "boolean" then
        return false, "unknown_skill_up"
    end
    return true
end

local function checkRequest(session, snapshot)
    local valid, reason = validateSnapshot(snapshot, session.skillGoal, session.stopOnGray)
    if not valid then return false, reason end
    if snapshot.recipeID ~= session.recipeID then return false, "recipe_changed" end
    if snapshot.targetGUID ~= session.targetGUID then return false, "target_changed" end
    if snapshot.allocationKey ~= session.allocationKey then return false, "allocation_changed" end
    if session.completed >= session.goal then return false, "complete" end
    if session.skillGoal and snapshot.skillRank >= session.skillGoal then
        return false, "skill_goal"
    end
    if session.stopOnGray and not snapshot.canSkillUp then return false, "gray" end
    if snapshot.available == 0 then return false, "no_materials" end
    if snapshot.available <= session.reserve then return false, "reserve" end
    return true
end

local function clearActive(self, castGUID)
    local active = self._active
    local retiredGUID = castGUID or (active and active.castGUID)
    -- Keep this set across sessions. A late duplicate must not satisfy a new
    -- intent, including after the user resets or re-arms the session.
    if retiredGUID then self._seenGUIDs[retiredGUID] = true end
    self._active = nil
    if self.session then
        self.session.intentAt = nil
        self.session.castGUID = nil
        self.session.castAt = nil
    end
end

local function validTime(now, active)
    return finiteNumber(now) and now >= 0
        and (not active or now >= active.intentAt)
end

local function matchingEvent(self, spellID, castGUID, now)
    if not self.session then return false, "not_armed" end
    if spellID ~= self.session.recipeID then return false, "unrelated_spell" end
    if not nonempty(castGUID) then return false, "invalid_cast" end
    if self._seenGUIDs[castGUID] then return false, "duplicate" end
    local active = self._active
    if not active then return false, "unsolicited" end
    if not validTime(now, active) then return false, "invalid_time" end
    if active.castGUID and active.castGUID ~= castGUID then return false, "cast_mismatch" end
    return true
end

function Engine.New()
    return setmetatable({state = "idle", reason = "idle", _seenGUIDs = {}}, Engine)
end

function Engine:Arm(snapshot, requested, options)
    if self._active then return false, "busy" end
    if not integer(requested, 1, 500) then return false, "invalid_count" end
    if options ~= nil and type(options) ~= "table" then return false, "invalid_options" end
    options = options or {}
    local reserve = options.reserve
    if reserve == nil then reserve = 0 end
    if not integer(reserve, 0, 500) then return false, "invalid_reserve" end
    local skillGoal = options.skillGoal
    if skillGoal == 0 then skillGoal = nil end
    if skillGoal ~= nil and not integer(skillGoal, 1) then return false, "invalid_skill_goal" end
    if options.stopOnGray ~= nil and type(options.stopOnGray) ~= "boolean" then
        return false, "invalid_options"
    end
    local stopOnGray = options.stopOnGray == true
    local valid, reason = validateSnapshot(snapshot, skillGoal, stopOnGray)
    if not valid then return false, reason end
    local skillRank
    if integer(snapshot.skillRank, 0) then skillRank = snapshot.skillRank end
    self.session = {
        completed = 0, goal = requested, reserve = reserve,
        skillGoal = skillGoal, stopOnGray = stopOnGray,
        recipeID = snapshot.recipeID, targetGUID = snapshot.targetGUID,
        allocationKey = snapshot.allocationKey,
        startSkill = skillRank, currentSkill = skillRank,
        castSeconds = duration(snapshot.castSeconds), available = snapshot.available,
        name = snapshot.name, targetLink = snapshot.targetLink,
    }
    self.state, self.reason = "ready", "ready"
    return true
end

function Engine:Request(snapshot, now)
    local session = self.session
    if not session then return false, "not_armed" end
    if self._active then return false, "busy" end
    if self.state == "complete" then return false, "complete" end
    if self.state ~= "ready" and self.state ~= "paused" then return false, "busy" end
    if not validTime(now) then
        self.state, self.reason = "paused", "invalid_time"
        return false, "invalid_time"
    end
    local valid, reason = checkRequest(session, snapshot)
    if not valid then
        if reason == "skill_goal" then session.currentSkill = snapshot.skillRank end
        if reason == "complete" or reason == "skill_goal" or reason == "gray" then
            self.state = "complete"
        else
            self.state = "paused"
        end
        self.reason = reason
        return false, reason
    end
    session.available = snapshot.available
    session.castSeconds = duration(snapshot.castSeconds)
    session.currentSkill = nil
    if integer(snapshot.skillRank, 0) then session.currentSkill = snapshot.skillRank end
    session.intentAt = now
    self._active = {
        phase = "requesting", intentAt = now,
        castSeconds = session.castSeconds, deadline = now + 15,
    }
    self.state, self.reason = "requesting", "requesting"
    return true
end

function Engine:Restore(snapshot, progress)
    if type(progress) ~= 'table' or not integer(progress.completed, 0)
        or not integer(progress.goal, 1, 500) or progress.completed >= progress.goal then return false end
    if not self:Arm(snapshot, progress.goal, progress) then return false end
    self.session.completed = progress.completed
    if integer(progress.workshopSerial, 1) then self.session.workshopSerial = progress.workshopSerial end
    if integer(progress.startSkill, 0) then self.session.startSkill = progress.startSkill end
    self:Pause('session_restored')
    return true
end

function Engine:ConfirmPending()
    if not self.session then return false, "not_armed" end
    local active = self._active
    if not active then return false, "unsolicited" end
    if active.phase == "casting" then return false, "busy" end
    active.phase = "confirming"
    -- This API deliberately has no clock argument. The generous confirmation
    -- window begins at the originating input, never at a repeated popup poll.
    active.deadline = active.intentAt + 120
    if self.state ~= "paused" then self.state, self.reason = "confirming", "confirming" end
    return true
end

function Engine:CastStart(spellID, castGUID, now)
    local valid, reason = matchingEvent(self, spellID, castGUID, now)
    if not valid then return false, reason end
    local active = self._active
    if active.castGUID then return false, "duplicate" end
    active.phase, active.castGUID, active.castAt = "casting", castGUID, now
    active.deadline = now + active.castSeconds + 15
    self.session.castGUID, self.session.castAt = castGUID, now
    if self.state ~= "paused" then self.state, self.reason = "casting", "casting" end
    return true
end

function Engine:Success(spellID, castGUID, now, skillRank)
    local valid, reason = matchingEvent(self, spellID, castGUID, now)
    if not valid then return false, reason end
    local session = self.session
    local wasPaused, pauseReason = self.state == "paused", self.reason
    clearActive(self, castGUID)
    session.completed = session.completed + 1
    session.currentSkill = nil
    if integer(skillRank, 0) then session.currentSkill = skillRank end
    if session.completed >= session.goal then
        self.state, self.reason = "complete", "complete"
    elseif session.skillGoal and session.currentSkill == nil then
        -- A confirmed success counts even if the subsequent skill query fails.
        self.state, self.reason = "paused", "unknown_skill"
    elseif session.skillGoal and session.currentSkill >= session.skillGoal then
        self.state, self.reason = "complete", "skill_goal"
    elseif wasPaused then
        self.state, self.reason = "paused", pauseReason
    else
        self.state, self.reason = "ready", "ready"
    end
    return true
end

-- Spell failure events carry identity just like successes. Retire their GUID
-- even before START, so a delayed second failure cannot clear a later intent.
function Engine:FailCast(spellID, castGUID, now, reason)
    local valid, rejection = matchingEvent(self, spellID, castGUID, now)
    if not valid then return false, rejection end
    clearActive(self, castGUID)
    self.state, self.reason = "paused", reasonOr(reason, "cast_failed")
    return true
end

-- Internal failures have no event identity; callers handling spell events use
-- FailCast instead so stale events cannot cancel unrelated active work.
function Engine:Fail(reason)
    if not self.session then return false, "not_armed" end
    if not self._active then return false, "unsolicited" end
    clearActive(self)
    self.state, self.reason = "paused", reasonOr(reason, "cast_failed")
    return true
end

function Engine:Pause(reason)
    if not self.session then return false, "not_armed" end
    if self.state == "complete" then return false, "complete" end
    -- Do not clear an active intent: a cast that finishes while paused is still
    -- a completed enchant, and an unresolved cast must prevent reentrant input.
    self.state, self.reason = "paused", reasonOr(reason, "paused")
    return true
end

function Engine:Reset()
    if self._active then return false, "busy" end
    self.session = nil
    self.state, self.reason = "idle", "idle"
    return true
end

function Engine:Tick(now)
    if not validTime(now, self._active) then return false, "invalid_time" end
    local active = self._active
    if not active then return false, "inactive" end
    if now < active.deadline then return false, "pending" end
    local reason = "request_timeout"
    if active.phase == "confirming" then reason = "confirmation_timeout" end
    if active.phase == "casting" then reason = "cast_timeout" end
    clearActive(self)
    self.state, self.reason = "paused", reason
    return true, reason
end

function Engine:GetView(snapshot)
    local session = self.session
    local view = {
        state = self.state, reason = self.reason,
        completed = 0, goal = 0, remaining = 0, reserve = 0,
        inFlight = self._active ~= nil, canRequest = false,
        phase = self._active and self._active.phase or nil,
        deadline = self._active and self._active.deadline or nil,
    }
    if not session then
        view.validationReason = "not_armed"
        return view
    end
    view.completed, view.goal = session.completed, session.goal
    view.remaining = math.max(0, session.goal - session.completed)
    view.reserve, view.skillGoal, view.stopOnGray = session.reserve, session.skillGoal, session.stopOnGray
    view.recipeID, view.targetGUID, view.allocationKey = session.recipeID, session.targetGUID, session.allocationKey
    view.name, view.targetLink = session.name, session.targetLink
    view.startSkill, view.skillRank = session.startSkill, session.currentSkill
    if session.startSkill ~= nil and session.currentSkill ~= nil then
        view.skillDelta = session.currentSkill - session.startSkill
    end
    view.castSeconds = session.castSeconds
    if session.castSeconds > 0 then view.estimatedSeconds = view.remaining * session.castSeconds end
    view.intentAt, view.castGUID, view.castAt = session.intentAt, session.castGUID, session.castAt
    if snapshot == nil then
        view.available = session.available
    elseif type(snapshot) == "table" and integer(snapshot.available, 0) then
        view.available = snapshot.available
    end
    if view.available ~= nil then view.usable = math.max(0, view.available - session.reserve) end
    if self._active then
        view.validationReason = "busy"
    elseif self.state == "complete" then
        view.validationReason = "complete"
    elseif self.state == "ready" or self.state == "paused" then
        view.canRequest, view.validationReason = checkRequest(session, snapshot)
    else
        view.validationReason = "busy"
    end
    return view
end
