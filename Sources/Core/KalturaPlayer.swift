// ===================================================================================================
// Copyright (C) 2017 Kaltura Inc.
//
// Licensed under the AGPLv3 license, unless a different license for a
// particular library is specified in the applicable library path.
//
// You may obtain a copy of the License at
// https://www.gnu.org/licenses/agpl-3.0.html
// ===================================================================================================

import Foundation
import PlayKit
import KalturaNetKit
import SwiftyJSON

public class KalturaPlayer<T: MediaOptions> : TokenReplacer, PlayerDelegate, KalturaPlayerUIManagerDelegate {
   
    var partnerId: Int
    var ks: String?
    
    var player: Player!
    var autoPlay: Bool = false
    var preload: Bool = false
    var startPosition: Double = 0.0
    var mediaEntry: PKMediaEntry?
    var lookupTable: [String : String]?
    
    var preferredFormat: PKMediaSource.MediaFormat = .unknown
    var referrer: String = ""
    var serverUrl: String = ""
    
    var uiManager: KalturaPlayerUIManager?
    var uiConf: PlayerConfigObject?
    
    internal init(options: KalturaPlayerOptions?) throws {
        guard let options = options else { throw NSError(domain: "KalturaPlayerOptions cannot be nil", code: 0, userInfo: nil) }
        
        self.partnerId = options.partnerId
        
        self.ks = options.ks
        
        if let autoPlay = options.autoPlay {
            self.autoPlay = autoPlay
        } else if let autoPlay = options.uiConf?.autoPlay {
            self.autoPlay = autoPlay
        }
        
        if let preload = options.preload {
            self.preload = preload
        } else if let preload = options.uiConf?.preload {
            self.preload = preload
        }

        self.preload = preload || autoPlay
        self.preferredFormat = options.preferredFormat
        self.uiManager = options.uiManager
        self.uiConf = options.uiConf
        
        if let url = options.serverUrl {
            self.serverUrl = url + (url.hasSuffix("/") ? "" : "/")
        } else {
            self.serverUrl = getDefaultServerUrl()
        }
        
        self.referrer = buildReferrer(appReferrer: options.referrer)
        
        registerPlugins()
        try loadPlayer(pluginConfig: merge(uiConfPluginConfig: uiConf?.pluginConfig, optionsPluginConfig: options.pluginConfig))
        
        if let settings = merge(uiConfTrackSelection: uiConf?.trackSelection, optionsTrackSelection: options.trackSelectionSettings) {
            self.player.settings.trackSelection = settings
        }
    }
    
    public func setMedia(_ mediaEntry: PKMediaEntry) {
        self.mediaEntry = mediaEntry
        
        if preload {
            prepare()
        }
    }
    
    public func prepare() {
        if let _ = mediaEntry {
            let config = MediaConfig(mediaEntry: mediaEntry!, startTime: startPosition)
            prepare(config)
            
            if autoPlay {
                play()
            }
        }
    }
    
    public func getKS() -> String? {
        return ks
    }
    
    public func setKS(_ ks: String) {
        self.ks = ks
        updateKS(ks)
    }

    func buildReferrer(appReferrer: String?) -> String {
        if let url = appReferrer, verifyUrl(url) {
            return url
        }
        
        return "app://\(Bundle.main.bundleIdentifier ?? "")"
    }
    
    func verifyUrl(_ urlString: String) -> Bool {
        if let url = URL(string: urlString) {
            return UIApplication.shared.canOpenURL(url)
        }
        return false
    }
    
    func merge(uiConfPluginConfig: PluginConfig?, optionsPluginConfig: PluginConfig?) -> PluginConfig? {
        if uiConfPluginConfig == nil {
            return optionsPluginConfig
        }
        if optionsPluginConfig == nil {
            return uiConfPluginConfig
        }
        for item in optionsPluginConfig!.config {
            if let params = uiConfPluginConfig?.config[item.key] {
                if let type = PlayKitManager.shared.pluginClass(by: item.key) as? PKPluginMerge.Type {
                    uiConfPluginConfig?.config[item.key] = type.merge(uiConf: params, appConf: item.value)
                }
            } else {
                uiConfPluginConfig?.config[item.key] = item.value
            }
        }
        return uiConfPluginConfig
    }
    
    func merge(uiConfTrackSelection: PKTrackSelectionSettings?, optionsTrackSelection: PKTrackSelectionSettings?) -> PKTrackSelectionSettings? {
        if uiConfTrackSelection == nil {
            return optionsTrackSelection
        }
        if optionsTrackSelection == nil {
            return uiConfTrackSelection
        }
        
        let result = uiConfTrackSelection!
        
        if let audioSelectionLanguage = optionsTrackSelection!.audioSelectionLanguage {
            result.audioSelectionLanguage = audioSelectionLanguage
        }
        if let textSelectionLanguage = optionsTrackSelection!.textSelectionLanguage {
            result.textSelectionLanguage = textSelectionLanguage
        }
        if optionsTrackSelection!.audioSelectionMode != .off {
            result.audioSelectionMode = optionsTrackSelection!.audioSelectionMode
        }
        if optionsTrackSelection!.textSelectionMode != .off {
            result.textSelectionMode = optionsTrackSelection!.textSelectionMode
        }

        return result
    }
    
    func loadPlayer(pluginConfig: PluginConfig?) throws {
        let kalturaConfigs = PluginConfig(config: getKalturaPluginConfigs())
        let _pluginConfig = merge(uiConfPluginConfig: kalturaConfigs, optionsPluginConfig: pluginConfig)
        
        self.player = try PlayKitManager.shared.loadPlayer(pluginConfig: _pluginConfig, tokenReplacer: self)
        self.player.delegate = self
        
        KalturaPlaybackRequestAdapter.install(in: player, withReferrer: referrer)
    }
    
    func mediaLoadCompleted(entry: PKMediaEntry?, error: Error?, callback: ((PKMediaEntry?, Error?) -> Void)?) {
        if let _ = entry {
            removeUnpreferredFormatsIfNeeded(entry: entry!)
        }
        mediaEntry = entry
        lookupTable = entry?.metadata

        DispatchQueue.main.async { [weak self] in
            callback?(entry, error)
            if error == nil && self?.preload == true {
                self?.prepare()
            }
        }
    }
    
    func removeUnpreferredFormatsIfNeeded(entry: PKMediaEntry) {
        if preferredFormat != .unknown, let entrySources = entry.sources {
            var preferredSources = [PKMediaSource]()
            for s in entrySources {
                if s.mediaFormat == preferredFormat {
                    preferredSources.append(s)
                }
            }
            
            if preferredSources.count > 0 {
                entry.sources = preferredSources
            }
        }
    }
    
    public func replace(expression: String) -> String {
        var result = expression
        if let table = lookupTable {
            for (key, value) in table {
                result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
        }
        return result
    }
    
    public func playerShouldPlayAd(_ player: Player) -> Bool {
        return true
    }
    
    // Player controls
    @objc public var duration: TimeInterval {
        return player.duration
    }
    
    @objc public var currentState: PlayerState {
        return player.currentState
    }
    
    @objc public var isPlaying: Bool {
        return player.isPlaying
    }
    
    @objc public weak var view: PlayerView? {
        get {
            return player.view
        }
        set {
            player.view = newValue
            uiManager?.addControlsView(to: player, delegate: self)
        }
    }
        
    @objc public var currentTime: TimeInterval {
        get {
            return player.currentTime
        }
        set {
            player.currentTime = newValue
        }
    }
    
    @objc public var currentAudioTrack: String? {
        return player.currentAudioTrack
    }
    
    @objc public var currentTextTrack: String? {
        return player.currentTextTrack
    }
    
    @objc public var rate: Float {
        return player.rate
    }
    
    @objc public var loadedTimeRanges: [PKTimeRange]? {
        return player.loadedTimeRanges
    }
    
    @objc public func addObserver(_ observer: AnyObject, event: PKEvent.Type, block: @escaping (PKEvent) -> Void) {
        player.addObserver(observer, event: event, block: block)
    }
    
    @objc public func addObserver(_ observer: AnyObject, events: [PKEvent.Type], block: @escaping (PKEvent) -> Void) {
        player.addObserver(observer, events: events, block: block)
    }
    
    @objc public func removeObserver(_ observer: AnyObject, event: PKEvent.Type) {
        player.removeObserver(observer, event: event)
    }
    
    @objc public func removeObserver(_ observer: AnyObject, events: [PKEvent.Type]) {
        player.removeObserver(observer, events: events)
    }
    
    @objc public func updatePluginConfig(pluginName: String, config: Any) {
        player.updatePluginConfig(pluginName: pluginName, config: config)
    }
    
    @objc public func getController(type: PKController.Type) -> PKController? {
        return player.getController(type: type)
    }

    @objc public func addPeriodicObserver(interval: TimeInterval, observeOn dispatchQueue: DispatchQueue?, using block: @escaping (TimeInterval) -> Void) -> UUID {
        return player.addPeriodicObserver(interval: interval, observeOn: dispatchQueue, using: block)
    }
    
    
    @objc public func addBoundaryObserver(boundaries: [PKBoundary], observeOn dispatchQueue: DispatchQueue?, using block: @escaping (TimeInterval, Double) -> Void) -> UUID {
        return player.addBoundaryObserver(boundaries: boundaries, observeOn: dispatchQueue, using: block)
    }
    
    @objc public func removePeriodicObserver(_ token: UUID) {
        player.removePeriodicObserver(token)
    }
    
    @objc public func removeBoundaryObserver(_ token: UUID) {
        player.removeBoundaryObserver(token)
    }
    
    @objc public func play() {
        player.play()
    }
    
    @objc public func pause() {
        player.pause()
    }
    
    @objc public func resume() {
        player.resume()
    }
    
    @objc public func stop() {
        player.stop()
    }
    
    @objc public func seek(to time: TimeInterval) {
        player.seek(to: time)
    }
    
    @objc public func selectTrack(trackId: String) {
        player.selectTrack(trackId: trackId)
    }
    
    @objc public func destroy() {
        player.destroy()
    }
    
    @objc func prepare(_ config: MediaConfig) {
        player.prepare(config)
    }
    
    //abstract methods
    public func loadMedia(mediaOptions: T, callback: ((PKMediaEntry?, Error?) -> Void)? = nil) {
        fatalError("must be implemented in subclass")
    }

    func getDefaultServerUrl() -> String {
        fatalError("must be implemented in subclass")
    }
    
    func getKalturaPluginConfigs() -> [String : Any] {
        fatalError("must be implemented in subclass")
    }
    
    func registerPlugins() {
        fatalError("must be implemented in subclass")
    }
    
    func updateKS(_ ks: String) {
        fatalError("must be implemented in subclass")
    }
    
    // KalturaPlayerUIManagerDelegate
    public func kalturaPlayerUIManagerDidRequestPlayWithoutMediaEntry(_ kalturaPlayerUIManager: KalturaPlayerUIManager) {
        prepare()
        play()
    }
    
}

public struct KalturaPlayerOptions {
    public var autoPlay: Bool?
    public var preload: Bool?
    public var preferredFormat: PKMediaSource.MediaFormat = .unknown
    public var serverUrl: String?
    public var referrer: String?
    public var uiManager: KalturaPlayerUIManager?
    public var partnerId: Int
    public var ks: String?
    public var uiConf: PlayerConfigObject?
    public var pluginConfig: PluginConfig?
    public var trackSelectionSettings: PKTrackSelectionSettings?
    
    public init(partnerId: Int) {
        self.partnerId = partnerId
    }
}

public protocol KalturaPlayerUIManager {
    func addControlsView(to player: Player, delegate: KalturaPlayerUIManagerDelegate)
}

public protocol KalturaPlayerUIManagerDelegate: class {
    func kalturaPlayerUIManagerDidRequestPlayWithoutMediaEntry(_ kalturaPlayerUIManager: KalturaPlayerUIManager)
}
