# Runs as root. MYRCH_USER, MYRCH_HOME and MYRCH_MODULES are set.

visudo -cqf /etc/sudoers.d/10-wheel || die "sudoers.d/10-wheel is invalid"
chmod 0440 /etc/sudoers.d/10-wheel

if [[ $(getent passwd "$MYRCH_USER" | cut -d: -f7) != "$USER_SHELL" ]]; then
	usermod -s "$USER_SHELL" "$MYRCH_USER"
fi
