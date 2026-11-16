local keys={"SEARCH","FILTER","SHOW_UNUSABLE","HINT_UNUSABLE","SHOW_BEST","HINT_BEST","SHOW_MANA","HINT_MANA","SHOW_COLLECTED","HINT_COLLECTED","SORT_BY","DEFAULT","PRICE","PAGE_FMT","REASON_ARMOR","REASON_CASTER","REASON_ILVL","SELECTED_FMT","ITEM","CANNOT_EQUIP","ILVL_FMT","SELL_ITEMS","KEEP_HINT","ACCEPT","DECLINE","CANCEL","PREV","NEXT","FREE","SELL_ACTION","OPTIONS_HINT","GREY_ITEMS","SOULBOUND","CONSUMABLES","SELL_INCOMPAT_FMT","INCOMPATIBLE","HINT_INCOMPAT","SELL_QUALITY_FMT","UNCOMMON","RARE","SELL_DOWNGRADES","HINT_DOWNGRADES","SELL_LOW","HINT_LOW","SELL_MANA","HINT_SELL_MANA","PER_PACK","PER_ITEM","TOTAL","BUY_HINT","SELL_HINT","INVENTORY_CHANGED","CONFIRM_SELL_ALL","BUYBACK_NOTE","AUTO_SELL","HINT_AUTO_SELL","AUTO_REPAIR","HINT_AUTO_REPAIR"}
local locales={"enUS","enGB","deDE","esES","esMX","frFR","itIT","ptBR","ruRU","koKR","zhCN","zhTW","xxXX"}
for _,locale in ipairs(locales) do
    local env=setmetatable({GetLocale=function()return locale end},{__index=_G})
    env._G=env
    assert(loadfile("Localization.lua","t",env))()
    local L=env.VendorPlusL
    for _,key in ipairs(keys) do
        assert(type(L[key])=="string" and L[key]~="" and L[key]~=key,locale..":"..key)
        local args={}
        for spec in L[key]:gmatch("%%([ds])") do args[#args+1]=spec=="d" and 2 or "Test" end
        assert(pcall(string.format,L[key],table.unpack(args)),locale..":"..key.." invalid formatting")
    end
    if locale~="enUS" and locale~="enGB" and locale~="xxXX" then
        assert(L.SELL_ITEMS~="Sell Items",locale.." missing translation")
        assert(L.HINT_BEST:sub(1,4)~="Show",locale.." missing tooltip translation")
    end
end
local env=setmetatable({GetLocale=function()return "frFR"end,ITEM_STACK_BUY="Native localized stock hint"},{__index=_G})
env._G=env
assert(loadfile("Localization.lua","t",env))()
assert(env.VendorPlusL.BUY_HINT==env.ITEM_STACK_BUY)
print("PASS: all 58 strings across 12 locales, unknown-locale fallback, format placeholders, native stock hint override")
