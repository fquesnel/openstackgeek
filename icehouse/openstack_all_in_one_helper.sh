function mysql_secure_installation_helper {
mysql_secure_installation <<EOF
MY_SQL_PASSWORD
n
y
y
y
y
EOF
}
