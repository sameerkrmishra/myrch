# Keep nouveau out of the initramfs: drop the kms hook.
if grep -qE '^HOOKS=.*\bkms\b' /etc/mkinitcpio.conf; then
	sed -i -E '/^HOOKS=/ s/ kms\b//' /etc/mkinitcpio.conf
	mkinitcpio -P
fi
