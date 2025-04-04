//
//  RNAudioRecorderPlayer.swift
//  RNAudioRecorderPlayer
//
//  Created by hyochan on 2021/05/05.
//

import Foundation
import AVFoundation

@objc(RNAudioRecorderPlayer)
class RNAudioRecorderPlayer: RCTEventEmitter, AVAudioRecorderDelegate {
    var subscriptionDuration: Double = 0.5
    var audioFileURL: URL?

    // Recorder
    var audioRecorder: AVAudioRecorder!
    var audioSession: AVAudioSession!
    var recordTimer: Timer?
    var _meteringEnabled: Bool = false

    // Player
    var pausedPlayTime: CMTime?
    var audioPlayerAsset: AVURLAsset!
    var audioPlayerItem: AVPlayerItem!
    var audioPlayer: AVPlayer!
    var timeObserverToken: Any?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override static func requiresMainQueueSetup() -> Bool {
      return true
    }

    override func supportedEvents() -> [String]! {
        return ["rn-playback", "rn-recordback"]
    }

    func setAudioFileURL(path: String) {
        if (path == "DEFAULT") {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = cachesDirectory.appendingPathComponent("sound.m4a")
        } else if (path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://")) {
            audioFileURL = URL(string: path)
        } else {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = cachesDirectory.appendingPathComponent(path)
        }
    }

    /**********               Recorder               **********/

    @objc(updateRecorderProgress:)
    public func updateRecorderProgress(timer: Timer) -> Void {
        if (audioRecorder != nil) {
            var currentMetering: Float = 0

            if (_meteringEnabled) {
                audioRecorder.updateMeters()
                currentMetering = audioRecorder.averagePower(forChannel: 0)
            }

            let status = [
                "isRecording": audioRecorder.isRecording,
                "currentPosition": audioRecorder.currentTime * 1000,
                "currentMetering": currentMetering,
            ] as [String : Any];

            sendEvent(withName: "rn-recordback", body: status)
        }
    }

    @objc(startRecorderTimer)
    func startRecorderTimer() -> Void {
        let timer = Timer(
            timeInterval: self.subscriptionDuration,
            target: self,
            selector: #selector(self.updateRecorderProgress),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .default)
        self.recordTimer = timer
    }

    @objc(pauseRecorder:rejecter:)
    public func pauseRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        recordTimer?.invalidate()
        recordTimer = nil;

        DispatchQueue.main.async {
            if (self.audioRecorder == nil) {
                return reject("RNAudioRecorderError", "Cannot pause recorder: recorder instance is nil", nil)
            }

            self.audioRecorder.pause()
            resolve("Recorder paused!")
        }
    }

    @objc(resumeRecorder:rejecter:)
    public func resumeRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        DispatchQueue.main.async {
            if (self.audioRecorder == nil) {
                return reject("RNAudioRecorderError", "Cannot resume recorder: recorder instance is nil", nil)
            }

            self.audioRecorder.record()

            if (self.recordTimer == nil) {
                self.startRecorderTimer()
            }
            resolve("Recorder resumed!")
        }
    }

    @objc
    func construct() {
        self.subscriptionDuration = 0.1
    }

    @objc(audioPlayerDidFinishPlaying:)
    public static func audioPlayerDidFinishPlaying(player: AVAudioRecorder) -> Bool {
        return true
    }

    @objc(audioPlayerDecodeErrorDidOccur:)
    public static func audioPlayerDecodeErrorDidOccur(error: Error?) -> Void {
        print("Playing failed with error")
        print(error ?? "")
        return
    }

    @objc(setSubscriptionDuration:)
    func setSubscriptionDuration(duration: Double) -> Void {
        subscriptionDuration = duration
    }

    // handle interrupt events
    @objc 
    func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let interruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return
        }

        switch interruptionType {
        case AVAudioSession.InterruptionType.began.rawValue:
            pauseRecorder { _ in } rejecter: { _, _, _ in }
            break
        case AVAudioSession.InterruptionType.ended.rawValue:
            resumeRecorder { _ in } rejecter: { _, _, _ in }
            break
        default:
            break
        }
    }

    /**********               Player               **********/

    @objc(startRecorder:audioSets:meteringEnabled:resolve:reject:)
    func startRecorder(path: String,  audioSets: [String: Any], meteringEnabled: Bool, resolve: @escaping RCTPromiseResolveBlock,
       rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {

        _meteringEnabled = meteringEnabled;

        let encoding = audioSets["AVFormatIDKeyIOS"] as? String
        let mode = audioSets["AVModeIOS"] as? String
        let avLPCMBitDepth = audioSets["AVLinearPCMBitDepthKeyIOS"] as? Int
        let avLPCMIsBigEndian = audioSets["AVLinearPCMIsBigEndianKeyIOS"] as? Bool
        let avLPCMIsFloatKey = audioSets["AVLinearPCMIsFloatKeyIOS"] as? Bool
        let avLPCMIsNonInterleaved = audioSets["AVLinearPCMIsNonInterleavedIOS"] as? Bool

        var avMode: AVAudioSession.Mode = AVAudioSession.Mode.default
        var sampleRate = audioSets["AVSampleRateKeyIOS"] as? Int
        var numberOfChannel = audioSets["AVNumberOfChannelsKeyIOS"] as? Int
        var audioQuality = audioSets["AVEncoderAudioQualityKeyIOS"] as? Int
        var bitRate = audioSets["AVEncoderBitRateKeyIOS"] as? Int

        if (sampleRate == nil) {
            sampleRate = 44100;
        }
        
        // Using standard sample rates that are well-supported
        if (sampleRate != 8000 && sampleRate != 16000 && sampleRate != 22050 && sampleRate != 44100 && sampleRate != 48000) {
            sampleRate = 44100; // Default to a safe value
            print("RNARP: Non-standard sample rate provided, defaulting to 44100Hz")
        }

        guard let avFormat: AudioFormatID = avFormat(fromString: encoding) else {
            return reject("RNAudioRecorderError", "Audio format '\(encoding ?? "nil")' not available or not supported", nil)
        }

        if (path == "DEFAULT") {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let fileExt = fileExtension(forAudioFormat: avFormat)
            audioFileURL = cachesDirectory.appendingPathComponent("sound." + fileExt)
        } else {
            setAudioFileURL(path: path)
        }

        if (mode == "measurement") {
            avMode = AVAudioSession.Mode.measurement
        } else if (mode == "gamechat") {
            avMode = AVAudioSession.Mode.gameChat
        } else if (mode == "movieplayback") {
            avMode = AVAudioSession.Mode.moviePlayback
        } else if (mode == "spokenaudio") {
            avMode = AVAudioSession.Mode.spokenAudio
        } else if (mode == "videochat") {
            avMode = AVAudioSession.Mode.videoChat
        } else if (mode == "videorecording") {
            avMode = AVAudioSession.Mode.videoRecording
        } else if (mode == "voicechat") {
            avMode = AVAudioSession.Mode.voiceChat
        } else if (mode == "voiceprompt") {
            if #available(iOS 12.0, *) {
                avMode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
        }


        if (numberOfChannel == nil) {
            numberOfChannel = 2
        }

        if (audioQuality == nil) {
            audioQuality = AVAudioQuality.medium.rawValue
        }

        if (bitRate == nil) {
            bitRate = 128000
        }

        func startRecording() {
            let settings = [
                AVSampleRateKey: sampleRate!,
                AVFormatIDKey: avFormat,
                AVNumberOfChannelsKey: numberOfChannel!,
                AVEncoderAudioQualityKey: audioQuality!,
                AVLinearPCMBitDepthKey: avLPCMBitDepth ?? AVLinearPCMBitDepthKey.count,
                AVLinearPCMIsBigEndianKey: avLPCMIsBigEndian ?? true,
                AVLinearPCMIsFloatKey: avLPCMIsFloatKey ?? false,
                AVLinearPCMIsNonInterleaved: avLPCMIsNonInterleaved ?? false,
                 AVEncoderBitRateKey: bitRate!
            ] as [String : Any]

            do {
                // Make sure we clean up any previous recorder instance
                if (self.audioRecorder != nil) {
                    self.audioRecorder = nil
                }
                
                // Make sure the directory exists
                let directory = audioFileURL!.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                
                // Check if file exists and remove it
                if FileManager.default.fileExists(atPath: audioFileURL!.path) {
                    try FileManager.default.removeItem(at: audioFileURL!)
                }
                
                audioRecorder = try AVAudioRecorder(url: audioFileURL!, settings: settings)

                if (audioRecorder != nil) {
                    audioRecorder.prepareToRecord()
                    audioRecorder.delegate = self
                    audioRecorder.isMeteringEnabled = _meteringEnabled
                    let isRecordStarted = audioRecorder.record()

                    if !isRecordStarted {
                        reject("RNAudioRecorderError", "Error starting recorder: AVAudioRecorder.record() returned false", nil)
                        return
                    }

                    startRecorderTimer()

                    resolve(audioFileURL?.absoluteString)
                    return
                }

                reject("RNAudioRecorderError", "Error initializing recorder: AVAudioRecorder is nil after initialization", nil)
            } catch {
                reject("RNAudioRecorderError", "Exception during recorder initialization: \(error.localizedDescription)", error as NSError)
            }
        }

        audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: avMode, options: [AVAudioSession.CategoryOptions.defaultToSpeaker, AVAudioSession.CategoryOptions.allowBluetooth])
            try audioSession.setActive(true)

            audioSession.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        startRecording()
                    } else {
                        reject("RNAudioRecorderPermissionError", "Microphone permission denied by user", nil)
                    }
                }
            }
        } catch {
            reject("RNAudioRecorderSessionError", "Failed to configure audio session: \(error.localizedDescription)", error as NSError)
        }
    }

    @objc(stopRecorder:rejecter:)
    public func stopRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (recordTimer != nil) {
            recordTimer!.invalidate()
            recordTimer = nil
        }

        DispatchQueue.main.async {
            if (self.audioRecorder == nil) {
                resolve("Recorder is already stopped")
                return
            }

            self.audioRecorder.stop()
            self.audioRecorder = nil

            resolve(self.audioFileURL?.absoluteString)
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Failed to stop recorder")
        }
    }

    /**********               Player               **********/
    func addPeriodicTimeObserver() {
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: subscriptionDuration, preferredTimescale: timeScale)

        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: time,
                                                                queue: .main) {_ in
            if (self.audioPlayer != nil) {
                self.sendEvent(withName: "rn-playback", body: [
                    "isMuted": self.audioPlayer.isMuted,
                    "currentPosition": self.audioPlayerItem.currentTime().seconds * 1000,
                    "duration": self.audioPlayerItem.asset.duration.seconds * 1000,
                    "isFinished": false,
                ])
            }
        }
    }

    func removePeriodicTimeObserver() {
        if let timeObserverToken = timeObserverToken {
            audioPlayer.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
    }


    @objc(startPlayer:httpHeaders:resolve:rejecter:)
    public func startPlayer(
        path: String,
        httpHeaders: [String: String],
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [AVAudioSession.CategoryOptions.defaultToSpeaker, AVAudioSession.CategoryOptions.allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            reject("RNAudioPlayerSessionError", "Failed to configure audio session for playback: \(error.localizedDescription)", error as NSError)
            return
        }

        do {
            setAudioFileURL(path: path)
            
            // Validate that the URL is valid
            guard let fileURL = audioFileURL else {
                reject("RNAudioPlayerPathError", "Invalid audio file path provided: \(path)", nil)
                return
            }
            
            // Check if the file exists for local files
            if fileURL.isFileURL && !FileManager.default.fileExists(atPath: fileURL.path) {
                reject("RNAudioPlayerFileError", "Audio file does not exist at path: \(fileURL.path)", nil)
                return
            }
            
            audioPlayerAsset = AVURLAsset(url: fileURL, options:["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
            audioPlayerItem = AVPlayerItem(asset: audioPlayerAsset!)

            if (audioPlayer == nil) {
                audioPlayer = AVPlayer(playerItem: audioPlayerItem)
            } else {
                audioPlayer.replaceCurrentItem(with: audioPlayerItem)
            }

            addPeriodicTimeObserver()
            NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying), name: Notification.Name.AVPlayerItemDidPlayToEndTime, object: audioPlayer.currentItem)
            audioPlayer.play()
            resolve(audioFileURL?.absoluteString)
        } catch {
            reject("RNAudioPlayerError", "Failed to initialize player: \(error.localizedDescription)", error as NSError)
        }
    }
    
    @objc
    public func playerDidFinishPlaying(notification: Notification) {
        if let playerItem = notification.object as? AVPlayerItem {
            let duration = playerItem.duration.seconds * 1000
            self.sendEvent(withName: "rn-playback", body: [
                "isMuted": self.audioPlayer?.isMuted as Any,
                "currentPosition": duration,
                "duration": duration,
                "isFinished": true,
            ])
        }
    }

    @objc(stopPlayer:rejecter:)
    public func stopPlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerError", "Cannot stop player: player instance is nil", nil)
        }

        audioPlayer.pause()
        self.removePeriodicTimeObserver()
        self.audioPlayer = nil;

        resolve(audioFileURL?.absoluteString)
    }

    @objc(pausePlayer:rejecter:)
    public func pausePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerError", "Cannot pause player: player instance is nil", nil)
        }

        audioPlayer.pause()
        resolve("Player paused!")
    }

    @objc(resumePlayer:rejecter:)
    public func resumePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerError", "Cannot resume player: player instance is nil", nil)
        }

        audioPlayer.play()
        resolve("Resumed!")
    }

    @objc(seekToPlayer:resolve:rejecter:)
    public func seekToPlayer(
        time: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerError", "Cannot seek: player instance is nil", nil)
        }

        audioPlayer.seek(to: CMTime(seconds: time / 1000, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        resolve("Seeked successfully!")
    }

    @objc(setVolume:resolve:rejecter:)
    public func setVolume(
        volume: Float,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        audioPlayer.volume = volume
        resolve(volume)
    }

    @objc(setPlaybackSpeed:resolve:rejecter:)
    public func setPlaybackSpeed(
        playbackSpeed: Float,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerError", "Cannot set playback speed: player instance is nil", nil)
        }

        audioPlayer.rate = playbackSpeed
        resolve("Playback speed set to \(playbackSpeed)")
    }

    private func avFormat(fromString encoding: String?) -> AudioFormatID? {
        if (encoding == nil) {
            return kAudioFormatAppleLossless
        } else {
            if (encoding == "lpcm") {
                return kAudioFormatAppleIMA4
            } else if (encoding == "ima4") {
                return kAudioFormatAppleIMA4
            } else if (encoding == "aac") {
                return kAudioFormatMPEG4AAC
            } else if (encoding == "MAC3") {
                return kAudioFormatMACE3
            } else if (encoding == "MAC6") {
                return kAudioFormatMACE6
            } else if (encoding == "ulaw") {
                return kAudioFormatULaw
            } else if (encoding == "alaw") {
                return kAudioFormatALaw
            } else if (encoding == "mp1") {
                return kAudioFormatMPEGLayer1
            } else if (encoding == "mp2") {
                return kAudioFormatMPEGLayer2
            } else if (encoding == "mp4") {
                return kAudioFormatMPEG4AAC
            } else if (encoding == "alac") {
                return kAudioFormatAppleLossless
            } else if (encoding == "amr") {
                return kAudioFormatAMR
            } else if (encoding == "flac") {
                if #available(iOS 11.0, *) {
                    return kAudioFormatFLAC
                }
            } else if (encoding == "opus") {
                return kAudioFormatOpus
            } else if (encoding == "wav") {
                return kAudioFormatLinearPCM
            }
        }
        return nil;
    }

    private func fileExtension(forAudioFormat format: AudioFormatID) -> String {
        switch format {
        case kAudioFormatOpus:
            return "ogg"
        case kAudioFormatLinearPCM:
            return "wav"
        case kAudioFormatAC3, kAudioFormat60958AC3:
            return "ac3"
        case kAudioFormatAppleIMA4:
            return "caf"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4CELP, kAudioFormatMPEG4HVXC, kAudioFormatMPEG4TwinVQ, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_Spatial:
            return "m4a"
        case kAudioFormatMACE3, kAudioFormatMACE6:
            return "caf"
        case kAudioFormatULaw, kAudioFormatALaw:
            return "wav"
        case kAudioFormatQDesign, kAudioFormatQDesign2:
            return "mov"
        case kAudioFormatQUALCOMM:
            return "qcp"
        case kAudioFormatMPEGLayer1:
            return "mp1"
        case kAudioFormatMPEGLayer2:
            return "mp2"
        case kAudioFormatMPEGLayer3:
            return "mp3"
        case kAudioFormatMIDIStream:
            return "mid"
        case kAudioFormatAppleLossless:
            return "m4a"
        case kAudioFormatAMR:
            return "amr"
        case kAudioFormatAMR_WB:
            return "awb"
        case kAudioFormatAudible:
            return "aa"
        case kAudioFormatiLBC:
            return "ilbc"
        case kAudioFormatDVIIntelIMA, kAudioFormatMicrosoftGSM:
            return "wav"
        default:
            // Generic file extension for types that don't have a natural
            // file extension
            return "audio"
        }
    }
}
