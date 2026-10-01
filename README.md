# Desktop Automata

macOS 바탕화면(아이콘 아래)에 RGB 셀룰러 오토마타를 Metal로 그리는 메뉴바 앱입니다. 마우스를 움직이거나 클릭하면 그 자리에서 셀이 생겨납니다. 세대가 바뀌는 과정은 나이에 따른 색, 탄생 플래시, 잔상으로 표현됩니다.

## 요구 사항
- macOS 14 이상, Apple Silicon 또는 Metal 지원 GPU
- Xcode Command Line Tools (Swift 6). Xcode 본체는 필요 없습니다.

## 빌드 / 실행
```sh
make build   # 디버그 빌드
make test    # Swift Testing 테스트
make app     # build/DesktopAutomata.app 생성 (ad-hoc 서명)
make run     # 번들을 만든 뒤 실행
```
종료하려면 메뉴바의 격자 아이콘에서 Quit(⌘Q)을 누릅니다.

## 메뉴
- Enabled: 켜기/끄기
- Pause / Play, Step One Generation, Random Reset, Clear
- Rule: RGB Life, Brian's Brain, Cyclic CA, Rock-Paper-Scissors
- Palette: Neon, Rainbow, Fire & Ice, Pure RGB, Acid
- Style: Pixel(격자선), Glow(꼬리 + 블룸)
- Speed: 1–60 gen/s
- Cell Size: 3–12 pt
- Show HUD: 규칙, 세대, 개체 수, gen/s 표시

## 마우스
바탕화면이 직접 보이는 곳에서만 반응합니다. 커서를 움직이면 색이 순환하는 자취가 남고, 왼쪽 클릭을 하면 원형 버스트가 생깁니다. 별도 권한은 필요 없습니다.

## 팁
- 바탕화면을 클릭할 때 창이 치워지지 않게 하려면 다음 설정을 바꾸세요.
  - 시스템 설정 > 데스크탑 및 Dock > "배경화면 클릭하여 데스크탑 보기" → "스테이지 매니저에서만"
- 로그인할 때 자동으로 실행하려면 시스템 설정 > 일반 > 로그인 항목에 앱을 추가하세요.

## 구조
- `Sources/AutomataCore`: 순수 Swift 코드입니다. 규칙의 CPU 레퍼런스, 해시, 팔레트, 좌표 변환, 일시정지 상태 머신이 들어 있습니다.
- `Sources/AutomataGPU`: Metal 셰이더(런타임 컴파일), 시뮬레이션, 렌더러, 블룸이 들어 있습니다.
- `Sources/DesktopAutomata`: 앱 본체입니다. 메뉴, 바탕화면 창, 마우스 추적, HUD가 들어 있습니다.
- `Tests/`: CPU 레퍼런스 테스트와 CPU/GPU 비트 단위 일치 테스트가 들어 있습니다.
