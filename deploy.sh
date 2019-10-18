#!/usr/bin/env bash
set -e

info()
{
    echo '[INFO] ' "$@"
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
}

# --- fatal if no systemd or openrc ---
verify_system() {
    if [ -d /run/systemd ]; then
        HAS_SYSTEMD=true
        return
    fi
    fatal 'Can not find systemd to use as a process supervisor for edgesite'
    exit 1
}


setup_verify_arch() {
    if [ -z "$ARCH" ]; then
        ARCH=$(uname -m)
    fi
    case $ARCH in
        amd64)
            ARCH=amd64
            SUFFIX=
            ;;
        x86_64)
            ARCH=amd64
            SUFFIX=
            ;;
        arm64)
            ARCH=arm64
            SUFFIX=-${ARCH}
            ;;
        aarch64)
            ARCH=arm64
            SUFFIX=-${ARCH}
            ;;
        arm*)
            ARCH=arm
            SUFFIX=-${ARCH}
            ;;
        *)
            fatal "Unsupported architecture $ARCH"
    esac
}

create_config_file() {
  cat >$PWD/.edgeSite/conf/edgeSite.yaml <<EOF
  mqtt:
      server: tcp://127.0.0.1:1883 # external mqtt broker url.
      internal-server: tcp://127.0.0.1:1884 # internal mqtt broker url.
      mode: $MQTT_MODE # 0: internal mqtt broker enable only. 1: internal and external mqtt broker enable. 2: external mqtt broker enable only.
      qos: 0 # 0: QOSAtMostOnce, 1: QOSAtLeastOnce, 2: QOSExactlyOnce.
      retain: false # if the flag set true, server will store the message and can be delivered to future subscribers.
      session-queue-size: 100 # A size of how many sessions will be handled. default to 100.

  controller:
      kube:
         master: https://$K3S_SERVER_URL:6443
         namespace: "default"
         content_type: "application/vnd.kubernetes.protobuf"
         qps: 5
         burst: 10
         node_update_frequency: 10
         node-id: $NODE_NAME
         node-name: $NODE_NAME
         kubeconfig: $PWD/.edgeSite/conf/kubeconfig.yaml
      context:
         send-module: metaManager
         receive-module: edgecontroller
         response-module: metaManager

  edged:
      register-node-namespace: default
      hostname-override: $NODE_NAME
      interface-name: eth0
      node-status-update-frequency: 10 # second
      device-plugin-enabled: false
      gpu-plugin-enabled: false
      image-gc-high-threshold: 80 # percent
      image-gc-low-threshold: 40 # percent
      maximum-dead-containers-per-container: 1
      docker-address: unix:///var/run/docker.sock
      runtime-type: docker
      version: v1.15.0-kubeedge-v1.0.0
      remote-runtime-endpoint: unix:///var/run/dockershim.sock
      remote-image-endpoint: unix:///var/run/dockershim.sock
      runtime-request-timeout: 2
      podsandbox-image: kubeedge/pause$SUFFIX:3.1
      image-pull-progress-deadline: 60 # second
      cgroup-driver: cgroupfs
      node-ip: ""
      cluster-dns: ""
      cluster-domain: ""
      edged-memory-capacity-bytes: 7852396000

  metamanager:
      context-send-group: edgecontroller
      context-send-module: edgecontroller
      edgesite: true
EOF
}

create_kubeconfig_file() {
  cat > $PWD/.edgeSite/conf/kubeconfig.yaml <<EOF
  apiVersion: v1
  clusters:
  - cluster:
      certificate-authority-data: $SSL_CERT
      server: https:// https://127.0.0.1:6443
    name: default
  contexts:
  - context:
      cluster: default
      user: default
    name: default
  current-context: default
  kind: Config
  preferences: {}
  users:
  - name: default
    user:
      password: $USER_PASS
      username: $USER_NAME
EOF
}


create_logging_file() {
  cat > $PWD/.edgeSite/conf/logging.yaml <<EOF
  loggerLevel: "DEBUG"
  #loggingLevel: "INFO"
  enableRsyslog: false
  logFormatText: true
  writers: [stdout]
EOF
}

create_modules_file() {
  cat > $PWD/.edgeSite/conf/modules.yaml <<EOF
  modules:
      enabled: [edgecontroller, metaManager, edged, dbTest]
EOF
}

deploy_files() {
  create_config_file
  create_logging_file
  create_modules_file
  create_kubeconfig_file
}


create_service() {
  [ $(id -u) -eq 0 ] || exec sudo $0 $@
  cat > /etc/systemd/system/edgesite.service<<EOF
  [Unit]
  Description=edgesite.service

  [Service]
  Type=simple
  ExecStart=$CURRENT/.edgeSite/edgesite

  [Install]
  WantedBy=multi-user.target
EOF
#systemctl enable daemon-reload
systemctl daemon-reload
systemctl start edgesite.service
systemctl enable edgesite.service
}


check_args() {
  ERROR=false
  if [ -z "$K3S_SERVER_URL" ]; then
    fatal "The master address is not set. The K3S_SERVER_URL argument is mandatory."
    ERROR=true
  fi
  if [ -z "$NODE_NAME" ]; then
    fatal "The node name is not set. The NODE_NAME argument is mandatory."
    ERROR=true
  fi
  if [ -z "$MQTT_MODE" ]; then
    MQTT_MODE="2"
  elif [[ $MQTT_MODE != "0" && $MQTT_MODE != "1" && $MQTT_MODE != "2" ]]; then
    fatal "Invalid entry for MQTT_MODE arguement. Availables inputs are 0 , 1 or 2"
    ERROR=true
  fi
  if [ -z "$SSL_CERT" ]; then
    SSL_CERT="LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJWekNCL3FBREFnRUNBZ0VBTUFvR0NDcUdTTTQ5QkFNQ01DTXhJVEFmQmdOVkJBTU1HR3N6Y3kxelpYSjIKWlhJdFkyRkFNVFUzTVRFME5qazNNREFlRncweE9URXdNVFV4TXpReU5UQmFGdzB5T1RFd01USXhNelF5TlRCYQpNQ014SVRBZkJnTlZCQU1NR0dzemN5MXpaWEoyWlhJdFkyRkFNVFUzTVRFME5qazNNREJaTUJNR0J5cUdTTTQ5CkFnRUdDQ3FHU000OUF3RUhBMElBQk5tOE9IS1NtM0JmMnJVS3NiTG1reHcxYURZWXpXVFp3TVhiVmlSbWtEcHQKdFJCTHFHREVVWnVZcXU5VThVZnZQaWErWi9WTTNoL3Q1SkN5cklncEM1V2pJekFoTUE0R0ExVWREd0VCL3dRRQpBd0lDcERBUEJnTlZIUk1CQWY4RUJUQURBUUgvTUFvR0NDcUdTTTQ5QkFNQ0EwZ0FNRVVDSUFqQ2t3N2p6QXdCCmhCY1FndjBiRXdzNit5dUh1THMyUVkva015WnNCNk9rQWlFQTdwdnNyMGtMc0JzS2FDL0JIeisrS0Z6ZkFYNXEKZEphYlN6Zml2d1U2UzZzPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg=="
  fi
  if [ -z "$USER_NAME" ]; then
    USER_NAME="admin"
  fi
  if [ -z "$USER_PASS" ]; then
    fatal "The user password is not set. The USER_PASS argument is mandatory."
    ERROR=true
  fi
  if $ERROR; then
    info "Deployement aborded, please set the needed arguements"
    exit 1
  fi
}

download_binary() {
  wget -q -O $PWD/.edgeSite/edgesite https://github.com/cetic/Kubeedge-edgeSite-deploy/releases/download/v1.1.0/edgesite$SUFFIX
  chmod +x $PWD/.edgeSite/edgesite
}

cd ~
CURRENT=$PWD
info "Checking the arguments"
export $* >/dev/null 2>&1
check_args
info "Get architecture information"
setup_verify_arch
info "Create file tree"
mkdir -p ~/.edgeSite/conf/
deploy_files
info "Get the edgeSite binary"
download_binary
verify_system
info "Create edgeSite service"
create_service
info "edgeSite deploy on a $ARCH architecture whose the master is located at $K3S_SERVER_URL"
