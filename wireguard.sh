#!/usr/bin/env bash

############################ WireGuard Script by Yashau v2.0 ############################

######################################### README ########################################
##--This script assumes that the WireGuard server configuration lives in---------------##
##--/etc/wireguard/$interface.conf and a \t delimited DB in the format-----------------##
##--"cName cPriv cPub cPsk cIP cASN" is exists at /etc/wireguard/$interface.db---------##
##-------------------------------------------------------------------------------------##
##--Examples:--------------------------------------------------------------------------##
##--1) add - add client to WireGuard configuration and generate the client-------------##
##------client configuration. Minimum of client name and the client IP-----------------##
##------address must follow the add command.-------------------------------------------##
##-------------------------------------------------------------------------------------##
##------./wireguard.sh add alice 172.16.0.5--------------------------------------------##
##-------------------------------------------------------------------------------------##
##------Adding bgp=XXXXX to the end of the normal add command enables BGP auto---------##
##------configuration. In this case, the client IP address should be followed by a-----##
##------comma separated list of networks in CIDR notation used at the remote site.-----##
##------**There must be no space after the comma.** Since BGP is assumed, the----------##
##------generated client config will have the Table = off option so that Wireguard-----##
##------will not add or remove anything from the kernel routing table. Since the-------##
##------option holds no value over routing entries, feel free to make the range as-----##
##------broad as you like. It will make managing many peers a bit easier by not--------##
##------having to mention their specific networks.-------------------------------------##
##-------------------------------------------------------------------------------------##
##------./wireguard.sh add remotesite 172.16.0.5,172.16.0.0/12 bgp=65123---------------##
##------./wireguard.sh add remotesite 172.16.0.5,172.16.10.0/24,172.16.11.0/24 \-------##
##--------------bgp=65123--------------------------------------------------------------##
##-------------------------------------------------------------------------------------##
##--2) remove - remove a client from the wireguard configuration. also-----------------##
##------removes the BGP neighbor from the server if ASN is found in the DB-------------##
##-------------------------------------------------------------------------------------##
##------./wireguard.sh remove remote-site----------------------------------------------##
##-------------------------------------------------------------------------------------##
##--3) conf - regenerate configuration for an existing client. if an ASN---------------##
##------exists for the client, client-side BGP configuration is------------------------##
##------regenerated.-------------------------------------------------------------------##
##-------------------------------------------------------------------------------------##
##------./wireguard.sh conf alice------------------------------------------------------##
##-------------------------------------------------------------------------------------##
##--4) reload - flushes all client information from the wireguard config---------------##
##------and reloads all client from the DB. For BGP peers, it will also reconfigure----##
##------all BGP neighbors in FRRouting.------------------------------------------------##
##-------------------------------------------------------------------------------------##
##------./wireguard.sh reload----------------------------------------------------------##
##-------------------------------------------------------------------------------------##
#########################################################################################

[[ $EUID -ne 0 ]] && echo "This script must be run as root. Terminating." && exit 1

# read variables from arguments
read -r cmd cName cIP cASN <<< "${1} ${2} ${3} ${4}"

# read variables from env file
mapfile -t env <<< "$(grep -v '^\s*$\|^\s*\#' .env)"
IFS=$'\n' read -r -d '' genQR autoBGP dynamicBGP sIface sHost cRoutes cDNS cConfs sConf sDB \
	<<< "$(printf '%s\n' "${env[@]#*=}")"

set -e

# make sure binaries are available
[[ -x "$(hash wg wg-quick)" ]] && echo 'Wireguard tools are not installed. Terminating.' && \
	exit 1
[[ "${genQR}" -eq 1 ]] && [[ -x "$(hash qrencode)" ]] && \
	echo 'qrencode is not installed. Terminating.' && exit 1

# check if vtysh is available and then get the server ASN
if [[ "${autoBGP}" -eq 1 ]]; then
	[[ -x "$(hash vtysh)" ]] && echo 'FRRouting is not installed. Terminating.' && exit 1
	sASN=$(grep -Po '(?<=AS)\d{5}' <<< "$(vtysh -c 'show bgp view')")
	cASN=${cASN#*bgp=}
fi

sConf=$(eval echo "$sConf")
sDB=$(eval echo "$sDB")

getVars()
{
	if [[ -z "${cName}" ]]; then
		echo "Client name must be specified. Terminating."
    	exit 1;
	fi

	# get client params from the DB
	line=$(grep -P "${cName}\t" "${sDB}")
	if [[ -z "${line}" ]]; then
		# exit if client name doesn't exist in the DB
		echo "Client not found in DB. Terminating."
		exit 1
	fi

	read -r cName cPriv cPub _cPsk cIP cASN <<< "${line}"
	cPsk="$(mktemp /tmp/psk-XXXXX)" && trap 'rm "${cPsk}"' EXIT
	echo "${_cPsk}" > "${cPsk}"

	[[ "${autoBGP}" -eq 1 ]] && [[ "${cASN}" -ne 0 ]] && cBGPConf=1
}

makeConf()
{
	# get wireguard interface details from the config file
	sAddress=$(grep -Po 'Address = \K.*' "${sConf}")
	sPriv=$(grep -Po 'PrivateKey = \K.*' "${sConf}")
	sPub=$(wg pubkey <<< "${sPriv}")
	sPort=$(grep -Po 'ListenPort = \K.*' "${sConf}")
	sEndpoint="${sHost}:${sPort}"

	# create client configs dir
	mkdir -p "${cConfs}"
	cPath="${cConfs}/${cName}"

	# create the client config to be shared
	{
		echo "[Interface]"
		echo "PrivateKey = ${cPriv}"
		echo "Address = ${cIP%%,*}$([[ "${cBGPConf}" -eq 1 ]] && echo -n "/${sAddress#*/}")"
		echo "DNS = ${cDNS}"
		[[ "${cBGPConf}" -eq 1 ]] && echo "Table = off"
		echo "[Peer]"
		echo "PublicKey = ${sPub}"
		echo "PresharedKey = $(<"${cPsk}")"
		echo "AllowedIPs = ${cRoutes}"
		echo "Endpoint = ${sEndpoint}"
	} > "${cPath}.conf"
	
	echo "Use the following config on the client:"
	echo
	cat "${cPath}.conf"
	echo
	echo "A copy of the config has been saved at ${cPath}.conf"

	# generate single vtysh command to configure frrouting on client-side
	if [[ "${cBGPConf}" -eq 1 ]]; then
		{
			echo "vtysh -c \"configure terminal\" \\"
			echo "-c \"ip prefix-list no-default-route seq 5 permit 0.0.0.0/0 ge 1\" \\"
			echo "-c \"router bgp ${cASN}\" \\"
			echo "-c \"bgp router-id ${cIP%%,*}\" \\"
			echo "-c \"neighbor ${sAddress%/*} remote-as ${sASN}\" \\"
			echo "-c \"address-family ipv4 unicast\" \\"
			echo "-c \"redistribute connected\" \\"
			echo "-c \"neighbor ${sAddress%/*} prefix-list no-default-route in\" \\"
			echo "-c \"neighbor ${sAddress%/*} prefix-list no-default-route out\" \\"
			echo "-c \"do write memory\""
		} > "${cPath}.bgp"
		echo
		echo "Paste the following to setup BGP routing at the remote site."
		echo
		cat "${cPath}.bgp"
		echo
	else
		# if bgp is not being used, create client qr code for mobile use
		if [[ "${genQR}" -eq 1 ]]; then
			qrencode -t png -o "${cPath}.png" < "${cPath}.conf"
			qrencode -t ansiutf8 < "${cPath}.conf"
		fi
	fi
	
}

addBGP()
{
	# add the client bgp neighbor on the server
	if ! grep -q "${cASN}" <<< "$(vtysh -c 'show ip bgp summary')"; then
		vtysh -c "configure terminal" \
			-c "ip prefix-list no-default-route seq 5 permit 0.0.0.0/0 ge 1" \
			-c "router bgp ${sASN}" \
			-c "neighbor ${cIP%%,*} remote-as ${cASN}" \
			-c "address-family ipv4 unicast" \
			-c "neighbor ${cIP%%,*} prefix-list no-default-route in" \
			-c "neighbor ${cIP%%,*} prefix-list no-default-route out" \
			-c "do write memory"
	fi
}

removeBGP()
{
	# remove the client bgp neighbor on the server
	if grep -q "${cASN}" <<< "$(vtysh -c 'show ip bgp summary')"; then
		vtysh -c "configure terminal" \
			-c "router bgp ${sASN}" \
			-c "no neighbor ${cIP%%,*} remote-as ${cASN}" \
			-c "do write memory"
	fi
}

addClient()
{
	if [[ -z "${cName}" ]]; then
		echo "Client name must be specified. Terminating."
    	exit 1
	fi
	if [[ -z "${cIP}" ]]; then
		echo "Client IP must be specified. Terminating."
    	exit 1
	fi

	# making sure frr is running
	if [[ "${autoBGP}" -eq 1 ]]; then
		if [[ -n "${cASN}" ]]; then
			if [[ "${dynamicBGP}" -ne 1 ]]; then
				if grep -q grep bgpd <<< "$(systemctl status frr.service)"; then
					configFRR=1
				else
					echo "FRRouting BGP is not running. Terminating"
				fi
			fi
		fi
	fi

	# make sure client does not already exist in DB
	if grep -qP "${cName}\t" "${sDB}"; then
		echo "Client already exists in DB. Terminating."
		exit 1
	fi

	# making sure IP does not already exist in DB
	if grep -qP "${cIP}\t" "${sDB}"; then
		echo "IP already exists in DB. Terminating."
		exit 1
	fi

	# generate client private/public keys
	cPriv=$(wg genkey)
	cPub=$(wg pubkey <<< "${cPriv}")

	# write unique psk to a temporary file
	cPsk="$(mktemp /tmp/psk-XXXXX)" && trap 'rm "${cPsk}"' EXIT
	wg genpsk > "${cPsk}"

	# hot add client peer to wireguard without restarting service
	wg set "${sIface}" peer "${cPub}" allowed-ips "${cIP}" \
		preshared-key "${cPsk}"

	# save currently running wireguard configuration
	wg-quick save "${sIface}"

	# save client information to DB
	echo -e "${cName}\t${cPriv}\t${cPub}\t$(<"${cPsk}")\t${cIP}\t${cASN:=0}" \
		>> "${sDB}"

	# generate the client configuration files and commands
	makeConf

	# if enabled, configure frrouting bgp daemon on the server
	if [[ "${configFRR}" -eq 1 ]]; then
		addBGP
	fi
}

removeClient()
{
	if [[ -z "${cName}" ]]; then
		echo "Client name must be specified. Terminating."
    	exit 1
	fi

	# hot remove the peer from the wireguard config without restarting service
	wg set "${sIface}" peer "${cPub}" remove
	sed -i "/${cName}\t/d" "${sDB}"

	# save currently running wireguard configuration
	wg-quick save "${sIface}"

	# if ASN exists in the DB, remove neighbor from server BGP daemon
	if [[ "${autoBGP}" -eq 1 ]]; then
		if [[ "${dynamicBGP}" -ne 1 ]]; then
			if [[ "${cASN}" -ne 0 ]]; then 
				removeBGP
			fi
		fi
	fi
	
	# delete config files from configs directory
	find "${cConfs}" -name "${cName}.*" -delete
}

reloadConf()
{
	# flush all peers from wireguard configuration
	for i in $(wg show wg0 | grep -Po 'peer: \K.*'); do
		wg set wg0 peer "${i}" remove
	done

	# read the DB file and add each peer to wireguard and FRR configuration
	while read -r line; do
		cPub=$(awk '{print $3}' <<< "${line}")
		cIP=$(awk '{print $5}' <<< "${line}")
		cPsk="$(mktemp /tmp/psk-XXXXX)" && trap 'rm "${cPsk}"' EXIT
		awk '{print $4}' <<< "${line}" > "${cPsk}"
		wg set "${sIface}" peer "${cPub}" allowed-ips "${cIP}" \
			preshared-key "${cPsk}"
		cASN=$(awk '{print $6}' <<< "${line}")

		if [[ "${autoBGP}" -eq 1 ]]; then
			if [[ "${dynamicBGP}" -ne 1 ]]; then
				if [[ "${cASN}" -ne 0 ]]; then
					addBGP
				fi
			fi
		fi

	done < "${sDB}"

	# save currently running wireguard configuration
	wg-quick save "${sIface}"
}

case "${cmd}" in
	add)
		addClient
		echo "Done. Client configuration at ${cPath}.conf"
		;;
	remove)
		getVars
		removeClient
		echo "Done. Client ${cName} removed."
		;;
	conf)
		getVars
		makeConf
		echo "Done."
		;;
	reload)
		reloadConf
		echo "Reloaded clients from ${sDB}"
		;;
	*)
		echo "Unknown command. Terminating."
		exit 1
esac