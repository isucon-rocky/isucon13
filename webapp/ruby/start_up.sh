#!/bin/bash

# 環境変数の設定
export ISUCON13_MYSQL_DIALCONFIG_NET="tcp"
export ISUCON13_MYSQL_DIALCONFIG_ADDRESS="127.0.0.1"
export ISUCON13_MYSQL_DIALCONFIG_PORT="3306"
export ISUCON13_MYSQL_DIALCONFIG_USER="isucon"
export ISUCON13_MYSQL_DIALCONFIG_DATABASE="isupipe"
export ISUCON13_MYSQL_DIALCONFIG_PARSETIME="true"
export ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS="52.193.198.181"
export ISUCON13_POWERDNS_DISABLED="false"

# bundle exec puma の実行
bundle exec puma --bind tcp://0.0.0.0:8080 --workers 8 --threads 0:8 --environment production