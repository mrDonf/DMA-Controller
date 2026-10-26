// axis_item - one AXI4-Stream packet (beats up to TLAST)
class axis_item extends uvm_sequence_item;
  rand bit [AXIS_ID_W-1:0]   id;
  rand bit [AXIS_DEST_W-1:0] dest;
  rand int unsigned          beats;
  rand axis_keep_e           keep_mode;
  rand bit [AXIS_DATA_W-1:0] data[];
  rand bit [AXIS_KEEP_W-1:0] keep[];
  rand bit [AXIS_KEEP_W-1:0] strb[];
  rand bit [AXIS_USER_W-1:0] user[];
  rand int unsigned          delay[];        // cycles with TVALID low before every beat
  rand int unsigned          gap;            // idle cycles before the packet

  // observation
  time         start_time, end_time;
  int unsigned stalls;                       // cycles with TVALID && !TREADY
  bit          aborted;

  `uvm_object_utils(axis_item)

  constraint c_beats  { beats inside {[1:64]}; beats dist { 1 := 15, [2:8] :/ 60, [9:64] :/ 25 }; }
  constraint c_arrays { data.size() == beats; keep.size() == beats; strb.size() == beats; user.size() == beats; delay.size() == beats; }
  constraint c_mode   { keep_mode dist { AXIS_KEEP_FULL := 30, AXIS_KEEP_TAIL := 50, AXIS_KEEP_SPARSE := 20 }; }
  constraint c_keep   {
    foreach (keep[i]) {
      (keep_mode == AXIS_KEEP_FULL) -> keep[i] == '1;
      (keep_mode == AXIS_KEEP_TAIL && i != beats - 1) -> keep[i] == '1;
      // tail: the last beat holds 1..KEEP_W bytes in the low lanes
      (keep_mode == AXIS_KEEP_TAIL && i == beats - 1) -> (keep[i] != '0 && ((keep[i] + 1) & keep[i]) == '0);
      (keep_mode == AXIS_KEEP_SPARSE) -> keep[i] != '0;
    }
    solve keep_mode, beats before keep;
  }
  constraint c_strb   {
    foreach (strb[i]) {
      (keep_mode == AXIS_KEEP_SPARSE) -> (strb[i] & ~keep[i]) == '0;      // position bytes: TKEEP=1, TSTRB=0
      (keep_mode != AXIS_KEEP_SPARSE) -> strb[i] == keep[i];
    }
    solve keep before strb;
  }
  constraint c_delay  { foreach (delay[i]) delay[i] dist { 0 := 70, [1:3] := 25, [4:10] := 5 }; gap dist { 0 := 60, [1:5] := 30, [6:20] := 10 }; }

  function new(string name = "axis_item");
    super.new(name);
  endfunction

  // the data bytes of the packet (TKEEP and TSTRB set), in transmission order
  function void bytes(ref byte unsigned q[$]);
    q.delete();
    foreach (data[i])
      for (int l = 0; l < AXIS_KEEP_W; l++)
        if (keep[i][l] && strb[i][l]) q.push_back(data[i][8*l +: 8]);
  endfunction

  function int unsigned num_data_bytes();
    byte unsigned q[$];
    bytes(q);
    return q.size();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axis_item r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `vip_fatal("AXIS_ITEM", "do_copy: type mismatch")
    id = r.id; dest = r.dest; beats = r.beats; keep_mode = r.keep_mode; data = r.data; keep = r.keep; strb = r.strb; user = r.user;
    delay = r.delay; gap = r.gap; start_time = r.start_time; end_time = r.end_time; stalls = r.stalls; aborted = r.aborted;
  endfunction

  // full comparison: payload bytes are compared only where the byte is a data byte (keep && strb)
  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    axis_item r;
    if (!$cast(r, rhs)) return 0;
    if (!(id == r.id && dest == r.dest && data.size() == r.data.size() && keep == r.keep && strb == r.strb && user == r.user)) return 0;
    foreach (data[i])
      for (int l = 0; l < AXIS_KEEP_W; l++)
        if (keep[i][l] && strb[i][l] && data[i][8*l +: 8] !== r.data[i][8*l +: 8]) return 0;
    return 1;
  endfunction

  virtual function string convert2string();
    string s = $sformatf("id=%0h dest=%0h beats=%0d bytes=%0d", id, dest, data.size(), num_data_bytes());
    foreach (data[i]) if (i < 4) s = {s, $sformatf(" [%0d] d=%0h k=%b s=%b u=%0h", i, data[i], keep[i], strb[i], user[i])};
    if (aborted) s = {s, " ABORTED"};
    return s;
  endfunction
endclass : axis_item
