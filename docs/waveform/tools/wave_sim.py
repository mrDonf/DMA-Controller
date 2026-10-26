#!/usr/bin/env python3
"""
wave_sim.py - run one existing UVM test of the repository and dump a VCD of the DUT.

Uses the private build of wave_build.py; nothing inside the repository is written.

  python docs/waveform/tools/wave_sim.py --work <dir> -t dma_dir_1d_test -s 1 --until 30us -o out.vcd
                                          [--plus "+NCMD=4"] [--extra "/dma_tb_top/dut/g_ch(0)/u_ch/st"]

The VCD holds every object declared in the dma_top scope (all ports) plus the channel FSM state
registers (/dma_tb_top/dut/g_ch(n)/u_ch/st) and the AXI-Stream VIP side is not needed (the DUT
ports already show it).
"""
import argparse, os, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
QUESTA = os.environ.get("QUESTA_BIN", r"C:/questasim64_10.7c/win64")

def run(work, test, seed, until, out_vcd, plus="", variant="default", nch=4, extra=()):
    bdir = os.path.join(os.path.abspath(work), "build", variant)
    rdir = os.path.dirname(os.path.abspath(out_vcd))
    os.makedirs(rdir, exist_ok=True)
    out_vcd = os.path.abspath(out_vcd).replace("\\", "/")
    adds = ["vcd add /dma_tb_top/dut/*"]
    adds += ["vcd add /dma_tb_top/dut/g_ch(%d)/u_ch/st" % c for c in range(nch)]
    adds += ["vcd add %s" % e for e in extra]
    do = ["vcd file %s" % out_vcd] + adds + ["run %s" % until, "quit -f"]
    cmd = [os.path.join(QUESTA, "vsim.exe"), "-c", "-lib", os.path.join(bdir, "work").replace("\\", "/"), "tb_opt",
           "-sv_seed", str(seed), "+UVM_TESTNAME=" + test, "+UVM_VERBOSITY=UVM_LOW", "-do", "; ".join(do)]
    cmd += [p for p in plus.split() if p]
    env = dict(os.environ)
    env["DMA_ROOT"] = ROOT.replace("\\", "/")
    log = os.path.join(rdir, os.path.splitext(os.path.basename(out_vcd))[0] + ".log")
    with open(log, "w") as f:
        subprocess.run(cmd, cwd=rdir, stdout=f, stderr=subprocess.STDOUT, env=env)
    return log

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("-t", "--test", required=True)
    ap.add_argument("-s", "--seed", type=int, default=1)
    ap.add_argument("--until", default="100us", help="simulation time limit, e.g. 50us")
    ap.add_argument("--plus", default="")
    ap.add_argument("-v", "--variant", default="default")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    print(run(a.work, a.test, a.seed, a.until, a.out, a.plus, a.variant, extra=a.extra))

if __name__ == "__main__":
    main()
