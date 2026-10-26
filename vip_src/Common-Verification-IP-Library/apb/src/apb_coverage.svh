// apb_coverage - functional coverage of the observed traffic (subscriber of the monitor)
class apb_coverage extends uvm_subscriber #(apb_item);
  `uvm_component_utils(apb_coverage)

  apb_agent_cfg cfg;
  apb_item      it;
  bit           b2b;                 // the transfer started in the cycle after the previous one completed (it.idle == 0)

  localparam bit [APB_ADDR_W-1:0] Q1 = APB_ADDR_W'(1) << (APB_ADDR_W - 2);
  localparam bit [APB_ADDR_W-1:0] Q2 = Q1 << 1;
  localparam bit [APB_ADDR_W-1:0] Q3 = Q2 | Q1;

  covergroup cg_xfer;
    option.per_instance = 1;
    cp_dir  : coverpoint it.write { bins read = {0}; bins write = {1}; }
    cp_addr : coverpoint it.addr  {
      bins low   = {[0 : Q1 - 1]};
      bins mid1  = {[Q1 : Q2 - 1]};
      bins mid2  = {[Q2 : Q3 - 1]};
      bins high  = {[Q3 : $]};
    }
    cp_align : coverpoint (it.addr % APB_STRB_W) { bins aligned = {0}; bins unaligned = default; }
    cp_strb  : coverpoint it.strb iff (it.write) {
      bins full = {{APB_STRB_W{1'b1}}};
      bins single_lane[] = {[1:$]} with ($countones(item) == 1);
      bins partial = default;
    }
    cp_prot  : coverpoint it.prot { bins p[] = {[0:7]}; }
    cp_err   : coverpoint it.slverr { bins ok = {0}; bins err = {1}; }
    cp_wait  : coverpoint it.wait_cycles { bins none = {0}; bins one = {1}; bins few = {[2:3]}; bins many = {[4:15]}; bins long_ = {[16:$]}; }
    cp_b2b   : coverpoint b2b { bins gap = {0}; bins back_to_back = {1}; }
    x_dir_err  : cross cp_dir, cp_err;
    x_dir_wait : cross cp_dir, cp_wait;
    x_dir_prot : cross cp_dir, cp_prot;
    x_dir_b2b  : cross cp_dir, cp_b2b;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_xfer = new();
    cg_xfer.set_inst_name({get_full_name(), ".cg_xfer"});
  endfunction

  function void write(apb_item t);
    if (cfg != null && !cfg.coverage_en) return;
    it  = t;
    b2b = (t.idle == 0);
    cg_xfer.sample();
  endfunction
endclass : apb_coverage
