pipeline {
  agent any
  parameters {
    choice(name: 'SCALE_OPTION', choices: ['scale_up', 'scale_down'], description: '')
    string(name: 'TARGET_HOST', defaultValue: '')
    string(name: 'DB_SID', defaultValue: '')
    string(name: 'SGA_MAX_SIZE_GB', defaultValue: '')
    string(name: 'SGA_TARGET_GB', defaultValue: '')
    string(name: 'PGA_AGGREGATE_TARGET_GB', defaultValue: '')
    string(name: 'PGA_AGGREGATE_LIMIT_GB', defaultValue: '')
    string(name: 'PROCESSES', defaultValue: '')
    string(name: 'SESSIONS', defaultValue: '')
    string(name: 'TARGET_SERVER_RAM_GB', defaultValue: '')
  }
  stages {
    stage('Run Scaling Playbook') {
      steps {
        sh """
          ansible-galaxy collection install -r requirements.yml
          ansible-playbook playbook.yml -i inventory/hosts.ini \
            -e "target_host=${params.TARGET_HOST}" \
            -e "scale_option=${params.SCALE_OPTION}" \
            -e "db_sid=${params.DB_SID}" \
            -e "sga_max_size_gb=${params.SGA_MAX_SIZE_GB}" \
            -e "sga_target_gb=${params.SGA_TARGET_GB}" \
            -e "pga_aggregate_target_gb=${params.PGA_AGGREGATE_TARGET_GB}" \
            -e "pga_aggregate_limit_gb=${params.PGA_AGGREGATE_LIMIT_GB}" \
            -e "processes=${params.PROCESSES}" \
            -e "sessions=${params.SESSIONS}" \
            -e "target_server_ram_gb=${params.TARGET_SERVER_RAM_GB}"
        """
      }
    }
  }
}
