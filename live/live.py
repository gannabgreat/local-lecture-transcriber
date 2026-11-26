#!/usr/bin/env python3
"""수업 실시간 전사 — Apple 온디바이스 SpeechAnalyzer(bin/transcribe)를 감싸 .md 로 남긴다.

  python3 live.py start <과목> [--no-view]   포그라운드로 돈다(뒤에서 돌리려면 & 또는 위젯)
  python3 live.py start "<이름>" --raw       사전 없이 그 이름으로(회의·사전 없는 수업 — 위젯이 쓴다)
                                    실시간 보기 창(터미널)을 자동으로 연다. 이미 열려 있으면 안 연다.
  python3 live.py watch             실시간 보기 — 확정 문장 + 지금 말하는 중인 글자(회색). 쉬는시간에도 안 닫히고 기다린다
  python3 live.py stop              [쉬는시간]·[마감] — 남은 소리까지 확정하고 멈춘다
  python3 live.py status            지금 도는지·파일 경로
  python3 live.py file <오디오> <과목> [--at "YYYY-MM-DD HH:MM"]   폰 녹음 파일 전사

<과목> = dict/ 사전 파일 이름의 일부(예: dict/알고리즘.json → 알고리즘). 사전 없이 하려면 "없음" 또는 --raw.
같은 날 같은 과목을 다시 start 하면 같은 파일 끝에 <!-- 쉬는시간 후 (HH:MM~) --> 와 새 머리를 붙여 이어 쓴다.
경과 시간은 그날 첫 start 기준으로 이어진다.

출력: live/out/YYYY-MM-DD <과목>.md (git 에 안 올린다)
녹음: start 마다 live/out/audio/YYYY-MM-DD <과목> HHMM.m4a. 쉬는시간 뒤 다시 start 하면 새 파일이 생긴다.
      전사 .md 머리의 「- 녹음:」 줄이 그 구간 파일이다.
엔진은 SpeechTranscriber 다. 이 엔진은 용어 사전을 넣어도 인식 결과가 거의 안 바뀐다(2026-11-15 시험).
사전은 정리 단계에서 오표기 교정에 쓴다 — dict/README.md.
"""
import datetime as dt
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE / "bin" / "transcribe"
DICT_DIR = HERE.parent / "dict"
OUT = HERE / "out"
AUDIO = OUT / "audio"              # 마이크 녹음 .m4a (git 에 안 올라간다 — out/ 아래)
STATE = OUT / ".state.json"
VOLATILE = OUT / ".volatile"      # 지금 말하는 중인 글자(확정 전) — watch 가 읽는다
WATCH_PID = OUT / ".watch.pid"
WATCH_IDLE_EXIT = 60 * 60          # 전사가 이만큼 멈춰 있으면 보기 창도 끝낸다
ALIASES = {}  # 줄임말 → 사전 파일 이름 일부. 예: {"알고": "알고리즘"}
ENGINE = "Apple SpeechAnalyzer (신형)"


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def find_dict(course, raw=False):
    if raw:
        name = " ".join(course.replace("/", "-").replace(":", "-").split()).strip(". ")
        return None, name or "기타", None
    if course == "없음":
        return None, "없음", None
    key = ALIASES.get(course.lower(), ALIASES.get(course, course))
    import unicodedata
    nfc = lambda x: unicodedata.normalize("NFC", x).lower()
    hits = [p for p in sorted(DICT_DIR.glob("*.json")) if nfc(key) in nfc(p.stem)]
    if len(hits) != 1:
        names = ", ".join(p.stem for p in sorted(DICT_DIR.glob("*.json")))
        die(f"❌ 과목 '{course}' 사전을 하나로 못 정함(찾은 것 {len(hits)}개). 있는 사전: {names}")
    d = json.loads(hits[0].read_text(encoding="utf-8"))
    return hits[0], d.get("subject", hits[0].stem), len(d.get("contextual_strings", []))


def hms(sec):
    sec = max(0, int(sec))
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def header(when, subject, n):
    dict_line = "없음" if n is None else f"{subject} ({n}개)"
    return (f"# 수업 전사 ({ENGINE}) {when:%Y-%m-%d %H:%M}\n"
            f"- 엔진: {ENGINE}\n- 언어: ko-KR\n- 용어 사전: {dict_line}\n\n")


def read_state():
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def run_engine(cmd, out_f, base_wall, offset):
    """엔진을 돌려 확정 문장을 out_f 에 적는다. SIGINT/SIGTERM 은 엔진에 넘겨 남은 소리를 확정하게 한다."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, encoding="utf-8")

    def forward(signum, _frame):
        if proc.poll() is None:
            proc.send_signal(signal.SIGINT)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    lines = 0
    for raw in proc.stdout:
        try:
            r = json.loads(raw)
        except ValueError:
            continue
        if r.get("final") is False:
            write_volatile(r.get("text", ""))
            continue
        write_volatile("")
        if not r.get("text"):
            continue
        start = float(r.get("start") or 0)
        at = base_wall + dt.timedelta(seconds=start)
        out_f.write(f"**[경과 {hms(offset + start)} · 시각 {at:%H:%M:%S}]** {r['text']}\n\n")
        out_f.flush()
        lines += 1
    rc = proc.wait()
    write_volatile("")
    return rc, lines


def write_volatile(text):
    tmp = VOLATILE.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(VOLATILE)


def cmd_start(course, view=True, raw=False):
    if not BIN.exists():
        die(f"❌ 엔진 없음 — 먼저 zsh {HERE / 'build.sh'}")
    st = read_state()
    if st and alive(st["pid"]):
        die(f"❌ 이미 전사 중: {st['course']} → {st['file']} (pid {st['pid']}). 먼저 stop")
    dict_path, subject, n = find_dict(course, raw)
    OUT.mkdir(exist_ok=True)
    now = dt.datetime.now()
    out = OUT / f"{now:%Y-%m-%d} {subject}.md"
    meta = OUT / f".{out.stem}.json"  # 그날 첫 시작 시각(경과 기준)
    first = now
    if out.exists() and meta.exists():
        first = dt.datetime.fromisoformat(json.loads(meta.read_text(encoding="utf-8"))["first_start"])
    else:
        meta.write_text(json.dumps({"first_start": now.isoformat()}), encoding="utf-8")
    resumed = out.exists() and out.stat().st_size > 0
    audio = AUDIO / f"{now:%Y-%m-%d} {subject} {now:%H%M}.m4a"
    AUDIO.mkdir(exist_ok=True)
    with out.open("a", encoding="utf-8") as f:
        if resumed:
            f.write(f"\n<!-- 쉬는시간 후 ({now:%H:%M}~) -->\n\n")
        f.write(header(now, subject, n).replace("- 언어:", f"- 녹음: audio/{audio.name}\n- 언어:"))
        f.flush()
        STATE.write_text(json.dumps({"pid": os.getpid(), "course": subject, "file": str(out),
                                     "started": now.isoformat()}, ensure_ascii=False), encoding="utf-8")
        print(f"▶️ 전사 {'재개' if resumed else '시작'}: {subject} → {out}", flush=True)
        cmd = [str(BIN), "--volatile", "--save", str(audio)] + (["--dict", str(dict_path)] if dict_path else [])
        if view:
            open_viewer()
        offset = (now - first).total_seconds()
        try:
            rc, lines = run_engine(cmd, f, now, offset)
        finally:
            st = read_state()
            if st and st.get("pid") == os.getpid():
                STATE.unlink()
    print(f"⏹ 전사 멈춤: {lines}줄 · 엔진 종료코드 {rc} → {out}", flush=True)
    sys.exit(0 if rc == 0 else 1)


def cmd_stop():
    st = read_state()
    if not st or not alive(st["pid"]):
        die("ℹ️ 도는 전사 없음", 0)
    os.kill(st["pid"], signal.SIGINT)
    for _ in range(120):  # 남은 소리 확정에 보통 몇 초
        if not alive(st["pid"]):
            print(f"⏹ 멈춤: {st['course']} → {st['file']}")
            return
        time.sleep(0.5)
    die(f"⚠️ 60초 안에 안 멈춤 — pid {st['pid']} 확인")


def cmd_status():
    st = read_state()
    if st and alive(st["pid"]):
        print(f"🔴 전사 중: {st['course']} · {st['started'][:16]} 부터 → {st['file']} (pid {st['pid']})")
    else:
        print("⚪ 전사 안 함")


def cmd_file(audio, course, at):
    if not BIN.exists():
        die(f"❌ 엔진 없음 — 먼저 zsh {HERE / 'build.sh'}")
    dict_path, subject, n = find_dict(course)
    base = dt.datetime.strptime(at, "%Y-%m-%d %H:%M") if at else dt.datetime.fromtimestamp(Path(audio).stat().st_mtime)
    OUT.mkdir(exist_ok=True)
    out = OUT / f"{base:%Y-%m-%d %H%M} {subject} (녹음).md"
    with out.open("w", encoding="utf-8") as f:
        f.write(header(base, subject, n).replace("- 언어:", f"- 원본: {Path(audio).name}\n- 언어:"))
        cmd = [str(BIN), "--file", audio] + (["--dict", str(dict_path)] if dict_path else [])
        rc, lines = run_engine(cmd, f, base, 0)
    print(f"{'✅' if rc == 0 else '❌'} {lines}줄 → {out}")
    sys.exit(0 if rc == 0 else 1)


def open_viewer():
    """실시간 보기 창을 연다(Terminal 새 창). 이미 떠 있으면 그대로 둔다."""
    try:
        if alive(int(WATCH_PID.read_text())):
            return
    except (OSError, ValueError):
        pass
    cmd_file_ = OUT / ".watch.command"
    cmd_file_.write_text(f"#!/bin/zsh\nclear\nexec /usr/bin/python3 '{Path(__file__).resolve()}' watch\n", encoding="utf-8")
    cmd_file_.chmod(0o755)
    subprocess.run(["open", str(cmd_file_)], check=False)


def width(s):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def tail_fit(s, cols):
    """한글 폭(2칸)을 따져 끝쪽 cols 칸만 남긴다."""
    out, w = [], 0
    for c in reversed(s):
        cw = width(c)
        if w + cw > cols:
            break
        out.append(c)
        w += cw
    return "".join(reversed(out))


def cmd_watch():
    import re
    import shutil
    OUT.mkdir(exist_ok=True)
    WATCH_PID.write_text(str(os.getpid()))
    GRAY, DIM, BOLD, OFF, CLR = "\x1b[90m", "\x1b[2m", "\x1b[1m", "\x1b[0m", "\r\x1b[K"
    line_re = re.compile(r"^\*\*\[경과 (\S+) · 시각 (\S+)\]\*\* (.*)$")
    cur, pos, last_vol, idle_since = None, 0, None, None
    print(f"{BOLD}📝 실시간 전사 보기{OFF}  {DIM}(닫아도 전사는 계속된다 · Ctrl-C){OFF}\n", flush=True)
    try:
        while True:
            st = read_state()
            running = bool(st and alive(st["pid"]))
            if running and st["file"] != cur:
                cur, pos = st["file"], 0
                sys.stdout.write(f"{CLR}{BOLD}── {Path(cur).stem} ──{OFF}\n")
            new = ""
            if cur:
                try:
                    with open(cur, encoding="utf-8") as f:
                        f.seek(pos)
                        new = f.read()
                        if new and not new.endswith("\n"):  # 반쯤 쓰인 줄은 다음 번에
                            new = new[: new.rfind("\n") + 1]
                        pos += len(new.encode("utf-8"))
                except OSError:
                    pass
            if new:
                sys.stdout.write(CLR)
                for ln in new.splitlines():
                    m = line_re.match(ln)
                    if m:
                        sys.stdout.write(f"{DIM}{m.group(2)}{OFF} {m.group(3)}\n")
                    elif ln.startswith("<!-- 쉬는시간 후"):
                        sys.stdout.write(f"\n{BOLD}☕ {ln[5:-4].strip()}{OFF}\n")
                last_vol = None
            if running:
                idle_since = None
                try:
                    vol = VOLATILE.read_text(encoding="utf-8").strip()
                except OSError:
                    vol = ""
                show = f"{GRAY}… {tail_fit(vol, shutil.get_terminal_size().columns - 3)}{OFF}" if vol else f"{DIM}🎙 듣는 중{OFF}"
            else:
                idle_since = idle_since or time.time()
                if time.time() - idle_since > WATCH_IDLE_EXIT:
                    sys.stdout.write(f"{CLR}⏹ 전사가 1시간 멈춰 있어 보기를 끝낸다\n")
                    break
                show = f"{DIM}⏸ 전사 멈춤 — 다시 시작하면 이어서 보인다{OFF}"
            if show != last_vol:
                sys.stdout.write(CLR + show)
                last_vol = show
            sys.stdout.flush()
            time.sleep(0.2)
    except KeyboardInterrupt:
        print()
    finally:
        try:
            if WATCH_PID.read_text() == str(os.getpid()):
                WATCH_PID.unlink()
        except OSError:
            pass


def main(argv):
    # 위젯(Swift Process)은 인자를 NFD(한글 자모 분리)로 넘긴다 — 그대로면 사전 이름과 안 맞는다(2026-11-23)
    import unicodedata
    argv = [unicodedata.normalize("NFC", x) for x in argv]
    if len(argv) >= 2 and argv[0] == "start":
        cmd_start(argv[1], view="--no-view" not in argv, raw="--raw" in argv)
    elif argv[:1] == ["watch"]:
        cmd_watch()
    elif argv[:1] == ["stop"]:
        cmd_stop()
    elif argv[:1] == ["status"]:
        cmd_status()
    elif len(argv) >= 3 and argv[0] == "file":
        at = argv[argv.index("--at") + 1] if "--at" in argv else None
        cmd_file(argv[1], argv[2], at)
    else:
        die(__doc__, 2)


if __name__ == "__main__":
    main(sys.argv[1:])
