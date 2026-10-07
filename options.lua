-- GuildFeed - options
-- Standalone settings screen, reachable from the game's Interface > AddOns list
-- (and via "/feed options"). Guarded: if the options API is absent, the panel
-- simply isn't registered and the slash command prints the settings instead.

local GF = GuildFeed

local function MakeCheckbox(parent, label, tooltip, x, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    fs:SetText(label)
    cb.tooltipText = tooltip
    return cb
end

local CHECKBOXES = {
    { key = "postLevel", label = "Post level-ups",
        tooltip = "Automatically share a post when you level up." },
    { key = "postLoot", label = "Post epic loot",
        tooltip = "Automatically share a post when you loot an epic or better." },
    { key = "testGreens", label = "Test mode: trigger loot posts on greens",
        tooltip = "Lowers the loot threshold to greens. Useful for testing the feed without waiting for an epic." },
    { key = "followFriends", label = "Automatically follow friends",
        tooltip = "People on your in-game friend list are followed automatically. Unfollowing someone sticks." },
    { key = "followAllies", label = "Automatically follow recent allies",
        tooltip = "People you've grouped with in the last 14 days are followed automatically. Unfollowing someone sticks." },
}

function GF:BuildOptionsPanel()
    if self.optionsPanel then
        return self.optionsPanel
    end
    local panel = CreateFrame("Frame", "GuildFeedOptionsPanel", UIParent)
    panel.name = "GuildFeed"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("GuildFeed")

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    sub:SetText("Choose which game moments become feed posts.")

    local y = -72
    local checks = {}
    for _, opt in ipairs(CHECKBOXES) do
        local cb = MakeCheckbox(panel, opt.label, opt.tooltip, 16, y)
        cb:SetScript("OnClick", function(c)
            GF:SetSetting(opt.key, c:GetChecked() and true or false)
        end)
        checks[opt.key] = cb
        y = y - 36
    end
    y = y - 20

    self.SyncOptionsPanel = function()
        for key, cb in pairs(checks) do
            cb:SetChecked(GF:GetSetting(key))
        end
    end
    self:SyncOptionsPanel()

    local danger = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    danger:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    danger:SetText("Local data")
    y = y - 30
    local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearBtn:SetSize(200, 24)
    clearBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    clearBtn:SetText("Clear local feed history")
    clearBtn:SetScript("OnClick", function()
        GF:ClearPosts()
        GF:Print("local feed history cleared.")
    end)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
    self.optionsPanel = panel
    return panel
end

-- Open the panel directly (used by "/feed options").
function GF:OpenOptions()
    self:BuildOptionsPanel()
    if InterfaceOptionsFrame_OpenToCategory and self.optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
    else
        self:Print("options panel isn't available on this client. Settings: " .. self:SettingsSummary() .. ".")
    end
end
