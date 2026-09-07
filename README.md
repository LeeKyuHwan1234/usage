# AI Usage Dashboard for Windows

현재 배포 버전: **v1.0.2**

Codex와 Claude Code의 구독형 사용량을 Windows 시스템 트레이와 작업표시줄 사용량 위젯에서 확인하는 작은 도구입니다. 트레이 아이콘이나 작업표시줄 위젯을 우클릭하면 둥근 상세 대시보드가 열립니다.

## 표시 내용

- Codex 및 Claude의 5시간(5h)·주간(7d) 사용률
- 남은 비율과 재설정 시각
- 주간 한도는 재설정 **날짜와 시각** 표시
- 사용률 게이지: 초록(0~59%) / 주황(60~79%) / 빨강(80% 이상)
- 트레이 아이콘: 5h·7d 중 가장 높은 사용률을 원형 게이지와 색상으로 표시
- 작업표시줄 위젯: 알림 영역 바로 왼쪽에 실제로 고정되며, ChatGPT·Claude 아이콘과 5h·7d 사용률 게이지 표시
- 상세 대시보드: 한국어 UI로 세션/주간 사용량, 남은 비율, 초기화 시각을 둥근 카드 형태로 표시
- 다크/라이트 모드: 기본 다크 모드이며, 상세 대시보드에서 즉시 전환하고 선택값을 저장
- 원격 서비스 호출은 성공·실패 모두 최소 5분 간격으로 제한하고, 마지막 정상 값을 유지
- 429 응답의 `Retry-After`가 5분보다 길면 해당 시간까지 재시도를 미룸
- Claude Code 로그인 토큰이 만료되면 저장된 갱신 토큰으로 자동 갱신 시도
- 일반 실행은 사용자당 하나만 허용 (중복 실행 시 안내 표시)

## 가장 쉬운 실행 방법

### 다운로드

최신 배포본은 아래 링크에서 받을 수 있습니다.

[AI Usage Dashboard v1.0.2 ZIP 다운로드](https://github.com/LeeKyuHwan1234/usage/releases/latest/download/AI-Usage-Dashboard-v1.0.2.zip)

ZIP 파일을 압축 해제한 뒤 `AI Usage Dashboard.vbs`를 더블클릭하세요.

`AI Usage Dashboard.vbs`를 더블클릭하세요. PowerShell이나 콘솔 창이 열리지 않고 시스템 트레이에서 실행됩니다.

처음 실행하면 사용할 제공자를 선택하는 등록 화면이 나타납니다.

- Codex만 사용: **Codex**만 선택
- Claude만 사용: **Claude**만 선택
- 둘 다 사용: 둘 다 선택

등록 후에는 작업표시줄 오른쪽의 숨겨진 아이콘 영역에서 **AI Usage Dashboard** 아이콘을 우클릭해 상세 사용량을 봅니다.

작업표시줄 오른쪽 알림 영역 바로 왼쪽에는 다음 형식의 작은 위젯이 표시됩니다.

```text
[Claude ]  5h / 18%  ━━━━━      [ChatGPT]  5h / 32%  ━━━━━
            7d / 82%  ━━━━━                 7d / 43%  ━━━━━
```

게이지 색은 초록·주황·빨강 순으로 사용률 상태를 나타냅니다. 작업표시줄 위젯 또는 트레이 아이콘을 우클릭하면 상세 대시보드가 열립니다.

## 다른 사람이 사용하기 전 준비

이 도구는 각 사용자의 PC에 이미 로그인된 Codex 또는 Claude Code 계정만 읽습니다. 다음 중 사용하는 서비스만 준비하면 됩니다.

### Codex 사용량을 표시하려면

1. Codex CLI를 설치합니다.
2. PowerShell에서 ChatGPT 계정으로 로그인합니다.

```powershell
codex login
```

브라우저를 열 수 없으면 다음을 사용합니다.

```powershell
codex login --device-auth
```

### Claude 사용량을 표시하려면

1. Claude Code를 설치합니다.
2. 터미널에서 `claude`를 실행하고 Claude.ai 구독 계정으로 로그인합니다.

첫 등록 화면에는 각 제공자의 로그인 상태가 표시됩니다. 아직 준비되지 않은 제공자를 선택한 경우에도 대시보드에 필요한 로그인 방법을 표시합니다.

## 설정 변경 및 종료

트레이 아이콘 또는 작업표시줄 위젯을 우클릭해 상세 대시보드를 연 뒤 다음 버튼을 사용합니다.

- `설정`: Codex / Claude 표시 여부 변경
- `위젯 숨기기` / `위젯 보이기`: 작업표시줄 위젯을 숨기거나 다시 표시
- `라이트 모드` / `다크 모드`: 대시보드와 작업표시줄 위젯의 색상 모드 전환
- `종료`: 프로그램 완전 종료

숨긴 작업표시줄 위젯은 트레이 아이콘을 우클릭해 대시보드를 연 뒤 `위젯 보이기`로 다시 표시할 수 있습니다.

또는 `Configure AI Usage Dashboard.vbs`를 더블클릭해 등록 화면을 다시 열 수 있습니다.

## PowerShell로 실행하기

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\dev.ps1
```

설정 화면을 강제로 다시 열려면 다음을 실행합니다.

```powershell
.\dev.ps1 -Setup
```

## 필요한 로그인 상태

- **Codex**: ChatGPT 계정 로그인 방식의 Codex CLI가 필요합니다. API 키 전용 사용량은 ChatGPT 구독의 5시간·7일 한도와 다릅니다.
- **Claude**: Claude.ai 구독 계정으로 Claude Code에 로그인되어 있어야 합니다. API 키 전용 사용량은 별도입니다.

각 서비스에 로그인하지 않았거나 선택하지 않은 제공자는 사용량을 조회하지 않습니다.

## 다른 사람에게 공유하기

이 저장소의 최신 Release ZIP(또는 폴더 전체)을 전달하세요. 받는 사람은 압축을 풀고 `AI Usage Dashboard.vbs`를 더블클릭하면 됩니다. `assets` 폴더도 반드시 함께 포함되어야 작업표시줄 아이콘이 정상 표시됩니다. Release ZIP에는 이 폴더가 포함되어 있습니다.

각 사용자는 자신의 Windows 계정으로 Codex와 Claude Code에 로그인해야 합니다. 이 도구는 실행한 사용자의 `%USERPROFILE%\.codex` 및 `%USERPROFILE%\.claude` 경로를 자동으로 사용합니다.

**인증 파일, API 키, 토큰은 절대 함께 복사하거나 공유하지 마세요.**

Windows가 다운로드한 파일을 차단하는 경우 파일을 우클릭하고 **속성 → 차단 해제**를 선택한 뒤 다시 실행하세요.

## 포함 파일

- `AI Usage Dashboard.vbs` — 더블클릭 실행
- `Configure AI Usage Dashboard.vbs` — 제공자 등록/변경
- `dev.ps1` — 트레이 앱 본체
- `assets/chatgpt.png`, `assets/claude.png` — 작업표시줄 위젯 아이콘

## 참고

사용량 조회는 Codex와 Claude Code의 로컬 로그인 정보를 사용해 각 계정의 서버에서 읽습니다. Claude Code의 만료된 액세스 토큰은 로컬에 저장된 갱신 토큰을 사용해 Claude의 로그인 서버에서 자동 갱신을 시도합니다. 인증 정보를 화면이나 별도 서버로 전송·공유하지 않습니다. 제공사가 개인 사용량 조회 응답을 변경하면 카드에 오류가 표시될 수 있습니다.
