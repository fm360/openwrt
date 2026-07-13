# Google Wifi Gale / IPQ4019 routing acceleration analysis

## Conclusion

The stock Gale image does not use an NSS, ECM, or PPE hardware NAT/routing
engine. Its routed-flow accelerator is Qualcomm Shortcut Forwarding Engine
(SFE), a software fast path running on the four Cortex-A7 CPUs. Hardware helps
around that fast path through the ESS switch and EDMA controller:

- L2 switching, VLAN handling, and port forwarding in the ESS switch
- EDMA descriptor processing, four receive/transmit netdev queues, RSS,
  checksum offload, VLAN offload, scatter/gather, TSO, and GRO
- Deliberate IRQ, RSS, RPS, RFS, and XPS placement across the CPUs

The maintained OpenWrt replacement for the SFE routed fast path is nftables
`nf_flow_table` software offload. Setting `flow_offloading_hw=1` does not add
hardware NAT on IPQ4019 because this tree has no IPQ4019 flow-offload driver
callback.

## Evidence and provenance

The main authorities for this port are the exact Gale firmware artifacts:

- OEM kernel input `vmlinux_raw.bin`, SHA-256
  `4ac3518ecdbcf4ca28b347f85915c0eb8a93da490ecc202ffa551bf859e640a9`
- reconstructed kernel ELF, SHA-256
  `c49ff06f427d3c323ea1ae5471f74d29eae7f9c6d73c14e16df0048ce2a1bae1`
- unstripped OEM `essedma.ko`, SHA-256
  `6fecb8a1f3407697afa38d869fe642ec60c2ba5b6d5df21206d9d99374b829a2`
- the modules and configuration files under the extracted OEM root filesystem
- FIT `fdt@8`, whose SHA-1 is
  `fe50df4a1aa77a2076198156154a884a605fbe00`

The FIT `kernel@1` extraction is byte-identical to `vmlinux_raw.bin`.
`gale_v1.dts` is a byte-identical `dtc` round-trip of FIT `fdt@8`.

The current `vmlinux-to-elf` output contains the correct OEM kernel bytes, but
several recovered kallsyms names do not point to valid function boundaries.
For example, the recovered `__netif_receive_skb_core` address lands on a return
instruction. Therefore exact module disassembly and extracted Gale policy files
are treated as binary-confirmed evidence; matching ChromiumOS source is used to
explain kernel-core behavior that cannot yet be reliably named in the IDB.
Modern ethtool, DSA, and nftables changes are explicitly classified as ports or
adaptations rather than OEM code.

## Stock fast-path architecture

The stock image contains these matching Linux 3.18 modules:

```text
shortcut-fe.ko
shortcut-fe-ipv6.ko
shortcut-fe-cm.ko
fast-classifier.ko
essedma.ko
```

`/etc/init/load-sfe-module.conf` unconditionally loads `shortcut-fe-cm`.
`/etc/init/traffic-acceleration.conf` enables it through `/sys/sfe_cm/stop`
and flushes cached rules through `/sys/sfe_cm/defunct_all`.

The first packet follows the normal path:

```text
EDMA RX -> Linux receive stack -> firewall/conntrack/NAT/routing
        -> SFE post-routing hook -> install translated two-way flow rule
```

Later packets follow this path when the cached rule is eligible:

```text
EDMA RX -> __netif_receive_skb_core() -> fast_nat_recv
        -> sfe_cm_recv() -> sfe_ipv4_recv()/sfe_ipv6_recv()
        -> rewrite L2/L3/L4 headers and checksums -> dev_queue_xmit()
```

The Chromium 3.18 kernel adds the global `fast_nat_recv` callback before
VLAN receive handling, bridge receive handlers, protocol dispatch, routing,
and netfilter. `shortcut-fe-cm` assigns `sfe_cm_recv` to that callback. This
placement is why SFE saves so much per-packet CPU time; it is also why the old
hook is unsafe to transplant unchanged into a modern observable nftables/DSA
stack.

SFE only installs confirmed, eligible TCP/UDP flows. It rejects helpers/ALGs,
non-established TCP, local output, broadcast/multicast, and flows lacking
valid devices, routes, neighbours, or translation state. It synchronizes
counters and TCP state back to conntrack and removes cached rules on device or
conntrack events.

Matching source references used to explain the binary-confirmed behavior:

- [ChromeOS 3.18 receive path](https://chromium.googlesource.com/chromiumos/third_party/kernel/+/cb1966e3e030/net/core/dev.c)
- [ChromeOS SFE connection manager](https://chromium.googlesource.com/chromiumos/third_party/kernel/+/cb1966e3e030/drivers/net/ethernet/qualcomm/sfe/shortcut-fe/sfe_cm.c)
- [ChromeOS SFE IPv4 engine](https://chromium.googlesource.com/chromiumos/third_party/kernel/+/cb1966e3e030/drivers/net/ethernet/qualcomm/sfe/shortcut-fe/sfe_ipv4.c)
- [ChromeOS ESS EDMA driver](https://chromium.googlesource.com/chromiumos/third_party/kernel/+/cb1966e3e030/drivers/net/ethernet/qualcomm/essedma/edma.c)

## Why this is not routed hardware offload

There are no `qca-nss-drv`, `qca-nss-ecm`, PPE, or hardware-NAT modules in the
root filesystem. SFE imports ordinary kernel routing, conntrack, and transmit
functions; its fast engines rewrite packets in ARM code and call
`dev_queue_xmit()`. They do not import an NSS firmware or PPE rule API.

The stock hardware features have narrower scopes:

| Mechanism | Scope | Present |
|---|---|---|
| ESS switch | L2 FDB/VLAN/port switching | Yes |
| ESS EDMA | DMA, RSS, checksum/VLAN offload, SG/TSO/GRO | Yes |
| SFE | CPU software routed/NAT flow cache | Yes |
| EDMA aRFS | Per-flow CPU steering through a switch callback | Driver code exists, but no registering backend was found |
| NSS/ECM/PPE | Hardware routed/NAT flow engine | No |

The stock settings framework also disables hardware AQM unless
`PLATFORM_HAS_NSS_SUPPORT=1`; Gale does not set that capability.

## Stock multicore tuning

`/etc/init/gale-platform.conf` supplies most of the non-SFE performance gain:

- EDMA RX interrupts are assigned one per CPU.
- Four exposed TX queues use XPS masks `1`, `2`, `4`, and `8`.
- Each RX queue receives 256 RFS entries; the global table has 1024 entries.
- GRO is enabled.
- All 128 RSS entries are reprogrammed to use three RX queues, reserving CPU3
  for the 5 GHz radio.
- The exact packed RSS registers repeat `0x42042042`, `0x20420420`, and
  `0x40240240`, producing queue counts `42/43/43/0`.
- WAN RPS masks rotate through CPUs 1, 2, and 0; LAN masks rotate through CPUs
  2, 0, and 1.
- Hardware RX hash publication is then disabled so software RPS computes the
  hash used for the cross-CPU handoff.
- Wi-Fi IRQ and RPS placement deliberately separates radio interrupt work from
  later packet processing.

The EDMA interrupt moderation register uses two-microsecond ticks. Stock
defaults are 64 microseconds for RX (`0x20`) and 160 microseconds for TX
(`0x50`).

## Existing OpenWrt implementation

This clone uses Linux 6.18.38 and already has a modern IPQESS plus QCA8K DSA
stack. It provides:

- Four RX and four TX netdev queues
- RSS over hardware rings 0, 2, 4, and 6
- Threaded NAPI and `napi_gro_receive()`
- BQL, RX/TX checksums, VLAN acceleration, SG, TSO, and GRO
- DSA hardware offload for L2 FDB, VLAN, bridge, MDB, mirroring, and LAG
- `kmod-nft-offload` for maintained software routed-flow acceleration

It does not provide NSS/ECM, SFE, a PPE backend, `ndo_flow_offload`, or a QCA8K
TC flower/flow-block callback. Hardware flowtable mode must therefore remain
disabled.

## Implemented changes

| OpenWrt change | Exact OEM authority | Classification |
|---|---|---|
| Patch 720 coalescing | `essedma.ko` writes `0x00500020`; its setters use two-microsecond ticks | Direct capability port |
| Patch 721 RSS/hash API | `essedma.ko` publishes the descriptor hash and exposes private RSS sysctls | Modern ethtool API port |
| Patch 722 four DSA TX queues | `gale-platform.conf` assigns four XPS queues to both OEM netdevs | DSA topology adaptation |
| Patch 723 ring reporting | Linux 6.18 ethtool requirements and Gale runtime diagnostics | OpenWrt compatibility fix |
| Patch 724 exact RSS table | `gale-platform.conf` raw RSS patterns | Direct policy port via DT |
| nftables flow offload | `shortcut-fe*.ko` and `traffic-acceleration.conf` | Maintained functional substitute for SFE |
| Shared-master RPS masks | Separate OEM LAN/WAN masks in `gale-platform.conf` | DSA topology adaptation |

### Kernel patch 720: configurable interrupt moderation

`720-net-qualcomm-ipqess-add-ethtool-coalescing-support.patch` exposes the
EDMA RX/TX timers through the standard ethtool coalescing API. It retains the
stock-derived defaults while allowing measurements to trade interrupt cost
against latency.

```sh
ethtool -c eth0
ethtool -C eth0 rx-usecs 64 tx-usecs 160
```

### Kernel patch 721: RSS control and RX hash publication

`721-net-qualcomm-ipqess-add-RSS-ethtool-controls.patch` restores two vendor
capabilities missing from the current IPQESS driver:

- Publish the EDMA descriptor hash with `skb_set_hash()` when RXHASH is on.
- Get/set the 128-entry RSS indirection table with standard ethtool APIs.

The driver translates netdev queues 0-3 to EDMA hardware rings 0, 2, 4, and 6.
No private procfs ABI is introduced.

```sh
ethtool -x eth0
ethtool -X eth0 equal 4

# Generic three-queue distribution for manual experiments. The Gale image
# normally uses the exact OEM table supplied by its DTS instead.
ethtool -X eth0 equal 3

# Use software-computed hashes when deliberately reproducing stock RPS.
ethtool -K eth0 rxhash off
```

### Kernel patch 723: complete fixed-queue reporting

`723-net-qualcomm-ipqess-complete-fixed-queue-ethtool-reporting.patch` reports
the fixed four RX rings through the Linux 6.18 `get_rx_ring_count` callback.
The legacy ethtool ioctl uses that callback to validate RSS indirection-table
updates, so it is required for manual `ethtool -X` adjustments. It also reports
four RX/TX channels and the current 128-descriptor ring sizes.

### Kernel patch 724: exact OEM RSS table

`724-net-qualcomm-ipqess-allow-a-DT-RSS-indirection-table.patch` lets an
IPQESS board supply the 16 packed RSS registers through `qcom,rss-idt`. The
Google Wifi DTS contains the exact values written by OEM
`/etc/init/gale-platform.conf`; the driver validates every ring selector before
programming the hardware. Other IPQ40xx boards retain the standard four-queue
table.

### OpenWrt policy

The Gale first-boot defaults now enable:

```text
firewall flow_offloading=1
firewall flow_offloading_hw=0
network packet_steering=1
256 RFS entries per RX queue
1024 global RFS entries
```

The Google Wifi image includes `ethtool` for RSS and coalescing inspection.
The DTS programs the exact OEM RSS buckets over queues 0-2, leaving queue 3
out of the hardware receive distribution as on stock Gale. Its platform
packet-steering helper identifies the IPQESS master by its ethtool driver name
and applies the coordinated stock policy:

- non-threaded IPQESS NAPI so IRQ affinity also controls the poll CPU
- active EDMA TX IRQ masks `4,4,1,2` and RX IRQ masks `1,2,4,8`
- Ethernet XPS masks `1,2,4,8` and 256 RFS entries per receive queue
- direction-neutral DSA-master RPS masks `6,5,3,6`
- 2.4 GHz IRQ/RPS masks `1/8` and 5 GHz IRQ/RPS masks `8/7`
- all XHCI interrupts on CPU2
- RPS mask `1` for true 802.11s mesh interfaces on either radio

Patch 722 gives the DSA `lan` and `wan` devices four software TX queues so
the same XPS mapping can be retained through the DSA user device and IPQESS
conduit. This feeds all four EDMA DMA rings; it does not add switch egress
hardware QoS.

Stock could select different LAN and WAN RPS CPUs because it exposed two EDMA
netdevs. Modern DSA performs RPS on the shared IPQESS master before port demux,
so the helper uses the union of Google's LAN and WAN masks. This preserves the
CPU-avoidance policy but cannot be a bit-for-bit per-port reproduction.

Do not combine software flow offload with SQM/CAKE when accurate shaping is
required. Like stock SFE, a fast path avoids work that a shaper expects to see.
Disable `flow_offloading` before enabling SQM and benchmark that configuration
separately.

## Deliberately not ported

- The Linux 3.18 `fast_nat_recv` hook: modern nftables flowtable already
  supplies a maintained fast path without an unrestricted global callback.
- SFE itself: it would duplicate `nf_flow_table` and recreate old bridge,
  netfilter, QoS, and observability hazards.
- EDMA `ndo_rx_flow_steer`: the old code cannot program hardware until a
  separate ESS switch component registers a proprietary rule callback. No
  active backend was found in Gale.
- NSS/ECM/PPE hardware NAT: no matching Gale firmware/control plane exists,
  and the current DSA/netfilter integration would be a separate experimental
  project rather than a small EDMA patch.
- RX page-mode code from Linux 3.18: the correct modern follow-up is a measured
  page-pool conversion, not a verbatim port.

## Broader OEM networking binary audit

The extracted root filesystem contains one additional Google-authored kernel
networking component that is not a forwarding accelerator:

- `lib/modules/3.18.0-20714-gcb1966e3e030/kernel/net/sched/sch_arl.ko` is
  Google's Adaptive Rate Limiting qdisc. Symbols such as
  `arl_sample_latency_ingress`, `arl_update_hrtt`, and `arl_apply_new_rate`
  show that it adjusts a shaped rate from TCP/conntrack latency measurements.
- `/usr/sbin/ap-qos-monitor` enables ARL by default and combines it with IFB,
  HTB, priority qdiscs, FQ-CoDel, and NFQUEUE. Its embedded defaults include a
  60 percent minimum-rate ratio, a 100 ms latency threshold, and 25 ms
  hysteresis.

ARL is a bufferbloat/QoS feature, not part of Gale's SFE routing fast path. A
modern OpenWrt implementation should build an adaptive controller around CAKE
rather than forward-porting the Linux 3.18 qdisc and its direct TCP internals.

The OEM ath10k/mac80211 modules also contain custom airtime-fairness, per-TID
FQ-CoDel, queue-limit, aggregation, bursting, RTS, and latency-statistics
controls. Modern OpenWrt mac80211 already provides newer airtime scheduling,
FQ-CoDel, and AQL, but Google's exact optional per-TID/Stadia policy is not
reproduced by these routing patches.

Other audited behavior includes SFE bypass/flush coordination while QoS is
active, multicast-to-unicast policy, and a shorter established conntrack
timeout. No hidden NSS, ECM, PPE, or other hardware routed-flow driver was
found. `fast-classifier.ko` is installed but no OEM init job loads it.

## Validation and benchmark plan

The patches were applied through the complete OpenWrt Linux 6.18.38 target
prepare step and compiled with the ARM cross-compiler. Gale runtime diagnostics
confirmed the four Ethernet TX queues, XPS/RPS masks, RFS sizing, interrupt
moderation, non-threaded NAPI, and exact EDMA/ath10k IRQ affinity. They also
identified the missing RX-ring-count callback fixed by patch 723; that final
RSS programming path requires validation with the rebuilt image.

On Gale, verify:

```sh
ethtool -k eth0
ethtool -c eth0
ethtool -x eth0
ethtool -S eth0
ls -l /sys/class/net/eth0/queues
cat /sys/class/net/eth0/threaded
for dev in eth0 lan wan; do
	for q in /sys/class/net/$dev/queues/tx-*; do
		printf '%s: ' "$q"
		cat "$q/xps_cpus"
	done
done
cat /proc/interrupts
cat /proc/softirqs
cat /proc/sys/net/core/rps_sock_flow_entries
uci show firewall | grep flow_offloading
nft list ruleset | grep -A8 -B2 flowtable
```

Benchmark bidirectional IPv4 NAT, IPv6 routing, LAN-to-WLAN bridging, and
small-packet PPS. Compare software flow offload on/off, record per-CPU softirq
load, EDMA queue counters, drops, latency under load, and conntrack state. Tune
coalescing only from measured results.

## Gale v1 device-tree warning

The current OpenWrt device profile identifies `google,gale-v2`. The repository
root's extracted v1 DTS identifies `google,gale` and has materially different
GPIO assignments, including write-protect, recovery, and 802.15.4 reset pins.
The Ethernet PHY/port mapping is consistent, but these routing patches do not
make the v2 board file safe for v1 hardware. Create and validate a separate v1
DTS/device profile before flashing a unit that truly uses the v1 board wiring.
