// -----------------------------------------------------------------------------
// AXI5 sequence library
//   axi5_base_seq         helpers: xfer(item), write_word(), read_word(), read_bytes(), write_bytes(), make_atomic(), atomic()
//   axi5_api_seq          stays alive: helpers from any thread of a test
//   axi5_single_seq       n x single-beat write + read-back
//   axi5_wr_rd_seq        n x random burst (all types / sizes / lengths) written and read back, compared
//   axi5_outstanding_seq  queues many bursts before collecting any response (outstanding transactions), then reads them back
//   axi5_ooo_seq          reads with different IDs issued back to back (out-of-order / interleaved when the subordinate does so)
//   axi5_narrow_seq       byte / halfword / unaligned INCR writes into one word, read back
//   axi5_long_seq         256-beat INCR bursts
//   axi5_excl_seq         exclusive read + write (success), exclusive write after a conflicting write (failure)
//   axi5_error_seq        accesses to the erroring window (SLVERR) and outside the mapped window (DECERR)
//   axi5_mixed_seq        n random bursts: reads and writes on separate regions at the same time (reads of the low half only)
//   axi5_atomic_seq       random atomics (every type / operation / size / endianness) with a shadow copy of the region
//   axi5_poison_seq       WPOISON / RPOISON round trip, partial write keeps, full write clears the poison
//   axi5_unique_seq       outstanding reads / writes with distinct IDs and AxIDUNQ, random TRACE / LOOP
// -----------------------------------------------------------------------------
class axi5_base_seq extends uvm_sequence #(axi5_item);
  `uvm_object_utils(axi5_base_seq)

  int unsigned n_mismatch;

  function new(string name = "axi5_base_seq");
    super.new(name);
    set_response_queue_depth(-1);
  endfunction

  task xfer(axi5_item it);
    axi5_item r;
    start_item(it);
    finish_item(it);
    get_response(r);
    it.data = r.data; it.rresp = r.rresp; it.bresp = r.bresp; it.error = r.error; it.aborted = r.aborted;
    it.rpoison = r.rpoison; it.adata = r.adata; it.aresp = r.aresp; it.apoison = r.apoison;
  endtask

  // ---------------------------------------------------------------- AXI5 atomics
  // builds an atomic transaction following the atomic rules: AWADDR = operand address, write data = operand
  // (AtomicCompare: compare value at AWADDR, swap value in the other half of the 2n-byte window), AWSIZE / AWLEN from
  // the total size, INCR (AtomicCompare to the upper half: WRAP), strobes = the whole window
  function axi5_item make_atomic(bit [5:0] atop, bit [AXI5_ADDR_W-1:0] a, byte unsigned opnd[$], byte unsigned swp[$],
                                 bit [AXI5_ID_W-1:0] id = 0, bit [AXI5_POISON_W-1:0] pz = '0);
    axi5_item it = axi5_item::type_id::create("atomic");
    axi5_atop_kind_e k = axi5_atop_kind(atop);
    int unsigned n = opnd.size();
    int unsigned total = (k == AXI5_ATOP_COMPARE) ? 2 * n : n;
    bit [AXI5_ADDR_W-1:0] w0 = axi5_atop_base(a, total);
    bit [AXI5_ADDR_W-1:0] sw = (a == w0) ? w0 + n : w0;
    byte unsigned win[];
    if (!it.randomize() with { write == 1; len == 0; size == 0; burst == AXI5_INCR; lock == 0; id == local::id; })
      `vip_fatal("AXI5_SEQ", "randomize failed")
    it.atop = atop; it.addr = a;
    if (total <= AXI5_STRB_W) begin it.size = $clog2(total); it.len = 0; end
    else begin it.size = AXI5_SIZE_MAX; it.len = total / AXI5_STRB_W - 1; end
    it.burst = (k == AXI5_ATOP_COMPARE && a != w0) ? AXI5_WRAP : AXI5_INCR;
    win = new[total];
    for (int i = 0; i < n; i++) begin
      win[a - w0 + i] = opnd[i];
      if (k == AXI5_ATOP_COMPARE) win[sw - w0 + i] = (i < swp.size()) ? swp[i] : 8'h00;
    end
    it.data = new[it.beats()]; it.strb = new[it.beats()]; it.w_delay = new[it.beats()]; it.poison = new[it.beats()];
    for (int b = 0; b < it.beats(); b++) begin
      bit [AXI5_ADDR_W-1:0] ba = (it.beats() == 1) ? w0 - (w0 % AXI5_STRB_W) : it.beat_addr(b) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
      it.data[b] = '0; it.strb[b] = '0; it.w_delay[b] = 0; it.poison[b] = pz;
      for (int l = 0; l < AXI5_STRB_W; l++)
        if (longint'(ba) + l >= longint'(w0) && longint'(ba) + l < longint'(w0) + total) begin
          it.data[b][8*l +: 8] = win[ba + l - w0];
          it.strb[b][l] = 1'b1;
        end
    end
    return it;
  endfunction

  // original value (n bytes at AWADDR) from the read data of an atomic
  function void atomic_orig(axi5_item it, ref byte unsigned orig[$]);
    int unsigned rb = axi5_atop_rbeats(it.atop, it.size, it.len);
    int unsigned n  = axi5_atop_rbytes(it.atop, it.size, it.len);
    bit [2:0] rsz = axi5_atop_rsize(it.atop, it.size, it.len);
    orig.delete(); repeat (n) orig.push_back(8'h00);
    for (int j = 0; j < rb && j < it.adata.size(); j++) begin
      longint unsigned ba = longint'(axi5_burst_addr(it.addr, rsz, AXI5_INCR, rb, j));
      ba = ba - (ba % AXI5_STRB_W);
      for (int l = 0; l < AXI5_STRB_W; l++)
        if (ba + l >= longint'(it.addr) && ba + l < longint'(it.addr) + n) orig[ba + l - longint'(it.addr)] = it.adata[j][8*l +: 8];
    end
  endfunction

  // one atomic: returns the original value (Load / Swap / Compare) and the worst response
  task atomic(bit [5:0] atop, bit [AXI5_ADDR_W-1:0] a, byte unsigned opnd[$], byte unsigned swp[$],
              output byte unsigned orig[$], output axi5_resp_e resp, input bit [AXI5_ID_W-1:0] id = 0, bit [AXI5_POISON_W-1:0] pz = '0);
    axi5_item it = make_atomic(atop, a, opnd, swp, id, pz);
    xfer(it);
    resp = it.bresp;
    foreach (it.aresp[i]) if (it.aresp[i] > resp) resp = it.aresp[i];
    orig.delete();
    if (axi5_atop_has_rdata(atop)) atomic_orig(it, orig);
  endtask

  // byte access helpers (full-width beats around the bytes)
  task read_bytes(bit [AXI5_ADDR_W-1:0] a, int unsigned n, output byte unsigned b[$]);
    b.delete();
    for (bit [AXI5_ADDR_W-1:0] w = a & ~AXI5_ADDR_W'(AXI5_STRB_W - 1); w < a + n; w += AXI5_STRB_W) begin
      bit [AXI5_DATA_W-1:0] d; bit e;
      read_word(w, d, e);
      for (int l = 0; l < AXI5_STRB_W; l++) if (w + l >= a && w + l < a + n) b.push_back(d[8*l +: 8]);
    end
  endtask

  task write_bytes(bit [AXI5_ADDR_W-1:0] a, byte unsigned b[$]);
    foreach (b[i]) begin
      axi5_item it = axi5_item::type_id::create("wb");
      if (!it.randomize() with { write == 1; len == 0; size == 0; burst == AXI5_INCR; lock == 0; addr == a + i; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      it.data[0] = '0; it.data[0][8 * ((a + i) % AXI5_STRB_W) +: 8] = b[i];
      it.strb[0] = '0; it.strb[0][(a + i) % AXI5_STRB_W] = 1'b1;
      xfer(it);
    end
  endtask

  // single beat of the full bus width
  task write_word(bit [AXI5_ADDR_W-1:0] a, bit [AXI5_DATA_W-1:0] d, output bit err, input bit [AXI5_ID_W-1:0] id = 0);
    axi5_item it = axi5_item::type_id::create("wr");
    if (!it.randomize() with { write == 1; addr == a; len == 0; size == AXI5_SIZE_MAX; id == local::id; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    it.data[0] = d; it.strb[0] = it.valid_lanes(0);              // an unaligned address leaves out the lanes below it
    xfer(it);
    err = it.error;
  endtask

  task read_word(bit [AXI5_ADDR_W-1:0] a, output bit [AXI5_DATA_W-1:0] d, output bit err, input bit [AXI5_ID_W-1:0] id = 0);
    axi5_item it = axi5_item::type_id::create("rd");
    if (!it.randomize() with { write == 0; addr == a; len == 0; size == AXI5_SIZE_MAX; id == local::id; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(it);
    d = it.data[0]; err = it.error;
  endtask

  // compare the lanes that belong to each beat of a write burst with the data read back (a FIXED burst rewrites the same
  // location: the value that survives is the one of the last beat that enabled the lane)
  function void compare(axi5_item w, axi5_item r);
    bit [AXI5_DATA_W-1:0] fin;
    bit [AXI5_STRB_W-1:0] fin_v = '0;
    if (w.burst == AXI5_FIXED)
      for (int i = 0; i < w.beats(); i++)
        for (int l = 0; l < AXI5_STRB_W; l++) if (w.valid_lanes(i)[l] && w.strb[i][l]) begin fin[8*l +: 8] = w.data[i][8*l +: 8]; fin_v[l] = 1'b1; end
    for (int i = 0; i < w.beats(); i++) begin
      bit [AXI5_STRB_W-1:0] lanes = w.valid_lanes(i);
      for (int l = 0; l < AXI5_STRB_W; l++) begin
        bit chk = (w.burst == AXI5_FIXED) ? (lanes[l] && fin_v[l]) : (lanes[l] && w.strb[i][l]);
        bit [7:0] expd = (w.burst == AXI5_FIXED) ? fin[8*l +: 8] : w.data[i][8*l +: 8];
        if (chk && expd !== r.data[i][8*l +: 8]) begin
          n_mismatch++;
          `vip_error("AXI5_SEQ_MISMATCH", $sformatf("%s id=%0h addr=0x%0h len=%0d size=%0d beat %0d lane %0d: expected 0x%0h read 0x%0h", w.burst.name(), w.id, w.addr, w.len, w.size, i, l, expd, r.data[i][8*l +: 8]))
          return;
        end
      end
    end
  endfunction
endclass : axi5_base_seq

// stays alive; tests call the helpers (xfer / atomic / read_bytes ...) from any thread
class axi5_api_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_api_seq)
  bit stop;
  function new(string name = "axi5_api_seq"); super.new(name); endfunction
  task body(); wait (stop); endtask
endclass : axi5_api_seq

class axi5_single_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_single_seq)
  rand int unsigned n = 20;
  rand bit [AXI5_ADDR_W-1:0] lo = 0;
  rand bit [AXI5_ADDR_W-1:0] hi = 'hFFF;
  constraint c_n { n inside {[1:1000]}; lo <= hi; }
  function new(string name = "axi5_single_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      bit [AXI5_ADDR_W-1:0] a = (lo + ($urandom % (hi - lo + 1))) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
      bit [AXI5_DATA_W-1:0] d = {(AXI5_DATA_W / 32 + 1){$urandom}}, q;
      bit e;
      write_word(a, d, e, $urandom);
      read_word(a, q, e, $urandom);
      if (!e && q !== d) begin
        n_mismatch++;
        `vip_error("AXI5_SEQ_MISMATCH", $sformatf("addr 0x%0h wrote 0x%0h read 0x%0h", a, d, q))
      end
    end
  endtask
endclass : axi5_single_seq

class axi5_wr_rd_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_wr_rd_seq)
  rand int unsigned n = 20;
  bit [AXI5_ID_W-1:0] id_lo = 0, id_hi = '1;                 // ID range (keep it apart from concurrently running atomics)
  rand bit [AXI5_ADDR_W-1:0] lo = 0;
  rand bit [AXI5_ADDR_W-1:0] hi = 'hFFFF;
  bit allow_lock = 0;
  constraint c_n { n inside {[1:1000]}; lo <= hi; }
  function new(string name = "axi5_wr_rd_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axi5_item w = axi5_item::type_id::create("w");
      axi5_item r = axi5_item::type_id::create("r");
      if (!w.randomize() with { write == 1; addr >= lo; 72'(addr) + (int'(len) + 1) * (1 << size) <= 72'(hi) + 1; lock == 0; id inside {[id_lo:id_hi]}; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      xfer(w);
      if (!r.randomize() with { write == 0; addr == w.addr; len == w.len; size == w.size; burst == w.burst; lock == 0; id == w.id; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      xfer(r);
      if (!w.error && !r.error) compare(w, r);
    end
  endtask
endclass : axi5_wr_rd_seq

class axi5_outstanding_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_outstanding_seq)
  rand int unsigned n = 16;
  rand bit [AXI5_ADDR_W-1:0] base;
  constraint c_n { n inside {[2:64]}; }
  function new(string name = "axi5_outstanding_seq"); super.new(name); endfunction
  task body();
    axi5_item q[$];
    axi5_item r;
    for (int i = 0; i < n; i++) begin                     // all writes queued first: up to max_wr_outstanding are in flight
      axi5_item w = axi5_item::type_id::create($sformatf("w%0d", i));
      start_item(w);
      if (!w.randomize() with { write == 1; lock == 0; 72'(addr) >= 72'(base) + i * 'h200; 72'(addr) + (int'(len) + 1) * (1 << size) <= 72'(base) + (i + 1) * 'h200;
                                id == i % (4 < 2 ** AXI5_ID_W ? 4 : 2 ** AXI5_ID_W); }) `vip_fatal("AXI5_SEQ", "randomize failed")
      finish_item(w);
      q.push_back(w);
    end
    foreach (q[i]) begin get_response(r, q[i].get_transaction_id()); q[i].error = r.error; q[i].bresp = r.bresp; end
    // read everything back, all queued before the first response is collected
    begin
      axi5_item rq[$];
      foreach (q[i]) begin
        axi5_item rd = axi5_item::type_id::create($sformatf("r%0d", i));
        start_item(rd);
        if (!rd.randomize() with { write == 0; lock == 0; addr == q[i].addr; len == q[i].len; size == q[i].size; burst == q[i].burst; id == q[i].id; })
          `vip_fatal("AXI5_SEQ", "randomize failed")
        finish_item(rd);
        rq.push_back(rd);
      end
      foreach (rq[i]) begin
        get_response(r, rq[i].get_transaction_id());
        rq[i].data = r.data; rq[i].rresp = r.rresp; rq[i].error = r.error;
      end
      foreach (q[i]) if (!q[i].error && !rq[i].error) compare(q[i], rq[i]);
    end
  endtask
endclass : axi5_outstanding_seq

class axi5_ooo_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_ooo_seq)
  rand int unsigned n = 12;
  rand bit [AXI5_ADDR_W-1:0] base;
  constraint c_n { n inside {[2:32]}; }
  function new(string name = "axi5_ooo_seq"); super.new(name); endfunction
  task body();
    axi5_item q[$];
    axi5_item r;
    // fill the area first, then read with different IDs
    for (int i = 0; i < n; i++) begin
      bit [AXI5_DATA_W-1:0] d = {(AXI5_DATA_W / 32 + 1){$urandom}};
      bit e;
      write_word(base + i * AXI5_STRB_W, d, e);
    end
    for (int i = 0; i < n; i++) begin
      axi5_item rd = axi5_item::type_id::create($sformatf("r%0d", i));
      start_item(rd);
      if (!rd.randomize() with { write == 0; lock == 0; addr == base + i * AXI5_STRB_W; len == 3; size == AXI5_SIZE_MAX; burst == AXI5_INCR; id == i % (8 < 2 ** AXI5_ID_W ? 8 : 2 ** AXI5_ID_W);
                                 aw_delay == 0; (addr[11:0] + 4 * AXI5_STRB_W) <= 4096; })
        `vip_fatal("AXI5_SEQ", "randomize failed")
      finish_item(rd);
      q.push_back(rd);
    end
    foreach (q[i]) get_response(r, q[i].get_transaction_id());
  endtask
endclass : axi5_ooo_seq

class axi5_narrow_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_narrow_seq)
  rand bit [AXI5_ADDR_W-1:0] addr;
  function new(string name = "axi5_narrow_seq"); super.new(name); endfunction
  task body();
    bit [AXI5_DATA_W-1:0] q;
    bit e;
    write_word(addr, '0, e);
    for (int sz = 0; sz < AXI5_SIZE_MAX; sz++) begin
      for (int pos = 0; pos < AXI5_STRB_W; pos += (1 << sz)) begin
        axi5_item w = axi5_item::type_id::create("w");
        axi5_item r = axi5_item::type_id::create("r");
        if (!w.randomize() with { write == 1; addr == local::addr + pos; len == 0; size == sz; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
        xfer(w);
        if (!r.randomize() with { write == 0; addr == w.addr; len == 0; size == sz; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
        xfer(r);
        compare(w, r);
      end
    end
    // unaligned start address of an INCR burst: the first beat only uses the upper lanes of its window
    begin
      axi5_item w = axi5_item::type_id::create("w");
      axi5_item r = axi5_item::type_id::create("r");
      if (!w.randomize() with { write == 1; addr == local::addr + 1; len == 3; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      xfer(w);
      if (!r.randomize() with { write == 0; addr == w.addr; len == 3; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      xfer(r);
      compare(w, r);
    end
  endtask
endclass : axi5_narrow_seq

class axi5_long_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_long_seq)
  localparam int LONG_LEN = ((4096 / AXI5_STRB_W) > 256) ? 255 : (4096 / AXI5_STRB_W) - 1;   // longest full-width burst inside 4KB
  rand bit [AXI5_ADDR_W-1:0] base;
  function new(string name = "axi5_long_seq"); super.new(name); endfunction
  task body();
    axi5_item w = axi5_item::type_id::create("w");
    axi5_item r = axi5_item::type_id::create("r");
    if (!w.randomize() with { write == 1; len == LONG_LEN; burst == AXI5_INCR; size == AXI5_SIZE_MAX; lock == 0; addr == (local::base & ~AXI5_ADDR_W'('hFFF)); }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(w);
    if (!r.randomize() with { write == 0; len == LONG_LEN; burst == AXI5_INCR; size == AXI5_SIZE_MAX; lock == 0; addr == w.addr; id == w.id; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(r);
    if (!w.error && !r.error) compare(w, r);
  endtask
endclass : axi5_long_seq

class axi5_excl_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_excl_seq)
  rand bit [AXI5_ADDR_W-1:0] addr;
  int unsigned n_exokay;
  function new(string name = "axi5_excl_seq"); super.new(name); endfunction

  task excl_pair(bit [AXI5_ADDR_W-1:0] a, bit [AXI5_ID_W-1:0] id, bit conflict, output axi5_resp_e wresp);
    axi5_item rd = axi5_item::type_id::create("xr");
    axi5_item wr = axi5_item::type_id::create("xw");
    bit e;
    if (!rd.randomize() with { write == 0; addr == a; len == 0; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 1; id == local::id; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(rd);
    if (rd.rresp[0] != AXI5_EXOKAY) `vip_error("AXI5_SEQ_EXCL", $sformatf("exclusive read answered %s", rd.rresp[0].name()))
    if (conflict) write_word(a, AXI5_DATA_W'(32'hC0FFEE00), e, 0);        // another master writes the location
    if (!wr.randomize() with { write == 1; addr == a; len == 0; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 1; id == local::id; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(wr);
    wresp = wr.bresp;
  endtask

  task body();
    axi5_resp_e rs;
    excl_pair(addr, 5, 0, rs);
    if (rs != AXI5_EXOKAY) `vip_error("AXI5_SEQ_EXCL", $sformatf("exclusive write without conflict answered %s, expected EXOKAY", rs.name())) else n_exokay++;
    excl_pair(addr + 'h40, 6, 1, rs);
    if (rs != AXI5_OKAY) `vip_error("AXI5_SEQ_EXCL", $sformatf("exclusive write after a conflicting write answered %s, expected OKAY (failed)", rs.name()))
    // the failed exclusive write must not have changed the memory
    begin
      bit [AXI5_DATA_W-1:0] q; bit e;
      read_word(addr + 'h40, q, e);
      if (!e && q !== AXI5_DATA_W'(32'hC0FFEE00)) `vip_error("AXI5_SEQ_EXCL", $sformatf("failed exclusive write modified memory (0x%0h)", q))
    end
  endtask
endclass : axi5_excl_seq

class axi5_error_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_error_seq)
  bit [AXI5_ADDR_W-1:0] slverr_addr;
  bit [AXI5_ADDR_W-1:0] decerr_addr;
  bit [AXI5_ADDR_W-1:0] ok_addr;
  function new(string name = "axi5_error_seq"); super.new(name); endfunction
  task body();
    axi5_item w = axi5_item::type_id::create("w");
    axi5_item r = axi5_item::type_id::create("r");
    bit [AXI5_DATA_W-1:0] d;
    bit e;
    write_word(slverr_addr, 32'h1, e);   if (!e) `vip_error("AXI5_SEQ_ERR", "write into the SLVERR window reported no error")
    read_word(slverr_addr, d, e);        if (!e) `vip_error("AXI5_SEQ_ERR", "read from the SLVERR window reported no error")
    write_word(decerr_addr, 32'h1, e);   if (!e) `vip_error("AXI5_SEQ_ERR", "write outside the mapped window reported no error")
    read_word(decerr_addr, d, e);        if (!e) `vip_error("AXI5_SEQ_ERR", "read outside the mapped window reported no error")
    if (!w.randomize() with { write == 1; addr == slverr_addr - 'h10; len == 7; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(w);                                                       // burst running into the window: the error applies to the whole burst
    if (!w.error) `vip_error("AXI5_SEQ_ERR", "burst touching the SLVERR window reported no error")
    write_word(ok_addr, AXI5_DATA_W'(32'hA5A5_5A5A), e); if (e) `vip_error("AXI5_SEQ_ERR", "unexpected error on a normal address")
    read_word(ok_addr, d, e);              if (e || d !== AXI5_DATA_W'(32'hA5A5_5A5A)) `vip_error("AXI5_SEQ_ERR", "read-back after error accesses is wrong")
  endtask
endclass : axi5_error_seq

class axi5_mixed_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_mixed_seq)
  rand int unsigned n = 60;
  constraint c_n { n inside {[2:500]}; }
  function new(string name = "axi5_mixed_seq"); super.new(name); endfunction
  // writes go to [0x1_0000, 0x1_FFFF] and are never read here; reads go to [0, 0xFFFF], which was initialised by the caller
  task body();
    axi5_item q[$];
    axi5_item r;
    for (int i = 0; i < n; i++) begin
      axi5_item it = axi5_item::type_id::create($sformatf("m%0d", i));
      start_item(it);
      if ($urandom_range(1)) begin
        if (!it.randomize() with { write == 1; lock == 0; addr >= 'h10000; 72'(addr) + (int'(len) + 1) * (1 << size) <= 'h20000; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      end else begin
        if (!it.randomize() with { write == 0; lock == 0; 72'(addr) + (int'(len) + 1) * (1 << size) <= 'h10000; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      end
      finish_item(it);
      q.push_back(it);
    end
    foreach (q[i]) get_response(r, q[i].get_transaction_id());
  endtask
endclass : axi5_mixed_seq

// ================================================================ AXI5 extensions
// random atomics inside [base, base + 0x100) with a shadow copy of the region (read first): every returned original
// value and the final contents are compared
class axi5_atomic_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_atomic_seq)
  rand int unsigned n = 40;
  bit [AXI5_ADDR_W-1:0] base = 'h6000;
  bit [AXI5_ID_W-1:0] id_lo = 0, id_hi = '1;                 // ID range (an atomic must not share the ID of outstanding traffic)
  constraint c_n { n inside {[1:2000]}; }
  function new(string name = "axi5_atomic_seq"); super.new(name); endfunction

  function bit [5:0] rand_atop(output int unsigned nb);
    int unsigned k = $urandom_range(3);
    int unsigned sz[4] = '{1, 2, 4, 8};
    nb = sz[$urandom_range(3)];
    case (k)
      0: return {2'b01, 1'($urandom), 3'($urandom)};                 // AtomicStore
      1: return {2'b10, 1'($urandom), 3'($urandom)};                 // AtomicLoad
      2: return 6'b110000;                                           // AtomicSwap
      default: begin nb = 1 << $urandom_range(0, 4); if (nb > 16) nb = 16; return 6'b110001; end   // operand 1..16
    endcase
  endfunction

  task body();
    byte unsigned shadow[$];
    read_bytes(base, 'h100, shadow);
    repeat (n) begin
      int unsigned nb;
      bit [5:0] t = rand_atop(nb);
      axi5_atop_kind_e k = axi5_atop_kind(t);
      int unsigned total = (k == AXI5_ATOP_COMPARE) ? 2 * nb : nb;
      bit [AXI5_ADDR_W-1:0] a = base + ($urandom_range(0, 'h100 / total - 1) * total) + (((k == AXI5_ATOP_COMPARE) && $urandom_range(1)) ? nb : 0);
      byte unsigned op[$], sw[$], orig[$], exp_o[$], res[$];
      axi5_resp_e rs;
      for (int i = 0; i < nb; i++) begin exp_o.push_back(shadow[a - base + i]); op.push_back($urandom); sw.push_back($urandom); end
      if (k == AXI5_ATOP_COMPARE && $urandom_range(1)) op = exp_o;           // half of the compares match
      if (k != AXI5_ATOP_COMPARE) sw.delete();
      atomic(t, a, op, sw, orig, rs, $urandom_range(id_lo, id_hi));
      if (rs != AXI5_OKAY) begin
        `vip_error("AXI5_SEQ_ATOMIC", $sformatf("atomic %s answered %s", k.name(), rs.name()))
        continue;
      end
      if (axi5_atop_has_rdata(t) && orig != exp_o) begin
        n_mismatch++;
        `vip_error("AXI5_SEQ_ATOMIC", $sformatf("atomic %s @0x%0h: wrong original value", k.name(), a))
      end
      axi5_atomic_result(t, exp_o, op, sw, res);
      foreach (res[i]) shadow[a - base + i] = res[i];
    end
    begin
      byte unsigned fin[$];
      read_bytes(base, 'h100, fin);
      if (fin != shadow) begin n_mismatch++; `vip_error("AXI5_SEQ_ATOMIC", "memory after the atomics differs from the shadow copy") end
    end
  endtask
endclass : axi5_atomic_seq

// poison: written poison is returned, a partial non-poisoned write keeps it, a full write of the chunk clears it
class axi5_poison_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_poison_seq)
  bit [AXI5_ADDR_W-1:0] base = 'h7000;
  function new(string name = "axi5_poison_seq"); super.new(name); endfunction
  task rd(bit [AXI5_ADDR_W-1:0] a, int unsigned beats, output axi5_item r);
    r = axi5_item::type_id::create("prd");
    if (!r.randomize() with { write == 0; addr == a; len == local::beats - 1; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 0; })
      `vip_fatal("AXI5_SEQ", "randomize failed")
    xfer(r);
  endtask
  task body();
    axi5_item w = axi5_item::type_id::create("pwr"), r;
    if (!w.randomize() with { write == 1; addr == base; len == 7; size == AXI5_SIZE_MAX; burst == AXI5_INCR; lock == 0;
                              foreach (strb[i]) strb[i] == '1; }) `vip_fatal("AXI5_SEQ", "randomize failed")
    foreach (w.poison[i]) w.poison[i] = (i % 2) ? '1 : '0;          // odd beats poisoned
    xfer(w);
    rd(base, 8, r);
    foreach (r.rpoison[i]) if (r.rpoison[i] !== ((i % 2) ? {AXI5_POISON_W{1'b1}} : '0))
      `vip_error("AXI5_SEQ_POISON", $sformatf("beat %0d: RPOISON=%0b", i, r.rpoison[i]))
    // partial non-poisoned write of beat 1 keeps the poison, a full write of beat 3 clears it
    begin
      axi5_item p = axi5_item::type_id::create("ppart");
      bit e;
      if (!p.randomize() with { write == 1; addr == base + AXI5_STRB_W; len == 0; size == 0; burst == AXI5_INCR; lock == 0; }) `vip_fatal("AXI5_SEQ", "randomize failed")
      p.strb[0] = 1; p.poison[0] = '0;
      xfer(p);
      write_word(base + 3 * AXI5_STRB_W, '1, e);
    end
    rd(base, 4, r);
    if (r.rpoison[1] !== '1) `vip_error("AXI5_SEQ_POISON", "a partial write cleared the poison")
    if (r.rpoison[3] !== '0) `vip_error("AXI5_SEQ_POISON", "a full write did not clear the poison")
  endtask
endclass : axi5_poison_seq

// many reads / writes outstanding, every one with a different ID and AxIDUNQ = 1, random TRACE / LOOP
class axi5_unique_seq extends axi5_base_seq;
  `uvm_object_utils(axi5_unique_seq)
  bit [AXI5_ADDR_W-1:0] base = 'h8000;
  function new(string name = "axi5_unique_seq"); super.new(name); endfunction
  task body();
    axi5_item q[$], r;
    int unsigned nid = (2 ** AXI5_ID_W > 8) ? 8 : 2 ** AXI5_ID_W;
    for (int dir = 1; dir >= 0; dir--) begin
      q.delete();
      for (int i = 0; i < nid; i++) begin
        axi5_item it = axi5_item::type_id::create($sformatf("u%0d", i));
        start_item(it);
        if (!it.randomize() with { write == local::dir; lock == 0; id == i; idunq == 1; trace dist {0 := 1, 1 := 1};
                                   72'(addr) >= 72'(base) + i * 'h100; 72'(addr) + (int'(len) + 1) * (1 << size) <= 72'(base) + (i + 1) * 'h100; })
          `vip_fatal("AXI5_SEQ", "randomize failed")
        it.loop = $urandom; it.trace = $urandom_range(1);       // set after randomize(): the item has soft defaults of 0
        finish_item(it);
        q.push_back(it);
      end
      foreach (q[i]) get_response(r, q[i].get_transaction_id());
    end
  endtask
endclass : axi5_unique_seq
