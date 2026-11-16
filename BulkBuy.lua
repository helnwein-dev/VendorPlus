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
