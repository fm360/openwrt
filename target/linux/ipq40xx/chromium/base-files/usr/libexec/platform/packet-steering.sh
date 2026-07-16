#!/bin/sh

. /lib/functions.sh

packet_steering="$1"
steering_flows="$(uci -q get 'network.@globals[0].steering_flows')"
opts=""

# The Gale placement below is this board's supported operating mode, so treat
# a missing packet_steering option (e.g. a hand-written or restored network
# config without the globals section) as enabled.  Only an explicit '0'
# disables it.  Without this, every reload path - boot, procd triggers and the
# hotplug reapply hooks - silently exits and the box degrades to whatever
# packet-steering.uc last did, with all IRQs left on CPU0.
[ -n "$packet_steering" ] || packet_steering=1

[ "${steering_flows:-0}" -gt 0 ] || steering_flows=256
opts="-l $steering_flows"

# Retain OpenWrt's general steering for non-IPQESS devices, then override the
# Gale-specific Ethernet and Wi-Fi placement below.
/usr/libexec/network/packet-steering.uc $opts "$packet_steering"

[ "$packet_steering" = "1" ] || [ "$packet_steering" = "2" ] || exit 0
[ "$(board_name)" = "google,wifi" ] || exit 0

write_value()
{
	local path="$1"
	local value="$2"

	[ -w "$path" ] || return 0
	printf '%s\n' "$value" > "$path"
}

set_irq_action_affinity()
{
	local actions irq_path wanted="$1"
	local mask="$2"

	for irq_path in /sys/kernel/irq/[0-9]*; do
		[ -r "$irq_path/actions" ] || continue
		read -r actions < "$irq_path/actions"
		case "$actions" in
		*"$wanted"*)
			write_value "/proc/irq/${irq_path##*/}/smp_affinity" \
				"$mask"
			;;
		esac
	done
}

set_hwirq_affinity()
{
	local actions hwirq irq_path wanted="$1"
	local mask="$2"

	for irq_path in /sys/kernel/irq/[0-9]*; do
		[ -r "$irq_path/hwirq" ] || continue
		read -r hwirq < "$irq_path/hwirq"
		[ "$hwirq" = "$wanted" ] || continue

		# Both radios use the same action name, so the GIC hardware IRQ is
		# what distinguishes the 2.4 GHz and 5 GHz instances.
		if [ -r "$irq_path/actions" ]; then
			read -r actions < "$irq_path/actions"
			case "$actions" in
			*ath10k_ahb*) ;;
			*) continue ;;
			esac
		fi

		write_value "/proc/irq/${irq_path##*/}/smp_affinity" "$mask"
	done
}

set_xps()
{
	local device="$1"

	write_value "/sys/class/net/$device/queues/tx-0/xps_cpus" 1
	write_value "/sys/class/net/$device/queues/tx-1/xps_cpus" 2
	write_value "/sys/class/net/$device/queues/tx-2/xps_cpus" 4
	write_value "/sys/class/net/$device/queues/tx-3/xps_cpus" 8
}

apply_ipqess_policy()
{
	local device device_path driver pdev queue

	for device_path in /sys/class/net/*; do
		[ -e "$device_path" ] || continue
		device="${device_path##*/}"
		driver="$(/usr/sbin/ethtool -i "$device" 2>/dev/null |
			sed -n 's/^driver: //p')"
		[ "$driver" = "qca_ipqess" ] || continue

		# Stock Gale used non-threaded NAPI.  This makes the IRQ placement
		# below control the poll CPU as well, instead of leaving eight
		# dynamically numbered NAPI kthreads free to migrate onto CPU3.
		write_value "$device_path/threaded" 0

		# The Gale DTS supplies the OEM's exact 128-bucket RSS table. Queue 3
		# is kept out of Ethernet receive work so CPU3 remains available to
		# radio processing. Hardware RSS remains active when RXHASH
		# publication is disabled for software RPS.
		/usr/sbin/ethtool -K "$device" gro on rxhash off ||
			logger -t google-wifi-steering -p daemon.err \
				"failed to configure offloads on $device"

		set_xps "$device"
		# With four DSA user TX queues, preserve the same XPS mapping at
		# the user-facing layer so locally generated traffic reaches the
		# corresponding IPQESS hardware queue.
		set_xps lan
		set_xps wan

		for queue in 0 1 2 3; do
			write_value "$device_path/queues/rx-$queue/rps_flow_cnt" 256
		done

		# Stock had separate LAN and WAN netdevs with +2 and +1 CPU
		# rotations. DSA combines them before RPS, so use the union for
		# each queue. Active queues still avoid their IRQ CPU and CPU3.
		write_value "$device_path/queues/rx-0/rps_cpus" 6
		write_value "$device_path/queues/rx-1/rps_cpus" 5
		write_value "$device_path/queues/rx-2/rps_cpus" 3
		write_value "$device_path/queues/rx-3/rps_cpus" 6

		pdev="$(readlink -f "$device_path/device")"
		pdev="${pdev##*/}"
		set_irq_action_affinity "$pdev:txq0" 4
		set_irq_action_affinity "$pdev:txq4" 4
		set_irq_action_affinity "$pdev:txq8" 1
		set_irq_action_affinity "$pdev:txq12" 2
		set_irq_action_affinity "$pdev:rxq0" 1
		set_irq_action_affinity "$pdev:rxq2" 2
		set_irq_action_affinity "$pdev:rxq4" 4
		set_irq_action_affinity "$pdev:rxq6" 8
	done
}

apply_wifi_rps()
{
	local device_path iface_mask mask net_path net_phy phy_path
	local phy_real radio_path

	for phy_path in /sys/class/ieee80211/phy*; do
		[ -e "$phy_path/device" ] || continue
		radio_path="$(readlink -f "$phy_path/device")"
		case "$radio_path" in
		*/a000000.wifi) mask=8 ;;
		*/a800000.wifi) mask=7 ;;
		*) continue ;;
		esac

		phy_real="$(readlink -f "$phy_path")"
		for net_path in /sys/class/net/*; do
			[ -e "$net_path/phy80211" ] || continue
			net_phy="$(readlink -f "$net_path/phy80211")"
			[ "$net_phy" = "$phy_real" ] || continue
			# All interfaces on a radio share its RPS mask, including
			# 802.11s mesh.  Stock Gale steered by radio, never by
			# interface role, and pinning the mesh backhaul to CPU0
			# would stack it on top of the Ethernet IRQs and the
			# 2.4 GHz radio's interrupt work.
			iface_mask="$mask"

			for device_path in "$net_path"/queues/rx-*; do
				write_value "$device_path/rps_cpus" "$iface_mask"
			done
		done
	done
}

apply_ipqess_policy

# Stock Gale assigns every XHCI host interrupt to CPU2.
set_irq_action_affinity "xhci-hcd:usb" 4

# IPQ4019's GIC translates the DTS legacy SPIs 168/169 to hwirqs 200/201.
# Put 2.4 GHz interrupt work on CPU0 and 5 GHz interrupt work on CPU3.
set_hwirq_affinity 200 1
set_hwirq_affinity 201 8

# Move upper-stack Wi-Fi receive work away from each radio's IRQ CPU.
apply_wifi_rps

exit 0
