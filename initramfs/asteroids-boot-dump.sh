# Appended to /init_functions.sh inside the initramfs by inject-boot-dump.sh.
# Defines only; nothing runs at source time. Sourced by /init and /init_2nd.sh,
# so the fail_halt_boot override below is in place before anything can fail.
#
# >>>> asteroids boot dump v1 >>>>

pmos_asteroids_dump_target() {
	# PMOS_DUMP_TTY exists so this can be tested on a host.
	if [ -n "${PMOS_DUMP_TTY:-}" ]; then
		printf '%s' "$PMOS_DUMP_TTY"
		return
	fi
	if [ -w /dev/tty0 ]; then
		printf '%s' /dev/tty0
	elif [ -w /dev/console ]; then
		printf '%s' /dev/console
	else
		printf '%s' /dev/null
	fi
}

pmos_asteroids_partitions_file() {
	printf '%s' "${PMOS_DUMP_PARTITIONS:-/proc/partitions}"
}

# Is the UFS host controller in the log at all?
pmos_asteroids_verdict() {
	parts=$(pmos_asteroids_partitions_file)
	disk=$(awk 'NR>2 && $4 ~ /^sd[a-z]$/ {print $4}' "$parts" 2>/dev/null | head -n1)
	kids=$(awk 'NR>2 && $4 ~ /^sd[a-z][0-9]/ {print $4}' "$parts" 2>/dev/null | tr '\n' ' ')
	ufs=$(dmesg 2>/dev/null | grep -ciE 'ufshcd')
	label=$(blkid 2>/dev/null | grep -c 'LABEL="pmOS_root"')

	if [ "$ufs" -eq 0 ]; then
		echo "UFS DRIVER NEVER BOUND - check &ufs_mem_hc and CONFIG_SCSI_UFS_QCOM"
	elif [ -z "$disk" ]; then
		echo "UFS PROBED, NO DISK - phy/regulator/link; look at the ufs lines above"
	elif [ -z "$kids" ]; then
		echo "DISK $disk HAS NO PARTITIONS - GPT not parsed or table missing"
	elif [ "$label" -eq 0 ]; then
		echo "DISK AND PARTITIONS OK, NO pmOS_root LABEL - format with -L pmOS_root"
	else
		echo "pmOS_root FOUND - failure is in the mount or the rootfs itself"
	fi
}

pmos_asteroids_boot_dump() {
	target=$(pmos_asteroids_dump_target)
	{
		echo ""
		echo "================ pmOS boot failure ================"
		echo "uptime: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
		echo "model : $(tr -d '\0' <"${PMOS_DUMP_MODEL_FILE:-/sys/firmware/devicetree/base/model}" 2>/dev/null)"
		echo "cmdline: $(cat "${PMOS_DUMP_CMDLINE:-/proc/cmdline}" 2>/dev/null)"
		echo "codename: $(grep -E '^deviceinfo_codename=' /etc/deviceinfo 2>/dev/null | cut -d= -f2 | tr -d '\"')"
		echo "super  : $(grep -E '^deviceinfo_super_partitions=' /etc/deviceinfo 2>/dev/null | cut -d= -f2-)"
		echo ""
		echo "--- ufs / phy / scsi (last 20) ---"
		dmesg 2>/dev/null | grep -iE 'ufs|qmp|scsi' | tail -n20
		echo ""
		echo "--- last 12 kernel lines ---"
		dmesg 2>/dev/null | tail -n12
		echo ""
		echo "--- /proc/partitions ---"
		cat "$(pmos_asteroids_partitions_file)" 2>/dev/null
		echo ""
		echo "--- blkid ---"
		blkid 2>/dev/null
		echo ""
		echo "--- /dev/disk/by-partlabel ---"
		ls -l "${PMOS_DUMP_PARTLABEL_DIR:-/dev/disk/by-partlabel}" 2>/dev/null || echo "(none)"
		echo ""
		echo "--- /dev/mapper ---"
		ls -l "${PMOS_DUMP_MAPPER_DIR:-/dev/mapper}" 2>/dev/null || echo "(none)"
		echo ""
		echo "==================================================="
		echo " VERDICT: $(pmos_asteroids_verdict)"
		echo " Photograph this screen; press the volume key to"
		echo " beep, then attach USB for the debug shell."
		echo "==================================================="
	} >"$target" 2>&1
}

# Same body as upstream fail_halt_boot, with the dump in front of it.
fail_halt_boot() {
	pmos_asteroids_boot_dump
	beebzzr -b 3 -d 250 &
	export_logs
	debug_shell
	echo "Looping forever"
	while true; do
		sleep 1
	done
}

# <<<< asteroids boot dump v1 <<<<
