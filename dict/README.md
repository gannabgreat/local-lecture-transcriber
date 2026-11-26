# dict — 과목별 용어 사전

과목 하나에 파일 하나(`dict/<과목>.json`). `live.py start <과목>` 의 `<과목>` 은 파일 이름의 일부면 된다.
위젯은 캘린더 일정 제목에 이 파일 이름이 들어 있으면 그 과목으로 시작한다(띄어쓰기·기호 무시).

| 키 | 뜻 |
|---|---|
| `subject` | 과목 이름(전사 파일 이름에 쓰임) |
| `contextual_strings` | 핵심 용어 100~150개. 엔진에 넘기지만 SpeechTranscriber 는 거의 반영하지 않는다 — 실제로는 바른 표기 기준표 |
| `replace_safe` | 실제 전사에서 본 오표기 → 바른 표기. 정리할 때 바로 바꿔도 되는 것 |
| `context_needed` | 흔한 말과 겹치거나 아직 예측인 오표기. 문맥을 보고만 고친다 |
| `entries` | (선택) 항목별 메모: term · spoken(발음) · asr_variants(observed = 실제로 봤나) · weeks · note |

`예시과목.json` 을 복사해 과목마다 만든다. 사전이 없어도 전사는 된다(`--raw`).
