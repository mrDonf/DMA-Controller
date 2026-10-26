# Verification IPs used by the UVM test bench

The UVM test bench (`tb/uvm`) uses three AMBA verification IPs. They come from the author's
[Common-Verification-IP-Library](https://github.com/mrDonf/Common-Verification-IP-Library); only the parts that this
test bench compiles are included here (the full library also has AHB, AXI4, UART, SPI, I2C and QSPI VIPs).

```
vip_src/Common-Verification-IP-Library/
├── common/       vip_common_pkg.sv, vip_macros.svh, vip_clk_rst_if.sv   shared package (sparse memory, roles, checkers)
├── apb/src/      APB4 VIP     – drives the DMA register interface (requester role)
├── axi5/src/     AXI5 VIP     – subordinate models of the two AXI5 manager ports M0 / M1 with a shared memory
├── axi4s/src/    AXI4-Stream VIP – stream-out receiver and stream-in transmitter
└── docs/         user guides of these VIPs and the integration guide
```

| VIP | Role in the test bench | Guide |
|---|---|---|
| `apb` | master agent of the DMA programming port | [apb_vip.md](Common-Verification-IP-Library/docs/apb_vip.md) |
| `axi5` | slave agents on M0 and M1 (error / poison injection, timing knobs, memory) | [axi5_vip.md](Common-Verification-IP-Library/docs/axi5_vip.md) |
| `axi4s` | stream-out slave and stream-in master for the stream channels | [axi4s_vip.md](Common-Verification-IP-Library/docs/axi4s_vip.md) |

The compile order is in `scripts/run_sim.py` (`tb_files()`); the integration steps that apply to every VIP are in
[integration_guide.md](Common-Verification-IP-Library/docs/integration_guide.md).

`docs/axi4_vip.md` is included only because the AXI5 guide builds on it; the AXI4 VIP sources are not part of this
repository.

## Local addition

The AXI5 VIP configuration `axi5_agent_cfg` has three extra, backward-compatible fields used by the performance tests:
`r_gap_sep`, `r_gap_min` and `r_gap_max`. When `r_gap_sep` is set, the gap between R beats is controlled separately from
the first-beat latency (default off, VIP behaviour unchanged).
