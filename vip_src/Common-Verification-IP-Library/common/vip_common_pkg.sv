// -----------------------------------------------------------------------------
// vip_common_pkg - utilities shared by all VIPs of this library
//
//   vip_sparse_mem      byte-addressable sparse memory used by the slave / device models
//   vip_expect_catcher  report catcher that turns *expected* errors of negative tests into
//                       counted infos (so that a negative test can still end with a clean log)
//   vip_role_e          role of a bus agent
//
// Everything is plain UVM 1.2 (IEEE 1800.2 compatible API); no simulator specific code.
// -----------------------------------------------------------------------------
`ifndef VIP_COMMON_PKG_SV
`define VIP_COMMON_PKG_SV

`include "uvm_macros.svh"
`include "vip_macros.svh"

package vip_common_pkg;
  import uvm_pkg::*;

  typedef enum bit [1:0] { VIP_MASTER, VIP_SLAVE, VIP_MONITOR } vip_role_e;

  // content of memory locations that were never written
  typedef enum bit [1:0] { MEM_INIT_ZERO, MEM_INIT_ONES, MEM_INIT_ADDR_HASH, MEM_INIT_FIXED } vip_mem_init_e;

  // ---------------------------------------------------------------------------
  // Sparse byte memory
  // ---------------------------------------------------------------------------
  class vip_sparse_mem;
    protected byte unsigned m_mem[longint unsigned];
    vip_mem_init_e init_mode  = MEM_INIT_ADDR_HASH;
    byte unsigned  init_value = 8'h00;           // MEM_INIT_FIXED

    function void clear();
      m_mem.delete();
    endfunction

    function int unsigned num_written();
      return m_mem.num();
    endfunction

    function bit is_written(longint unsigned addr);
      return m_mem.exists(addr);
    endfunction

    // value seen by a read of a location that has never been written
    function byte unsigned default_byte(longint unsigned addr);
      case (init_mode)
        MEM_INIT_ZERO:      return 8'h00;
        MEM_INIT_ONES:      return 8'hFF;
        MEM_INIT_FIXED:     return init_value;
        default:            return byte'((addr * 64'h9E37_79B9_7F4A_7C15) >> 56) ^ byte'(addr);
      endcase
    endfunction

    function byte unsigned read_byte(longint unsigned addr);
      return m_mem.exists(addr) ? m_mem[addr] : default_byte(addr);
    endfunction

    function void write_byte(longint unsigned addr, byte unsigned d);
      m_mem[addr] = d;
    endfunction

    // append the written addresses to q
    function void get_keys(ref longint unsigned q[$]);
      longint unsigned k;
      if (m_mem.first(k)) do q.push_back(k); while (m_mem.next(k));
    endfunction

    // forget the locations [addr, addr + nbytes): they read init_mode again (e.g. a flash erase with MEM_INIT_ONES)
    function void delete_range(longint unsigned addr, longint unsigned nbytes);
      longint unsigned k, lst[$];
      if (nbytes == 0) return;
      if (!m_mem.first(k)) return;
      do if (k >= addr && k - addr < nbytes) lst.push_back(k); while (m_mem.next(k));
      foreach (lst[i]) m_mem.delete(lst[i]);
    endfunction

    // little-endian word access, `nbytes` <= 128 (buses up to 1024 bits)
    function bit [1023:0] read_le(longint unsigned addr, int unsigned nbytes);
      bit [1023:0] r = '0;
      for (int unsigned i = 0; i < nbytes && i < 128; i++) r[8*i +: 8] = read_byte(addr + i);
      return r;
    endfunction

    // little-endian write with byte strobes (bit i of `strb` enables byte i)
    function void write_le(longint unsigned addr, bit [1023:0] data, int unsigned nbytes, bit [127:0] strb = '1);
      for (int unsigned i = 0; i < nbytes && i < 128; i++)
        if (strb[i]) m_mem[addr + i] = data[8*i +: 8];
    endfunction
  endclass : vip_sparse_mem

  // ---------------------------------------------------------------------------
  // Report catcher for negative tests
  //   add_expect("TAG", UVM_ERROR, 3) : UVM_ERRORs whose ID contains TAG or whose message contains "[TAG" are demoted
  //   to UVM_INFO (the VIP reports use ID = get_name() and start the message with "[TAG] ", see vip_macros.svh)
  //   at the end `check_all()` reports an error for every expectation that was not met
  // ---------------------------------------------------------------------------
  class vip_expect_catcher extends uvm_report_catcher;
    typedef struct { string id; uvm_severity sev; int unsigned min_count; int unsigned seen; } exp_t;
    protected exp_t m_exp[$];

    function new(string name = "vip_expect_catcher");
      super.new(name);
    endfunction

    static function bit has_substr(string s, string sub);
      for (int i = 0; i + sub.len() <= s.len(); i++) if (s.substr(i, i + sub.len() - 1) == sub) return 1;
      return 0;
    endfunction

    function void add_expect(string id, uvm_severity sev = UVM_ERROR, int unsigned min_count = 1);
      exp_t e;
      e.id = id; e.sev = sev; e.min_count = min_count; e.seen = 0;
      m_exp.push_back(e);
    endfunction

    virtual function action_e catch();
      foreach (m_exp[i]) begin
        if (get_severity() == m_exp[i].sev && (has_substr(get_id(), m_exp[i].id) || has_substr(get_message(), {"[", m_exp[i].id}))) begin
          m_exp[i].seen++;
          set_severity(UVM_INFO);
          set_message({"[expected] ", get_message()});
          return THROW;
        end
      end
      return THROW;
    endfunction

    function int unsigned seen(string id);
      foreach (m_exp[i]) if (m_exp[i].id == id) return m_exp[i].seen;
      return 0;
    endfunction

    // returns the number of unmet expectations (and reports them)
    function int unsigned check_all();
      int unsigned bad = 0;
      foreach (m_exp[i]) begin
        if (m_exp[i].seen < m_exp[i].min_count) begin
          bad++;
          `vip_error("EXPECT", $sformatf("expected at least %0d '%s' %s report(s), saw %0d",
                     m_exp[i].min_count, m_exp[i].id, m_exp[i].sev.name(), m_exp[i].seen))
        end
      end
      return bad;
    endfunction

    function void install();
      uvm_report_cb::add(null, this);
    endfunction
  endclass : vip_expect_catcher

  // ---------------------------------------------------------------------------
  // Checker attribution for negative tests: every protocol interface counts its violations per ID (viol_by_id).
  //   vip_viol_check(target, prev, cur, allowed) returns "" when `target` fired at least once between the two
  //   snapshots and no other ID (except those in `allowed`) did; target "" means "nothing may fire".
  // ---------------------------------------------------------------------------
  typedef int unsigned vip_viol_map_t [string];

  function automatic string vip_viol_check(string target, vip_viol_map_t prev, vip_viol_map_t cur, string allowed[$] = {});
    string msg = "";
    foreach (cur[id]) begin
      int unsigned d = cur[id] - (prev.exists(id) ? prev[id] : 0);
      bit ok_id = (id == target);
      foreach (allowed[i]) if (allowed[i] == id) ok_id = 1;
      if (d != 0 && !ok_id) msg = {msg, $sformatf(" unexpected %s x%0d;", id, d)};
    end
    if (target != "" && (!cur.exists(target) || cur[target] <= (prev.exists(target) ? prev[target] : 0)))
      msg = {msg, $sformatf(" %s did not fire;", target)};
    return msg;
  endfunction

endpackage : vip_common_pkg

`endif
