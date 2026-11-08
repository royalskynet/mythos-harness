#!/usr/bin/env python3
# 六項回歸共用暫存 fixture；runner、API、資料、transcript 都在測試 sandbox。
import datetime, json, os, pathlib, runpy, shutil, subprocess, sys, time
from unittest import mock
P = pathlib.Path
MODE = sys.argv[1]
SOURCE = P(os.environ.get('MYTHOS_FIX_ROOT', P(__file__).resolve().parents[1]))
TMP = P(os.environ['MYTHOS_TEST_SANDBOX']).resolve()
ROOT = TMP / 'copy'
shutil.copytree(SOURCE / 'bin', ROOT / 'bin')
M = TMP / 'm'
(M / 'state/bg').mkdir(parents=True)
(TMP / 'worker').mkdir()
(TMP / 'rt').mkdir()
(TMP / 'projects').mkdir()
(TMP / 'home').mkdir()
(TMP / 'rt/r.jsonl').write_text('{"type":"user","message":{"content":"fixture"}}\n')
ENV = dict(os.environ, MYTHOS_TEST_SANDBOX=str(TMP), HOME=str(TMP / 'home'), MYTHOS_DIR=str(M), MYTHOS_WORKER_DIR=str(TMP / 'worker'),
           MYTHOS_TRANSCRIPT_DIR=str(TMP / 'rt'), CLAUDE_PROJECTS_DIR=str(TMP / 'projects'),
           BG_PROJECTS_DIR=str(TMP / 'projects'), CTX_GUARD_OFF='1', DW_DEADLINE_ARMED='1',
           BRIEF_LINES_DIR=str(TMP / 'brief-lines'), DCQ_HOME=str(TMP / 'dcq'), BG_RESULT_GRACE_SEC='0')
ENV = {k: v.replace(os.environ['MYTHOS_TEST_SANDBOX'], str(TMP)) for k, v in ENV.items()}
def stub(name, body):
    p = TMP / name
    p.write_text(body); p.chmod(0o755)
    return str(p)
def run(name, *args, env=None):
    return subprocess.run([str(ROOT / 'bin' / name), *map(str,args)], env=ENV | (env or {}),
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
def require(cond, msg):
    if not cond: raise AssertionError(msg)
def nested(r):
    if 'Operation not permitted' in r.stderr and 'sandbox' in r.stderr.lower():
        print('SKIP nested-sandbox'); return True
    return False
def jsonlines(p):
    return [json.loads(l) for l in P(p).read_text().splitlines() if l]
def quick():
    q = ROOT / 'bin/quick'
    (ROOT / 'bin/free-models').write_text('#!/bin/sh\necho fixture/free\n')
    (ROOT / 'bin/free-models').chmod(0o755)
    work = TMP / 'work'; work.mkdir()
    cache = TMP / 'cache'; cache.mkdir()
    ENV.update(TMPDIR=str(cache), XDG_DATA_HOME=str(TMP / 'data'), XDG_CACHE_HOME=str(cache),
               QUICK_OC=stub('oc', '#!/usr/bin/env python3\nimport json,os,pathlib\n' +
                 "p=pathlib.Path(os.environ['VICTIM'])\n" +
                 ("\ntry:p.write_text('changed')\nexcept PermissionError:pass\n" if MODE == 'readonly' else
                  "\ntry:leak=p.read_text()\nexcept PermissionError:leak='blocked'\nprint(json.dumps({'type':'text','part':{'text':leak}}))\n") +
                 "print(json.dumps({'type':'text','part':{'text':'ok'}}))\n"))
    if MODE == 'readonly':
        victim = work / 'victim'; victim.write_text('original'); ENV['VICTIM'] = str(victim)
        r = run('quick', work, '檢查檔案')
        if nested(r):
            profile = runpy.run_path(str(q))['sandbox_prefix'](str(work))
            require(profile[0] == '/usr/bin/sandbox-exec' and '(deny file-write*)' in profile[2], '唯讀 profile 缺失')
            print('PASS quick 唯讀 profile；OS 阻擋待沙箱外驗證')
            return
        if not P('/usr/bin/sandbox-exec').exists():
            require('沒有事前沙箱' in r.stderr, '無 sandbox-exec 未警告降級')
            print('PASS downgrade warning; SKIP no-sandbox-exec'); return
        require(victim.read_text() == 'original', 'quick 未阻擋事前寫入，victim 已被修改')
        require(r.returncode == 0, f'唯讀 runner 失敗 {r.stderr}')
        print('PASS quick 阻擋隱藏在 Python 的寫入')
    else:
        for d in ['.creds', '.ssh', '.aws', '.gnupg', '.env.d']:
            target = TMP / 'home' / d; target.mkdir()
            ENV['VICTIM'] = str(target / 'secret'); P(ENV['VICTIM']).write_text('SECRET')
            r = run('quick', target, '列出檔案')
            require(r.returncode == 4, f'敏感 cwd {d} 應 exit 4，得到 {r.returncode}')
        extra = TMP / 'private'; extra.mkdir(); link = TMP / 'alias'; link.symlink_to(extra, target_is_directory=True)
        r = run('quick', link, '列出檔案', env={'QUICK_DENY_READ':str(extra)})
        require(r.returncode == 4, '追加 deny 與 cwd symlink 未封鎖')
        print('PASS quick 敏感 cwd、symlink 與追加 deny 的事前拒絕')
        if not P('/usr/bin/sandbox-exec').exists():
            print('SKIP no-sandbox-exec'); return
        for target in [TMP / 'home/.ssh/secret', work / '.env.local', link / 'key']:
            target.write_text('SECRET'); ENV['VICTIM'] = str(target)
            r = run('quick', work, '檢查檔案', env={'QUICK_DENY_READ':str(extra)})
            if nested(r):
                with mock.patch.dict(os.environ, ENV | {'QUICK_DENY_READ':str(extra)}):
                    profile=runpy.run_path(str(q))['sandbox_prefix'](str(work))[2]
                require('(deny file-read*' in profile and '.env' in profile and str(extra) in profile, '敏感讀取 profile 缺失')
                print('PASS quick 敏感讀取 profile；OS 阻擋待沙箱外驗證')
                return
            require(r.returncode == 0 and 'SECRET' not in r.stdout, f'敏感檔案可讀：{target.name}')
        print('PASS quick 敏感 cwd、symlink、.env 與追加 deny')

CLAUDE_STUB = '''#!/usr/bin/env python3
import fcntl,json,os,pathlib,sys,time
p=pathlib.Path(os.environ['MYTHOS_TEST_SANDBOX']); state=p/'agents.json'
args=sys.argv[1:]
if args[0]=='agents': print(state.read_text() if state.exists() else '[]');sys.exit(0)
if args[0]=='stop':sys.exit(0)
if args[0]=='logs':print('fixture logs');sys.exit(0)
with open(p/'counter','a+') as f:
 fcntl.flock(f,fcntl.LOCK_EX);f.seek(0);n=int(f.read() or 0)+1;f.seek(0);f.truncate();f.write(str(n));f.flush()
 sid='a%07x'%n
 with open(p/'calls.jsonl','a') as c:c.write(json.dumps(args)+'\\n')
 time.sleep(.2)
 state.write_text(json.dumps([{'sessionId':sid+'-1111-2222-3333-444455556666','state':'working','pid':54321+n}]))
 print('backgrounded · '+sid+' · fixture')
'''
def bg_setup():
    ENV.update(CLAUDE_BIN=stub('claude',CLAUDE_STUB), TMUX_BIN=stub('tmux','#!/bin/sh\necho idle\n'),
               DISPATCH_BG_BIN=str(ROOT / 'bin/dispatch-bg'), DISPATCH_CANCEL_BIN=stub('cancel','#!/bin/sh\nexit 0\n'),
               BRIEF_BIN=stub('brief','#!/bin/sh\ncat >/dev/null\n'),
               TG_SEND_BIN=stub('send.mjs',"process.stdin.resume();process.exit(1)\n"))
    task=TMP / 'p.md'; task.write_text('request_id=tg:42:5\n> 初始任務\n')
    return task
def done():
    a=json.loads((TMP/'agents.json').read_text());a[-1]['state']='done';(TMP/'agents.json').write_text(json.dumps(a))
    sid=a[-1]['sessionId'][:8];(M/f'state/bg/{sid}.result').write_text('thread=t-a\n摘要：\n[靜默]\n---細節---\n完成\n')
    return sid

def mailbox():
    task=bg_setup(); task2=TMP/'p2.md'; task2.write_text('request_id=tg:42:6\n> 補充 B\n')
    ps=[subprocess.Popen([str(ROOT/'bin/dispatch-bg'),'t-a',str(p)],env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for p in [task,task2]]
    out=[p.communicate(timeout=25) for p in ps]
    require(all(p.returncode==0 for p in ps),f'併發派工失敗 {out}')
    calls=jsonlines(TMP/'calls.jsonl')
    require(len(calls)==1,f'同 thread 啟動了 {len(calls)} 個 worker，應為 1')
    files=list((M/'state/mailbox/t-a').glob('*.md'))
    require(len(files)==1,'新訊息沒有原子落入 mailbox 單檔')
    queued_text=files[0].read_text()
    done();r=run('dispatch-watch');require(r.returncode==0,f'watch 失敗 {r.stderr}')
    calls=jsonlines(TMP/'calls.jsonl');require(len(calls)==2,'worker 結束後未續派 mailbox')
    require('--resume' in calls[-1] and queued_text.strip() in calls[-1][-1], '續派未帶原 session 與信箱內容')
    require(not list((M/'state/mailbox/t-a').glob('*.md')),'續派後 mailbox 未清空')
    run('dispatch-watch');require(len(jsonlines(TMP/'calls.jsonl'))==2,'同批信箱被重派兩次')
    print('PASS thread 併發保留、mailbox、續派一次與清空')

def autoheal():
    task=bg_setup(); r=run('dispatch-bg','t-a',task);require(r.returncode==0,r.stderr)
    agents=json.loads((TMP/'agents.json').read_text());sid=agents[0]['sessionId'][:8];agents[0]['state']='failed';(TMP/'agents.json').write_text(json.dumps(agents))
    # launcher 已成功登錄後，讓父 watch 在 ACK 前中斷；intent 必須先落地。
    real=ENV['DISPATCH_BG_BIN']
    ENV['DISPATCH_BG_BIN']=stub('crash-launch',f'#!/bin/bash\n"{real}" "$@"\nkill -TERM "$PPID"\n')
    r=run('dispatch-watch');require(r.returncode!=0,'故障注入沒有中斷 watch')
    intents=list((M/'state/bg/autoheal').glob('*.json'))
    require(len(intents)==1,'重派前沒有持久化 intent')
    require(len(jsonlines(TMP/'calls.jsonl'))==2,'故障注入前未重派成功')
    ENV['DISPATCH_BG_BIN']=real
    r=run('dispatch-watch');require(r.returncode==0,r.stderr)
    require(len(jsonlines(TMP/'calls.jsonl'))==2,'登錄成功後 crash 又重派一次')
    require(not list((M/'state/bg/autoheal').glob('*.json')),'恢復後 intent 未清')
    ev=[x for x in jsonlines(M/'state/events.jsonl') if x['event_id']==f'bg-{sid}-FAIL'][0]
    require(ev.get('direct')=='retried' and ev.get('acked_at'),'殘留 intent 沒有 ACK 收尾')
    # 另造「intent 已寫、尚未派」；事件已存在時也要補做一次。
    pending=M/'state/bg/t-z-autoretry-1.md';pending.write_text('> 接續 Z\n')
    marker=M/'state/bg/autoheal/bg-ffffffff-FAIL.json';marker.parent.mkdir(exist_ok=True)
    marker.write_text(json.dumps(dict(id='bg-ffffffff',eid='bg-ffffffff-FAIL',thread='t-z',task=str(task),extra='fixture',kind='FAIL',prompt=str(pending))))
    with open(M/'state/events.jsonl','a') as f:f.write(json.dumps(dict(event_id='bg-ffffffff-FAIL',job_id='bg-ffffffff',status='FAIL',task=str(task),created=int(time.time()),tries=0,acked_at=None))+'\n')
    run('dispatch-watch');run('dispatch-watch')
    require(len(jsonlines(TMP/'calls.jsonl'))==3 and not marker.exists(),'派工前 crash 未補一次或重複補派')
    print('PASS autoheal 派工前後 crash 恢復與同 eid 冪等')

if MODE in ('readonly','sensitive'):quick()
elif MODE=='mailbox':mailbox()
elif MODE=='autoheal':autoheal()

def proxy_start(content='交辦', locked=False):
    ENV.update(TG_API_STUB=str(TMP/'api.log'), TG_BUSY_FILE=str(TMP/'busy'), TG_TYPING_MS='100',
               TG_COMMANDS_CHILD='node '+stub('child.mjs', '''import fs from 'node:fs';
const m={jsonrpc:'2.0',method:'notifications/claude/channel',params:{content:process.env.FIX_CONTENT,meta:{chat_id:'42',message_id:'5'}}};
console.log(JSON.stringify(m)); console.log(JSON.stringify({jsonrpc:'2.0',id:99,result:{ok:true}}));
let b='';process.stdin.on('data',d=>{b+=d;let n;while((n=b.indexOf('\\n'))>=0){const l=b.slice(0,n);b=b.slice(n+1);try{const m=JSON.parse(l);console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{content:[{type:'text',text:'ok'}]}}))}catch{}}});
setInterval(()=>{},1000);
'''), FIX_CONTENT=content, DISPATCH_BG_BIN=str(ROOT/'bin/dispatch-bg'))
    (TMP/'busy').touch()
    out=open(TMP/'proxy.out','w');err=open(TMP/'proxy.err','w')
    p=subprocess.Popen(['node',str(ROOT/'bin/tg-commands.mjs')],env=ENV,stdin=subprocess.PIPE,stdout=out,stderr=err,text=True)
    return p,out,err

def wait_for(fn, msg):
    until=time.monotonic()+5
    while time.monotonic()<until:
        if fn():return
        time.sleep(.05)
    raise AssertionError(msg)
def stop_proxy(p, out, err):
    p.stdin.close();p.wait(timeout=7);out.close();err.close()
def requests():
    task=bg_setup()
    p,out,err=proxy_start()
    wait_for(lambda:(TMP/'api.log').exists() and '收到，等等處理' in (TMP/'api.log').read_text(),'proxy 未 ACK')
    stop_proxy(p,out,err)
    transcript=TMP/'chat.jsonl'
    transcript.write_text(json.dumps(dict(type='user',origin={'kind':'channel'},message={'content':'<channel source="telegram" chat_id="42" message_id="5">\n交辦\n</channel>'}))+'\n')
    result=run('chat-prompt.mjs',transcript,'t-a');require(result.returncode==0,result.stderr)
    task=P(result.stdout.strip());require('request_id=tg:42:5' in task.read_text(),'chat-prompt 沒有帶 request id')
    r=run('dispatch-bg','t-a',task);require(r.returncode==0,r.stderr);job=r.stdout.strip()
    # 真 tg-send 對本機 HTTP stub，不接 Telegram；驗證 answer-sent 記成功回應時間。
    preload=stub('fetch-stub.mjs', 'globalThis.fetch=async()=>({ok:true,text:async()=>JSON.stringify({ok:true,result:{message_id:99}})})\n')
    access=TMP/'telegram';access.mkdir();(access/'access.json').write_text('{"allowFrom":["42"]}')
    sent=subprocess.run(['node','--import',preload,str(ROOT/'bin/tg-send'),'--thread','t-a','--job',job],input='fixture',text=True,capture_output=True,
          env=ENV | {'TG_API_BASE':'http://127.0.0.1:1','TELEGRAM_STATE_DIR':str(access),'TELEGRAM_BOT_TOKEN':'fixture'},timeout=10)
    require(sent.returncode==0,sent.stderr)
    # 計時檔壞掉也不能把 Telegram 成功改成失敗，否則上游會重送。
    broken=TMP/'broken';(broken/'state/requests.jsonl').mkdir(parents=True)
    again=subprocess.run(['node','--import',preload,str(ROOT/'bin/tg-send'),'--thread','t-a','--job',job],input='fixture',text=True,capture_output=True,
          env=ENV | {'MYTHOS_DIR':str(broken),'MYTHOS_REQUEST_ID':'tg:42:8','TG_API_BASE':'http://127.0.0.1:1','TELEGRAM_STATE_DIR':str(access),'TELEGRAM_BOT_TOKEN':'fixture'},timeout=10)
    require(again.returncode==0 and 'request 紀錄寫入失敗' in again.stderr,'計時檔失敗讓已送出的答案被改判未送')
    rows=jsonlines(M/'state/requests.jsonl'); stages={r['stage'] for r in rows if r['request_id']=='tg:42:5'}
    require({'received','ack','queued','worker-start','answer-sent'} <= stages, f'id 未貫穿五個階段 {stages}')
    # 精確時間樣本，舊版 n/p50 仍由原 transcript 掃描，不受新事件筆數影響。
    base=int(time.time()*1000)-10000
    with open(M/'state/requests.jsonl','a') as f:
        for stage,delta in [('received',0),('ack',1000),('queued',2000),('worker-start',4000),('answer-sent',9000)]:
            f.write(json.dumps(dict(request_id='tg:42:6',stage=stage,ts=base+delta))+'\n')
    with open(M/'state/requests.jsonl','a') as f:f.write('invalid-json\nnull\n')
    r=run('latency-report','--by-id','--json');require(r.returncode==0,f'--by-id 失敗 {r.stderr}')
    row=next(x for x in json.loads(r.stdout) if x['request_id']=='tg:42:6')
    require([row[k] for k in ['ack_s','answer_s','completion_s','queue_s','start_s']]==[1,5,9,2,2],f'分段不符 {row}')
    start=time.time()-60
    ts=lambda delta:datetime.datetime.fromtimestamp(start+delta,datetime.timezone.utc).isoformat()
    legacy=[dict(type='user',timestamp=ts(0),message={'content':'<channel source="telegram">舊訊息</channel>'}),
            dict(type='assistant',timestamp=ts(2),message={'content':[dict(type='tool_use',id='reply-old',name='mcp__telegram__reply')]}),
            dict(type='user',timestamp=ts(3),message={'content':[dict(type='tool_result',tool_use_id='reply-old',content='ok')]})]
    (TMP/'rt/r.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in legacy))
    r=run('latency-report','--json');old=json.loads(r.stdout)
    require(old['n']==1 and old['p50_s']==3,'舊資料 n/p50 被 request 事件污染')
    print('PASS request id 五階段貫穿、分段數值與舊 n/p50')

TMUX_CTX = '''#!/usr/bin/env python3
import json,os,pathlib,sys,time
p=pathlib.Path(os.environ['MYTHOS_TEST_SANDBOX']);a=sys.argv[1:]
with open(p/'keys.jsonl','a') as f:f.write(json.dumps(a)+'\\n')
mode=os.environ.get('CTX_TEST_MODE','')
if 'capture-pane' in a:
 f=p/'captures';n=int(f.read_text() if f.exists() else 0)+1;f.write_text(str(n))
 if mode=='before' and n==2:os.utime(os.environ['CTX_TEST_TP'],None)
 print('❯ pending' if mode=='input' else '❯ ')
if '/compact' in a:
 if not (pathlib.Path(os.environ['MYTHOS_DIR'])/'state/router-compact.lock').exists():
  (p/'unlocked-send').touch()
 if mode=='after':os.utime(os.environ['CTX_TEST_TP'],None)
if 'Enter' in a and mode=='complete':
 with open(os.environ['CTX_TEST_TP'],'a') as f:f.write('{"type":"system","subtype":"compact_boundary"}\\n')
'''
def compact():
    tp=TMP/'rt/router.jsonl'
    ENV.update(CTX_DIRS=str(TMP/'rt'), CTX_ROUTER_DIR=str(TMP/'rt'), CTX_STATE_DIR=str(M/'state'),
               CTX_LOG=str(TMP/'ctx.log'), CTX_TMUX_BIN=stub('ctx-tmux',TMUX_CTX), CTX_TEST_TP=str(tp))
    def reset(mode):
        tp.write_text(json.dumps(dict(type='assistant',message={'usage':{'input_tokens':210001}}))+'\n')
        for f in [M/'state/ctx-guard.json', M/'state/router-compact.lock',TMP/'keys.jsonl', TMP/'captures', TMP/'unlocked-send']:
            f.unlink(missing_ok=True)
        ENV['CTX_TEST_MODE']=mode
    def keys():return jsonlines(TMP/'keys.jsonl')
    for mode in ['input','before','after']:
        reset(mode);r=run('ctx-guard','scan');require(r.returncode==0,r.stderr)
        require(not any('Enter' in x for x in keys()),f'compact {mode} 競態仍送 Enter')
        require(not (M/'state/router-compact.lock').exists(),'取消 compact 沒釋放鎖')
    reset('wait');run('ctx-guard','scan')
    require(not (TMP/'unlocked-send').exists(),'compact 送鍵前沒有取共用鎖')
    lock=M/'state/router-compact.lock';require(lock.exists(),'壓縮未完成就釋放鎖')
    lk=json.loads(lock.read_text());require(0<lk['expires']-time.time()<=600,'鎖期限超過 10 分鐘')
    p,out,err=proxy_start('壓縮中補充')
    try:
        wait_for(lambda:(TMP/'proxy.out').exists() and '"id":99' in (TMP/'proxy.out').read_text(),'maintenance 卡住 RPC')
        time.sleep(.2)
        require('壓縮中補充' not in (TMP/'proxy.out').read_text(),'maintenance 沒有攔住 channel')
        wait_for(lambda:bool(list((M/'state/router-mailbox').glob('*.json'))),'訊息沒持久化排隊')
        wait_for(lambda:(TMP/'api.log').exists() and '收到，等等處理' in (TMP/'api.log').read_text(),'壓縮期間未 ACK')
        with open(tp,'a') as f:f.write('{"type":"system","subtype":"compact_boundary"}\n')
        run('ctx-guard','scan')
        wait_for(lambda:'壓縮中補充' in (TMP/'proxy.out').read_text(),'壓縮完成沒有放行排隊訊息')
        require(not lock.exists(),'compact_boundary 完成後未釋放')
    finally:stop_proxy(p,out,err)
    # proxy 也能清過期鎖；不需要等到下一輪 watch。
    lock.write_text(json.dumps(dict(expires=time.time()-1)))
    p,out,err=proxy_start('過期後繼續')
    try:wait_for(lambda:'過期後繼續' in (TMP/'proxy.out').read_text(),'鎖逾期仍擋訊息')
    finally:stop_proxy(p,out,err)
    print('PASS compact 送前後競態、共用鎖、ACK/持久佇列、RPC 透傳、完成與逾期釋放')

if MODE=='requests':requests()
elif MODE=='compact':compact()
