# Minimal stand-in for Supabase Realtime (Phoenix vsn 1.0.0 JSON): join, broadcast, presence.
import asyncio,json,websockets
rooms={}  # topic -> {ws: key}
pres={}   # topic -> {key: meta}
async def send(ws,topic,event,payload,ref=None):
    try: await ws.send(json.dumps({'topic':topic,'event':event,'payload':payload,'ref':ref}))
    except Exception: pass
async def handler(ws):
    joined={}
    try:
        async for raw in ws:
            m=json.loads(raw);t=m['topic'];ev=m['event'];p=m.get('payload') or {}
            if ev=='heartbeat': await send(ws,'phoenix','phx_reply',{'status':'ok','response':{}},m['ref']);continue
            if ev=='phx_join':
                key=p['config']['presence']['key'];joined[t]=key;rooms.setdefault(t,{})[ws]=key
                await send(ws,t,'phx_reply',{'status':'ok','response':{}},m['ref'])
                await send(ws,t,'presence_state',{k:{'metas':[v]} for k,v in pres.get(t,{}).items()})
            elif ev=='broadcast':
                for o in list(rooms.get(t,{})):
                    if o is not ws: await send(o,t,'broadcast',p)
            elif ev=='presence' and p.get('event')=='track':
                key=joined[t];pres.setdefault(t,{})[key]={**p['payload'],'phx_ref':'x'}
                for o in list(rooms.get(t,{})): await send(o,t,'presence_diff',{'joins':{key:{'metas':[pres[t][key]]}},'leaves':{}})
            elif ev=='phx_leave':
                await leave(ws,t,joined.pop(t,None))
    finally:
        for t,key in list(joined.items()): await leave(ws,t,key)
async def leave(ws,t,key):
    rooms.get(t,{}).pop(ws,None)
    if key and key in pres.get(t,{}):
        meta=pres[t].pop(key)
        for o in list(rooms.get(t,{})): await send(o,t,'presence_diff',{'joins':{},'leaves':{key:{'metas':[meta]}}})
async def main():
    async with websockets.serve(handler,'localhost',8766): await asyncio.Future()
asyncio.run(main())
