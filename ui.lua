-- GuildFeed - ui
-- The feed window: scrolling posts, like buttons, follow filter,
-- profile popups, and the composer box. /feed to toggle.

local GF = GuildFeed

local ROW_WIDTH = 372
local FEED_W, FEED_H = 440, 540
local MAX_ROWS = 40

local KIND_LABEL = {
    level = "leveled up",
    loot = "got loot",
    post = "posted",
}

local function ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS[classFile]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

local function ColorizeName(name, classFile)
    local r, g, b = ClassColor(classFile)
    -- math.floor: %x needs integers on Lua 5.4+ (WoW's 5.1 tolerates floats)
    r, g, b = math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
    return string.format("|cff%02x%02x%02x%s|r", r, g, b, name)
end

local function PrettyClass(classFile)
    if not classFile or classFile == "" then
        return "?"
    end
    return classFile:sub(1, 1):upper() .. classFile:sub(2):lower()
end

local function TimeAgo(t)
    local d = GF:Now() - (t or 0)
    if d < 0 then
        d = 0
    end
    if d < 60 then
        return "just now"
    end
    if d < 3600 then
        return math.floor(d / 60) .. "m ago"
    end
    if d < 86400 then
        return math.floor(d / 3600) .. "h ago"
    end
    return math.floor(d / 86400) .. "d ago"
end

local function MakeWindow(name, w, h, title)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.TitleText:SetText(title)
    f:Hide()
    return f
end

-- Square avatar with a class-colored border. Shows the live 3D portrait when
-- the character is in your party/raid, otherwise a class-colored initial.
-- (True portraits for arbitrary guildmates aren't possible: the API only
-- exposes portraits through unit tokens.)
-- Note: drawn with plain textures, not SetBackdrop — plain frames on this
-- client don't have backdrop methods.
-- Built once per row/window and re-filled with SetAvatar on each refresh.
function GF:CreateAvatar(parent, size)
    local edge = 2
    local avatar = CreateFrame("Frame", nil, parent)
    avatar:SetSize(size, size)

    -- class-colored border: 4 thin textures around the edge
    avatar.border = {}
    local function borderBar(point, w, h)
        local t = avatar:CreateTexture(nil, "BORDER")
        t:SetSize(w, h)
        t:SetPoint(point, avatar, point, 0, 0)
        table.insert(avatar.border, t)
    end
    borderBar("TOP", size, edge)
    borderBar("BOTTOM", size, edge)
    borderBar("LEFT", edge, size)
    borderBar("RIGHT", edge, size)

    -- dark inset background
    local bg = avatar:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0.07, 0.07, 0.07, 1)
    bg:SetPoint("TOPLEFT", avatar, "TOPLEFT", edge, -edge)
    bg:SetPoint("BOTTOMRIGHT", avatar, "BOTTOMRIGHT", -edge, edge)

    local portrait = avatar:CreateTexture(nil, "ARTWORK")
    portrait:SetPoint("TOPLEFT", avatar, "TOPLEFT", edge + 1, -(edge + 1))
    portrait:SetPoint("BOTTOMRIGHT", avatar, "BOTTOMRIGHT", -(edge + 1), edge + 1)
    avatar.portrait = portrait

    local initial = avatar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    initial:SetPoint("CENTER", avatar, "CENTER", 0, 1)
    avatar.initial = initial
    return avatar
end

function GF:SetAvatar(avatar, name, class, unitMap)
    local r, g, b = ClassColor(class)
    for _, t in ipairs(avatar.border) do
        t:SetColorTexture(r, g, b, 1)
    end
    local token = unitMap and unitMap[name]
    if token and SetPortraitTexture then
        SetPortraitTexture(avatar.portrait, token)
        avatar.portrait:Show()
        avatar.initial:Hide()
    else
        avatar.portrait:Hide()
        avatar.initial:SetText(name:sub(1, 1):upper())
        avatar.initial:SetTextColor(r, g, b)
        avatar.initial:Show()
    end
end

function GF:ToggleUI()
    if not self.mainFrame then
        self:BuildUI()
    end
    if self.mainFrame:IsShown() then
        self.mainFrame:Hide()
    else
        self:BroadcastHello() -- let everyone know we're here
        self:RefreshFeed()
        self.mainFrame:Show()
    end
end

function GF:SetTab(tab)
    self.currentTab = tab
    self:UpdateTabs()
    self:RefreshFeed()
end

function GF:UpdateTabs()
    for id, btn in pairs(self.tabButtons or {}) do
        if id == self.currentTab then
            btn:SetText("|cffffd100" .. btn.tabLabel .. "|r")
        else
            btn:SetText(btn.tabLabel)
        end
    end
end

function GF:BuildUI()
    local f = MakeWindow("GuildFeedFrame", FEED_W, FEED_H, "GuildFeed")
    self.mainFrame = f

    -- online count in the header
    local onlineLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    onlineLabel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -13)
    onlineLabel:SetTextColor(0.6, 1, 0.6)
    self.onlineLabel = onlineLabel

    -- feed tabs: Guild | Top | Following
    local tabs = {
        { id = "guild", label = "Guild" },
        { id = "top", label = "Top" },
        { id = "following", label = "Following" },
    }
    self.tabButtons = {}
    self.currentTab = "guild"
    local tx = 12
    for _, t in ipairs(tabs) do
        local tabId = t.id
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(86, 22)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -32)
        btn.tabLabel = t.label
        btn:SetScript("OnClick", function()
            GF:SetTab(tabId)
        end)
        self.tabButtons[tabId] = btn
        tx = tx + 90
    end
    self:UpdateTabs()

    -- scroll area
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -60)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 66)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_WIDTH + 12, 10)
    scroll:SetScrollChild(content)
    self.feedContent = content

    -- composer: type a status update, hit Post (or Enter)
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(FEED_W - 112, 24)
    box:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(GF.MAX_TEXT)
    self.composer = box

    local postBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    postBtn:SetSize(80, 24)
    postBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 20)
    postBtn:SetText("Post")
    postBtn:SetScript("OnClick", function()
        GF:SubmitComposer()
    end)
    box:SetScript("OnEnterPressed", function()
        GF:SubmitComposer()
    end)

    -- periodic refresh while shown (OnUpdate doesn't fire on hidden frames):
    -- RefreshFeed prunes the online list and keeps "xm ago" fresh
    local tick = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        tick = tick + elapsed
        if tick >= 30 then
            tick = 0
            GF:RefreshFeed()
        end
    end)
end

function GF:SubmitComposer()
    -- NewPost trims and rejects empty text
    if self:NewPost("post", self.composer:GetText()) then
        self.composer:SetText("")
        self.composer:ClearFocus()
    end
end

function GF:UpdateOnlineLabel()
    if self.onlineLabel then
        self.onlineLabel:SetText(self:OnlineCount() .. " online")
    end
end

-- The post list for the active tab.
-- Guild: everything, newest first. Top: best of the guild, hot-ranked.
-- Following: followed authors (plus self), newest first.
function GF:BuildFeedList()
    local list = {}
    for _, post in ipairs(self.posts) do
        if self.currentTab ~= "following"
            or post.author == self.playerName
            or self.following[post.author] then
            table.insert(list, post)
        end
    end
    if self.currentTab == "top" then
        local score = {}
        for _, post in ipairs(list) do
            score[post] = self:HotScore(post)
        end
        table.sort(list, function(a, b)
            return score[a] > score[b]
        end)
    end
    return list
end

function GF:RefreshFeed()
    local content = self.feedContent
    if not content then
        return
    end
    if self.followHintFs then
        self.followHintFs:Hide()
    end
    self:PruneOnline()
    self:UpdateOnlineLabel()

    local unitMap = self:BuildUnitMap()
    local list = self:BuildFeedList()

    local y = -6

    -- hint when the Following tab has nobody in it yet (created once, shown/hidden)
    if self.currentTab == "following" and not next(self.following) then
        local hint = self.followHintFs
        if not hint then
            hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            hint:SetWidth(ROW_WIDTH - 12)
            hint:SetJustifyH("LEFT")
            hint:SetWordWrap(true)
            hint:SetTextColor(1, 0.85, 0.4)
            hint:SetText("You're not following anyone yet. Tap Follow on any post to fill this tab.")
            self.followHintFs = hint
        end
        hint:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y)
        hint:Show()
        y = y - hint:GetStringHeight() - 10
    end

    -- rows are pooled: created on first need, then re-filled every refresh
    self.rows = self.rows or {}
    local n = math.min(#list, MAX_ROWS)
    for i = 1, n do
        local row = self.rows[i] or self:CreateRow(content)
        self.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y)
        y = y - self:FillRow(row, list[i], unitMap) - 8
        row:Show()
    end
    for i = n + 1, #self.rows do
        self.rows[i]:Hide()
    end
    content:SetHeight(math.max(10, -y + 6))
end

-- Shared row click handlers: each reads the post the row currently shows.
local function OnAuthorClick(btn)
    GF:ShowProfile(btn:GetParent().post.author)
end

local function OnLikeClick(btn)
    GF:ToggleLike(btn:GetParent().post)
end

local function OnFollowClick(btn)
    GF:ToggleFollow(btn:GetParent().post.author)
end

function GF:CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetWidth(ROW_WIDTH)

    -- avatar square on the left
    row.avatar = self:CreateAvatar(row, 36)
    row.avatar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)

    -- author name, class-colored, clickable -> profile popup
    local author = CreateFrame("Button", nil, row)
    author:SetPoint("TOPLEFT", row, "TOPLEFT", 44, 0)
    author:SetSize(168, 18)
    author:SetScript("OnClick", OnAuthorClick)
    local authorText = author:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    authorText:SetPoint("LEFT", author, "LEFT", 0, 0)
    authorText:SetJustifyH("LEFT")
    authorText:SetWidth(168)
    row.authorText = authorText

    -- kind + relative time, right aligned
    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    meta:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -2)
    meta:SetTextColor(0.62, 0.62, 0.62)
    row.meta = meta

    -- body text
    local body = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", row, "TOPLEFT", 44, -20)
    body:SetWidth(ROW_WIDTH - 76 - 74 - 44) -- like + follow buttons + avatar gutter
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    row.body = body

    -- like button
    local likeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    likeBtn:SetSize(68, 20)
    likeBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -20)
    likeBtn:SetScript("OnClick", OnLikeClick)
    row.likeBtn = likeBtn

    -- follow button, left of like, so following is discoverable without the profile popup
    local followBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    followBtn:SetSize(68, 20)
    followBtn:SetPoint("TOPRIGHT", likeBtn, "TOPLEFT", -6, 0)
    followBtn:SetScript("OnClick", OnFollowClick)
    row.followBtn = followBtn
    return row
end

-- Fill a pooled row with a post; returns the row's height.
function GF:FillRow(row, post, unitMap)
    row.post = post
    self:SetAvatar(row.avatar, post.author, post.class, unitMap)

    local followMark = self.following[post.author] and "|cff7fd4ff*|r " or ""
    row.authorText:SetText(followMark .. ColorizeName(post.author, post.class))
    row.meta:SetText((KIND_LABEL[post.kind] or "posted") .. " - " .. TimeAgo(post.time))
    row.body:SetText(post.text)

    local liked = self:HasLiked(post, self.playerName)
    row.likeBtn:SetText((liked and "|cffff6060" or "") .. "Like (" .. self:LikeCount(post) .. ")" .. (liked and "|r" or ""))

    if post.author ~= self.playerName then
        row.followBtn:SetText(self.following[post.author] and "Following" or "Follow")
        row.followBtn:Show()
    else
        row.followBtn:Hide()
    end

    local rowH = math.max(46, 20 + math.max(row.body:GetStringHeight(), 22) + 12)
    row:SetHeight(rowH)
    return rowH
end

-- Character portfolio ("LinkedIn"): identity, professions, achievement
-- points, and recent epics witnessed in local post history.
function GF:BuildProfileFrame()
    local frame = MakeWindow("GuildFeedProfileFrame", 300, 100, "Profile") -- height fits content
    frame.avatar = self:CreateAvatar(frame, 48)
    frame.avatar:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -36)
    frame.lines = {}

    local followBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    followBtn:SetSize(110, 24)
    followBtn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 14)
    followBtn:SetScript("OnClick", function()
        GF:ToggleFollow(frame.name)
        followBtn:SetText(GF.following[frame.name] and "Unfollow" or "Follow")
    end)
    frame.followBtn = followBtn
    self.profileFrame = frame
    return frame
end

function GF:ShowProfile(name)
    local frame = self.profileFrame or self:BuildProfileFrame()
    frame.name = name
    local p = self.profiles[name] or {}
    local pf = self.portfolios[name] or {}
    local online = self.online[name] ~= nil
    local class = p.class or "UNKNOWN"

    self:SetAvatar(frame.avatar, name, class, self:BuildUnitMap())

    -- text lines come from a fontstring pool on the frame
    local y, used = -40, 0
    local function addLine(text, x, template, cr, cg, cb)
        template = template or "GameFontNormalSmall"
        used = used + 1
        local fs = frame.lines[used]
        if not fs then
            fs = frame:CreateFontString(nil, "OVERLAY", template)
            fs:SetJustifyH("LEFT")
            frame.lines[used] = fs
        end
        fs:SetFontObject(template)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
        fs:SetWidth(284 - x)
        fs:SetText(text)
        if cr then
            fs:SetTextColor(cr, cg, cb)
        else
            fs:SetTextColor(_G[template]:GetTextColor())
        end
        fs:Show()
        y = y - 17
    end
    local function addHeader(text)
        y = y - 4
        addLine(text, 16, "GameFontNormalSmall", 1, 0.82, 0)
    end

    -- identity block, next to the avatar
    addLine(ColorizeName(name, class), 76, "GameFontNormalLarge")
    y = y - 6
    addLine("Level " .. (p.level or "?") .. " " .. PrettyClass(class), 76)
    if online then
        addLine("Online now", 76, "GameFontNormalSmall", 0.4, 1, 0.4)
    else
        addLine("Offline", 76, "GameFontNormalSmall", 0.6, 0.6, 0.6)
    end
    if p.rank then
        addLine("<" .. p.rank .. ">", 76, "GameFontNormalSmall", 0.7, 0.7, 0.7)
    end

    -- portfolio sections, full width
    addHeader("PROFESSIONS")
    if pf.professions and #pf.professions > 0 then
        for _, pr in ipairs(pf.professions) do
            addLine("  " .. pr.name .. " " .. pr.skill .. "/" .. pr.max, 16)
        end
    else
        addLine("  not shared yet", 16, "GameFontNormalSmall", 0.55, 0.55, 0.55)
    end

    if (pf.achPoints or 0) > 0 then
        addHeader("ACHIEVEMENTS")
        addLine("  " .. pf.achPoints .. " points", 16)
    end

    addHeader("RECENT EPICS")
    local loot = self:RecentLoot(name, 3)
    if #loot > 0 then
        for _, post in ipairs(loot) do
            addLine("  " .. post.text, 16)
        end
    else
        addLine("  none tracked yet", 16, "GameFontNormalSmall", 0.55, 0.55, 0.55)
    end
    for i = used + 1, #frame.lines do
        frame.lines[i]:Hide()
    end

    frame:SetHeight(-y + 56)

    if name ~= self.playerName then
        frame.followBtn:SetText(self.following[name] and "Unfollow" or "Follow")
        frame.followBtn:Show()
    else
        frame.followBtn:Hide()
    end
    frame:Show()
end

-- Slash commands
SLASH_GUILDFEED1 = "/feed"
SLASH_GUILDFEED2 = "/guildfeed"
SlashCmdList["GUILDFEED"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "options" then
        GuildFeed:OpenOptions()
    else
        GuildFeed:ToggleUI()
    end
end

-- Quick-post without opening the window: /gfp having a great time in Barrens
SLASH_GUILDFEEDPOST1 = "/gfp"
SlashCmdList["GUILDFEEDPOST"] = function(msg)
    if GuildFeed:NewPost("post", msg) then
        GuildFeed:Print("posted to your feed.")
    else
        GuildFeed:Print("usage: /gfp <your status>")
    end
end

-- Diagnostics: /feeddebug prints addon state for troubleshooting.
-- /feeddebug greens -> loot auto-posts trigger on greens+ (test mode, resets on relog)
-- /feeddebug epics  -> back to epics+
SLASH_GUILDFEEDDEBUG1 = "/feeddebug"
SlashCmdList["GUILDFEEDDEBUG"] = function(msg)
    local GF = GuildFeed
    msg = strtrim(msg or ""):lower()
    if msg == "greens" then
        GF:SetSetting("testGreens", true)
        print("|cff7fd4ffGuildFeed debug:|r loot auto-posts now trigger on |cff1eff00greens|r and up (test mode)")
        return
    elseif msg == "epics" then
        GF:SetSetting("testGreens", false)
        print("|cff7fd4ffGuildFeed debug:|r loot auto-posts now trigger on |cffa335eeepics|r and up")
        return
    end
    print("|cff7fd4ffGuildFeed debug:|r v" .. GF.VERSION)
    print("  player: " .. tostring(GF.playerName) .. " (" .. tostring(GF.playerClass) .. ")")
    print("  in guild: " .. tostring(IsInGuild()))
    print("  posts: " .. #GF.posts .. ", online: " .. GF:OnlineCount() .. ", following: " .. GF:CountKeys(GF.following))
    print("  loot threshold: " .. (GF:LootThreshold() == 2 and "greens+ (test mode)" or "epics+"))
    print("  settings: " .. GF:SettingsSummary())
    print("  addon comms: " .. (GF.SendMsg and "ok" or "MISSING"))
    print("  portraits: " .. (SetPortraitTexture and "ok" or "MISSING"))
end
