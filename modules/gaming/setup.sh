# 32-bit Vulkan drivers matching the GPU modules on this machine.
lib32=()
has_module gpu-intel && lib32+=(lib32-vulkan-intel)
has_module gpu-amd && lib32+=(lib32-vulkan-radeon)
has_module gpu-nvidia && lib32+=(lib32-nvidia-utils)
has_module gpu-nouveau && lib32+=(lib32-vulkan-nouveau)
if ((${#lib32[@]})); then
	pacman -S --needed --noconfirm "${lib32[@]}"
fi
