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

do
if not VendorPlusSellLoaded then
VendorPlusSellLoaded=true
local L=VendorPlusL
local events = CreateFrame("Frame")
local button, preview, summary, sellButton, content
local rows, candidates, automaticCandidates = {}, {}, {}
local selling, token = false, 0
local page, pageText, previousPage, nextPage = 1
local renderPage
local slots = {
    INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3}, INVTYPE_CHEST = {5},
    INVTYPE_ROBE = {5}, INVTYPE_WAIST = {6}, INVTYPE_LEGS = {7}, INVTYPE_FEET = {8},
    INVTYPE_WRIST = {9}, INVTYPE_HAND = {10}, INVTYPE_FINGER = {11, 12}, INVTYPE_TRINKET = {13, 14},
    INVTYPE_CLOAK = {15}, INVTYPE_WEAPON = {16, 17}, INVTYPE_2HWEAPON = {16},
    INVTYPE_WEAPONMAINHAND = {16}, INVTYPE_WEAPONOFFHAND = {17}, INVTYPE_SHIELD = {17},
    INVTYPE_HOLDABLE = {17}, INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18}, INVTYPE_THROWN = {18},
}

local function options()
    VendorPlusDB = VendorPlusDB or {}
    VendorPlusDB.sell = VendorPlusDB.sell or {}
    local db = VendorPlusDB.sell
    if db.grey == nil then db.grey = true end
    if db.uncommon == nil then db.uncommon = true end
    if db.rare == nil then db.rare = false end
    if db.soulboundMenuVersion~=1 then
        if not db.soulbound then db.uncommon,db.rare=false,false end
        db.soulbound=nil
        db.soulboundMenuVersion=1
    end
    if db.consumableMenuVersion~=1 then
        db.lowConsumables=not not (db.lowConsumables or db.lowHealthPotions or db.lowManaPotions)
        local class
        if UnitClass then local _;_,class=UnitClass("player") end
        if db.sellManaConsumables==nil then
            db.sellManaConsumables=db.manaWithoutMana~=false and (class=="WARRIOR" or class=="ROGUE") or false
        end
        db.lowHealthPotions,db.lowManaPotions,db.manaWithoutMana=nil,nil,nil
        db.consumableMenuVersion=1
    end
    if db.lowConsumables == nil then db.lowConsumables = false end
    if db.sellManaConsumables == nil then db.sellManaConsumables = false end
    db.elixirs = nil
    if db.classUnusableDefaultVersion~=1 then
        db.classUnusable=true
        db.classUnusableDefaultVersion=1
    end
    if db.classUnusable == nil then db.classUnusable = true end
    if db.downgrades == nil then db.downgrades = true end
    db.blacklist = db.blacklist or {}
    return db
end

local function details(link)
    local name, _, quality, itemLevel, requiredLevel, _, _, _, equipLoc, _, price, classID, subclassID, bindType = C_Item.GetItemInfo(link)
    if not name then return end
    if C_Item.GetDetailedItemLevelInfo then itemLevel = C_Item.GetDetailedItemLevelInfo(link) or itemLevel end
    return {quality = quality, level = itemLevel, requiredLevel = requiredLevel, equipLoc = equipLoc, price = price,
        classID = classID, subclassID = subclassID, bindType = bindType}
end

local function lowerThanEquipped(data)
    local compareSlots = slots[data.equipLoc]
    if not compareSlots or not data.level then return false end
    for _, slot in ipairs(compareSlots) do
        local link = GetInventoryItemLink("player", slot)
        local equipped = link and details(link)
        if not equipped or not equipped.level or equipped.level <= data.level
            or equipped.classID ~= data.classID or equipped.subclassID ~= data.subclassID then return false end
        local sameType = equipped.equipLoc == data.equipLoc
            or ((equipped.equipLoc == "INVTYPE_ROBE" or equipped.equipLoc == "INVTYPE_CHEST")
                and (data.equipLoc == "INVTYPE_ROBE" or data.equipLoc == "INVTYPE_CHEST"))
        if not sameType then return false end
    end
    return true
end

local classArmor={WARRIOR=4,PALADIN=4,HUNTER=3,ROGUE=2,PRIEST=1,SHAMAN=3,MAGE=1,WARLOCK=1,DRUID=2}
local classWeapons={
    WARRIOR={0,1,2,3,4,5,6,7,8,10,13,15,16,18,20},
    PALADIN={0,1,4,5,6,7,8,20},
    HUNTER={0,1,2,3,6,7,8,10,13,15,16,18,20},
    ROGUE={0,2,3,4,7,13,15,16,18,20},
    PRIEST={4,10,15,19,20},
    SHAMAN={0,1,4,5,10,13,15,20},
    MAGE={7,10,15,19,20},
    WARLOCK={7,10,15,19,20},
    DRUID={4,5,6,10,13,15,20},
}
local weaponTypes={[0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,[10]=true,[13]=true,[15]=true,[16]=true,[18]=true,[19]=true,[20]=true}

local function classCannotUse(data)
    if not UnitClass then return false end
    local _,class=UnitClass("player")
    if not class or not data.subclassID then return false end
    if data.classID==4 then
        if data.equipLoc=="INVTYPE_CLOAK" then return false end
        if data.subclassID>=1 and data.subclassID<=4 and classArmor[class] then
            return data.subclassID>classArmor[class]
        end
        if data.subclassID==6 and classArmor[class] then
            return class~="WARRIOR" and class~="PALADIN" and class~="SHAMAN"
        end
        local relicClasses={[7]="PALADIN",[8]="DRUID",[9]="SHAMAN"}
        if relicClasses[data.subclassID] and classArmor[class] then return class~=relicClasses[data.subclassID] end
    elseif data.classID==2 and weaponTypes[data.subclassID] and classWeapons[class] then
        for _,subclass in ipairs(classWeapons[class]) do
            if subclass==data.subclassID then return false end
        end
        return true
    end
    return false
end

local bodyArmorSlots={INVTYPE_HEAD=true,INVTYPE_SHOULDER=true,INVTYPE_CHEST=true,INVTYPE_ROBE=true,
    INVTYPE_WAIST=true,INVTYPE_LEGS=true,INVTYPE_FEET=true,INVTYPE_WRIST=true,INVTYPE_HAND=true}
local physicalStats={"ITEM_MOD_STRENGTH_SHORT","ITEM_MOD_AGILITY_SHORT","ITEM_MOD_ATTACK_POWER_SHORT",
    "ITEM_MOD_RANGED_ATTACK_POWER_SHORT","ITEM_MOD_HIT_RATING_SHORT","ITEM_MOD_CRIT_RATING_SHORT",
    "ITEM_MOD_MELEE_HIT_RATING_SHORT","ITEM_MOD_MELEE_CRIT_RATING_SHORT","ITEM_MOD_RANGED_HIT_RATING_SHORT",
    "ITEM_MOD_RANGED_CRIT_RATING_SHORT","ITEM_MOD_HASTE_RATING_SHORT","ITEM_MOD_EXPERTISE_RATING_SHORT",
    "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT","ITEM_MOD_DODGE_RATING_SHORT","ITEM_MOD_PARRY_RATING_SHORT",
    "ITEM_MOD_BLOCK_RATING_SHORT","ITEM_MOD_BLOCK_VALUE_SHORT"}
local casterStats={"ITEM_MOD_INTELLECT_SHORT","ITEM_MOD_SPIRIT_SHORT","ITEM_MOD_SPELL_POWER_SHORT",
    "ITEM_MOD_SPELL_HEALING_DONE_SHORT","ITEM_MOD_SPELL_DAMAGE_DONE_SHORT","ITEM_MOD_SPELL_HIT_RATING_SHORT",
    "ITEM_MOD_SPELL_CRIT_RATING_SHORT","ITEM_MOD_MANA_REGENERATION_SHORT"}

local function smartDowngrade(data,link)
    local class
    if UnitClass then local _;_,class=UnitClass("player") end
    if class and data.classID==4 and bodyArmorSlots[data.equipLoc] and classArmor[class] then
        local preferred=classArmor[class]
        local knows=IsPlayerSpell or IsSpellKnown
        if class=="WARRIOR" or class=="PALADIN" then
            if not knows or not knows(750) then preferred=3 end
        elseif class=="HUNTER" or class=="SHAMAN" then
            if not knows or not knows(8737) then preferred=2 end
        end
        if data.subclassID and data.subclassID>=1 and data.subclassID<preferred then
            return true,L.REASON_ARMOR
        end
    end
    if class=="WARRIOR" or class=="ROGUE" then
        local getStats=C_Item.GetItemStats or GetItemStats
        local stats=getStats and getStats(link)
        if stats then
            local caster=false
            for _,key in ipairs(casterStats) do if (stats[key] or 0)>0 then caster=true;break end end
            if caster then
                local physical=false
                for _,key in ipairs(physicalStats) do if (stats[key] or 0)>0 then physical=true;break end end
                if not physical then return true,L.REASON_CASTER end
            end
        end
    end
    if lowerThanEquipped(data) then return true,L.REASON_ILVL end
    return false
end

local function gearCandidate(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or info.isLocked or not info.isBound or info.hasLoot or info.hasNoValue then return end
    local db = options()
    local selectedQuality=(info.quality == 2 and db.uncommon) or (info.quality == 3 and db.rare)
    if not selectedQuality and not db.classUnusable then return end
    local quest = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
    if quest and quest.isQuestItem then return end
    local refund = C_Container.GetContainerItemPurchaseInfo and C_Container.GetContainerItemPurchaseInfo(bag, slot, false)
    if refund and (refund.refundSeconds or 0) > 0 then return end
    local data = details(info.hyperlink)
    if not data or (data.classID ~= 2 and data.classID ~= 4) or not data.equipLoc or data.equipLoc==""
        or not data.price or data.price <= 0 or (data.bindType ~= 1 and data.bindType ~= 2) then return end
    local incompatible=classCannotUse(data)
    if not (db.classUnusable and incompatible) and (not selectedQuality or not slots[data.equipLoc]) then return end
    if not incompatible and UnitLevel and (not data.requiredLevel or data.requiredLevel>UnitLevel("player")) then return end
    local downgrade,reason=false,nil
    if db.downgrades and not (db.classUnusable and incompatible) then
        downgrade,reason=smartDowngrade(data,info.hyperlink)
        if not downgrade then return end
    end
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local guid = C_Item.GetItemGUID(location)
    if not guid then return end
    return {bag = bag, slot = slot, guid = guid, id = info.itemID, link = info.hyperlink,
        price = data.price * (info.stackCount or 1), level = data.level, classUnusable = incompatible, quality = info.quality, reason = reason}
end

local healingRanks={{118,1},{858,3},{929,12},{1710,21},{3928,35},{13446,45}}
local manaRanks={{2455,5},{3385,14},{3827,22},{6149,31},{13443,41},{13444,49}}
local potionFamily={}
for _,rank in ipairs(healingRanks) do potionFamily[rank[1]]="health" end
for _,rank in ipairs(manaRanks) do potionFamily[rank[1]]="mana" end

local function bestPotionLevel(ranks,playerLevel)
    local best=-1
    for _,rank in ipairs(ranks) do
        local name,_,_,_,level,_,_,_,_,_,_,classID,subclassID=C_Item.GetItemInfo(rank[1])
        if not name or classID~=0 or subclassID~=1 then level=rank[2] end
        level=level or rank[2]
        if level<=playerLevel then best=math.max(best,level) end
    end
    return best
end

local function consumableCandidate(info,db)
    local _,_,_,_,level,_,_,_,_,_,_,classID,subclassID=C_Item.GetItemInfo(info.hyperlink)
    if classID~=0 or not level then return false end
    local playerLevel=UnitLevel("player")
    if subclassID==5 then
        local spell=C_Item.GetItemSpell(info.hyperlink)
        local food,drink=C_Item.GetItemSpell(117),C_Item.GetItemSpell(159)
        local isFood=spell and food and spell==food
        local isDrink=spell and drink and (spell==drink or spell:find(drink,1,true))
        if db.sellManaConsumables and isDrink then return true end
        local best=playerLevel<5 and 1 or (math.floor((playerLevel-5)/10)*10+5)
        return db.lowConsumables and (isFood or isDrink) and math.max(1,level)<best
    elseif subclassID==1 then
        local family=potionFamily[info.itemID]
        if not family and C_Item.GetItemSpell then
            local spell=C_Item.GetItemSpell(info.hyperlink)
            local mana=C_Item.GetItemSpell(2455)
            local healing=C_Item.GetItemSpell(118)
            if spell and mana and spell==mana then family="mana"
            elseif spell and healing and spell==healing then family="health" end
        end
        if family=="mana" and db.sellManaConsumables then return true end
        if family=="health" and db.lowConsumables then return level<bestPotionLevel(healingRanks,playerLevel) end
        if family=="mana" and db.lowConsumables then return level<bestPotionLevel(manaRanks,playerLevel) end
    end
    return false
end

local function candidate(bag,slot)
    local db=options()
    local info=C_Container.GetContainerItemInfo(bag,slot)
    if not info or info.isLocked or info.hasLoot or info.hasNoValue then return end
    if db.uncommon or db.rare or db.classUnusable then
        local gear=gearCandidate(bag,slot)
        if gear then return gear end
    end
    local match=db.grey and info.quality==0
    if not match and info.quality==1 and (db.lowConsumables or db.sellManaConsumables) then
        match=consumableCandidate(info,db)
    end
    if not match then return end
    local quest=C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag,slot)
    if quest and quest.isQuestItem then return end
    local refund=C_Container.GetContainerItemPurchaseInfo and C_Container.GetContainerItemPurchaseInfo(bag,slot,false)
    if refund and (refund.refundSeconds or 0)>0 then return end
    local data=details(info.hyperlink)
    if not data or not data.price or data.price<=0 then return end
    local guid=C_Item.GetItemGUID(ItemLocation:CreateFromBagAndSlot(bag,slot))
    if not guid then return end
    return {bag=bag,slot=slot,guid=guid,id=info.itemID,link=info.hyperlink,price=data.price*(info.stackCount or 1),level=data.level,quality=info.quality}
end

local function updateSummary()
    local count, total = 0, 0
    local db = options()
    for _,list in ipairs({automaticCandidates,candidates}) do
        for _,item in ipairs(list) do
            if not db.blacklist[item.id] then
                count=count+1
                total=total+item.price
            end
        end
    end
    summary:SetText(L.TOTAL..VendorPlusMoneyText(total))
    sellButton:SetEnabled(count > 0 and not selling)
end

local function collect()
    candidates,automaticCandidates = {},{}
    for _,bag in ipairs(VendorPlusCarriedBags()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local item = gearCandidate(bag, slot)
            if item then
                candidates[#candidates + 1] = item
            else
                local automatic=candidate(bag,slot)
                if automatic and not automatic.classUnusable and automatic.quality and automatic.quality<=1 then
                    automaticCandidates[#automaticCandidates+1]=automatic
                end
            end
        end
    end
end

renderPage=function()
    local db = options()
    for i=1,6 do
        local item=candidates[(page-1)*6+i]
        local row = rows[i]
        if not row then
            row = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
            rows[i] = row
            row:SetSize(24, 24)
            row:SetHitRectInsets(0,-296,-8,-8)
            row.unusableShade=row:CreateTexture(nil,"BACKGROUND")
            row.unusableShade:SetSize(320,42)
            row.unusableShade:SetPoint("LEFT",row,"LEFT",0,0)
            row.unusableShade:SetColorTexture(0.8,0.05,0.05,0.14)
            row:SetPoint("TOPLEFT", 0, -9-(i - 1) * 44)
            row.icon=row:CreateTexture(nil,"ARTWORK")
            row.icon:SetSize(30,30)
            row.icon:SetPoint("LEFT",row,"RIGHT",4,0)
            row.iconBorder=row:CreateTexture(nil,"OVERLAY")
            row.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            row.iconBorder:SetSize(48,48)
            row.iconBorder:SetPoint("CENTER",row.icon)
            row.price=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            row.price:SetPoint("LEFT",row,"LEFT",245,0)
            row.price:SetWidth(74)
            row.price:SetJustifyH("RIGHT")
            row.detail=row:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
            row.detail:SetPoint("TOPLEFT",row,"TOPRIGHT",42,-13)
            row.detail:SetWidth(170)
            row.detail:SetWordWrap(false)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("TOPLEFT", row, "TOPRIGHT", 42, 2)
            row.label:SetWidth(170)
            row.label:SetWordWrap(false)
            row.label:SetJustifyH("LEFT")
            row:SetScript("OnClick", function(self)
                options().blacklist[self.item.id] = not self:GetChecked() or nil
                for _, other in ipairs(rows) do
                    if other.item and other.item.id == self.item.id then other:SetChecked(self:GetChecked()) end
                end
                updateSummary()
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.item.link)
                if self.item.reason then GameTooltip:AddLine(self.item.reason,1,0.82,0,true) end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        row.item = item
        if item then
        row:SetChecked(not db.blacklist[item.id])
        local itemInfo=C_Container.GetContainerItemInfo(item.bag,item.slot)
        row.icon:SetTexture(itemInfo and itemInfo.iconFileID)
        row.unusableShade:SetShown(not not item.classUnusable)
        row.icon:SetVertexColor(1,item.classUnusable and 0.4 or 1,item.classUnusable and 0.4 or 1)
        local name=C_Item.GetItemInfo(item.link)
        row.label:SetText(item.classUnusable and ("|cffff4040"..(name or L.ITEM).."|r") or item.link)
        row.detail:SetText((item.classUnusable and ("|cffff4040"..L.CANNOT_EQUIP.."|r  ") or "")..string.format(L.ILVL_FMT,item.level or "?")..((itemInfo and (itemInfo.stackCount or 1)>1) and ("  ×"..itemInfo.stackCount) or ""))
        row.price:SetText(VendorPlusMoneyText(item.price))
        row:Show()
        row:Enable()
        else row:Hide() end
    end
    local pages=math.max(1,math.ceil(#candidates/6))
    pageText:SetText(string.format(L.PAGE_FMT,page,pages))
    previousPage:SetEnabled(page>1)
    nextPage:SetEnabled(page<pages)
    updateSummary()
end

local function populate()
    collect()
    page=1
    preview:ClearAllPoints()
    preview:SetPoint("CENTER",UIParent,"CENTER",0,0)
    renderPage()
end

local function sellBatch(batch,onDone)
    selling = true
    token = token + 1
    local currentToken, nextItem = token, 1
    local function step()
        if token ~= currentToken then return end
        if not MerchantFrame:IsShown() or MerchantFrame.selectedTab ~= 1
            or (InCombatLockdown and InCombatLockdown()) or (CursorHasItem and CursorHasItem()) then
            selling = false
            preview:Hide()
            return
        end
        local item = batch[nextItem]
        if not item then
            selling = false
            if onDone then onDone() end
            return
        end
        nextItem = nextItem + 1
        local now = candidate(item.bag, item.slot)
        if now and now.guid == item.guid and not options().blacklist[now.id] then
            C_Container.UseContainerItem(item.bag, item.slot)
        end
        C_Timer.After(0.2, step)
    end
    step()
end

local function sellSelected()
    if selling or not MerchantFrame:IsShown() or MerchantFrame.selectedTab ~= 1
        or (InCombatLockdown and InCombatLockdown()) or (CursorHasItem and CursorHasItem()) then return end
    local batch = {}
    for _,list in ipairs({automaticCandidates,candidates}) do
        for _,item in ipairs(list) do
            if not options().blacklist[item.id] then batch[#batch+1]=item end
        end
    end
    preview:Hide()
    sellButton:Disable()
    for _, row in ipairs(rows) do row:Disable() end
    sellBatch(batch)
end

local function sellAutomaticAndReviewGear()
    if selling or not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1
        or (InCombatLockdown and InCombatLockdown()) or (CursorHasItem and CursorHasItem()) then return end
    preview:Hide()
    populate()
    if #candidates>0 then
        preview:Show()
        return
    end
    local automatic={}
    for _,item in ipairs(automaticCandidates) do
        if not options().blacklist[item.id] then automatic[#automatic+1]=item end
    end
    sellBatch(automatic)
end

local function createPreview()
    preview = CreateFrame("Frame", "VendorPlusSellPreview", UIParent, "ButtonFrameTemplate")
    preview:SetSize(370, 424)
    preview:SetPoint("CENTER",UIParent,"CENTER",0,0)
    preview:SetFrameStrata("DIALOG")
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(preview) end
    preview:SetTitle(L.SELL_ITEMS)
    if preview.TitleContainer then
        preview.TitleContainer:ClearAllPoints()
        preview.TitleContainer:SetPoint("TOPLEFT",preview,"TOPLEFT",16,-2)
        preview.TitleContainer:SetPoint("TOPRIGHT",preview,"TOPRIGHT",-16,-2)
        preview.TitleContainer:SetHeight(20)
        preview.TitleContainer.TitleText:SetJustifyH("CENTER")
    end
    if preview.Inset then
        preview.Inset:ClearAllPoints()
        preview.Inset:SetPoint("TOPLEFT",16,-59)
        preview.Inset:SetPoint("BOTTOMRIGHT",-16,98)
    end
    preview:EnableMouse(true)
    preview:SetMovable(true)
    preview:RegisterForDrag("LeftButton")
    preview:SetScript("OnDragStart", preview.StartMoving)
    preview:SetScript("OnDragStop", preview.StopMovingOrSizing)
    preview:SetScript("OnHide", function() GameTooltip:Hide() end)
    table.insert(UISpecialFrames, "VendorPlusSellPreview")
    local help = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 16, -36)
    help:SetWidth(334)
    help:SetJustifyH("LEFT")
    help:SetText(L.KEEP_HINT)
    content = CreateFrame("Frame", nil, preview)
    content:SetPoint("TOPLEFT",22,-62)
    content:SetSize(320,264)
    local function pageButton(direction,side,label)
        local pageButton=CreateFrame("Button",nil,preview)
        pageButton:SetSize(32,32)
        pageButton:SetPoint(side=="LEFT" and "BOTTOMLEFT" or "BOTTOMRIGHT",side=="LEFT" and 22 or -22,64)
        local path="Interface\\Buttons\\UI-SpellbookIcon-"..direction.."Page-"
        pageButton:SetNormalTexture(path.."Up")
        pageButton:SetPushedTexture(path.."Down")
        pageButton:SetDisabledTexture(path.."Disabled")
        pageButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight","ADD")
        local background=pageButton:CreateTexture(nil,"BACKGROUND")
        background:SetTexture("Interface\\Buttons\\UI-PageButton-Background")
        background:SetSize(32,32)
        background:SetPoint("CENTER",0,1)
        local text=pageButton:CreateFontString(nil,"BACKGROUND","GameFontNormal")
        text:SetText(label)
        if side=="LEFT" then text:SetPoint("LEFT",pageButton,"RIGHT",0,0)
        else text:SetPoint("RIGHT",pageButton,"LEFT",-3,0) end
        return pageButton
    end
    previousPage=pageButton("Prev","LEFT",L.PREV)
    previousPage:SetScript("OnClick",function() if page>1 then page=page-1;renderPage() end end)
    nextPage=pageButton("Next","RIGHT",L.NEXT)
    nextPage:SetScript("OnClick",function() if page<math.ceil(#candidates/6) then page=page+1;renderPage() end end)
    pageText=preview:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    pageText:SetPoint("CENTER",preview,"BOTTOM",0,80)
    summary = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("BOTTOM", 0, 49)
    sellButton = CreateFrame("Button", nil, preview, "UIPanelButtonTemplate")
    sellButton:SetSize(120, 24)
    sellButton:SetPoint("BOTTOMRIGHT", -22, 16)
    sellButton:SetText(L.ACCEPT)
    sellButton:SetScript("OnClick", sellSelected)
    local cancel = CreateFrame("Button", nil, preview, "UIPanelButtonTemplate")
    cancel:SetSize(120, 24)
    cancel:SetPoint("BOTTOMLEFT", 22, 16)
    cancel:SetText(L.DECLINE)
    cancel:SetScript("OnClick", function() preview:Hide() end)
    preview:Hide()
end

local function initialize()
    if button or not MerchantSellAllJunkButton then return end
    options()
    createPreview()
    button = MerchantSellAllJunkButton
    if not button then return end
    local function positionButton()
        button:SetShown(MerchantFrame.selectedTab ~= 2)
        button:Enable()
        if button.Icon then button.Icon:SetDesaturated(false) end
    end
    positionButton()
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.SELL_ITEMS)
        GameTooltip:AddLine(L.SELL_ACTION, 1, 1, 1)
        GameTooltip:AddLine(L.OPTIONS_HINT, 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnClick", function(self, mouse)
        if selling then return end
        if mouse == "RightButton" then
            MenuUtil.CreateContextMenu(self, function(_, root)
                local db = options()
                local function toggle(label,key,description)
                    local entry=root:CreateCheckbox(label,function() return db[key] end,function() db[key]=not db[key];if preview:IsShown() then populate() end end)
                    if description then entry:SetTooltip(function(tooltip) tooltip:AddLine(description,1,1,1,true) end) end
                end
                toggle(L.GREY_ITEMS,"grey")
                root:CreateDivider()
                root:CreateTitle(L.SOULBOUND)
                toggle(string.format(L.SELL_INCOMPAT_FMT,"|cffff4040"..L.INCOMPATIBLE.."|r"),"classUnusable",L.HINT_INCOMPAT)
                toggle(string.format(L.SELL_QUALITY_FMT,"|cff1eff00"..L.UNCOMMON.."|r"),"uncommon")
                toggle(string.format(L.SELL_QUALITY_FMT,"|cff0070dd"..L.RARE.."|r"),"rare")
                toggle(L.SELL_DOWNGRADES,"downgrades",L.HINT_DOWNGRADES)
                root:CreateDivider()
                root:CreateTitle(L.CONSUMABLES)
                toggle(L.SELL_LOW,"lowConsumables",L.HINT_LOW)
                toggle(L.SELL_MANA,"sellManaConsumables",L.HINT_SELL_MANA)
            end)
        else
            sellAutomaticAndReviewGear()
        end
    end)
    MerchantFrame:HookScript("OnHide", function() token=token+1;selling=false;preview:Hide() end)
    hooksecurefunc("MerchantFrame_Update", positionButton)
end

events:RegisterEvent("MERCHANT_SHOW")
events:SetScript("OnEvent", initialize)

end

end

do
if not VendorPlusBulkBuyLoaded then
VendorPlusBulkBuyLoaded=true
local L=VendorPlusL
local events = CreateFrame("Frame")
local dialog, input, title, amountText, priceText, unitText, okay, cancel
local current, running, generation = nil, false, 0

local function info(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then return C_MerchantFrame.GetItemInfo(index) end
    local name, texture, price, stackCount, numAvailable, isPurchasable, isUsable, hasExtendedCost = GetMerchantItemInfo(index)
    return {name=name,texture=texture,price=price,stackCount=stackCount,numAvailable=numAvailable,isPurchasable=isPurchasable,hasExtendedCost=hasExtendedCost}
end

local function quote(index)
    local data = info(index)
    if not data or not data.name then return end
    local result = {index=index,link=GetMerchantItemLink(index),name=data.name,pack=math.max(1,data.stackCount or 1),
        price=data.price or 0,available=data.numAvailable, costs={}}
    if not result.link then return end
    if data.hasExtendedCost then
        for n=1,GetMerchantItemCostInfo(index) do
            local texture, count, link, name = GetMerchantItemCostItem(index,n)
            if not count then return end
            result.costs[#result.costs+1] = {texture=texture,count=count,link=link,name=name}
        end
    end
    local key = {result.link,tostring(result.pack),tostring(result.price)}
    for _,cost in ipairs(result.costs) do
        key[#key+1] = tostring(cost.link or cost.name or cost.texture)..":"..cost.count
    end
    result.key = table.concat(key,"|")
    return result
end

local function costsText(data, packs)
    local text = {}
    if data.price > 0 then text[#text+1] = VendorPlusMoneyText(data.price*packs) end
    for _,cost in ipairs(data.costs) do
        text[#text+1] = string.format("%d |T%s:14|t",cost.count*packs,tostring(cost.texture or 134400))
    end
    return #text>0 and table.concat(text,"  ") or (L.FREE)
end

local function affordable(data,packs)
    if data.price*packs>GetMoney() then return false end
    if data.available and data.available>=0 and packs*data.pack>data.available then return false end
    for _,cost in ipairs(data.costs) do
        if cost.link then
            local currencyID = tonumber(cost.link:match("currency:(%d+)"))
            if currencyID and C_CurrencyInfo then
                local currency = C_CurrencyInfo.GetCurrencyInfo(currencyID)
                if currency and currency.quantity<cost.count*packs then return false end
            elseif not cost.name then
                local getCount = C_Item and C_Item.GetItemCount or GetItemCount
                if getCount and getCount(cost.link,false,false,true)<cost.count*packs then return false end
            end
        end
    end
    return true
end

local function batchSize(data,remaining)
    local stack = math.max(data.pack,GetMerchantItemMaxStack(data.index) or data.pack)
    return math.min(remaining,math.max(data.pack,math.floor(stack/data.pack)*data.pack))
end

local function stop()
    generation=generation+1
    running=false
end

local function buy(data,packs)
    if running or not packs or packs<1 or packs>9999 or packs~=math.floor(packs) or not affordable(data,packs) then return end
    if not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1 then return end
    local remaining=packs*data.pack
    generation=generation+1
    local run=generation
    running=true
    local function step()
        if run~=generation then return end
        if not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1 or (InCombatLockdown and InCombatLockdown())
            or (CursorHasItem and CursorHasItem()) then stop(); return end
        if remaining<=0 then stop(); return end
        local now=quote(data.index)
        if not now or now.key~=data.key then stop(); return end
        local count=batchSize(now,remaining)
        if not affordable(now,count/now.pack) then stop(); return end
        remaining=remaining-count
        BuyMerchantItem(data.index,count)
        if run==generation then C_Timer.After(0.25,step) end
    end
    step()
end

local proxy,footer,costLabel
local opening=false
local hookedButtons=setmetatable({}, {__mode="k"})
local function isMerchantButton(owner)
    for slot=1,MERCHANT_ITEMS_PER_PAGE or 10 do
        if owner==_G["MerchantItem"..slot.."ItemButton"] then return true end
    end
    return false
end

local function priceUpdate()
    if not proxy or StackSplitFrame.owner~=proxy or not current then return end
    local packs=math.max(1,math.floor((StackSplitFrame.split or current.pack)/current.pack))
    costLabel:SetText((current.pack>1 and L.PER_PACK or L.PER_ITEM)..costsText(current,1)..("\n"..L.TOTAL)..costsText(current,packs))
    if costLabel.GetStringHeight then footer:SetHeight(math.max(44,(costLabel:GetStringHeight() or 0)+16)) end
    footer:Show()
end

local function open(owner)
    if opening or running or not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1 then return end
    local data=quote(owner:GetID())
    if not data then return end
    if not proxy then
        proxy=CreateFrame("Frame",nil,UIParent)
        proxy:SetSize(1,1)
        proxy.SplitStack=function(_,split)
            local data=current
            if data and split%data.pack==0 then buy(data,split/data.pack) end
        end
        footer=CreateFrame("Frame",nil,StackSplitFrame,"BackdropTemplate")
        footer:SetPoint("TOPLEFT",StackSplitFrame,"BOTTOMLEFT",4,6)
        footer:SetPoint("TOPRIGHT",StackSplitFrame,"BOTTOMRIGHT",-4,6)
        footer:SetHeight(44)
        footer:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
        costLabel=footer:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        costLabel:SetPoint("CENTER")
        costLabel:SetWidth(160)
        StackSplitFrame:HookScript("OnUpdate",function(self)
            if self.owner==proxy and current then
                if footer.lastSplit~=self.split then footer.lastSplit=self.split;priceUpdate() end
            else footer:Hide() end
        end)
    end
    local low,high=0,9999
    while low<high do
        local mid=math.ceil((low+high)/2)
        if affordable(data,mid) then low=mid else high=mid-1 end
    end
    if low<1 then return end
    current=data
    proxy:ClearAllPoints()
    proxy:SetPoint("TOPLEFT",owner,"TOPLEFT")
    opening=true
    StackSplitFrame:OpenStackSplitFrame(low*data.pack,proxy,"BOTTOMLEFT","TOPLEFT",data.pack)
    opening=false
    footer.lastSplit=nil
    priceUpdate()
end

local function chatHasFocus()
    local edit=ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    return edit and edit.HasFocus and edit:HasFocus()
end

local function attachButtons()
    for slot=1,MERCHANT_ITEMS_PER_PAGE or 10 do
        local button=_G["MerchantItem"..slot.."ItemButton"]
        if button and not hookedButtons[button] then
            hookedButtons[button]=true
            button:HookScript("OnClick",function(self,mouse)
                if mouse=="LeftButton" and IsShiftKeyDown() and not (IsControlKeyDown and IsControlKeyDown())
                    and not (IsAltKeyDown and IsAltKeyDown()) and not chatHasFocus() then open(self) end
            end)
        end
    end
end

local nativeHint
local function isBuyHint(line)
    local text=line and line.leftText
    if not text then return false end
    local plain=text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower()
    return plain==L.BUY_HINT:lower() or plain:find("buy a different amount",1,true)
end

local function hintTemplate(data)
    if not data or not data.lines then return end
    for index,line in ipairs(data.lines) do
        if isBuyHint(line) then
            return {trailing=#data.lines-index,text=line.leftText,color=line.leftColor,wrap=line.wrapText}
        end
    end
end

local function insertBuyHint(self,data)
    if self~=GameTooltip or not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1
        or not data or not data.lines or not isMerchantButton(self:GetOwner()) then return end
    local existing=hintTemplate(data)
    if existing then nativeHint=existing;return end
    if not nativeHint and C_TooltipInfo and C_TooltipInfo.GetMerchantItem then
        for index=1,GetMerchantNumItems() do
            if (GetMerchantItemMaxStack(index) or 1)>1 then
                nativeHint=hintTemplate(C_TooltipInfo.GetMerchantItem(index))
                if nativeHint then break end
            end
        end
    end
    nativeHint=nativeHint or {trailing=0,text=L.BUY_HINT,color=GREEN_FONT_COLOR}
    local position=math.max(1,#data.lines-nativeHint.trailing+1)
    table.insert(data.lines,position,{type=Enum.TooltipDataLineType.None,leftText=nativeHint.text,
        leftColor=nativeHint.color or GREEN_FONT_COLOR,wrapText=nativeHint.wrap or false})
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPreCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPreCall(Enum.TooltipDataType.Item,insertBuyHint)
else
    hooksecurefunc(GameTooltip,"SetMerchantItem",function(self)
        if self~=GameTooltip or not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1 then return end
        for line=1,self:NumLines() do
            local text=_G[self:GetName().."TextLeft"..line]
            if text and text:GetText() and isBuyHint({leftText=text:GetText()}) then return end
        end
        self:AddLine(("|cff00ff00"..L.BUY_HINT.."|r"))
        self:Show()
    end)
end

local hookedSplit=false
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("UI_ERROR_MESSAGE")
events:SetScript("OnEvent",function(_,event)
    if event=="MERCHANT_CLOSED" then
        stop()
        if proxy and StackSplitFrame.owner==proxy then StackSplitFrame:Hide() end
    elseif event=="UI_ERROR_MESSAGE" and running then stop()
    elseif event=="MERCHANT_SHOW" then
        nativeHint=nil
        stop()
        attachButtons()
        if not hookedSplit then
            hookedSplit=true
            hooksecurefunc(StackSplitFrame,"OpenStackSplitFrame",function(_,_,owner)
                if not opening and isMerchantButton(owner) then open(owner) end
            end)
        end
    end
end)

end

end

do
if not VendorPlusSellAllLoaded then
VendorPlusSellAllLoaded=true
local L=VendorPlusL
local events=CreateFrame("Frame")
local active, generation=false,0
local hookedButtons=setmetatable({}, {__mode="k"})
local tooltipMarker=("|cff00ff00"..L.SELL_HINT.."|r")

local function merchantOpen()
    return MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab==1
end

local function sellable(bag,slot,itemID)
    local info=C_Container.GetContainerItemInfo(bag,slot)
    if not info or info.itemID~=itemID or info.isLocked or info.hasLoot or info.hasNoValue then return end
    local quest=C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag,slot)
    if quest and quest.isQuestItem then return end
    local refund=C_Container.GetContainerItemPurchaseInfo and C_Container.GetContainerItemPurchaseInfo(bag,slot,false)
    if refund and (refund.refundSeconds or 0)>0 then return end
    local name,_,_,_,_,_,_,_,_,_,price=C_Item.GetItemInfo(info.hyperlink)
    if not name or not price or price<=0 then return end
    local guid=C_Item.GetItemGUID(ItemLocation:CreateFromBagAndSlot(bag,slot))
    if not guid then return end
    return {bag=bag,slot=slot,id=itemID,guid=guid,link=info.hyperlink,count=info.stackCount or 1,price=price}
end

local function collect(itemID)
    local plan={items={},count=0,total=0,id=itemID}
    for _,bag in ipairs(VendorPlusCarriedBags()) do
        for slot=1,C_Container.GetContainerNumSlots(bag) do
            local item=sellable(bag,slot,itemID)
            if item then
                plan.items[#plan.items+1]=item
                plan.count=plan.count+item.count
                plan.total=plan.total+item.price*item.count
                plan.link=plan.link or item.link
            end
        end
    end
    return plan
end

local function sameItem(before,after)
    return after and before.guid==after.guid and before.count==after.count
        and before.price==after.price and before.link==after.link
end

local function stop()
    active=false
    generation=generation+1
end

local function accept(plan)
    if active or not merchantOpen() or plan.generation~=generation
        or (InCombatLockdown and InCombatLockdown()) or (CursorHasItem and CursorHasItem()) then return end
    for _,item in ipairs(plan.items) do
        if not sameItem(item,sellable(item.bag,item.slot,item.id)) then
            print(L.INVENTORY_CHANGED)
            return
        end
    end
    active=true
    local run,index=generation,1
    local function step()
        if run~=generation then return end
        if not merchantOpen() or (InCombatLockdown and InCombatLockdown())
            or (CursorHasItem and CursorHasItem()) then stop(); return end
        local item=plan.items[index]
        if not item then stop(); return end
        index=index+1
        if not sameItem(item,sellable(item.bag,item.slot,item.id)) then stop(); return end
        C_Container.UseContainerItem(item.bag,item.slot)
        if run==generation then C_Timer.After(0.2,step) end
    end
    step()
end

StaticPopupDialogs["VENDORPLUS_SELL_ALL"]={
    text="%s",
    button1=L.ACCEPT,
    button2=L.CANCEL,
    OnAccept=function(_,data) accept(data) end,
    timeout=0,
    whileDead=false,
    hideOnEscape=true,
    preferredIndex=3,
}

local function showConfirmation(bag,slot)
    if active or not merchantOpen() or (InCombatLockdown and InCombatLockdown())
        or (CursorHasItem and CursorHasItem()) then return end
    local info=C_Container.GetContainerItemInfo(bag,slot)
    if not info then return end
    local plan=collect(info.itemID)
    if plan.count==0 then return end
    if StackSplitFrame and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
    plan.generation=generation
    local message=string.format(L.CONFIRM_SELL_ALL,plan.count,plan.link,VendorPlusMoneyText(plan.total))
    if #plan.items>12 then message=message..("\n\n"..L.BUYBACK_NOTE) end
    StaticPopup_Show("VENDORPLUS_SELL_ALL",message,nil,plan)
end

local function bagAndSlot(button)
    local bag=button.GetBagID and button:GetBagID() or (button:GetParent() and button:GetParent():GetID())
    return bag,button:GetID()
end

local function attach(button,bag,slot)
    if not button or not button.HookScript or not button.GetID or button:GetID()~=slot then return end
    local buttonBag=bagAndSlot(button)
    if buttonBag~=bag or hookedButtons[button] then return end
    hookedButtons[button]=true
    button:HookScript("OnClick",function(self,mouse)
        local edit=ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if mouse~="LeftButton" or not IsShiftKeyDown() or (IsControlKeyDown and IsControlKeyDown())
            or (IsAltKeyDown and IsAltKeyDown()) or (edit and edit.HasFocus and edit:HasFocus()) then return end
        local currentBag,currentSlot=bagAndSlot(self)
        if VendorPlusIsCarriedBag(currentBag) then showConfirmation(currentBag,currentSlot) end
    end)
end

local function appendSellHint(self)
    if self~=GameTooltip or not merchantOpen() then return end
    local owner=self:GetOwner()
    if not owner or not owner.GetID or not owner.GetParent then return end
    local bag,slot=bagAndSlot(owner)
    if not VendorPlusIsCarriedBag(bag) or not slot or slot<1 then return end
    local info=C_Container.GetContainerItemInfo(bag,slot)
    if not info then return end
    attach(owner,bag,slot)
    if not sellable(bag,slot,info.itemID) then return end
    for line=1,self:NumLines() do
        local text=_G[self:GetName().."TextLeft"..line]
        if text and text:GetText()==tooltipMarker then return end
    end
    self:AddLine(tooltipMarker)
end

hooksecurefunc(GameTooltip,"SetBagItem",function(self,bag,slot)
    if self~=GameTooltip or not merchantOpen() then return end
    attach(self:GetOwner(),bag,slot)
    if not TooltipDataProcessor then appendSellHint(self) end
end)

if TooltipDataProcessor and TooltipDataProcessor.AddLinePostCall and Enum and Enum.TooltipDataLineType then
    TooltipDataProcessor.AddLinePostCall(Enum.TooltipDataLineType.SellPrice,appendSellHint)
elseif TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,appendSellHint)
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("ContainerFrameItemButton.EnterButton",function(_,owner)
        if not merchantOpen() then return end
        local bag,slot=bagAndSlot(owner)
        if VendorPlusIsCarriedBag(bag) then attach(owner,bag,slot) end
    end,events)
end

events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("UI_ERROR_MESSAGE")
events:SetScript("OnEvent",function(_,event)
    if event=="MERCHANT_SHOW" or event=="MERCHANT_CLOSED" then
        stop()
        StaticPopup_Hide("VENDORPLUS_SELL_ALL")
    elseif event=="UI_ERROR_MESSAGE" and active then stop() end
end)

end

end
