if [[ ! -d /var/lib/mysql/mysql ]]; then
	mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
fi
