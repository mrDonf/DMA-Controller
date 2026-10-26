#!/usr/bin/env python3
"""
check_protocols.py - protocol / spec rule checker run on the simulation VCDs behind the waveform figures.

It re-checks, cycle by cycle on the DUT ports, the rules the waveform documentation relies on
(AMBA AXI5 / APB4 / AXI4-Stream / trigger 4-phase / Q-Channel and the DMA-350 TRM rules), so the
figures can be trusted as examples of correct behaviour and not only as pictures.

  python docs/waveform/tools/check_protocols.py --work <dir>

<dir> is the directory used by gen_all.py (VCDs in <dir>/vcd). Exit code 0 = no violation.
"""
import argparse, glob, os, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from vcdwave import Vcd

DW = 64
DWB = DW // 8
NCH = 4
FIFO_WORDS = {0: 16, 1: 8, 2: 32, 3: 4}      # build "default" (run_sim.py BASE)

class Report:
    def __init__(self):
        self.rows = []     # (test, rule, n_checked, n_fail, first_fail)
    def add(self, test, rule, n, bad, first=""):
        self.rows.append((test, rule, n, bad, first))

def ser(v, name):
    return v.series(name)

def fld(v, name, hi, lo=None):
    lo = hi if lo is None else lo
    m = (1 << (hi - lo + 1)) - 1
    return [None if (x is None or (x[1] >> lo) & m) else (x[0] >> lo) & m for x in v.raw(name)]

def axi_checks(v, rep, test, p):
    """AXI manager port rules for one port suffix p ('_m0' / '_m1')"""
    g = lambda n: ser(v, n + p)
    n = v.ncyc
    arv, arr, awv, awr, wv, wr, wl = (g(x) for x in ("arvalid", "arready", "awvalid", "awready", "wvalid", "wready", "wlast"))
    rv, rr, rl, rid = g("rvalid"), g("rready"), g("rlast"), g("rid")
    bv, br, bid = g("bvalid"), g("bready"), g("bid")
    araddr, arlen, arsize, arburst, arid = g("araddr"), g("arlen"), g("arsize"), g("arburst"), g("arid")
    awaddr, awlen, awsize, awburst, awid = g("awaddr"), g("awlen"), g("awsize"), g("awburst"), g("awid")
    wstrb = g("wstrb")
    if not any(arv) and not any(awv):
        return
    # ---- 1. VALID held until READY, payload stable (AR, AW, W are DUT outputs)
    def stable(valid, ready, fields, name):
        bad, first, cnt = 0, "", 0
        for k in range(n - 1):
            if valid[k] and not ready[k]:
                cnt += 1
                if not valid[k + 1] or any(f[k] != f[k + 1] for f in fields):
                    bad += 1
                    first = first or "cycle %d" % k
        rep.add(test, "%s: %s VALID held and payload stable until READY" % (p, name), cnt, bad, first)
    stable(arv, arr, (araddr, arlen, arsize, arburst, arid), "AR")
    stable(awv, awr, (awaddr, awlen, awsize, awburst, awid), "AW")
    stable(wv, wr, (wl, wstrb, g("wdata")), "W")
    # ---- 2. burst legality: size <= bus, FIXED/INCR only, <= 16 beats, never crossing 1 KB
    bad, first, cnt = 0, "", 0
    for ch, (vv, rd, A, L, S, B) in (("AR", (arv, arr, araddr, arlen, arsize, arburst)), ("AW", (awv, awr, awaddr, awlen, awsize, awburst))):
        for k in range(n):
            if vv[k] and rd[k]:
                cnt += 1
                a, l, s, b = A[k], L[k], S[k], B[k]
                end = (a & ~((1 << s) - 1)) + (l + 1) * (1 << s) - 1 if b == 1 else a | ((1 << s) - 1)
                ok = s <= 3 and b in (0, 1) and l + 1 <= 16 and (a >> 10) == (end >> 10)
                if not ok:
                    bad += 1
                    first = first or "%s cycle %d addr=%x len=%d size=%d burst=%d" % (ch, k, a, l, s, b)
    rep.add(test, "%s: AR/AW burst legal (size<=bus, FIXED/INCR, <=16 beats, no 1KB crossing)" % p, cnt, bad, first)
    # ---- 3. read data: R beat count per ID equals ARLEN+1, RLAST on the last beat, no R without AR
    outst = {}                      # id -> list of [beats_left]
    bad, first, cnt = 0, "", 0
    for k in range(n):
        if arv[k] and arr[k]:
            outst.setdefault(arid[k], []).append(arlen[k] + 1)
        if rv[k] and rr[k]:
            cnt += 1
            q = outst.get(rid[k])
            if not q:
                bad += 1; first = first or "cycle %d: R without AR (id %s)" % (k, rid[k]); continue
            q[0] -= 1
            if (q[0] == 0) != bool(rl[k]):
                bad += 1; first = first or "cycle %d: RLAST wrong (id %s)" % (k, rid[k])
            if q[0] == 0:
                q.pop(0)
    rep.add(test, "%s: R beats match ARLEN, RLAST on last beat, ID routing" % p, cnt, bad, first)
    # ---- 4. write data: W follows AW (same cycle or later), beat count = AWLEN+1, WLAST, WSTRB inside the beat window
    aw_q = []                       # [addr, len, size, beats_done]
    bad, first, cnt = 0, "", 0
    bad_s, first_s, cnt_s = 0, "", 0
    for k in range(n):
        if awv[k] and awr[k]:
            aw_q.append([awaddr[k], awlen[k], awsize[k], 0, awid[k], awburst[k]])
        if wv[k] and wr[k]:
            cnt += 1
            if not aw_q:
                bad += 1; first = first or "cycle %d: W before AW" % k; continue
            a, l, s, i, _, bt = aw_q[0]
            if bool(wl[k]) != (i == l):
                bad += 1; first = first or "cycle %d: WLAST wrong" % k
            base = a & ~((1 << s) - 1)
            if bt == 0:                                  # FIXED: every beat uses the same address
                beat_lo, beat_hi = a, base + (1 << s)
            else:
                beat_lo = max(a, base + i * (1 << s))
                beat_hi = base + (i + 1) * (1 << s)    # exclusive
            lane_lo, lane_hi = beat_lo % DWB, beat_lo % DWB + (beat_hi - beat_lo)
            allowed = ((1 << lane_hi) - 1) & ~((1 << lane_lo) - 1)
            cnt_s += 1
            if wstrb[k] & ~allowed:
                bad_s += 1; first_s = first_s or "cycle %d strb=%x allowed=%x" % (k, wstrb[k], allowed)
            aw_q[0][3] += 1
            if aw_q[0][3] == l + 1:
                aw_q.pop(0)
    rep.add(test, "%s: W never before AW, beat count = AWLEN+1, WLAST on last beat" % p, cnt, bad, first)
    rep.add(test, "%s: WSTRB only inside the byte window of its beat" % p, cnt_s, bad_s, first_s)
    # ---- 5. B response per AW
    bad, first, cnt = 0, "", 0
    wr_out = {}
    done_w = []                     # (id) of bursts whose last W beat was sent
    aw_ids = []
    wq = []
    for k in range(n):
        if awv[k] and awr[k]:
            aw_ids.append(awid[k])
            wq.append(awlen[k] + 1)
        if wv[k] and wr[k] and wq:
            wq[0] -= 1
            if wq[0] == 0:
                wq.pop(0)
                wr_out.setdefault(aw_ids[len(done_w)], 0)
                wr_out[aw_ids[len(done_w)]] += 1
                done_w.append(1)
        if bv[k] and br[k]:
            cnt += 1
            if not wr_out.get(bid[k]):
                bad += 1; first = first or "cycle %d: B without completed write (id %s)" % (k, bid[k])
            else:
                wr_out[bid[k]] -= 1
    rep.add(test, "%s: every B belongs to a fully written burst" % p, cnt, bad, first)
    # ---- 6. channel read issue limit: bytes still in flight never exceed the channel FIFO (TRM 4.3.4)
    bad, first, cnt = 0, "", 0
    infl = {}                       # id -> bytes requested and not yet received
    rq = {}                         # id -> [[beats_left, bytes_per_beat], ...]
    for k in range(n):
        if arv[k] and arr[k] and not g("arcmdlink")[k]:
            i, bpb = arid[k], 1 << arsize[k]
            skip = araddr[k] % bpb if arburst[k] == 1 else 0     # unaligned first beat carries fewer bytes
            infl[i] = infl.get(i, 0) + (arlen[k] + 1) * bpb - skip
            rq.setdefault(i, []).append([arlen[k] + 1, bpb])
            cnt += 1
            cap = FIFO_WORDS.get(i, 16) * DWB
            if infl[i] > cap:
                bad += 1; first = first or "cycle %d: id %s has up to %d bytes in flight, FIFO %d bytes" % (k, i, infl[i], cap)
        if rv[k] and rr[k] and rq.get(rid[k]):
            ent = rq[rid[k]][0]
            infl[rid[k]] -= ent[1]
            ent[0] -= 1
            if ent[0] == 0:
                rq[rid[k]].pop(0)
    rep.add(test, "%s: read bytes in flight <= channel FIFO size (reads issue only with room for the response)" % p, cnt, bad, first)

def apb_checks(v, rep, test):
    ps, pe, pr, pw, pa, pd = (ser(v, x) for x in ("psel", "penable", "pready", "pwrite", "paddr", "pwdata"))
    n = v.ncyc
    bad, first, acc = 0, "", 0
    waits = {"wr": set(), "rd": set()}
    k = 0
    while k < n:
        if ps[k] and not pe[k]:                     # setup phase
            a, w, d = pa[k], pw[k], pd[k]
            j = k + 1
            ok = True
            while j < n and not (ps[j] and pe[j] and pr[j]):
                if not (ps[j] and pe[j]) or pa[j] != a or pw[j] != w or (w and pd[j] != d):
                    ok = False
                    break
                j += 1
            acc += 1
            if not ok or j >= n:
                bad += 1; first = first or "cycle %d" % k
            else:
                waits["wr" if w else "rd"].add(j - k - 1)       # wait states = access cycles with PREADY=0
            k = j + 1
        else:
            if pe[k] and not ps[k]:
                bad += 1; first = first or "cycle %d: PENABLE without PSEL" % k
            k += 1
    rep.add(test, "APB: setup phase, stable address / data, completion with PREADY", acc, bad, first)
    rep.add(test, "APB: wait states per access (write=%s read=%s, TRM/arch: 3 with pclken=1)" % (sorted(waits["wr"]), sorted(waits["rd"])),
            acc, 0 if waits["wr"] <= {3} and waits["rd"] <= {3} else 1, "")

def trig_checks(v, rep, test):
    if not v.has("trig_in_req"):
        return
    n = v.ncyc
    for name_req, name_ack, tag, ntr in (("trig_in_req", "trig_in_ack", "trigger in", 4), ("trig_out_req", "trig_out_ack", "trigger out", 4)):
        bad, first, cnt = 0, "", 0
        for p in range(ntr):
            rq, ak = fld(v, name_req, p), fld(v, name_ack, p)
            for k in range(1, n):
                if rq[k] is None or ak[k] is None:
                    continue
                cnt += 1
                if tag == "trigger in":
                    # DUT output is ack: it must rise only while req is high and fall only after req fell
                    rise = ak[k] == 1 and ak[k - 1] == 0
                    fall_ = ak[k] == 0 and ak[k - 1] == 1
                    if rise and not rq[k]:
                        bad += 1; first = first or "port %d cycle %d: ack rises without req" % (p, k)
                    if fall_ and rq[k]:
                        bad += 1; first = first or "port %d cycle %d: ack falls while req high" % (p, k)
                else:
                    # DUT output is req: must stay high until ack is high, and fall only after ack rose
                    if rq[k - 1] == 1 and rq[k] == 0 and not ak[k - 1]:
                        bad += 1; first = first or "port %d cycle %d: req dropped before ack" % (p, k)
        rep.add(test, "%s: 4-phase ordering" % tag, cnt, bad, first)
    tot_bad = 0
    for p in range(4):
        at = fld(v, "trig_in_ack_type", 2 * p + 1, 2 * p)
        ak = fld(v, "trig_in_ack", p)
        tot_bad += sum(1 for k in range(n) if ak[k] and at[k] == 3)
    rep.add(test, "trigger in: ack_type never RESERVED (2'b11)", n, tot_bad, "")

def stream_checks(v, rep, test):
    if not v.has("str_out_tvalid"):
        return
    n = v.ncyc
    bad, first, cnt = 0, "", 0
    bad_s, first_s = 0, ""
    tv, tr, tl = fld(v, "str_out_tvalid", 0), fld(v, "str_out_tready", 0), fld(v, "str_out_tlast", 0)
    ts, td = fld(v, "str_out_tstrb", DWB - 1, 0), fld(v, "str_out_tdata", DW - 1, 0)
    for k in range(n - 1):
        if tv[k]:
            cnt += 1
            if not tr[k] and (not tv[k + 1] or ts[k] != ts[k + 1] or td[k] != td[k + 1] or tl[k] != tl[k + 1]):
                bad += 1; first = first or "cycle %d" % k
            if ts[k] is not None and ts[k] != (1 << DWB) - 1 and not tl[k]:
                bad_s += 1; first_s = first_s or "cycle %d strb=%x" % (k, ts[k])
    rep.add(test, "stream out: TVALID held with stable payload until TREADY", cnt, bad, first)
    rep.add(test, "stream out: TSTRB all ones except on the TLAST beat (TRM 4.5)", cnt, bad_s, first_s)

def lpi_checks(v, rep, test):
    n = v.ncyc
    qr, qa, qd = ser(v, "clk_qreqn"), ser(v, "clk_qacceptn"), ser(v, "clk_qdeny")
    if not any(x == 0 for x in qr):
        return
    bad, first, cnt = 0, "", 0
    k = 1
    while k < n:
        if qr[k] == 0 and qr[k - 1] == 1:
            cnt += 1
            j = k
            while j < n and qa[j] != 0 and qd[j] != 1:
                j += 1
            if j >= n or j - k > 8:
                bad += 1; first = first or "cycle %d: no answer" % k
            elif qa[j] == 0 and qd[j] == 1:
                bad += 1; first = first or "cycle %d: accept and deny together" % k
        k += 1
    rep.add(test, "Q-Channel: every request answered by accept xor deny within 8 cycles", cnt, bad, first)

def status_checks(v, rep, test):
    n = v.ncyc
    en, er = ser(v, "ch_enabled"), ser(v, "ch_err")
    bad, first, cnt = 0, "", 0
    for k in range(1, n):
        for c in range(NCH):
            if (er[k] >> c) & 1 and not (er[k - 1] >> c) & 1:
                cnt += 1
                if (en[k] >> c) & 1:
                    bad += 1; first = first or "ch%d cycle %d: ch_err rises while ch_enabled still 1" % (c, k)
    rep.add(test, "ch_err rises together with ch_enabled falling (STAT_ERR set on return to DISABLED)", cnt, bad, first)


def attr_checks(v, rep, test, p):
    """TRM 4.3.2 / 4.3.9 / 5.7.2: command-link reads and AxID / AxQOS attributes"""
    g = lambda n: ser(v, n + p)
    n = v.ncyc
    arv, arr, awv, awr = g("arvalid"), g("arready"), g("awvalid"), g("awready")
    if not any(arv):
        return
    # command link reads: instruction access (ARPROT[2]=1), ARCMDLINK, beat size = DATA_WIDTH, INCR; data reads ARPROT[2]=0
    bad, first, cnt = 0, "", 0
    bad_d, first_d, cnt_d = 0, "", 0
    for k in range(n):
        if arv[k] and arr[k]:
            if g("arcmdlink")[k]:
                cnt += 1
                if not ((g("arprot")[k] >> 2) & 1 and g("arsize")[k] == 3 and g("arburst")[k] == 1):
                    bad += 1; first = first or "cycle %d" % k
            else:
                cnt_d += 1
                if (g("arprot")[k] >> 2) & 1:
                    bad_d += 1; first_d = first_d or "cycle %d" % k
    if cnt:
        rep.add(test, "%s: link reads use ARCMDLINK=1, ARPROT[2]=1, size=DATA_WIDTH, INCR (TRM 4.3.9, 5.7.2)" % p, cnt, bad, first)
    rep.add(test, "%s: data reads are not instruction accesses (ARPROT[2]=0)" % p, cnt_d, bad_d, first_d)
    # AxID = channel number and AxQOS = CH_CTRL.CHPRIO of that channel (tests without command links only)
    if cnt:
        return
    prio = {}
    wr = {}
    for k, w, a, d in apb_writes(v):
        if w and a is not None and 0x1000 <= a < 0x1800 and (a & 0xFF) == 0x0C:
            wr.setdefault(k, []).append(((a - 0x1000) >> 8, (d >> 4) & 0xF))
    bad, first, cnt = 0, "", 0
    for k in range(n):
        for c, pv in wr.get(k, []):
            prio[c] = pv
        for nm, vv, rd, idn, qn in (("AR", arv, arr, "arid", "arqos"), ("AW", awv, awr, "awid", "awqos")):
            if vv[k] and rd[k]:
                i = g(idn)[k]
                cnt += 1
                if i not in prio or g(qn)[k] != prio[i]:
                    bad += 1; first = first or "%s cycle %d id=%s qos=%s CHPRIO=%s" % (nm, k, i, g(qn)[k], prio.get(i))
    rep.add(test, "%s: AxQOS equals CH_CTRL.CHPRIO of the channel whose number is AxID" % p, cnt, bad, first)

def apb_writes(v):
    ps, pe, pr, pw, pa, pd = (ser(v, x) for x in ("psel", "penable", "pready", "pwrite", "paddr", "pwdata"))
    return [(k, bool(pw[k]), pa[k], pd[k]) for k in range(v.ncyc) if ps[k] and pe[k] and pr[k]]

def metrics(v, test, out):
    """informational: ENABLECMD -> first AR (plain commands) and last B -> channel idle"""
    n = v.ncyc
    en = ser(v, "ch_enabled")
    arv, arr, arid, arc = ser(v, "arvalid_m0"), ser(v, "arready_m0"), ser(v, "arid_m0"), ser(v, "arcmdlink_m0")
    bv, br, bid = ser(v, "bvalid_m0"), ser(v, "bready_m0"), ser(v, "bid_m0")
    for c in range(NCH):
        st = ser(v, "ch%d.st" % c)
        k = 1
        while k < n:
            if (en[k] >> c) & 1 and not (en[k - 1] >> c) & 1:
                e0 = k
                e1 = next((j for j in range(k, n) if not (en[j] >> c) & 1), None)
                if e1 is None:
                    break
                states = set(st[e0:e1])
                seq = st[e0:e1]
                plain = (not (states & {1, 6, 12}) and seq.count(8) <= 2 and seq.count(10) <= 3 and
                         seq.count(9) < 400)               # no LINK / ALLOCW / STOP, no trigger wait, short commands
                firstar = next((j for j in range(e0, e1) if arv[j] and arr[j] and arid[j] == c and not arc[j]), None)
                lastb = [j for j in range(e0, e1) if bv[j] and br[j] and bid[j] == c]
                if plain and firstar is not None:
                    out["start"].setdefault(4 in states, []).append(firstar - e0)
                if plain and lastb:
                    out["end"].append(e1 - lastb[-1])
                k = e1
            k += 1

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    rep = Report()
    met = {"start": {}, "end": []}
    files = sorted(glob.glob(os.path.join(a.work, "vcd", "*.vcd")))
    for f in files:
        test = os.path.splitext(os.path.basename(f))[0]
        if test.startswith("t1"):
            continue
        v = Vcd(f)
        for p in ("_m0", "_m1"):
            axi_checks(v, rep, test, p)
            attr_checks(v, rep, test, p)
        metrics(v, test, met)
        apb_checks(v, rep, test)
        trig_checks(v, rep, test)
        stream_checks(v, rep, test)
        lpi_checks(v, rep, test)
        status_checks(v, rep, test)
    nbad = 0
    cur = None
    for test, rule, n, bad, first in rep.rows:
        if test != cur:
            print("\n[%s]" % test)
            cur = test
        print("  %-4s %-95s checked=%-6d %s" % ("FAIL" if bad else "ok", rule, n, ("violations=%d (%s)" % (bad, first)) if bad else ""))
        nbad += bad
    print("\nInformational latencies (cycles, plain commands without link / trigger / stop):")
    from collections import Counter
    for is2d, lst in sorted(met["start"].items()):
        print("  ENABLECMD (ch_enabled rises) -> first AR, %s: %s" % ("2D (MUL state)" if is2d else "1D", dict(sorted(Counter(lst).items()))))
    print("  last B -> ch_enabled falls: %s" % dict(sorted(Counter(met["end"]).items())))
    print("\nTotal violations: %d over %d checks" % (nbad, len(rep.rows)))
    return 1 if nbad else 0

if __name__ == "__main__":
    sys.exit(main())
