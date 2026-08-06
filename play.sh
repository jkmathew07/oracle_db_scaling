 ansible-playbook playbook.yml -i inventory/hosts.yml \
   -e "target_host=genx-db-711.genex.com scale_option=scale_up \
        db_sid=PRODCDB  sga_max_size_gb=4 \
        sga_target_gb=6 pga_aggregate_target_gb=2 pga_aggregate_limit_gb=4 \
        processes=1000 sessions=1522 target_server_ram_gb=16" 
#     --vault-password-file=.vaultpass

#formula for sessions = SESSIONS = (1.5 * PROCESSES) + 22