# WireGuard Script by Yashau

This script assumes that the WireGuard server configuration lives in
/etc/wireguard/$interface.conf and a \t delimited DB in the format
"cName cPriv cPub cPsk cIP cASN" exists at /etc/wireguard/$interface.db

## Examples:

1) add - add client to WireGuard configuration and generate the client
client configuration. Minimum of client name and the client IP address 
must follow the add command.

	```./wireguard.sh add alice 172.16.0.5```

	Adding bgp=XXXXX to the end of the normal add
	command enables BGP auto configuration. In this case, the
	client IP address should be followed by a comma separated 
	list of networks in CIDR notation used at the remote site. 
	**There must be no space after the comma.** Since BGP is 
	assumed, the generated client config will have the 
	```Table = off``` option so that Wireguard will not add or 
	remove anything from the kernel routing table. Since the 
	option holds no value over routing entries, feel free to 
	make the range as broad as you like. It will make managing 
	many peers a bit easier by not having to mention their 
	specific networks.

	```./wireguard.sh add remotesite 172.16.0.5,172.16.0.0/12 bgp=65123```
	
	```./wireguard.sh add remotesite 172.16.0.5,172.16.10.0/24,172.16.11.0/24 bgp=65123```

2) remove - remove a client from the wireguard configuration. also
removes the BGP neighbor from the server if ASN is found in the DB

	```./wireguard.sh remove remotesite```

3) conf - regenerate configuration for an existing client. if an ASN
exists for the client, clientside BGP configuration is
regenerated.

	```./wireguard.sh conf alice```

4) reload - flushes all client information from the wireguard config
and reloads all client from the DB.For BGP peers, it will also reconfigure
all BGP neighbors in FRRouting

	```./wireguard.sh reload```

## TODO
- Suggest client IP addresses
