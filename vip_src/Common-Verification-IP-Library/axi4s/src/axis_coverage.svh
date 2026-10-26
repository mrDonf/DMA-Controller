// axis_coverage - functional coverage of observed packets (subscriber of the monitor)
class axis_coverage extends uvm_subscriber #(axis_item);
  `uvm_component_utils(axis_coverage)

  axis_agent_cfg cfg;
  axis_item      it;
  bit            has_pos_bytes, has_null_bytes, tail_partial, user_nonzero, id_changes_between;
  int unsigned   nbytes;
  bit [AXIS_ID_W-1:0] prev_id;
  bit            have_prev;

  covergroup cg_pkt;
    option.per_instance = 1;
    cp_beats  : coverpoint it.data.size() { bins one = {1}; bins l2_4 = {[2:4]}; bins l5_8 = {[5:8]}; bins l9_16 = {[9:16]}; bins l17_64 = {[17:$]}; }
    cp_bytes  : coverpoint nbytes         { bins b1 = {1}; bins few = {[2:AXIS_KEEP_W]}; bins mid = {[AXIS_KEEP_W+1:8*AXIS_KEEP_W]}; bins big = {[8*AXIS_KEEP_W+1:$]}; }
    cp_tail   : coverpoint tail_partial   { bins full = {0}; bins partial = {1}; }
    cp_pos    : coverpoint has_pos_bytes  { bins none = {0}; bins position_bytes = {1}; }
    cp_null   : coverpoint has_null_bytes { bins none = {0}; bins null_bytes = {1}; }
    cp_id     : coverpoint it.id          { bins low = {[0:(2**AXIS_ID_W)/2-1]}; bins high = {[(2**AXIS_ID_W)/2:$]}; }
    cp_dest   : coverpoint it.dest        { bins low = {[0:(2**AXIS_DEST_W)/2-1]}; bins high = {[(2**AXIS_DEST_W)/2:$]}; }
    cp_user   : coverpoint user_nonzero;
    cp_gap    : coverpoint it.gap         { bins b2b = {0}; bins short_ = {[1:5]}; bins long_ = {[6:$]}; }
    cp_stall  : coverpoint it.stalls      { bins none = {0}; bins few = {[1:4]}; bins many = {[5:$]}; }
    cp_idchg  : coverpoint id_changes_between;
    x_tail_len : cross cp_tail, cp_beats;
    x_pos_tail : cross cp_pos, cp_tail;
    x_gap_stall: cross cp_gap, cp_stall;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_pkt = new();
    cg_pkt.set_inst_name({get_full_name(), ".cg_pkt"});
  endfunction

  function void write(axis_item t);
    if (t.aborted || t.data.size() == 0) return;
    if (cfg != null && !cfg.coverage_en) return;
    it = t;
    nbytes = t.num_data_bytes();
    has_pos_bytes = 0; has_null_bytes = 0; user_nonzero = 0;
    foreach (t.keep[i]) begin
      if ((t.keep[i] & ~t.strb[i]) != 0) has_pos_bytes = 1;
      if (t.keep[i] != '1 && i != t.keep.size() - 1) has_null_bytes = 1;
      if (t.user[i] != 0) user_nonzero = 1;
    end
    tail_partial = (t.keep[t.keep.size() - 1] != '1);
    id_changes_between = have_prev && (t.id != prev_id);
    prev_id = t.id; have_prev = 1;
    cg_pkt.sample();
  endfunction
endclass : axis_coverage
