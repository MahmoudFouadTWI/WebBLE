//
//  Cache.swift
//  WebBLE
//
//  Created by Fouad on 27/02/2023.
//

import Foundation


class Cache {
    static let shared = Cache()
    private let defaults = UserDefaults.standard
    private init () {}
    
    func add(value: [String: String], key: String) {
        defaults.set(value, forKey: key)
    }
    func get(forKey key: String) -> [String: String] {
        defaults.object(forKey: key) as? [String: String] ?? [String: String]()
    }
}

class CacheConstants {
    static let devicesKey = "devices"
}

class DevicesHandler {
    static let shared = DevicesHandler()
    private init () {}
    
    func adjustSavedDevices(device: WBDevice, adjustCase: AdjustCase) {
        var savedDevices = Cache.shared.get(forKey: CacheConstants.devicesKey)
        if adjustCase == .add {
            savedDevices[device.deviceId.uuidString] = device.jsonify()
        } else {
            savedDevices[device.deviceId.uuidString] = nil
        }
        Cache.shared.add(value: savedDevices, key: CacheConstants.devicesKey)
    }
}

enum AdjustCase {
    case add , remove
}
