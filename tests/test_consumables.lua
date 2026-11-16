dofile('Localization.lua')
function CreateFrame()return {RegisterEvent=function()end,SetScript=function()end}end
local file=assert(io.open('Sell.lua'))
local source=file:read('*a')
file:close()
source=source:gsub('^if not [^\n]+\n[^\n]+\n',''):gsub('\nend\n$','\n')
local matches=assert(load(source..'\nreturn consumableCandidate','ConsumableSalesTest'))()
function UnitLevel()return 60 end
local name,level,spell='Raw Brilliant Smallfish',1,'Food'
C_Item={
    GetItemInfo=function()return name,nil,1,1,level,nil,nil,nil,'',nil,1,0,5 end,
    GetItemSpell=function(link)
        if link==117 then return 'Food' end
        if link==159 then return 'Drink' end
        return spell
    end,
}
local info={itemID=6291,hyperlink='item:6291'}
local db={lowConsumables=true,sellManaConsumables=false}
assert(not matches(info,db),'Raw cooking fish must not be sold as low-level food')
name='Raw Slitherskin Mackerel';assert(not matches(info,db))
name='RAW Longjaw Mud Snapper';assert(not matches(info,db))
name='raw fish';assert(not matches(info,db))
name='Brilliant Smallfish';assert(matches(info,db),'Cooked low-level fish should still qualify')
name='Drawfish Snack';assert(matches(info,db),'Raw must be a separate word')
level=55;assert(not matches(info,db),'Best usable food must remain protected')
level=65;assert(not matches(info,db),'Future-level food must remain protected')
name='Refreshing Spring Water';level=1;spell='Drink'
assert(matches(info,db),'Low-level drinks should still qualify')
print('PASS: raw cooking fish protected; cooked food and drinks unchanged; word boundaries, case and level protections')
