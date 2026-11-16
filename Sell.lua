if not VendorPlusSellLoaded then
VendorPlusSellLoaded=true
local L=VendorPlusL
local events = CreateFrame("Frame")
local button, preview, summary, sellButton, content
local rows, candidates, automaticCandidates = {}, {}, {}
local selling, token = false, 0
local page, pageText, previousPage, nextPage = 1
local renderPage
local merchantSession=0
local repairHooked=false
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
    if db.autoSell == nil then db.autoSell=false end
    if db.autoRepair == nil then db.autoRepair=false end
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
    local name,_,_,_,level,_,_,_,_,_,_,classID,subclassID=C_Item.GetItemInfo(info.hyperlink)
    if classID~=0 or not level then return false end
    local playerLevel=UnitLevel("player")
    if subclassID==5 then
        if name and name:lower():find("%f[%a]raw%f[%A]") then return false end
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

local function automaticallyRepair()
    if not options().autoRepair or not CanMerchantRepair or not CanMerchantRepair() then return end
    local cost,canRepair=GetRepairAllCost()
    if canRepair and cost and cost>0 and cost<=GetMoney() then RepairAllItems(false) end
end

local function setupRepairOptions()
    if repairHooked or not MerchantRepairAllButton then return end
    repairHooked=true
    local repair=MerchantRepairAllButton
    local original=repair:GetScript("OnClick")
    repair:RegisterForClicks("LeftButtonUp","RightButtonUp")
    repair:SetScript("OnClick",function(self,mouse)
        if mouse=="RightButton" then
            MenuUtil.CreateContextMenu(self,function(_,root)
                local entry=root:CreateCheckbox(L.AUTO_REPAIR,function() return options().autoRepair end,
                    function() options().autoRepair=not options().autoRepair end)
                entry:SetTooltip(function(tooltip) tooltip:AddLine(L.HINT_AUTO_REPAIR,1,1,1,true) end)
            end)
        elseif original then
            original(self,mouse)
        end
    end)
    repair:HookScript("OnEnter",function()
        GameTooltip:AddLine(L.OPTIONS_HINT,1,1,1)
        GameTooltip:Show()
    end)
    local function enableRepairOptions()
        if MerchantFrame.selectedTab~=2 and CanMerchantRepair and CanMerchantRepair() then repair:Enable() end
    end
    hooksecurefunc("MerchantFrame_Update",enableRepairOptions)
    if type(MerchantFrame_UpdateCanRepairAll)=="function" then hooksecurefunc("MerchantFrame_UpdateCanRepairAll",enableRepairOptions) end
    enableRepairOptions()
end

local function initialize()
    setupRepairOptions()
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
                toggle(L.AUTO_SELL,"autoSell",L.HINT_AUTO_SELL)
                root:CreateDivider()
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
events:RegisterEvent("MERCHANT_CLOSED")
events:SetScript("OnEvent",function(_,event)
    merchantSession=merchantSession+1
    if event=="MERCHANT_CLOSED" then return end
    initialize()
    local session=merchantSession
    C_Timer.After(0.05,function()
        if session~=merchantSession or not MerchantFrame:IsShown() or MerchantFrame.selectedTab~=1 then return end
        automaticallyRepair()
        if options().autoSell then sellAutomaticAndReviewGear() end
    end)
end)

end
