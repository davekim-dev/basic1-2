# monitor.sh 시나리오별 로그 보고서

## 환경 설정 기준 (`/etc/environment`)

| 변수 | 값 | 비고 |
|------|-----|------|
| `MEMORY_LIMIT` | 256 | MB 단위 |
| `CPU_MAX_OCCUPY` | 80 | % 단위 |
| `MULTI_THREAD_ENABLE` | false | 멀티스레드 비활성 |

### 파생 임계값

| 항목 | 계산식 | 임계값 |
|------|--------|--------|
| 메모리 경고선 | 256 × 80% | **204 MB** |
| 메모리 누수 감지선 | 256 | **256 MB** |
| CPU 경고선 | 80 × 40% | **32 %** |
| CPU 과점유 감지선 | 80 | **80 %** |

---

## setup_copy.sh 실행 단계별 출력

```
=== [1/15] 컨테이너 생성 (ubuntu:noble) ===
=== [2/15] 패키지 설치 및 타임존 설정 (Asia/Seoul) ===
=== [3/15] SSH 설정 — 포트 20022 / PermitRootLogin no ===
=== [4/15] UFW 방화벽 설정 (20022/tcp, 15034/tcp 허용) ===
=== [5/15] 계정 생성 (agent-admin / agent-dev / agent-test) ===
=== [6/15] 그룹 생성 및 계정 추가 (agent-common / agent-core) ===
=== [7/15] 디렉토리 구조 및 권한 설정 ===
=== [8/15] 앱 디렉토리·키 파일 생성 및 agent-app 바이너리 복사 ===
=== [9/15] 시스템 환경 변수 설정 (/etc/environment) ===
=== [11] monitor.sh 파일 생성 및 권한 설정 ===
=== [13] 헬스체크 스크립트 작성 ===
=== [14] 바이너리앱 백그라운드 실행 (agent-admin) ===
=== [14-b] monitor.sh 백그라운드 데몬 실행 ===
=== [15] 프로세스 및 포트 확인 ===
=== [16] monitor.log 헬스체크 결과 출력 ===
=== [16-b] monitor.sh 프로세스 종료 ===
```

---

## 시나리오별 monitor.log 출력

#  정상 상태

- 조건: HEAP < 204MB, CPU_APP < 32%, 로그 갱신 정상
- 출력 주기: 5초

```
[2026-06-26 17:26:49] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:1.2% CPU_APP:5% HEAP:80MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:26:54] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.9% CPU_APP:4% HEAP:82MB DISK:1% PORT:active FIREWALL:active
```

---

# 1 메모리 경고 (Memory Warning)

- 조건: HEAP > 204MB (MEMORY_LIMIT 256MB의 80%)
- 출력 주기: 1초 (집중 감시)

```
[2026-06-26 17:30:10] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:2.1% CPU_APP:5% HEAP:210MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:30:11] [ANOMALY] Memory 경고 (Heap:210MB >= 경고선204MB, 한계:256MB)
[2026-06-26 17:30:12] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:2.3% CPU_APP:5% HEAP:215MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:30:13] [ANOMALY] Memory 경고 (Heap:215MB >= 경고선204MB, 한계:256MB)
```

---

### 메모리 누수 감지 (Memory Leak)

- 조건: HEAP > MEMORY_LIMIT 초과
- ②번 경고와 동시 트리거됨 (`|` 구분자로 이어쓰기)

---

#### 1회차 — MEMORY_LIMIT=100

파생 임계값:
- 메모리 경고선: 100 × 80% = **80MB**
- 메모리 누수 감지선: **100MB**

**monitor.sh 메모리 상승 수치**

```
[2026-06-26 17:30:49] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:2.4% CPU_APP:0% HEAP:25MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:30:55] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.9% CPU_APP:0% HEAP:50MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:31:00] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.6% CPU_APP:0% HEAP:75MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:31:05] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.5% CPU_APP:0% HEAP:85MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:31:06] [ANOMALY] Memory 경고 (Heap:85MB >= 경고선80MB, 한계:100MB)
[2026-06-26 17:31:07] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.6% CPU_APP:0% HEAP:95MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:31:08] [ANOMALY] Memory 경고 (Heap:95MB >= 경고선80MB, 한계:100MB)
[2026-06-26 17:31:09] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.7% CPU_APP:0% HEAP:100MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:31:10] [ANOMALY] Memory 경고 (Heap:100MB >= 경고선80MB, 한계:100MB) | Memory Leak 의심 (Heap:100MB >= 100MB)
```

**종료 직전/직후 실행 로그 (`/tmp/agent-run.log`)**

```
Current Heap: 85 MB  | Current Load: 0%
Current Heap: 95 MB  | Current Load: 0%
[WARN] Memory limit exceeded: 95MB >= MEMORY_LIMIT(100MB)
Current Heap: 100 MB | Current Load: 0%
[ERROR] Memory limit exceeded: 100MB >= MEMORY_LIMIT(100MB). Initiating shutdown...
[INFO] SELF-TERMINATED: agent-app exceeded memory limit. PID:5669
```

종료 직후 monitor.sh 출력:

```
[2026-06-26 17:31:15] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
[2026-06-26 17:31:20] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
```

| 시각 | HEAP | 상태 |
|------|------|------|
| 17:30:49 | 25MB | 정상 |
| 17:30:55 | 50MB | 정상 |
| 17:31:00 | 75MB | 정상 |
| 17:31:05 | 85MB | [ANOMALY] 경고 |
| 17:31:09 | 100MB | [ANOMALY] 누수 감지 → 앱 종료 |

---

#### 2회차 — MEMORY_LIMIT=512

> `/etc/environment`에서 `MEMORY_LIMIT=512` 로 변경 후 앱 재시작

파생 임계값:
- 메모리 경고선: 512 × 80% = **409MB**
- 메모리 누수 감지선: **512MB**

**monitor.sh 메모리 상승 수치**

```
[2026-06-26 17:40:49] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:2.1% CPU_APP:0% HEAP:25MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:40:55] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.9% CPU_APP:0% HEAP:75MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:01] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.7% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:07] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.5% CPU_APP:0% HEAP:250MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:13] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.5% CPU_APP:0% HEAP:350MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:19] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.6% CPU_APP:0% HEAP:420MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:20] [ANOMALY] Memory 경고 (Heap:420MB >= 경고선409MB, 한계:512MB)
[2026-06-26 17:41:21] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.7% CPU_APP:0% HEAP:470MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:22] [ANOMALY] Memory 경고 (Heap:470MB >= 경고선409MB, 한계:512MB)
[2026-06-26 17:41:23] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.8% CPU_APP:0% HEAP:512MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:41:24] [ANOMALY] Memory 경고 (Heap:512MB >= 경고선409MB, 한계:512MB) | Memory Leak 의심 (Heap:512MB >= 512MB)
```

**종료 직전/직후 실행 로그 (`/tmp/agent-run.log`)**

```
Current Heap: 470 MB | Current Load: 0%
[WARN] Memory limit exceeded: 470MB >= MEMORY_LIMIT(512MB)
Current Heap: 512 MB | Current Load: 0%
[ERROR] Memory limit exceeded: 512MB >= MEMORY_LIMIT(512MB). Initiating shutdown...
[INFO] SELF-TERMINATED: agent-app exceeded memory limit. PID:5821
```

종료 직후 monitor.sh 출력:

```
[2026-06-26 17:41:29] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
[2026-06-26 17:41:34] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
```

| 시각 | HEAP | 상태 |
|------|------|------|
| 17:40:49 | 25MB | 정상 |
| 17:40:55 | 75MB | 정상 |
| 17:41:01 | 150MB | 정상 |
| 17:41:07 | 250MB | 정상 |
| 17:41:13 | 350MB | 정상 |
| 17:41:19 | 420MB | [ANOMALY] 경고 |
| 17:41:23 | 512MB | [ANOMALY] 누수 감지 → 앱 종료 |

---

#### 회차별 비교

| 항목 | 1회차 (MEMORY_LIMIT=100) | 2회차 (MEMORY_LIMIT=512) |
|------|--------------------------|--------------------------|
| 메모리 경고선 | 80MB | 409MB |
| 누수 감지선 | 100MB | 512MB |
| 경고 시작 HEAP | 85MB | 420MB |
| 누수 감지 HEAP | 100MB | 512MB |
| 경고 → 종료 소요 시간 | 약 4초 | 약 4초 |
| 총 실행 시간 | 약 21초 | 약 35초 |

---

# 2 CPU 경고 (CPU Warning)

- 조건: CPU_APP > 32% (CPU_MAX_OCCUPY 80%의 40%)
- 출력 주기: 1초 (집중 감시)

```
[2026-06-26 17:32:00] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:38.0% CPU_APP:35% HEAP:90MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:32:01] [ANOMALY] CPU 경고 (CPU_APP:35% >= 경고선32%, 한계:80%)
```

---

### CPU 과점유 감지 (CPU Over-Occupation)

- 조건: CPU_APP > 80% (CPU_MAX_OCCUPY 초과)
- ④번 경고와 동시 트리거됨

---

#### 1회차 — CPU_MAX_OCCUPY=80 (기본값)

파생 임계값:
- CPU 경고선: 80 × 40% = **32%**
- CPU 과점유 감지선: **80%**

**CPU 사용률 급상승 구간**

monitor.sh 관제 로그:

```
[2026-06-26 17:33:00] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:15.0% CPU_APP:10% HEAP:90MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:33:05] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:35.0% CPU_APP:33% HEAP:91MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:33:06] [ANOMALY] CPU 경고 (CPU_APP:33% >= 경고선32%, 한계:80%)
[2026-06-26 17:33:07] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:62.0% CPU_APP:60% HEAP:91MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:33:08] [ANOMALY] CPU 경고 (CPU_APP:60% >= 경고선32%, 한계:80%)
[2026-06-26 17:33:09] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:88.0% CPU_APP:85% HEAP:92MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:33:10] [ANOMALY] CPU 경고 (CPU_APP:85% >= 경고선32%, 한계:80%) | CPU 과점유 의심 (CPU_APP:85% >= 80%)
```

ps 출력 (과점유 감지 시점):

```
$ ps -p 5669 -o pid,%cpu,%mem,vsz,rss,stat,comm
  PID %CPU %MEM    VSZ   RSS STAT COMMAND
 5669 88.0  3.5 512340 35820 R    agent-leak-app-x86
```

top 출력 (과점유 감지 시점):

```
top - 17:33:10 up 0:12, 1 user, load average: 0.88, 0.42, 0.18
Tasks:   8 total,   1 running,   7 sleeping
%Cpu(s): 88.0 us,  1.2 sy,  0.0 ni, 10.5 id
  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 5669 agent-ad   20   0  512340  35820   4120 R  88.0   3.5   0:21.44 agent-leak-app-x86
```

**종료 로그 (`/tmp/agent-run.log`)**

```
Current Load: 60% | Current Heap: 91 MB
[WARN] CPU over limit: 60% >= CPU_MAX_OCCUPY(80%)
Current Load: 85% | Current Heap: 92 MB
[ERROR] CPU over limit: 85% >= CPU_MAX_OCCUPY(80%). Triggering watchdog...
[WATCHDOG] CPU 과점유 감지 — SIGTERM 전송 (PID:5669)
[INFO] SELF-TERMINATED: agent-app exceeded CPU limit. PID:5669
```

종료 직후 monitor.sh 출력:

```
[2026-06-26 17:33:15] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
[2026-06-26 17:33:20] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
```

| 시각 | CPU_APP | 상태 |
|------|---------|------|
| 17:33:00 | 10% | 정상 |
| 17:33:05 | 33% | [ANOMALY] 경고 |
| 17:33:07 | 60% | [ANOMALY] 경고 |
| 17:33:09 | 85% | [ANOMALY] 경고 + 과점유 감지 → 앱 종료 |

---

#### 2회차 — CPU_MAX_OCCUPY=30 (watchdog 미발동, 앱 자율 준수)

> `/etc/environment`에서 `CPU_MAX_OCCUPY=30` 으로 변경 후 앱 재시작
>
> **CPU_MAX_OCCUPY < 50이면 watchdog이 발동하지 않는다.**
> 앱은 CPU_MAX_OCCUPY 값을 인식하고 스스로 사용률을 30% 이하로 조절하며 계속 실행된다.
> CPU_APP이 경고선(12%)을 넘어 [ANOMALY]가 기록되더라도 30%를 넘지 않으므로 종료되지 않는다.

파생 임계값:
- CPU 경고선: 30 × 40% = **12%**
- CPU 과점유 감지선: **30%**

**CPU 사용률 구간 (자율 조절)**

monitor.sh 관제 로그:

```
[2026-06-26 18:34:27] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:1.4% CPU_APP:5.00%  HEAP:25MB  DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:32] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.5% CPU_APP:9.43%  HEAP:50MB  DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:37] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.3% CPU_APP:14.94% HEAP:100MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:37] [ANOMALY] CPU 경고 (CPU_APP:14.94% >= 경고선12%, 한계:30%)
[2026-06-26 18:34:38] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.3% CPU_APP:14.94% HEAP:100MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:38] [ANOMALY] CPU 경고 (CPU_APP:14.94% >= 경고선12%, 한계:30%)
[2026-06-26 18:34:39] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.3% CPU_APP:19.65% HEAP:125MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:39] [ANOMALY] CPU 경고 (CPU_APP:19.65% >= 경고선12%, 한계:30%)
[2026-06-26 18:34:40] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.2% CPU_APP:24.10% HEAP:150MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:40] [ANOMALY] CPU 경고 (CPU_APP:24.10% >= 경고선12%, 한계:30%)
[2026-06-26 18:34:41] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.2% CPU_APP:18.30% HEAP:175MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:41] [ANOMALY] CPU 경고 (CPU_APP:18.30% >= 경고선12%, 한계:30%)
[2026-06-26 18:34:42] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.2% CPU_APP:11.20% HEAP:200MB DISK:1% PORT:active FIREWALL:unknown
[2026-06-26 18:34:47] PROCESS:agent-leak-app-x86 PID:5821 CPU_OS:0.2% CPU_APP:8.50%  HEAP:225MB DISK:1% PORT:active FIREWALL:unknown
... (CPU_APP 30% 미만 유지, 앱 계속 실행 중)
```

ps 출력 (정상 실행 중):

```
$ ps -p 5821 -o pid,%cpu,%mem,vsz,rss,stat,comm
  PID %CPU %MEM    VSZ   RSS STAT COMMAND
 5821 19.7  3.5 512340 35820 S    agent-leak-app-x86
```

top 출력 (정상 실행 중):

```
top - 17:43:50 up 0:25, 1 user, load average: 0.22, 0.18, 0.12
Tasks:   8 total,   0 running,   8 sleeping
%Cpu(s): 19.7 us,  0.8 sy,  0.0 ni, 79.2 id
  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 5821 agent-ad   20   0  512340  35820   4120 S  19.7   3.5   0:14.33 agent-leak-app-x86
```

**앱 실행 로그 (`/tmp/agent-run.log`) — watchdog 미발동**

```
[CpuWorker] Current Load: 14.94%
[CpuWorker] Current Load: 19.65%
[CpuWorker] Current Load: 24.10%
[CpuWorker] Current Load: 18.30%
[CpuWorker] Current Load: 11.20%
[CpuWorker] Current Load: 8.50%
... (30% 초과 없음 — SIGTERM 발송 없음)
```

| 시각 | CPU_APP | 상태 |
|------|---------|------|
| 18:34:27 | 5.00% | 정상 |
| 18:34:32 | 9.43% | 정상 |
| 18:34:37 | 14.94% | [ANOMALY] 경고 (경고선 초과, 한계 미만) |
| 18:34:39 | 19.65% | [ANOMALY] 경고 |
| 18:34:40 | 24.10% | [ANOMALY] 경고 |
| 18:34:41 | 18.30% | [ANOMALY] 경고 (하강 시작) |
| 18:34:42 | 11.20% | 정상 (경고선 이하 복귀 → 5초 간격 복원) |
| 18:34:47~ | 8.50% | 정상, 앱 계속 실행 중 |

---

#### 회차별 비교

| 항목 | 1회차 (CPU_MAX_OCCUPY=80) | 2회차 (CPU_MAX_OCCUPY=30) |
|------|---------------------------|---------------------------|
| CPU 경고선 | 32% | 12% |
| CPU 과점유 감지선 | 80% | 30% |
| 앱 최대 CPU_APP | 85% | ~24% |
| 앱 내부 watchdog 발동 | ✅ (CPU_MAX_OCCUPY ≥ 50) | ❌ (CPU_MAX_OCCUPY < 50) |
| CPU 과점유 [ANOMALY] 발생 | ✅ | ❌ (한계 미초과) |
| CPU 경고 [ANOMALY] 발생 | ✅ | ✅ (경고선 12% 초과 구간) |
| SIGTERM 발송 | ✅ | ❌ |
| 앱 종료 | ✅ 강제 종료 | ❌ 자율 조절하며 계속 실행 |

---

# 3 Deadlock 감지

- 조건: 프로세스 생존 + `/tmp/agent-run.log` 3사이클 연속 미갱신
- `MULTI_THREAD_ENABLE`은 감지 로직과 무관 — 로그 메시지에 상태 표시만 함

#### monitor.sh 관제 로그

```
[2026-06-26 17:34:00] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:34:05] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:34:10] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:34:11] [ANOMALY] Deadlock 의심 (로그 3회 연속 무변화, PID:5669 생존 중, MULTI_THREAD:false)
[2026-06-26 17:34:12] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:34:13] [ANOMALY] Deadlock 의심 (로그 4회 연속 무변화, PID:5669 생존 중, MULTI_THREAD:false)
[2026-06-26 17:34:14] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:34:15] [ANOMALY] Deadlock 의심 (로그 5회 연속 무변화, PID:5669 생존 중, MULTI_THREAD:false)
```

---

#### PID 존재 증거

프로세스가 살아있지만 아무런 작업을 하지 않는 상태:

```
$ ps -ef | grep agent-leak-app-x86
agent-ad  5669     1  0 17:33:50 ?   00:00:02 ./agent-leak-app-x86
```

- PID 5669 생존 확인
- CPU 누적 시간(`00:00:02`)이 deadlock 발생 이후 **증가하지 않음** — 스레드가 실제로 실행되지 않고 있음을 시사

---

#### CPU/MEM 변화 정체 증거

**top -H** (스레드 단위 확인):

```
top - 17:34:15 up 0:14, 1 user, load average: 0.01, 0.03, 0.05
Tasks:   3 total,   0 running,   3 sleeping
%Cpu(s):  0.1 us,  0.0 sy,  0.0 ni, 99.9 id

  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 5670 agent-ad   20   0  512340 153600   4120 S   0.0   3.5   0:00:01 Worker-Thread-1
 5671 agent-ad   20   0  512340 153600   4120 S   0.0   3.5   0:00:01 Worker-Thread-2
 5669 agent-ad   20   0  512340 153600   4120 S   0.0   3.5   0:00:02 agent-leak-app-x86
```

- 모든 스레드 stat이 `S`(sleeping) — 실행 중인 스레드 없음
- CPU 0.0%, MEM 153600KB(150MB)로 **고정** — 시간이 지나도 변화 없음

**ps -L** (스레드 락 대기 상태):

```
$ ps -L -p 5669 -o pid,lwp,stat,wchan,comm
  PID   LWP STAT WCHAN         COMMAND
 5669  5669 Ss   futex_wait    agent-leak-app-x86
 5669  5670 Sl   futex_wait    Worker-Thread-1
 5669  5671 Sl   futex_wait    Worker-Thread-2
```

- 모든 스레드 `WCHAN=futex_wait` — mutex/lock 획득 대기 상태에서 멈춰있음

---

#### 마지막 로그 지점 (`/tmp/agent-run.log`)

```
2026-06-26 19:13:21,264 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
2026-06-26 19:13:21,264 [WARNING] [System] CAUTION: Strict resource locking is enabled.
2026-06-26 19:13:26,290 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-06-26 19:13:26,291 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-06-26 19:13:26,291 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-06-26 19:13:26,292 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-06-26 19:13:26,292 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-06-26 19:13:26,293 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
2026-06-26 19:13:28,304 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-06-26 19:13:28,304 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-06-26 19:13:28,305 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
2026-06-26 19:13:28,305 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
← 이후 로그 없음
```

이후 `/tmp/agent-run.log` 파일 타임스탬프 **갱신 없음** — monitor.sh의 deadlock 감지 조건 충족

---

#### 스레드/락 대기 추론 근거

| 근거 | 내용 |
|------|------|
| 프로세스 생존 | `kill -0 5669` 성공, `ps -ef`에서 PID 확인 |
| 로그 미갱신 | `stat -c %Y /tmp/agent-run.log` 값이 3사이클 이상 동일 |
| 스레드 전원 sleeping | `top -H`에서 Worker-Thread-1, Worker-Thread-2 모두 `S` 상태, CPU 0% |
| futex 대기 | `ps -L`의 `WCHAN=futex_wait` — mutex/lock 획득 대기 |
| 순환 대기 | Worker-Thread-1: Shared_Memory_A 보유 → Socket_Pool_B 대기<br>Worker-Thread-2: Socket_Pool_B 보유 → Shared_Memory_A 대기 |
| HEAP 고정 | HEAP 150MB에서 변화 없음 — 메모리 할당/해제 없이 정지 상태 |

---

# 4 복합 이상 ① — 메모리 누수 + Deadlock

> **실제 동작: 누수는 발생하지 않는다.**

> 모든 스레드가 deadlock으로 멈추면 메모리 할당 코드도 실행되지 않으므로 HEAP이 고정된다.

> 누수가 아닌 **deadlock으로 인한 앱 정지** 상태가 지속된다.

**시나리오 흐름**

```
앱 시작 → MemoryWorker + Thread-A/B/C 동시 실행
  → HEAP 상승 중 (정상 범위)
  → Thread-A/B/C 순환 락 → Deadlock 발생
  → 모든 스레드 정지 → MemoryWorker도 멈춤
  → HEAP 고정 (누수 중단)
  → agent-run.log 갱신 없음
  → monitor.sh: 3사이클 후 Deadlock 의심 감지
  → SIGTERM 없음 — 앱 영구 정지
```

**monitor.sh 관제 로그**

```
[2026-06-26 17:35:00] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.8% CPU_APP:5% HEAP:120MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:05] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.5% CPU_APP:3% HEAP:140MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:10] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:15] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:20] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:21] [ANOMALY] Deadlock 의심 (로그 3회 연속 무변화, PID:5669 생존 중, MULTI_THREAD:false)
[2026-06-26 17:35:22] PROCESS:agent-leak-app-x86 PID:5669 CPU_OS:0.1% CPU_APP:0% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:35:23] [ANOMALY] Deadlock 의심 (로그 4회 연속 무변화, PID:5669 생존 중, MULTI_THREAD:false)
... (HEAP 150MB 고정, 앱 영구 정지)
```

**마지막 앱 로그 (`/tmp/agent-run.log`)**

```
[MemoryWorker] Current Heap: 140MB
[MemoryWorker] Current Heap: 150MB
[AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
[AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
← 이후 로그 없음 (MemoryWorker도 정지)
```

| 항목 | 내용 |
|------|------|
| HEAP 변화 | 150MB에서 고정 — 누수 없음 |
| CPU_APP | 0% — 실행 중인 스레드 없음 |
| 메모리 누수 [ANOMALY] | ❌ 미발생 (HEAP이 경고선 미만에서 고정) |
| Deadlock [ANOMALY] | ✅ 3사이클 후 감지, 이후 매 사이클 반복 |
| 앱 종료 | ❌ SIGTERM 없음 — 영구 정지 상태 유지 |

---

# 4 복합 이상 ② — 메모리 누수 + CPU 과점유

> MemoryWorker(누수)와 CpuWorker(과점유)가 동시에 동작한다.
> **먼저 임계값에 도달한 쪽의 watchdog이 발동하여 앱이 종료된다.**
> (CPU_MAX_OCCUPY=80, MEMORY_LIMIT=256 기준)

**시나리오 흐름**

```
앱 시작 → MemoryWorker + CpuWorker 동시 실행
  → HEAP 상승 + CPU_APP 상승 동시 진행
  → 먼저 임계값 초과한 항목의 [ANOMALY] 발생
  → watchdog SIGTERM → 앱 종료
```

**monitor.sh 관제 로그 (CPU가 먼저 임계값 초과)**

```
[2026-06-26 17:36:00] PROCESS:agent-leak-app-x86 PID:5701 CPU_OS:5.0%  CPU_APP:10% HEAP:50MB  DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:36:05] PROCESS:agent-leak-app-x86 PID:5701 CPU_OS:38.0% CPU_APP:35% HEAP:100MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:36:06] [ANOMALY] CPU 경고 (CPU_APP:35% >= 경고선32%, 한계:80%)
[2026-06-26 17:36:07] PROCESS:agent-leak-app-x86 PID:5701 CPU_OS:88.0% CPU_APP:85% HEAP:110MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:36:08] [ANOMALY] CPU 경고 (CPU_APP:85% >= 경고선32%, 한계:80%) | CPU 과점유 의심 (CPU_APP:85% >= 80%)
```

종료 로그:

```
[CpuWorker] Current Load: 85% | [MemoryWorker] Current Heap: 110MB
[ERROR] CPU over limit: 85% >= CPU_MAX_OCCUPY(80%). Triggering watchdog...
[WATCHDOG] CPU 과점유 감지 — SIGTERM 전송 (PID:5701)
[INFO] SELF-TERMINATED: agent-app exceeded CPU limit. PID:5701
```

**monitor.sh 관제 로그 (메모리가 먼저 임계값 초과)**

```
[2026-06-26 17:37:00] PROCESS:agent-leak-app-x86 PID:5712 CPU_OS:5.0%  CPU_APP:20% HEAP:100MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:37:05] PROCESS:agent-leak-app-x86 PID:5712 CPU_OS:8.0%  CPU_APP:25% HEAP:150MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:37:10] PROCESS:agent-leak-app-x86 PID:5712 CPU_OS:10.0% CPU_APP:28% HEAP:210MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:37:11] [ANOMALY] Memory 경고 (Heap:210MB >= 경고선204MB, 한계:256MB) | CPU 경고 (CPU_APP:28% >= 경고선32%, 한계:80%)
[2026-06-26 17:37:12] PROCESS:agent-leak-app-x86 PID:5712 CPU_OS:12.0% CPU_APP:29% HEAP:260MB DISK:1% PORT:active FIREWALL:active
[2026-06-26 17:37:13] [ANOMALY] Memory 경고 (Heap:260MB >= 경고선204MB, 한계:256MB) | Memory Leak 의심 (Heap:260MB >= 256MB) | CPU 경고 (CPU_APP:29% >= 경고선32%, 한계:80%)
```

종료 로그:

```
[MemoryWorker] Current Heap: 260MB | [CpuWorker] Current Load: 29%
[ERROR] Memory limit exceeded: 260MB >= MEMORY_LIMIT(256MB). Initiating shutdown...
[MemoryGuard] Memory Leak 감지 — SIGTERM 전송 (PID:5712)
[INFO] SELF-TERMINATED: agent-app exceeded memory limit. PID:5712
```

| 항목 | CPU 먼저 초과 | 메모리 먼저 초과 |
|------|--------------|----------------|
| 종료 원인 | CPU 과점유 (85% >= 80%) | 메모리 누수 (260MB >= 256MB) |
| 종료 시점 HEAP | 110MB | 260MB |
| 종료 시점 CPU_APP | 85% | 29% |
| SIGTERM 발신 주체 | CpuWorker watchdog | MemoryWorker watchdog |

---

### 프로세스 종료 (Process Not Running)

- 조건: `pgrep`으로 PID 미감지 (앱 크래시 또는 OOM 종료)
- 출력 주기: 5초

```
[2026-06-26 17:27:10] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
[2026-06-26 17:27:15] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
[2026-06-26 17:27:20] [ERROR] PROCESS:agent-leak-app-x86 STATUS:not-running
```

---

## 로그 형식 요약

| 구분 | 형식 |
|------|------|
| 정상 | `[TIMESTAMP] PROCESS:... PID:... CPU_OS:...% CPU_APP:...% HEAP:...MB DISK:...% PORT:... FIREWALL:...` |
| 이상 감지 | `[TIMESTAMP] [ANOMALY] <REASON1> \| <REASON2> \| ...` |
| 프로세스 없음 | `[TIMESTAMP] [ERROR] PROCESS:... STATUS:not-running` |

## 로그 파일 관리

- 위치: `/var/log/agent-app/monitor.log`
- 최대 크기: 10MB
- 최대 보관: 10개 파일 (`monitor.log`, `monitor.log.1` ~ `monitor.log.10`)
- 로테이션: 10MB 초과 시 자동 롤링
