# oracle_database_scaling

Standalone (non-RAC) Oracle DB scaling via Ansible. Uses `sqlplus / as sysdba`
OS authentication — no wallet. RAC is blocked by a `cluster_database` guard.

## Ordering (why)
- scale_up: server (hugepages+reboot) FIRST, then DB config — instance must
  never request more SGA than the current server can back.
- scale_down: DB config FIRST (while old larger RAM/hugepages still present),
  then server shrink+reboot — shrinking server first would strand a running
  instance holding a now-too-large SGA.

## Required run-time vars (Jenkins -e)
scale_option, db_sid, sga_max_size_gb, sga_target_gb, pga_aggregate_target_gb,
pga_aggregate_limit_gb, processes, sessions, target_server_ram_gb

`target_server_ram_gb` = the RAM the host has (scale_up, applied before this
run) or will have (scale_down, applied by infra AFTER this run's reboot).
VM/hypervisor resize itself is out of scope — orchestrated outside this play.

## Scope / assumptions
- Standalone instances only (no ASM/RAC support).
- Opens the database after maintenance is NOT done here — a separate
  existing role/playbook brings components up; this play stops at MOUNT
  (scale_up) or DOWN (scale_down).
- pfile is backed up from spfile before any parameter change, every run.
- One host at a time (`serial: 1`) with a lock file to block concurrent runs.

## Install
ansible-galaxy collection install -r requirements.yml

## Run
ansible-playbook playbook.yml -i inventory/hosts.ini -e "scale_option=scale_up db_sid=ORCL sga_max_size_gb=64 sga_target_gb=64 pga_aggregate_target_gb=16 pga_aggregate_limit_gb=20 processes=1000 sessions=1500 target_server_ram_gb=128"
