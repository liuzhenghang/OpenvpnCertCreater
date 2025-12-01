pipeline {
  agent { label 'docker' }

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    string(
      name: 'VPN_ENDPOINT',
      defaultValue: 'udp://vpn.example.com:1194',
      description: '传给 ovpn_genconfig -u 的值，格式 proto://host:port'
    )
    string(
      name: 'CLIENT_NAME',
      defaultValue: 'client01',
      description: '客户端证书/配置的 Common Name'
    )
    booleanParam(
      name: 'REBUILD_CA',
      defaultValue: false,
      description: '是否先重建整套 CA/PKI（会清空历史）'
    )
    booleanParam(
      name: 'ARCHIVE_FULL_PKI',
      defaultValue: true,
      description: '是否额外打包完整 PKI 目录，方便备份'
    )
  }

  environment {
    DOCKER_IMAGE = 'ghcr.io/kylemanna/docker-openvpn:2.6'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Generate OpenVPN Assets') {
      steps {
        withCredentials([string(credentialsId: 'openvpn-ca-pass', variable: 'CA_PASSPHRASE')]) {
          script {
            List<String> extras = []
            if (params.REBUILD_CA) {
              extras << '--rebuild-ca'
            }
            if (params.ARCHIVE_FULL_PKI) {
              extras << '--archive-pki'
            }
            String extraSwitches = extras.join(' ')

            withEnv([
              "TARGET_ENDPOINT=${params.VPN_ENDPOINT}",
              "TARGET_CLIENT=${params.CLIENT_NAME}",
              "EXTRA_SWITCHES=${extraSwitches}"
            ]) {
              sh '''
                #!/usr/bin/env bash
                set -euo pipefail
                chmod +x scripts/generate-openvpn.sh
                scripts/generate-openvpn.sh \
                  --endpoint "${TARGET_ENDPOINT}" \
                  --client "${TARGET_CLIENT}" \
                  --image "${DOCKER_IMAGE}" \
                  ${EXTRA_SWITCHES}
              '''
            }
          }
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'artifacts/**/*', allowEmptyArchive: true, fingerprint: true
    }
    success {
      echo "OpenVPN 证书与配置生成完成"
    }
  }
}

