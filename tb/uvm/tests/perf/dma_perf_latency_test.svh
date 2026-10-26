//-----------------------------------------------------------------------------
// dma_perf_latency_test.svh
//   Latency tolerance: 8KB aligned copies against the read latency of the
//   memory for every channel FIFO depth (default build: ch3 4, ch1 8, ch0 16,
//   ch2 32 words), CH_ISSUECAP (outstanding transactions), write response
//   latency and READY backpressure.
//   A copy can only keep the read data in flight that fits in the FIFO, so the
//   expected rate is about min(DW/8, FIFO bytes / (latency + burst)).
//-----------------------------------------------------------------------------
class dma_perf_latency_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_latency_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int lats[] = '{0, 4, 8, 16, 32, 64};
    int caps[] = '{0, 1, 3, 7};
    int blat[] = '{0, 16, 64};
    int rdy[]  = '{100, 75, 50, 25};
    int ch2 = (TB_NCH > 2) ? 2 : 0;
    suite = "latency";
    // read latency x FIFO depth
    for (int ch = 0; ch < TB_NCH && ch < 4; ch++)
      foreach (lats[l]) begin
        mem_profile(lats[l]);
        measure($sformatf("ch%0d_l%0d", ch, lats[l]), '{copy(ch, 8192)},
                $sformatf("lat=%0d,fifo=%0d", lats[l], tb_fifo_depth(ch) * TB_DWB));
      end
    // issuing capability at 32 cycles read latency
    mem_profile(32);
    foreach (caps[k]) begin
      regs.chw(ch2, CH_ISSUECAP, caps[k]);
      measure($sformatf("cap%0d_l32", caps[k] + 1), '{copy(ch2, 8192)}, $sformatf("lat=32,issuecap=%0d", caps[k] + 1));
    end
    regs.chw(ch2, CH_ISSUECAP, 7);
    // write response latency
    foreach (blat[k]) begin
      mem_profile(0, 0, 100, blat[k]);
      measure($sformatf("blat%0d", blat[k]), '{copy(ch2, 8192)}, $sformatf("blat=%0d", blat[k]));
    end
    // READY backpressure (AR / AW / W)
    foreach (rdy[k]) begin
      mem_profile(0, 0, rdy[k]);
      measure($sformatf("rdy%0d", rdy[k]), '{copy(ch2, 8192)}, $sformatf("ready=%0d", rdy[k]));
    end
    // read data gaps (slow memory bandwidth)
    for (int g = 1; g <= 3; g++) begin
      mem_profile(0, g);
      measure($sformatf("gap%0d", g), '{copy(ch2, 8192)}, $sformatf("rgap=%0d", g));
    end
    mem_profile(0);
  endtask
endclass
