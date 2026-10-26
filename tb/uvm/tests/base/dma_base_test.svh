//-----------------------------------------------------------------------------
// dma_base_test.svh
//   Base test: environment, register API, memory windows, random command generator,
//   command execution helpers (expect / start / finish / run).
//-----------------------------------------------------------------------------
class dma_base_test extends uvm_test;
  `uvm_component_utils(dma_base_test)

  dma_env        env;
  dma_reg_api    regs;
  dma_ctrl_vif_t vif;
  int unsigned   n_cmds;
  longint        timeout_ns = 50_000_000;   // overall test timeout
  string         tname;

  // generator knobs
  int  max_bytes   = 2048;     // per command, source side
  int  p_device    = 15;       // % device memory
  bit  allow_m1    = 1;
  bit  use_all_ch  = 1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = dma_env::type_id::create("env", this);
    if (!uvm_config_db #(dma_ctrl_vif_t)::get(this, "", "ctrl_vif", vif)) `uvm_fatal("TEST", "no ctrl_vif")
    tname = get_type_name();
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_top.set_timeout(timeout_ns * 1ns, 0);
  endfunction

  // ------------------------------------------------------------------ setup
  task init_signals();
    vif.pdebug                 <= 1'b0;
    vif.allch_stop_req_nonsec  <= 1'b0;
    vif.allch_pause_req_nonsec <= 1'b0;
    vif.allch_stop_req_sec     <= 1'b0;
    vif.allch_pause_req_sec    <= 1'b0;
    vif.halt_req               <= 1'b0;
    vif.restart_req            <= 1'b0;
    vif.boot_en                <= 1'b0;
    vif.boot_addr              <= '0;
    vif.boot_memattr           <= 8'h44;
    vif.boot_shareattr         <= 2'b00;
  endtask

  virtual task pre_body();
  endtask

  virtual task body();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    init_signals();
    regs = dma_reg_api::type_id::create("regs");
    regs.vif = vif;
    regs.bus = apb_api_seq::type_id::create("bus");
    fork regs.bus.start(env.apb.sqr); join_none
    pre_body();
    wait (vif.resetn === 1'b1);
    repeat (10) @(posedge vif.clk);
    body();
    repeat (50) @(posedge vif.clk);
    regs.bus.stop = 1;
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    `uvm_info("TEST", $sformatf("%s: %0d commands executed", tname, n_cmds), UVM_NONE)
    if (errs == 0) `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
    else           `uvm_info("TEST", $sformatf("*** TEST FAILED *** (%0d errors)", errs), UVM_NONE)
  endfunction

  // ------------------------------------------------------------------ memory
  // per channel windows (2 MB each): source then destination; port 1 windows
  // are placed in the M1 address range when the secondary port exists
  function longint unsigned win_base(int ch, bit dst, bit m1);
    longint unsigned b = 64'h0010_0000 + longint'(ch) * 64'h0040_0000 + (dst ? 64'h0020_0000 : 0);
    if (m1) b = b + 64'h8000_0000;
    return b;
  endfunction
  localparam longint unsigned WIN_SIZE = 64'h0020_0000;

  function void fill_rand(longint unsigned a, int n);
    for (int i = 0; i < n; i++) env.mem.write_byte(a + i, $urandom);
  endfunction

  // ------------------------------------------------------------------ random command generator
  function bit [15:0] rnd_inc();
    int r = $urandom_range(99);
    if (r < 60) return 16'd1;
    if (r < 70) return 16'd0;
    if (r < 90) return 16'($urandom_range(0, 8) - 4);
    return 16'($urandom_range(0, 64) - 32);
  endfunction

  // byte offset span of one side relative to its base: [lo, hi)
  function void side_span(dma_cmd c, bit dst, longint unsigned nx, longint unsigned ny,
                          output longint lo, output longint hi);
    int esz = c.esize();
    bit [4:0]  tsz  = dst ? c.destsize : c.srctsize;
    bit [31:0] tm   = dst ? c.destmplt : c.srctmplt;
    longint    inc  = longint'($signed(dst ? c.desxinc : c.srcxinc));
    longint    str  = longint'($signed(dst ? c.desystride : c.srcystride));
    longint    xe, ye, xl, xh, yl, yh;
    if (nx == 0) nx = 1;
    if (ny == 0) ny = 1;
    if (tsz != 0) begin
      int pos[$];
      tm[0] = 1;
      for (int i = 0; i <= tsz; i++) if (tm[i]) pos.push_back(i);
      xe = ((nx - 1) / pos.size()) * (tsz + 1) + pos[(nx - 1) % pos.size()];
      xe = xe * esz;
      xl = 0; xh = xe;
    end else begin
      xe = inc * longint'(nx - 1) * esz;
      xl = (xe < 0) ? xe : 0;
      xh = (xe < 0) ? 0 : xe;
    end
    ye = c.is2d() ? str * longint'(ny - 1) * esz : 0;
    yl = (ye < 0) ? ye : 0;
    yh = (ye < 0) ? 0 : ye;
    lo = xl + yl;
    hi = xh + yh + esz;
  endfunction

  // place both sides inside the channel windows; returns 0 if they do not fit
  function bit place(dma_cmd c);
    longint lo, hi;
    bit m1s, m1d;
    m1s = TB_M1 && allow_m1 && ($urandom_range(1) == 1);
    m1d = TB_M1 && allow_m1 && ($urandom_range(1) == 1);
    side_span(c, 0, c.srcxsize, c.is2d() ? c.srcysize : 1, lo, hi);
    if (hi - lo + 64 > WIN_SIZE) return 0;
    c.srcaddr = win_base(c.ch, 0, m1s) + longint'(-lo) +
                (longint'($urandom_range(0, int'(WIN_SIZE - (hi - lo) - 64))) & ~longint'(c.esize() - 1));
    side_span(c, 1, c.desxsize, c.is2d() ? c.desysize : 1, lo, hi);
    if (hi - lo + 64 > WIN_SIZE) return 0;
    c.desaddr = win_base(c.ch, 1, m1d) + longint'(-lo) +
                (longint'($urandom_range(0, int'(WIN_SIZE - (hi - lo) - 64))) & ~longint'(c.esize() - 1));
    // sub-element address bits are ignored by the DMA: keep some for coverage
    if ($urandom_range(3) == 0) c.srcaddr += $urandom_range(0, c.esize() - 1);
    if ($urandom_range(3) == 0) c.desaddr += $urandom_range(0, c.esize() - 1);
    return 1;
  endfunction

  function bit [7:0] rnd_attr();
    int r = $urandom_range(99);
    if (r < p_device) return ($urandom_range(1)) ? 8'h00 : 8'h04;
    case ($urandom_range(3))
      0: return 8'h44;
      1: return 8'hFF;
      2: return 8'h77;
      default: return 8'hAA;
    endcase
  endfunction

  // kind: 0 1D continue, 1 1D wrap/fill, 2 2D, 3 template, -1 random
  function dma_cmd gen_cmd(int ch, int kind = -1);
    dma_cmd c;
    int esz, maxel;
    bit ext = TB_EXT_MASK[ch];
    for (int tries = 0; tries < 50; tries++) begin
      c = dma_cmd::type_id::create("cmd");
      c.ch = ch;
      if (kind < 0) begin
        int r = $urandom_range(99);
        kind = (r < 40) ? 0 : (r < 55) ? 1 : (r < 85) ? 2 : 3;
      end
      if (!ext && kind != 0) kind = 0;
      c.ts   = $urandom_range(0, $clog2(TB_DWB));
      esz    = c.esize();
      maxel  = max_bytes / esz;
      if (maxel < 1) maxel = 1;
      c.prio = $urandom_range(0, 15);
      c.src_memattr = rnd_attr();
      c.des_memattr = rnd_attr();
      c.src_maxburst = $urandom_range(0, 15);
      c.des_maxburst = $urandom_range(0, 15);
      c.fillval = $urandom;
      c.intren  = 11'h00F;
      case (kind)
        0: begin
          c.xtype = T_CONTINUE;
          c.srcxsize = $urandom_range(1, maxel);
          c.desxsize = ($urandom_range(9) == 0) ? $urandom_range(1, maxel) : c.srcxsize;
          c.srcxinc = rnd_inc();
          c.desxinc = rnd_inc();
        end
        1: begin
          c.xtype = ($urandom_range(1)) ? T_WRAP : T_FILL;
          c.desxsize = $urandom_range(1, maxel);
          c.srcxsize = $urandom_range(1, c.desxsize);
          if (c.xtype == T_FILL && $urandom_range(9) == 0) c.srcxsize = 0;
          c.srcxinc = rnd_inc();
          c.desxinc = rnd_inc();
        end
        2: begin
          int sx, sy, dx, dy;
          c.xtype = $urandom_range(T_CONTINUE, T_FILL);
          c.ytype = $urandom_range(T_CONTINUE, T_FILL);
          sx = $urandom_range(1, 24); sy = $urandom_range(1, 12);
          while (sx * sy * esz > max_bytes) begin
            if (sx > 1) sx = sx / 2; else sy = sy / 2;
            if (sy == 0) sy = 1;
          end
          dx = $urandom_range(1, 24); dy = $urandom_range(1, 12);
          if (c.xtype != T_CONTINUE && dx < sx) dx = sx;                 // wrap / fill: destination line >= source
          if (c.ytype != T_CONTINUE && c.xtype != T_CONTINUE && dy < sy) dy = sy;
          if (c.xtype == T_CONTINUE && c.ytype != T_CONTINUE)            // area >= source area
            while (dx * dy < sx * sy) dy++;
          while (dx * dy * esz > 3 * max_bytes) begin
            if (dy > 1) dy--; else if (dx > 1) dx--; else break;
          end
          if (c.xtype == T_CONTINUE && c.ytype != T_CONTINUE && dx * dy < sx * sy) continue;
          c.srcxsize = sx; c.srcysize = sy; c.desxsize = dx; c.desysize = dy;
          c.srcxinc = rnd_inc(); c.desxinc = rnd_inc();
          if (c.srcxinc == 0) c.srcxinc = 1;
          if (c.desxinc == 0 && $urandom_range(3) != 0) c.desxinc = 1;
          c.srcystride = 16'($urandom_range(0, 1) ? (sx * $signed(c.srcxinc) + $urandom_range(0, 8))
                                                  : -(sx * $signed(c.srcxinc) + $urandom_range(0, 8)));
          c.desystride = 16'($urandom_range(0, 1) ? (dx * $signed(c.desxinc) + $urandom_range(0, 8))
                                                  : -(dx * $signed(c.desxinc) + $urandom_range(0, 8)));
          if ($urandom_range(7) == 0) c.desystride = 0;
        end
        3: begin
          c.xtype = ($urandom_range(3) != 0) ? T_CONTINUE : (($urandom_range(1)) ? T_WRAP : T_FILL);
          c.srcxsize = $urandom_range(1, maxel / 2 + 1);
          c.desxsize = (c.xtype == T_CONTINUE) ? c.srcxsize : $urandom_range(c.srcxsize, maxel / 2 + 1);
          if ($urandom_range(1)) begin c.srctsize = $urandom_range(1, 31); c.srctmplt = $urandom | 1; end
          if ($urandom_range(1) || c.srctsize == 0) begin c.destsize = $urandom_range(1, 31); c.destmplt = $urandom | 1; end
          c.srcxinc = 1; c.desxinc = 1;
        end
        default: ;
      endcase
      if (place(c)) return c;
    end
    `uvm_fatal("GEN", "could not place a command")
    return c;
  endfunction

  // ------------------------------------------------------------------ execution
  // predict + register expectations (memory snapshot taken now)
  function dma_exp expect_cmd(dma_cmd c, byte unsigned si_bytes[$] = {});
    dma_exp e = dma_ref_model::predict(c, env.mem, si_bytes);
    env.cov.sample_cmd(c);
    env.sb.add_expect(e);
    set_attr_exp(c);
    return e;
  endfunction

  // expected AXI attributes of the channel for this command
  function void set_attr_exp(dma_cmd c);
    bit ns = regs.ch_ns.exists(c.ch) ? regs.ch_ns[c.ch] : !TB_SECEXT;
    bit pv = regs.ch_pv.exists(c.ch) ? regs.ch_pv[c.ch] : 1'b0;
    env.sb.exp_qos[c.ch]    = c.prio;
    env.sb.exp_rprot[c.ch]  = {1'b0, ns | c.src_nonsec, pv & c.src_priv};
    env.sb.exp_wprot[c.ch]  = {1'b0, ns | c.des_nonsec, pv & c.des_priv};
    env.sb.exp_lprot[c.ch]  = {1'b1, ns, pv};
    env.sb.exp_rcache[c.ch] = tb_cache(c.src_memattr, 1'b0);
    env.sb.exp_wcache[c.ch] = tb_cache(c.des_memattr, 1'b1);
    env.sb.exp_lcache[c.ch] = tb_cache(c.linkattr[7:0], 1'b0);
    env.sb.chk_attr[c.ch]   = 1'b1;
  endfunction

  task start_cmd(dma_cmd c, byte unsigned si_bytes[$] = {});
    void'(expect_cmd(c, si_bytes));
    regs.program_cmd(c);
    regs.enable(c.ch);
  endtask

  task finish_cmd(dma_cmd c, bit [31:0] exp_mask = (1 << ST_DONE), bit chk_sb = 1);
    bit [31:0] st, ei;
    regs.wait_idle(c.ch, st);
    if ((st & 32'h000F_0000) != exp_mask) begin
      regs.chr(c.ch, CH_ERRINFO, ei);
      `uvm_error("TEST", $sformatf("ch%0d status %08h (ERRINFO %08h), expected %08h : %s",
                                   c.ch, st, ei, exp_mask, c.convert2string()))
    end
    if (chk_sb) void'(env.sb.check_done(c.ch, tname));
    env.sb.clear_reads(c.ch);
    regs.clear_status(c.ch);
    n_cmds++;
  endtask

  task run_cmd(dma_cmd c, byte unsigned si_bytes[$] = {});
    `uvm_info("CMD", c.convert2string(), UVM_LOW)
    start_cmd(c, si_bytes);
    finish_cmd(c);
  endtask

  // fill the source area of a command with random bytes
  function void init_src(dma_cmd c);
    longint lo, hi;
    side_span(c, 0, c.srcxsize, c.is2d() ? c.srcysize : 1, lo, hi);
    fill_rand(longint'(c.srcaddr & ~longint'(c.esize() - 1)) + lo, int'(hi - lo));
  endfunction

endclass : dma_base_test
