dofile('Localization.lua')
function VendorPlusCarriedBags()return {0,5}end
function VendorPlusMoneyText(amount)return tostring(amount)end
local methods={}
local function obj(name)return setmetatable({scripts={},name=name}, {__index=methods})end
function methods:SetScript(k,v)self.scripts[k]=v end
function methods:GetScript(k)return self.scripts[k]end
function methods:HookScript(k,v)self.scripts[k]=v end
function methods:Show()self.shown=true end
function methods:Hide()self.shown=false;if self.scripts.OnHide then self.scripts.OnHide(self)end end
function methods:SetShown(v)self.shown=v end
function methods:IsShown()return self.shown end
function methods:SetText(t)self.text=t end
function methods:SetTitle(t)self.title=t end
function methods:SetChecked(c)self.checked=c end
function methods:GetChecked()return self.checked end
function methods:SetEnabled(c)self.enabled=c end
function methods:CreateFontString()return obj()end
function methods:CreateTexture()return obj()end
setmetatable(methods,{__index=function(_,key)if key:match("^[A-Z]") then return function()end end end})
function CreateFrame(_,name,_,template)
 local f=obj(name)
 if template=='ButtonFrameTemplate' then f.Inset=obj();f.TitleContainer=obj();f.TitleContainer.TitleText=obj()end
 if name then _G[name]=f end
 return f
end
UIParent=obj();MerchantFrame=obj();MerchantFrame.shown=true;MerchantFrame.selectedTab=1
MerchantSellAllJunkButton=obj();MerchantSellAllJunkButton.Icon=obj()
GameTooltip=obj()
UISpecialFrames={}
NUM_BAG_SLOTS=0
function hooksecurefunc()end
function GetInventoryItemLink()return 'equipped'end
C_Item={GetItemInfo=function(link)return 'Gear',link,2,link=='equipped' and 20 or 10,1,nil,nil,nil,'INVTYPE_CHEST',nil,100,4,2,1 end,GetItemGUID=function(loc)return 'G'..loc.slot end}
ItemLocation={CreateFromBagAndSlot=function(_,_,slot)return {slot=slot}end}
C_Container={GetContainerNumSlots=function(bag)return bag==0 and 13 or 0 end,GetContainerItemInfo=function(_,slot)return {quality=2,isBound=true,itemID=slot,hyperlink='item:'..slot,iconFileID=1}end,GetContainerItemPurchaseInfo=function(_,_,eq)assert(eq==false);return {}end,UseContainerItem=function()end}
local timers={}
C_Timer={After=function(_,f)timers[#timers+1]=f end}
VendorPlusDB={sell={soulbound=true}}
local source=assert(io.open('Sell.lua')):read('*a')
source=source:gsub('^if not [^\n]+\n[^\n]+\n',''):gsub('\nend\n$','\n')
local api=assert(load(source..'\nreturn {events=events,options=options,repair=automaticallyRepair,init=initialize,auto=sellAutomaticAndReviewGear,show=function()populate();preview:Show()end,state=function()return rows,pageText,nextPage,previousPage,sellButton,preview,summary end}', 'SellPagesTest'))()
api.init();api.show()
local rows,text,nextPage,prev,accept,frame=api.state()
assert(#rows==6 and rows[1].item.id==1 and rows[6].item.id==6 and text.text=='Page 1 of 3')
nextPage.scripts.OnClick()
assert(rows[1].item.id==7 and rows[6].item.id==12)
nextPage.scripts.OnClick()
assert(rows[1].item.id==13 and not rows[2]:IsShown())
rows[1].checked=false;rows[1].scripts.OnClick(rows[1])
assert(VendorPlusDB.sell.blacklist[13])
prev.scripts.OnClick();prev.scripts.OnClick()
assert(rows[1].item.id==1)
rows[1].scripts.OnEnter(rows[1])
assert(accept.text=='Accept' and frame.title=='Sell Items')
accept.scripts.OnClick()
assert(not frame:IsShown(), 'Accept must close the preview immediately')
assert(#timers>0, 'Sale must continue after preview closes')
print('PASS: 6 rows per page, 13 items across 3 pages, blacklist persists, tooltip handler, Accept closes and sale continues')

function UnitClass()return 'Mage','MAGE' end
function UnitLevel()return 10 end
api.show()
local refreshed=api.state()
assert(refreshed[1].item.classUnusable)
assert(refreshed[1].label.text:find('|cffff4040',1,true))
assert(refreshed[1].unusableShade.shown)
print('PASS: class-incompatible gear receives red name and red row background')
while #timers>0 do table.remove(timers,1)() end
local headers={}
MenuUtil={CreateContextMenu=function(_,fn)
 local root={CreateTitle=function(_,name)headers[#headers+1]=name end,CreateDivider=function()end,CreateCheckbox=function()return {SetTooltip=function()end}end}
 fn(nil,root)
end}
MerchantSellAllJunkButton.scripts.OnClick(MerchantSellAllJunkButton,'RightButton')
assert(headers[1]=='Soulbound' and headers[2]=='Consumables')
print('PASS: native options menu groups Soulbound and Consumables')

local inventory={
 [1]={itemID=1,quality=0,hyperlink='item:1',stackCount=1},
 [2]={itemID=2455,quality=1,hyperlink='item:2455',stackCount=20},
 [3]={itemID=3,quality=2,hyperlink='item:3',stackCount=1,isBound=true}
}
local sales={}
C_Container.GetContainerNumSlots=function(bag)return bag==0 and 3 or 0 end
C_Container.GetContainerItemInfo=function(_,slot)return inventory[slot]end
C_Container.UseContainerItem=function(_,slot)sales[#sales+1]=slot;inventory[slot]=nil end
C_Item.GetItemInfo=function(link)
 if link=='item:2455' then return 'Mana Potion',link,1,15,5,nil,nil,nil,'',nil,10,0,1,0 end
 if link=='item:1' then return 'Junk',link,0,1,1,nil,nil,nil,'',nil,5,15,0,0 end
 return 'Leather',link,2,10,1,nil,nil,nil,'INVTYPE_CHEST',nil,100,4,2,1
end
VendorPlusDB.sell.uncommon=true;VendorPlusDB.sell.rare=true;VendorPlusDB.sell.sellManaConsumables=true;VendorPlusDB.sell.grey=true
api.auto()
assert(frame:IsShown() and #sales==0, 'Opening confirmation must not sell junk or consumables first')
while #timers>0 do table.remove(timers,1)()end
assert(#sales==0, 'No sale may be queued before Accept')
local displayed,_,_,_,_,_,saleSummary=api.state()
assert(displayed[1].item.id==3 and not displayed[2]:IsShown())
assert(saleSummary.text=='Total: '..VendorPlusMoneyText(305), 'Total must include junk, consumable stacks and selected gear')
displayed[1].checked=false;displayed[1].scripts.OnClick(displayed[1])
assert(saleSummary.text=='Total: '..VendorPlusMoneyText(205), 'Unchecking gear must immediately update the total')
frame:Hide()
assert(#sales==0, 'Declining must not sell the pending automatic items')
displayed[1].checked=true;displayed[1].scripts.OnClick(displayed[1])
api.auto()
assert(saleSummary.text=='Total: '..VendorPlusMoneyText(305))
accept.scripts.OnClick()
assert(#sales==1 and sales[1]==1 and not frame:IsShown())
while #timers>0 do table.remove(timers,1)()end
assert(#sales==3 and sales[1]==1 and sales[2]==2 and sales[3]==3, 'Automatic items must sell first; confirmed gear last for Buyback')
inventory[2]={itemID=2455,quality=1,hyperlink='item:2455',stackCount=20}
api.auto()
while #timers>0 do table.remove(timers,1)()end
assert(not frame:IsShown() and #sales==4, 'Without gear, white consumables should sell without confirmation')
inventory[2]={itemID=2455,quality=1,hyperlink='item:2455',stackCount=20}
VendorPlusDB.sell.blacklist[2455]=true
api.auto()
while #timers>0 do table.remove(timers,1)()end
assert(#sales==4, 'Blacklisted automatic items must remain protected')
print('PASS: no sales before Accept; Decline cancels everything; live combined Total; junk/consumables first, gear last; automatic-only sale; blacklist protection')

local repairCount,manualCount,cost,money,canRepair=0,0,25,100,true
function CanMerchantRepair()return canRepair end
function GetRepairAllCost()return cost,cost>0 end
function GetMoney()return money end
local order={}
function RepairAllItems(guild)
 assert(guild==false,'Automatic repair must use personal gold')
 repairCount=repairCount+1;cost=0;order[#order+1]='repair'
end
MerchantRepairAllButton=CreateFrame('Button')
MerchantRepairAllButton:SetScript('OnClick',function()manualCount=manualCount+1 end)
api.init()
assert(api.options().autoSell==false and api.options().autoRepair==false)
local choices={}
MenuUtil.CreateContextMenu=function(_,fn)
 local root={CreateTitle=function()end,CreateDivider=function()end,CreateCheckbox=function(_,label,get,set)
 choices[#choices+1]={label=label,get=get,set=set}
 return {SetTooltip=function()end}
 end}
 fn(nil,root)
end
MerchantRepairAllButton.scripts.OnClick(MerchantRepairAllButton,'RightButton')
assert(choices[1].label=='Automatically repair items' and not choices[1].get())
choices[1].set();assert(api.options().autoRepair)
MerchantRepairAllButton.scripts.OnClick(MerchantRepairAllButton,'LeftButton')
assert(manualCount==1)
choices={}
MerchantSellAllJunkButton.scripts.OnClick(MerchantSellAllJunkButton,'RightButton')
assert(choices[1].label=='Automatically sell items' and not choices[1].get())
choices[1].set();assert(api.options().autoSell)
VendorPlusDB.sell.blacklist[2455]=nil
inventory[1]={itemID=1,quality=0,hyperlink='item:1',stackCount=1}
inventory[2]={itemID=2455,quality=1,hyperlink='item:2455',stackCount=20}
sales={}
local use=C_Container.UseContainerItem
C_Container.UseContainerItem=function(bag,slot)order[#order+1]='sell';use(bag,slot)end
api.events.scripts.OnEvent(nil,'MERCHANT_SHOW')
while #timers>0 do table.remove(timers,1)()end
assert(repairCount==1 and #sales==2 and order[1]=='repair')
cost=50;money=0;api.repair();assert(repairCount==1)
money=100;canRepair=false;api.repair();assert(repairCount==1)
canRepair=true;api.repair();assert(repairCount==2)
cost=20
api.events.scripts.OnEvent(nil,'MERCHANT_SHOW')
api.events.scripts.OnEvent(nil,'MERCHANT_CLOSED')
while #timers>0 do table.remove(timers,1)()end
assert(repairCount==2,'Closing vendor must cancel a pending automatic action')
api.options().autoSell=false;api.options().autoRepair=false
api.events.scripts.OnEvent(nil,'MERCHANT_SHOW')
while #timers>0 do table.remove(timers,1)()end
assert(repairCount==2 and #sales==2)
print('PASS: opt-in persisted auto-sell/repair, native left-click repair retained, repair affordability/capability, canceled sessions, disabled defaults')
