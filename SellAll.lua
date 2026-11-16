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
