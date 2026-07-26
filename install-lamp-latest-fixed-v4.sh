#!/usr/bin/env bash
# ==============================================================================
# Apache + PHP + MySQL Installer
# Target OS  : Ubuntu 22.04 (jammy) / Ubuntu 24.04 (noble)
# PHP        : 8.5 (Ondrej PPA)
# MySQL      : 8.4 LTS (Oracle MySQL APT repository)
# Apache     : latest version available from the Ubuntu APT repository
#
# Usage:
#   chmod +x install-lamp-latest.sh
#   sudo ./install-lamp-latest.sh
#
# Optional environment variables:
#   PHP_VERSION=8.5
#   MYSQL_SERVER_ID=1
#   ENABLE_MYSQL_MASTER=1
#   MYSQL_BIND_ADDRESS=0.0.0.0
#   MYSQL_ROOT_PASSWORD='...'
#   MYSQL_ADMIN_USER='octopoda_master'
#   MYSQL_ADMIN_PASSWORD='...'
#   MYSQL_REPL_USER='replica_user'
#   MYSQL_REPL_PASSWORD='...'
#
# Passwords that are not supplied will be generated automatically and saved to:
#   /root/lamp-install-credentials.txt
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

PHP_VERSION="${PHP_VERSION:-8.5}"
MYSQL_SERVER_ID="${MYSQL_SERVER_ID:-1}"
ENABLE_MYSQL_MASTER="${ENABLE_MYSQL_MASTER:-1}"
MYSQL_BIND_ADDRESS="${MYSQL_BIND_ADDRESS:-0.0.0.0}"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-octopoda_master}"
MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-}"
MYSQL_REPL_USER="${MYSQL_REPL_USER:-replica_user}"
MYSQL_REPL_PASSWORD="${MYSQL_REPL_PASSWORD:-}"

CREDENTIAL_FILE="/root/lamp-install-credentials.txt"
LOG_FILE="/var/log/install-lamp-latest.log"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local exit_code=$?
    log "Installation failed at line ${BASH_LINENO[0]} (exit code ${exit_code})."
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root: sudo $0"
}

generate_password() {
    openssl rand -hex 16
}

wait_for_apt() {
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/cache/apt/archives/lock
        /var/lib/apt/lists/lock
    )
    local lock

    for lock in "${locks[@]}"; do
        while fuser "$lock" >/dev/null 2>&1; do
            log "Waiting for APT lock: $lock"
            sleep 3
        done
    done
}

apt_install() {
    wait_for_apt
    apt-get install -y --no-install-recommends "$@"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only."
    case "${VERSION_CODENAME:-}" in
        jammy|noble) ;;
        *) die "Supported releases: Ubuntu 22.04 (jammy) and 24.04 (noble). Detected: ${VERSION_CODENAME:-unknown}" ;;
    esac

    ARCH="$(dpkg --print-architecture)"
    [[ "$ARCH" == "amd64" ]] || die "Oracle MySQL APT packages in this script require amd64. Detected: $ARCH"

    CODENAME="$VERSION_CODENAME"
    log "Detected Ubuntu ${VERSION_ID} (${CODENAME}), architecture ${ARCH}."
}

cleanup_stale_mysql_repo() {
    # Remove stale/manual Oracle MySQL repository entries before the first apt update.
    # They can break all APT operations when an old signing key has expired.
    rm -f /etc/apt/sources.list.d/mysql-community.list \
          /etc/apt/sources.list.d/mysql.list \
          /etc/apt/keyrings/mysql.gpg \
          /usr/share/keyrings/mysql-apt-config.gpg
}

prepare_system() {
    log "Repairing any interrupted package operation."
    dpkg --configure -a
    wait_for_apt
    apt-get -f install -y

    log "Updating APT package indexes."
    wait_for_apt
    apt-get update

    apt_install \
        apache2 \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        openssl \
        software-properties-common \
        unzip
}

install_php() {
    log "Adding Ondrej PHP PPA."
    if ! grep -Rqs "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php
    fi

    wait_for_apt
    apt-get update

    local packages=(
        "php${PHP_VERSION}"
        "php${PHP_VERSION}-cli"
        "php${PHP_VERSION}-common"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-readline"
        "libapache2-mod-php${PHP_VERSION}"
    )

    log "Installing PHP ${PHP_VERSION} and common extensions."
    apt_install "${packages[@]}"

    local module
    while read -r module; do
        [[ -n "$module" ]] || continue
        [[ "$module" == "php${PHP_VERSION}" ]] || a2dismod "$module" || true
    done < <(find /etc/apache2/mods-enabled -maxdepth 1 -type l -name 'php*.load' -printf '%f\n' 2>/dev/null \
        | sed 's/\.load$//' | sort -u)

    a2enmod "php${PHP_VERSION}" rewrite headers ssl
    update-alternatives --set php "/usr/bin/php${PHP_VERSION}"

    cat > /etc/php/"${PHP_VERSION}"/apache2/conf.d/99-app.ini <<PHPINI
    date.timezone = Asia/Jakarta
    memory_limit = 512M
    upload_max_filesize = 100M
    post_max_size = 110M
    max_execution_time = 300
    max_input_time = 300
    expose_php = Off
    opcache.enable = 1
    opcache.validate_timestamps = 1
PHPINI

    cat > /etc/php/"${PHP_VERSION}"/cli/conf.d/99-app.ini <<PHPCLI
    date.timezone = Asia/Jakarta
    memory_limit = -1
PHPCLI
}

configure_apache() {
    log "Configuring Apache."
    if ! grep -RqsE '^[[:space:]]*ServerName[[:space:]]+' /etc/apache2/apache2.conf /etc/apache2/conf-enabled 2>/dev/null; then
        cat > /etc/apache2/conf-available/servername.conf <<'APACHECONF'
ServerName localhost
APACHECONF
        a2enconf servername
    fi

    apache2ctl configtest
    systemctl enable apache2
    systemctl restart apache2
}

install_mysql_repo() {
    if dpkg-query -W -f='${Status}' mysql-community-server 2>/dev/null | grep -q "install ok installed"; then
        log "Oracle MySQL Community Server is already installed; preserving existing data."
        return
    fi

    if dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q "install ok installed"; then
        die "A MySQL/MariaDB server is already installed. This script will not purge existing databases automatically."
    fi

    log "Installing the official MySQL APT configuration package for MySQL 8.4 LTS."

    # Clean manual/stale repository definitions first, including expired keys.
    cleanup_stale_mysql_repo

    local apt_config_deb="/tmp/mysql-apt-config.deb"
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$apt_config_deb" \
        "https://dev.mysql.com/get/mysql-apt-config_0.8.39-1_all.deb"

    # Preselect MySQL 8.4 LTS and disable preview products.
    echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts" | debconf-set-selections
    echo "mysql-apt-config mysql-apt-config/select-tools select Enabled" | debconf-set-selections
    echo "mysql-apt-config mysql-apt-config/select-preview select Disabled" | debconf-set-selections

    dpkg -i "$apt_config_deb" || apt-get -f install -y
    rm -f "$apt_config_deb"

    wait_for_apt
    apt-get update
}

install_mysql() {
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(generate_password)}"
    MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-$(generate_password)}"
    MYSQL_REPL_PASSWORD="${MYSQL_REPL_PASSWORD:-$(generate_password)}"

    install_mysql_repo

    if ! dpkg-query -W -f='${Status}' mysql-community-server 2>/dev/null | grep -q "install ok installed"; then
        log "Installing the latest MySQL 8.4 LTS package."

        echo "mysql-community-server mysql-community-server/root-pass password ${MYSQL_ROOT_PASSWORD}" \
            | debconf-set-selections
        echo "mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_ROOT_PASSWORD}" \
            | debconf-set-selections
        echo "mysql-community-server mysql-community-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" \
            | debconf-set-selections

        apt_install mysql-server
    fi

    systemctl enable mysql
    systemctl restart mysql

    for _ in {1..30}; do
        mysqladmin ping --silent >/dev/null 2>&1 && break
        sleep 2
    done
    mysqladmin ping --silent >/dev/null 2>&1 || die "MySQL did not become ready."

    local mysql_root=(mysql --protocol=socket -uroot)
    if ! "${mysql_root[@]}" -Nse "SELECT 1" >/dev/null 2>&1; then
        mysql_root=(mysql --protocol=socket -uroot "-p${MYSQL_ROOT_PASSWORD}")
    fi

    "${mysql_root[@]}" <<SQL
ALTER USER 'root'@'localhost'
    IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';

CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'%'
    IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ADMIN_PASSWORD}';
ALTER USER '${MYSQL_ADMIN_USER}'@'%'
    IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'%' WITH GRANT OPTION;

CREATE USER IF NOT EXISTS '${MYSQL_REPL_USER}'@'%'
    IDENTIFIED WITH caching_sha2_password BY '${MYSQL_REPL_PASSWORD}';
ALTER USER '${MYSQL_REPL_USER}'@'%'
    IDENTIFIED WITH caching_sha2_password BY '${MYSQL_REPL_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_REPL_USER}'@'%';
SQL

    if [[ "$ENABLE_MYSQL_MASTER" == "1" ]]; then
        log "Configuring MySQL as a GTID replication source."
        cat > /etc/mysql/mysql.conf.d/90-replication-source.cnf <<MYSQLCONF
[mysqld]
server-id = ${MYSQL_SERVER_ID}
bind-address = ${MYSQL_BIND_ADDRESS}

log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
sync_binlog = 1
binlog_expire_logs_seconds = 604800

gtid_mode = ON
enforce_gtid_consistency = ON
log_replica_updates = ON

innodb_flush_log_at_trx_commit = 1
MYSQLCONF
        systemctl restart mysql
    fi

    install -m 0600 /dev/null "$CREDENTIAL_FILE"
    cat > "$CREDENTIAL_FILE" <<CREDS
Generated on: $(date --iso-8601=seconds)

MySQL root:
  user: root
  host: localhost
  password: ${MYSQL_ROOT_PASSWORD}

MySQL administrator:
  user: ${MYSQL_ADMIN_USER}
  host: %
  password: ${MYSQL_ADMIN_PASSWORD}

MySQL replication:
  user: ${MYSQL_REPL_USER}
  host: %
  password: ${MYSQL_REPL_PASSWORD}
CREDS
    chmod 0600 "$CREDENTIAL_FILE"
}

install_composer() {
    log "Installing the latest Composer release."
    local expected actual

    curl -fsSL https://composer.github.io/installer.sig -o /tmp/composer.sig
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php

    expected="$(cat /tmp/composer.sig)"
    actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    [[ "$expected" == "$actual" ]] || die "Composer installer signature verification failed."

    php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer.sig /tmp/composer-setup.php
}

show_summary() {
    log "Installation completed successfully."
    echo
    echo "================ INSTALLED VERSIONS ================"
    apache2 -v | head -n 1
    php -v | head -n 1
    mysql --version
    composer --version
    echo "===================================================="
    echo
    echo "Apache status : $(systemctl is-active apache2)"
    echo "MySQL status  : $(systemctl is-active mysql)"
    echo "Credentials   : ${CREDENTIAL_FILE} (root-only, mode 600)"
    echo
    echo "IMPORTANT:"
    echo "  - MySQL listens on ${MYSQL_BIND_ADDRESS}; restrict TCP/3306 using UFW/security groups."
    echo "  - Test before opening port 3306 to the internet."
    echo "  - Review /etc/mysql/mysql.conf.d/90-replication-source.cnf."
}

main() {
    require_root
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"

    detect_os
    cleanup_stale_mysql_repo
    prepare_system
    install_php
    configure_apache
    install_mysql
    install_composer
    show_summary
}

main "$@"
