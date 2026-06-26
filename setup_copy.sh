#!/bin/bash
set -e

CONTAINER_NAME="server2"
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
    apt-get install -y openssh-server ufw tzdata iproute2 nano bc acl &&
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
  chmod 770 /var/log/agent-app &&
  touch /var/log/agent-app/monitor.log &&
  chown agent-admin:agent-core /var/log/agent-app/monitor.log &&
  chmod 750 /var/log/agent-app/monitor.log
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
CPU_MAX_OCCUPY=30
MULTI_THREAD_ENABLE=false
EOF

  echo '--- /etc/environment ---'
  cat /etc/environment
"

# ────────────────────────────────────────────────────
# 11. monitor.sh 파일 생성 및 권한 설정
#     /home/agent-admin/agent-app/bin/monitor.sh
#     owner: agent-admin:agent-core / 750
# ────────────────────────────────────────────────────
echo ""
echo "=== [11] monitor.sh 파일 생성 및 권한 설정 ==="
docker exec "$CONTAINER_NAME" bash -c "
  mkdir -p /home/agent-admin/agent-app/bin &&
  touch /home/agent-admin/agent-app/bin/monitor.sh &&
  chown agent-admin:agent-core /home/agent-admin/agent-app/bin/monitor.sh &&
  chmod 750 /home/agent-admin/agent-app/bin/monitor.sh &&
  ls -l /home/agent-admin/agent-app/bin/monitor.sh
"

# ────────────────────────────────────────────────────
# 12. (skipped) monitor.sh는 while 루프 내장 — cron 불필요
#     앱 실행 후 [14-b] 에서 백그라운드 데몬으로 실행
# ────────────────────────────────────────────────────

# ────────────────────────────────────────────────────
# 13. 헬스체크 스크립트 작성 (총 스크립트)
# ────────────────────────────────────────────────────
echo ""
echo "=== [13] 헬스체크 스크립트 작성 ==="
MONITOR_TMP=$(mktemp)
cat > "$MONITOR_TMP" << MONEOF
#!/bin/bash

BINARY_NAME="$BINARY_NAME"
LOG_FILE=/var/log/agent-app/monitor.log
APP_LOG=/tmp/agent-run.log

PREV_LOG_TIME=0
DEADLOCK_COUNT=0
PREV_PID=""

while true; do
    TIMESTAMP=\$(date "+%Y-%m-%d %H:%M:%S")

    # ──────────────────────────────────────────
    # 환경변수 재로드 — /etc/environment 변경 시 즉시 반영
    # CPU_MAX_OCCUPY=50%  → 50
    # MEMORY_LIMIT=256MB  → 256 (MB 단위)
    # ──────────────────────────────────────────
    if [ -f /etc/environment ]; then
        set -a
        . /etc/environment
        set +a
    fi
    CPU_THRESHOLD=\${CPU_MAX_OCCUPY//%/}
    MEM_THRESHOLD=\${MEMORY_LIMIT//MB/}
    MEM_WARN_MB=\$(( \${MEM_THRESHOLD:-256} * 80 / 100 ))
    CPU_WARN_PCT=\$(( \${CPU_THRESHOLD:-100} * 40 / 100 ))
    PID=\$(pgrep -f "\$BINARY_NAME" 2>/dev/null | head -1)

    # ── 프로세스 없으면 에러 로그 후 평상시 간격 유지
    if [ -z "\$PID" ]; then
        echo "[\$TIMESTAMP] [ERROR] PROCESS:\$BINARY_NAME STATUS:not-running" >> "\$LOG_FILE"
        PREV_PID=""
        sleep 5
        continue
    fi

    # ── 새 PID 감지 시 이전 실행 잔존 데이터 리셋
    if [ "\$PID" != "\$PREV_PID" ]; then
        DEADLOCK_COUNT=0
        PREV_LOG_TIME=0
    fi

    # ── 현재 지표 수집
    CPU=\$(ps -p "\$PID" -o %cpu= 2>/dev/null | tr -d ' ')
    CPU_APP=\$(grep "Current Load:" "\$APP_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tr -d '%')
    HEAP_MB=\$(grep "Current Heap:" "\$APP_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1)
    DISK=\$(df / | tail -1 | awk '{print \$5}' | tr -d '%')
    if ss -tln 2>/dev/null | grep -q ":15034"; then
        PORT_STATUS="active"
    else
        PORT_STATUS="inactive"
    fi
    UFW_STATUS=\$(ufw status 2>/dev/null | grep "^Status:" | awk '{print \$2}')
    [ -z "\$UFW_STATUS" ] && UFW_STATUS="unknown"
    CURR_LOG_TIME=\$(stat -c %Y "\$APP_LOG" 2>/dev/null || echo 0)

    # ──────────────────────────────────────────
    # [4] 메인 상태 로그 기록 (매 주기)
    # ──────────────────────────────────────────
    echo "[\$TIMESTAMP] PROCESS:\$BINARY_NAME PID:\$PID CPU_OS:\${CPU:-0}% CPU_APP:\${CPU_APP:-0}% HEAP:\${HEAP_MB:-0}MB DISK:\${DISK}% PORT:\$PORT_STATUS FIREWALL:\$UFW_STATUS" >> "\$LOG_FILE"

    ANOMALY=false
    REASON=""

    # ── ① Memory 사전 경고 (Heap > MEMORY_LIMIT × 80%) → 집중 감시 전환
    if [ -n "\$HEAP_MB" ] && [ "\${HEAP_MB:-0}" -gt "\$MEM_WARN_MB" ] 2>/dev/null; then
        ANOMALY=true
        REASON="\${REASON:+\$REASON | }Memory 경고 (Heap:\${HEAP_MB}MB >= 경고선\${MEM_WARN_MB}MB, 한계:\${MEM_THRESHOLD:-256}MB)"
    fi

    # ── ② Memory Leak 감지 (Heap > MEMORY_LIMIT)
    if [ -n "\$HEAP_MB" ] && [ "\${HEAP_MB:-0}" -gt "\${MEM_THRESHOLD:-256}" ] 2>/dev/null; then
        ANOMALY=true
        REASON="\${REASON:+\$REASON | }Memory Leak 의심 (Heap:\${HEAP_MB}MB >= \${MEM_THRESHOLD:-256}MB)"
    fi

    # ── ③ CPU 사전 경고 (CPU_APP > CPU_MAX_OCCUPY × 80%) → 집중 감시 전환
    if [ -n "\$CPU_APP" ] && awk "BEGIN { exit !(\${CPU_APP:-0} > \${CPU_WARN_PCT:-80}) }" 2>/dev/null; then
        ANOMALY=true
        REASON="\${REASON:+\$REASON | }CPU 경고 (CPU_APP:\${CPU_APP}% >= 경고선\${CPU_WARN_PCT}%, 한계:\${CPU_THRESHOLD:-100}%)"
    fi

    # ── ④ CPU 과점유 감지 (CPU_APP > CPU_MAX_OCCUPY)
    if [ -n "\$CPU_APP" ] && awk "BEGIN { exit !(\${CPU_APP:-0} > \${CPU_THRESHOLD:-100}) }" 2>/dev/null; then
        ANOMALY=true
        REASON="\${REASON:+\$REASON | }CPU 과점유 의심 (CPU_APP:\${CPU_APP}% >= \${CPU_THRESHOLD}%)"
    fi

    # ── ⑤ Deadlock 감지 (프로세스 생존 + 앱 로그 N사이클 연속 무변화)
    if [ "\$CURR_LOG_TIME" = "\$PREV_LOG_TIME" ] && kill -0 "\$PID" 2>/dev/null; then
        DEADLOCK_COUNT=\$(( DEADLOCK_COUNT + 1 ))
    else
        DEADLOCK_COUNT=0
    fi
    if [ "\$DEADLOCK_COUNT" -ge 3 ]; then
        ANOMALY=true
        REASON="\${REASON:+\$REASON | }Deadlock 의심 (로그 \${DEADLOCK_COUNT}회 연속 무변화, PID:\$PID 생존 중, MULTI_THREAD:\${MULTI_THREAD_ENABLE:-unknown})"
    fi

    # ── 적응형 간격 전환
    if [ "\$ANOMALY" = true ]; then
        echo "[\$TIMESTAMP] [ANOMALY] \$REASON" >> "\$LOG_FILE"
        sleep 1    # 이상 감지 → 집중 감시
    else
        sleep 5    # 정상 → 평상시 간격
    fi

    # ──────────────────────────────────────────
    # [8] 로그 용량 관리 (최대 10MB / 10개 파일)
    # ──────────────────────────────────────────
    MAX_SIZE=\$((10 * 1024 * 1024))
    MAX_COUNT=10
    if [ -f "\$LOG_FILE" ]; then
        CURRENT_SIZE=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
        if [ "\$CURRENT_SIZE" -gt "\$MAX_SIZE" ]; then
            for j in \$(seq \$MAX_COUNT -1 1); do
                [ -f "\${LOG_FILE}.\$((\$j-1))" ] && mv "\${LOG_FILE}.\$((\$j-1))" "\${LOG_FILE}.\${j}"
            done
            mv "\$LOG_FILE" "\${LOG_FILE}.1"
        fi
    fi

    PREV_LOG_TIME=\$CURR_LOG_TIME
    PREV_PID=\$PID
done
MONEOF
docker cp "$MONITOR_TMP" "$CONTAINER_NAME:/home/agent-admin/agent-app/bin/monitor.sh"
rm -f "$MONITOR_TMP"

# docker cp로 덮어써진 권한 복원
docker exec "$CONTAINER_NAME" bash -c "
  chown agent-admin:agent-core /home/agent-admin/agent-app/bin/monitor.sh &&
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
    cd /home/agent-admin/agent-app && : > /tmp/agent-run.log && nohup bash -c \"./$BINARY_NAME 2>&1 | tee /tmp/agent-run.log\" > /dev/null &
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

docker exec "$CONTAINER_NAME" bash -c "
  chown agent-admin:agent-core /tmp/agent-run.log &&
  chmod 750 /tmp/agent-run.log
"

# ────────────────────────────────────────────────────
# 14-b. monitor.sh 백그라운드 데몬 실행 (적응형 모니터링)
# ────────────────────────────────────────────────────
echo ""
echo "=== [14-b] monitor.sh 백그라운드 데몬 실행 ==="
docker exec "$CONTAINER_NAME" bash -c "
  nohup bash /home/agent-admin/agent-app/bin/monitor.sh > /dev/null 2>&1 &
  echo \$! > /tmp/monitor.pid
  echo '>>> monitor.sh PID: '\$(cat /tmp/monitor.pid)
"

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
echo ">>> 15초 대기 후 로그 확인 (버스트 1회분)..."
sleep 15
echo ""
echo "--- cat /var/log/agent-app/monitor.log ---"
docker exec "$CONTAINER_NAME" cat /var/log/agent-app/monitor.log

# ────────────────────────────────────────────────────
# 16-b. monitor.sh 프로세스 종료
# ────────────────────────────────────────────────────
echo ""
echo "=== [16-b] monitor.sh 프로세스 종료 ==="
docker exec "$CONTAINER_NAME" bash -c "
  if [ -f /tmp/monitor.pid ]; then
    MONITOR_PID=\$(cat /tmp/monitor.pid)
    if kill -0 \$MONITOR_PID 2>/dev/null; then
      kill \$MONITOR_PID
      echo '>>> monitor.sh (PID: '\$MONITOR_PID') 종료 완료'
    else
      echo '>>> monitor.sh (PID: '\$MONITOR_PID') 이미 종료된 상태'
    fi
    rm -f /tmp/monitor.pid
  else
    echo '>>> /tmp/monitor.pid 파일 없음 — monitor.sh가 실행 중이 아닐 수 있습니다'
  fi
"

echo ""
echo "================================================================"
echo "  완료."
echo "================================================================"
