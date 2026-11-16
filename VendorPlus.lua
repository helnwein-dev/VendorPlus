local L=VendorPlusL
function VendorPlusCarriedBags()
    local bags={}
    local regular=NUM_BAG_SLOTS or 4
    for bag=0,regular do bags[#bags+1]=bag end
    local reagent=(Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
    if reagent>regular then bags[#bags+1]=reagent end
    return bags
end

function VendorPlusIsCarriedBag(bag)
    if type(bag)~="number" then return false end
    local reagent=(Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
    return (bag>=0 and bag<=(NUM_BAG_SLOTS or 4)) or bag==reagent
end

function VendorPlusMoneyText(amount)
    amount=math.max(0,math.floor(tonumber(amount) or 0))
    local gold=math.floor(amount/10000)
    local silver=math.floor(amount/100)%100
    local copper=amount%100
    local parts={}
    if gold>0 then parts[#parts+1]=gold.."|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t" end
    if silver>0 then parts[#parts+1]=silver.."|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t" end
    if copper>0 or #parts==0 then parts[#parts+1]=copper.."|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t" end
    return table.concat(parts," ")
end

local events = CreateFrame("Frame")
local initialized, search, filterButton, resetButton, scanTooltip
local settings
local stateCache, scanQueue, queued = {}, {}, {}
local scanHead, redraw, elapsedSinceDraw = 1, false, 0
local refreshing = false

local function itemInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        return C_MerchantFrame.GetItemInfo(index)
    end
    local name, texture, price, stackCount, numAvailable, isPurchasable, isUsable, hasExtendedCost = GetMerchantItemInfo(index)
    return {name = name, texture = texture, price = price, stackCount = stackCount, numAvailable = numAvailable, isPurchasable = isPurchasable, isUsable = isUsable, hasExtendedCost = hasExtendedCost}
end

local function scanItemState(index)
    scanTooltip:ClearLines()
    scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTooltip:SetMerchantItem(index)
    local known, blocked, knownRecipe = false, false, false
    for line = 2, scanTooltip:NumLines() do
        for _, side in ipairs({"Left", "Right"}) do
            local text = _G[scanTooltip:GetName() .. "Text" .. side .. line]
            if text and text:GetText() then
                local value = text:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                if value == ITEM_SPELL_KNOWN or value == ITEM_ALREADY_KNOWN then
                    known, knownRecipe = true, true
                elseif value == TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN then
                    known = true
                else
                    local r, g, b = text:GetTextColor()
                    if r > 0.8 and g < 0.3 and b < 0.3 then blocked = true end
                end
            end
        end
    end
    scanTooltip:Hide()
    local link = GetMerchantItemLink(index)
    if link and C_TransmogCollection and C_TransmogCollection.GetItemInfo
        and C_TransmogCollection.GetAppearanceSourceInfo then
        local _, source = C_TransmogCollection.GetItemInfo(link)
        if source then
            local info = C_TransmogCollection.GetAppearanceSourceInfo(source)
            if info and info.isCollected then known = true end
        end
    end
    return known, blocked, knownRecipe
end

local function clearStates()
    stateCache, scanQueue, queued = {}, {}, {}
    scanHead = 1
end

local function itemState(index)
    local cached = stateCache[index]
    if cached then return cached.known, cached.blocked, cached.knownRecipe end
    if not queued[index] then
        queued[index] = true
        scanQueue[#scanQueue + 1] = index
    end
    return false, false
end

local metadata = {}
local pendingItemInfo = false
local function itemMetadata(index)
    local link = GetMerchantItemLink(index)
    if not link then return end
    if metadata[link] then return metadata[link] end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if not getInfo then return end
    local name, _, _, _, requiredLevel, _, _, _, equipLoc, _, _, classID, subclassID = getInfo(link)
    if not name or not classID then pendingItemInfo = true; return end
    local data = {level = requiredLevel or 0, classID = classID, subclassID = subclassID, equipLoc = equipLoc}
    if classID == 0 and subclassID == 5 then
        local getSpell = C_Item and C_Item.GetItemSpell or GetItemSpell
        if getSpell then
            local spell = getSpell(link)
            local food, drink = getSpell(117), getSpell(159)
            if spell and food and spell == food then data.family = "food"
            elseif spell and drink and spell == drink then data.family = "drink"
            elseif spell and food and drink and spell:find(food, 1, true) and spell:find(drink, 1, true) then data.family = "fooddrink" end
        end
    end
    if classID == 0 and subclassID == 5 and not data.family then
        pendingItemInfo = true
        return data
    end
    metadata[link] = data
    return data
end

local function meetsRequirements(data, playerLevel)
    if not data then return true end
    if data.level > playerLevel then return false end
    if data.classID == 4 and data.equipLoc ~= "INVTYPE_CLOAK" then
        local proficiency = ({[1] = 9078, [2] = 9077, [3] = 8737, [4] = 750, [6] = 9116})[data.subclassID]
        local isKnown = IsPlayerSpell or IsSpellKnown
        if proficiency and isKnown and not isKnown(proficiency) then return false end
    end
    return true
end

local function priceKey(index, info)
    local parts, amounts = {}, {}
    if info.hasExtendedCost then
        for n = 1, GetMerchantItemCostInfo(index) do
            local texture, amount, link, name = GetMerchantItemCostItem(index, n)
            parts[#parts + 1] = tostring(link or name or texture or n)
            amounts[#amounts + 1] = amount or 0
        end
    end
    return {gold = info.price or 0, group = table.concat(parts, "|"), amounts = amounts}
end

local function comparePrice(a, b)
    local x, y = a.cost, b.cost
    local xGroup, yGroup = x.group == "" and 0 or 1, y.group == "" and 0 or 1
    if xGroup ~= yGroup then return xGroup < yGroup end
    if x.group ~= y.group then return x.group < y.group end
    if x.gold ~= y.gold then return x.gold < y.gold end
    for n = 1, math.max(#x.amounts, #y.amounts) do
        local left, right = x.amounts[n] or 0, y.amounts[n] or 0
        if left ~= right then return left < right end
    end
    return a.index < b.index
end

local recipeColors = {}
local function altoholicColor(index, link)
    if not Altoholic or not Altoholic.GetRecipeOwners or not Altoholic.GetRecipeLevel
        or not Altoholic_UI_Options or Altoholic_UI_Options.VendorColorCoding == false then return end
    local itemID = link and tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    if recipeColors[itemID] then return recipeColors[itemID] end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local _, _, _, _, _, _, subtype, _, _, _, _, classID, subclassID = getInfo(itemID)
    if not classID then return end
    local color = {1, 1, 1}
    if IsBOPItemKnown and IsBOPItemKnown(itemID) then
        color = {1, 0, 0}
    elseif Enum and classID == Enum.ItemClass.Recipe and subclassID ~= Enum.ItemRecipeSubclass.Book then
        local ok, _, couldLearn, willLearn = pcall(function()
            return Altoholic:GetRecipeOwners(subtype, link, Altoholic:GetRecipeLevel(link))
        end)
        if not ok or not couldLearn or not willLearn then return end
        if #couldLearn > 0 then color = {0, 1, 0}
        elseif #willLearn > 0 then color = {1, 1, 0}
        else color = {1, 0, 0} end
    end
    recipeColors[itemID] = color
    return color
end

local correctingColor = false
local function preserveSlotColor(button)
    if correctingColor or not button or not button.vendorPlusColor
        or not MerchantFrame:IsShown() or MerchantFrame.selectedTab ~= 1 then return end
    correctingColor = true
    local color = button.vendorPlusColor
    SetItemButtonTextureVertexColor(button, color[1], color[2], color[3])
    SetItemButtonNormalTextureVertexColor(button, color[1], color[2], color[3])
    correctingColor = false
end

local function refresh()
    if not initialized then return end
    local perPage = MERCHANT_ITEMS_PER_PAGE or 10
    for slot = 1, perPage do
        local frame = _G["MerchantItem" .. slot]
        if frame then frame:Show() end
        local button = _G["MerchantItem" .. slot .. "ItemButton"]
        if button then button.vendorPlusColor = nil end
    end
    if MerchantFrame.selectedTab == 2 then return end
    local query = strlower(search:GetText()):match("^%s*(.-)%s*$")
    if resetButton then resetButton:SetShown(settings.usable or not settings.collected or not settings.hideLowConsumables or not settings.showManaDrinks or settings.sort ~= "default") end
    if query == "" and not settings.usable and settings.collected and not settings.hideLowConsumables and settings.showManaDrinks and settings.sort == "default" then return end
    local playerLevel = UnitLevel and UnitLevel("player") or 60
    local bestRanks = {}
    if settings.hideLowConsumables then
        for index = 1, GetMerchantNumItems() do
            local data = itemMetadata(index)
            local info = itemInfo(index)
            if data and data.family and data.level <= playerLevel and info and info.isUsable ~= false then
                bestRanks[data.family] = math.max(bestRanks[data.family] or -1, data.level)
            end
        end
    end
    local matches = {}
    for index = 1, GetMerchantNumItems() do
        local info = itemInfo(index)
        if info and info.name and strlower(info.name):find(query, 1, true) then
            local known, blocked, knownRecipe = false, false, false
            if settings.usable or not settings.collected then known, blocked, knownRecipe = itemState(index) end
            local data = (settings.usable or settings.hideLowConsumables or not settings.showManaDrinks) and itemMetadata(index)
            local keepConsumable = not settings.hideLowConsumables or not data or not data.family
                or (data.level <= playerLevel and data.level == bestRanks[data.family])
            local keepDrink=settings.showManaDrinks or not data or (data.family~="drink" and data.family~="fooddrink")
            if keepDrink and keepConsumable and (settings.collected or not known) and
                (not settings.usable or (not knownRecipe and not blocked and info.isUsable ~= false and meetsRequirements(data, playerLevel))) then
                matches[#matches + 1] = {index = index, info = info, cost = settings.sort == "price" and priceKey(index, info) or nil}
            end
        end
    end
    if settings.sort == "price" then table.sort(matches, comparePrice) end
    local pages = math.max(1, math.ceil(#matches / perPage))
    MerchantFrame.page = math.max(1, math.min(MerchantFrame.page or 1, pages))
    for slot = 1, perPage do
        local prefix = "MerchantItem" .. slot
        local frame, button = _G[prefix], _G[prefix .. "ItemButton"]
        local match = matches[(MerchantFrame.page - 1) * perPage + slot]
        if frame and button then
            frame:SetShown(match ~= nil)
            if match then
                local info, index = match.info, match.index
                button:SetID(index)
                button.hasItem = true
                button.name, button.link, button.texture = info.name, GetMerchantItemLink(index), info.texture
                button.price = info.price
                button.extendedCost = info.hasExtendedCost
                button.showNonrefundablePrompt = false
                local itemID = GetMerchantItemID and GetMerchantItemID(index)
                if itemID and C_Heirloom and C_Heirloom.IsItemHeirloom then
                    button.showNonrefundablePrompt = C_Heirloom.IsItemHeirloom(itemID)
                end
                _G[prefix .. "Name"]:SetText(info.name)
                SetItemButtonCount(button, info.stackCount or 1)
                SetItemButtonStock(button, info.numAvailable)
                SetItemButtonTexture(button, info.texture)
                local money, alt = _G[prefix .. "MoneyFrame"], _G[prefix .. "AltCurrencyFrame"]
                if money then
                    MoneyFrame_Update(money:GetName(), info.price or 0)
                    money:SetShown(not info.hasExtendedCost or (info.price or 0) > 0)
                end
                if alt then
                    alt:Hide()
                    if info.hasExtendedCost and MerchantFrame_UpdateAltCurrency then
                        MerchantFrame_UpdateAltCurrency(index, slot, CanAffordMerchantItem and CanAffordMerchantItem(index))
                        alt:ClearAllPoints()
                        if (info.price or 0) > 0 and money then
                            alt:SetPoint("LEFT", money, "RIGHT", -14, 0)
                        else
                            alt:SetPoint("BOTTOMLEFT", _G[prefix .. "NameFrame"], "BOTTOMLEFT", 0, 31)
                        end
                        alt:Show()
                    end
                end
                if MerchantFrameItem_UpdateQuality then MerchantFrameItem_UpdateQuality(frame, button.link) end
                local usable = info.isUsable ~= false and info.isPurchasable ~= false
                local shade = info.numAvailable == 0 and 0.5 or 1
                SetItemButtonTextureVertexColor(button, shade, usable and shade or 0, usable and shade or 0)
                SetItemButtonNormalTextureVertexColor(button, shade, usable and shade or 0, usable and shade or 0)
                if SetItemButtonDesaturated then SetItemButtonDesaturated(button, false) end
                if SetItemButtonNameFrameVertexColor then SetItemButtonNameFrameVertexColor(frame, 0.5, usable and 0.5 or 0, usable and 0.5 or 0) end
                if SetItemButtonSlotVertexColor then SetItemButtonSlotVertexColor(frame, shade, usable and shade or 0, usable and shade or 0) end
                button.vendorPlusColor = altoholicColor(index, button.link) or {shade, usable and shade or 0, usable and shade or 0}
                preserveSlotColor(button)
                button:Show()
            else
                button.hasItem = nil
                button:Hide()
            end
        end
    end
    if MerchantPageText then
        MerchantPageText:SetFormattedText(L.PAGE_FMT, MerchantFrame.page, pages)
        MerchantPageText:SetShown(pages > 1)
    end
    if MerchantPrevPageButton then
        MerchantPrevPageButton:SetShown(pages > 1)
        MerchantPrevPageButton:SetEnabled(MerchantFrame.page > 1)
    end
    if MerchantNextPageButton then
        MerchantNextPageButton:SetShown(pages > 1)
        MerchantNextPageButton:SetEnabled(MerchantFrame.page < pages)
    end
end

local function initialize()
    if initialized or not MerchantFrame then return end
    initialized = true
    VendorPlusDB = VendorPlusDB or {}
    settings = VendorPlusDB
    if settings.usable == nil then settings.usable = false end
    if settings.hideLowConsumables == nil then settings.hideLowConsumables = true end
    if settings.collected == nil then settings.collected = true end
    if settings.showManaDrinks == nil then settings.showManaDrinks = true end
    if settings.sort ~= "price" then settings.sort = "default" end
    scanTooltip = CreateFrame("GameTooltip", "VendorPlusScanTooltip", UIParent, "GameTooltipTemplate")
    search = CreateFrame("EditBox", "VendorSearchBox", MerchantFrame, "SearchBoxTemplate")
    search:SetSize(135, 20)
    search:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -117, -40)
    search:SetAutoFocus(false)
    search:SetMaxLetters(100)
    search.Instructions:SetText(L.SEARCH)
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local function updateClear(self) self.clearButton:SetShown(self:GetText() ~= "") end
    search:HookScript("OnTextChanged", function(self)
        updateClear(self)
        MerchantFrame.page = 1
        if MerchantFrame_CloseStackSplitFrame then MerchantFrame_CloseStackSplitFrame() end
        MerchantFrame_Update()
    end)
    search:HookScript("OnEditFocusGained", updateClear)
    search:HookScript("OnEditFocusLost", updateClear)
    local function changed()
        MerchantFrame.page = 1
        if MerchantFrame_CloseStackSplitFrame then MerchantFrame_CloseStackSplitFrame() end
        MerchantFrame_Update()
    end
    filterButton = CreateFrame("DropdownButton", "VendorPlusFilters", MerchantFrame, "WowStyle1FilterDropdownTemplate")
    filterButton:SetSize(90, 22)
    filterButton:SetPoint("LEFT", search, "RIGHT", 12, 0)
    filterButton:SetText(L.FILTER)
    filterButton.Text:SetFontObject(GameFontNormal)
    filterButton:SetupMenu(function(_, root)
        local unusable = root:CreateCheckbox(L.SHOW_UNUSABLE, function() return not settings.usable end,
            function() settings.usable = not settings.usable; changed() end)
        unusable:SetTooltip(function(tooltip)
            tooltip:AddLine(L.HINT_UNUSABLE, 1, 1, 1, true)
        end)
        local lowConsumables = root:CreateCheckbox(L.SHOW_BEST, function() return settings.hideLowConsumables end,
            function() settings.hideLowConsumables = not settings.hideLowConsumables; changed() end)
        lowConsumables:SetTooltip(function(tooltip)
            tooltip:AddLine(L.HINT_BEST, 1, 1, 1, true)
        end)
        local manaDrinks=root:CreateCheckbox(L.SHOW_MANA,function() return settings.showManaDrinks end,function() settings.showManaDrinks=not settings.showManaDrinks;changed() end)
        manaDrinks:SetTooltip(function(tooltip) tooltip:AddLine(L.HINT_MANA,1,1,1,true) end)
        local collected = root:CreateCheckbox(L.SHOW_COLLECTED, function() return settings.collected end,
            function() settings.collected = not settings.collected; changed() end)
        collected:SetTooltip(function(tooltip) tooltip:AddLine(L.HINT_COLLECTED) end)
        root:CreateDivider()
        root:CreateTitle(L.SORT_BY)
        root:CreateRadio(L.DEFAULT, function() return settings.sort == "default" end,
            function() settings.sort = "default"; changed() end)
        root:CreateRadio(L.PRICE, function() return settings.sort == "price" end,
            function() settings.sort = "price"; changed() end)
    end)
    resetButton = filterButton.ResetButton
    filterButton:SetIsDefaultCallback(function()
        return not settings.usable and settings.collected and settings.hideLowConsumables and settings.showManaDrinks and settings.sort == "default"
    end)
    filterButton:SetDefaultCallback(function()
        settings.usable, settings.collected, settings.sort, settings.hideLowConsumables, settings.showManaDrinks = false, true, "default", true, true
        changed()
        filterButton:GenerateMenu()
    end)
    filterButton:ValidateResetState()

    hooksecurefunc("SetItemButtonTextureVertexColor", preserveSlotColor)
    hooksecurefunc("SetItemButtonNormalTextureVertexColor", preserveSlotColor)
    hooksecurefunc("MerchantFrame_Update", function()
        if refreshing then return end
        refreshing = true
        refresh()
        refreshing = false
    end)
    MerchantFrame:HookScript("OnHide", function() clearStates(); redraw = false; search:SetText(""); search:ClearFocus(); GameTooltip:Hide() end)
end

events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_UPDATE")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("SKILL_LINES_CHANGED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:SetScript("OnEvent", function(_, event, _, success)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if pendingItemInfo and success then
            pendingItemInfo = false
            if initialized and MerchantFrame:IsShown() then redraw = true end
        end
        return
    end
    if event == "MERCHANT_SHOW" then
        initialize()
        clearStates()
        recipeColors = {}
        metadata = {}
        if search then search:SetText("") end
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" or event == "SKILL_LINES_CHANGED" then
        clearStates()
        recipeColors = {}
    end
    if initialized and MerchantFrame:IsShown() then redraw = true end
end)

events:SetScript("OnUpdate", function(_, elapsed)
    if not initialized or not MerchantFrame:IsShown() then return end
    elapsedSinceDraw = elapsedSinceDraw + elapsed
    if settings.usable or not settings.collected then
        local index = scanQueue[scanHead]
        if index then
            local known, blocked, knownRecipe = scanItemState(index)
            stateCache[index] = {known = known, blocked = blocked, knownRecipe = knownRecipe}
            scanHead = scanHead + 1
            redraw = true
        end
    end
    if redraw and elapsedSinceDraw >= 0.15 then
        redraw = false
        elapsedSinceDraw = 0
        MerchantFrame_Update()
    end
end)
