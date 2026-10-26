// -----------------------------------------------------------------------------
// vip_macros.svh - reporting macros of the VIP library
//
//   The report ID is always get_name() of the object / component that reports, so that messages are attributed to the
//   instance that produced them in any project (two agents of the same VIP report as "mst"/"slv", "a"/"b", ... and the
//   UVM header still shows the full hierarchical path). The message starts with a short tag in brackets, e.g.
//   "[TIMEOUT] PREADY not seen ...", that tests and report catchers can filter on (vip_expect_catcher matches the tag
//   in the ID or in the message).
//
//   `vip_info(TAG, MSG, VERBOSITY)   `vip_warning(TAG, MSG)   `vip_error(TAG, MSG)   `vip_fatal(TAG, MSG)
// -----------------------------------------------------------------------------
`ifndef VIP_MACROS_SVH
`define VIP_MACROS_SVH

`include "uvm_macros.svh"

`define vip_info(TAG, MSG, VERB)  `uvm_info(get_name(), {"[", TAG, "] ", MSG}, VERB)
`define vip_warning(TAG, MSG)     `uvm_warning(get_name(), {"[", TAG, "] ", MSG})
`define vip_error(TAG, MSG)       `uvm_error(get_name(), {"[", TAG, "] ", MSG})
`define vip_fatal(TAG, MSG)       `uvm_fatal(get_name(), {"[", TAG, "] ", MSG})

`endif
