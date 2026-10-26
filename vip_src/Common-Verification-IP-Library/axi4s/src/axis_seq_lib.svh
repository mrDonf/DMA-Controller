// -----------------------------------------------------------------------------
// AXI4-Stream sequence library
//   axis_base_seq      helper send(item) (blocking: waits until the last beat was accepted)
//   axis_pkt_seq       n random packets (lengths, TKEEP modes, ID / DEST / USER, delays)
//   axis_stream_seq    n packets queued without any delay: continuous TVALID across packets (maximum throughput)
//   axis_byte_seq      packets of every byte length 1..max (partial last beats)
//   axis_sparse_seq    packets with position bytes (TKEEP=1, TSTRB=0) and sparse TKEEP
//   axis_multi_seq     packets cycling through several TID / TDEST values
//   axis_long_seq      one long packet
// -----------------------------------------------------------------------------
class axis_base_seq extends uvm_sequence #(axis_item);
  `uvm_object_utils(axis_base_seq)

  function new(string name = "axis_base_seq");
    super.new(name);
    set_response_queue_depth(-1);
  endfunction

  task send(axis_item it);
    axis_item r;
    start_item(it);
    finish_item(it);
    get_response(r);
    it.aborted = r.aborted;
  endtask
endclass : axis_base_seq

class axis_pkt_seq extends axis_base_seq;
  `uvm_object_utils(axis_pkt_seq)
  rand int unsigned n = 20;
  constraint c_n { n inside {[1:2000]}; }
  function new(string name = "axis_pkt_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axis_item it = axis_item::type_id::create("it");
      if (!it.randomize()) `vip_fatal("AXIS_SEQ", "randomize failed")
      send(it);
    end
  endtask
endclass : axis_pkt_seq

class axis_stream_seq extends axis_base_seq;
  `uvm_object_utils(axis_stream_seq)
  rand int unsigned n = 20;
  rand int unsigned max_beats = 8;
  constraint c_n { n inside {[2:500]}; max_beats inside {[1:64]}; }
  function new(string name = "axis_stream_seq"); super.new(name); endfunction
  task body();
    axis_item q[$];
    axis_item r;
    repeat (n) begin
      axis_item it = axis_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { beats <= max_beats; gap == 0; foreach (delay[i]) delay[i] == 0; }) `vip_fatal("AXIS_SEQ", "randomize failed")
      finish_item(it);
      q.push_back(it);
    end
    foreach (q[i]) get_response(r, q[i].get_transaction_id());
  endtask
endclass : axis_stream_seq

class axis_byte_seq extends axis_base_seq;
  `uvm_object_utils(axis_byte_seq)
  rand int unsigned max_bytes = 3 * AXIS_KEEP_W;
  constraint c_m { max_bytes inside {[1:512]}; }
  function new(string name = "axis_byte_seq"); super.new(name); endfunction
  task body();
    for (int nb = 1; nb <= max_bytes; nb++) begin
      axis_item it = axis_item::type_id::create("it");
      int unsigned bts = (nb + AXIS_KEEP_W - 1) / AXIS_KEEP_W;
      int unsigned last_bytes = nb - (bts - 1) * AXIS_KEEP_W;
      if (!it.randomize() with { beats == bts; keep_mode == AXIS_KEEP_TAIL; keep[bts - 1] == ((1 << last_bytes) - 1); }) `vip_fatal("AXIS_SEQ", "randomize failed")
      send(it);
    end
  endtask
endclass : axis_byte_seq

class axis_sparse_seq extends axis_base_seq;
  `uvm_object_utils(axis_sparse_seq)
  rand int unsigned n = 20;
  constraint c_n { n inside {[1:500]}; }
  function new(string name = "axis_sparse_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axis_item it = axis_item::type_id::create("it");
      if (!it.randomize() with { keep_mode == AXIS_KEEP_SPARSE; }) `vip_fatal("AXIS_SEQ", "randomize failed")
      send(it);
    end
  endtask
endclass : axis_sparse_seq

class axis_multi_seq extends axis_base_seq;
  `uvm_object_utils(axis_multi_seq)
  rand int unsigned n = 32;
  constraint c_n { n inside {[2:500]}; }
  function new(string name = "axis_multi_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      axis_item it = axis_item::type_id::create("it");
      if (!it.randomize() with { id == (i % (2 ** AXIS_ID_W)); dest == ((i / 2) % (2 ** AXIS_DEST_W)); }) `vip_fatal("AXIS_SEQ", "randomize failed")
      send(it);
    end
  endtask
endclass : axis_multi_seq

class axis_long_seq extends axis_base_seq;
  `uvm_object_utils(axis_long_seq)
  rand int unsigned len = 512;
  constraint c_l { len inside {[65:4096]}; }
  function new(string name = "axis_long_seq"); super.new(name); endfunction
  task body();
    axis_item it = axis_item::type_id::create("it");
    // the generic constraint limits packets to 64 beats: disable it for this one
    it.c_beats.constraint_mode(0);
    if (!it.randomize() with { beats == len; keep_mode == AXIS_KEEP_TAIL; foreach (delay[i]) delay[i] inside {[0:1]}; }) `vip_fatal("AXIS_SEQ", "randomize failed")
    send(it);
  endtask
endclass : axis_long_seq
