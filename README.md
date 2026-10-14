# rsyslog UDP/514 multi-destination relay

Operator guide for `install-syslog-relay-multi.sh`. 
## What it does

The interactive Bash installer configures an Ubuntu host to receive syslog over UDP port 514 and forward each received message to **every** selected destination over UDP port 514. This is fan-out (duplicate forwarding), not load balancing or failover.

```text
Sender(s) -- UDP/514 --> Relay -- UDP/514 --> Destination 1
                              -- UDP/514 --> Destination 2
                              -- UDP/514 --> ... Destination N
```

It creates a dedicated `remote_udp514_relay` ruleset with one `omfwd` action per destination, named `relay_to_server1`, `relay_to_server2`, and so on. The UDP listener uses `imudp` with one worker thread and batch size 32. No bind address is specified; treat the listener as exposed on available interfaces and verify its actual bindings.

The managed ruleset has no severity/facility filter and no local file-writing action. It does not deliberately forward the relay host's locally generated messages; those continue through the host's existing configuration. Incoming messages handled by this ruleset are not automatically stored in `/var/log/syslog` on the relay.

It also enables `impstats`: JSON-format internal statistics every 60 seconds in `/var/log/rsyslog-relay-stats.log`, with `log.syslog="off"`. It does not configure statistics-log rotation.

## Requirements and preparation

- Ubuntu: the script requires `/etc/os-release` to identify `ID=ubuntu`. It is designed for **Ubuntu 26.04**; other Ubuntu versions produce a warning and continue, without a compatibility guarantee.
- Bash, root privileges through `sudo`, and an interactive terminal.
- A working systemd environment and APT repositories/network access. The installer runs `apt-get update` and installs `rsyslog`, `iproute2`, and `tcpdump` using `apt-get install -y` with noninteractive package handling. Existing packages may be upgraded by that install.
- Standard administrative utilities used by the script, including `grep`, `cp`, `install`, and `chmod`.
- **Python 3 already installed if you supply a sender IP/CIDR**. Validation occurs before package installation; the script does not install Python.
- One to 100 destination IPv4 addresses, with collectors already configured to receive UDP/514. Hostnames, IPv6, custom ports, TCP, and TLS are not offered.
- Sender-to-relay UDP/514 reachability and relay-to-each-collector UDP/514 reachability, including routing, host firewalls, network ACLs, and cloud security rules.
- UFW is optional. The installer neither installs nor enables it.

Review the script and existing rsyslog/firewall settings first. Make an independent backup of `/etc/rsyslog.conf`, `/etc/rsyslog.d/`, relevant firewall configuration, and the current rsyslog service enabled/running state. Schedule for a service restart and possible UDP message loss during the interruption.

Avoid a relay address, loopback address, broadcast/multicast target, or any collector that forwards messages back into this relay. The destination validator is a basic IPv4 syntax check, not a suitability or routing check.

## Installation

Place the script on the intended Ubuntu relay, then run from its directory:

```bash
bash -n ./install-syslog-relay-multi.sh
sudo bash ./install-syslog-relay-multi.sh
```

The first command checks Bash syntax only. It does not validate rsyslog configuration or network behavior. An executable bit is unnecessary when invoking the script through Bash. Preserve Unix line endings when transferring from Windows.

### Prompts, in order

| Prompt | Accepted input and behavior |
| --- | --- |
| `How many logging destinations?` | Integer 1–100. Leading zeros, signs, blanks, and nonnumeric text are rejected and reprompted. |
| `Destination logging server #N IPv4 address:` | Four decimal octets, each 0–255. `0.0.0.0` and `255.255.255.255` are rejected. Repeated address strings are rejected and reprompted. |
| `Allowed syslog sender IP/CIDR [blank = no UFW change]:` | Optional IPv4 address or CIDR, validated by Python's `ipaddress.ip_network(..., strict=False)`. Invalid input aborts rather than reprompting. Blank skips automated firewall changes. |
| `Continue with installation? [y/N]:` | Only one character `y` or `Y` proceeds. Any other input cancels with exit status 0 before package or configuration changes. |

Destination validation accepts leading-zero octets and compares duplicates as text. Use ordinary dotted-decimal addresses without leading zeros; different spellings are not reliably detected as the same destination. Sender CIDR validation accepts host bits, but the original input is passed to UFW; supply a canonical network such as `10.20.30.0/24`.

Example answers for two collectors:

```text
How many logging destinations? 2
Destination logging server #1 IPv4 address: 192.0.2.20
Destination logging server #2 IPv4 address: 192.0.2.21
Allowed syslog sender IP/CIDR [blank = no UFW change]: 10.20.30.0/24
Continue with installation? [y/N]: y
```

These are example addresses; replace them for your environment.

### Changes and checks

After confirmation, the script:

1. Updates APT indexes and installs the three packages.
2. Checks whether UDP/514 is already bound. It aborts if a listener exists and its managed relay file does not. If that file exists, the check permits continuation; it does not prove the listener belongs to rsyslog.
3. Scans configuration for certain existing `imudp` and `impstats` definitions outside its managed files and aborts on detected conflicts. These pattern checks are not a complete parser and may miss alternate syntax or includes.
4. Creates a mode-0700 backup directory and copies any existing managed files, preserving metadata.
5. Writes both managed configuration files with mode 0644, replacing their previous contents.
6. Validates the complete rsyslog configuration using `rsyslogd -N1`.
7. If a sender scope was supplied and UFW is installed and active, attempts to add `ufw allow from SOURCE to any port 514 proto udp`, unless its text-based status check appears to find a matching rule.
8. Enables rsyslog at boot, restarts it, checks that it is active, and checks for a UDP/514 listener.
9. Prints success, destination addresses, statistics location, and backup location.

A success message confirms these local checks, **not collector receipt**. The printed approximately 1,000 messages/second figure is a target to measure, not a benchmark or guarantee. The final message refers to “both collectors” even when you choose another count; verify every configured collector.

| Path | Purpose |
| --- | --- |
| `/etc/rsyslog.d/30-udp514-relay.conf` | Managed UDP listener and fan-out actions |
| `/etc/rsyslog.d/00-relay-impstats.conf` | Managed statistics module |
| `/var/log/rsyslog-relay-stats.log` | Runtime statistics output |
| `/var/backups/rsyslog-relay/YYYYMMDD-HHMMSS-PID/` | Previous managed files, if present, named `relay.conf` and `stats.conf` |

The generated configuration comments say `install-syslog-relay.sh`; that is the script's existing comment text, not a separate required installer.

## Verify receive and duplicate forwarding

### 1. Validate service and listener on the relay

```bash
sudo rsyslogd -N1
systemctl is-active rsyslog
systemctl is-enabled rsyslog
sudo ss -lunp '( sport = :514 )'
sudo journalctl -u rsyslog -n 100 --no-pager
```

Confirm configuration validation succeeds, the service is active, and rsyslog owns the expected UDP/514 socket. A listening socket alone proves neither firewall access nor delivery.

### 2. Send identifiable messages from an allowed external sender

On a Linux sender with util-linux `logger`, replace the relay IP below:

```bash
RELAY_IP=192.0.2.10
TEST_ID="relay-test-$(date -u +%Y%m%dT%H%M%SZ)-$$"
for i in $(seq 1 10); do
  logger --udp --server "$RELAY_IP" --port 514 --rfc3164 \
    --tag relay-test "$TEST_ID seq=$i total=10"
done
printf 'Search every collector for: %s\n' "$TEST_ID"
```

Use a sender within the intended firewall scope and record the test ID. A plain local `logger` invocation on the relay tests its local logging path, not this UDP-bound ruleset. Successful `logger` execution does not acknowledge UDP delivery.

### 3. Observe relay ingress and egress

Start capture before sending the test:

```bash
sudo tcpdump -ni any -nn -s0 -A 'udp dst port 514'
```

For a quieter capture of one sender and two destinations, substitute actual addresses:

```bash
sudo tcpdump -ni any -nn -s0 -A \
  'udp dst port 514 and (src host 10.20.30.15 or dst host 192.0.2.20 or dst host 192.0.2.21)'
```

Look for each numbered marker entering the relay and outgoing traffic addressed to each collector. `any` captures can show a packet more than once across interfaces; use addresses, interface information, and markers rather than raw line counts. Packet capture may expose sensitive log contents; limit duration and access.

### 4. Confirm storage on every collector

Search each collector's actual syslog file, journal, or logging platform for the exact test ID. Collector storage paths depend on its configuration; the installer configures no collectors. For a collector known to write `/var/log/syslog`, for example:

```bash
sudo grep -F 'REPLACE_WITH_TEST_ID' /var/log/syslog
```

Expect sequence numbers 1–10 at **each** destination. Compare missing and repeated sequence numbers. Capture on a collector if needed to distinguish network arrival from collector parsing/storage failure. A packet reaching the relay or an increasing action counter is not proof of collector storage. Forwarding uses rsyslog's configured/default formatting, not a byte-for-byte packet copy; compare message markers rather than entire wire payloads.

## Statistics and performance

Allow at least one 60-second interval after startup:

```bash
sudo tail -f /var/log/rsyslog-relay-stats.log
sudo grep -E 'imudp|relay_to_server' /var/log/rsyslog-relay-stats.log | tail -n 30
nstat -az | grep -E 'UdpInErrors|UdpRcvbufErrors'
```

Inspect input and action records for activity and reported failures/suspensions. Counter names and available fields depend on the installed rsyslog version. Read counter changes over time and account for service restarts; counters do not prove UDP acknowledgment. `nstat` values are host-wide: compare before/after values during a controlled test rather than attributing every existing error to this relay.

For N collectors and R incoming messages/second, plan for roughly N × R outgoing datagrams/second, plus message and network overhead. Test representative message sizes and rates while checking CPU, network capacity, kernel UDP drops, and actual collector counts. The script adds no explicit disk-assisted queues, retries, rate controls, socket-buffer tuning, or performance test. Establish rotation/retention for the statistics log separately.

## Diagnostics

| Symptom | Checks and next steps |
| --- | --- |
| Wrong OS or privileges | Run on Ubuntu with `sudo`; other distribution IDs are rejected. |
| Python validation fails | Install/verify Python 3 separately; supply a valid IPv4 sender address or canonical CIDR. |
| APT fails | Check repositories, DNS, connectivity, package locks, and package-manager output before rerunning. |
| UDP/514 conflict | Inspect `sudo ss -lunp '( sport = :514 )'`; resolve ownership deliberately rather than killing an unknown service. |
| Existing module configuration detected | Inspect `/etc/rsyslog.conf` and `/etc/rsyslog.d/`; reconcile existing listeners/statistics manually. Do not blindly delete another service's configuration. |
| Configuration validation fails | Run `sudo rsyslogd -N1` and inspect its file/line diagnostics. Existing unrelated errors can also prevent installation. |
| Service fails to restart | Inspect `sudo systemctl status rsyslog --no-pager` and `sudo journalctl -u rsyslog -n 100 --no-pager`. Check for rollback warnings. |
| No inbound packets | Check sender protocol/target, routing, NAT, UFW, other host firewalls, network ACLs, and cloud rules. |
| Inbound traffic but no forwarding | Inspect managed actions, full configuration validation, service journal, and stats; confirm captures target the intended interfaces/addresses. |
| Relay egress but no collector records | Capture at the collector; check collector listener, firewall, parsing, filters, and storage. |
| No statistics file | Wait a full interval; check `impstats` configuration and journal for write/permission errors. |
| Drops or missing messages | Compare kernel counters, interface statistics, traffic rate, collector capacity, and numbered test results. UDP permits loss even when local checks succeed. |

## Rerunning and rollback

A rerun asks for a complete new destination list and replaces the managed configuration; it does not append destinations. It backs up the immediately previous managed files, installs packages again, and restarts rsyslog. Manual edits to those files will be overwritten. Old sender-specific UFW allowances are not removed when you change or omit the sender scope.

### Automatic failure rollback

On a nonzero exit after configuration modification begins, the exit trap attempts to restore prior managed files, or remove newly created ones when no previous file existed. It attempts to remove a UFW rule marked as added by that run, then validates the resulting configuration and attempts an rsyslog restart.

This is a best-effort rollback, not a complete system transaction. It does not undo APT changes, restore the previous service enabled/running state, remove backups/statistics, or guarantee service recovery. Restart/firewall-delete failures can be suppressed. Abrupt termination such as power loss or `SIGKILL` bypasses the trap. Package installation occurs before managed-file rollback is armed. The UFW matching check is text-based; inspect actual rules after a failed run.

### Manual restoration after a successful install

Choose the backup for the installation you intend to undo. The following commands change the live configuration: inspect the chosen backup first and retain a copy of the current files if needed.

```bash
# Replace this example with the exact backup path printed by the installer.
BACKUP=/var/backups/rsyslog-relay/YYYYMMDD-HHMMSS-PID
sudo ls -la "$BACKUP"
```

Restore the relay file if it exists in that backup:

```bash
sudo cp -p "$BACKUP/relay.conf" /etc/rsyslog.d/30-udp514-relay.conf
```

If the backup has no `relay.conf`, that managed file did not exist before that run; remove the newly created file instead:

```bash
sudo rm -f /etc/rsyslog.d/30-udp514-relay.conf
```

Apply the same choice independently for statistics: restore if backed up, otherwise remove the new managed file.

```bash
# Run this only if stats.conf exists in the selected backup:
sudo cp -p "$BACKUP/stats.conf" /etc/rsyslog.d/00-relay-impstats.conf
# Otherwise run this instead:
sudo rm -f /etc/rsyslog.d/00-relay-impstats.conf
```

Validate before restarting:

```bash
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
sudo systemctl status rsyslog --no-pager
sudo ss -lunp '( sport = :514 )'
```

Inspect `sudo ufw status numbered` and remove only a rule you have confirmed was introduced by this installation and is no longer needed. For the exact sender scope previously added, the deletion form is:

```bash
sudo ufw delete allow from 10.20.30.0/24 to any port 514 proto udp
```

Do not remove a pre-existing or shared allowance. Restore the prior service enablement/state only if you recorded it and understand the impact on other local logging. Packages, backup directories, and accumulated statistics remain; do not uninstall rsyslog merely to undo these relay files.

## Security and operational cautions

- UDP syslog here has no encryption, authentication, acknowledgment, guaranteed ordering, or exactly-once delivery. Use trusted/isolated networks or an independently managed secure transport when confidentiality or delivery assurance is required.
- The sender prompt is **not a source filter in rsyslog**. It adds an allowance only when UFW is already active; it does not remove broad allowances, add a deny rule, change default policies, or restrict other firewall systems. Verify effective access from both allowed and disallowed hosts. Source-address rules do not provide cryptographic sender identity.
- The script configures neither TLS nor TCP and does not protect against malicious/spoofed syslog traffic, log injection, flooding, or fan-out amplification.
- Prevent forwarding loops. Every accepted message is sent to all destinations; a loop can multiply traffic quickly.
- Destination addresses and sender scopes are not tested for connectivity. Collectors may see the relay as the network source even when message content retains an originating hostname.
- Configuration is mode 0644; backup directories are mode 0700. The script does not explicitly set statistics-file permissions or retention; inspect effective permissions and disk growth.
- The script uses strict Bash error handling, but its conflict checks and rollback have the limits described above. Keep independent backups and verify after every run.
- No license is declared in the inspected script. This README does not grant a software license.

## Reference documentation

Script-specific statements above come from the inspected script. For underlying module behavior and test-command options, consult:

- [rsyslog imudp input module](https://docs.rsyslog.com/doc/configuration/modules/imudp.html)
- [rsyslog omfwd forwarding module](https://docs.rsyslog.com/doc/configuration/modules/omfwd.html)
- [rsyslog impstats module](https://docs.rsyslog.com/doc/configuration/modules/impstats.html)
- [rsyslog statistics counters](https://docs.rsyslog.com/doc/configuration/rsyslog_statistic_counter.html)
- [util-linux logger manual](https://man7.org/linux/man-pages/man1/logger.1.html)

