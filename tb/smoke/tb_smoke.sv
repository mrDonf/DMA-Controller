//-----------------------------------------------------------------------------
// tb_smoke.sv - directed bring-up test bench (no UVM)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_smoke;
  localparam int AW  = 32;
  localparam int DW  = 64;
  localparam int NCH = 2;
  localparam int IW  = 1;
  localparam int DWB = DW/8;

  logic clk = 0, resetn = 0;
  always #5 clk = ~clk;

  // APB
  logic psel=0, penable=0, pwrite=0, pready, pslverr;
  logic [2:0] pprot=0; logic [12:0] paddr=0; logic [31:0] pwdata=0, prdata; logic [3:0] pstrb=0;

  // AXI M0
  logic awvalid, awready, wvalid, wready, wlast, bvalid, bready, arvalid, arready, rvalid, rready, rlast;
  logic [AW-1:0] awaddr, araddr; logic [7:0] awlen, arlen; logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp; logic [IW-1:0] awid, arid, bid, rid;
  logic [DW-1:0] wdata, rdata; logic [DWB-1:0] wstrb;

  logic [NCH-1:0] irq, ch_en;

  dma_top #(
    .NUM_CHANNELS(NCH), .ADDR_WIDTH(AW), .DATA_WIDTH(DW), .CHID_WIDTH(0), .GPO_WIDTH(8),
    .CH_GPO_MASK(8'h03), .CH_STREAM_MASK(8'h00), .CH_EXT_FEAT_MASK(8'hFF),
    .NUM_TRIGGER_IN(2), .NUM_TRIGGER_OUT(2), .AXI5_M1_PRESENT(1'b0), .SECEXT_PRESENT(1'b1)
  ) dut (
    .clk(clk), .resetn(resetn), .aclken_m0(1'b1), .aclken_m1(1'b1), .pclken(1'b1),
    .clk_qreqn(1'b1), .clk_qacceptn(), .clk_qdeny(), .clk_qactive(),
    .preq(1'b0), .pstate(4'd8), .paccept(), .pdeny(), .pactive(),
    .psel(psel), .penable(penable), .pprot(pprot), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .pstrb(pstrb), .pready(pready), .pslverr(pslverr), .prdata(prdata), .pwakeup(1'b0), .pdebug(1'b0),
    .awakeup_m0(), .awvalid_m0(awvalid), .awready_m0(awready), .awaddr_m0(awaddr), .awburst_m0(awburst),
    .awid_m0(awid), .awlen_m0(awlen), .awsize_m0(awsize), .awqos_m0(), .awprot_m0(), .awcache_m0(),
    .awdomain_m0(), .awinner_m0(), .awchid_m0(), .awchidvalid_m0(),
    .arvalid_m0(arvalid), .arready_m0(arready), .araddr_m0(araddr), .arburst_m0(arburst), .arid_m0(arid),
    .arlen_m0(arlen), .arsize_m0(arsize), .arqos_m0(), .arprot_m0(), .arcache_m0(), .ardomain_m0(),
    .arinner_m0(), .archid_m0(), .archidvalid_m0(), .arcmdlink_m0(),
    .wvalid_m0(wvalid), .wready_m0(wready), .wlast_m0(wlast), .wstrb_m0(wstrb), .wdata_m0(wdata),
    .rvalid_m0(rvalid), .rready_m0(rready), .rid_m0(rid), .rlast_m0(rlast), .rdata_m0(rdata),
    .rpoison_m0('0), .rresp_m0(rresp), .bvalid_m0(bvalid), .bready_m0(bready), .bid_m0(bid), .bresp_m0(bresp),
    .awakeup_m1(), .awvalid_m1(), .awready_m1(1'b0), .awaddr_m1(), .awburst_m1(), .awid_m1(), .awlen_m1(),
    .awsize_m1(), .awqos_m1(), .awprot_m1(), .awcache_m1(), .awdomain_m1(), .awinner_m1(), .awchid_m1(),
    .awchidvalid_m1(), .arvalid_m1(), .arready_m1(1'b0), .araddr_m1(), .arburst_m1(), .arid_m1(), .arlen_m1(),
    .arsize_m1(), .arqos_m1(), .arprot_m1(), .arcache_m1(), .ardomain_m1(), .arinner_m1(), .archid_m1(),
    .archidvalid_m1(), .arcmdlink_m1(), .wvalid_m1(), .wready_m1(1'b0), .wlast_m1(), .wstrb_m1(), .wdata_m1(),
    .rvalid_m1(1'b0), .rready_m1(), .rid_m1('0), .rlast_m1(1'b0), .rdata_m1('0), .rpoison_m1('0), .rresp_m1('0),
    .bvalid_m1(1'b0), .bready_m1(), .bid_m1('0), .bresp_m1('0),
    .trig_in_req('0), .trig_in_req_type('0), .trig_in_ack(), .trig_in_ack_type(),
    .trig_out_req(), .trig_out_ack('0),
    .irq_channel(irq), .irq_comb_nonsec(), .irq_comb_sec(), .irq_sec_viol_err(),
    .str_out_tvalid(), .str_out_tready('0), .str_out_tdata(), .str_out_tstrb(), .str_out_tlast(),
    .str_in_tvalid('0), .str_in_tready(), .str_in_tdata('0), .str_in_tstrb('0), .str_in_tlast('0), .str_in_flush(),
    .gpo_ch(), .allch_stop_req_nonsec(1'b0), .allch_stop_ack_nonsec(), .allch_pause_req_nonsec(1'b0),
    .allch_pause_ack_nonsec(), .allch_stop_req_sec(1'b0), .allch_stop_ack_sec(), .allch_pause_req_sec(1'b0),
    .allch_pause_ack_sec(), .halt_req(1'b0), .restart_req(1'b0), .halted(),
    .ch_enabled(ch_en), .ch_err(), .ch_stopped(), .ch_paused(), .ch_priv(), .ch_nonsec(),
    .boot_en(1'b0), .boot_addr('0), .boot_memattr('0), .boot_shareattr('0)
  );

  axi_mem_bfm #(.AW(AW), .DW(DW), .IW(IW), .RAND_PCT(30)) mem (
    .clk(clk), .resetn(resetn),
    .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
    .awburst(awburst), .awid(awid), .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
    .wlast(wlast), .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
    .arvalid(arvalid), .arready(arready), .araddr(araddr), .arlen(arlen), .arsize(arsize),
    .arburst(arburst), .arid(arid), .rvalid(rvalid), .rready(rready), .rdata(rdata), .rid(rid),
    .rlast(rlast), .rresp(rresp)
  );

  // ---------------------------------------------------------------- APB
  task automatic apb_wr(input [12:0] a, input [31:0] d);
    @(posedge clk);
    psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d; pstrb <= 4'hF; pprot <= 3'b000;
    @(posedge clk); penable <= 1;
    do @(posedge clk); while (!pready);
    if (pslverr) $error("APB write error @%h", a);
    psel <= 0; penable <= 0;
  endtask

  task automatic apb_rd(input [12:0] a, output [31:0] d);
    @(posedge clk);
    psel <= 1; penable <= 0; pwrite <= 0; paddr <= a; pstrb <= 0; pprot <= 3'b000;
    @(posedge clk); penable <= 1;
    do @(posedge clk); while (!pready);
    d = prdata;
    psel <= 0; penable <= 0;
  endtask

  // ---------------------------------------------------------------- checks
  int errors = 0;

  task automatic fill_src(input longint unsigned base, input int n, input int seed);
    for (int i = 0; i < n; i++) mem.mem[base + i] = byte'((i * 7 + seed) ^ (i >> 3));
  endtask

  task automatic run_1d(input int ch, input longint unsigned src, input longint unsigned dst,
                        input int nelem, input int ts, input bit normal, input int maxb);
    bit [31:0] st;
    int esz = 1 << ts;
    int base = 'h1000 + ch * 'h100;
    fill_src(src, nelem * esz, nelem);
    for (int i = 0; i < nelem * esz + 16; i++) mem.mem[dst - 8 + i] = 8'hEE;
    apb_wr(base + 'h10, src);
    apb_wr(base + 'h18, dst);
    apb_wr(base + 'h20, {16'(nelem), 16'(nelem)});
    apb_wr(base + 'h28, {12'd0, 4'(maxb), 4'd0, 4'h4, normal ? 8'h44 : 8'h00});
    apb_wr(base + 'h2C, {12'd0, 4'(maxb), 4'd0, 4'h4, normal ? 8'h44 : 8'h00});
    apb_wr(base + 'h30, 32'h0001_0001);
    apb_wr(base + 'h0C, {8'd0, 3'b001, 3'b000, 3'd0, 3'b000, 3'b001, 1'b0, 4'd0, 1'b0, 3'(ts)});
    apb_wr(base + 'h00, 32'h1);
    do begin
      repeat (20) @(posedge clk);
      apb_rd(base + 'h04, st);
    end while (!(st[16] || st[17] || st[19]));
    if (st[17]) begin $error("ch%0d error status %h", ch, st); errors++; end
    // compare
    for (int i = 0; i < nelem * esz; i++) begin
      byte unsigned exp, got;
      exp = mem.mem[(src & ~(esz-1)) + i];
      got = mem.mem.exists((dst & ~(esz-1)) + i) ? mem.mem[(dst & ~(esz-1)) + i] : 8'hXX;
      if (exp !== got) begin
        if (errors < 20) $error("ch%0d mismatch byte %0d exp %h got %h", ch, i, exp, got);
        errors++;
      end
    end
    // guard bytes
    if (mem.mem[(dst & ~(esz-1)) - 1] !== 8'hEE) begin $error("underrun"); errors++; end
    if (mem.mem[(dst & ~(esz-1)) + nelem*esz] !== 8'hEE) begin $error("overrun"); errors++; end
    apb_wr(base + 'h04, 32'h000F_0000);   // clear status
    $display("[%0t] 1D ch%0d src=%h dst=%h n=%0d ts=%0d normal=%0d mb=%0d done (errors=%0d)",
             $time, ch, src, dst, nelem, ts, normal, maxb, errors);
  endtask

  initial begin
    bit [31:0] d;
    repeat (5) @(posedge clk);
    resetn = 1;
    repeat (10) @(posedge clk);
    apb_rd(13'h0FB0, d); $display("DMA_BUILDCFG0 = %h", d);
    apb_rd(13'h10F8, d); $display("CH0_BUILDCFG0 = %h", d);
    run_1d(0, 'h1000, 'h8000, 64, 0, 0, 15);
    run_1d(0, 'h1003, 'h8005, 100, 0, 1, 15);
    run_1d(1, 'h2002, 'h9006, 77, 1, 1, 3);
    run_1d(0, 'h3004, 'hA00C, 33, 2, 0, 7);
    run_1d(1, 'h43F8, 'hB3F0, 300, 3, 1, 15);
    for (int t = 0; t < 40; t++) begin
      automatic int ts = $urandom_range(0, 3);
      automatic int esz = 1 << ts;
      run_1d(t % 2, ('h10000 + $urandom_range(0, 'hFFF)) & ~(esz-1), ('h40000 + $urandom_range(0, 'hFFF)) & ~(esz-1),
             $urandom_range(1, 600 / esz), ts, $urandom_range(0, 1), $urandom_range(0, 15));
    end
    $display("SMOKE DONE errors=%0d bfm_err=%0d", errors, mem.err_cnt);
    if (errors == 0 && mem.err_cnt == 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end

  initial begin
    #5ms;
    $display("TIMEOUT");
    $finish;
  end

endmodule
