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
	local label="$1"

	[ ${#label} -gt "$STEP_WIDTH" ] && label="${label:0:$((STEP_WIDTH - 3))}..."

	local pad=$((STEP_WIDTH - ${#label})) dots=""
	[ $pad -gt 0 ] && dots="$(printf '·%.0s' $(seq 1 $pad))"

	printf '%s %s%s%s ' "$label" "$C_DIM" "$dots" "$C_RESET"
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

USER_AGENT="Mozilla/5.0+(compatible; IP2Location/PostgreSQL-Docker; https://hub.docker.com/r/ip2location/postgresql)"
CODES=(DB1-LITE DB3-LITE DB5-LITE DB9-LITE DB11-LITE DB1 DB2 DB3 DB4 DB5 DB6 DB7 DB8 DB9 DB10 DB11 DB12 DB13 DB14 DB15 DB16 DB17 DB18 DB19 DB20 DB21 DB22 DB23 DB24 DB25 DB26)

trim() { local v="${1//$'\r'/}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

TOKEN="$(trim "$TOKEN")"
CODE="$(trim "$CODE")"
IP_TYPE="$(trim "$IP_TYPE")"
CODE_INPUT="$CODE"

PSQL_VERSION=$(psql -V | awk '{ print $3 }' | cut -d. -f1)
PG_CONF="/etc/postgresql/$PSQL_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PSQL_VERSION/main/pg_hba.conf"

if [ -f "$PG_HBA" ] && [ -z "$(grep '0.0.0.0' "$PG_HBA")" ]; then
	sed -i 's/^\#listen_addresses.*/listen_addresses = '\''*'\''/g' "$PG_CONF"
	echo "host	all	all	0.0.0.0/0	md5" >> "$PG_HBA"
fi

if [ -f /ip2location.conf ]; then
	CONF_TOKEN="$(grep '^TOKEN=' /ip2location.conf | cut -d= -f2-)"
	CONF_CODE="$(grep '^CODE=' /ip2location.conf | cut -d= -f2-)"
	CONF_IP_TYPE="$(grep '^IP_TYPE=' /ip2location.conf | cut -d= -f2-)"
	CONF_PASSWORD="$(grep '^POSTGRESQL_PASSWORD=' /ip2location.conf | cut -d= -f2-)"

	if [ -n "$CODE_INPUT" ] && [ "$CODE_INPUT" != "$CONF_CODE" ]; then
		echo " > NOTE: CODE has changed from '$CONF_CODE' to '$CODE_INPUT', but the database"
		echo " >       is already installed. The existing data is kept. To install"
		echo " >       '$CODE_INPUT' instead, start a fresh container with an empty volume."
	fi
	if [ -n "$TOKEN" ] && [ "$TOKEN" != "$CONF_TOKEN" ]; then
		echo " > NOTE: TOKEN has changed but is not re-applied to an existing install."
	fi
	if [ -n "$IP_TYPE" ] && [ "$IP_TYPE" != "$CONF_IP_TYPE" ]; then
		echo " > NOTE: IP_TYPE has changed from '$CONF_IP_TYPE' to '$IP_TYPE', but the"
		echo " >       database is already installed and is not converted in place."
		echo " >       To install '$IP_TYPE', start a fresh container with an empty volume."
	fi
	if [ -n "$POSTGRESQL_PASSWORD" ] && [ "$POSTGRESQL_PASSWORD" != "$CONF_PASSWORD" ]; then
		echo " > NOTE: POSTGRESQL_PASSWORD has changed but the existing password is kept."
		echo " >       Change it with: ALTER USER postgres WITH PASSWORD '...';"
	fi

	service postgresql start >/dev/null 2>&1
	tail -f /dev/null
fi

[ -z "$TOKEN" ] && fail "Missing download token. Pass it with -e TOKEN=..."
[ -z "$CODE" ] && fail "Missing database code. Pass it with -e CODE=... (e.g. DB1-LITE)"

if [ -z "$POSTGRESQL_PASSWORD" ]; then
	POSTGRESQL_PASSWORD="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-12})"
fi

FOUND=""
for i in "${CODES[@]}"; do
	if [ "$i" == "$CODE" ] ; then
		FOUND="$CODE"
	fi
done

if [ -z "$FOUND" ]; then
	fail "Download code '$CODE' is invalid. See the README for the list of supported codes."
fi

CODE=$(echo $CODE | sed 's/-//')

if [ "$IP_TYPE" == "IPV6" ]; then
	IP_TYPE="IPV6"
	SUFFIX="CSVIPV6"
else
	[ -n "$IP_TYPE" ] && [ "$IP_TYPE" != "IPV4" ] && echo " > IP_TYPE '$IP_TYPE' is not recognised, using IPV4."
	IP_TYPE="IPV4"
	SUFFIX="CSV"
fi

banner "IP2Location Database Setup"
field "Database" "ip2location_database"
field "Code" "$CODE_INPUT"
field "IP type" "$IP_TYPE"

step "Create directory /_tmp"

rm -rf /_tmp
mkdir /_tmp

[ ! -d /_tmp ] && fail "ERROR" || ok
cd /_tmp

step "Download IP2Location $IP_TYPE database"

ARCHIVE="/_tmp/database.zip"

wget -O "$ARCHIVE" -q --user-agent="$USER_AGENT" "https://www.ip2location.com/download?token=${TOKEN}&code=${CODE}${SUFFIX}" > /dev/null 2>&1

[ ! -z "$(grep 'NO PERMISSION' "$ARCHIVE")" ] && fail "DENIED"
[ ! -z "$(grep '5 TIMES' "$ARCHIVE")" ] && fail "QUOTA EXCEEDED"

unzip -t "$ARCHIVE" >/dev/null 2>&1

[ $? -ne 0 ] && fail "FILE CORRUPTED"

ok
CSV=$(unzip -l "$ARCHIVE" | sort -nr | grep -Eio 'IP(V6)?.*CSV' | head -n 1)

step "Decompress the downloaded archive"

FIRST="$(unzip -p "$ARCHIVE" "$CSV" 2>/dev/null | head -n 1)"

[ -z "$(echo "$FIRST" | grep -E '^"?[0-9]+"?,')" ] && fail "Unexpected CSV layout: $FIRST"

unzip -p "$ARCHIVE" "$CSV" | sed -E 's/^"?[0-9]+"?,//' > "$CSV"

[ ! -f "/_tmp/$CSV" ] && fail "ERROR"

ok
service postgresql start >/dev/null

step "Create database \"ip2location_database\""

RESPONSE="$(sudo -u postgres createdb ip2location_database 2>&1)"

[ ! -z "$(echo $RESPONSE | grep 'FATAL')" ] && fail "$RESPONSE" || ok
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

RESPONSE="$(sudo -u postgres psql -c 'CREATE TABLE ip2location_database_tmp (ip_to decimal(39,0) NOT NULL,country_code character(2) NOT NULL,country_name varchar(64) NOT NULL '"$FIELDS"', CONSTRAINT idx_key PRIMARY KEY (ip_to));' ip2location_database 2>&1)"

[ -z "$(echo "$RESPONSE" | grep -E '^CREATE TABLE')" ] && fail "$RESPONSE" || ok

step "Load the CSV into the database"

RESPONSE="$(sudo -u postgres psql -c '\copy ip2location_database_tmp FROM '\''/_tmp/'"$CSV"''\'' WITH (FORMAT csv, QUOTE '\''"'\'')' ip2location_database 2>&1)"

[ -z "$(echo "$RESPONSE" | grep -E '^COPY [0-9]')" ] && fail "$RESPONSE" || ok
step "Activate ip2location_database"

RESPONSE="$(sudo -u postgres psql -c 'DROP TABLE IF EXISTS ip2location_database; ALTER TABLE ip2location_database_tmp RENAME TO ip2location_database;' ip2location_database 2>&1)"

[ ! -z "$(echo $RESPONSE | grep 'ERROR')" ] && fail "$RESPONSE" || ok
step "Create function \"IP_ATON\""

cat > /_tmp/ip_aton.sql << 'SQL'
CREATE OR REPLACE FUNCTION IP_ATON(ip inet) RETURNS numeric AS $$
DECLARE h text; r numeric := 0;
BEGIN
	IF family(ip) = 4 THEN RETURN host(ip)::inet - '0.0.0.0'::inet; END IF;
	-- inet_send() prefixes a 4-byte header; the address is the remaining 16 bytes.
	h := substr(encode(inet_send(ip), 'hex'), 9);
	FOR i IN 1..4 LOOP
		r := r * 4294967296 + ('x' || substr(h, i*8-7, 8))::bit(32)::bigint;
	END LOOP;
	RETURN r;
END $$ LANGUAGE plpgsql IMMUTABLE;

GRANT execute ON FUNCTION IP_ATON(inet) TO public;
SQL

RESPONSE="$(sudo -u postgres psql -q -d ip2location_database -f /_tmp/ip_aton.sql 2>&1)"
RESPONSE="$RESPONSE$(sudo -u postgres psql -t -A -d ip2location_database -c "SELECT IP_ATON('8.8.8.8'::inet)" 2>&1)"

[ "$(echo $RESPONSE | tr -d ' ')" == "134744072" ] && ok || fail "$RESPONSE"

sudo -u postgres psql -d postgres -c "ALTER USER postgres WITH PASSWORD '$POSTGRESQL_PASSWORD';" > /dev/null

banner "IP2Location Database Ready"
ROWS="$(sudo -u postgres psql -t -A -d ip2location_database -c 'SELECT COUNT(*) FROM ip2location_database' 2>/dev/null)"
summary "Setup completed" "$(group "$ROWS") records loaded from $CODE_INPUT ($IP_TYPE)"
field "Host" "ip2location"
field "Database" "ip2location_database"
field "User" "postgres"
field "Password" "$POSTGRESQL_PASSWORD"
printf '\n  %spsql -h ip2location -U postgres -d ip2location_database%s\n' "$C_DIM" "$C_RESET"
printf '\n'

rm -rf /_tmp

echo "POSTGRESQL_PASSWORD=$POSTGRESQL_PASSWORD" > /ip2location.conf
echo "TOKEN=$TOKEN" >> /ip2location.conf
echo "CODE=$CODE_INPUT" >> /ip2location.conf
echo "IP_TYPE=$IP_TYPE" >> /ip2location.conf

cd /

service postgresql start >/dev/null 2>&1

tail -f /dev/null
