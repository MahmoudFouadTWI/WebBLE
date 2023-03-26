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
    
    func set(value: [String: String], key: String) {
        defaults.set(value, forKey: key)
    }
    func get(forKey key: String) -> [String: String] {
        defaults.object(forKey: key) as? [String: String] ?? [String: String]()
    }
}

struct CacheConstants {
    static let devicesKey = "devicesKey"
}

class CachingHandler {
    static let shared = CachingHandler()
    private init () {}
    
    func addDevice(device: WBDevice) {
        var savedDevices = Cache.shared.get(forKey: CacheConstants.devicesKey)
        savedDevices[device.deviceId.uuidString] = device.jsonify()
        Cache.shared.set(value: savedDevices, key: CacheConstants.devicesKey)
    }
    
    func removeDevice(device: WBDevice) {
        var savedDevices = Cache.shared.get(forKey: CacheConstants.devicesKey)
        savedDevices[device.deviceId.uuidString] = nil
        Cache.shared.set(value: savedDevices, key: CacheConstants.devicesKey)
    }
}
