# 퐁듀 모드 — 좀보이드 B41 치지직 후원연동 인게임 모드

**최종 업데이트**: 2026-07-14 (커밋 `f795503` 기준 코드 대조 최신화)
**모드 ID**: `t3chzzkDonation` ·
**표시명**: `[PongDu] - 치지직 도네이션 연동모드` ·
**폴더**: `[Puppet] chzzk API`

Project Zomboid B41 멀티플레이어에서 **치지직(Chzzk) 후원 → 인게임 이벤트**를 실시간으로
발동시키는 모드. 외부 릴레이 앱(**퐁듀 런처**)이 후원 이벤트를 `rewards.txt`로 흘려주면,
이 모드가 읽어서 게임 안에서 인게임 이벤트를 트리거한다.

---

## 📦 퐁듀 시스템 구성

| 구성요소                                       | 저장소                                                                | 역할                                      |
| ---------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------- |
| **퐁듀 런처** (`gui.py`, PyQt5 → `PongDu.exe`) | [Project-PongDu/Launcher](https://github.com/Project-PongDu/Launcher) | 치지직 후원 이벤트 → `rewards.txt` 릴레이 |
| **퐁듀 모드** (이 저장소)                      | [Project-PongDu/Mod](https://github.com/Project-PongDu/Mod)           | `rewards.txt` 읽기 → 게임 이펙트 트리거   |
| **퐁듀 위키** (MkDocs)                         | [Project-PongDu/Wiki](https://github.com/Project-PongDu/Wiki)         | GitHub Pages 문서 사이트                  |

---

## 🔗 통신 규약

- **입력 라인 포맷** (`rewards.txt`): `amount,featureId,sender,message`
  - `featureId`가 실제 디스패치 키. `amount`는 통계/로그용 (금액↔featureId 매핑은 런처가 담당)
  - `sender` / `message`는 URL 인코딩
- **디스패치**: `rewards/rewardManager.lua`가 `featureId → 핸들러` 테이블로 분기
- **커맨드 네임스페이스** (전부 `PongDu*` 접두사로 통일):
  `PongDuDonation` · `PongDuBombard` · `PongDuMutant` · `PongDuRain` · `PongDuRiseUp` ·
  `PongDuVehicleDrop` · `PongDuZombie` · `PongDuStats`

---

## 🗂 디렉토리 구조 (`media/lua/client`)

리팩토링(`[Refactor] 모듈명 리팩토링`)으로 도네이션 로직을 기능별 디렉토리로 재편했다.
히트맨 NPC 기반 인프라(`Hitman*`)는 별개 계층으로 그대로 유지.

```
client/
├── DonationReceiver.lua       # rewards.txt 폴링 + 도네큐박스 UI (핵심)
├── DonationTestMenu.lua       # 어드민 테스트 주입 (실제 파이프라인 관통)
├── rewards/rewardManager.lua  # featureId 디스패치 테이블
├── features/                  # 기능별 구현체
│   ├── hitman / bombard / teleport / randomteleport / backroom
│   ├── zombie / zombierain / mutantspawn / riseup / riseupDiag
│   ├── skillpotion / invsave / exercise / moodle
├── utils/   (zone, Event, handler, updateText)
├── sound/soundManager.lua
├── Hitman*.lua                # 히트맨 NPC 기반 인프라 (Bandits 격리 네임스페이스)
└── ISUI/ · ModPatches/
server/  (server.lua, PongDuRainServer.lua, t3VehicleDrop*, Hitman*)
shared/  (Hitman*, t3RandomWeapon, t3VehicleDrop, ZombieActions/)
```

---

## ✅ 기능 구현 현황

`rewardManager.lua`에 **20개 featureId 등록 / 17개 구현 / 3개 스텁**.

### 구현 완료 (17)

| featureId                           | 효과                                 | 비고                        |
| ----------------------------------- | ------------------------------------ | --------------------------- |
| `debuff_roulette` / `buff_roulette` | 디버프/버프 룰렛                     | 즉발                        |
| `zombie_roulette`                   | 좀비 룰렛 (랜덤 마리수)              | 안전지대 밖 대기            |
| `sprinter5`                         | 스프린터 좀비 5마리                  | 안전지대 밖 대기            |
| `bandit_melee` / `bandit_ranged`    | 히트맨 NPC 소환 (근접/원거리)        |                             |
| `vaccine`                           | 좀보시비르 백신 지급                 |                             |
| `exile`                             | 유배 텔레포트                        |                             |
| `random_teleport`                   | 랜덤 위치 텔레포트 (100~200타일)     | 2단계 좌표검증              |
| `backroom`                          | 백룸                                 |                             |
| `missile`                           | 미사일 폭격 (Bombard)                |                             |
| `random_skill_potion`               | 신체강화 혈청 7종 (확률표 dispatch)  |                             |
| `rise_up_dead_man`                  | 강령술 — 반경 내 시체 전부 부활      | 부활 지속성 아키텍처        |
| `random_weapon`                     | 랜덤 무기상자 (근접/원거리 50:50)    | `t3RandomWeapon` 확률표     |
| `vehicle_drop`                      | 차량소환 키트                        | `VehicleDrop_Pool` 샌드박스 |
| `inv_save_ticket`                   | 인벤세이브권 (사망시 인벤 보존/복원) | `features/invsave.lua`      |
| `mutant_spawn`                      | 특수좀비(뮤턴트) 1마리 소환          | 안전지대 밖 대기            |
| `zombie_rain`                       | 좀비 레인 (30초간 500마리 낙하)      | 낙하데미지 무효화           |

### 미구현 스텁 (3)

| featureId            | 라벨               | 설계 메모                                                     | 난이도 |
| -------------------- | ------------------ | ------------------------------------------------------------- | ------ |
| `revive_ticket`      | 즉시부활 티켓      | 기절 즉시 해제                                                | ⭐     |
| `secret_passage_kit` | 비밀통로 공사 키트 | `bombard`의 `transmitAddObjectToSquare` 패턴 재사용 (벽 제거) | ⭐⭐⭐ |
| `horde_night`        | 호드나이트         | 대량 스폰 + 서버 부하 관리 (스폰 큐 확장)                     | ⭐⭐⭐ |

---

## 🎨 도네큐박스 (후원 큐 UI)

우상단 알림 패널을 **아이콘 기반 쿨다운 슬롯 UI**로 개편 (`DonationReceiver.lua`).

- 정사각형 슬롯 + 둥근 모서리 (Pillow 생성 알파마스크 PNG — 바닐라 `drawRect`는 각진 사각형만 그림)
- **도착순 시리얼 헤드**: 슬롯 배열 순서가 아니라 실제 도착 순서로 처리 (`donationSeq` 전역 카운터 + `arrivalSeq`)
- 색상 틴트 채움 / 스택 병합(같은 featureId 누적) / 호버 툴팁 / 드래그 이동(위치 저장, `DonationUI.ini`)
- **안전지대 락 병렬 레인**: `immediate=false`(zombie_roulette·sprinter5·mutant_spawn) 대기 항목은 별도 레인에 자물쇠 표시
- 준비 카운트다운은 샌드박스 `PongDu.Donation_PrepDelay`(0~10초), 발동확정 표시는 고정 5초

**어드민 테스트 메뉴** (`DonationTestMenu.lua`): 실제 도네 파이프라인을 관통해 주입 →
인게임 검증용. 단 `PongDuStats/Record`는 안 보내 시즌 통계를 오염시키지 않음.

---

## 🧟 특수좀비 시스템

### 뮤턴트 (mutant_spawn)

- **브루트 / 스크리머 / 로치** 3종 랜덤. 외부 모드(CDDA) 의존 제거하고 독립 구현
- 서버가 스폰 후 `sendServerCommand("PongDuMutant", …)`로 타입 브로드캐스트 → 각 클라 `OnZombieUpdate`에서 행동/외형 적용
- 로치: `media/AnimSets`의 `PuppetRoach` 불리언 + `m_SpeedScale`로 이동/공격속도 커스텀
- 네임태그: `TextDrawObject` 머리 위 표기 (후원자 어트리뷰션), `PongDu.Mutant_NameTag` 샌드박스로 토글
- 소환 대사: 욕 + 종류 + 마무리 3파트 랜덤 조합 외침 (번역 키 기반)

### 트레이서 (파쿠르 좀비)

- 담 넘기 / 낮은 담장 뛰어넘기 / 창문 부수기 능력
- `TracerSpeed` 캐릭터 변수로 AnimSet XML 구동 (locomotion)

### 부활 지속성 아키텍처

`rise_up_dead_man`으로 특수좀비 시체를 부활시켜도 능력 유지.

- **영속 레지스트리** (`ModData.getOrCreate`, 서버 세이브 저장 → 서버 재시작 후에도 유효)
- 정규화 ID 키 (`persistentOutfitID`에서 모자 비트 마스킹 — 모자 벗겨져도 불변)
- 부활 좀비는 pid 재발급되므로 좌표+종류를 클라 브로드캐스트 → `OnZombieUpdate`가 능력 재적용
- **재접속 자동부활 버그 픽스** (`3602ed6`): 부활 좀비의 엔진 `ReanimateTimer`가 청크 세이브에
  직렬화돼 서버 재부팅 시 자동부활하던 버그 → `_riseSweeps` 스윕 + `LoadGridsquare` 훅으로 `reanimateTime` 세정

---

## ⚙️ 샌드박스 옵션 (`PongDu` 페이지)

| 옵션                   | 범위/기본          | 설명                                |
| ---------------------- | ------------------ | ----------------------------------- |
| `Donation_ShowPanel`   | on/off             | 도네큐박스 표시 토글                |
| `Donation_PrepDelay`   | 0~10초             | 이펙트 적용 대기시간                |
| `Bombard_Delay`        | 10~300초 (기본 60) | 폭격 발동 대기                      |
| `Bombard_Radius`       | 5~60타일 (기본 55) | 폭격 반경                           |
| `RiseUp_Radius`        | 5~60타일 (기본 55) | 강령술 부활 반경 (폭격과 별개 변수) |
| `Mutant_NameTag`       | on/off             | 뮤턴트 네임태그 표시                |
| `VehicleDrop_Pool`     | 목록               | 차량소환 키트 차종 풀               |
| `Rain_Radius`          | 타일               | 좀비 레인 반경                      |
| `Rain_SprinterPercent` | %                  | 좀비 레인 스프린터 비율             |

전부 사용 시점 읽기 (`SandboxVars and SandboxVars.PongDu` nil 가드).
※ 기반 히트맨 NPC용 `Hitmans.General_*` 옵션은 별도 계층.

---

## 📊 통계 (`profits.txt`)

- 각 클라이언트가 티어 유효성과 **무관하게 모든** 후원을 `sendClientCommand("PongDuStats","Record",{line=raw})`로 전송
- 호스트가 `player:getUsername()`으로 라벨링 → 서버 `Zomboid/Lua/profits.txt`에 기록
- 포맷: 한 줄당 `<스트리머 PZ 사용자명>\t<rewards.txt 원본 라인>`, CRLF
- 시즌 종료 후 외부 Python 스크립트(런처 측, 미착수)로 xlsx 리포트 생성 예정

---

## 🚧 남은 작업

1. **스텁 3개 구현**: `revive_ticket`(가장 간단) → `secret_passage_kit` → `horde_night`
2. 부활 지속성 인게임 최종 검증 (부활 후 능력 유지 + 서버 재부팅 시나리오)
3. dead code 정리: `rewardManager` 큐 함수(`.b`/`.c`), 스탈 메뉴 엔트리 등

---

## 🔧 개발 참조

| 이름           | URL                                                                   | 용도                                                   |
| -------------- | --------------------------------------------------------------------- | ------------------------------------------------------ |
| PZ 바닐라 소스 | [t3qquq/PZ-Library](https://github.com/t3qquq/PZ-Library)             | `PZ 41.78.19 Lua library` / `Java decompiled` 디렉토리 |
| 퐁듀 런처      | [Project-PongDu/Launcher](https://github.com/Project-PongDu/Launcher) | 후원 릴레이 앱                                         |
| 퐁듀 위키      | [Project-PongDu/Wiki](https://github.com/Project-PongDu/Wiki)         | MkDocs 문서                                            |

```bash
# Lua 문법 검증 (모든 Lua 파일 전달 전 필수)
luac5.1 -p "media/lua/client/features/*.lua"
```

---

## 📝 주의사항 (B41 MP)

- **좀비 권한 모델**: `IsoZombie`는 클라이언트 소유 (서버 변경은 소유 클라 동기화에 덮어써짐).
  → 서버 → 브로드캐스트 → **각 클라가 자기 소유 좀비만** 처리. 반대로 `IsoDeadBody`는 서버 권한.
- **스크립트 `.txt` 주석**: `/* */`만 유효. `--`(Lua 스타일)는 파서가 다음 아이템 블록을 통째로 삼킴.
- **번역 파일** (`IG_UI_*.txt`, `Sandbox_*.txt`): UTF-16 BE + BOM + CRLF. 일반 grep/cat 실패 → Python으로 편집.
- **Lua 소스 내 한글 리터럴 금지**: `\ddd` 바이트 이스케이프 또는 `getText()` 키 사용.
- **modData 네임스페이싱**: 키 충돌 시 크로스모드 데이터가 조용히 삭제됨 → 항상 모드 접두사.
- `persistentOutfitID`는 `reanimateNow()` 시 재발급 → 사망/부활 교차 식별자로 사용 불가 (corpse `getModData()` 사용).
- `DebugLog`는 콜러블 함수 아닌 Java 클래스 객체 → `DebugLog(...)` 호출 금지.
- `getGameVersion()`은 Java 객체 반환 → 숫자 비교 금지, B41 상수 하드코딩.
