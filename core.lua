-- GuildFeed - core
-- A social feed for your guild. Proof of concept.
-- File tour: core.lua (init + event dispatch), data.lua (posts, likes,
-- follows, serialization), comms.lua (guild addon-channel sync),
-- events.lua (auto-posts from game events), ui.lua (the feed window).

GuildFeed = GuildFeed or {}
local GF = GuildFeed

GF.ADDON_NAME = "GuildFeed"
GF.VERSION = "0.5.0"
GF.PREFIX = "GuildFeed1" -- addon-message prefix, max 16 chars
-- Note: Classic (1.13.3+) deliberately blocks SendAddonMessage over custom
-- channels, so all sync is guild-scoped. There is no global feed.

GF.MAX_POSTS = 60      -- max posts kept in the feed
GF.HISTORY_COUNT = 12  -- how many of your posts get rebroadcast on login
GF.ONLINE_TIMEOUT = 300 -- seconds before someone drops off the "online" list
GF.PRUNE_DAYS = 7      -- drop posts older than this
GF.MAX_TEXT = 160      -- addon messages cap at 255 bytes; keep posts well under

GF.posts = {}      -- newest first
GF.seen = {}       -- postId -> true (dedupe)
GF.online = {}     -- name -> last seen timestamp
GF.profiles = {}   -- name -> { class, level, rank }
GF.portfolios = {} -- name -> { professions = { {name, skill, max} }, achPoints }
GF.following = {}  -- name -> true
GF.unfollowed = {} -- name -> true (explicit unfollows; auto-follow skips these)
GF.recentAllies = {} -- name -> timestamp of last group together (tracked locally)
GF.ALLY_WINDOW_DAYS = 14 -- "recent" ally window for auto-follow
GF.postCounter = 0

-- User settings (persisted in SavedVariables; editable in the Interface > AddOns panel).
GF.DEFAULT_SETTINGS = {
    postLevel = true,  -- auto-post level-ups
    postLoot = true,   -- auto-post loot at the quality threshold
    testGreens = false, -- test mode: loot threshold drops to greens
    followFriends = true, -- automatically follow in-game friends
    followAllies = true,  -- automatically follow recent group allies
}

function GF:GetSetting(key)
    local s = self.db and self.db.settings or {}
    if s[key] == nil then
        return self.DEFAULT_SETTINGS[key]
    end
    return s[key]
end

-- Side effects of turning a setting on, run from every entry point
-- (options panel, slash commands). The sync functions re-check the setting.
local SETTING_HOOKS = {
    followFriends = "SyncFriendsToFollowing",
    followAllies = "SyncAlliesToFollowing",
}

function GF:SetSetting(key, val)
    self.db = self.db or {}
    self.db.settings = self.db.settings or {}
    self.db.settings[key] = val
    self:Save()
    if SETTING_HOOKS[key] then
        self[SETTING_HOOKS[key]](self)
    end
    if self.SyncOptionsPanel then
        self:SyncOptionsPanel()
    end
end

function GF:SettingsSummary()
    local function onoff(key)
        return self:GetSetting(key) and "on" or "off"
    end
    return "level-ups " .. onoff("postLevel") .. ", epic loot " .. onoff("postLoot")
        .. ", greens test mode " .. onoff("testGreens") .. ", follow friends " .. onoff("followFriends")
        .. ", follow allies " .. onoff("followAllies")
end

-- Loot auto-post quality threshold: 4 = epic+, 2 = green+ (test mode).
function GF:LootThreshold()
    return self:GetSetting("testGreens") and 2 or 4
end

-- Consistent clock across clients (server time when available).
function GF:Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

function GF:Print(msg)
    print("|cff7fd4ffGuildFeed:|r " .. msg)
end

-- Run fn after delay seconds, or right away if C_Timer is missing.
function GF:After(delay, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
    else
        fn()
    end
end

function GF:CountKeys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- Persist, then redraw the feed once on the next frame. Bursts of changes
-- (e.g. a dozen HISTORY messages on login) coalesce into a single redraw.
function GF:Changed()
    self:Save()
    if self.refreshPending or not (self.mainFrame and self.mainFrame:IsShown()) then
        return
    end
    self.refreshPending = true
    self:After(0, function()
        GF.refreshPending = false
        GF:RefreshFeed()
    end)
end

-- Event dispatcher: calls GF:On<EVENT>(...) when a handler exists.
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = GF["On" .. event]
    if handler then
        handler(GF, ...)
    end
end)

function GF:RegisterEvents()
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
    eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
end

function GF:OnADDON_LOADED(name)
    if name ~= self.ADDON_NAME then
        return
    end
    GuildFeedDB = GuildFeedDB or {}
    GuildFeedDB.posts = GuildFeedDB.posts or {}
    GuildFeedDB.following = GuildFeedDB.following or {}
    GuildFeedDB.portfolios = GuildFeedDB.portfolios or {}
    GuildFeedDB.unfollowed = GuildFeedDB.unfollowed or {}
    GuildFeedDB.recentAllies = GuildFeedDB.recentAllies or {}
    self.db = GuildFeedDB
    self.following = GuildFeedDB.following
    self.portfolios = GuildFeedDB.portfolios
    self.unfollowed = GuildFeedDB.unfollowed
    self.recentAllies = GuildFeedDB.recentAllies
    for _, post in ipairs(self.db.posts) do
        self:RestorePost(post)
    end
    -- renumber restored posts so new ones sort after them (list is newest first)
    self:SortPosts()
    self.seqCounter = #self.posts
    for i, post in ipairs(self.posts) do
        post.seq = self.seqCounter - i + 1
    end
    self:PrunePosts()
end

function GF:OnPLAYER_LOGIN()
    local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if RegisterPrefix then
        RegisterPrefix(self.PREFIX)
    end
    self.playerName = UnitName("player")
    self.playerClass = select(2, UnitClass("player"))

    -- Startup self-check: report missing APIs instead of failing silently.
    -- (Forever's API differs from classic in places; this surfaces it.)
    do
        local checks = {
            { "SendAddonMessage", GF.SendMsg },
            { "SetPortraitTexture", SetPortraitTexture },
            { "GuildRoster", GuildRoster },
            { "GetGuildRosterInfo", GetGuildRosterInfo },
        }
        local missing = {}
        for _, c in ipairs(checks) do
            if not c[2] then
                table.insert(missing, c[1])
            end
        end
        if #missing > 0 then
            self:Print("note, unavailable on this client: "
                .. table.concat(missing, ", ") .. ". Related features are disabled gracefully.")
        end
    end

    if IsInGuild() and GuildRoster then
        GuildRoster()
    end
    self:MarkOnline(self.playerName)
    self:BroadcastHello()
    self:ScheduleSyncRequest()
    self:SyncFriendsToFollowing()
    self:RecordGroupAllies()
    self:SyncAlliesToFollowing()
    -- Register the standalone settings screen (Interface > AddOns > GuildFeed).
    -- Guarded inside BuildOptionsPanel; safe to call even if the API is absent.
    self:BuildOptionsPanel()
    print("|cff7fd4ffGuildFeed|r v" .. self.VERSION .. " loaded. Type |cffffffff/feed|r to open your feed.")
end

GF:RegisterEvents()
