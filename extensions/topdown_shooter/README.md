# Top-down Shooter Tools

3D 탑뷰 익스트랙션 슈터용 Godot AI 커스텀 MCP 도구 애드온입니다. Godot AI 원본
코드는 건드리지 않고, 원본이 공식 지원하는 `custom_tools` 확장 지점
(`McpToolRegistry`)에 도구를 등록합니다. 그래서 원본 동기화와 충돌하지 않습니다.

요구 사항: Godot 4.7 이상, 같은 프로젝트에 Godot AI 플러그인(`addons/godot_ai`).

## 설치 (macOS, Windows 공통)

1. 이 폴더의 `addons/topdown_shooter_tools/`를 게임 프로젝트의 `addons/` 아래로
   복사합니다. 결과: `<게임 프로젝트>/addons/topdown_shooter_tools/plugin.cfg`
2. Godot에서 **프로젝트 > 프로젝트 설정 > 플러그인**을 열고 `Godot AI`와
   `Top-down Shooter Tools`를 둘 다 켭니다.
3. Godot AI 독의 **Tools** 탭에 도구 10개가 보이면 끝입니다. Claude Code나 Claude
   데스크톱에는 `custom_topdown_camera_setup`, `custom_player_controller_scaffold`,
   `custom_weapon_create`, `custom_enemy_ai_scaffold`, `custom_item_db_import`,
   `custom_loot_table_edit`, `custom_inventory_ui_scaffold`, `custom_raid_map_blockout`,
   `custom_raid_playtest`, `custom_playtest_notes`라는
   이름으로 바로 나타납니다(승격 도구). 도구 목록이
   갱신되지 않는 클라이언트라면 `custom_manage(op="invoke", name=...)`로도 부를
   수 있습니다.

## 도구

| 도구 | 하는 일 |
|---|---|
| `topdown_camera_setup` | 열린 3D 씬에 탑뷰 추적 카메라 리그(Node3D + Camera3D)를 추가. 대상(기본: `player` 그룹의 첫 노드)을 따라가고, 마우스 방향으로 화면을 살짝 당겨 줌(선행 오프셋). 각도·거리·회전·부드러움을 인스펙터에서 바로 조정. 실행 취소 한 번으로 제거 |
| `player_controller_scaffold` | 플레이어 씬 생성: CharacterBody3D, 캡슐 충돌·메시, 조준 피벗(`Aim`), 무기 장착점(`Aim/WeaponMount`). 카메라 기준 WASD 이동, 마우스 조준(바닥 평면 레이캐스트), 무적 구르기, 체력·`take_damage`, 발사·재장전 입력. 없는 입력 액션만 `project.godot`에 추가하고, 기본으로 열린 씬에 배치 |
| `enemy_ai_scaffold` | 적 씬 생성: CharacterBody3D, 캡슐, `NavigationAgent3D`, `WeaponMount`. 상태 머신 AI(순찰 → 추격 → 공격 → 수색 → 순찰, 사망). 시야각 + 시선 레이로 감지하고, 맞으면 쏜 쪽을 쫓고, 주변 적에게 알림. 근접 공격 또는 원거리(자체 레이, 또는 `weapon_create` 무기 장착). 체력·`take_damage`. 열린 씬에 여러 마리 배치하고, 씬에 `NavigationRegion3D`가 없으면 정적 충돌체로 내비 메시를 구워 추가. 실행 취소 한 번으로 제거 |
| `item_db_import` | 아이템 스프레드시트(CSV/TSV)를 행마다 아이템 `.tres` 하나로 바꾸고, 전체를 묶은 `item_database.tres`(`get_item(id)`, `find_by`, `find_by_tag`)를 만들거나 갱신. 모든 행을 먼저 검사해서 한 칸이라도 틀리면 아무것도 쓰지 않음. 다시 가져오면 기존 아이템을 제자리에서 갱신. 실행 취소 한 번으로 이전 파일로 복원 |
| `loot_table_edit` | 적·상자용 드롭 확률표 `.tres` 생성·수정. 아이템별 가중치, 개수 범위, 확정 드롭, 드롭당 굴림 횟수, "없음" 가중치. 아이템 id는 `item_database.tres`로 검사하고 `category`/`tag`로 해당 아이템을 한 번에 추가. 아이템마다 정확한 드롭 확률·기대 개수와 시드 고정 시뮬레이션 결과·샘플 드롭을 보고(`table_id`만 주면 시뮬레이션만). `attach_to`/`attach_to_group`으로 적에게 `LootDropper`를 붙이면 `died` 때 바닥에 아이템이 떨어짐. 표 파일과 드롭 노드 각각 실행 취소 한 번 |
| `inventory_ui_scaffold` | 플레이어에 격자·무게 인벤토리(`Inventory` 자식)와 인벤토리 화면(`InventoryUI` CanvasLayer)을 붙임. Tab/I로 열고 닫기, 드래그로 이동, R로 회전, 우클릭으로 바닥에 버리기, Shift+클릭으로 나누기, 정렬 버튼, 무게·가치 표시, 툴팁, 획득 알림, 무게 HUD. 무거우면 이동 속도가 줄고, 가방이 가득 차거나 너무 무거우면 바닥 아이템이 그대로 남음. 플레이어 스크립트에 `add_item`이 없으면 짧게 추가해서 `loot_table_edit`의 바닥 아이템이 가방으로 들어감. 노드는 실행 취소 한 번, 스크립트 수정은 따로 한 번 |
| `raid_map_blockout` | 열린 3D 씬에 레이드 맵 뼈대를 만듦. 방과 복도를 1m 격자에 배치(방 개수 + 시드로 자동 생성, 또는 방 좌표·크기와 연결을 직접 지정)하고 바닥·벽·엄폐물(낮은 벽, 상자, 기둥)을 StaticBody3D 상자로 생성. 플레이어 스폰(플레이어를 옮김), 방마다 적 스폰 지점(적 씬을 주면 방을 도는 순찰 경로와 함께 배치), 루팅 상자(E로 수색, 드롭표를 주면 바닥에 아이템), 탈출 지점(안에 몇 초 서 있으면 탈출)을 배치. 내비 메시를 다시 굽고 ASCII 미리보기를 돌려줌. 맵 전체가 실행 취소 한 번 |
| `weapon_create` | 무기 스탯 `.tres`(데미지, 연사, 자동, 탄창, 재장전, 탄퍼짐, 산탄 수, 사거리)와 무기 씬 생성. 히트스캔 또는 투사체로 발사하고, 맞은 대상의 `take_damage(amount, info)`를 호출. `attach_to`로 플레이어에 바로 장착 |
| `raid_playtest` | 게임을 실행해 봇이 레이드를 직접 플레이하고 보고. 실제 입력 액션으로 내비 메시를 따라 걷고, 마우스 이동으로 조준하고, 쏘고 재장전하고, 상자에서 interact를 눌러 열고, 떨어진 아이템을 줍고, 보이는 적과 싸우고, 시간 안에 탈출 지점으로 감. 결과(탈출/사망/시간 초과), 게임 중 오류, FPS, 전투·루팅 수치, 막힌 위치, 스크린샷과 문제 목록(`issues`), 판정(`verdict`)을 돌려줌. 처음 한 번 `RaidPlaytest` 자동 로드를 등록(평소 플레이에서는 아무것도 안 함, 실행 취소 한 번) |
| `playtest_notes` | 플레이 중 메모. 게임에서 F8(또는 Ctrl/Cmd+N)을 누르면 일시정지하고 화면을 찍은 뒤, 마우스가 가리키는 바닥(Tab으로 플레이어 위치)에 핀을 꽂고 메모 창을 띄움. 메모·종류·씬·좌표·카메라·커서 아래 노드·최근 엔진 오류·시각과 스크린샷(표시한 곳에 빨간 원)을 `res://playtest_notes/`에 저장. Claude가 목록·내용·사진을 읽고 고친 뒤 `resolve`로 닫음. 열린 씬에 메모 핀 표시(보기 전용, 저장 안 됨). 닫기·다시 열기·삭제는 실행 취소 한 번. 처음 한 번 `PlaytestNotes` 자동 로드를 등록(디버그 빌드에서만 동작) |

Claude에게는 이렇게 말하면 됩니다.

> 빈 3D 씬에 바닥 깔고, 플레이어 만들고, 탑뷰 카메라 붙이고, 연사 12발 SMG랑
> 산탄 8발 샷건 만들어서 플레이어한테 SMG 장착해 줘.

> 근접 적 grunt 3마리를 (-6,0,-10), (0,0,-12), (6,0,-10)에 두고, 권총 든 원거리 적
> gunner 하나를 (0,0,-20)에 둬. grunt는 (-8,0,-10)과 (8,0,-10) 사이를 순찰하게.

> 이 아이템 시트(CSV 붙여 넣기)를 아이템 DB로 가져와 줘. 먼저 dry_run으로 확인해 줘.

> grunt 드롭표 만들어 줘. 붕대 가중치 3에 1~2개, 9mm 탄 가중치 1에 10~30개, 꽝 4. 1000번 돌려서
> 확률 보여 주고, 씬의 적 전부(enemy 그룹)에 붙여 줘.

> 플레이어한테 8x6 인벤토리 달아 줘. 최대 무게 35kg, 20kg부터 느려지게. 붕대 2개 들고 시작.

> 레이드 한 판 자동으로 돌려 보고 문제 있으면 알려 줘. 2배속으로.

> 플레이 메모 기능 켜 줘. (플레이하며 F8로 메모를 남긴 뒤) 내가 남긴 메모 보고 고쳐 줘.

> 방 7개짜리 레이드 맵 만들어 줘. 먼저 dry_run으로 미리보기 보여 주고, 괜찮으면 grunt랑 gunner를
> 방마다 하나씩 두고 상자는 crate 드롭표로, 탈출구는 2개.

## 아이템 DB 가져오기

시트 예시(첫 줄은 열 이름). Google 시트는 **파일 > 다운로드 > CSV**, Excel은
**CSV UTF-8**로 저장합니다. 파일은 `res://`나 `user://` 아래에 두고 `csv_path`로
주거나, 내용을 그대로 `csv_text`로 줍니다.

```csv
id,이름,category,rarity,무게,price,stack,tags,weapon,durability
bandage,붕대,medical,common,0.1,50,5,heal;cheap,,
ak_rifle,AK 소총,weapon,rare,3.5,12000,1,,ak47,
gold_watch,금시계,valuable,epic,0.2,1500,1,sell,,80
```

| 규칙 | 내용 |
|---|---|
| 열 → 속성 | 열 이름이 `item_data.gd`의 `@export` 속성 이름과 같으면 그대로 연결. 별칭: `id`, `name`/`이름`, `price`/`가격`, `stack`/`중첩`, `무게`, `분류`, `희귀도`, `설명`, `태그`, `무기` 등. 다른 이름은 `column_map`(`{"시트 열": "속성"}`, `"-"`면 무시)으로 연결 |
| 값 변환 | 속성 타입에 맞춰 변환: 숫자, 정수, true/false, 열거형(`category`, `rarity`, 대소문자 무시), `;`로 나눈 목록(`tags`), `res://` 경로(아이콘 등), `weapon`은 무기 id만 써도 `res://data/weapons/<id>.tres`를 찾음 |
| 모르는 열 | 아이템의 `extra` 사전에 저장(숫자는 숫자로). `#`나 `_`로 시작하는 열과 `#`로 시작하는 행은 무시 |
| 빈 칸 | 새 아이템은 기본값, 기존 아이템은 원래 값 유지 |
| 이미 있는 아이템 | `existing`: `update`(기본, 시트에 있는 값만 바꿈) / `replace`(새로 만듦) / `skip` / `error` |
| 검사 | id 중복, 형식 오류, 없는 열거값, 없는 리소스를 줄 번호와 함께 모두 보고하고 아무것도 쓰지 않음. `dry_run=true`는 결과만 미리 봄 |

`item_data.gd`에 `@export var armor_class := 0`처럼 속성을 추가하고 같은 이름의 열을
시트에 넣으면 다음 가져오기부터 자동으로 채워집니다. `item_database.tres`는 같은
폴더의 이전 항목을 유지하고 이번 시트의 아이템을 추가하거나 교체합니다.

## 드롭 확률표

표는 `res://data/loot/<table_id>.tres`(`loot_table.gd`)에 저장됩니다. 한 번 드롭할 때
`rolls_min`~`rolls_max`번 굴리고, 굴릴 때마다 가중치에 비례해 항목 하나(또는
`empty_weight` 비율로 "없음")를 고릅니다. `guaranteed` 항목은 굴림과 별개로 항상
떨어집니다. 같은 아이템이 여러 번 뽑히면 개수가 합쳐집니다.

| 매개변수 | 내용 |
|---|---|
| `entries` | `[{item_id, weight, min_count, max_count, guaranteed}]`. `item_id` 대신 `category`나 `tag`를 주면 DB에서 맞는 아이템을 모두 같은 가중치로 추가. 이미 표에 있는 아이템은 값만 바꿈. 같은 아이템을 여러 항목이 가리키면 뒤의 것이 이김 |
| `remove_items`, `replace_entries` | 아이템 빼기, 기존 항목을 비우고 새로 쓰기 |
| `rolls_min`, `rolls_max`, `empty_weight` | 드롭당 굴림 횟수, "없음" 가중치. 새 표 기본값은 1, 1, 0 |
| `simulate`, `seed`, `samples` | 시뮬레이션 횟수(기본 1000), 시드(같은 시드면 같은 결과), 보여 줄 샘플 드롭 수 |
| `attach_to`, `attach_to_group`, `trigger_signal` | 열린 씬의 노드나 그룹(예: `enemy`)에 `LootDropper` 자식을 붙임. 이미 있으면 표만 바꿈. 기본으로 부모의 `died` 신호에 드롭 |

보고서의 `drop_percent`는 한 번 드롭할 때 그 아이템이 하나 이상 나올 정확한 확률,
`expected_count`는 평균 개수, `simulated_*`는 시뮬레이션 결과, `nothing_chance_percent`는
아무것도 안 나올 확률입니다. DB에 없는 id는 오류입니다(`allow_unknown_items=true`로 허용).

게임에서는:

- `LootDropper`는 부모가 `died`를 내면 표를 굴려, 부모 옆(부모의 부모 아래)에 아이템마다
  `loot_pickup.gd` 노드 하나를 흩뿌립니다. 상자처럼 신호가 없으면 `trigger_signal`을 비우고
  `$LootDropper.drop()`을 직접 부르세요. `dropped(drops)` 신호도 냅니다.
- 바닥 아이템은 희귀도 색 상자와 이름표를 띄우고, `player` 그룹 몸체가 닿으면 주워집니다.
  그 몸체에 `add_item(item, count)`가 있으면 호출하고, `false`를 돌려주면(가방이 가득 참)
  그대로 남습니다. 없으면 그냥 사라지고 `picked_up` 신호만 냅니다. `inventory_ui_scaffold`가
  이 `add_item`을 플레이어에 연결합니다.
- 코드에서 바로 굴리려면 `table.roll()` → `[{item_id, count, item}]`, 확률은 `table.get_roll_chances()`.

## 인벤토리

`Inventory` 노드(`inventory.gd`)는 플레이어 아래에 들어가고, 아이템마다 `item_data.gd`의
`grid_width` x `grid_height` 칸을 차지합니다(회전하면 가로세로가 바뀜). 같은 아이템은
`max_stack`까지 한 칸에 쌓입니다.

| 매개변수 | 내용 |
|---|---|
| `grid_width`, `grid_height` | 가방 칸 수. 기본 6 x 8 |
| `max_weight` | 들 수 있는 최대 무게(kg). 넘으면 줍지 못함. 0이면 제한 없음. 기본 40 |
| `encumbered_weight`, `min_speed_factor` | 이 무게부터 플레이어 `move_speed`가 줄어 `max_weight`에서 `min_speed_factor`배가 됨. 기본 25, 0.5 |
| `starting_items` | 시작할 때 가방에 넣을 아이템 `[{item_id, count}]`. id는 `item_database.tres`로 검사 |
| `toggle_action` | 화면을 여는 입력 액션. 없으면 Tab과 I로 만듦. 기본 `inventory` |
| `block_player_while_open` | 화면이 열려 있으면 플레이어가 멈추고 쏘지 않음. 기본 true |
| `patch_player_script` | 플레이어 스크립트에 `add_item`이 없으면 끝에 추가. 기본 true |

다시 실행하면 노드를 새로 만들지 않고 설정만 바꿉니다. 게임 코드에서는:

- `add_item(item_or_id, count)`는 전부 들어가거나 아무것도 안 들어갑니다(가득 차거나 너무
  무거우면 `false`, `add_failed(item, count, reason)` 신호). 바닥 아이템이 이걸 부릅니다.
- `remove_item(id, count)`, `count_of(id)`, `has_item(id, count)`, `get_total_weight()`,
  `get_total_value()`, `drop_entry(index)`, `sort_items()`
- 저장/불러오기: `to_data()` → `[{item_id, count, x, y, rotated}]`, `from_data(data)`
- 신호: `changed`, `item_added`, `item_removed`, `item_dropped`

## 레이드 맵

맵은 `RaidMap` 노드 하나(이름은 `name`)이고, 그 아래에 `Floors`, `Walls`, `Cover`, `Rooms`(방마다
`raid_room` 그룹 Marker3D), `PlayerSpawn`(`player_spawn` 그룹), `EnemySpawns`(`enemy_spawn` 그룹),
`Enemies`, `Crates`(`loot_crate` 그룹), `Extractions`(`extraction` 그룹)가 들어갑니다. 벽·엄폐물·상자는
평범한 노드라 지우거나 옮겨서 다듬으면 되고, 그 뒤에 `Navigation`에서 **Bake NavigationMesh**를 누르세요.

| 매개변수 | 내용 |
|---|---|
| `room_count`, `seed`, `room_size_min`, `room_size_max`, `room_gap` | 자동 생성. 방을 격자로 놓고 이웃끼리 무작위 신장 트리로 잇고 `extra_connections`개를 더 이어 순환로를 만듦. 같은 시드면 같은 맵. 첫 방은 화면 아래(+z), 나머지는 위로 |
| `rooms`, `connections` | 직접 지정. `rooms`: `[{name, position: [x, z], size: [가로, 세로], cover, crates, enemies}]`(위치는 방 중심), `connections`: `[["Gate", "Yard"], [1, 2]]`. 연결을 빼면 가까운 방끼리 이음 |
| `corridor_width`, `wall_height`, `wall_thickness`, `build_floor` | 복도 폭(기본 3m), 벽 높이(3m)·두께(0.4m), 바닥(윗면 y=0) |
| `cover_per_room`, `crates_per_room`, `enemies_per_room` | 방마다 개수(기본 3, 1, 1). 스폰 방에는 상자와 적을 두지 않음. 모두 벽에서 1.5m 안쪽에 두어 문과 벽을 따라 도는 길이 항상 열려 있음. 자리가 모자라면 건너뛰고 `warnings`에 알림 |
| `player_spawn_room`, `move_player` | 스폰 방(이름이나 번호, 기본 첫 방)과 플레이어 이동 여부 |
| `extraction_count`, `extraction_rooms`, `extract_time`, `restart_delay` | 탈출 지점 수(기본 1, 스폰에서 복도로 가장 먼 방), 직접 고를 방, 안에 있어야 하는 시간(5초), 탈출 뒤 씬을 다시 시작하기까지(4초, 0이면 안 함) |
| `enemy_scenes` | `enemy_ai_scaffold`로 만든 적 `.tscn` 목록. 스폰 지점마다 번갈아 배치하고, `enemy_patrol`이면 방 네 모서리를 도는 `patrol_points`를 줌. 없으면 스폰 지점만 두고 좌표를 `enemy_spawn_positions`로 보고 |
| `crate_loot_table` | `loot_table_edit`의 표 id(예: `crate`)나 경로. 상자마다 `LootDropper`(신호 `opened`)를 붙임 |
| `setup_navigation` | 씬의 `NavigationRegion3D`를 다시 구움(실행 취소 따로 한 번). 없으면 새로 만들어 구움 |
| `replace`, `dry_run` | 같은 이름의 맵을 지우고 다시 만들기(같은 실행 취소 단계), 쓰지 않고 미리보기만 |

보고서의 `preview`는 1m당 한 글자인 지도입니다(위쪽이 -z): `.` 방, `,` 복도, `#` 벽, `o` 엄폐물,
`C` 상자, `e` 적 스폰, `P` 플레이어 스폰, `X` 탈출 지점.

게임에서는:

- 상자(`loot_crate.gd`): 플레이어가 1.8m 안에서 `interact`(E)를 누르면 `search_time`초 동안 수색하고(멀어지면
  취소), 열리면 `opened` 신호로 드롭합니다. 코드에서는 `open()`, `start_search(player)`.
- 탈출 지점(`raid_extraction.gd`): 플레이어가 안에 `extract_time`초 머물면 `extracted(player)` 신호를 내고,
  플레이어에 `on_extracted(zone)`가 있으면 부르고, 플레이어를 멈추고 "탈출 성공!"과 가방 가치를 띄운 뒤
  `restart_delay`초 뒤 씬을 다시 시작합니다. 나가면 취소됩니다.

## 자동 플레이테스트

`raid_playtest`는 열린 씬(없으면 메인 씬)을 실행하고, 게임 안의 `RaidPlaytest` 자동 로드가
플레이어를 조종합니다. 에디터가 실행 직전에 `user://raid_playtest/request.json`을 남길 때만
움직이고(3분 넘은 요청은 무시), 그 밖의 플레이에서는 아무것도 하지 않습니다. 봇은 사람과
같은 입력 경로를 씁니다: 이동은 `move_*` 액션(카메라 기준을 거꾸로 계산), 조준은 마우스
이동 이벤트, 발사·재장전·구르기·상자 열기는 각 입력 액션입니다.

봇이 고르는 순서: 남은 시간이 탈출 경로 + 탈출 대기 시간에 가까우면 탈출 → 가까운 바닥
아이템 → 가장 가까운(경로 기준) 닫힌 상자 → (`hunt`) 적 → (`explore`) 안 가 본 방 → 탈출.
보이는 적은 사거리 안에서 쏘고, 너무 가까우면 물러나며, 맞으면 더 멀리까지 공격자를 찾습니다.
같은 목표에서 세 번 막히면 그 목표를 건너뛰고 `navigation.unreachable`에 남깁니다.

| 매개변수 | 내용 |
|---|---|
| `op` | `run`(기본), `report`(마지막 보고서), `stop`(게임 종료), `install`/`uninstall`(자동 로드) |
| `scene`, `duration`, `time_scale` | 실행할 씬, 게임 시간 제한(기본 60초), 배속(0.25~4). 기다리는 실행은 `duration / time_scale`이 105초 이하 |
| `wait` | 기본 true: 끝날 때까지 기다려 보고서를 돌려줌. false면 게임이 뜨자마자 돌려주고 나중에 `op="report"` |
| `crates`, `max_crates`, `loot`, `loot_radius` | 상자 열기, 최대 개수, 아이템 줍기, 주울 거리 |
| `fight`, `hunt`, `engage_range` | 보이는 적 쏘기, 적을 찾아다니기, 교전 거리(무기 사거리로 제한) |
| `extract`, `explore`, `invulnerable` | 탈출로 끝내기, 모든 방 들르기, 죽지 않게(경로 점검용) |
| `min_fps`, `screenshots`, `screenshot_interval`, `max_screenshots`, `show_hud` | FPS 기준, 스크린샷(시작·첫 교전·첫 상자·첫 막힘·끝 + N초마다), 게임 화면의 봇 상태 표시 |

보고서는 `user://raid_playtest/report.json`(맥: `~/Library/Application Support/Godot/app_userdata/<프로젝트>/raid_playtest/`),
스크린샷은 같은 폴더의 `shots/`에 저장됩니다. `issues`가 비어 있으면 `verdict`가 `pass`입니다. 문제로
잡는 것: 게임 중 오류, 사망, 시간 안에 탈출 못 함, 무기 없음, 내비 메시 없음, 막힘, 못 간 목표, 못 주운
아이템, `min_fps` 아래로 떨어진 FPS.

## 플레이 중 메모

`playtest_notes op="install"`을 한 번 부르면 `PlaytestNotes` 자동 로드가 등록됩니다. 그다음 평소처럼
플레이하다가 이상한 곳에서 키를 누르면 됩니다.

| 키 | 하는 일 |
|---|---|
| F8, Ctrl+N, Cmd+N | 메모 시작: 지금 화면을 찍고 일시정지, 마우스가 가리키는 곳에 노란 핀. 이 씬의 열린 메모 핀도 함께 보임 |
| Tab | 핀 위치를 마우스 지점 ↔ 플레이어 위치로 전환 |
| Enter / Shift+Enter / Esc | 저장 / 줄바꿈 / 취소 (한글 조합 중 Enter는 조합만 끝냄) |

맥에서 F8은 기본이 미디어 키라 fn+F8이어야 하므로 Cmd+N이 편합니다. 다른 키를 쓰려면 입력 맵에
`playtest_note` 액션을 만들면 그 키만 씁니다. 종류(버그·밸런스·레벨/맵·아이디어·기타)는 창에서 고릅니다.

메모 하나는 `res://playtest_notes/<id>.json`과 `<id>.png`입니다(내보낸 게임에서는 `user://playtest_notes/`).
폴더에 `.gdignore`가 생겨 에디터가 스크린샷을 가져오지 않습니다. JSON에는 `text`, `category`, `status`,
`scene`, `position`(핀 좌표)과 `position_source`, `cursor_position`, `cursor_node`(커서 아래 충돌체의
씬 경로), `player_position`, `player_state`(체력 등), `camera`, `mouse_screen`, `recent_errors`(최근
오류 10개와 몇 초 전인지), `fps`, `game_time_sec`, `created`가 들어갑니다.

| op | 하는 일 |
|---|---|
| `list` (기본) | 메모 목록. `status`(open 기본/resolved/all), `scene`(res:// 경로, `current`, `all`), `category`, `limit` |
| `get` | 메모 전체와 `screenshot_path`(절대 경로, 빨간 원이 표시한 곳) |
| `resolve`, `reopen` | `id`나 `ids`. `resolve`는 `resolution`(무엇을 고쳤는지)을 메모에 남김. 실행 취소 한 번 |
| `delete` | 메모와 스크린샷 삭제. 실행 취소 한 번으로 되살림 |
| `markers`, `clear_markers` | 열린 3D 씬에 메모 핀(종류별 색, 해결한 메모는 흐리게) 표시·제거. 소유자 없는 노드라 씬 파일에 저장되지 않음. 기본은 이 씬의 열린 메모, `status="all"`이면 해결한 것도 |
| `install`, `uninstall` | 자동 로드 등록·해제(각각 실행 취소 한 번). 스크립트와 메모는 남김 |

## 적 AI

| 상태 | 하는 일 | 다음 상태 |
|---|---|---|
| PATROL | `patrol_points`를 순서대로 돌거나(없으면 스폰 지점 주변 `wander_radius` 안을 배회), 지점마다 `patrol_wait_time`만큼 멈춤 | 대상을 보거나, 맞거나, 아군 알림 → CHASE |
| CHASE | 마지막으로 본 위치로 `chase_speed`로 이동 | `attack_range` 안 → ATTACK, `lose_sight_time` 동안 못 봄 → SEARCH |
| ATTACK | 대상을 바라보고 `attack_windup`(예고) 뒤 공격, `attack_cooldown`마다 반복. 원거리 적은 시선이 끊기면 다시 추격 | 범위 밖 → CHASE |
| SEARCH | 마지막 위치까지 간 뒤 `search_time` 동안 주위를 둘러봄 | 다시 보면 CHASE, 못 찾으면 PATROL |
| DEAD | 충돌 레이어를 0으로 꺼서 총알이 통과, `died` 신호, `death_free_delay` 뒤 제거 | |

- 감지: `target_group`(기본 `player`)의 노드가 `sight_range` 안, 앞쪽
  `sight_angle_degrees` 부채꼴 안(또는 `proximity_radius` 안이면 방향 무관)에
  있고, 눈 높이에서 대상까지 `sight_mask` 레이에 막힘이 없을 때 봅니다. 벽 뒤는
  못 봅니다.
- 피격: 플레이어 무기가 `take_damage(amount, info)`를 부르면 `info.source`(쏜
  플레이어)를 쫓습니다. 안 보이는 데서 맞아도 그 위치로 갑니다.
- 원거리 적에 `weapon_scene`을 주면 그 무기의 연사·탄창·재장전·탄퍼짐을 그대로
  씁니다. 무기가 쏘는 레이는 적 자신만 제외하므로 다른 적이 맞을 수 있습니다.
- 내비게이션: 씬 루트를 `navigation_source` 그룹에 넣고, 그 아래의
  StaticBody3D로 내비 메시를 굽습니다. 레벨을 바꾸면 `Navigation` 노드를 선택해
  **Bake NavigationMesh**를 다시 누르세요. 내비 메시가 비었거나 목표가 메시 밖이면
  목표를 향해 직선으로 이동합니다.
- 인스턴스마다 다른 순찰 경로를 주려면 인스펙터에서 `patrol_points`를 고칩니다.

## 만들어지는 파일

기본 위치이며 모두 매개변수로 바꿀 수 있습니다.

```
res://scripts/topdown/   topdown_camera_rig.gd, player_controller.gd,
                         weapon.gd, weapon_data.gd, projectile.gd, enemy_ai.gd,
                         item_data.gd, item_database.gd,
                         loot_table.gd, loot_dropper.gd, loot_pickup.gd,
                         inventory.gd, inventory_ui.gd,
                         loot_crate.gd, raid_extraction.gd,
                         raid_playtest_agent.gd (자동 로드 RaidPlaytest),
                         playtest_notes_overlay.gd (자동 로드 PlaytestNotes)
res://playtest_notes/    <id>.json, <id>.png  (플레이 중 메모)
res://scenes/player/     player.tscn
res://scenes/weapons/    <weapon_id>.tscn, projectile.tscn
res://scenes/enemies/    <enemy_id>.tscn  (스크립트는 scripts/topdown/enemy_ai.gd)
res://data/weapons/      <weapon_id>.tres
res://data/items/        <item_id>.tres, item_database.tres
res://data/loot/         <table_id>.tres
```

스크립트는 템플릿에서 프로젝트로 **복사**되므로 마음대로 고쳐도 됩니다. 이미
있는 스크립트는 덮어쓰지 않고 그대로 씁니다(`overwrite_scripts=true`일 때만
템플릿으로 되돌림). 씬과 `.tres`는 같은 경로가 있으면 오류를 내고,
`overwrite=true`일 때만 교체합니다.

도구는 파일을 쓴 뒤 에디터 파일 시스템에 파일 단위로만 알리고 전체 재스캔은
하지 않습니다(Godot AI가 문서화한 에디터 크래시를 피하기 위해서). 그래서 새로
만든 폴더는 FileSystem 독에 바로 안 보일 수 있지만, 에디터 창을 다시 클릭하면
나타납니다. 씬과 스크립트는 그 전에도 정상적으로 동작합니다.

## 게임 코드 규약

- 적은 `enemy` 그룹, 플레이어는 `player` 그룹에 들어갑니다.
- 데미지를 받는 모든 것(적, 상자, 플레이어)은 `take_damage(amount: float, info: Dictionary)`를
  구현합니다. 무기는 맞은 충돌체에서 부모 쪽으로 올라가며 이 함수를 가진 첫
  노드를 찾습니다. `info`에는 `source`, `weapon`, `position`, `direction`이 들어
  있습니다.
- 플레이어는 `Aim/WeaponMount` 아래에서 `try_fire()`가 있는 첫 노드를 무기로
  씁니다.
- 마우스 위치는 입력 이벤트에서 읽으므로, MCP의
  `game_manage(op="input_mouse")`나 `raid_playtest`의 봇으로도 조준과 카메라 선행을
  움직일 수 있습니다.

## 개발과 테스트

이 저장소에서 GDScript 테스트를 돌리려면 애드온과 테스트를 `test_project/`에
링크한 뒤 에디터를 시작합니다(링크는 git에서 제외되므로 `test_project/`는
원본과 같은 상태로 남습니다).

```bash
extensions/topdown_shooter/script/link-test-project
# 에디터 실행 후
script/ci-godot-tests          # 또는 MCP test_run(suite="topdown_shooter")
extensions/topdown_shooter/script/link-test-project --remove
```

테스트는 `res://zz_mcp_test_topdown/`에 파일을 쓰고 끝나면 지웁니다. 입력 액션은
`mcp_test_td_` 접두사로 만들고 끝나면 `project.godot`에서 지웁니다.
