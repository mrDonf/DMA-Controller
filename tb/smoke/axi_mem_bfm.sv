//-----------------------------------------------------------------------------
// axi_mem_bfm.sv - simple behavioural AXI subordinate memory (smoke test only)
// INCR / FIXED bursts, narrow transfers, strobes, random ready / latency.
// The UVM testbench uses the AXI5 VIP instead.
//-----------------------------------------------------------------------------
module axi_mem_bfm #(
  parameter int AW = 32,
  parameter int DW = 64,
  parameter int IW = 1,
  parameter int RAND_PCT = 30      // % of cycles with ready / valid stalls
) (
  input  logic          clk,
  input  logic          resetn,
  input  logic          awvalid, output logic awready,
  input  logic [AW-1:0] awaddr,  input logic [7:0] awlen, input logic [2:0] awsize,
  input  logic [1:0]    awburst, input logic [IW-1:0] awid,
  input  logic          wvalid,  output logic wready,
  input  logic [DW-1:0] wdata,   input logic [DW/8-1:0] wstrb, input logic wlast,
  output logic          bvalid,  input logic bready,
  output logic [IW-1:0] bid,     output logic [1:0] bresp,
  input  logic          arvalid, output logic arready,
  input  logic [AW-1:0] araddr,  input logic [7:0] arlen, input logic [2:0] arsize,
  input  logic [1:0]    arburst, input logic [IW-1:0] arid,
  output logic          rvalid,  input logic rready,
  output logic [DW-1:0] rdata,   output logic [IW-1:0] rid,
  output logic          rlast,   output logic [1:0] rresp
);
  localparam int DWB = DW / 8;

  byte unsigned mem [longint unsigned];
  int  err_cnt = 0;
  int  rd_beats = 0, wr_beats = 0;

  function automatic byte unsigned rd_byte(longint unsigned a);
    if (mem.exists(a)) return mem[a];
    return byte'(a ^ (a >> 8));
  endfunction

  typedef struct { longint unsigned addr; int len; int size; int burst; int id; } req_t;
  req_t aw_q[$], ar_q[$];
  int   b_q[$];

  function automatic bit stall();
    return ($urandom_range(0, 99) < RAND_PCT);
  endfunction

  function automatic longint unsigned beat_addr(req_t r, int bt);
    longint unsigned nb, base;
    nb   = 1 << r.size;
    base = (r.addr / nb) * nb;
    if (r.burst == 0 || bt == 0) return r.addr;
    return base + bt * nb;
  endfunction

  // ---------------- AW / AR acceptance
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      awready <= 1'b0;
      arready <= 1'b0;
    end else begin
      if (arvalid && arready) ar_q.push_back('{araddr, arlen, arsize, arburst, arid});
      awready <= !stall();
      arready <= !stall();
    end
  end

  // ---------------- W
  int wbeat = 0;
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      wready <= 1'b0;
      wbeat  = 0;
    end else begin
      // AW accepted in this cycle is visible to a W beat of the same cycle
      if (awvalid && awready) aw_q.push_back('{awaddr, awlen, awsize, awburst, awid});
      if (wvalid && wready) begin
        req_t r;
        longint unsigned a, lo, hi;
        if (aw_q.size() == 0) begin
          $error("[BFM] W beat before AW");
          err_cnt++;
        end else begin
          r  = aw_q[0];
          a  = beat_addr(r, wbeat);
          lo = (a >> r.size) << r.size;
          hi = lo + (1 << r.size);
          for (int b = 0; b < DWB; b++) begin
            automatic longint unsigned ba = (a / DWB) * DWB + b;
            if (wstrb[b]) begin
              if (ba < lo || ba >= hi || ba < a) begin
                $error("[BFM] WSTRB lane %0d outside beat (addr %h size %0d)", b, a, r.size);
                err_cnt++;
              end
              mem[ba] = wdata[8*b +: 8];
            end
          end
          if (wlast != (wbeat == r.len)) begin
            $error("[BFM] WLAST mismatch beat %0d len %0d", wbeat, r.len);
            err_cnt++;
          end
          wr_beats++;
          wbeat++;
          if (wbeat > r.len) begin
            b_q.push_back(r.id);
            void'(aw_q.pop_front());
            wbeat = 0;
          end
        end
      end
      wready <= !stall();
    end
  end

  // ---------------- B (procedural)
  initial begin
    bvalid = 1'b0; bresp = 2'b00; bid = '0;
    forever begin
      @(posedge clk);
      if (!resetn) begin bvalid <= 1'b0; continue; end
      if (b_q.size() > 0 && !stall()) begin
        bid    <= IW'(b_q.pop_front());
        bvalid <= 1'b1;
        do @(posedge clk); while (!bready);
        bvalid <= 1'b0;
      end
    end
  end

  // ---------------- R (procedural, in order)
  initial begin
    rvalid = 1'b0; rlast = 1'b0; rresp = 2'b00; rid = '0; rdata = '0;
    forever begin
      @(posedge clk);
      if (!resetn) begin rvalid <= 1'b0; continue; end
      if (ar_q.size() > 0) begin
        req_t r;
        r = ar_q.pop_front();
        for (int bt = 0; bt <= r.len; bt++) begin
          longint unsigned a;
          while (stall()) @(posedge clk);
          a = beat_addr(r, bt);
          for (int b = 0; b < DWB; b++) rdata[8*b +: 8] <= rd_byte((a / DWB) * DWB + b);
          rid    <= IW'(r.id);
          rlast  <= (bt == r.len);
          rvalid <= 1'b1;
          do @(posedge clk); while (!rready);
          rd_beats++;
          rvalid <= 1'b0;
        end
      end
    end
  end

endmodule
