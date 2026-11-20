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
3. Godot AI 독의 **Tools** 탭에 도구 6개가 보이면 끝입니다. Claude Code나 Claude
   데스크톱에는 `custom_topdown_camera_setup`, `custom_player_controller_scaffold`,
   `custom_weapon_create`, `custom_enemy_ai_scaffold`, `custom_item_db_import`,
   `custom_loot_table_edit`라는
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
| `weapon_create` | 무기 스탯 `.tres`(데미지, 연사, 자동, 탄창, 재장전, 탄퍼짐, 산탄 수, 사거리)와 무기 씬 생성. 히트스캔 또는 투사체로 발사하고, 맞은 대상의 `take_damage(amount, info)`를 호출. `attach_to`로 플레이어에 바로 장착 |

Claude에게는 이렇게 말하면 됩니다.

> 빈 3D 씬에 바닥 깔고, 플레이어 만들고, 탑뷰 카메라 붙이고, 연사 12발 SMG랑
> 산탄 8발 샷건 만들어서 플레이어한테 SMG 장착해 줘.

> 근접 적 grunt 3마리를 (-6,0,-10), (0,0,-12), (6,0,-10)에 두고, 권총 든 원거리 적
> gunner 하나를 (0,0,-20)에 둬. grunt는 (-8,0,-10)과 (8,0,-10) 사이를 순찰하게.

> 이 아이템 시트(CSV 붙여 넣기)를 아이템 DB로 가져와 줘. 먼저 dry_run으로 확인해 줘.

> grunt 드롭표 만들어 줘. 붕대 가중치 3에 1~2개, 9mm 탄 가중치 1에 10~30개, 꽝 4. 1000번 돌려서
> 확률 보여 주고, 씬의 적 전부(enemy 그룹)에 붙여 줘.

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
  그대로 남습니다. 없으면 그냥 사라지고 `picked_up` 신호만 냅니다.
- 코드에서 바로 굴리려면 `table.roll()` → `[{item_id, count, item}]`, 확률은 `table.get_roll_chances()`.

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
                         loot_table.gd, loot_dropper.gd, loot_pickup.gd
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
  `game_manage(op="input_mouse")`로도 조준과 카메라 선행을 움직일 수 있습니다.
  자동 플레이테스트에 그대로 쓸 수 있습니다.

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
