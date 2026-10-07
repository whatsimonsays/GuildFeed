-- GuildFeed - data
-- Posts, likes, follows, and the (tiny) serialization format used on the wire.
-- A post is: { id, author, class, level, kind, text, time, likes = { [name] = true } }
-- kinds: "post" (manual), "level" (ding), "loot" (epic+ drop)

local GF = GuildFeed

-- We delimit fields with "|", so escape any literal "|" in user text.
-- \031 (unit separator) effectively never appears in chat text.
local SEP = "\031"

local function esc(s)
    return (tostring(s):gsub("|", SEP))
end

local function unesc(s)
    return (s:gsub(SEP, "|"))
end

function GF.Split(str)
    local parts = {}
    for part in (str .. "|"):gmatch("(.-)|") do
        table.insert(parts, part)
    end
    return parts
end

-- Serialize a post's like state for HISTORY messages: most recent first,
-- capped to respect addon message size limits. Partial merges are safe
-- (per-liker last-writer-wins), just incomplete.
local LIKE_CAP = 15
local function serializeLikes(post)
    local entries = {}
    for liker, e in pairs(post.likeState or {}) do
        table.insert(entries, { liker = liker, s = e.s, ts = e.ts })
    end
    table.sort(entries, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    local parts = {}
    for i = 1, math.min(#entries, LIKE_CAP) do
        local e = entries[i]
        table.insert(parts, esc(e.liker) .. ":" .. (e.ts or 0) .. ":" .. (e.s or 0))
    end
    return table.concat(parts, ",")
end

function GF:SerializePost(post)
    return table.concat({
        esc(post.id),
        esc(post.author),
        esc(post.class or ""),
        tostring(post.level or 0),
        esc(post.kind or "post"),
        esc(post.text or ""),
        tostring(post.time or 0),
        serializeLikes(post),
    }, "|")
end

function GF:DeserializePost(str)
    local p = GF.Split(str)
    if #p < 7 then
        return nil
    end
    local post = {
        id = unesc(p[1]),
        author = unesc(p[2]),
        class = unesc(p[3]),
        level = tonumber(p[4]) or 0,
        kind = unesc(p[5]),
        text = unesc(p[6]),
        time = tonumber(p[7]) or 0,
        likeState = {},
    }
    if p[8] and p[8] ~= "" then
        for entry in p[8]:gmatch("[^,]+") do
            local nm, ts, s = entry:match("^(.-):(%d+):(%d+)$")
            if nm then
                post.likeState[unesc(nm)] = { s = tonumber(s), ts = tonumber(ts) }
            end
        end
    end
    return post
end

-- Create a post from this client: store it locally AND broadcast it.
function GF:NewPost(kind, text)
    text = strtrim(tostring(text or ""))
    if text == "" then
        return nil
    end
    text = text:sub(1, self.MAX_TEXT)
    self.postCounter = (self.postCounter or 0) + 1
    local now = self:Now()
    local post = {
        id = self.playerName .. "-" .. now .. "-" .. self.postCounter,
        author = self.playerName,
        class = self.playerClass,
        level = UnitLevel("player"),
        kind = kind,
        text = text,
        time = now,
        likeState = {},
    }
    self:AddPost(post)
    self:BroadcastPost(post)
    return post
end

-- Store a post locally (from anywhere). Never broadcasts; callers decide that.
function GF:AddPost(post)
    if not post or not post.id or self.seen[post.id] then
        return false
    end
    self.seen[post.id] = post
    -- sequence number: deterministic newest-first order when two posts
    -- share a timestamp (table.sort is not stable)
    self.seqCounter = (self.seqCounter or 0) + 1
    post.seq = self.seqCounter
    post.likeState = post.likeState or {}
    table.insert(self.posts, post)
    self:CacheProfile(post.author, post.class, post.level)
    -- sort before pruning: PrunePosts keeps the first MAX_POSTS in list order
    self:SortPosts()
    self:PrunePosts()
    self:Changed()
    return true
end

-- Ingest a post from the wire: a new post is stored as-is; a known one
-- gets its like state merged (HISTORY catch-up, last-writer-wins per liker).
function GF:IngestPost(post)
    if not self:AddPost(post) then
        self:MergeLikes(self:FindPost(post.id), post.likeState)
    end
end

function GF:ClearPosts()
    self.posts = {}
    self.seen = {}
    self:Changed()
end

-- Restore a post from SavedVariables.
function GF:RestorePost(saved)
    if not saved or not saved.id or self.seen[saved.id] then
        return
    end
    local post = saved
    post.likeState = post.likeState or {}
    -- migrate pre-0.4.0 format: likes = { [name] = true }
    if post.likes then
        for liker in pairs(post.likes) do
            post.likeState[liker] = { s = 1, ts = post.time or 0 }
        end
        post.likes = nil
    end
    self.seen[post.id] = post
    table.insert(self.posts, post)
    self:CacheProfile(post.author, post.class, post.level)
end

function GF:SortPosts()
    table.sort(self.posts, function(a, b)
        if (a.time or 0) ~= (b.time or 0) then
            return (a.time or 0) > (b.time or 0)
        end
        return (a.seq or 0) > (b.seq or 0)
    end)
end

function GF:PrunePosts()
    local cutoff = self:Now() - (self.PRUNE_DAYS * 86400)
    local kept = {}
    for _, post in ipairs(self.posts) do
        if (post.time or 0) >= cutoff and #kept < self.MAX_POSTS then
            table.insert(kept, post)
        else
            self.seen[post.id] = nil
        end
    end
    self.posts = kept
end

-- Only posts needs re-pointing: PrunePosts/ClearPosts replace the table. The
-- other saved tables are the GuildFeedDB tables themselves (see OnADDON_LOADED).
function GF:Save()
    if self.db then
        self.db.posts = self.posts
    end
end

function GF:FindPost(id)
    return self.seen[id]
end

-- Likes are a last-writer-wins set: likeState[liker] = { s = 1|0, ts }.
-- Only the liker ever writes their own key, and newer timestamps win, so
-- likes converge across clients regardless of delivery order, duplicates,
-- or offline gaps. (A tiny CRDT.)
function GF:LikeCount(post)
    local n = 0
    for _, e in pairs(post.likeState or {}) do
        if e.s == 1 then
            n = n + 1
        end
    end
    return n
end

function GF:HasLiked(post, name)
    local e = post and post.likeState and post.likeState[name]
    return e ~= nil and e.s == 1
end

-- "Hot" ranking for the Top tab: likes with time decay.
-- Approximate by design: each client ranks only the posts it has seen.
function GF:HotScore(post)
    local ageHours = math.max(self:Now() - (post.time or 0), 60) / 3600
    return self:LikeCount(post) / (ageHours + 2) ^ 1.5
end

function GF:ToggleLike(post)
    if not post or not self.playerName then
        return
    end
    local me = self.playerName
    local state = self:HasLiked(post, me) and 0 or 1
    local ts = self:Now()
    self:SetLike(post.id, me, state, ts)
    self:BroadcastLike(post.id, me, state, ts)
end

function GF:SetLike(postId, liker, state, ts)
    local post = self:FindPost(postId)
    if not post then
        return
    end
    post.likeState = post.likeState or {}
    ts = tonumber(ts) or self:Now()
    local cur = post.likeState[liker]
    if not cur or ts >= (cur.ts or 0) then
        post.likeState[liker] = { s = state, ts = ts }
    end
    self:Changed()
end

-- Merge a remote like state (from HISTORY catch-up): per-liker
-- last-writer-wins. Idempotent and order-independent.
function GF:MergeLikes(post, remote)
    if not post or not remote then
        return
    end
    post.likeState = post.likeState or {}
    local changed = false
    for liker, e in pairs(remote) do
        local cur = post.likeState[liker]
        if not cur or (e.ts or 0) >= (cur.ts or 0) then
            post.likeState[liker] = { s = e.s, ts = e.ts }
            changed = true
        end
    end
    if changed then
        self:Changed()
    end
end

-- Profiles: best-known class/level/guild rank per character name.
function GF:CacheProfile(name, class, level, rank)
    if not name then
        return
    end
    local p = self.profiles[name] or {}
    if class and class ~= "" then
        p.class = class
    end
    if level and level > 0 then
        p.level = level
    end
    if rank then
        p.rank = rank
    end
    self.profiles[name] = p
end

-- Portfolios ("LinkedIn"): professions and achievement points are only
-- queryable for yourself, so each client broadcasts its own in HELLO and
-- everyone caches it here, persisted in SavedVariables. Recent epics are
-- different: they're witnessed from local post history, not self-reported
-- (the game keeps no loot history API; our feed IS the store).
function GF:GatherProfessions()
    local profs = {}
    if GetProfessions then
        local slots = { GetProfessions() }
        for i = 1, 6 do
            local idx = slots[i]
            if idx and GetProfessionInfo then
                local name, _, skill, maxSkill = GetProfessionInfo(idx)
                if name and skill and skill > 0 then
                    table.insert(profs, { name = name, skill = skill, max = maxSkill or 0 })
                end
            end
        end
    end
    return profs
end

function GF:PortfolioString()
    local parts = {}
    for _, pr in ipairs(self:GatherProfessions()) do
        -- profession names come from the client's fixed list; no pipes possible
        table.insert(parts, pr.name .. ":" .. pr.skill .. "/" .. pr.max)
    end
    return table.concat(parts, ",")
end

function GF:CachePortfolio(name, profStr, achPoints)
    if not name or name == "" then
        return
    end
    local pf = self.portfolios[name] or {}
    if profStr ~= nil then
        local profs = {}
        if profStr ~= "" then
            for entry in profStr:gmatch("[^,]+") do
                local nm, skill, max = entry:match("^(.-):(%d+)/(%d+)$")
                if nm then
                    table.insert(profs, { name = nm, skill = tonumber(skill), max = tonumber(max) })
                end
            end
        end
        pf.professions = profs
    end
    if achPoints and achPoints > 0 then
        pf.achPoints = achPoints
    end
    self.portfolios[name] = pf
    self:Save()
end

-- Recent loot posts by author, newest first.
function GF:RecentLoot(name, n)
    local found = {}
    for _, post in ipairs(self.posts) do
        if post.kind == "loot" and post.author == name then
            table.insert(found, post)
            if #found >= n then
                break
            end
        end
    end
    return found
end

-- Presence: who else is running the addon right now.
function GF:MarkOnline(name)
    if name and name ~= "" then
        self.online[name] = self:Now()
    end
end

function GF:PruneOnline()
    local cutoff = self:Now() - self.ONLINE_TIMEOUT
    for name, lastSeen in pairs(self.online) do
        if lastSeen < cutoff then
            self.online[name] = nil
        end
    end
end

function GF:OnlineCount()
    return self:CountKeys(self.online)
end

function GF:ToggleFollow(name)
    if not name or name == self.playerName then
        return
    end
    if self.following[name] then
        self.following[name] = nil
        -- explicit unfollow sticks: friend auto-follow won't re-add them
        self.unfollowed[name] = true
    else
        self.following[name] = true
        self.unfollowed[name] = nil
    end
    self:Changed()
end

-- Auto-follow rule shared by friends and allies: never yourself, and an
-- explicit unfollow sticks. Returns true if a new follow was added.
function GF:AutoFollow(name)
    if not name or name == "" or name == self.playerName
        or self.following[name] or self.unfollowed[name] then
        return false
    end
    self.following[name] = true
    return true
end

-- Friends are followed automatically (unless explicitly unfollowed, or the
-- setting is off). Runs at login and whenever the friend list changes.
function GF:SyncFriendsToFollowing()
    if not self:GetSetting("followFriends") then
        return
    end
    if not GetNumFriends or not GetFriendInfo then
        return
    end
    local changed = false
    for i = 1, GetNumFriends() do
        -- classic API: name is the first return
        changed = self:AutoFollow((GetFriendInfo(i))) or changed
    end
    if changed then
        self:Changed()
    end
end

function GF:OnFRIENDLIST_UPDATE()
    self:SyncFriendsToFollowing()
end

-- Build a name -> unit token map for you and everyone in your party/raid.
-- Used for group-ally tracking, and by the UI for portraits (SetPortraitTexture
-- needs a unit token).
function GF:BuildUnitMap()
    local map = {}
    if not UnitExists or not UnitName then
        return map
    end
    local function add(token)
        if UnitExists(token) then
            local name = UnitName(token)
            if name and name ~= "" then
                map[name] = token
            end
        end
    end
    add("player")
    for i = 1, 4 do
        add("party" .. i)
    end
    for i = 1, 40 do
        add("raid" .. i)
    end
    return map
end

-- "Recent allies": there is no API for group history on Classic, so we track
-- it ourselves. Everyone in your party/raid gets a timestamp; allies grouped
-- with inside ALLY_WINDOW_DAYS are auto-followed (same blocklist rules).
function GF:RecordGroupAllies()
    local now = self:Now()
    local seen = false
    for name in pairs(self:BuildUnitMap()) do
        if name ~= self.playerName then
            self.recentAllies[name] = now
            seen = true
        end
    end
    if seen then
        self:Save()
    end
end

function GF:SyncAlliesToFollowing()
    if not self:GetSetting("followAllies") then
        return
    end
    local cutoff = self:Now() - (self.ALLY_WINDOW_DAYS * 86400)
    local changed = false
    for name, ts in pairs(self.recentAllies) do
        if ts < cutoff then
            self.recentAllies[name] = nil -- window expired; existing follows stay
            changed = true
        else
            changed = self:AutoFollow(name) or changed
        end
    end
    if changed then
        self:Changed()
    end
end

function GF:OnGROUP_ROSTER_UPDATE()
    self:RecordGroupAllies()
    self:SyncAlliesToFollowing()
end
