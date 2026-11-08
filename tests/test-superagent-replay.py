#!/usr/bin/env python3
"""P5 離線重播量測：follow-up 路由三策略（現行路由／關閉直通／最小直通）。stdlib only。

用法：python3 tests/test-superagent-replay.py --seed 20261108 --runs 5 --offline [--inject-drop [event|control]]
通過：最後一行 REPLAY_OK（rc 0）。任一項失敗：列 FAIL 行、最後一行 REPLAY_FAIL（rc 1）。
不連網、不打 TG、不起 hermes、不讀 ~/.hermes；--offline 必填。

選擇（ponytail）：用 Python 重現規則，不在 mktemp 沙箱跑 bin/*。
  - bin/followup-direct 的判斷順序（去重 → rmid 對照 → 任務狀態 → 新話題規則 → 入列）照其步驟 1:1 重現（classify_text／direct_decide）。
  - bin/dispatch-bg 的 slot 上限（MYTHOS_HERMES_SLOTS 預設 3）、同 repo 寫入序列化、hermes-queue FIFO（可跳過被擋項）、
    dispatch-watch 的信箱批次與輪詢，以模擬時鐘重現。
  代價：規則若在 bash 改了，這裡不會自動知道。升級路徑：改在 mktemp 沙箱跑真腳本做交叉比對。

限制／假設（全部未與真系統比對，皆為假設）：
  - Router 判斷視為正確（ground truth）；直通的錯派只來自 followup-direct 關鍵字規則漏判（中性文字的新話題）。
  - 固定假延遲：Router 3.0s、一次一則（串行）；dispatch-watch 輪詢 5.0s；cancel 生效 1.0s（不含真實 kill 耗時）。
  - worker 時長：seed 決定的 lognormal（中位 60s，夾 10–600s），按 job 內容鍵取值，三策略相同。
  - thread 序列化：同 thread 同時只跑一個 job（信箱規則；Router 路徑假設相同）。
  - 使用者看到結果才回：follow-up 到達 = max(排程時間, 被回覆結果送達時刻)。事件內容與順序三策略一致。
  - Telegram 層重播（同 chat+fmid）：S1／S2 假設 TG 層已去重（未實測）；S3 的重播進直通判斷，
    直通去重只擋「已入列」的收據，被交回 Router 的重播會再進 Router（報表的「重複結果」會計到）。
  - token 欄不量，一律 unsupported。
"""
import argparse
import heapq
import math
import random
import re
import sys

ROUTER_S = 3.0      # 假：Router 單次回應（串行）
CANCEL_S = 1.0      # 假：cancel 生效（dispatch-cancel 殺行程樹）
POLL_S = 5.0        # 假：dispatch-watch 輪詢（信箱批次、hermes-queue 排空）
SLOTS = 3           # 同 MYTHOS_HERMES_SLOTS 預設
N_NEW = 24
REPOS = ["repo-a", "repo-b", "repo-c"]
STRATS = [("S1", "現行路由", "legacy"), ("S2", "關閉直通", "flag_off"), ("S3", "最小直通", "direct")]
NEW_PREFIX = ("新題", "新的題", "換一題", "換個話題", "另一題", "另外一件")   # 同 followup-direct 步驟 3
THREAD_RE = re.compile(r"t-[a-z0-9][a-z0-9-]{3,30}")
CONT = ["這個結果再加一個欄位", "改用表格呈現", "順便補上測試", "範圍縮小到 README", "好，照這個做", "第二段講細一點"]
NEWKW = ["新題：幫我查另一件事", "換一題，問天氣", "新的題目：整理會議紀錄"]
UNDET = ["幫我另外查一下價格", "來個完全不同的想法"]   # 沒命中關鍵字：直通會誤判成續問
UNMAP = ["收到", "ok"]                              # 回覆的不是已知結果訊息（rmid 不在對照表）
REQ_KINDS = ("new", "fu", "interrupt")
TERM_KINDS = ("done", "cancelled", "handoff", "noop", "dedup")


def classify_text(text, own):
    """同 bin/followup-direct 步驟 3：0＝可直通，6＝交 Router。"""
    if not re.sub(r"\s", "", text):
        return 6
    if text.startswith(NEW_PREFIX):
        return 6
    if any(m != own for m in THREAD_RE.findall(text)):
        return 6
    return 0


def next_tick(t):
    return (math.floor(t / POLL_S) + 1) * POLL_S


def dur_of(seed, key):
    r = random.Random(f"dur:{seed}:{key}")
    return min(600.0, max(10.0, r.lognormvariate(math.log(60.0), 0.6)))


def gen_stream(seed):
    """同一 seed 必得同一份事件流（三策略共用）。"""
    rng = random.Random(f"stream:{seed}")
    evs = []
    t = 0.0
    fmid = 1000
    for i in range(N_NEW):
        t += rng.expovariate(1 / 120.0)
        nid, th = f"n{i:02d}", f"t-{i:03d}xq"
        repo, ro = rng.choice(REPOS), rng.random() < 0.25
        evs.append(dict(id=nid, kind="new", t=round(t, 3), thread=th, repo=repo, ro=ro))
        if rng.random() < 0.25:
            evs.append(dict(id=f"c{i:02d}", kind="cancel", t=round(t + rng.uniform(5, 60), 3), thread=th))
        if rng.random() < 0.15:
            evs.append(dict(id=f"i{i:02d}", kind="interrupt", t=round(t + rng.uniform(10, 90), 3),
                            thread=th, repo=repo, ro=ro, text="改口：範圍縮小"))
        r = rng.random()
        if r >= 0.6:
            continue
        n = 1 if r < 0.4 else rng.randint(3, 5)   # 0.4–0.6 是 burst：同一則結果短時間多則回覆
        base = t + rng.uniform(30, 240)
        for k in range(n):
            fid = f"f{i:02d}{k}"
            if n > 1:
                cls = "cont"
            else:
                x = rng.random()
                cls = ("cont" if x < 0.80 else "newkw" if x < 0.85 else "other" if x < 0.89
                       else "undet" if x < 0.95 else "unmapped")
            if cls == "other":
                text = f"順便看 t-{(i + 1) % N_NEW:03d}xq 那題"
            else:
                text = rng.choice({"cont": CONT, "newkw": NEWKW, "undet": UNDET, "unmapped": UNMAP}[cls])
            truth = {"cont": "cont", "newkw": "new", "other": "cont", "undet": "new", "unmapped": "unmapped"}[cls]
            rjob = None if cls == "unmapped" else nid
            same = truth == "cont"
            fmid += 1
            ev = dict(id=fid, kind="fu", t=round(base + k * rng.uniform(0.2, 2.0), 3),
                      thread=th if rjob else None,
                      repo=repo if same else rng.choice(REPOS), ro=ro if same else False,
                      rjob=rjob, text=text, truth=truth, fmid=fmid, chat=1)
            evs.append(ev)
            if rng.random() < 0.10:   # 同 fmid 重播（t 由原事件到達後 +2s 排入）
                evs.append(dict(ev, id=fid + "r", replay_of=fid, t=None))
    return {"seed": seed, "events": evs}


class Sim:
    """單一策略的離散事件重播。mode：legacy（全回 Router）／flag_off（同 legacy，flag 關）／direct（最小直通）。"""

    def __init__(self, stream, mode, inject):
        self.seed = stream["seed"]
        self.mode = mode
        self.inject = inject
        self.ev = {e["id"]: e for e in stream["events"]}
        self.order = [e["id"] for e in stream["events"]]
        self.heap, self.seq, self.now = [], 0, 0.0
        self.router_free, self.router_calls = 0.0, 0
        self.jobs, self.job_n = {}, 0
        self.q, self.running = [], []
        self.mailbox, self.receipts = {}, set()
        self.term, self.arrived = {}, {}
        self.waiting, self.new_job, self.tinfo = {}, {}, {}
        self.replay_map, self.delivered_fmid = {}, set()
        self.ctrl, self.target_of = {}, {}
        self.resp, self.cancel_eff, self.qwait, self.batch = [], [], [], []
        self.misroute, self.dup = 0, 0
        ctrl = sorted((e for e in stream["events"] if e["kind"] in ("cancel", "interrupt")),
                      key=lambda e: (e["t"], e["id"]))
        self.inject_ctrl = ctrl[0]["id"] if ctrl else None
        for e in stream["events"]:
            if e.get("replay_of"):
                self.replay_map[e["replay_of"]] = e["id"]
        for e in stream["events"]:
            k = e["kind"]
            if k == "new":
                self.tinfo[e["thread"]] = (e["repo"], e["ro"])
                self.at(e["t"], self.arrive, e["id"])
            elif k == "fu":
                if e.get("replay_of"):
                    continue
                if e["rjob"] is not None:
                    self.waiting.setdefault(e["rjob"], []).append(e["id"])
                else:
                    self.at(e["t"], self.arrive, e["id"])
            else:
                self.at(e["t"], self.arrive, e["id"])

    # ---- 事件骨架 ----
    def at(self, t, fn, *args):
        heapq.heappush(self.heap, (t, self.seq, fn, args))
        self.seq += 1

    def run(self):
        n = 0
        while self.heap:
            t, _, fn, args = heapq.heappop(self.heap)
            self.now = t
            fn(*args)
            n += 1
            if n > 500000:
                raise RuntimeError("事件數超過上限，疑似迴圈")

    def router(self, fn, *args):
        start = max(self.now, self.router_free)
        done = start + ROUTER_S
        self.router_free = done
        self.router_calls += 1
        self.at(done, fn, *args)

    # ---- 入口 ----
    def arrive(self, eid):
        e = self.ev[eid]
        self.arrived[eid] = self.now
        if eid in self.replay_map:
            self.at(self.now + 2.0, self.arrive, self.replay_map[eid])
        if self.inject == "event" and eid == "n00":          # 注入：第一則新題在入口被吞掉
            return
        if self.inject == "control" and eid == self.inject_ctrl:  # 注入：第一個控制事件被吞掉
            return
        k = e["kind"]
        if k == "new":
            self.router(self.on_new, eid)
        elif k == "fu":
            self.on_fu(eid)
        elif k == "cancel":
            self.on_control(eid, False)
        else:
            self.router(self.on_control, eid, True)

    def on_new(self, eid):
        e = self.ev[eid]
        j = self.make_job(e["thread"], e["repo"], e["ro"], [eid])
        self.new_job[eid] = j["id"]
        self.submit(j)

    def on_fu(self, eid):
        e = self.ev[eid]
        if self.mode == "direct":
            code = self.direct_decide(e)
            if code == "dup":
                self.term[eid] = ("dedup", self.now)
                return
            if code == "queue":
                self.mailbox_add(e)
                return
        elif e.get("replay_of"):
            self.term[eid] = ("dedup", self.now)   # S1／S2：假設 TG 層已去重
            return
        self.route_fu(e)

    # ---- followup-direct 重現 ----
    def direct_decide(self, e):
        if (1, e["fmid"]) in self.receipts:                  # 步驟 0：同 chat+fmid 已入列 → dup
            return "dup"
        rj = e["rjob"]
        jid = self.new_job.get(rj) if rj else None           # 步驟 1：rmid 要對到已知結果
        if jid is None:
            return "4"
        j = self.jobs[jid]
        if j["state"] == "cancelled":                        # 步驟 2：已取消＝舊 generation
            return "7"
        if j["state"] != "done":
            return "4"
        if classify_text(e["text"], e["thread"]):            # 步驟 3：新話題 → Router
            return "6"
        return "queue"                                       # 步驟 4：入列（信箱）

    def mailbox_add(self, e):
        self.receipts.add((1, e["fmid"]))
        self.mailbox.setdefault(e["thread"], []).append(e["id"])
        if e["truth"] == "new":
            self.misroute += 1                               # 新話題被續問進舊 thread
        self.at(next_tick(self.now), self.mailbox_pump)

    def mailbox_pump(self):
        for th in sorted(self.mailbox):
            ids = self.mailbox[th]
            if not ids or self.thread_busy(th):
                continue
            self.mailbox[th] = []
            repo, ro = self.tinfo[th]
            j = self.make_job(th, repo, ro, ids)
            self.submit(j, enq=min(self.arrived[x] for x in ids))

    # ---- Router 路徑 ----
    def route_fu(self, e):
        if e["truth"] == "unmapped":
            self.router(self.handoff, e["id"])
        elif e["truth"] == "new":
            self.router(self.new_topic_job, e["id"])
        else:
            self.router(self.same_thread_job, e["id"])

    def handoff(self, eid):
        self.deliver_fmid(eid)
        self.term[eid] = ("handoff", self.now)
        self.resp.append(self.now - self.arrived[eid])

    def new_topic_job(self, eid):
        e = self.ev[eid]
        th = f"t-{eid}"
        self.tinfo[th] = (e["repo"], e["ro"])
        self.submit(self.make_job(th, e["repo"], e["ro"], [eid]))

    def same_thread_job(self, eid):
        th = self.ev[self.ev[eid]["rjob"]]["thread"]
        repo, ro = self.tinfo[th]
        self.submit(self.make_job(th, repo, ro, [eid]))

    # ---- 控制事件（cancel／interrupt；interrupt 先過 Router）----
    def on_control(self, eid, then_new):
        th = self.ev[eid]["thread"]
        tgt = next((j for j in self.running if self.jobs[j]["thread"] == th), None)
        self.target_of[eid] = tgt
        self.at(self.now + CANCEL_S, self.cancel_effect, eid, th, tgt, then_new)

    def cancel_effect(self, eid, th, tgt, then_new):
        killed = False
        if tgt is None:
            outcome = "no-target"
        elif self.jobs[tgt]["state"] == "running":
            self.running.remove(tgt)
            self.jobs[tgt]["state"] = "cancelled"
            self.kill_terms(self.jobs[tgt])
            self.close(self.jobs[tgt])
            self.cancel_eff.append(self.now - self.arrived[eid])
            killed, outcome = True, "killed"
        else:
            outcome = "done-first"
        for jid in list(self.q):                             # 未開工的排隊項：同 thread 丟掉（dispatch-cancel 行為）
            j = self.jobs[jid]
            if j["thread"] == th:
                self.q.remove(jid)
                j["state"] = "cancelled"
                self.kill_terms(j)
                self.close(j)
        for rid in self.mailbox.pop(th, []):                 # 信箱未派出的：舊 generation，作廢
            self.term[rid] = ("cancelled", self.now)
        self.ctrl[eid] = outcome
        if then_new:
            repo, ro = self.tinfo[th]
            self.submit(self.make_job(th, repo, ro, [eid]))
        elif killed or outcome != "killed":
            self.term[eid] = ("cancelled" if killed else "noop", self.now)
        self.at(self.now, self.pump)

    def kill_terms(self, j):
        for rid in j["reqs"]:
            self.term[rid] = ("cancelled", self.now)

    # ---- slot／repo／thread 排程 ----
    def make_job(self, th, repo, ro, reqs):
        self.job_n += 1
        jid = f"j{self.job_n:03d}"
        j = dict(id=jid, thread=th, repo=repo, ro=ro, reqs=list(reqs),
                 dur=dur_of(self.seed, "+".join(reqs)), enq=None, start=None, state="new")
        self.jobs[jid] = j
        return j

    def submit(self, j, enq=None):
        j["enq"] = self.now if enq is None else enq
        j["state"] = "queued"
        self.q.append(j["id"])
        self.at(self.now, self.pump)

    def thread_busy(self, th):
        return any(self.jobs[x]["thread"] == th for x in self.running + self.q)

    def pump(self):
        for jid in list(self.q):
            if len(self.running) >= SLOTS:
                break
            j = self.jobs[jid]
            if any(self.jobs[x]["thread"] == j["thread"] for x in self.running):
                continue
            if not j["ro"] and any(self.jobs[x]["repo"] == j["repo"] and not self.jobs[x]["ro"]
                                   for x in self.running):
                continue                                     # 同 repo 寫入序列化：跳過（不擋後面不同 repo）
            self.q.remove(jid)
            j["state"] = "running"
            j["start"] = self.now
            self.running.append(jid)
            self.qwait.append(self.now - j["enq"])
            self.batch.append(len(j["reqs"]))
            self.at(self.now + j["dur"], self.finish, jid)

    def finish(self, jid):
        j = self.jobs[jid]
        if j["state"] != "running":
            return
        j["state"] = "done"
        self.running.remove(jid)
        for rid in j["reqs"]:
            self.deliver_fmid(rid)
            self.term[rid] = ("done", self.now)
            self.resp.append(self.now - self.arrived[rid])
        self.close(j)
        self.at(next_tick(self.now), self.pump)
        self.at(next_tick(self.now), self.mailbox_pump)

    def deliver_fmid(self, rid):
        fm = self.ev[rid].get("fmid")
        if fm is None:
            return
        if fm in self.delivered_fmid:
            self.dup += 1                                    # 同一則 follow-up 被答兩次
        self.delivered_fmid.add(fm)

    def close(self, j):
        """job 結束（完成或取消）：放出等它的 follow-up（超過原排程者以結束時間為準）。"""
        for rid in j["reqs"]:
            for fid in self.waiting.pop(rid, []):
                self.at(max(self.ev[fid]["t"], self.now), self.arrive, fid)


def control_swallowed(sim):
    out = []
    for eid in sim.order:
        if sim.ev[eid]["kind"] not in ("cancel", "interrupt"):
            continue
        oc = sim.ctrl.get(eid)
        if oc is None:
            out.append(eid)
            continue
        tgt = sim.target_of.get(eid)
        if tgt is None:
            continue
        st = sim.jobs[tgt]["state"]
        if (oc == "killed" and st != "cancelled") or (oc == "done-first" and st != "done"):
            out.append(eid)
    return out


def pct(xs, p):
    """最近秩百分位（nearest rank）。空＝None。"""
    if not xs:
        return None
    s = sorted(xs)
    k = max(1, math.ceil(p / 100.0 * len(s)))
    return s[k - 1]


def new_agg():
    return dict(reqs=0, cancelled_req=0, terms={k: 0 for k in TERM_KINDS}, resp=[], cancel=[], qwait=[],
                batch=[], misroute=0, dup=0, dropped=0, swallowed=0, router=0)


def run_all(seed, runs, inject):
    agg = {sid: new_agg() for sid, _, _ in STRATS}
    failures = []
    n_events = 0
    for i in range(runs):
        stream = gen_stream(seed + i)
        n_events += len(stream["events"])
        for sid, _name, mode in STRATS:
            sim = Sim(stream, mode, inject)
            sim.run()
            a = agg[sid]
            unrec = [eid for eid in sim.order if eid not in sim.term]
            a["dropped"] += len(unrec)
            # CHECK-RECONCILE-BEGIN
            if unrec:
                failures.append(f"UNRECONCILED run={i} {sid}: 無終態 {unrec[:5]}（共 {len(unrec)}）")
            # CHECK-RECONCILE-END
            sw = control_swallowed(sim)
            a["swallowed"] += len(sw)
            # CHECK-CONTROL-BEGIN
            if sw:
                failures.append(f"CONTROL-SWALLOWED run={i} {sid}: {sw[:5]}")
            # CHECK-CONTROL-END
            for eid in sim.order:
                if sim.ev[eid]["kind"] in REQ_KINDS:
                    a["reqs"] += 1
                    tk = sim.term.get(eid, ("missing", 0))[0]
                    if tk == "cancelled":
                        a["cancelled_req"] += 1
                if eid in sim.term and sim.term[eid][0] in a["terms"]:
                    a["terms"][sim.term[eid][0]] += 1
            a["resp"] += sim.resp
            a["cancel"] += sim.cancel_eff
            a["qwait"] += sim.qwait
            a["batch"] += sim.batch
            a["misroute"] += sim.misroute
            a["dup"] += sim.dup
            a["router"] += sim.router_calls
    return agg, failures, n_events


def summarize(a):
    """回傳 [(標籤, 值)]。延遲欄必有 p50／p95（缺就是報表退化成平均值，視為失敗）。"""
    b = a["batch"]
    rows = [
        ("請求數（new／fu／interrupt）", a["reqs"]),
        ("回應延遲 p50 (s)", pct(a["resp"], 50)),
        ("回應延遲 p95 (s)", pct(a["resp"], 95)),
        ("取消生效 p50 (s)", pct(a["cancel"], 50)),
        ("取消生效 p95 (s)", pct(a["cancel"], 95)),
        ("queue wait p50 (s)", pct(a["qwait"], 50)),
        ("queue wait p95 (s)", pct(a["qwait"], 95)),
        ("錯派（新話題被續問）", a["misroute"]),
        ("漏事件（無終態）", a["dropped"]),
        ("重複結果", a["dup"]),
        ("控制事件被吞", a["swallowed"]),
        ("被取消的請求", a["cancelled_req"]),
        ("終態 done/cancel/handoff/noop/dedup",
         "/".join(str(a["terms"][k]) for k in TERM_KINDS)),
        ("Router call 數", a["router"]),
        ("batch size 平均", round(sum(b) / len(b), 2) if b else None),
        ("batch size 最大", max(b) if b else None),
        ("token 用量", "unsupported"),
    ]
    return rows


PCT_LABELS = ("回應延遲", "取消生效", "queue wait")


def check_percentiles(agg):
    fails = []
    for sid, _n, _m in STRATS:
        for label, val in summarize(agg[sid]):
            if label.startswith(PCT_LABELS) and val is None:
                fails.append(f"報表缺樣本，無法算 {label}（{sid}）")
    return fails


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def render(agg, seed, runs, n_events):
    cols = [summarize(agg[sid]) for sid, _n, _m in STRATS]
    lines = [f"superagent-replay seed={seed} runs={runs} offline=1 事件合計={n_events}（三策略同一份事件流）",
             "指標（runs 次合併；p50／p95 為最近秩；時間單位秒）",
             f"{'指標':<34}" + "".join(f"{sid + ' ' + name:<16}" for sid, name, _m in STRATS)]
    for idx in range(len(cols[0])):
        label = cols[0][idx][0]
        lines.append(f"{label:<34}" + "".join(f"{fmt(c[idx][1]):<16}" for c in cols))
    lines.append("假設：Router 3.0s 串行、輪詢 5.0s、cancel 1.0s；worker 時長 seed 決定；token 不量。詳見檔頭。")
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(description="P5 離線重播量測（stdlib only）")
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--offline", action="store_true", help="必填：本測試不連網")
    ap.add_argument("--inject-drop", nargs="?", const="event", choices=["event", "control"], default=None,
                    help="注入漏事件 fixture（應該失敗）：event＝入口吞掉第一則新題；control＝吞掉第一個控制事件")
    args = ap.parse_args(argv)
    if not args.offline:
        print("需要 --offline（本測試不連網、不打 TG、不起 hermes）", file=sys.stderr)
        return 2
    if args.runs < 1:
        print("--runs 要 >= 1", file=sys.stderr)
        return 2

    agg, failures, n_events = run_all(args.seed, args.runs, args.inject_drop)
    failures += check_percentiles(agg)
    if summarize(agg["S1"]) != summarize(agg["S2"]):
        failures.append("flag-off 控制組（S2）與現行路由（S1）不一致：關閉直通不該改變行為")
    text = render(agg, args.seed, args.runs, n_events)
    print(text)

    if args.inject_drop is None:
        # 自測 1：注入漏事件必須失敗（證明終態對帳有作用）
        f_ev = run_all(args.seed, args.runs, "event")[1]
        if not any(f.startswith("UNRECONCILED") for f in f_ev):
            failures.append("SELFTEST 注入漏事件（event）未被偵測")
        # 自測 2：注入控制事件被吞必須失敗
        f_ct = run_all(args.seed, args.runs, "control")[1]
        if not any(f.startswith(("CONTROL-SWALLOWED", "UNRECONCILED")) for f in f_ct):
            failures.append("SELFTEST 注入控制事件被吞（control）未被偵測")
        # 自測 3：可重現（同 seed 再跑一次，報表逐字相同）
        text2 = render(run_all(args.seed, args.runs, None)[0], args.seed, args.runs, n_events)
        if text2 != text:
            failures.append("不可重現：同 seed 兩次報表不同")
        print(f"SELFTEST 注入漏事件：{len(f_ev)} 項失敗（預期 >0）；注入控制事件被吞：{len(f_ct)} 項失敗（預期 >0）；"
              f"重跑報表一致={text2 == text}")

    for f in failures:
        print("FAIL: " + f)
    if failures:
        print("REPLAY_FAIL")
        return 1
    print("REPLAY_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
