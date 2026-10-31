# shellcheck shell=bash
# Kernel step: firmware, microcode, installkernel, dracut, the kernel command line and the dist-kernel.

step_define kernel "Firmware and kernel" \
  "Installs firmware, CPU microcode and a prebuilt or locally built distribution kernel. installkernel and dracut build an initramfs for this machine and place the kernel where the bootloader looks." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Kernel"

# The kernel installs during the world step, so everything installkernel and dracut read is written here.
step_kernel_portage() {
  local cmdline
  cmdline=$(kernel_cmdline) || return
  {
    case ${CFG[bootloader]} in
      grub) echo 'sys-kernel/installkernel dracut grub' ;;
      limine)
        # installkernel has no limine flag. Without systemd-boot's boot flag, systemd keeps the
        # binary host's build, which has kernel-install already.
        echo 'sys-kernel/installkernel dracut systemd'
        if is_openrc; then echo 'sys-apps/systemd-utils kernel-install'; fi
        ;;
      *)
        echo 'sys-kernel/installkernel dracut systemd systemd-boot'
        if is_openrc; then echo 'sys-apps/systemd-utils boot kernel-install'; else echo 'sys-apps/systemd boot'; fi
        ;;
    esac
    # dracut unlocks LUKS through systemd-cryptsetup when the initramfs runs systemd.
    if is_systemd && [[ ${CFG[encryption]} == luks2 ]]; then echo 'sys-apps/systemd cryptsetup'; fi
  } | portage_file package.use installkernel
  make_conf_use_add dist-kernel
  printf '%s\n' "$cmdline" | write_file /etc/kernel/cmdline
  # installkernel refuses to run dracut in a chroot without a command line here. Relative, so it
  # resolves both inside the chroot and from the live system.
  run_cmd mkdir -p "$GI_TARGET/etc/cmdline.d"
  run_cmd ln -sfn ../kernel/cmdline "$GI_TARGET/etc/cmdline.d/00-installkernel.conf"
  _kernel_dracut_conf | write_file /etc/dracut.conf.d/gentooinstall.conf
  _kernel_limine_files
  _kernel_cleanup_files
}

# Portage leaves an unmerged kernel in the boot menu, on the 1 GiB ESP (about 40 MB) or in /boot,
# and keeps its /lib/modules/<version> (about 630 MB) by design (UNINSTALL_IGNORE).
_kernel_cleanup_files() {
  local p
  for p in gentoo-kernel-bin gentoo-kernel; do
    _kernel_cleanup_hook | write_file "/etc/portage/env/sys-kernel/$p"
  done
}

_kernel_cleanup_hook() {
  cat << 'EOF'
# Written by gentooinstall. Portage runs this after it removes a kernel package, which leaves that
# kernel in the boot menu and its modules in /lib/modules. It takes the kernels whose build tree is
# gone out of the boot menu, then deletes their modules, except the running one and the newest.
# One kept as running goes at the next removal.
# Portage saves this function with each kernel it installs: to turn it off, empty its body here.
post_pkg_postrm() {
	local f v newest running grub=0 removed=0
	local -a vers=()
	# Not for an emerge --root into another system: its kernels aren't the ones in /boot and /efi.
	[[ -z ${EROOT%/} ]] || return 0
	running=$(uname -r)
	# Nor from a live system's chroot: its running kernel isn't this system's, so the one that last
	# ran here, the known-good fallback, would go.
	[[ -d /lib/modules/${running} ]] || return 0
	if [[ -f /boot/grub/grub.cfg ]]; then
		# installkernel names a kernel vmlinuz-<version>, or kernel-<version> through systemd's
		# kernel-install, and keeps the files a same-version reinstall replaced as <name>.old.
		grub=1
		for f in /boot/vmlinuz-* /boot/kernel-*; do
			v=${f#/boot/*-}
			if [[ -f ${f} && ${v} != *.old ]]; then vers+=("${v}"); fi
		done
	else
		command -v kernel-install > /dev/null || return 0
		for f in /efi/loader/entries/*.conf; do
			[[ -f ${f} ]] || continue
			vers+=("$(sed -n 's/^version[[:space:]]\+//p' "${f}")")
		done
	fi
	newest=$(printf '%s\n' "${vers[@]}" | sort -V | tail -n 1)
	for v in "${vers[@]}"; do
		# Only a kernel release, one name under /lib/modules, may reach rm -rf. Portage keeps a removed
		# kernel's modules, so one without them is a copy, another system's or one built without modules.
		[[ ${v} == [0-9]* && ${v} != */* && -d /lib/modules/${v} ]] || continue
		# A kernel package installs /usr/src/linux-<version>, linked as /lib/modules/<version>/build, and
		# its removal takes both away. A kernel built by hand keeps its build link to its source tree.
		if [[ -e /usr/src/linux-${v} || -e /lib/modules/${v}/build || ${v} == "${running}" || ${v} == "${newest}" ]]; then
			continue
		fi
		if ((grub)); then
			# Even a partial removal changes the menu.
			removed=1
			if ! rm -f -- /boot/{vmlinuz,kernel,System.map,config}-"${v}"{,.old} /boot/initramfs-"${v}".img{,.old}; then
				ewarn "Couldn't remove the old kernel ${v} from /boot, so its modules stay too."
				continue
			fi
		elif ! kernel-install remove "${v}"; then
			ewarn "kernel-install remove ${v} failed, so that kernel and its modules stay."
			continue
		fi
		if rm -rf -- "/lib/modules/${v}"; then
			elog "Removed the old kernel ${v} and its modules."
		else
			ewarn "Removed the old kernel ${v}, but not all of /lib/modules/${v}."
		fi
	done
	# Once, after all removals. Only a warning: the packages are gone either way.
	if ((removed)) && ! grub-mkconfig -o /boot/grub/grub.cfg; then
		ewarn "grub-mkconfig failed, so the GRUB menu still lists the removed kernels. Run: grub-mkconfig -o /boot/grub/grub.cfg"
	fi
}
EOF
}

# Limine reads only FAT and ISO 9660, so kernels go to the ESP in the systemd-boot layout, and a
# kernel-install plugin rewrites limine.conf from those entries on every kernel install and removal.
_kernel_limine_files() {
  local f
  if [[ ${CFG[bootloader]} != limine ]]; then
    # Left from an earlier answer, layout=bls would send GRUB's kernels to the ESP.
    for f in /etc/portage/package.accept_keywords/limine /etc/kernel/install.conf.d/limine.conf \
      /etc/kernel/install.d/95-limine.install /etc/portage/env/sys-boot/limine; do
      if [[ -e $GI_TARGET$f ]]; then run_cmd rm -f -- "$GI_TARGET$f"; fi
    done
    return 0
  fi
  echo 'sys-boot/limine ~amd64' | portage_file package.accept_keywords limine
  # A drop-in overrides only the layout in installkernel's /usr/lib/kernel/install.conf.
  echo 'layout=bls' | write_file /etc/kernel/install.conf.d/limine.conf
  _kernel_limine_plugin | write_file /etc/kernel/install.d/95-limine.install 0755
  _kernel_limine_update_hook | write_file /etc/portage/env/sys-boot/limine
}

# Portage sources /etc/portage/env/<category>/<package> in every phase of that package. The ebuild
# installs the loader only to /usr/share/limine, so without this the ESP keeps the old one.
_kernel_limine_update_hook() {
  cat << 'EOF'
# Written by gentooinstall. After every install or update of sys-boot/limine, Portage runs this
# to copy the new loader over Limine's copies on the ESP.
post_pkg_postinst() {
	local d=${EROOT%/}/efi/EFI f
	local -a files=()
	# On the first install the bootloader step makes the copies.
	[[ -f ${d}/limine/BOOTX64.EFI ]] || return 0
	# The fallback path is Limine's only while it holds the same loader as Limine's own path.
	if cmp -s -- "${d}/BOOT/BOOTX64.EFI" "${d}/limine/BOOTX64.EFI"; then files+=("${d}/BOOT/BOOTX64.EFI"); fi
	files+=("${d}/limine/BOOTX64.EFI")
	for f in "${files[@]}"; do
		# Written beside it, flushed, then renamed, so a crash never leaves half a loader.
		if cp -- "${EROOT%/}/usr/share/limine/BOOTX64.EFI" "${f}.new" && sync -- "${f}.new" &&
			mv -f -- "${f}.new" "${f}"; then
			elog "Copied the new Limine loader to ${f}"
		else
			rm -f -- "${f}.new"
			eerror "Couldn't copy /usr/share/limine/BOOTX64.EFI to ${f}. Copy it there yourself."
		fi
	done
}
EOF
}

# After 90-loaderentry.install, which writes or removes the entry for this kernel.
_kernel_limine_plugin() {
  cat << 'EOF'
#!/bin/bash
# Written by gentooinstall. kernel-install runs this after every kernel install and removal. It
# rewrites limine.conf on the ESP from the boot entries in loader/entries, newest kernel first.
# Edits to limine.conf are lost at the next kernel update; change the settings here instead.
[[ $1 == add || $1 == remove ]] || exit 0
[[ $KERNEL_INSTALL_LAYOUT == bls ]] || exit 0
esp=${KERNEL_INSTALL_BOOT_ROOT:?}
shopt -s nullglob
entries=$(for f in "$esp"/loader/entries/*.conf; do
  printf '%s\t%s\n' "$(sed -n 's/^version[[:space:]]\+//p' "$f")" "$f"
done | sort -rV | cut -f2-)
conf=$(
  echo 'timeout: 3'
  # The editor would let anyone at the keyboard boot with init=/bin/sh.
  echo 'editor_enabled: no'
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    title=Linux version='' options='' linux='' initrds=()
    while read -r key value; do
      case $key in
        title) title=$value ;;
        version) version=$value ;;
        options) options+=${options:+ }$value ;;
        linux) linux=$value ;;
        initrd) initrds+=("$value") ;;
      esac
    done < "$f"
    [[ -n $linux ]] || continue
    # boot() is the partition holding limine.conf, the ESP; entry paths are relative to it.
    printf '\n/%s %s\n    protocol: linux\n    path: boot():%s\n' "$title" "$version" "$linux"
    for i in "${initrds[@]}"; do printf '    module_path: boot():%s\n' "$i"; done
    printf '    cmdline: %s\n' "$options"
  done <<< "$entries"
)
# Limine expands ${NAME} anywhere in its config, and a ${ without its } stops it at boot.
if [[ $conf == *\$\{* ]]; then
  echo "95-limine.install: a boot entry contains \${, which Limine reads as a macro; limine.conf stays as it was." >&2
  exit 1
fi
# One write, flushed, then a rename: a full ESP or a crash never leaves Limine half a config.
printf '%s\n' "$conf" > "$esp/limine.conf.new" && sync -- "$esp/limine.conf.new" &&
  mv -f -- "$esp/limine.conf.new" "$esp/limine.conf"
EOF
}

step_kernel_packages() {
  local -a p=(sys-kernel/linux-firmware sys-kernel/installkernel "sys-kernel/${CFG[kernel]}")
  if [[ ${HW[cpu_vendor]:-} == intel ]]; then p+=(sys-firmware/intel-microcode); fi
  if [[ ${HW[sof]:-} == yes ]]; then p+=(sys-firmware/sof-firmware); fi
  if [[ ${CFG[encryption]} == luks2 ]]; then p+=(sys-fs/cryptsetup); fi
  printf '%s\n' "${p[@]}"
}

step_kernel() {
  # installkernel's grub flag writes grub.cfg with each kernel. Left from an earlier bootloader answer,
  # it would make the cleanup hook look for old kernels in /boot instead of on the ESP.
  if [[ ${CFG[bootloader]} != grub && -e $GI_TARGET/boot/grub/grub.cfg ]]; then
    run_cmd rm -f -- "$GI_TARGET/boot/grub/grub.cfg"
  fi
  # world may have installed the kernel before cryptsetup, btrfs-progs or the firmware; rebuild the initramfs now.
  kernel_reinstall
  kernel_check
}

# Every installed kernel is in the boot menu, so each gets a new initramfs. With two slots, as from an
# LTS kernel in packages or a sync before a retry, emerge --config refuses a name without a version.
kernel_reinstall() {
  local d
  local -a atoms=()
  for d in "$GI_TARGET"/var/db/pkg/sys-kernel/gentoo-kernel{,-bin}-[0-9]*/; do
    if [[ -d $d ]]; then
      d=${d%/}
      atoms+=("=sys-kernel/${d##*/}")
    fi
  done
  if ((!${#atoms[@]})); then atoms=("sys-kernel/${CFG[kernel]}"); fi
  for d in "${atoms[@]}"; do emerge_run --config "$d" || return; done
}

kernel_cmdline() {
  local root_uuid luks_uuid
  local -a a=()
  root_uuid=$(state_get disk.root_uuid)
  luks_uuid=$(state_get disk.luks_uuid)
  if [[ -z $root_uuid ]] && ((!GI_DRY_RUN)); then die "The disk step didn't record the root filesystem UUID."; fi
  if [[ ${CFG[encryption]} == luks2 && -z $luks_uuid ]] && ((!GI_DRY_RUN)); then
    die "The disk step didn't record the LUKS UUID."
  fi
  if [[ ${CFG[encryption]} == luks2 ]]; then
    a+=("rd.luks.uuid=$luks_uuid")
    if [[ ${CFG[luks_discard]} == yes ]]; then
      # dracut's own unlocker (OpenRC) ignores rd.luks.options.
      if is_systemd; then a+=(rd.luks.options=discard); else a+=("rd.luks.allow-discards=$luks_uuid"); fi
    fi
  fi
  # The filesystem UUID works whatever name the initramfs gives the LUKS mapping (luks-<uuid> by default).
  a+=("root=UUID=$root_uuid")
  if [[ ${CFG[filesystem]} == btrfs ]]; then a+=(rootflags=subvol=@); fi
  # No nvidia_drm.modeset=1: nvidia-drivers 580 sets it in modprobe.d and 595 and later default to it.
  a+=(rw)
  printf '%s\n' "${a[*]}"
}

_kernel_dracut_conf() {
  echo 'hostonly="yes"'
  # Guarded because world may run dracut before these tools are installed, and dracut fails
  # on a requested module it can't add. The kernel step runs dracut again once they are.
  if [[ ${CFG[encryption]} == luks2 ]]; then
    echo 'if command -v cryptsetup >/dev/null; then add_dracutmodules+=" crypt "; fi'
  fi
  if [[ ${CFG[filesystem]} == btrfs ]]; then
    echo 'if command -v btrfs >/dev/null; then add_dracutmodules+=" btrfs "; fi'
  fi
  # On systemd dracut reads /etc/vconsole.conf by itself.
  if is_openrc; then echo 'i18n_vars="/etc/conf.d/keymaps:keymap-KEYMAP,extended_keymaps-EXT_KEYMAPS"'; fi
}

# Fails loudly unless a kernel and its initramfs sit where the bootloader reads them.
kernel_check() {
  local f key path ok initrd n=0 linux=''
  ((GI_DRY_RUN)) && return 0
  if [[ ${CFG[bootloader]} == grub ]]; then
    # installkernel names it vmlinuz-<version>, or kernel-<version> through systemd's kernel-install.
    if compgen -G "$GI_TARGET/boot/vmlinuz-*" > /dev/null || compgen -G "$GI_TARGET/boot/kernel-*" > /dev/null; then
      compgen -G "$GI_TARGET/boot/initramfs-*.img" > /dev/null && return 0
    fi
    error "No kernel and initramfs in $GI_TARGET/boot, where GRUB looks. See /var/log/installkernel.log in the new system."
    return 1
  fi
  if [[ ${CFG[bootloader]} == limine ]]; then
    f=$GI_TARGET/efi/limine.conf ok=1 initrd=''
    # Limine boots the first entry, the newest kernel. boot() is the ESP, which holds limine.conf.
    if [[ -f $f ]]; then
      while read -r key path; do
        case $key in
          /*) ((n == 0)) || break; n=1 ;;
          path: | module_path:)
            path=/efi${path#'boot():'}
            if [[ $path != /efi/* || ! -f $GI_TARGET$path ]]; then
              ok=0
            elif [[ $key == path: ]]; then
              linux=$path
            else
              initrd=$path
            fi
            ;;
        esac
      done < "$f"
    fi
    if ((n && ok)) && [[ -n $linux && -n $initrd ]]; then
      _kernel_initrd_unlocks "$initrd"
      return
    fi
    error "The first entry in $f doesn't have its kernel and initramfs on the ESP. See /var/log/installkernel.log in the new system."
    return 1
  fi
  # Entry paths are relative to the ESP. kernel-install falls back to /boot when it can't find the ESP.
  for f in "$GI_TARGET"/efi/loader/entries/*.conf; do
    [[ -f $f ]] || continue
    ok=1 initrd=''
    while read -r key path; do
      case $key in
        linux) [[ -f $GI_TARGET/efi$path ]] || ok=0 ;;
        initrd) if [[ -f $GI_TARGET/efi$path ]]; then initrd=/efi$path; else ok=0; fi ;;
      esac
    done < "$f"
    if ((ok)) && [[ -n $initrd ]] && grep -q '^linux[[:space:]]' "$f"; then
      _kernel_initrd_unlocks "$initrd"
      return
    fi
  done
  error "No systemd-boot entry with its kernel and initramfs on the ESP ($GI_TARGET/efi/loader/entries). See /var/log/installkernel.log in the new system."
  return 1
}

# dracut leaves the unlocker out without a word when it doesn't detect LUKS in the chroot, or when
# systemd lacks USE=cryptsetup; the machine would then stop at boot without asking for the passphrase.
_kernel_initrd_unlocks() { # INITRD (path inside the target)
  local want=bin/cryptsetup list
  [[ ${CFG[encryption]} == luks2 ]] || return 0
  # The systemd initramfs unlocks through systemd-cryptsetup and doesn't carry cryptsetup itself.
  if is_systemd; then want=/systemd-cryptsetup; fi
  list=$(dry_value '' arch-chroot "$GI_TARGET" lsinitrd "$1" 2>> "$GI_LOG") || list=''
  # lsinitrd lists one file per line, ending in its path.
  grep -q -- "$want\$" <<< "$list" && return 0
  error "The initramfs $1 has no ${want##*/}, so it can't unlock the encrypted root. Check dracut's output in the install log."
  return 1
}
