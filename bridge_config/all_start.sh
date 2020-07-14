#!/bin/sh
ifconfig br0 10.10.10.10/32
route add default gw 10.10.10.10
service nginx start
iptables-restore < iptables.conf
ebtables -P INPUT ACCEPT
ebtables -P OUTPUT ACCEPT
ebtables -P FORWARD ACCEPT
ebtables -t nat -A POSTROUTING -p ipv4 --ip-dst 192.168.88.124 -j snat --to-source 00:0c:29:5f:91:cb
