// axi5_item - one AXI5 burst (write: AW + W beats + B [+ R beats for AtomicLoad / Swap / Compare], read: AR + R beats)
//   atomics are built with axi5_base_seq::atomic() (size / length / burst / strobes follow the atomic rules)
class axi5_item extends uvm_sequence_item;
  rand bit                     write;
  rand bit [AXI5_ID_W-1:0]     id;
  rand bit [AXI5_ADDR_W-1:0]   addr;
  rand bit [7:0]               len;             // AxLEN: beats - 1
  rand bit [2:0]               size;            // AxSIZE: log2(bytes per beat)
  rand axi5_burst_e            burst;
  rand bit                     lock;            // exclusive access
  rand bit [3:0]               cache;
  rand bit [2:0]               prot;
  rand bit [3:0]               qos;
  rand bit [3:0]               region;
  rand bit [AXI5_USER_W-1:0]   user;
  rand bit [AXI5_DATA_W-1:0]   data[];          // per beat, bus lanes as on the wire (write data / read data)
  rand bit [AXI5_STRB_W-1:0]   strb[];          // per beat, write only
  rand bit [5:0]               atop;            // AWATOP (writes)
  rand bit                     idunq;           // AxIDUNQ
  rand bit                     trace;           // AxTRACE (also WTRACE of every beat)
  rand bit [AXI5_LOOP_W-1:0]   loop;            // AxLOOP
  rand bit [AXI5_POISON_W-1:0] poison[];        // WPOISON per beat (writes)
  // manager side timing (cycles of VALID being held low before the transfer)
  rand int unsigned            aw_delay;        // before AWVALID / ARVALID
  rand int unsigned            w_delay[];       // before every WVALID beat

  // response / observation
  axi5_resp_e  bresp;
  axi5_resp_e  rresp[];
  bit [AXI5_POISON_W-1:0] rpoison[];            // RPOISON per beat (reads)
  bit [AXI5_DATA_W-1:0]   adata[];              // atomic read data beats (original value)
  axi5_resp_e             aresp[];              // their RRESP
  bit [AXI5_POISON_W-1:0] apoison[];            // their RPOISON
  bit          error;                           // SLVERR or DECERR anywhere
  bit          aborted;                         // reset hit the burst
  time         start_time, end_time;            // address handshake / last response handshake
  int unsigned latency_cycles;
  bit          w_first_seen;                    // monitor: write data was accepted before the address
  bit          ooo;                             // monitor: the response overtook an older outstanding transaction
  int unsigned outstanding;                     // monitor: same-direction transactions outstanding when this one was issued
  int unsigned w_stalls;                        // monitor: cycles with WVALID && !WREADY (writes) / RVALID && !RREADY (reads) inside the burst

  `uvm_object_utils(axi5_item)

  constraint c_burst  { burst dist { AXI5_INCR := 70, AXI5_WRAP := 15, AXI5_FIXED := 15 }; }
  constraint c_size   { size <= AXI5_SIZE_MAX; size dist { AXI5_SIZE_MAX := 50, [0:AXI5_SIZE_MAX] :/ 50 }; }
  constraint c_len    {
    (burst == AXI5_FIXED) -> len inside {[0:15]};
    (burst == AXI5_WRAP)  -> len inside {1, 3, 7, 15};
    (burst == AXI5_INCR)  -> len dist { [0:15] :/ 80, [16:255] :/ 20 };
  }
  constraint c_wrap   { (burst == AXI5_WRAP) -> (addr & ((1 << size) - 1)) == 0; }
  constraint c_4kb    { (burst == AXI5_INCR) -> (int'(addr[11:0]) & ~((1 << size) - 1)) + (int'(len) + 1) * (1 << size) <= 4096; }
  constraint c_lock   {
    soft lock == 1'b0;
    lock -> { burst == AXI5_INCR; len <= 15; ((int'(len) + 1) * (1 << size)) inside {1, 2, 4, 8, 16, 32, 64, 128};
              (addr % ((int'(len) + 1) * (1 << size))) == 0; }
  }
  constraint c_arrays { data.size() == int'(len) + 1; strb.size() == int'(len) + 1; w_delay.size() == int'(len) + 1;
                        poison.size() == int'(len) + 1; }
  constraint c_axi5   { !write -> atop == 6'b0; soft atop == 6'b0; soft idunq == 1'b0; soft trace == 1'b0; soft loop == '0;
                        foreach (poison[i]) soft poison[i] == '0; }
  constraint c_delay  {
    aw_delay dist { 0 := 60, [1:4] := 30, [5:10] := 10 };
    foreach (w_delay[i]) w_delay[i] dist { 0 := 80, [1:3] := 20 };
  }
  constraint c_strb   {
    foreach (strb[i]) {
      write  -> (strb[i] & ~axi5_valid_lanes(addr, size, burst, len + 1, i)) == '0;
      !write -> strb[i] == '0;
    }
    solve write, addr, size, burst, len before strb;
  }
  constraint c_misc   { soft cache == 4'b0011; soft prot == 3'b000; soft qos == 4'd0; soft region == 4'd0; soft user == '0; }

  function new(string name = "axi5_item");
    super.new(name);
  endfunction

  function int unsigned beats();
    return int'(len) + 1;
  endfunction

  function axi5_atop_kind_e atop_kind();
    return axi5_atop_kind(atop);
  endfunction

  function bit is_atomic();
    return write && atop != 6'b0;
  endfunction

  function int unsigned total_bytes();
    return beats() * (1 << size);
  endfunction

  // address of beat i (IHI0022 A3.4.1)
  function bit [AXI5_ADDR_W-1:0] beat_addr(int unsigned i);
    return axi5_burst_addr(addr, size, burst, beats(), i);
  endfunction

  // byte lanes of the data bus that belong to beat i
  function bit [AXI5_STRB_W-1:0] valid_lanes(int unsigned i);
    if (is_atomic()) return axi5_atop_lanes(addr, size, burst, beats(), i);
    return axi5_valid_lanes(addr, size, burst, beats(), i);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axi5_item r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `vip_fatal("AXI5_ITEM", "do_copy: type mismatch")
    write = r.write; id = r.id; addr = r.addr; len = r.len; size = r.size; burst = r.burst; lock = r.lock; cache = r.cache;
    prot = r.prot; qos = r.qos; region = r.region; user = r.user; data = r.data; strb = r.strb; aw_delay = r.aw_delay; w_delay = r.w_delay;
    atop = r.atop; idunq = r.idunq; trace = r.trace; loop = r.loop; poison = r.poison; rpoison = r.rpoison;
    adata = r.adata; aresp = r.aresp; apoison = r.apoison;
    bresp = r.bresp; rresp = r.rresp; error = r.error; aborted = r.aborted; start_time = r.start_time; end_time = r.end_time;
    latency_cycles = r.latency_cycles; w_first_seen = r.w_first_seen; ooo = r.ooo; outstanding = r.outstanding; w_stalls = r.w_stalls;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    axi5_item r;
    if (!$cast(r, rhs)) return 0;
    return super.do_compare(rhs, comparer) && write == r.write && id == r.id && addr == r.addr && len == r.len && size == r.size &&
           burst == r.burst && lock == r.lock && data == r.data && strb == r.strb && bresp == r.bresp && rresp == r.rresp &&
           atop == r.atop && idunq == r.idunq && trace == r.trace && loop == r.loop && adata == r.adata;
  endfunction

  virtual function string convert2string();
    string s = $sformatf("%s id=%0h addr=0x%0h len=%0d size=%0d %s%s", write ? "WR" : "RD", id, addr, len, size, burst.name(), lock ? " LOCK" : "");
    if (atop != 0) s = {s, $sformatf(" %s(atop=%06b)", atop_kind().name(), atop)};
    if (idunq) s = {s, " IDUNQ"};
    if (trace) s = {s, " TRACE"};
    if (write) s = {s, $sformatf(" bresp=%s", bresp.name())};
    else if (rresp.size() != 0) s = {s, $sformatf(" rresp0=%s", rresp[0].name())};
    if (aborted) s = {s, " ABORTED"};
    foreach (data[i]) if (i < 4) s = {s, $sformatf(" d%0d=%0h", i, data[i])};
    return s;
  endfunction
endclass : axi5_item
