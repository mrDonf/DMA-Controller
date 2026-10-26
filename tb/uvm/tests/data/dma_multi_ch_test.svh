//-----------------------------------------------------------------------------
// dma_multi_ch_test.svh
//   All channels run random commands concurrently (arbitration, routing).
//-----------------------------------------------------------------------------
class dma_multi_ch_test extends dma_base_test;
  `uvm_component_utils(dma_multi_ch_test)
  int rounds = 8;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    void'($value$plusargs("NCMD=%d", rounds));
    for (int r = 0; r < rounds; r++) begin
      dma_cmd cs [TB_NCH];
      for (int c = 0; c < TB_NCH; c++) begin
        cs[c] = gen_cmd(c);
        init_src(cs[c]);
        void'(expect_cmd(cs[c]));
        regs.program_cmd(cs[c]);
      end
      for (int c = 0; c < TB_NCH; c++) regs.enable(c);
      for (int c = 0; c < TB_NCH; c++) finish_cmd(cs[c]);
    end
  endtask
endclass
