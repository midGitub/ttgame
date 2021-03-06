local shaco = require "shaco"
local util = require "util"
local pb = require "protobuf"
local tbl = require "tbl"
local MSG_RESNAME = require "msg_resname"
local ctx = require "ctx"
local mydb = require "mydb"
local myredis = require "myredis"
local bag = require "bag"
local rank = require "rank"
local gamestate = require "gamestate"
local fighttag = require "fighttag"
local tpexp = require "__tpexp"
local tpduanwei = require "__tpduanwei"
local tpduanwei_star = require "__tpduanwei_star"

local spack = string.pack

local user = {
    DB_ROLE=1,
    DB_ROLE_DELAY=2,
    DB_ITEM=4,
}
user.__index = user

local function headflower(ur)
    local myid = ur.info.roleid

    local season = ctx.season-1
    if season >=1 and season <= 9 then
        local dw = rank.getpower_lastseason(myid)
        if dw >= 10 then -- 至少大师
            local itemid = 600 + season
            ur:adduniqueitem(itemid)
        end
    end
    local now = shaco.now()//1000
    if os.date("%Y%m%d", now) == "20160809" then -- 七夕
        ur:adduniqueitem(610)
    elseif os.date("%Y%m%d", now) == "20170211" then -- 元宵
        ur:adduniqueitem(611)
    elseif os.date("%Y%m%d", now) == "20170128" then -- 春节
        ur:adduniqueitem(612)
    end
    ur:refreshbag(10)
end

function user.new(connid, status)
    local self = {
        connid = connid,
        status = status,
        gmlevel = 0,
        db_dirty_flag = 0,
        acc = false,
        info = false,
        bag = false,
        fighting = false,
        fightenter = false,
    }
    setmetatable(self, user)
    return self
end

function user:init(roleid, gmlevel, info, items)
    if not info then
        info = {
            roleid = roleid,
            name = "",
            create_time=0,
            icon=101, -- default id
            sex=0,
            level=0,
            copper=10000,
            gold=10000,
            duanwei=1,
            star=1,
            mvp_cnt=0,
            champion_cnt=0,
            eat1_cnt=0,
            eat2_cnt=0,
            max_mass=0,
            province=0,
            city=0,
            describe="",
            exp=0,
            equips=false,
            free_ticket=0,
            refresh_time=0,
            sign=false,
            last_sign_time=0,
            sign_tags=0,
            award_refresh_time=0,
            award_gots=false,
        }
        self:db_tagdirty(self.DB_ROLE)
    else
        if info.duanwei<1 then
            info.duanwei=1
        end
        if info.star<1 then
            info.star=1
        end
        info.roleid = roleid -- force
    end
    if not info.equips then
      info.equips = {}
    end
    for i=#info.equips+1, 4 do -- max 4
        info.equips[i] = bag.genitem()
    end
    shaco.trace(tbl(info, "role_info"))
    self.info = info
    self.gmlevel = gmlevel
    self.bag = bag.new(items and items.list or nil)

    if not self.award_gots then
        self.award_gots = {}
    end
    local now = shaco.now()//1000
    local now_day = util.second2day(now)
    local last_day = util.second2day(info.refresh_time)

    if now_day ~= last_day then
        self:onchangeday(true)
    else
        headflower(self)
    end

    self:db_flush()
end

function user:entergame()
    self:send(IDUM_AwardList, {list = ctx.award.list})

    local fighting = fighttag.unset(self.info.roleid);
    self.fighting = fighting
	self:send(IDUM_EnterGame, {info=self.info, servertime=shaco.now()//1000, 
    fighting=not not fighting})

    local items = {}
    self.bag:foreach(function(v)
        items[#items+1] = v.info
    end)
    self:send(IDUM_ItemUpdate, {list=items, type=0})
end

function user:exitgame()
    if self.fighting then
        fighttag.set(self.info.roleid, self.fighting)
    end
    self:db_flush(true)
end

function user:syncrole()
    self:send(IDUM_SyncRole, {info=self.info})
end

function user:update(now)
end

function user:onchangeday(login, weekchanged)
    local now = shaco.now()//1000
	self.info.refresh_time = now
   
    local info = self.info
    if info.free_ticket < 1 then
        info.free_ticket = 1
    end
    info.sign = false -- 

    if info.award_refresh_time ~= ctx.award.refresh_time then
        info.award_gots = {}
        for i=1, #ctx.award.list do
            table.insert(info.award_gots, false)
        end
        info.award_refresh_time = ctx.award.refresh_time
    end
    
    self:syncrole()
    
    headflower(self)
    self:db_tagdirty(self.DB_ROLE)
    self:db_flush()
end

-- db
function user:db_tagdirty(t)
    self.db_dirty_flag = (self.db_dirty_flag | t)
end

function user:db_flush(force)
    local roleid = self.info.roleid
    local flag = self.db_dirty_flag

    local up_role = false
    if (flag & self.DB_ROLE) ~= 0 then
        flag = (flag & (~(self.DB_ROLE)))
        up_role = true
    elseif (force and ((flag & self.DB_ROLE_DELAY) ~= 0)) then
        flag = (flag & (~(self.DB_ROLE_DELAY)))
        up_role = true
    end
    if up_role then
        myredis.send('set', 'role:'..roleid, pb.encode("role_info", self.info))
    end 
    if (flag & self.DB_ITEM) ~= 0 then
        local items = {}
        self.bag:foreach(function(v)
            if v.info.stack > 0 then
                items[#items+1] = v.info
            end
        end)
        shaco.trace(tbl(items, "DB_ITEM"))
        myredis.send('set', 'item:'..roleid, pb.encode("item_list", {list=items}))
        flag = (flag & (~(self.DB_ITEM)))
    end  
	self.db_dirty_flag = flag
end

-- money
function user:copper_enough(take)
    return self.info.copper >= take
end

function user:copper_take(take)
    local old = self.info.copper
    if old >= take then
        self.info.copper = old - take
        self:db_tagdirty(self.DB_ROLE)
        return true
    else
        return false
    end
end

function user:copper_got(got)
    if got == 0 then
        return 0
    end
    local old = self.info.copper
    self.info.copper = old + got 
    if self.info.copper < 0 then
        self.info.copper = 0
    end
    self:db_tagdirty(self.DB_ROLE)
    return self.info.copper-old
end

-- gold
function user:gold_enough(take)
    return self.info.gold >= take
end

function user:gold_take(take)
    local old = self.info.gold
    if old >= take then
        self.info.gold = old - take
        self:db_tagdirty(self.DB_ROLE)
        return true
    else
        return false
    end
end

function user:gold_got(got)
    if got == 0 then
        return 0
    end
    local old = self.info.gold
    self.info.gold = old + got
    if self.info.gold < 0 then
        self.info.gold = 0     
    end
    self:db_tagdirty(self.DB_ROLE)
    return self.info.gold-old
end

-- exp
function user:addexp(got)
    if got <= 0 then
        return
    end
    local info = self.info
    local level = info.level
    local exp = info.exp + got
    while level < 100 do
        local tp = tpexp[level]
        if not tp then break end
        if exp < tp.exp then break end
        exp = exp - tp.exp
        level = level+1
    end
    info.level = level
    info.exp = exp
	self:db_tagdirty(self.DB_ROLE)
end

function user:setduanwei(i)
    if i<= 0 then 
        return
    end
    local dw = self.info.duanwei
    local star = self.info.star
    local tp = tpduanwei[dw]
    local tpstar = tpduanwei_star[dw]
    if not tp then
        shaco.error("Tplt duanwei not found:", dw)
        return
    end
    if not tpstar then
        shaco.error("Tplt duanwei_star not found:", dw)
        return
    end
    if i <= tp.up then
        star = star+1
        if star > tpstar.star then
            if not tpduanwei[dw+1] then
                return
            else
                dw = dw+1
                star = 1
            end
        end
    elseif tp.down>tp.up and i > tp.down then
        if star > 1 then
            star = star-1
        else 
            return
        end
    else
        return
    end
    self.info.duanwei = dw
    self.info.star = star
    self:db_tagdirty(self.DB_ROLE)
    rank.setpower(self.info.roleid, dw, star)
end

function user:addeat1(eat)
    if eat > 0 then
        self.info.eat1_cnt = self.info.eat1_cnt + eat
        self:db_tagdirty(self.DB_ROLE)
        rank.addscore(self.info.roleid, 'kill', eat)
    end
end

function user:addeat2(eat)
    if eat > 0 then
        self.info.eat2_cnt = self.info.eat2_cnt + eat
        self:db_tagdirty(self.DB_ROLE)
    end
end

function user:setmaxmass(mass)
    if self.info.max_mass < mass then
        self.info.max_mass = mass
        self:db_tagdirty(self.DB_ROLE)
    end
end

-- bag item
function user:refreshbag(typ)
    local items = {}
    self.bag:refresh(function(v)
        items[#items+1] = v.info
    end)
    if #items > 0 then
        self:db_tagdirty(self.DB_ITEM)
        self:send(IDUM_ItemUpdate, {list=items, type=typ})
    end
end

function user:hasitem(itemid)
    -- todo
    return self.bag:has(itemid, 1)
end

function user:adduniqueitem(itemid)
    if not self:hasitem(itemid) then
        self.bag:add(itemid, 1)
    end
end

-- send
function user:sendpackedmsg(msgid, packedmsg)
    if self.status == gamestate.LOGOUT then
        return
    end
    shaco.debug('Msg send:', self.connid, msgid, #packedmsg)

    --local str = string.gsub(packedmsg, ".", function(c)
    --    return string.format("%d ", string.byte(c))
    --end)
    --shaco.trace(str)

    ctx.send2c(self.connid, spack("<I2", msgid)..packedmsg)
end

function user:send(msgid, v)
    local name = MSG_RESNAME[msgid]
    assert(name)
    shaco.trace('Msg send:', tbl(v, name))
    self:sendpackedmsg(msgid, pb.encode(name, v))
end

function user:safecall(func)
    local r = func()
    if self.status == gamestate.LOGOUT then
        error(ctx.error_logout)
    end
    return r
end

function user:baseinfo()
    local info = self.info
    return {
        roleid=info.roleid,
        name=info.name,
        icon=info.icon,
        sex=info.sex,
    }
end

function user:islogout()
    return self.status == gamestate.LOGOUT
end

return user
