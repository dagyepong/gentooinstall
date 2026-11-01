#!/usr/bin/env bats
# Tests for lib/steps/graphics.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  gi_setup
  gi_load core ui state config graphics
  HW[gpus]=intel
  VC=$GI_TARGET/etc/portage/package.use/00video_cards
  LIC=$GI_TARGET/etc/portage/package.license/nvidia-drivers
  MASK=$GI_TARGET/etc/portage/package.mask/nvidia-drivers
  GI_HOST_ROOT=$BATS_TEST_TMPDIR/host
  mkdir -p "$GI_HOST_ROOT/sys/bus/pci/devices"
}

# Adds a PCI device to the fake /sys: SLOT VENDOR DEVICE CLASS.
pci_dev() {
  local d=$GI_HOST_ROOT/sys/bus/pci/devices/$1
  mkdir -p "$d"
  echo "$2" > "$d/vendor"
  echo "$3" > "$d/device"
  echo "$4" > "$d/class"
}

@test "binary packages keep the profile's VIDEO_CARDS for Intel, AMD and nouveau" {
  HW[gpus]="intel amd nvidia"
  CFG[nvidia_driver]=nouveau
  cfg_defaults_apply
  step_graphics_portage
  [ ! -e "$VC" ]
  [ ! -e "$LIC" ]
  run step_graphics_packages
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "proprietary NVIDIA on binary packages adds nvidia and its license, but no USE flags that rebuild ffmpeg" {
  HW[gpus]="intel nvidia"
  pci_dev 0000:01:00.0 0x10de 0x2860 0x030200
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: nvidia' ]
  [ "$(cat "$LIC")" = 'x11-drivers/nvidia-drivers NVIDIA-2025' ]
  [ ! -e "$MASK" ]
  run step_graphics_packages
  # Intel beside it makes it a hybrid laptop.
  [ "$output" = $'x11-drivers/nvidia-drivers\nx11-misc/prime-run' ]
}

@test "tune narrows VIDEO_CARDS to a hybrid Intel and NVIDIA laptop" {
  HW[gpus]="intel nvidia"
  CFG[tune]=yes
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$VC")" = $'*/* VIDEO_CARDS: -* intel nvidia\n*/* nvidia vdpau nvenc' ]
  [ -f "$LIC" ]
}

@test "binary packages off: AMD gets amdgpu radeonsi and Mesa's VA-API" {
  HW[gpus]=amd
  CFG[binpkgs]=no
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$VC")" = $'*/* VIDEO_CARDS: -* amdgpu radeonsi\nmedia-libs/mesa vaapi' ]
  [ ! -e "$LIC" ]
}

@test "tune with nouveau and a virtual GPU" {
  HW[gpus]="nvidia virtual"
  CFG[tune]=yes CFG[nvidia_driver]=nouveau
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: -* nouveau virgl' ]
  run step_graphics_packages
  [ -z "$output" ]
}

@test "tune with Intel only" {
  CFG[tune]=yes
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: -* intel' ]
}

@test "tune without a detected GPU keeps the profile default" {
  HW[gpus]=''
  CFG[tune]=yes
  cfg_defaults_apply
  step_graphics_portage
  [ ! -e "$VC" ]
}

@test "a rerun after switching to nouveau removes the NVIDIA files" {
  HW[gpus]="intel nvidia"
  cfg_defaults_apply
  step_graphics_portage
  [ -f "$VC" ]
  CFG[nvidia_driver]=nouveau
  step_graphics_portage
  [ ! -e "$VC" ]
  [ ! -e "$LIC" ]
}

@test "running the hook twice gives the same files" {
  HW[gpus]="amd nvidia"
  CFG[tune]=yes
  cfg_defaults_apply
  step_graphics_portage
  first=$(cat "$VC" "$LIC")
  step_graphics_portage
  [ "$(cat "$VC" "$LIC")" = "$first" ]
}

@test "dry-run prints the files and writes nothing" {
  HW[gpus]=nvidia
  cfg_defaults_apply
  GI_DRY_RUN=1
  run --separate-stderr step_graphics_portage
  [ "$status" -eq 0 ]
  [ ! -e "$VC" ]
  [ ! -e "$LIC" ]
  [[ $stderr == *'*/* VIDEO_CARDS: nvidia'* ]]
}

@test "step fails when the NVIDIA kernel module is missing" {
  HW[gpus]=nvidia
  cfg_defaults_apply
  run -1 step_graphics
  [[ $output == *"kernel module"* ]]
}

@test "step passes when the NVIDIA kernel module is installed" {
  HW[gpus]=nvidia
  cfg_defaults_apply
  mkdir -p "$GI_TARGET/lib/modules/6.12.1-gentoo-dist/video"
  touch "$GI_TARGET/lib/modules/6.12.1-gentoo-dist/video/nvidia.ko.xz"
  step_graphics
}

@test "step skips the module check for nouveau and in dry-run" {
  HW[gpus]=nvidia
  CFG[nvidia_driver]=nouveau
  cfg_defaults_apply
  step_graphics
  CFG[nvidia_driver]=proprietary
  GI_DRY_RUN=1
  step_graphics
}

@test "a pre-Turing NVIDIA GPU gets the 580 branch, and the mask goes when it's no longer needed" {
  HW[gpus]="intel nvidia"
  pci_dev 0000:00:02.0 0x8086 0x5917 0x030000
  pci_dev 0000:01:00.0 0x10de 0x1c8d 0x030200 # GP107M, GeForce GTX 1050 Mobile
  pci_dev 0000:01:00.1 0x10de 0x0fb9 0x040300 # its audio function, not a GPU
  cfg_defaults_apply
  step_graphics_portage
  [ "$(cat "$MASK")" = '>=x11-drivers/nvidia-drivers-581' ]
  [ -f "$LIC" ]
  run step_graphics_packages
  # Intel beside it makes it a hybrid laptop.
  [ "$output" = $'x11-drivers/nvidia-drivers\nx11-misc/prime-run' ]
  CFG[nvidia_driver]=nouveau
  step_graphics_portage
  [ ! -e "$MASK" ]
}

@test "Maxwell is the oldest generation on the 580 branch; Turing needs no mask" {
  HW[gpus]=nvidia
  cfg_defaults_apply
  pci_dev 0000:01:00.0 0x10de 0x1340 0x030000 # GM108M, the lowest Maxwell ID
  step_graphics_portage
  [ -f "$MASK" ]
  echo 0x1e02 > "$GI_HOST_ROOT/sys/bus/pci/devices/0000:01:00.0/device" # TU102, the lowest Turing ID
  step_graphics_portage
  [ ! -e "$MASK" ]
}

@test "a Kepler NVIDIA GPU falls back to nouveau with a warning" {
  HW[gpus]="intel nvidia"
  pci_dev 0000:01:00.0 0x10de 0x1180 0x030000 # GK104, GeForce GTX 680
  cfg_defaults_apply
  run --separate-stderr step_graphics_portage
  [ "$status" -eq 0 ]
  [[ $stderr == *"Kepler"*"nouveau"* ]]
  [ ! -e "$VC" ]
  [ ! -e "$LIC" ]
  [ ! -e "$MASK" ]
  run step_graphics_packages
  [ -z "$output" ]
  step_graphics
  CFG[tune]=yes
  step_graphics_portage 2> /dev/null
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: -* intel nouveau' ]
}

@test "a VMware or VirtualBox VMSVGA guest gets Mesa's vmware driver; other VMs get virgl" {
  HW[gpus]=virtual
  CFG[binpkgs]=no
  cfg_defaults_apply
  pci_dev 0000:00:01.0 0x1af4 0x1050 0x030000 # virtio GPU
  pci_dev 0000:00:03.0 0x15ad 0x07b0 0x020000 # vmxnet3, a VMware NIC QEMU can emulate, not a GPU
  step_graphics_portage
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: -* virgl' ]
  rm -r "$GI_HOST_ROOT/sys/bus/pci/devices/0000:00:01.0"
  pci_dev 0000:00:0f.0 0x15ad 0x0405 0x030000 # SVGA II, VMware's GPU and VirtualBox's VMSVGA
  step_graphics_portage
  [ "$(cat "$VC")" = '*/* VIDEO_CARDS: -* vmware' ]
}

@test "a hybrid laptop with NVIDIA's driver gets prime-run and runtime power management" {
  local opt=$GI_TARGET/etc/modprobe.d/nvidia-pm.conf rules=$GI_TARGET/etc/udev/rules.d/80-nvidia-pm.rules
  HW[gpus]="intel nvidia"
  cfg_defaults_apply
  mkdir -p "$GI_TARGET/lib/modules/6.18.1/video"
  touch "$GI_TARGET/lib/modules/6.18.1/video/nvidia.ko"
  pci_dev 0000:01:00.0 0x10de 0x1f91 0x030200 # GTX 1650 Mobile, Turing
  [ "$(step_graphics_packages | tr '\n' ' ')" = 'x11-drivers/nvidia-drivers x11-misc/prime-run ' ]
  step_graphics
  [ "$(cat "$opt")" = 'options nvidia NVreg_DynamicPowerManagement=0x02' ]
  [ "$(grep -c 'ATTR{vendor}=="0x10de"' "$rules")" -eq 4 ]
  # Ampere and later have it on by default, so only the udev rules.
  rm "$opt" "$rules"
  echo 0x2520 > "$GI_HOST_ROOT/sys/bus/pci/devices/0000:01:00.0/device" # RTX 3060 Mobile
  step_graphics
  [ ! -e "$opt" ]
  [ -e "$rules" ]
  # Pascal, on the 580 branch, has no runtime D3.
  rm "$rules"
  echo 0x1c8d > "$GI_HOST_ROOT/sys/bus/pci/devices/0000:01:00.0/device" # GTX 1050 Mobile
  step_graphics
  [ ! -e "$rules" ]
  [[ $(step_graphics_packages) == *prime-run* ]]
  # A desktop PC with only the NVIDIA GPU, or with nouveau, isn't hybrid.
  HW[gpus]=nvidia
  [ "$(step_graphics_packages)" = x11-drivers/nvidia-drivers ]
  HW[gpus]="intel nvidia" CFG[nvidia_driver]=nouveau
  [ -z "$(step_graphics_packages)" ]
}
