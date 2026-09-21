#!/bin/bash

if [ -n "$NO_COLOR" ]; then
	C_RESET=; C_DIM=; C_BOLD=; C_OK=; C_WARN=; C_ERR=
else
	C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
	C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
fi

STEP_N=0
STEP_WIDTH=58

banner() {
	printf '\n%s  %s%s\n%s  %s%s\n\n' \
		"$C_BOLD" "$1" "$C_RESET" \
		"$C_DIM" "$(printf '─%.0s' $(seq 1 $((${#1} + 2))))" "$C_RESET"
}

step() {
	STEP_N=$((STEP_N + 1))
	printf '  %s%2d.%s ' "$C_DIM" "$STEP_N" "$C_RESET"
	if [ $((${#1} + 1)) -le "$STEP_WIDTH" ]; then
		printf '%s ' "$1"
		printf '%s%s%s ' "$C_DIM" "$(printf '·%.0s' $(seq 1 $((STEP_WIDTH - ${#1}))))" "$C_RESET"
	else
		printf '%s\n     ' "$1"
	fi
	printf '%s' "$C_DIM"
}
ok()   { if [ -n "$1" ]; then printf '%s✓%s %s(%s)%s\n' "$C_OK" "$C_RESET" "$C_DIM" "$1" "$C_RESET"; else printf '%s✓%s\n' "$C_OK" "$C_RESET"; fi; }
warn() { printf '%s!%s %s%s%s\n' "$C_WARN" "$C_RESET" "$C_DIM" "$1" "$C_RESET"; }
fail() { printf '%s✗%s %s\n' "$C_ERR" "$C_RESET" "$1"; exit 1; }
note()  { printf '     %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
field() { printf '  %s%-9s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

group() {
	local n="$1" out=""
	while [ ${#n} -gt 3 ]; do
		out=",${n: -3}${out}"
		n="${n:0:${#n}-3}"
	done
	printf '%s%s' "$n" "$out"
}

summary() {
	printf '\n  %s✓%s %s%s%s\n' "$C_OK" "$C_RESET" "$C_BOLD$C_OK" "$1" "$C_RESET"
	[ -n "$2" ] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_RESET"
	printf '\n'
}

[ ! -f /ip2location.conf ] && fail "Missing configuration file."

banner "IP2Location Database Update"

USER_AGENT="Mozilla/5.0+(compatible; IP2Location/PostgreSQL-Docker; https://hub.docker.com/r/ip2location/postgresql)"
TOKEN=$(grep '^TOKEN=' /ip2location.conf | cut -d= -f2-)
CODE=$(grep '^CODE=' /ip2location.conf | cut -d= -f2-)
CODE_INPUT="$CODE"
IP_TYPE=$(grep '^IP_TYPE=' /ip2location.conf | cut -d= -f2-)

CODE=$(echo $CODE | sed 's/-//')

if [ "$IP_TYPE" == "IPV6" ]; then
	IP_TYPE="IPV6"
	SUFFIX="CSVIPV6"
else
	[ -n "$IP_TYPE" ] && [ "$IP_TYPE" != "IPV4" ] && echo " > IP_TYPE '$IP_TYPE' is not recognised, using IPV4."
	IP_TYPE="IPV4"
	SUFFIX="CSV"
fi

rm -rf /_tmp && mkdir /_tmp && cd /_tmp

# The setup script leaves PostgreSQL running, but a container that was stopped
# and started again comes back with the cluster down.
service postgresql start > /dev/null 2>&1

step "Download IP2Location $IP_TYPE database"

ARCHIVE="database.zip"
wget -qO "$ARCHIVE" --user-agent="$USER_AGENT" "https://www.ip2location.com/download?token=${TOKEN}&code=${CODE}${SUFFIX}" > /dev/null 2>&1

[ ! -z "$(grep 'NO PERMISSION' "$ARCHIVE")" ] && fail "DENIED"
[ ! -z "$(grep '5 TIMES' "$ARCHIVE")" ] && fail "QUOTA EXCEEDED"

unzip -t "$ARCHIVE" >/dev/null 2>&1

[ $? -ne 0 ] && fail "FILE CORRUPTED"

ok

CSV=$(unzip -l "$ARCHIVE" | sort -nr | grep -Eio 'IP(V6)?.*CSV' | head -n 1)

step "Decompress $CSV from $ARCHIVE"

FIRST="$(unzip -p "$ARCHIVE" "$CSV" 2>/dev/null | head -n 1)"

# The table keeps no ip_from column, so the CSV's leading field has to be
# dropped. Neither LOAD DATA nor COPY can skip a column, and handing a loader
# one field too many shifts every column one position to the left -- silently
# in MariaDB, and as a hard failure in PostgreSQL. Strip it here instead,
# streaming straight out of the archive so no second copy is written.
[ -z "$(echo "$FIRST" | grep -E '^"?[0-9]+"?,')" ] && fail "Unexpected CSV layout: $FIRST"

unzip -p "$ARCHIVE" "$CSV" | sed -E 's/^"?[0-9]+"?,//' > "$CSV"

if [ ! -f "$CSV" ]; then
	fail "ERROR"
fi

ok

step "Create table \"ip2location_database_tmp\""

RESPONSE="$(sudo -u postgres psql -c 'DROP TABLE IF EXISTS ip2location_database_tmp;' ip2location_database 2>&1)"

[ ! -z "$(echo $RESPONSE | grep 'ERROR')" ] && fail "$RESPONSE"

case "$CODE" in
	DB1|DB1LITE )
		FIELDS=''
	;;

	DB2 )
		FIELDS=',isp varchar(255) NOT NULL'
	;;

	DB3|DB3LITE )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL'
	;;

	DB4 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,isp varchar(255) NOT NULL'
	;;

	DB5|DB5LITE )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL'
	;;

	DB6 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,isp varchar(255) NOT NULL'
	;;

	DB7 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL'
	;;

	DB8 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL'
	;;

	DB9|DB9LITE )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL'
	;;

	DB10 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL'
	;;

	DB11|DB11LITE )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL'
	;;

	DB12 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL'
	;;

	DB13 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,time_zone varchar(8) NULL DEFAULT NULL,net_speed varchar(8) NOT NULL'
	;;

	DB14 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL'
	;;

	DB15 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL'
	;;

	DB16 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL'
	;;

	DB17 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,time_zone varchar(8) NULL DEFAULT NULL,net_speed varchar(8) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL'
	;;

	DB18 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL'
	;;

	DB19 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL'
	;;

	DB20 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL'
	;;

	DB21 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,elevation integer NOT NULL'
	;;

	DB22 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL,elevation integer NOT NULL'
	;;

	DB23 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL,usage_type varchar(11) NOT NULL'
	;;

	DB24 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL,elevation integer NOT NULL,usage_type varchar(11) NOT NULL'
	;;

	DB25 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL,elevation integer NOT NULL,usage_type varchar(11) NOT NULL,address_type char(1) NOT NULL,category varchar(10) NOT NULL'
	;;

	DB26 )
		FIELDS=',region_name varchar(128) NOT NULL,city_name varchar(128) NOT NULL,latitude varchar(20) NOT NULL,longitude varchar(20) NOT NULL,zip_code varchar(30) NULL DEFAULT NULL,time_zone varchar(8) NULL DEFAULT NULL,isp varchar(255) NOT NULL,domain varchar(128) NOT NULL,net_speed varchar(8) NOT NULL,idd_code varchar(5) NOT NULL,area_code varchar(30) NOT NULL,weather_station_code varchar(10) NOT NULL,weather_station_name varchar(128) NOT NULL,mcc varchar(128) NULL DEFAULT NULL,mnc varchar(128) NULL DEFAULT NULL,mobile_brand varchar(128) NULL DEFAULT NULL,elevation integer NOT NULL,usage_type varchar(11) NOT NULL,address_type char(1) NOT NULL,category varchar(10) NOT NULL,district varchar(128) NOT NULL,asn varchar(10) NOT NULL,"as" varchar(256) NOT NULL,"as_domain" varchar(128) NOT NULL,"as_usage_type" varchar(11) NOT NULL,"as_cidr" varchar(43) NOT NULL'
	;;
esac

RESPONSE="$(sudo -u postgres psql -c 'CREATE TABLE ip2location_database_tmp (ip_to decimal(39,0) NOT NULL,country_code character(2) NOT NULL,country_name varchar(64) NOT NULL '"$FIELDS"', CONSTRAINT idx_tmp_key PRIMARY KEY (ip_to));' ip2location_database 2>&1)"

[ -z "$(echo "$RESPONSE" | grep -E '^CREATE TABLE')" ] && fail "$RESPONSE" || ok

step "Load $CSV into database"

RESPONSE="$(sudo -u postgres psql -c '\copy ip2location_database_tmp FROM '\''/_tmp/'"$CSV"''\'' WITH (FORMAT csv, QUOTE '\''"'\'')' ip2location_database 2>&1)"

[ -z "$(echo "$RESPONSE" | grep -E '^COPY [0-9]')" ] && fail "$RESPONSE" || ok

step "Verify the new table"

ROWS="$(sudo -u postgres psql -t -A -c 'SELECT COUNT(*) FROM ip2location_database_tmp' ip2location_database 2>&1)"

[ -n "$ROWS" ] && [ "$ROWS" -gt 0 ] 2>/dev/null && ok "$(group "$ROWS") records" || fail "The downloaded database has no rows; the existing table was left untouched."

step "Activate ip2location_database"

RESPONSE="$(sudo -u postgres psql -c 'BEGIN; DROP TABLE IF EXISTS ip2location_database; ALTER TABLE ip2location_database_tmp RENAME TO ip2location_database; ALTER INDEX idx_tmp_key RENAME TO idx_key; COMMIT;' ip2location_database 2>&1)"

[ ! -z "$(echo $RESPONSE | grep 'ERROR')" ] && fail "$RESPONSE" || ok

rm -rf /_tmp

summary "Update completed" "$CODE_INPUT ($IP_TYPE) refreshed"
field "Database" "ip2location_database"
note "The previous table was dropped only after the new one finished loading."
printf '\n'
