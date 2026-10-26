#!/usr/bin/env python3
"""
run_sim.py - build / run / regression driver of the AXI DMA UVM test bench (QuestaSim)

  python scripts/run_sim.py build  [-v VARIANT]
  python scripts/run_sim.py run    -t TEST [-s SEED] [-v VARIANT] [--plus "+NCMD=10"] [--cov] [--wave]
  python scripts/run_sim.py regress [-l regress_list] [-j 12] [--cov] [--variants v1,v2]

At most 12 compile / simulation jobs run at the same time (machine resource limit).
"""
import argparse, concurrent.futures as cf, datetime, json, os, re, shutil, subprocess, sys, time, zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VIP  = os.path.join(ROOT, "vip_src", "Common-Verification-IP-Library")
SIM  = os.path.join(ROOT, "sim")
QUESTA = os.environ.get("QUESTA_BIN", r"C:/questasim64_10.7c/win64")
UVM_SRC = os.environ.get("UVM_SRC", r"C:/questasim64_10.7c/verilog_src/uvm-1.2/src")
MAX_JOBS = 12

# ------------------------------------------------------------------ build variants
BASE = dict(DMA_NUM_CH=4, DMA_AW=32, DMA_DW=64, DMA_CHID_W=4, DMA_GPO_W=8, DMA_GPO_MASK="8'h0F",
            DMA_STREAM_MASK="8'h03", DMA_EXT_MASK="8'hFF", DMA_FIFO_D0=16, DMA_FIFO_D1=8, DMA_FIFO_D2=32,
            DMA_FIFO_D3=4, DMA_NTI=4, DMA_NTO=4, DMA_M1=1, DMA_SECEXT=1)
VARIANTS = {
    "default": {},
    "d32":     dict(DMA_DW=32, DMA_FIFO_D3=2),
    "d128":    dict(DMA_DW=128, DMA_FIFO_D1=4, DMA_FIFO_D2=64),
    "a40":     dict(DMA_AW=40),
    "min":     dict(DMA_NUM_CH=1, DMA_NTI=0, DMA_NTO=0, DMA_M1=0, DMA_SECEXT=0, DMA_STREAM_MASK="8'h00",
                    DMA_CHID_W=0, DMA_GPO_W=0, DMA_GPO_MASK="8'h00"),
    "nosec":   dict(DMA_SECEXT=0, DMA_M1=0),
    "ch8":     dict(DMA_NUM_CH=8, DMA_EXT_MASK="8'h5F", DMA_STREAM_MASK="8'h81", DMA_GPO_MASK="8'h3C",
                    DMA_NTI=8, DMA_NTO=6),
    "nosync":  dict(DMA_TI_SYNC="32'h0", DMA_TO_SYNC="32'h0"),
    "oldrtl":  {},          # default configuration, RTL taken from $DMA_RTL_DIR
}

def variant_defines(v):
    d = dict(BASE)
    d.update(VARIANTS[v])
    nch = int(d["DMA_NUM_CH"])
    idw = max(1, (nch - 1).bit_length())
    d["AXI5_ADDR_W"] = d["DMA_AW"]
    d["AXI5_DATA_W"] = d["DMA_DW"]
    d["AXI5_ID_W"]   = idw
    d["APB_ADDR_W"]  = 13
    d["APB_DATA_W"]  = 32
    d["AXIS_DATA_W"] = d["DMA_DW"]
    return d

def q(p):
    return p.replace("\\", "/")

def tool(name):
    return os.path.join(QUESTA, name)

def sh(cmd, cwd, log=None, env=None):
    with open(log, "w") if log else open(os.devnull, "w") as f:
        p = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, env=env, shell=isinstance(cmd, str))
    return p.returncode

def env_vars():
    e = dict(os.environ)
    e["DMA_ROOT"] = q(ROOT)
    return e

# ------------------------------------------------------------------ UVM library
def build_uvm():
    lib = os.path.join(SIM, "libs")
    os.makedirs(lib, exist_ok=True)
    if os.path.isdir(os.path.join(lib, "uvm")) and os.path.exists(os.path.join(lib, "uvm.ok")):
        return
    sh([tool("vlib"), "uvm"], lib)
    rc = sh([tool("vlog"), "-work", "uvm", "-sv", "-timescale", "1ns/1ps", "+incdir+" + q(UVM_SRC), "+define+UVM_NO_DPI",
             "-suppress", "2181,2263,2275", q(os.path.join(UVM_SRC, "uvm_pkg.sv"))], lib,
            log=os.path.join(lib, "uvm_compile.log"))
    if rc != 0:
        sys.exit("UVM compile failed, see sim/libs/uvm_compile.log")
    open(os.path.join(lib, "uvm.ok"), "w").write("ok\n")

# ------------------------------------------------------------------ build
def tb_files():
    vip = q(VIP)
    rtl = [l.strip().replace("${DMA_ROOT}", q(ROOT)) for l in open(os.path.join(ROOT, "rtl", "dma_rtl.f")) if l.strip()]
    return rtl + [
        f"{vip}/common/vip_common_pkg.sv",
        f"{vip}/apb/src/vip_apb_if.sv",  f"{vip}/apb/src/apb_pkg.sv",
        f"{vip}/axi5/src/vip_axi5_if.sv", f"{vip}/axi5/src/axi5_pkg.sv",
        f"{vip}/axi4s/src/vip_axis_if.sv", f"{vip}/axi4s/src/axis_pkg.sv",
        q(os.path.join(ROOT, "tb", "uvm", "top", "dma_ctrl_if.sv")),
        q(os.path.join(ROOT, "tb", "uvm", "env", "dma_tb_pkg.sv")),
        q(os.path.join(ROOT, "tb", "uvm", "tests", "dma_test_pkg.sv")),
        q(os.path.join(ROOT, "tb", "uvm", "top", "dma_tb_top.sv")),
    ]

def build(variant, cov=False):
    build_uvm()
    bdir = os.path.join(SIM, "build", variant + ("_cov" if cov else ""))
    os.makedirs(bdir, exist_ok=True)
    if os.path.isdir(os.path.join(bdir, "work")):
        shutil.rmtree(os.path.join(bdir, "work"), ignore_errors=True)
    sh([tool("vlib"), "work"], bdir)
    sh([tool("vmap"), "uvm", q(os.path.join(SIM, "libs", "uvm"))], bdir)
    defs = ["+define+%s=%s" % (k, v) for k, v in variant_defines(variant).items()]
    vip = q(VIP)
    inc = ["+incdir+" + q(UVM_SRC), "+incdir+" + f"{vip}/common", "+incdir+" + f"{vip}/apb/src",
           "+incdir+" + f"{vip}/axi5/src", "+incdir+" + f"{vip}/axi4s/src",
           "+incdir+" + q(os.path.join(ROOT, "tb", "uvm", "top")),
           "+incdir+" + q(os.path.join(ROOT, "tb", "uvm", "env")),
           "+incdir+" + q(os.path.join(ROOT, "tb", "uvm", "seq")),
           "+incdir+" + q(os.path.join(ROOT, "tb", "uvm", "tests"))]
    rtl = [l.strip().replace("${DMA_ROOT}", q(ROOT)) for l in open(os.path.join(ROOT, "rtl", "dma_rtl.f")) if l.strip()]
    others = tb_files()[len(rtl):]
    if os.environ.get("DMA_RTL_DIR") and variant == "oldrtl":
        rtl = [r.replace(q(os.path.join(ROOT, "rtl")), q(os.environ["DMA_RTL_DIR"])) for r in rtl]
    log = os.path.join(bdir, "compile.log")
    covopt = ["+cover=bcesft"] if cov else []
    # RTL (with coverage when requested), then the test bench
    rc = sh([tool("vlog"), "-sv", "-timescale", "1ns/1ps", "-work", "work", "-L", "uvm", "-suppress", "13314,2583"] + defs + covopt + rtl,
            bdir, log=log)
    if rc == 0:
        rc = sh([tool("vlog"), "-sv", "-timescale", "1ns/1ps", "-work", "work", "-L", "uvm", "-suppress", "13314,2583,2181,2263"] +
                defs + inc + ["+define+UVM_NO_DPI"] + others, bdir, log=os.path.join(bdir, "compile_tb.log"))
    if rc != 0:
        print(open(log).read()[-3000:])
        if os.path.exists(os.path.join(bdir, "compile_tb.log")):
            print(open(os.path.join(bdir, "compile_tb.log")).read()[-6000:])
        sys.exit("compile failed (%s)" % variant)
    vopt = [tool("vopt"), "-work", "work", "-L", "uvm", "dma_tb_top", "-o", "tb_opt", "+acc=npr"]
    if cov:
        vopt += ["+cover=bcesft"]
    rc = sh(vopt, bdir, log=os.path.join(bdir, "vopt.log"))
    if rc != 0:
        print(open(os.path.join(bdir, "vopt.log")).read()[-5000:])
        sys.exit("vopt failed (%s)" % variant)
    return bdir

# ------------------------------------------------------------------ run one test
def run_test(variant, test, seed, plus="", cov=False, wave=False, outdir=None, tag=None):
    bdir = os.path.join(SIM, "build", variant + ("_cov" if cov else ""))
    name = tag or ("%s_%s_s%d" % (variant, test, seed))
    rdir = outdir or os.path.join(SIM, "run", name)
    os.makedirs(rdir, exist_ok=True)
    log = os.path.join(rdir, "sim.log")
    do = []
    if wave:
        do.append("log -r /*")
    if cov:
        do.append("coverage save -onexit %s" % q(os.path.join(rdir, "cov.ucdb")))
    do.append("run -all; quit -f")
    cmd = [tool("vsim"), "-c", "-lib", q(os.path.join(bdir, "work")), "tb_opt",
           "-sv_seed", str(seed), "+UVM_TESTNAME=" + test, "+UVM_VERBOSITY=UVM_LOW",
           "-do", "; ".join(do)]
    if cov:
        cmd.insert(2, "-coverage")
    if wave:
        cmd += ["-wlf", q(os.path.join(rdir, "wave.wlf"))]
    cmd += [p for p in plus.split() if p]
    t0 = time.time()
    sh(cmd, bdir, log=log, env=env_vars())
    dt = time.time() - t0
    txt = open(log, errors="replace").read()
    passed = ("*** TEST PASSED ***" in txt) and ("** Fatal" not in txt)
    m = re.search(r"UVM_ERROR :\s+(\d+)", txt)
    nerr = int(m.group(1)) if m else -1
    m = re.search(r"UVM_FATAL :\s+(\d+)", txt)
    nfat = int(m.group(1)) if m else -1
    serr = len(re.findall(r"^# \*\* Error", txt, re.M))
    if serr:
        passed = False
    simt = re.search(r"Time: (\d+) ns", txt[-2000:])
    return dict(name=name, variant=variant, test=test, seed=seed, plus=plus, passed=passed,
                uvm_errors=nerr, uvm_fatals=nfat, sim_errors=serr, wall_s=round(dt, 1), log=q(log))

# ------------------------------------------------------------------ regression
def load_list(path):
    jobs = []
    for line in open(path):
        line = line.split("#")[0].strip()
        if not line:
            continue
        parts = line.split()
        test, nseeds = parts[0], int(parts[1]) if len(parts) > 1 else 1
        plus = " ".join(parts[2:])
        jobs.append((test, nseeds, plus))
    return jobs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["build", "run", "regress"])
    ap.add_argument("-t", "--test", default="dma_smoke_test")
    ap.add_argument("-s", "--seed", type=int, default=1)
    ap.add_argument("-v", "--variant", default="default")
    ap.add_argument("--variants", default=None)
    ap.add_argument("--plus", default="")
    ap.add_argument("--cov", action="store_true")
    ap.add_argument("--wave", action="store_true")
    ap.add_argument("-l", "--list", default=os.path.join(ROOT, "tb", "uvm", "regress", "regress_list.txt"))
    ap.add_argument("-j", "--jobs", type=int, default=MAX_JOBS)
    ap.add_argument("--seed0", type=int, default=1)
    a = ap.parse_args()
    jobs = min(a.jobs, MAX_JOBS)

    if a.cmd == "build":
        for v in (a.variants.split(",") if a.variants else [a.variant]):
            print("built", build(v, a.cov))
        return
    if a.cmd == "run":
        build(a.variant, a.cov) if not os.path.isdir(os.path.join(SIM, "build", a.variant + ("_cov" if a.cov else ""), "work")) else None
        r = run_test(a.variant, a.test, a.seed, a.plus, a.cov, a.wave)
        print(json.dumps(r, indent=1))
        sys.exit(0 if r["passed"] else 1)

    # regress
    variants = a.variants.split(",") if a.variants else [a.variant]
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    rroot = os.path.join(SIM, "regress", stamp)
    os.makedirs(rroot, exist_ok=True)
    with cf.ThreadPoolExecutor(max_workers=min(jobs, len(variants))) as ex:
        list(ex.map(lambda v: build(v, a.cov), variants))
    tasks = []
    for v in variants:
        for test, nseeds, plus in load_list(a.list):
            for k in range(nseeds):
                seed = a.seed0 + k * 7919 + zlib.crc32((test + plus).encode()) % 1000
                tag = "%s_%s_s%d" % (v, test, seed)
                tasks.append((v, test, seed, plus, os.path.join(rroot, tag), tag))
    print("running %d simulations with %d parallel jobs" % (len(tasks), jobs))
    results = []
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = [ex.submit(run_test, v, t, s, p, a.cov, False, d, tag) for (v, t, s, p, d, tag) in tasks]
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            print("%-6s %-60s err=%d wall=%.0fs" % ("PASS" if r["passed"] else "FAIL", r["name"], r["uvm_errors"], r["wall_s"]),
                  flush=True)
    results.sort(key=lambda r: r["name"])
    npass = sum(r["passed"] for r in results)
    json.dump(results, open(os.path.join(rroot, "results.json"), "w"), indent=1)
    with open(os.path.join(rroot, "summary.txt"), "w") as f:
        f.write("regression %s: %d / %d passed\n" % (stamp, npass, len(results)))
        for r in results:
            f.write("%-5s %-60s uvm_err=%d sim_err=%d wall=%.0fs\n" % ("PASS" if r["passed"] else "FAIL", r["name"],
                    r["uvm_errors"], r["sim_errors"], r["wall_s"]))
    if a.cov:
        ucdbs = [q(os.path.join(rroot, r["name"], "cov.ucdb")) for r in results
                 if os.path.exists(os.path.join(rroot, r["name"], "cov.ucdb"))]
        if ucdbs:
            merged = q(os.path.join(rroot, "merged.ucdb"))
            sh([tool("vcover"), "merge", merged] + ucdbs, rroot, log=os.path.join(rroot, "merge.log"))
            sh([tool("vcover"), "report", "-code", "bcesft", "-bydu", merged], rroot,
               log=os.path.join(rroot, "cov_code_bydu.txt"))
            sh([tool("vcover"), "report", "-cvg", "-details", merged], rroot,
               log=os.path.join(rroot, "cov_functional.txt"))
            sh([tool("vcover"), "report", "-html", "-htmldir", q(os.path.join(rroot, "cov_html")),
                "-code", "bcesft", "-cvg", merged], rroot, log=os.path.join(rroot, "cov_html.log"))
    print("regression: %d / %d passed -> %s" % (npass, len(results), rroot))
    sys.exit(0 if npass == len(results) else 1)

if __name__ == "__main__":
    main()
