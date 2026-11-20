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
3. Godot AI 독의 **Tools** 탭에 도구 4개가 보이면 끝입니다. Claude Code나 Claude
   데스크톱에는 `custom_topdown_camera_setup`, `custom_player_controller_scaffold`,
   `custom_weapon_create`, `custom_enemy_ai_scaffold`라는 이름으로 바로
   나타납니다(승격 도구). 도구 목록이
   갱신되지 않는 클라이언트라면 `custom_manage(op="invoke", name=...)`로도 부를
   수 있습니다.

## 도구

| 도구 | 하는 일 |
|---|---|
| `topdown_camera_setup` | 열린 3D 씬에 탑뷰 추적 카메라 리그(Node3D + Camera3D)를 추가. 대상(기본: `player` 그룹의 첫 노드)을 따라가고, 마우스 방향으로 화면을 살짝 당겨 줌(선행 오프셋). 각도·거리·회전·부드러움을 인스펙터에서 바로 조정. 실행 취소 한 번으로 제거 |
| `player_controller_scaffold` | 플레이어 씬 생성: CharacterBody3D, 캡슐 충돌·메시, 조준 피벗(`Aim`), 무기 장착점(`Aim/WeaponMount`). 카메라 기준 WASD 이동, 마우스 조준(바닥 평면 레이캐스트), 무적 구르기, 체력·`take_damage`, 발사·재장전 입력. 없는 입력 액션만 `project.godot`에 추가하고, 기본으로 열린 씬에 배치 |
| `enemy_ai_scaffold` | 적 씬 생성: CharacterBody3D, 캡슐, `NavigationAgent3D`, `WeaponMount`. 상태 머신 AI(순찰 → 추격 → 공격 → 수색 → 순찰, 사망). 시야각 + 시선 레이로 감지하고, 맞으면 쏜 쪽을 쫓고, 주변 적에게 알림. 근접 공격 또는 원거리(자체 레이, 또는 `weapon_create` 무기 장착). 체력·`take_damage`. 열린 씬에 여러 마리 배치하고, 씬에 `NavigationRegion3D`가 없으면 정적 충돌체로 내비 메시를 구워 추가. 실행 취소 한 번으로 제거 |
| `weapon_create` | 무기 스탯 `.tres`(데미지, 연사, 자동, 탄창, 재장전, 탄퍼짐, 산탄 수, 사거리)와 무기 씬 생성. 히트스캔 또는 투사체로 발사하고, 맞은 대상의 `take_damage(amount, info)`를 호출. `attach_to`로 플레이어에 바로 장착 |

Claude에게는 이렇게 말하면 됩니다.

> 빈 3D 씬에 바닥 깔고, 플레이어 만들고, 탑뷰 카메라 붙이고, 연사 12발 SMG랑
> 산탄 8발 샷건 만들어서 플레이어한테 SMG 장착해 줘.

> 근접 적 grunt 3마리를 (-6,0,-10), (0,0,-12), (6,0,-10)에 두고, 권총 든 원거리 적
> gunner 하나를 (0,0,-20)에 둬. grunt는 (-8,0,-10)과 (8,0,-10) 사이를 순찰하게.

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
                         weapon.gd, weapon_data.gd, projectile.gd, enemy_ai.gd
res://scenes/player/     player.tscn
res://scenes/weapons/    <weapon_id>.tscn, projectile.tscn
res://scenes/enemies/    <enemy_id>.tscn  (스크립트는 scripts/topdown/enemy_ai.gd)
res://data/weapons/      <weapon_id>.tres
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
