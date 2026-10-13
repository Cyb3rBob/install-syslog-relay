Interactive rsyslog UDP/514 fan-out installer for Ubuntu.
Written by Cyb3rBob (and Codex)

Script was written for and only tested on Ubuntu 26.04

To run this script: 

sudo chmod +x install-syslog-relay.sh
sudo ./install-syslog-reloay.sh
After Installation you can see if rsyslog is receiving and forwarding traffic
sudo tcpdump -ni any 'udp port 514'
sudo tail -f /var/log/rsyslog-relay-stats.log
