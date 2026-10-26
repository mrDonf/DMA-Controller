//-----------------------------------------------------------------------------
// dma_perf_arb_test.svh
//   Arbitration under real contention: every channel uses 4-beat bursts so a
//   single channel alone reaches ~94% of the port; two or four of them
//   saturate M0.
//     * equal CHPRIO: share of the port per channel (LRG fairness), measured
//       on equal transfer sizes (completion order / per channel rate)
//     * CHPRIO 15 versus 0 (both directions): CHPRIO selects between requests
//       waiting at the same time in the BIU arbiter (also driven on AxQOS), so
//       it only shows when the address channels are back-pressured (READY 25%)
//     * 2 / 4 equal priority channels: port utilisation (R and W beats per
//       cycle) and the cost of switching between channels
//-----------------------------------------------------------------------------
class dma_perf_arb_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_arb_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function dma_cmd c4(int ch, int prio = 0);
    dma_cmd c = copy(ch, 8192);
    c.src_maxburst = 3; c.des_maxburst = 3;
    c.prio = prio;
    return c;
  endfunction

  task body();
    int a = 0, b = (TB_NCH > 2) ? 2 : 1;
    suite = "arb";
    if (TB_NCH < 2) begin `uvm_info("TEST", "single channel: skipped", UVM_NONE) return; end
    mem_profile(0);
    measure("single_a", '{c4(a)}, "nch=1");
    measure("single_b", '{c4(b)}, "nch=1");
    measure("eq_2ch", '{c4(a), c4(b)}, "nch=2,prio=0/0");
    measure("prio_a15", '{c4(a, 15), c4(b, 0)}, "nch=2,prio=15/0");
    measure("prio_b15", '{c4(a, 0), c4(b, 15)}, "nch=2,prio=0/15");
    if (TB_NCH >= 4) begin
      measure("eq_4ch", '{c4(0), c4(1), c4(2), c4(3)}, "nch=4,prio=0");
      measure("prio_4ch", '{c4(0, 3), c4(1, 2), c4(2, 1), c4(3, 0)}, "nch=4,prio=3/2/1/0");
      // the same four channels with full length bursts (port switching cost)
      begin
        dma_cmd cs[$];
        for (int ch = 0; ch < 4; ch++) cs.push_back(copy(ch, 8192));
        measure("eq_4ch_mbmax", cs, "nch=4,maxburst=16");
      end
    end
    mem_profile(16);
    measure("l16_eq_2ch", '{c4(a), c4(b)}, "nch=2,prio=0/0,lat=16");
    measure("l16_prio_a15", '{c4(a, 15), c4(b, 0)}, "nch=2,prio=15/0,lat=16");
    // address channel backpressure: requests wait in the arbiter, CHPRIO decides
    mem_profile(0, 0, 25);
    measure("rdy25_eq_2ch", '{c4(a), c4(b)}, "nch=2,prio=0/0,ready=25");
    measure("rdy25_prio_a15", '{c4(a, 15), c4(b, 0)}, "nch=2,prio=15/0,ready=25");
    measure("rdy25_prio_b15", '{c4(a, 0), c4(b, 15)}, "nch=2,prio=0/15,ready=25");
    if (TB_NCH >= 4) begin
      measure("rdy25_eq_4ch", '{c4(0), c4(1), c4(2), c4(3)}, "nch=4,prio=0,ready=25");
      measure("rdy25_prio_4ch", '{c4(0, 3), c4(1, 2), c4(2, 1), c4(3, 0)}, "nch=4,prio=3/2/1/0,ready=25");
    end
    // only AR back-pressured: read requests of all channels wait together
    mem_profile(0);
    for (int p = 0; p < 2; p++) env.axi_cfg[p].arready_pct = 20;
    measure("ar20_eq_2ch", '{c4(a), c4(b)}, "nch=2,prio=0/0,arready=20");
    measure("ar20_prio_a15", '{c4(a, 15), c4(b, 0)}, "nch=2,prio=15/0,arready=20");
    measure("ar20_prio_b15", '{c4(a, 0), c4(b, 15)}, "nch=2,prio=0/15,arready=20");
    if (TB_NCH >= 4) begin
      measure("ar20_eq_4ch", '{c4(0), c4(1), c4(2), c4(3)}, "nch=4,prio=0,arready=20");
      measure("ar20_prio_4ch", '{c4(0, 0), c4(1, 1), c4(2, 2), c4(3, 3)}, "nch=4,prio=0/1/2/3,arready=20");
    end
    mem_profile(0);
  endtask
endclass
