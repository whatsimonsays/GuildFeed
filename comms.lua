-- GuildFeed - comms
-- Sync between addon copies over the hidden guild addon channel.
-- (Classic 1.13.3+ blocks addon messages over custom channels, so there is
-- no server-wide scope: everything here is guild members only.)
-- Wire protocol (all messages are plain text):
--   HELLO|name|class|level|professions|achPoints - "I'm here and running GuildFeed"
--   POST|<serialized post>      - a brand new post
--   HISTORY|<serialized post>   - post sent in answer to a SYNC_REQ (catch-up)
--   LIKE|postId|liker|1|0|ts    - like added (1) or removed (0), with timestamp
--   SYNC_REQ|<newestTime>       - "I just logged in; send me anything newer than this"
-- Likes are last-writer-wins per liker (timestamps); HISTORY messages carry
-- each post's like set so returning clients converge on catch-up.
--
-- Hard limits of the platform, for the curious:
-- - No internet access, ever. This only reaches guildmates who are online
--   AND running the addon.
-- - Addon messages are throttled; keep them small and infrequent.

local GF = GuildFeed

GF.SendMsg = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

function GF:SendComm(message)
    if self.SendMsg and IsInGuild() then
        self.SendMsg(self.PREFIX, message, "GUILD")
    end
end

function GF:BroadcastHello()
    if not self.playerName then
        return
    end
    -- professions + achievement points ride along in HELLO (extra fields are
    -- ignored by older clients, which only read the first three)
    local profStr = self:PortfolioString()
    local ach = (GetTotalAchievementPoints and GetTotalAchievementPoints()) or 0
    self:CachePortfolio(self.playerName, profStr, ach)
    self:SendComm(table.concat({
        "HELLO",
        self.playerName,
        self.playerClass or "",
        tostring(UnitLevel("player") or 0),
        profStr,
        tostring(ach),
    }, "|"))
end

function GF:BroadcastPost(post)
    self:SendComm("POST|" .. self:SerializePost(post))
end

function GF:BroadcastLike(postId, liker, state, ts)
    self:SendComm("LIKE|" .. postId .. "|" .. liker .. "|" .. state .. "|" .. ts)
end

-- Catch-up, receiver-pull style: on login, ask peers for anything posted
-- since our newest post. (The old sender-push model had a hole: it repaired
-- "my posts, for others who were offline" but not "others' posts, for me.")
function GF:SendSyncRequest()
    local newest = (self.posts[1] and self.posts[1].time) or 0
    self:SendComm("SYNC_REQ|" .. newest)
end

function GF:ScheduleSyncRequest()
    self:After(5, function()
        GF:SendSyncRequest()
    end)
end

-- Answer a peer's SYNC_REQ with our posts newer than their newest.
-- Jittered so simultaneous logins don't reply in lockstep; receivers
-- dedupe by post id, so overlapping answers are harmless.
function GF:AnswerSyncRequest(reqTime)
    local fresh = {}
    for _, post in ipairs(self.posts) do
        if (post.time or 0) > reqTime then
            table.insert(fresh, post)
            if #fresh >= self.HISTORY_COUNT then
                break
            end
        end
    end
    if #fresh == 0 then
        return
    end
    self:After(1 + math.random() * 3, function()
        for _, post in ipairs(fresh) do
            GF:SendComm("HISTORY|" .. GF:SerializePost(post))
        end
    end)
end

function GF:OnCHAT_MSG_ADDON(prefix, message, channel, sender)
    if prefix ~= self.PREFIX then
        return
    end
    if sender == self.playerName then
        return
    end
    self:MarkOnline(sender)

    local msgType, payload = message:match("^([A-Z_]+)|(.*)$")
    if not msgType then
        return
    end

    if msgType == "HELLO" then
        local parts = self.Split(payload)
        self:CacheProfile(parts[1], parts[2], tonumber(parts[3]) or 0)
        self:CachePortfolio(parts[1], parts[4], tonumber(parts[5]) or 0)
    elseif msgType == "SYNC_REQ" then
        self:AnswerSyncRequest(tonumber(payload) or 0)
    elseif msgType == "POST" or msgType == "HISTORY" then
        local post = self:DeserializePost(payload)
        if post then
            self:IngestPost(post)
        end
    elseif msgType == "LIKE" then
        local postId, liker, state, ts = payload:match("^(.-)|(.-)|(%d+)|(%d+)$")
        if not postId then
            -- pre-0.4.0 format without timestamp
            postId, liker, state = payload:match("^(.-)|(.-)|(%d+)$")
        end
        if postId and liker then
            self:SetLike(postId, liker, tonumber(state) or 0, tonumber(ts))
        end
    end
end
