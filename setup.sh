#!/bin/bash
set -e

CONTAINER_NAME="server"
AGENT_APP_SRC="/Users/dave1392857/Downloads/agent-app-leak"

# 기존 컨테이너 정리 (재실행 대비)
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo ">>> 기존 '$CONTAINER_NAME' 컨테이너를 제거합니다."
  docker rm -f "$CONTAINER_NAME"
fi

# ────────────────────────────────────────────────────
# 1. 컨테이너 생성 (기능 보안 및 네트워크 설정)
# ────────────────────────────────────────────────────
echo ""
echo "=== [1/15] 컨테이너 생성 (ubuntu:noble) ==="
docker run -dit \
  --name "$CONTAINER_NAME" \
  --init \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -p 15034:15034 \
  ubuntu:noble \
  /bin/bash

# ────────────────────────────────────────────────────
# 2. 패키지 업데이트 / 설치 / 타임존 설정
# ────────────────────────────────────────────────────
echo ""
echo "=== [2/15] 패키지 설치 및 타임존 설정 (Asia/Seoul) ==="
docker exec "$CONTAINER_NAME" bash -c "
  apt-get update -q &&
  DEBIAN_FRONTEND=noninteractive TZ=Asia/Seoul \
    apt-get install -y openssh-server ufw tzdata iproute2 cron nano bc &&
  ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime &&
  echo 'Asia/Seoul' > /etc/timezone
"

# ────────────────────────────────────────────────────
# 3. SSH 설정 (포트 20022 변경 / root 원격 로그인 차단)
# ────────────────────────────────────────────────────
echo ""
echo "=== [3/15] SSH 설정 — 포트 20022 / PermitRootLogin no ==="
docker exec "$CONTAINER_NAME" bash -c "
  sed -i 's/#Port 22/Port 20022/' /etc/ssh/sshd_config &&
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config &&
  service ssh restart
"

# ────────────────────────────────────────────────────
# 4. UFW 방화벽 설정
# ────────────────────────────────────────────────────
echo ""
echo "=== [4/15] UFW 방화벽 설정 (20022/tcp, 15034/tcp 허용) ==="
docker exec "$CONTAINER_NAME" bash -c "
  ufw default deny incoming &&
  ufw default allow outgoing &&
  ufw allow 20022/tcp &&
  ufw allow 15034/tcp &&
  ufw --force enable
"

# ────────────────────────────────────────────────────
# 5. 계정 생성 (agent-admin / agent-dev / agent-test)
# ────────────────────────────────────────────────────
echo ""
echo "=== [5/15] 계정 생성 (agent-admin / agent-dev / agent-test) ==="
docker exec "$CONTAINER_NAME" bash -c "
  useradd -m -s /bin/bash agent-admin &&
  echo 'agent-admin:Admin1234!' | chpasswd &&
  useradd -m -s /bin/bash agent-dev &&
  echo 'agent-dev:Dev1234!'   | chpasswd &&
  useradd -m -s /bin/bash agent-test &&
  echo 'agent-test:Test1234!' | chpasswd
"

# ────────────────────────────────────────────────────
# 6. 그룹 생성 및 계정 추가
#    agent-common: admin + dev + test
#    agent-core  : admin + dev
# ────────────────────────────────────────────────────
echo ""
echo "=== [6/15] 그룹 생성 및 계정 추가 (agent-common / agent-core) ==="
docker exec "$CONTAINER_NAME" bash -c "
  groupadd agent-common &&
  usermod -aG agent-common agent-admin &&
  for user in agent-dev agent-test; do usermod -aG agent-common \$user; done &&
  groupadd agent-core &&
  for user in agent-admin agent-dev; do usermod -aG agent-core \$user; done
"

# ────────────────────────────────────────────────────
# 7. 디렉토리 구조 및 권한 설정
#    /opt/agent/upload_files  → agent-common (770)
#    /opt/agent/api_keys      → agent-core   (770)
#    /var/log/agent-app       → agent-core   (770)
# ────────────────────────────────────────────────────
echo ""
echo "=== [7/15] 디렉토리 구조 및 권한 설정 ==="
docker exec "$CONTAINER_NAME" bash -c "
  mkdir -p /var/log/agent-app &&
  chown root:agent-core /var/log/agent-app &&
  chmod 770 /var/log/agent-app
"

# ────────────────────────────────────────────────────
# 8. 앱 디렉토리 / 키 파일 생성 + 바이너리 복사
# ────────────────────────────────────────────────────
echo ""
echo "=== [8/15] 앱 디렉토리·키 파일 생성 및 agent-app 바이너리 복사 ==="
docker exec "$CONTAINER_NAME" bash -c "
  mkdir -p /home/agent-admin/agent-app/api_keys \
           /home/agent-admin/agent-app/upload_files &&
  echo 'agent_api_key_test' > /home/agent-admin/agent-app/api_keys/secret.key &&
  chown agent-admin:agent-admin /home/agent-admin/agent-app &&
  chown root:agent-common /home/agent-admin/agent-app/upload_files &&
  chmod 770 /home/agent-admin/agent-app/upload_files &&
  chown root:agent-core /home/agent-admin/agent-app/api_keys &&
  chmod 770 /home/agent-admin/agent-app/api_keys &&
  chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys/secret.key &&
  chmod 660 /home/agent-admin/agent-app/api_keys/secret.key
"

# 컨테이너 아키텍처 확인 후 맞는 바이너리 선택
CONTAINER_ARCH=$(docker exec "$CONTAINER_NAME" uname -m)
if [ "$CONTAINER_ARCH" = "aarch64" ]; then
  SRC_BINARY_NAME="agent-leak-app-arm64"
  BINARY_NAME="agent-leak-app-arm64"
else
  SRC_BINARY_NAME="agent-leak-app-x86"
  BINARY_NAME="agent-leak-app-x86"
fi
echo ">>> 컨테이너 아키텍처: $CONTAINER_ARCH → $SRC_BINARY_NAME 복사"

docker cp "$AGENT_APP_SRC/$SRC_BINARY_NAME" "$CONTAINER_NAME:/home/agent-admin/agent-app/$BINARY_NAME"

docker exec "$CONTAINER_NAME" bash -c "
  chown agent-admin:agent-admin /home/agent-admin/agent-app/$BINARY_NAME &&
  chmod +x /home/agent-admin/agent-app/$BINARY_NAME
"

# ────────────────────────────────────────────────────
# 9. 시스템 환경 변수 설정 (/etc/environment)
#    su - 로그인 셸 전환 시 PAM이 자동 로드 — 중복 export 불필요
# ────────────────────────────────────────────────────
echo ""
echo "=== [9/15] 시스템 환경 변수 설정 (/etc/environment) ==="
docker exec "$CONTAINER_NAME" bash -c "
  cat >> /etc/environment << 'EOF'
AGENT_HOME=/home/agent-admin/agent-app
AGENT_PORT=15034
AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
AGENT_LOG_DIR=/var/log/agent-app
MEMORY_LIMIT=256
CPU_MAX_OCCUPY=50
MULTI_THREAD_ENABLE=true
EOF

  echo '--- /etc/environment ---'
  cat /etc/environment
"

# ────────────────────────────────────────────────────
# 11. monitor.sh 파일 생성 및 권한 설정
#     /home/agent-admin/agent-app/bin/monitor.sh
#     owner: agent-dev:agent-core / 750
# ────────────────────────────────────────────────────
echo ""
echo "=== [11] monitor.sh 파일 생성 및 권한 설정 ==="
docker exec "$CONTAINER_NAME" bash -c "
  mkdir -p /home/agent-admin/agent-app/bin &&
  touch /home/agent-admin/agent-app/bin/monitor.sh &&
  chown agent-dev:agent-core /home/agent-admin/agent-app/bin/monitor.sh &&
  chmod 750 /home/agent-admin/agent-app/bin/monitor.sh &&
  ls -l /home/agent-admin/agent-app/bin/monitor.sh
"

# ────────────────────────────────────────────────────
# 12. cron 설치 및 편집
#     */1 * * * * monitor.sh >> monitor.log
# ────────────────────────────────────────────────────
echo ""
echo "=== [12] cron 설치 및 편집 ==="
docker exec "$CONTAINER_NAME" bash -c "
  service cron start &&
  echo '*/1 * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor.log 2>&1' \
    | crontab -u agent-admin - &&
  echo '--- cron 상태 ---' &&
  service cron status &&
  echo '' &&
  echo '--- crontab (agent-admin) ---' &&
  crontab -u agent-admin -l | grep -v '^#' | grep -v '^\$'
"

# ────────────────────────────────────────────────────
# 13. 헬스체크 스크립트 작성 (총 스크립트)
# ────────────────────────────────────────────────────
echo ""
echo "=== [13] 헬스체크 스크립트 작성 ==="
MONITOR_TMP=$(mktemp)
cat > "$MONITOR_TMP" << MONEOF
#!/bin/bash

# /etc/environment 로드 (cron 환경 대비)
if [ -f /etc/environment ]; then
    set -a
    . /etc/environment
    set +a
fi

BINARY_NAME="$BINARY_NAME"
LOG_FILE=/var/log/agent-app/monitor.log
APP_LOG=/tmp/agent-run.log
TIMESTAMP=\$(date "+%Y-%m-%d %H:%M:%S")

# ──────────────────────────────────────────
# [1] 프로세스 확인
# ──────────────────────────────────────────
PID=\$(pgrep -f "\$BINARY_NAME" 2>/dev/null | head -1)

if [ -z "\$PID" ]; then
    echo "[\$TIMESTAMP] [ERROR] PROCESS:\$BINARY_NAME STATUS:not-running" >> "\$LOG_FILE"
    exit 0
fi

# ──────────────────────────────────────────
# [2] 프로세스별 CPU / 물리 메모리(RSS) 수집
# ──────────────────────────────────────────
CPU=\$(ps -p "\$PID" -o %cpu --no-headers 2>/dev/null | tr -d ' ')
RSS_KB=\$(ps -p "\$PID" -o rss --no-headers 2>/dev/null | tr -d ' ')
RSS_MB=\$(( \${RSS_KB:-0} / 1024 ))
MEM_TOTAL_KB=\$(grep MemTotal /proc/meminfo | awk '{print \$2}')
if [ -n "\$MEM_TOTAL_KB" ] && [ "\$MEM_TOTAL_KB" -gt 0 ]; then
    MEM_PCT=\$(echo "scale=1; \${RSS_KB:-0} * 100 / \$MEM_TOTAL_KB" | bc 2>/dev/null || echo "0.0")
else
    MEM_PCT="0.0"
fi

# ──────────────────────────────────────────
# [3] 시스템 디스크 / 포트 / 방화벽
# ──────────────────────────────────────────
DISK=\$(df / | tail -1 | awk '{print \$5}' | tr -d '%')

if ss -tln 2>/dev/null | grep -q ":15034"; then
    PORT_STATUS="active"
else
    PORT_STATUS="inactive"
fi

UFW_STATUS=\$(ufw status 2>/dev/null | grep "^Status:" | awk '{print \$2}')
[ -z "\$UFW_STATUS" ] && UFW_STATUS="unknown"

# ──────────────────────────────────────────
# [4] 메인 로그 기록
# ──────────────────────────────────────────
echo "[\$TIMESTAMP] PROCESS:\$BINARY_NAME PID:\$PID CPU:\${CPU:-0}% MEM:\${MEM_PCT}% RSS:\${RSS_MB}MB DISK:\${DISK}% PORT:\$PORT_STATUS FIREWALL:\$UFW_STATUS" >> "\$LOG_FILE"

# ──────────────────────────────────────────
# [5] 메모리 임계치 경고 (MEMORY_LIMIT)
# ──────────────────────────────────────────
if [ -n "\$MEMORY_LIMIT" ] && [ "\${RSS_MB:-0}" -ge "\${MEMORY_LIMIT}" ] 2>/dev/null; then
    echo "[\$TIMESTAMP] [WARNING] 메모리 임계치 도달: \${RSS_MB}MB >= \${MEMORY_LIMIT}MB" >> "\$LOG_FILE"
fi

# ──────────────────────────────────────────
# [6] CPU 임계치 경고 (CPU_MAX_OCCUPY)
# ──────────────────────────────────────────
if [ -n "\$CPU_MAX_OCCUPY" ] && [ -n "\$CPU" ]; then
    if awk "BEGIN { exit !(\${CPU:-0} > \${CPU_MAX_OCCUPY:-100}) }" 2>/dev/null; then
        echo "[\$TIMESTAMP] [WARNING] CPU 임계치 초과: \${CPU}% > \${CPU_MAX_OCCUPY}%" >> "\$LOG_FILE"
    fi
fi

# ──────────────────────────────────────────
# [7] 교착상태 감지 (앱 로그 변화 없음 + 프로세스 생존)
# ──────────────────────────────────────────
LAST_SIZE_FILE=/tmp/.agent_log_size
if [ -f "\$APP_LOG" ]; then
    CURRENT_LOG_SIZE=\$(stat -c%s "\$APP_LOG" 2>/dev/null || echo 0)
    if [ -f "\$LAST_SIZE_FILE" ]; then
        PREV_LOG_SIZE=\$(cat "\$LAST_SIZE_FILE" 2>/dev/null || echo 0)
        if [ "\$CURRENT_LOG_SIZE" -eq "\$PREV_LOG_SIZE" ]; then
            echo "[\$TIMESTAMP] [WARNING] 앱 로그 변화 없음 (Deadlock 의심) PID:\$PID 생존 중" >> "\$LOG_FILE"
        fi
    fi
    echo "\$CURRENT_LOG_SIZE" > "\$LAST_SIZE_FILE"
fi

# ──────────────────────────────────────────
# [8] 로그 용량 관리 (최대 10MB / 10개 파일)
# ──────────────────────────────────────────
MAX_SIZE=\$((10 * 1024 * 1024))
MAX_COUNT=10
if [ -f "\$LOG_FILE" ]; then
    CURRENT_SIZE=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
    if [ "\$CURRENT_SIZE" -gt "\$MAX_SIZE" ]; then
        for i in \$(seq \$MAX_COUNT -1 1); do
            [ -f "\${LOG_FILE}.\$((\$i-1))" ] && mv "\${LOG_FILE}.\$((\$i-1))" "\${LOG_FILE}.\${i}"
        done
        mv "\$LOG_FILE" "\${LOG_FILE}.1"
    fi
fi
MONEOF
docker cp "$MONITOR_TMP" "$CONTAINER_NAME:/home/agent-admin/agent-app/bin/monitor.sh"
rm -f "$MONITOR_TMP"

# docker cp로 덮어써진 권한 복원
docker exec "$CONTAINER_NAME" bash -c "
  chown agent-dev:agent-core /home/agent-admin/agent-app/bin/monitor.sh &&
  chmod 750 /home/agent-admin/agent-app/bin/monitor.sh
"

docker exec "$CONTAINER_NAME" bash -c "
  echo '--- monitor.sh 내용 ---'
  cat /home/agent-admin/agent-app/bin/monitor.sh
"

# ────────────────────────────────────────────────────
# 14. 바이너리앱 백그라운드 실행 (agent-admin)
# ────────────────────────────────────────────────────
echo ""
echo "=== [14] 바이너리앱 백그라운드 실행 (agent-admin) ==="
echo ""

echo "--- agent-app 바이너리 확인 ---"
docker exec "$CONTAINER_NAME" ls -la /home/agent-admin/agent-app/$BINARY_NAME 2>/dev/null || echo "(바이너리 없음)"
echo ""

docker exec "$CONTAINER_NAME" \
  su - agent-admin -c "
    cd /home/agent-admin/agent-app && nohup ./$BINARY_NAME > /tmp/agent-run.log 2>&1 &
    echo \$! > /tmp/agent-app.pid
  "

echo ">>> 'Agent READY' 대기 중..."
for i in $(seq 1 15); do
  if docker exec "$CONTAINER_NAME" grep -q "Agent READY" /tmp/agent-run.log 2>/dev/null; then
    docker exec "$CONTAINER_NAME" cat /tmp/agent-run.log
    break
  fi
  sleep 1
done

echo "--- agent-run.log ---"
docker exec "$CONTAINER_NAME" cat /tmp/agent-run.log 2>/dev/null || echo "(run log 없음)"

# ────────────────────────────────────────────────────
# 15. 프로세스 및 포트 확인
# ────────────────────────────────────────────────────
echo ""
echo "=== [15] 프로세스 및 포트 확인 ==="
echo ""
echo "--- 프로세스 (pgrep -f agent-app) ---"
docker exec "$CONTAINER_NAME" pgrep -f agent-app || echo "(실행 중인 agent-app 없음)"
echo ""
echo "--- 포트 (ss -tlnp | grep 15034) ---"
docker exec "$CONTAINER_NAME" ss -tlnp | grep 15034 || echo "(15034 포트 미감지)"

# ────────────────────────────────────────────────────
# 16. monitor.log 헬스체크 결과 출력
# ────────────────────────────────────────────────────
echo ""
echo "=== [16] monitor.log 헬스체크 결과 출력 ==="
echo ""
echo ">>> Health Check 실행 중 (5회)..."
docker exec "$CONTAINER_NAME" bash -c "
  for i in 1 2 3 4 5; do
    bash /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor.log 2>&1 || true
    sleep 1
  done
"
echo ""
echo "--- cat /var/log/agent-app/monitor.log ---"
docker exec "$CONTAINER_NAME" cat /var/log/agent-app/monitor.log

echo ""
echo "================================================================"
echo "  완료."
echo "================================================================"
