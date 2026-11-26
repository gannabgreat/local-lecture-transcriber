// transcribe.swift — Apple 온디바이스 SpeechAnalyzer(macOS 26+) 한국어 전사 엔진.
// live.py 가 부른다. 직접 쓸 일은 시험·파일 전사 정도.
//
//   transcribe [--dict <과목 사전.json>] [--file <오디오>] [--save <녹음.m4a>] [--locale ko-KR] [--volatile]
//
// - --file 없으면 기본 마이크를 실시간 전사한다. SIGINT(kill -INT) 를 받으면 남은 소리까지 확정하고 끝낸다.
// - --file 이면 그 녹음 파일(폰 녹음 등)을 끝까지 전사하고 끝낸다.
// - --save 면 마이크 소리를 그 경로에 AAC(.m4a, 모노 48kbps)로도 저장한다(마이크 모드만). 정지 신호를 받아야 파일이 마무리된다.
// - --dict 의 contextual_strings 를 AnalysisContext 에 넣어 그 과목 용어를 더 잘 알아듣게 한다.
// - stdout = 결과 한 줄에 JSON 하나: {"start":초,"end":초,"text":"...","final":true|false} (start/end 는 입력 시작 기준)
//   --volatile 이면 확정 전(말하는 중) 결과도 final:false 로 낸다 — 실시간 보기용. 없으면 final:true 만.
// - stderr = 상태 메시지(시작·모델 설치·오류)
//
// 빌드: zsh live/build.sh  (→ live/bin/transcribe)
import AVFoundation
import Foundation
import Speech

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func emit(_ r: SpeechTranscriber.Result) {
    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !r.isFinal else { return }
    let obj: [String: Any] = [
        "start": r.range.start.seconds.isFinite ? r.range.start.seconds : 0,
        "end": r.range.end.seconds.isFinite ? r.range.end.seconds : 0,
        "text": text,
        "final": r.isFinal,
    ]
    if let d = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: d, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

/// 분석기에 넣는 것과 같은 버퍼를 .m4a 로 쓴다. 탭 스레드와 정지가 겹치지 않게 잠근다.
final class Recorder: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var failed = false

    init(path: String, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000,
        ]
        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func write(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let f = file else { return }
        do { try f.write(from: buf) } catch {
            if !failed { failed = true; log("⚠️ 녹음 저장 오류(전사는 계속): \(error.localizedDescription)") }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file?.close(); file = nil
    }
}

/// 마이크 버퍼를 분석기 형식으로 바꿔 AsyncStream 에 넣는다(녹음이 있으면 같은 버퍼를 저장).
final class MicFeeder: @unchecked Sendable {
    let engine = AVAudioEngine()
    var converter: AVAudioConverter?
    let target: AVAudioFormat
    let cont: AsyncStream<AnalyzerInput>.Continuation
    let recorder: Recorder?

    init(target: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation, recorder: Recorder?) {
        self.target = target
        self.cont = cont
        self.recorder = recorder
    }

    private let lock = NSLock()
    private var lastBuffer = Date()
    private var watchdog: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    /// 마이크가 바뀌면(이어폰 뽑기·꽂기 등) 엔진이 조용히 멈춘다 — 그때마다 새 장치로 다시 붙는다.
    /// 2026-11-24 회의: 18:37 EarPods 를 뽑자 녹음이 끊긴 채 20:15 까지 아무것도 안 남았다.
    func start() throws {
        try attach()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.reattach(reason: "마이크 장치 바뀜")
        }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = Date().timeIntervalSince(self.lastBuffer); self.lock.unlock()
            if idle > 8 { self.reattach(reason: "소리가 \(Int(idle))초째 안 들어옴") }
        }
        t.resume()
        watchdog = t
    }

    private func reattach(reason: String) {
        lock.lock(); defer { lock.unlock() }
        log("⚠️ \(reason) — 마이크 다시 연결")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try attachLocked() } catch { log("❌ 마이크 다시 연결 실패: \(error.localizedDescription) — 5초 뒤 다시") }
        lastBuffer = Date()
    }

    private func attach() throws { lock.lock(); defer { lock.unlock() }; try attachLocked() }

    private func attachLocked() throws {
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0 else { throw NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 입력 없음(권한 거부 또는 장치 없음)"]) }
        let conv: AVAudioConverter? = natural != target ? AVAudioConverter(from: natural, to: target) : nil
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { [self] buf, _ in
            lock.lock(); lastBuffer = Date(); lock.unlock()
            if let c = conv {
                let ratio = target.sampleRate / natural.sampleRate
                let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                var fed = false
                var err: NSError?
                c.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                if err == nil, out.frameLength > 0 { recorder?.write(out); cont.yield(AnalyzerInput(buffer: out)) }
            } else {
                recorder?.write(buf)
                cont.yield(AnalyzerInput(buffer: buf))
            }
        }
        engine.prepare()
        try engine.start()
        log("🎙 입력 장치: \(Int(natural.sampleRate))Hz \(natural.channelCount)ch")
    }

    func stop() {
        watchdog?.cancel()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        lock.lock(); defer { lock.unlock() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recorder?.close()
        cont.finish()
    }
}

@main
struct Transcribe {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func opt(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
        }
        let dictPath = opt("--dict")
        let filePath = opt("--file")
        let savePath = opt("--save")
        let localeID = opt("--locale") ?? "ko-KR"
        let volatile = args.contains("--volatile") && filePath == nil

        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
                log("❌ 이 맥에서 \(localeID) 전사를 지원하지 않음"); exit(2)
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: volatile ? [.volatileResults, .fastResults] : [], attributeOptions: [.audioTimeRange])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("ℹ️ 음성 모델 확인·설치 중…"); try await req.downloadAndInstall()
            }

            let context = AnalysisContext()
            if let p = dictPath {
                let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as? [String: Any]
                let strings = (d?["contextual_strings"] as? [String]) ?? []
                context.contextualStrings[.general] = strings
                log("ℹ️ 용어 사전: \(d?["subject"] as? String ?? p) (\(strings.count)개)")
            }

            let resultsTask = Task {
                for try await r in transcriber.results where r.isFinal || volatile { emit(r) }
            }

            if let fp = filePath {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: fp))
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.setContext(context)
                log("▶️ 파일 전사 시작: \(fp)")
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await resultsTask.value
                log("⏹ 파일 전사 끝"); exit(0)
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                log("❌ 분석기 오디오 형식을 못 정함"); exit(2)
            }
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            var recorder: Recorder? = nil
            if let sp = savePath {
                do { recorder = try Recorder(path: sp, format: format); log("ℹ️ 녹음 저장: \(sp)") }
                catch { log("⚠️ 녹음 파일을 못 만듦(전사만 한다): \(error.localizedDescription)") }
            }
            let mic = MicFeeder(target: format, cont: cont, recorder: recorder)

            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let stopper = Task {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    var sources: [DispatchSourceSignal] = []
                    var done = false
                    for sig in [SIGINT, SIGTERM] {
                        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                        s.setEventHandler { if !done { done = true; c.resume() } }
                        s.resume(); sources.append(s)
                    }
                    SignalHolder.keep = sources  // 소스가 해제되면 신호를 못 받는다
                }
            }

            try await analyzer.start(inputSequence: stream)
            try mic.start()
            log("▶️ 마이크 전사 시작")
            await stopper.value
            log("⏸ 정지 신호 — 남은 소리 확정 중")
            // 말 끝 직후 바로 끊으면 마지막 문장이 잘린다(2초 뒤 정지 시험에서 「…끝났습니다. .」). 3초 더 듣고 끊는다.
            try? await Task.sleep(for: .seconds(3))
            mic.stop()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultsTask.value
            log("⏹ 마이크 전사 끝"); exit(0)
        } catch {
            log("❌ \(error.localizedDescription)"); exit(1)
        }
    }
}

enum SignalHolder { nonisolated(unsafe) static var keep: [DispatchSourceSignal] = [] }
