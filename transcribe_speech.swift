import Foundation
import Speech

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

if CommandLine.arguments.count < 2 {
    fail("Usage: swift transcribe_speech.swift AUDIO_FILE")
}

let audioPath = CommandLine.arguments[1]
let localeId = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "zh-CN"
let audioURL = URL(fileURLWithPath: audioPath)

let authSemaphore = DispatchSemaphore(value: 0)
var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { status in
    authStatus = status
    authSemaphore.signal()
}
authSemaphore.wait()

guard authStatus == .authorized else {
    fail("Speech recognition not authorized: \(authStatus.rawValue)")
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
    fail("Could not create recognizer for locale \(localeId)")
}

guard recognizer.isAvailable else {
    fail("Speech recognizer is not available")
}

let request = SFSpeechURLRecognitionRequest(url: audioURL)
request.shouldReportPartialResults = false

let done = DispatchSemaphore(value: 0)
var task: SFSpeechRecognitionTask?

task = recognizer.recognitionTask(with: request) { result, error in
    if let result = result, result.isFinal {
        print(result.bestTranscription.formattedString)
        for segment in result.bestTranscription.segments {
            let start = segment.timestamp
            let end = segment.timestamp + segment.duration
            print(String(format: "[%.2f - %.2f] %@", start, end, segment.substring))
        }
        done.signal()
    }
    if let error = error {
        fputs("Recognition error: \(error.localizedDescription)\n", stderr)
        done.signal()
    }
}

if done.wait(timeout: .now() + 600) == .timedOut {
    task?.cancel()
    fail("Recognition timed out")
}
