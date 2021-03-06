#!/bin/bash

ZLLDB=""
MAINUSER=$(getent passwd 1000 | cut -d: -f1)
DECONZ_CONF_DIR="/home/$MAINUSER/.local/share"
DECONZ_PORT=
BRIDGEID=
LAST_MAX_TIMESTAMP=0
RC=1		# return code of function calls
TIMEOUT=0      # main loop iteration timeout, can be controlled by SIGUSR1
LOG_LEVEL=6

LOG_EMERG=
LOG_ALERT=
LOG_CRIT=
LOG_ERROR=
LOG_WARN=
LOG_NOTICE=
LOG_INFO=
LOG_DEBUG=

[[ $LOG_LEVEL -ge 0 ]] && LOG_EMERG="<0>"
[[ $LOG_LEVEL -ge 1 ]] && LOG_ALERT="<1>"
[[ $LOG_LEVEL -ge 2 ]] && LOG_CRIT="<2>"
[[ $LOG_LEVEL -ge 3 ]] && LOG_ERROR="<3>"
[[ $LOG_LEVEL -ge 4 ]] && LOG_WARN="<4>"
[[ $LOG_LEVEL -ge 5 ]] && LOG_NOTICE="<5>"
[[ $LOG_LEVEL -ge 6 ]] && LOG_INFO="<6>"
[[ $LOG_LEVEL -ge 7 ]] && LOG_DEBUG="<7>"

function init {
    # is sqlite3 installed?
	sqlite3 --version &> /dev/null
	if [ $? -ne 0 ]; then
		[[ $LOG_WARN ]] && echo "${LOG_WARN}sqlite3 not installed"
		return
	fi

	# look for latest config in specific order
	drs=("data/dresden-elektronik/deCONZ/zll.db" "dresden-elektronik/deCONZ/zll.db" "deCONZ/zll.db")
	for i in "${drs[@]}"; do
		if [ -f "${DECONZ_CONF_DIR}/$i" ]; then
			ZLLDB="${DECONZ_CONF_DIR}/$i"
			break
		fi
	done

	if [ ! -f "$ZLLDB" ]; then
		# might have been deleted
		ZLLDB=""
	fi

	if [[ -z "$ZLLDB" ]]; then
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}no database file (zll.db) found"
		return
	fi

	# get deCONZ REST-API port
	local value=$(sqlite3 $ZLLDB "select value from config2 where key=\"port\"")
	if [ $? -ne 0 ]; then
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}no deCONZ port found in database"
		return
	fi

	if [[ -n $value ]]; then
		DECONZ_PORT=$value
		[[ $LOG_INFO ]] && echo "${LOG_INFO}use deCONZ port $DECONZ_PORT"
	fi

	# get bridgeid
	local value=$(sqlite3 $ZLLDB "select value from config2 where key=\"bridgeid\"")
	if [ $? -ne 0 ]; then
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}no bridgeid found in database"
		return
	fi

	if [[ -n $value ]]; then
		BRIDGEID=$value
		[[ $LOG_INFO ]] && echo "${LOG_INFO}use bridgeid $BRIDGEID"
	fi
}

function addUser() {
	local json="{\"devicetype\":\"homebridge-hue#deconz\"}"
	curl --noproxy '*' -s -o /dev/null -d "$json" -X POST http://127.0.0.1:${DECONZ_PORT}/api
}

function checkNewDevices() {
	local max_timestamp=0
	local proceed=false
	local changed=false

	while [[ $proceed == false ]]
	do
		RC=1
		while [ $RC -ne 0 ]; do
			max_timestamp=$(sqlite3 $ZLLDB "select timestamp from devices order by timestamp DESC limit 1")
			RC=$?
			if [ $RC -ne 0 ]; then
				[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error reading timestamp from db"
				sleep 2
			fi
		done
		if [ $LAST_MAX_TIMESTAMP -eq 0 ]; then
			# skip first run
			LAST_MAX_TIMESTAMP=$max_timestamp
			return
		fi
		if [[ "$max_timestamp" -ne "$LAST_MAX_TIMESTAMP" ]]; then
			# there is a new light discovered by deCONZ
			[[ $LOG_INFO ]] && echo "${LOG_INFO} new light discovered by deCONZ - wait 30 sec for more lights"
			if [ -n "$max_timestamp" ]; then
				LAST_MAX_TIMESTAMP=$max_timestamp
				changed=true
			fi
			sleep 30
		else
			proceed=true
		fi
	done

	if [[ $changed == true ]]; then
		[[ $LOG_INFO ]] && echo "${LOG_INFO} all new lights discovered - restarting homebridge"
		pkill homebridge
		homebridge -U /home/$MAINUSER/.homebridge &
	fi
}

function checkHomebridge {

	local PROXY_ADDRESS=""
	local PROXY_PORT=""
	local HOMEBRIDGE=""
	local IP_ADDRESS=""
	local HOMEBRIDGE_PIN=""

	## get database config
	params=( [0]="homebridge" [1]="proxyaddress" [2]="proxyport" [3]="ipaddress" [4]="homebridge-pin")
	values=()

	for i in {0..4}; do
		param=${params[$i]}
		RC=1
		while [ $RC -ne 0 ]; do
			value=$(sqlite3 $ZLLDB "select value from config2 where key=\"${param}\"")
			RC=$?
			if [ $RC -ne 0 ]; then
				[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error reading parameter ${param} from db"
				sleep 2
			fi
		done

		# basic check for non empty
		if [[ ! -z "$value" ]]; then
			values[$i]=$(echo $value | cut -d'|' -f2)
		fi
	done

	## all parameters found and valid?
	if [ -z "${values[0]}" ]; then
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}missing parameter 'homebridge'"
		return
	fi
	if [ -z "${values[3]}" ]; then
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}missing parameter 'ipaddress'"
		return
	fi

	HOMEBRIDGE="${values[0]}" # disabled | managed | not-managed
	PROXY_ADDRESS="${values[1]}"
	PROXY_PORT="${values[2]}"
	IP_ADDRESS="${values[3]}"
	HOMEBRIDGE_PIN="${values[4]}"

	if [[ "$HOMEBRIDGE" == "disabled" ]]; then
		systemctl -q is-active homebridge
		if [ $? -eq 0 ]; then
			systemctl stop homebridge
			systemctl disable homebridge
		fi
		pkill homebridge
		return
	fi

	## check if apikey already exist or create a new apikey for homebridge apps
	RC=1
	while [ $RC -ne 0 ]; do
		local HOMEBRIDGE_AUTH=$(sqlite3 $ZLLDB "select * from auth where devicetype like 'homebridge-hue#%' limit 1")
		RC=$?
		if [ $RC -ne 0 ]; then
			[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error reading homebridge-hue auth db"
			sleep 2
		fi
	done
	if [[ $HOMEBRIDGE_AUTH == "" ]]; then
		# generate a new deconz apikey for homebridge-hue
		addUser
	else
		# homebridge-hue apikey exists
		if [ -z $(echo $HOMEBRIDGE_AUTH | grep deconz) ]; then
			if [[ "$HOMEBRIDGE" != "not-managed" ]]; then
				RC=1
				while [ $RC -ne 0 ]; do
					sqlite3 $ZLLDB "replace into config2 (key, value) values('homebridge', 'not-managed')" &> /dev/null
					RC=$?
					if [ $RC -ne 0 ]; then
						[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error setting homebridge to not-managed in db"
						sleep 2
					fi
				done
			fi
			[[ $LOG_INFO ]] && echo "${LOG_INFO}existing homebridge hue auth found"
        fi
	fi
	if [[ -z "$HOMEBRIDGE_PIN" ]]; then
		if [[ -f /home/$MAINUSER/.homebridge/config.json ]]; then
			local p=$(cat /home/$MAINUSER/.homebridge/config.json | grep "pin" | cut -d'"' -f4)
			local pin="${p:0:3}${p:4:2}${p:7:3}"
			# write pin from config.json in db
			RC=1
			while [ $RC -ne 0 ]; do
				sqlite3 $ZLLDB "replace into config2 (key, value) values('homebridge-pin', '${pin}')" &> /dev/null
				RC=$?
				if [ $RC -ne 0 ]; then
					[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error replace existing homebridge-pin into db"
					sleep 2
				fi
			done
		else
			# or create new pin and write it in db
			RC=1
			while [ $RC -ne 0 ]; do
				sqlite3 $ZLLDB "replace into config2 (key, value) values('homebridge-pin', ABS(RANDOM()) % (99999999 - 10000000) + 10000000)" &> /dev/null
				RC=$?
				if [ $RC -ne 0 ]; then
					[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error replace new homebridge-pin into db"
					sleep 2
				fi
			done
		fi
	fi

	## check installed components
	hb_installed=false
	hb_hue_installed=false
	node_installed=false
	npm_installed=false
	node_ver=""

	which homebridge &> /dev/null
	if [ $? -eq 0 ]; then
		hb_installed=true
		# look for homebridge-hue installation
		dirs=("/usr/local/lib/node_modules/" "/usr/lib/node_modules/")
		for i in "${dirs[@]}"; do
			if [ -d "$i/homebridge-hue" ]; then
				# homebridge-hue installation found
				hb_hue_installed=true
			fi
		done
	fi

	which nodejs &> /dev/null
	if [ $? -eq 0 ]; then
		node_installed=true
		# get version and strip it to only major part: v8.11.2 -> 8
		node_ver=$(nodejs --version | cut -d. -f1 | cut -c 2-)
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG} nodejs ver. $node_ver"
	fi

	if [[ $hb_installed = false || $hb_hue_installed = false || $node_installed = false ]]; then
		[[ $LOG_INFO ]] && echo "${LOG_INFO}check inet connectivity"

		curl --head --connect-timeout 20 -k https://www.phoscon.de &> /dev/null
		if [ $? -ne 0 ]; then
			if [[ ! -z "$PROXY_ADDRESS" && ! -z "$PROXY_PORT" && "$PROXY_ADDRESS" != "none" ]]; then
				export http_proxy="http://${PROXY_ADDRESS}:${PROXY_PORT}"
				export https_proxy="http://${PROXY_ADDRESS}:${PROXY_PORT}"
				[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}set proxy: ${PROXY_ADDRESS}:${PROXY_PORT}"
			else
				[[ $LOG_WARN ]] && echo "${LOG_WARN}no internet connection. Abort homebridge installation."
				return
			fi
		fi

		# install nodejs if not installed or if version < 8
		if [[ $node_installed = false ]]; then
			curl -sL https://deb.nodesource.com/setup_8.x | bash -
			if [ $? -eq 0 ]; then
				apt-get install -y nodejs
				if [ $? -ne 0 ]; then
					[[ $LOG_WARN ]] && echo "${LOG_WARN}could not install nodejs"
					return
				fi
			else
				[[ $LOG_WARN ]] && echo "${LOG_WARN}could not download node setup."
				return
			fi
		else
		    if [ $node_ver -lt 8 ]; then
			    curl -sL https://deb.nodesource.com/setup_8.x | bash -
				if [ $? -eq 0 ]; then
					apt-get install -y nodejs
					if [ $? -ne 0 ]; then
						[[ $LOG_WARN ]] && echo "${LOG_WARN}could not install nodejs"
						return
					fi
				else
					[[ $LOG_WARN ]] && echo "${LOG_WARN}could not download node setup."
					return
				fi
		    fi
		fi

		# install npm if not installed
		which npm
		if [ $? -eq 0 ]; then
			npm_installed=true
		fi

		if [[ $npm_installed = false ]]; then
			apt-get install -y npm
			if [ $? -ne 0 ]; then
				[[ $LOG_WARN ]] && echo "${LOG_WARN}could not install npm"
				return
			fi
		fi

		# install homebridge if not installed
		if [[ $hb_installed = false ]]; then
			npm -g install npm@latest
			if [ $? -eq 0 ]; then
				npm -g install homebridge --unsafe-perm
				if [ $? -ne 0 ]; then
					[[ $LOG_WARN ]] && echo "${LOG_WARN}could not install homebridge"
					return
				fi
			else
				[[ $LOG_WARN ]] && echo "${LOG_WARN}could not update npm"
				return
			fi
		fi

		# install homebridge-hue if not installed
		if [[ $hb_hue_installed = false ]]; then
			npm -g install homebridge-hue
			if [ $? -ne 0 ]; then
				[[ $LOG_WARN ]] && echo "${LOG_WARN}could not install homebridge hue"
				return
			fi
		fi
	fi

	RC=1
	while [ $RC -ne 0 ]; do
		APIKEY=$(sqlite3 $ZLLDB "select apikey from auth where devicetype like 'homebridge-hue#%' limit 1")
		RC=$?
		if [ $RC -ne 0 ]; then
			[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error reading apikey from db"
			sleep 2
		fi
	done

	# create config file if not exists
	if [[ -f /home/$MAINUSER/.homebridge/config.json ]]; then
		# existing config found
		[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}found existing homebridge config.json"
		if [ -z "$(cat /home/$MAINUSER/.homebridge/config.json | grep "Phoscon Homebridge")" ]; then
			# set to not-managed only if homebridge is not set up by phoscon
			if [[ "$HOMEBRIDGE" != "not-managed" ]]; then
				RC=1
				while [ $RC -ne 0 ]; do
					sqlite3 $ZLLDB "replace into config2 (key, value) values('homebridge', 'not-managed')" &> /dev/null
					RC=$?
					if [ $RC -ne 0 ]; then
						[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error setting homebridge to not-managed in db"
						sleep 2
					fi
				done
			fi
		else
			# config created by deCONZ - check if apikey is still correct
			if [ -z "$(cat /home/$MAINUSER/.homebridge/config.json | grep "$APIKEY")" ]; then
				# apikey not found - update config
				sed -i '/\"${BRIDGEID}\":/c\    \"${BRIDGEID}\": \"$APIKEY\"' /home/$MAINUSER/.homebridge/config.json
			fi
		fi
	else
		# create homebridge dir and config and add Mainuser ownership
		mkdir /home/$MAINUSER/.homebridge
		touch /home/$MAINUSER/.homebridge/config.json
		chown -R $MAINUSER /home/$MAINUSER/.homebridge

		RC=1
		while [ $RC -ne 0 ]; do
			HOMEBRIDGE_PIN=$(sqlite3 $ZLLDB "select value from config2 where key='homebridge-pin'")
			RC=$?
			if [ $RC -ne 0 ]; then
				[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error reading homebridge-pin from db"
				sleep 2
			fi
		done
		local HB_PIN="${HOMEBRIDGE_PIN:0:3}-${HOMEBRIDGE_PIN:3:2}-${HOMEBRIDGE_PIN:5:3}"
		echo "{
\"bridge\": {
    \"name\": \"Phoscon Homebridge\",
    \"username\": \"$(echo ${BRIDGEID:4} | fold -w2 | paste -sd':' -)\",
    \"port\": 51826,
    \"pin\": \"${HB_PIN}\"
},

\"platforms\": [
{
  \"platform\": \"Hue\",
  \"host\": \"127.0.0.1\",
  \"users\": {
    \"${BRIDGEID}\": \"${APIKEY}\"
  },
  \"sensors\": true,
  \"excludeSensorTypes\": [\"CLIP\", \"Geofence\"],
  \"lights\": true,
  \"hueMotionTemperatureHistory\": true
}
]
}" > /home/$MAINUSER/.homebridge/config.json

		chown $MAINUSER /home/$MAINUSER/.homebridge/config.json
	fi

	## start homebridge
	systemctl -q is-active homebridge
	if [ $? -eq 0 ]; then
		[[ $LOG_INFO ]] && echo "${LOG_INFO}another homebridge service is already running"
		return
	fi

	process=$(ps -ax | grep "homebridge$")
	if [ -z "$process" ]; then
		[[ $LOG_INFO ]] && echo "${LOG_INFO}starting homebridge"
		if [[ "$HOMEBRIDGE" != "managed" ]]; then
			RC=1
			while [ $RC -ne 0 ]; do
				sqlite3 $ZLLDB "replace into config2 (key, value) values('homebridge', 'managed')" &> /dev/null
				RC=$?
				if [ $RC -ne 0 ]; then
					[[ $LOG_DEBUG ]] && echo "${LOG_DEBUG}Error setting homebridge to managed in db"
					sleep 2
				fi
			done
		fi
		homebridge -U /home/$MAINUSER/.homebridge &
	fi

}

# break loop on SIGUSR1
trap 'TIMEOUT=0' SIGUSR1

while [ 1 ]
do
	if [[ -z "$ZLLDB" ]] || [[ ! -f "$ZLLDB" ]]; then
		init
	fi

	while [[ $TIMEOUT -gt 0 ]]
	do
		sleep 1
		TIMEOUT=$((TIMEOUT - 1))
	done

	TIMEOUT=30

	[[ -z "$ZLLDB" ]] && continue
	[[ ! -f "$ZLLDB" ]] && continue

    checkHomebridge
	checkNewDevices
done
