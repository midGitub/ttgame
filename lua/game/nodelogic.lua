local shaco = require "shaco"
local nodepool = require "nodepool"
local userpool = require "userpool"
local ctx = require "ctx"
local tbl = require "tbl"
local relation = require "relation"
local fight = require "fight"
local fighttag = require "fighttag"

local nodelogic = {}

function nodelogic.init(conf)
end

function nodelogic.update()
end

function nodelogic.dispatch(connid, msgid, msg)
    if msgid == 1 then
        local ok = nodepool.add(connid, msg)
        ctx.send2n(connid, msgid, {code=ok and 0 or 1})
    elseif msgid == 2 then -- after reconnect
        local node = nodepool.find(connid)
        assert(node)
        local serverid = node.serverid
        for k, v in ipairs(msg) do
            local ur = userpool.find_byid(v.roleid)
            if ur then
                if not ur.fighting then
                    ur.fighting = {
                        serverid = serverid,
                        mode = 0, -- todo sync from fightserver
                    }
                else
                    -- todo
                end
            end
        end
    elseif msgid == 11 then 
        local roles = msg.roles
        local ids = {}
        for i=1, #roles do
            local id = math.floor(roles[i].roleid)
            roles[i].roleid = id
            ids[i] = id
        end
        local now = shaco.now()//1000
        for k, v in ipairs(roles) do
            local roleid = v.roleid
            local ur = userpool.find_byid(roleid)
            if ur then
                if ur.fighting then
                    ur.fighting = false
                    ur:copper_got(v.copper)
                    ur:addexp(v.exp)
                    ur:addeat1(v.eat)
                    ur:setmaxmass(v.mass)
                    ur:setduanwei(v.rank)
                    ur:syncrole()
                    if v.box1>0 then
                      ur.bag:add(701, v.box1)
                    end
                    if v.box2>0 then
                      ur.bag:add(702, v.box2)
                    end
                    ur:refreshbag(3)
                    ur:db_flush()
                    fight.record(roleid, {
                        roleid=roleid,
                        nickname=v.name, --
                        icon=ur.info.icon,
                        sex=ur.info.sex,
                        time=now, --
                        rank=v.rank,
                        mass=v.mass,
                        eat=v.eat,
                        live=v.live, --
                        copper=v.copper,
                    })
                    local l1 = relation.mhas(roleid, 'attention', ids)
                    local l2 = relation.mhas(roleid, 'like', ids)
                    ur:send(IDUM_FightLikes, {attentions=l1, likes=l2, roles=ids})
                end
            else
                fighttag.unset(roleid) -- fighttag just cache for offline fighting user
            end
        end
    end
end

function nodelogic.error(serverid, err)
    -- no need clear fighting, just re request fighting once again, see h_fight
    --userpool.foreach_user(function(ur)
    --    if ur.fighting and ur.fighting.serverid == serverid  then
    --        ur.fighting = false
    --    end
    --end)
    --fighttag.clear_byserverid(serverid)
end

return nodelogic
