// -----------------------------------------------------------------------------
// vip_clk_rst_if - clock and reset generator that tests can control through a virtual interface
//   period_ps  clock period in ps (variable, set by the top at time 0)
//   rst_n      active-low reset, asserted at time 0 for `init_cycles` cycles
//   pulse(n)   asserts reset for n clock cycles (used by reset-in-the-middle tests), returns after release
// -----------------------------------------------------------------------------
`ifndef VIP_CLK_RST_IF_SV
`define VIP_CLK_RST_IF_SV

interface vip_clk_rst_if;
  // period and initial reset length are variables (not parameters) so that every testbench uses the same
  // virtual-interface type; a top changes them at time 0 (the clock starts at 1 ps)
  int unsigned period_ps   = 10000;
  int unsigned init_cycles = 5;
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  bit   clk_running = 1'b1;

  initial begin
    #1ps;
    forever begin
      #((period_ps / 2) * 1ps) if (clk_running) clk = ~clk;
    end
  end

  initial begin
    rst_n = 1'b0;
    #1ps;
    repeat (init_cycles) @(posedge clk);
    #1ns rst_n = 1'b1;
  end

  task automatic pulse(int unsigned cycles);
    @(posedge clk);
    #1ns rst_n = 1'b0;
    repeat (cycles) @(posedge clk);
    #1ns rst_n = 1'b1;
  endtask

  task automatic wait_cycles(int unsigned n);
    repeat (n) @(posedge clk);
  endtask
endinterface : vip_clk_rst_if

`endif
