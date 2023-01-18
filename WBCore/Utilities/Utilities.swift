//
//  Utilities.swift
//  WebBLE
//
//  Created by Fouad on 29/12/2022.
//

import Foundation
import UserNotifications

class Utilities {
    static func pushLocalNotification(notificationMessage : String, notificationTitle : String?) {
        let content = UNMutableNotificationContent()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
        if let title = notificationTitle {
            content.title = title
        } else {
            content.title = appName
        }
        
        let uuid = appName + " " + Date().description
        content.sound = UNNotificationSound.default
        content.body = notificationMessage
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: uuid ,content: content, trigger: trigger)
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request) { (error) in
            }
        }
    }
}
