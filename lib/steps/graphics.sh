# shellcheck shell=bash
# Graphics drivers step: VIDEO_CARDS, NVIDIA's driver, USE flags and license.

step_define graphics "Graphics drivers" \
  "VIDEO_CARDS tells Portage which GPU drivers to build. The binary packages were built for the profile's default list, so it only changes when binary packages are off, when tuning for this machine, or for NVIDIA's own driver." \
  "https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#VIDEO_CARDS"

_graphics_nvidia() {
  [[ " ${HW[gpus]:-} " == *" nvidia "* && ${CFG[nvidia_driver]} == proprietary && $(graphics_nvidia_branch) != none ]]
}

# Prints the driver branch the oldest NVIDIA GPU needs: current, 580 or none. Device IDs follow the
# chip generations. Below 0x1e00 (Maxwell, Pascal, Volta) only the 580 branch's closed kernel modules
# work, since 595 and later build only the open ones, which need Turing or newer. Below 0x1340
# (Kepler and older) no NVIDIA driver in the tree builds for current kernels.
graphics_nvidia_branch() {
  local min
  min=$(_graphics_nvidia_id)
  if ((min < 0x1340)); then
    echo none
  elif ((min < 0x1e00)); then
    echo 580
  else
    echo current
  fi
}

# Prints the lowest device ID of the NVIDIA GPUs, 0xffff without one.
_graphics_nvidia_id() {
  local d id min=0xffff
  for d in "${GI_HOST_ROOT:-}"/sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/class && -r $d/device ]] || continue
    [[ $(< "$d/vendor") == 0x10de && $(< "$d/class") == 0x03* ]] || continue
    id=$(< "$d/device")
    if [[ $id =~ ^0x[0-9a-f]{4}$ ]] && ((id < min)); then min=$id; fi
  done
  printf '%s\n' "$min"
}

# NVIDIA's driver beside Intel or AMD graphics: a laptop's hybrid graphics, where apps run on the
# other GPU and prime-run starts one on NVIDIA's.
graphics_hybrid() {
  _graphics_nvidia && [[ " ${HW[gpus]:-} " == *" intel "* || " ${HW[gpus]:-} " == *" amd "* ]]
}

# VMware's SVGA GPU, which VirtualBox's VMSVGA emulates too, has Mesa's vmware driver; QEMU's virtio GPU has virgl.
_graphics_vmware() {
  local d
  for d in "${GI_HOST_ROOT:-}"/sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/class ]] || continue
    if [[ $(< "$d/vendor") == 0x15ad && $(< "$d/class") == 0x03* ]]; then return 0; fi
  done
  return 1
}

step_graphics_portage() {
  local g cards='' content='' f=/etc/portage/package.use/00video_cards
  local lic=/etc/portage/package.license/nvidia-drivers mask=/etc/portage/package.mask/nvidia-drivers
  local -a gpus=()
  read -ra gpus <<< "${HW[gpus]:-}"
  if [[ " ${gpus[*]} " == *" nvidia "* && ${CFG[nvidia_driver]} == proprietary ]] && ! _graphics_nvidia; then
    warn "The NVIDIA GPU is a Kepler model or older, which no NVIDIA driver in Gentoo supports on current kernels. Using the open nouveau driver instead."
  fi
  if [[ ${CFG[tune]} == yes || ${CFG[binpkgs]} == no ]]; then
    for g in "${gpus[@]}"; do
      case $g in
        intel) cards+=' intel' ;;
        amd) cards+=' amdgpu radeonsi' ;;
        nvidia) if _graphics_nvidia; then cards+=' nvidia'; else cards+=' nouveau'; fi ;;
        virtual) if _graphics_vmware; then cards+=' vmware'; else cards+=' virgl'; fi ;;
      esac
    done
    if [[ -n $cards ]]; then content="*/* VIDEO_CARDS: -*$cards"$'\n'; fi
    # Mesa and ffmpeg build from source here anyway, so their hardware video decoding costs nothing extra.
    if [[ $cards == *amdgpu* ]]; then content+=$'media-libs/mesa vaapi\n'; fi
    if [[ $cards == *nvidia* ]]; then content+=$'*/* nvidia vdpau nvenc\n'; fi
  elif _graphics_nvidia; then
    # Not the wiki's "*/* nvidia vdpau nvenc": the binary ffmpeg lacks them, so it would build from
    # source, for NVDEC and VDPAU decoding that only players like mpv use.
    content=$'*/* VIDEO_CARDS: nvidia\n'
  fi
  if _graphics_nvidia; then
    echo 'x11-drivers/nvidia-drivers NVIDIA-2025' | portage_file package.license nvidia-drivers
  elif [[ -e $GI_TARGET$lic ]]; then
    run_cmd rm -f -- "$GI_TARGET$lic"
  fi
  if _graphics_nvidia && [[ $(graphics_nvidia_branch) == 580 ]]; then
    echo '>=x11-drivers/nvidia-drivers-581' | write_file "$mask"
  elif [[ -e $GI_TARGET$mask ]]; then
    run_cmd rm -f -- "$GI_TARGET$mask"
  fi
  # The preview step reruns this hook after changes, so a file that's no longer needed must go.
  if [[ -n $content ]]; then
    printf '%s' "$content" | portage_file package.use 00video_cards
  elif [[ -e $GI_TARGET$f ]]; then
    run_cmd rm -f -- "$GI_TARGET$f"
  fi
}

step_graphics_packages() {
  if _graphics_nvidia; then echo x11-drivers/nvidia-drivers; fi
  if graphics_hybrid; then echo x11-misc/prime-run; fi
}

# Lets a hybrid laptop's NVIDIA GPU power off while no app uses it, as NVIDIA's README describes
# under PCI-Express Runtime D3. Ampere and later have it on by default; Turing needs the option.
# The udev rules turn on runtime power management for the GPU's functions, which some laptops don't.
_graphics_rtd3() {
  if (($(_graphics_nvidia_id) < 0x2200)); then
    echo 'options nvidia NVreg_DynamicPowerManagement=0x02' | write_file /etc/modprobe.d/nvidia-pm.conf
  fi
  write_file /etc/udev/rules.d/80-nvidia-pm.rules << 'EOF'
# Written by gentooinstall, from NVIDIA's README: runtime power management for the NVIDIA GPU's
# VGA and 3D controller functions while its driver is bound.
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF
}

# A missing NVIDIA module means a black screen at the first boot, so stop here instead.
step_graphics() {
  _graphics_nvidia || return 0
  # Runtime D3 needs Turing or newer, which the current branch is for.
  if graphics_hybrid && [[ $(graphics_nvidia_branch) == current ]]; then _graphics_rtd3; fi
  ((!GI_DRY_RUN)) || return 0
  compgen -G "$GI_TARGET/lib/modules/*/video/nvidia.ko*" > /dev/null ||
    die "x11-drivers/nvidia-drivers is installed, but its kernel module isn't in /lib/modules/*/video/. Reinstall it with: emerge --oneshot x11-drivers/nvidia-drivers"
}
