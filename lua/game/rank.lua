local shaco = require "shaco"
local myredis = require "myredis"
local ctx = require "ctx"
local util = require "util"

local rank = {}

local MAX_RANK = 20
local RANKT = {
'power', 'fans', 'belike', 'flower', 'kill',
}
local DATET = {
'day', 'week', 'month', 'total', 'history',
}

function rank.rankt(typ)
    return RANKT[typ]
end
function rank.datet(typ)
    return DATET[typ]
end

local function curkey(typ, subt)
    return typ..':'..subt
end

local function lastdatekey(typ, subt, now)
    local last
    if subt=='day' then
        last=util.lastdaybase(now)
    elseif subt=='week' then
        last=util.lastweekbase(now)
    elseif subt=='month' then
        last=util.lastmonthbase(now)
    elseif subt=='total' then
        last=util.lastmonthbase(now)
    end
    if last then
        last = os.date('%Y%m%d', last)
        return rank.curkey(typ, subt)..':'..last
    end
end

function rank.setpower(roleid, v1, v2)
    local score = (v1<<8) | v2
    rank.setscore(roleid, 'power', score)
end

function rank.getpower(roleid)
    local score = rank.getscore(roleid, 'power')
    if score then
        return (score>>8)&0xff, score&0xff
    else 
        return 0, 0
    end
end

function rank.getscore(roleid, typ)
    local key = curkey(typ, 'day')
    return tonumber(myredis.zscore(key, roleid))
end

function rank.setscore(roleid, typ, score)
    for _, v in ipairs(DATET) do
        local key = curkey(typ, v)
        myredis.zadd(key, score, roleid)
        myredis.zremrangebyrank(key, MAX_RANK, -1)
    end
end

function rank.addscore(roleid, typ, score)
    for _, v in ipairs(DATET) do
        local key = curkey(typ, v)
        myredis.zincrby(key, score, roleid)
        myredis.zremrangebyrank(key, MAX_RANK, -1)
    end
end


local function reset(typ)
    local now = shaco.now()//1000
    local key, last
 
    key=curkey(typ, 'day')
    last=lastdatekey(typ, 'day', now)
    if not myredis.exists(last) then
        myredis.backupkey(key, last)
    end

    key=curkey(typ, 'week')
    last=lastdatekey(typ, 'week', now)
    if not myredis.exists(last) then
        myredis.backupkey(key, last)
    end

    key=curkey(typ, 'month')
    last=lastdatekey(typ, 'month', now)
    if not myredis.exists(last) then
        myredis.backupkey(key, last)
    end
end

local function resetall()
    for _, v in ipairs(RANKT) do
        reset(v)
    end
end

function rank.update(now, daychanged)
    if daychanged then
        resetall()
    end
end

function rank.init()
    local now = shaco.now()//1000
    local openbase  = util.daybase(ctx.server_opentime)
    local todaybase = util.daybase(now)
    if openbase < todaybase then
        resetall()
    end
end

rank.curkey = curkey
rank.lastdatekey = lastdatekey
rank.MAX_RANK = MAX_RANK

return rank
