-- GuildFeed - events
-- Auto-generated posts from game events. This is the file to extend when
-- you think of new "postable" moments (dungeon clears, first boss kills...).

local GF = GuildFeed

function GF:OnPLAYER_LEVEL_UP(level)
    if self:GetSetting("postLevel") then
        self:NewPost("level", "dinged level " .. tostring(level) .. "!")
    end
end

-- Item quality by link color. Auto-post threshold is GF:LootThreshold()
-- (default 4 = epic; 2 = green when test mode is on in the options panel).
local QUALITY_BY_COLOR = {
    ["ff9d9d9d"] = 0, -- poor
    ["ffffffff"] = 1, -- common
    ["ff1eff00"] = 2, -- uncommon (green)
    ["ff0070dd"] = 3, -- rare
    ["ffa335ee"] = 4, -- epic
    ["ffff8000"] = 5, -- legendary
    ["ffe6cc80"] = 6, -- artifact
    ["ff00ccff"] = 7, -- heirloom
}

function GF:OnCHAT_MSG_LOOT(message)
    -- Only our own loot ("You receive loot: ..."), not the whole group's.
    if not message:find("You receive loot:") then
        return
    end
    if not self:GetSetting("postLoot") then
        return
    end
    local color = message:match("|c(%x+)|Hitem")
    local quality = color and QUALITY_BY_COLOR[color:lower()]
    if not quality or quality < self:LootThreshold() then
        return
    end
    local link = message:match("(|c%x+|Hitem.-|h%[.-%]|h|r)")
    if link then
        self:NewPost("loot", "looted " .. link)
    end
end

-- Keep the profile cache fresh from the guild roster (for ranks especially).
-- Guarded: Forever 1.60.1 does not provide GuildRoster(), so these may be absent.
function GF:OnGUILD_ROSTER_UPDATE()
    if not IsInGuild() or not GetNumGuildMembers or not GetGuildRosterInfo then
        return
    end
    for i = 1, GetNumGuildMembers() do
        local name, rank, _, level, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
        self:CacheProfile(name, classFile, level, rank)
    end
end
