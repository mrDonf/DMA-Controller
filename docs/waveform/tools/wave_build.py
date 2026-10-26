#!/usr/bin/env python3
"""
wave_build.py - compile the DUT + UVM test bench into a private work directory.

The repository (rtl/, tb/, sim/) is only READ: run_sim.build() is re-used with its output
directory redirected to --work, so nothing outside docs/waveform is modified.

  python docs/waveform/tools/wave_build.py --work <dir> [-v default]
"""
import argparse, importlib.util, os, sys

sys.dont_write_bytecode = True      # keep scripts/ and tools/ free of __pycache__

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

def load_run_sim():
    spec = importlib.util.spec_from_file_location("run_sim", os.path.join(ROOT, "scripts", "run_sim.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True, help="private build / run directory (outside the repository)")
    ap.add_argument("-v", "--variant", default="default")
    a = ap.parse_args()
    rs = load_run_sim()
    rs.SIM = os.path.abspath(a.work)
    os.makedirs(rs.SIM, exist_ok=True)
    print("built", rs.build(a.variant))

if __name__ == "__main__":
    main()
