--[[
packet format:
packetID: random string to differentiate
packetType:
 - 0: unreliable
 - 1: reliable, requires ack
 - 2: ack packet
destination: end destination hostname
sender: original sender of packet
data: the actual packet data, duh.
]]--

local listeners = {}
local timers = {}

local cfg = {}

local event = require "event"
local component = require "component"
local computer = require "computer"
local serial = require "serialization"
local hostname = computer.address():sub(1,8)
local listener = false
cfg.debug = false
local modems = {}
cfg.port = 4096
cfg.retry = 10
cfg.retrycount = 64
cfg.route = true

--[[
LKR format:
address {
 local hardware address
 remote hardware address
 time last received
}
]]--
cfg.sroutes = {}
local rcache = setmetatable({},{__index=cfg.sroutes})
cfg.rctime = 15

--[[
packet queue format:
{
 packetID,
 packetType
 destination,
 data,
 timestamp,
 attempts
}
]]--
local pqueue = {}

-- packet cache: [packet ID]=uptime
local pcache = {}
cfg.pctime = 30

local function dprint(...)
 if cfg.debug then
  print(...)
 end
end

local function saveconfig()
 local f = io.open("/etc/minitel.cfg","wb")
 if f then
  f:write(serial.serialize(cfg))
  f:close()
 end
end
local function loadconfig()
 local f = io.open("/etc/minitel.cfg","rb")
 if f then
  local newcfg = serial.unserialize(f:read("*a"))
  f:close()
  for k,v in pairs(newcfg) do
   cfg[k] = v
  end
 else
  saveconfig()
 end
end

function start()
 loadconfig()
 local f=io.open("/etc/hostname","rb")
 if f then
  hostname = f:read()
  f:close()
 end
 print("Hostname: "..hostname)
 if listener then return end
 modems={}
 for a,t in component.list("modem") do
  modems[#modems+1] = component.proxy(a)
 end
 for k,v in ipairs(modems) do
  v.open(cfg.port)
  print("Opened port "..cfg.port.." on "..v.address)
 end
 for a,t in component.list("tunnel") do
  modems[#modems+1] = component.proxy(a)
 end
 
 local function genPacketID()
  local npID = ""
  for i = 1, 16 do
   npID = npID .. string.char(math.random(32,126))
  end
  return npID
 end
 
 local function sendPacket(packetID,packetType,dest,sender,vPort,data)
  if rcache[dest] then
   dprint("Cached", rcache[dest][1],"send",rcache[dest][2],cfg.port,packetID,packetType,dest,sender,vPort,data)
   if component.type(rcache[dest][1]) == "modem" then
    component.invoke(rcache[dest][1],"send",rcache[dest][2],cfg.port,packetID,packetType,dest,sender,vPort,data)
   elseif component.type(rcache[dest][1]) == "tunnel" then
    component.invoke(rcache[dest][1],"send",packetID,packetType,dest,sender,vPort,data)
   end
  else
   dprint("Not cached", cfg.port,packetID,packetType,dest,sender,vPort,data)
   for k,v in pairs(modems) do
    if v.type == "modem" then
     v.broadcast(cfg.port,packetID,packetType,dest,sender,vPort,data)
    elseif v.type == "tunnel" then
     v.send(packetID,packetType,dest,sender,vPort,data)
    end
   end
  end
 end
 
 local function pruneCache()
  for k,v in pairs(rcache) do
   dprint(k,v[3],computer.uptime())
   if v[3] < computer.uptime() then
    rcache[k] = nil
    dprint("pruned "..k.." from routing cache")
   end
  end
  for k,v in pairs(pcache) do
   if v < computer.uptime() then
    pcache[k] = nil
    dprint("pruned "..k.." from packet cache")
   end
  end
 end

 local function checkPCache(packetID)
  dprint(packetID)
  for k,v in pairs(pcache) do
   dprint(k)
   if k == packetID then return true end
  end
  return false
 end
 
 local function processPacket(_,localModem,from,pport,_,packetID,packetType,dest,sender,vPort,data)
  pruneCache()
  if pport == cfg.port or pport == 0 then -- for linked cards
   dprint(cfg.port,vPort,packetType,dest)
   if checkPCache(packetID) then return end
   if dest == hostname then
    if packetType == 1 then
     sendPacket(genPacketID(),2,sender,hostname,vPort,packetID)
    end
    if packetType == 2 then
     dprint("Dropping "..data.." from queue")
     pqueue[data] = nil
     computer.pushSignal("net_ack",data)
    end
    if packetType ~= 2 then
     computer.pushSignal("net_msg",sender,vPort,data)
    end
   elseif dest:sub(1,1) == "~" then -- broadcasts start with ~
    computer.pushSignal("net_broadcast",sender,vPort,data)
   elseif cfg.route then -- repeat packets if route is enabled
    sendPacket(packetID,packetType,dest,sender,vPort,data)
   end
   if not rcache[sender] then -- add the sender to the rcache
    dprint("rcache: "..sender..":", localModem,from,computer.uptime())
    rcache[sender] = {localModem,from,computer.uptime()+cfg.rctime}
   end
   if not pcache[packetID] then -- add the packet ID to the pcache
    pcache[packetID] = computer.uptime()+cfg.pctime
   end
  end
 end
 
 listeners["modem_message"]=processPacket
 event.listen("modem_message",processPacket)
 print("Started packet listening daemon: "..tostring(processPacket))
 
 local function queuePacket(_,ptype,to,vPort,data,npID)
  npID = npID or genPacketID()
  if to == hostname or to == "localhost" then
   computer.pushSignal("net_msg",to,vPort,data)
   computer.pushSignal("net_ack",npID)
   return
  end
  pqueue[npID] = {ptype,to,vPort,data,0,0}
  dprint(npID,table.unpack(pqueue[npID]))
 end
 
 listeners["net_send"]=queuePacket
 event.listen("net_send",queuePacket)
 print("Started packet queueing daemon: "..tostring(queuePacket))
 
 local function packetPusher()
  for k,v in pairs(pqueue) do
   if v[5] < computer.uptime() then
    dprint(k,v[1],v[2],hostname,v[3],v[4])
    sendPacket(k,v[1],v[2],hostname,v[3],v[4])
    if v[1] ~= 1 or v[6] == cfg.retrycount then
     pqueue[k] = nil
    else
     pqueue[k][5]=computer.uptime()+cfg.retry
     pqueue[k][6]=pqueue[k][6]+1
    end
   end
  end
 end
 
 timers[#timers+1]=event.timer(0,packetPusher,math.huge)
 print("Started packet pusher: "..tostring(timers[#timers]))
 
 listeners["net_ack"]=dprint
 event.listen("net_ack",dprint)
end

function stop()
 for k,v in pairs(listeners) do
  event.ignore(k,v)
  print("Stopped listener: "..tostring(v))
 end
 for k,v in pairs(timers) do
  event.cancel(v)
  print("Stopped timer: "..tostring(v))
 end
end

function debug()
 cfg.debug = not cfg.debug
end
function set_retry(sn)
 cfg.retry = tonumber(sn) or 30
 print("retry = "..tostring(cfg.retry))
end
function set_retrycount(sn)
 cfg.retrycount = tonumber(sn) or 64
 print("retrycount = "..tostring(cfg.retrycount))
end
function set_pctime(sn)
 cfg.pctime = tonumber(sn) or 30
 print("pctime = "..tostring(cfg.pctime))
end
function set_rctime(sn)
 cfg.rctime = tonumber(sn) or 30
 print("rctime = "..tostring(cfg.rctime))
end
function set_port(sn)
 cfg.port = tonumber(sn) or 4096
 print("port = "..tostring(cfg.port))
end
function set_route(to,laddr,raddr)
 cfg.sroutes[to] = {laddr,raddr,0}
end
function del_route(to)
 cfg.sroutes[to] = nil
end
