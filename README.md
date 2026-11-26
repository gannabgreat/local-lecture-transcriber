# local-lecture-transcriber

맥에서 수업·회의를 **실시간으로 받아쓰는** 도구다. Apple 온디바이스 음성 인식을 써서 **무료**이고, **오프라인**으로 돌고, **소리가 맥 밖으로 나가지 않는다.** 시간 제한도 없다.

- 결과: 줄마다 시각이 찍힌 Markdown 전사본, 그리고 같은 소리의 `.m4a` 녹음
- 시작·정지: 명령어(`live.py`) 또는 바탕화면 위젯(▶ ⏸ ⏹)
- 요구사항: **macOS 26 이상**, Xcode Command Line Tools(`xcode-select --install`), Python 3(표준 라이브러리만). 확인한 기기는 Apple Silicon 맥북 한 대다.

## 빠른 시작

```sh
git clone <이 레포> && cd local-lecture-transcriber
zsh live/build.sh                          # 엔진 빌드 → live/bin/transcribe
python3 live/live.py start "회의" --raw     # 사전 없이 바로 시작 (처음엔 마이크 권한·한국어 모델 설치를 묻는다)
python3 live/live.py stop                  # 다른 터미널에서 — 남은 소리까지 확정하고 멈춘다
```

전사본은 `live/out/YYYY-MM-DD <이름>.md`, 녹음은 `live/out/audio/` 에 생긴다.
`start` 하면 실시간 보기 창(터미널)이 자동으로 뜬다. 확정된 문장 아래에 지금 말하는 중인 글자가 회색으로 계속 고쳐지며 보인다.

## 명령

| 명령 | 하는 일 |
|---|---|
| `live.py start <과목>` | `dict/<과목>.json` 사전을 붙여 시작 |
| `live.py start "<이름>" --raw` | 사전 없이 그 이름으로 시작 |
| `live.py stop` | 멈춤(쉬는시간). 같은 날 같은 이름으로 다시 `start` 하면 같은 파일 끝에 `<!-- 쉬는시간 후 (HH:MM~) -->` 를 붙여 이어 쓴다 |
| `live.py status` | 지금 도는지, 어느 파일인지 |
| `live.py watch` | 실시간 보기 창을 손으로 열기 |
| `live.py file <오디오> <과목> --at "YYYY-MM-DD HH:MM"` | 녹음 파일(폰 녹음 등)을 전사 |

전사본 형식:

```
# 수업 전사 (Apple SpeechAnalyzer (신형)) 2026-11-25 15:05
- 엔진: Apple SpeechAnalyzer (신형)
- 녹음: audio/2026-11-25 알고리즘 1505.m4a
- 언어: ko-KR
- 용어 사전: 알고리즘 (120개)

**[경과 00:00:10 · 시각 15:05:32]** 오늘은 동적 계획법을 …
```

## 바탕화면 위젯 (선택)

```sh
zsh widget/build.sh            # ~/Applications/수업전사.app 를 만들고 로그인 때 켜지게 등록
zsh widget/build.sh --remove   # 제거
```

- 작은 정사각형 창과 메뉴 막대 아이콘이 생긴다. 「수업 · 회의 · 기타」를 고르고 ▶ / ⏸ / ⏹.
- **수업**: 캘린더 앱에서 지금(시작 20분 전 ~ 끝나고 15분 뒤) 일정을 찾는다. 제목에 사전 파일 이름이 들어 있으면 그 사전으로, 없으면 `--raw` 로 시작한다. 처음에 캘린더 접근을 묻는다.
- **회의**: 제목에 「회의」가 들어간 지금 일정의 이름으로 시작하고, 없으면 「회의」로 시작한다. **기타**: 시간표를 안 보고 `기타 HHMM` 으로 시작한다.
- ⏹ 는 `live/out/.finished/<파일>.json` 에 끝 표시를 남긴다. 후처리(요약 등)를 자동으로 돌리고 싶으면 이 폴더를 지켜보면 된다.
- (선택) 캘린더 대신 `live/out/.schedule.json` 을 둘 수 있다. 형식은 `{"until": "<ISO>", "events": [{"title", "start", "end", "kind": "수업|회의", "course": "<사전 이름>"}]}` 이고, `until` 이 지나면 캘린더로 돌아간다.
- 정식 WidgetKit 위젯이 아니라 일반 창이다(Xcode·정식 서명 없이 만들려고). ad-hoc 서명이라 다시 빌드하면 권한을 다시 물을 수 있다.

## 어떻게 동작하나

```
마이크 ─▶ AVAudioEngine 탭 ─▶ AVAudioConverter(분석기 형식, 16kHz 모노)
                                   ├─▶ AsyncStream<AnalyzerInput> ─▶ SpeechAnalyzer[SpeechTranscriber, ko-KR]
                                   └─▶ AVAudioFile(.m4a 녹음)                │
                                                                   JSON 한 줄씩 (stdout)
                                                                             │
                                                     live.py ─▶ 시각 찍힌 .md (+ 실시간 보기 창)
```

### 엔진 — `live/transcribe.swift` (Swift 파일 하나)
- **모델**: Apple **SpeechAnalyzer** 프레임워크(macOS 26+)의 **SpeechTranscriber**, `ko-KR`. 처음 쓸 때 `AssetInventory` 로 시스템이 모델을 내려받는다. 앱에 모델 파일은 없다.
- **마이크**: `AVAudioEngine` 입력에 탭을 달고, `SpeechAnalyzer.bestAvailableAudioFormat` 으로 변환해 `AsyncStream` 으로 분석기에 흘린다.
- **결과**: `attributeOptions: [.audioTimeRange]` 로 구간 시각을 받아 `{"start","end","text","final"}` JSON 을 한 줄씩 낸다. `--volatile` 이면 확정 전 글자(`final:false`)도 낸다(보기 창용, 파일엔 확정 문장만 남는다).
- **정지**: SIGINT·SIGTERM 을 받으면 **3초 더 듣고** 끈 뒤 `finalizeAndFinishThroughEndOfInput()`. 바로 끊으면 마지막 문장이 잘렸다.
- **마이크 재연결**: 입력 장치가 바뀌거나(이어폰 뽑기 등) 소리가 8초째 안 들어오면 다시 연결한다.
- **녹음**: 분석기에 넣는 버퍼와 같은 것을 AAC `.m4a`(모노 16kHz, 48kbps, 시간당 약 21MB)로 쓴다.

### 래퍼 — `live/live.py`
엔진을 띄우고 확정 문장을 시각과 함께 `.md` 에 적는다. `out/.state.json` 으로 중복 실행을 막고 `stop` 대상을 찾는다. 쉬는시간 이어쓰기, 실시간 보기 창, 파일 전사도 여기서 한다.

### 용어 사전 — `dict/`
과목별 JSON 이다. `dict/README.md` 참고.
- 2026-11-15 시험에서 **SpeechTranscriber 는 용어 목록(contextualStrings)을 넣어도 결과가 달라지지 않았다.**
- 용어를 반영하는 DictationTranscriber 는 전체 정확도가 더 나빴다.
- 그래서 사전은 인식이 아니라 **나중에 오표기를 고치는 기준표**로 쓴다(예: LLM 으로 요약할 때 같이 넘김).

## 한계
- 화자를 구분하지 못한다.
- 노트북 내장 마이크로 교실 멀리서 받으면 인식이 거칠다. 사람 이름·고유명사는 자주 틀린다.
- 시각 칸은 문장 구간의 시작이라, 앞에 침묵이 끼면 실제 말보다 이를 수 있다.
- 강제 종료나 전원 차단이 생기면 그 구간의 `.m4a` 가 마무리되지 않아 열리지 않을 수 있다.
- 요약·정리 기능은 들어 있지 않다. 원 사용처에서는 전사본을 LLM 으로 정리해 노트 앱에 붙였다.
