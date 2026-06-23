# 미션 수행 가이드 — agent-leak-app 장애 분석

## 환경 구성 요약 (setup.sh)

`setup.sh`를 실행하면 아래 구조의 Docker 컨테이너(`server`)가 준비된다.

```
컨테이너: server (ubuntu:noble)
실행 계정: agent-admin (비-root)
앱 경로:   /home/agent-admin/agent-app/<binary>
로그 경로: /tmp/agent-run.log          ← 앱 실행 로그 (MemoryGuard, Watchdog 등)
관제 로그: /var/log/agent-app/monitor.log ← monitor.sh 수집 로그
관제 주기: cron (매 1분, agent-admin 계정)
```

### 핵심 환경변수 (`/etc/environment`)

| 변수 | 초기값 | 역할 |
|------|--------|------|
| `MEMORY_LIMIT` | `256` | MemoryGuard 임계치(MB) — 이 값 초과 시 앱이 스스로 종료 |
| `CPU_MAX_OCCUPY` | `50` | Watchdog 임계치(%) — 이 값 초과 시 앱이 스스로 종료 |
| `MULTI_THREAD_ENABLE` | `true` | 멀티스레드 활성화 여부 — `true`이면 Deadlock 발생 가능 |

---

## 로그 읽는 법

### 앱 실행 로그 (`/tmp/agent-run.log`)
앱 내부 정책(MemoryGuard, Watchdog)이 동작할 때 기록된다. 장애 원인의 핵심 증거.

```bash
docker exec server cat /tmp/agent-run.log
```

### 관제 로그 (`/var/log/agent-app/monitor.log`)
`monitor.sh`가 1분마다 기록하는 프로세스별 시계열 데이터.

```
[2025-01-01 14:00:00] PROCESS:agent-app-linux-arm64 PID:123 CPU:1.2% MEM:5.1% RSS:13MB DISK:12% PORT:active FIREWALL:active
[2025-01-01 14:01:00] [WARNING] 메모리 임계치 도달: 260MB >= 256MB
```

```bash
docker exec server tail -f /var/log/agent-app/monitor.log
```

---

## Mission 1 — 메모리 누수 원인 규명

### 원리
앱 내부에서 힙 메모리를 해제하지 않고 계속 쌓는다(Memory Leak).  
물리 메모리 사용량(RSS)이 `MEMORY_LIMIT`에 도달하면 `MemoryGuard` 정책이 프로세스를 강제 종료한다.

### setup.sh와의 연결

| setup.sh 위치 | 역할 |
|---------------|------|
| Step 9 `MEMORY_LIMIT=256` | Before 시나리오의 임계치 설정 |
| Step 13 monitor.sh `[5] 메모리 임계치 경고` | RSS >= MEMORY_LIMIT 시 WARNING 기록 |
| Step 14 앱 실행 | `/tmp/agent-run.log`에 MemoryGuard 로그 생성 |
| Step 12 cron | 1분마다 RSS 추이 자동 수집 |

### 관측 절차

```bash
# 1. 관제 로그 실시간 모니터링 (RSS 증가 패턴 확인)
docker exec server tail -f /var/log/agent-app/monitor.log

# 2. 프로세스별 메모리 직접 확인
docker exec server ps -p $(docker exec server pgrep -f agent-app) \
  -o pid,rss,vsz,%mem --no-headers

# 3. 앱 종료 후 원인 로그 확인
docker exec server cat /tmp/agent-run.log
```

### 예상 증거 로그

```
# monitor.log — RSS가 선형 증가
[14:00] ... RSS:13MB ...
[14:03] ... RSS:120MB ...
[14:06] ... RSS:230MB ...
[14:07] [WARNING] 메모리 임계치 도달: 258MB >= 256MB

# agent-run.log — MemoryGuard 정책 동작
[CRITICAL] [MemoryGuard] Memory limit exceeded (258MB >= 256MB)
[CRITICAL] [MemoryGuard] Self-terminating process 123 to prevent system instability.
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```

### Before & After — `MEMORY_LIMIT` 조정

```bash
# 컨테이너 안에서 환경변수 수정
docker exec server sed -i 's/MEMORY_LIMIT=256/MEMORY_LIMIT=512/' /etc/environment

# 앱 재시작
docker exec server su - agent-admin -c "
  cd /home/agent-admin/agent-app &&
  nohup ./agent-app-linux-arm64 > /tmp/agent-run.log 2>&1 &
"
```

| | Before (256MB) | After (512MB) |
|--|----------------|---------------|
| 종료 시점 | 약 10분 후 | 약 30분 이상 생존 |
| 근본 원인 | 동일 (Memory Leak) | 동일 — 임시 조치에 불과 |

---

## Mission 2 — CPU 과점유 분석

### 원리
앱 내부 특정 구간에서 CPU 사용률이 급격히 상승한다.  
`CPU_MAX_OCCUPY`를 초과하면 `Watchdog` 정책이 프로세스에 SIGTERM을 보내 종료한다.

### setup.sh와의 연결

| setup.sh 위치 | 역할 |
|---------------|------|
| Step 9 `CPU_MAX_OCCUPY=50` | Before 시나리오의 Watchdog 임계치 |
| Step 13 monitor.sh `[6] CPU 임계치 경고` | 프로세스 CPU% > CPU_MAX_OCCUPY 시 WARNING 기록 |
| Step 14 앱 실행 | `/tmp/agent-run.log`에 Watchdog 로그 생성 |

### 관측 절차

```bash
# 1. 프로세스별 CPU 실시간 확인
docker exec server top -b -n 1 -p $(docker exec server pgrep -f agent-app)

# 2. 관제 로그에서 CPU 급등 구간 확인
docker exec server grep "WARNING" /var/log/agent-app/monitor.log

# 3. 앱 종료 후 Watchdog 로그 확인
docker exec server cat /tmp/agent-run.log
```

### 예상 증거 로그

```
# monitor.log — CPU 급등 후 WARNING
[14:10:00] ... CPU:2.1% ...
[14:11:00] ... CPU:73.5% ...
[14:11:00] [WARNING] CPU 임계치 초과: 73.5% > 50%

# agent-run.log — Watchdog 정책 동작
[WARNING] [Watchdog] CPU usage exceeded limit (73.5% > 50%)
[SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)
>>> [SYSTEM] SELF-TERMINATED (CPU Watchdog) <<<
```

### Before & After — `CPU_MAX_OCCUPY` 조정

```bash
# 임계치 상향 (50 → 90)
docker exec server sed -i 's/CPU_MAX_OCCUPY=50/CPU_MAX_OCCUPY=90/' /etc/environment

# 앱 재시작
docker exec server su - agent-admin -c "
  cd /home/agent-admin/agent-app &&
  nohup ./agent-app-linux-arm64 > /tmp/agent-run.log 2>&1 &
"
```

| | Before (50%) | After (90%) |
|--|--------------|-------------|
| Watchdog 발동 | CPU 50% 초과 즉시 | CPU 90% 초과 시 |
| 프로세스 생존 시간 | 짧음 | 더 오래 생존 또는 미종료 |

---

## Mission 3 — 교착상태(Deadlock) 진단

### 원리
`MULTI_THREAD_ENABLE=true`일 때 멀티스레드로 동작하며, 서로 다른 스레드가 상대방의 자원을 무한히 기다리는 **순환 대기** 상태에 빠진다.

교착상태 4대 조건이 모두 충족된다:
- **상호 배제**: 각 스레드가 자원을 독점적으로 점유
- **점유 대기**: 자원을 쥔 채로 다른 자원을 기다림
- **비선점**: 점유한 자원을 강제로 빼앗을 수 없음
- **순환 대기**: Thread-A → Thread-B → Thread-A 방식으로 무한 대기

### setup.sh와의 연결

| setup.sh 위치 | 역할 |
|---------------|------|
| Step 9 `MULTI_THREAD_ENABLE=true` | Deadlock 발생 시나리오 활성화 |
| Step 13 monitor.sh `[7] 교착상태 감지` | 앱 로그 파일 크기 변화 없음 + PID 생존 시 WARNING 기록 |

### 관측 절차

```bash
# 1. 프로세스 생존 확인 (PID 존재)
docker exec server pgrep -f agent-app

# 2. CPU / 메모리 변화 없음 확인 (무응답 상태)
docker exec server ps -p $(docker exec server pgrep -f agent-app) \
  -o pid,stat,pcpu,rss --no-headers
# stat 컬럼이 'S' (sleeping) 고착, CPU 거의 0

# 3. 스레드별 상태 확인
docker exec server ps -p $(docker exec server pgrep -f agent-app) -L \
  -o pid,lwp,stat,pcpu --no-headers

# 4. 앱 로그 마지막 기록 확인 (로그가 멈춘 지점)
docker exec server tail -20 /tmp/agent-run.log

# 5. 관제 로그에서 Deadlock 경고 확인
docker exec server grep "Deadlock" /var/log/agent-app/monitor.log
```

### 예상 증거 로그

```
# agent-run.log — 마지막 기록에서 스레드 대기 상태
[INFO] [Thread-A] Acquired Lock-1, waiting for Lock-2...
[INFO] [Thread-B] Acquired Lock-2, waiting for Lock-1...
# ← 이후 로그 없음 (무한 대기)

# monitor.log — Deadlock 감지 경고
[14:15:00] PROCESS:agent-app PID:123 CPU:0% MEM:5.1% ...
[14:16:00] [WARNING] 앱 로그 변화 없음 (Deadlock 의심) PID:123 생존 중
[14:17:00] [WARNING] 앱 로그 변화 없음 (Deadlock 의심) PID:123 생존 중
```

### Before & After — `MULTI_THREAD_ENABLE` 조정

```bash
# 멀티스레드 비활성화 (Deadlock 회피)
docker exec server sed -i 's/MULTI_THREAD_ENABLE=true/MULTI_THREAD_ENABLE=false/' /etc/environment

# 기존 프로세스 종료 후 재시작
docker exec server kill $(docker exec server pgrep -f agent-app)
docker exec server su - agent-admin -c "
  cd /home/agent-admin/agent-app &&
  nohup ./agent-app-linux-arm64 > /tmp/agent-run.log 2>&1 &
"
```

| | Before (`true`) | After (`false`) |
|--|-----------------|-----------------|
| 스레드 수 | 멀티스레드 | 단일 스레드 |
| Deadlock | 발생 (무응답) | 미발생 (정상 동작) |
| 로그 지속 여부 | 특정 시점 이후 정지 | 계속 기록 |

---

## Bonus — 스케줄링 알고리즘 추론

### 관측 방법

```bash
# 정상 실행 중 앱 로그에서 Worker 스레드 순서 패턴 분석
docker exec server cat /tmp/agent-run.log | grep "Thread"
```

### 판별 기준

| 패턴 | 알고리즘 |
|------|----------|
| 한 스레드가 100% 완료 후 다음 스레드 시작 | FCFS |
| 특정 스레드가 우선적으로 자주 실행됨 | Priority |
| 모든 스레드가 일정 간격으로 번갈아 실행됨 | Round-Robin |

---

## 공통 유틸 명령어

```bash
# 환경변수 현재 값 확인
docker exec server cat /etc/environment

# 관제 로그 전체 출력
docker exec server cat /var/log/agent-app/monitor.log

# 앱 수동 재시작
docker exec server kill $(docker exec server pgrep -f agent-app) 2>/dev/null || true
docker exec server su - agent-admin -c "
  cd /home/agent-admin/agent-app &&
  nohup ./agent-app-linux-arm64 > /tmp/agent-run.log 2>&1 &
"

# monitor.sh 수동 실행 (즉시 1회 수집)
docker exec server bash /home/agent-admin/agent-app/bin/monitor.sh

# cron 상태 확인
docker exec server service cron status
docker exec server crontab -u agent-admin -l
```
