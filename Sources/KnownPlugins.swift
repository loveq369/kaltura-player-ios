//
//  KnownPlugins.swift
//  KalturaPlayer
//
//  Created by Nilit Danan on 5/26/20.
//

import Foundation
import PlayKit

class KnownPlugins {
    
    enum PKPlugins: CaseIterable {
        case Kava
        case PhoenixAnalytics
        case IMA
        case IMADAI
        
        private func className() -> String {
            switch self {
            case .Kava:
                return "PlayKitKava.KavaPlugin"
            case .PhoenixAnalytics:
                return "PlayKitProviders.PhoenixAnalyticsPlugin"
            case .IMA:
                return "PlayKit_IMA.IMAPlugin"
            case .IMADAI:
                return "PlayKit_IMA.IMADAIPlugin"
            }
        }
        
        func getClass() -> BasePlugin.Type? {
            return NSClassFromString(self.className()) as? BasePlugin.Type
        }
    }
    
    static func registerAllPlugins() {
        for plugin in PKPlugins.allCases {
            if let pluginClass = plugin.getClass() {
                PlayKitManager.shared.registerPlugin(pluginClass)
            }
        }
    }
}
