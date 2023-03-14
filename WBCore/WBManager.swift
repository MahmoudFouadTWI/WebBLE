//
//  WebBluetooth.swift
//  BasicBrowser
//
//  Copyright 2016-2017 Paul Theriault and David Park. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import Foundation
import CoreBluetooth
import WebKit

open class WBManager: NSObject {

    // MARK: - Embedded types
    enum ManagerRequests: String {
        case device, requestDevice, getDevices
    }

    // MARK: - Properties

    private let debug = true
    var centralManager = CBCentralManager(delegate: nil, queue: nil)

    /*! @abstract The devices selected by the user for use by this manager. Keyed by the UUID provided by the system. */
    private var devicesByInternalUUID = [UUID: WBDevice]()

    /*! @abstract The devices selected by the user for use by this manager. Keyed by the UUID we create and pass to the web page. This seems to be for security purposes, and seems sensible. */
    private var devicesByExternalUUID = [UUID: WBDevice]()

    /*! @abstract The outstanding request for a device from the web page, if one is outstanding. Ony one may be outstanding at any one time and should be policed by a modal dialog box. TODO: how modal is the current solution?
     */
    private var requestDeviceTransaction: WBTransaction? = nil
    private var getDevicesTransaction: WBTransaction? = nil

    /*! @abstract Filters in use on the current device request transaction.  If nil, that means we are accepting all devices.
     */
    private var filters: [[String: AnyObject]]? = nil
    private var foundedDevices = [WBDevice]()
    private var scanTimer: Timer?

    // MARK: - Constructors / destructors
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "my-central"])
    }
    
    func clearState() {
        NSLog("WBManager clearState()")
        self.stopScanForPeripherals()
        self.requestDeviceTransaction?.abandon()
        self.requestDeviceTransaction = nil
        // the external and internal devices are the same, but tidier to do this in one loop; calling clearState on a device twice is OK.
        for var devMap in [self.devicesByExternalUUID, self.devicesByInternalUUID] {
            for (_, device) in devMap {
                device.clearState()
            }
            devMap.removeAll()
        }
        self._clearFoundedDevices()
    }
}

// MARK: - WKScriptMessageHandler
extension WBManager: WKScriptMessageHandler {
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {

        guard let trans = WBTransaction(withMessage: message) else {
            /* The transaction will have handled the error */
            return
        }
        self.triage(transaction: trans)
    }
}

// MARK: - CBCentralManagerDelegate
extension WBManager: CBCentralManagerDelegate {
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("Bluetooth is \(central.state == CBManagerState.poweredOn ? "ON" : "OFF")")
        print("devices = \(self.devicesByInternalUUID.values.count)")
        for device in self.devicesByInternalUUID.values {
            device.didDisconnect(error: nil)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {

        if let filters = self.filters,
            !self._peripheral(peripheral, isIncludedBy: filters) {
            return
        }

        guard self.foundedDevices.first(where: {$0.peripheral == peripheral}) == nil else {
            return
        }

        NSLog("New peripheral \(peripheral.name ?? "<no name>") discovered")
        let device = WBDevice(
            peripheral: peripheral, advertisementData: advertisementData,
            RSSI: RSSI, manager: self)
        if !self.foundedDevices.contains(where: {$0 == device}) {
            self.didFoundDevice(device)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard
            let device = self.devicesByInternalUUID[peripheral.identifier]
        else {
            NSLog("Unexpected didConnect notification for \(peripheral.name ?? "<no-name>") \(peripheral.identifier)")
            return
        }
        device.didConnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard
            let device = self.devicesByInternalUUID[peripheral.identifier]
            else {
                NSLog("Unexpected didDisconnect notification for unknown device \(peripheral.name ?? "<no-name>") \(peripheral.identifier)")
                return
        }
        device.didDisconnect(error: error)
        self.devicesByInternalUUID[peripheral.identifier] = nil
        self.devicesByExternalUUID[device.deviceId] = nil
        
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("FAILED TO CONNECT PERIPHERAL UNHANDLED \(error?.localizedDescription ?? "<no error>")")
    }
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {}
}


private extension WBManager {

    private func triage(transaction: WBTransaction){

        guard
            transaction.key.typeComponents.count > 0,
            let managerMessageType = ManagerRequests(
                rawValue: transaction.key.typeComponents[0])
        else {
            transaction.resolveAsFailure(withMessage: "Request type components not recognised \(transaction.key)")
            return
        }

        switch managerMessageType
        {
        case .device:

            guard let view = WBDevice.DeviceTransactionView(transaction: transaction) else {
                transaction.resolveAsFailure(withMessage: "Bad device request")
                break
            }
            guard self.centralManager.state == .poweredOn else {
                transaction.resolveAsFailure(withMessage: centralManager.state == .poweredOff ? Status.StatusBluetoothOff.rawValue : Status.StatusBluetoothUnauthorized.rawValue)
                return
            }
            let devUUID = view.externalDeviceUUID
            // get device from external Dictionary in case connect after scan.
            var device = self.devicesByExternalUUID[devUUID]
            if device == nil {
                //get device in reconnection cases.
                if let uuidstr = transaction.messageData["peripheralId"] as? String,
                   let uuid = UUID(uuidString: uuidstr),
                   let peripheral = self.centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
                    let wbDevice = WBDevice(peripheral: peripheral,deviceId: devUUID, manager: self)
                    wbDevice.view = transaction.webView
                    self.devicesByExternalUUID[devUUID] = wbDevice
                    self.devicesByInternalUUID[peripheral.identifier] = wbDevice
                    device = wbDevice
                }
            }
            if device == nil {
                    transaction.resolveAsFailure(withMessage: "No known device for device transaction \(transaction)")
                    break
            }
            device!.triage(view)
        case .requestDevice:
            guard transaction.key.typeComponents.count == 1
            else {
                transaction.resolveAsFailure(withMessage: "Invalid request type \(transaction.key)")
                break
            }
            let acceptAllDevices = transaction.messageData["acceptAllDevices"] as? Bool ?? false

            let filters = transaction.messageData["filters"] as? [[String: AnyObject]]
            let timeout = transaction.messageData["timeout"] as? Int ?? 10

            // PROTECT force unwrap see below
            guard acceptAllDevices || filters != nil
            else {
                transaction.resolveAsFailure(withMessage: "acceptAllDevices false but no filters passed: \(transaction.messageData)")
                break
            }
            guard self.requestDeviceTransaction == nil
            else {
                transaction.resolveAsFailure(withMessage: "Previous device request is still in progress")
                break
            }
            
            guard canStartScan == .StatusBluetoothOn else {
                transaction.resolveAsFailure(withMessage: canStartScan.rawValue)
                break
            }

            if self.debug {
                NSLog("Requesting device with filters \(filters?.description ?? "nil")")
            }

            self.requestDeviceTransaction = transaction
            if acceptAllDevices {
                self.scanForAllPeripherals()
            } else {
                // force unwrap, but protected by guard above marked PROTECT
                self.scanForPeripherals(with: filters!)
            }
            self.setupScanTimer(timeout: timeout)
            transaction.addCompletionHandler {_, _ in
                self.stopScanForPeripherals()
                self.requestDeviceTransaction = nil
            }
            
        case .getDevices:
            guard transaction.key.typeComponents.count == 1
            else {
                transaction.resolveAsFailure(withMessage: "Invalid request type \(transaction.key)")
                break
            }
            guard self.requestDeviceTransaction == nil
            else {
                transaction.resolveAsFailure(withMessage: "Previous get devices request is still in progress")
                break
            }
            
            self.getDevicesTransaction = transaction
            var devices = [String]()
            for value in Cache.shared.get(forKey: CacheConstants.devicesKey).values {
                devices.append(value)
            }
            self.getDevicesTransaction?.resolveAsSuccess(withObjects: devices)
            transaction.addCompletionHandler {_, _ in
                self.getDevicesTransaction = nil
            }
        }
    }
    private func scanForAllPeripherals() {
        self._clearFoundedDevices()
        self.filters = nil
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    private func scanForPeripherals(with filters:[[String: AnyObject]]) {
        let services = filters.reduce([String](), {
            (currReduction, nextValue) in
            if let nextServices = nextValue["services"] as? [String] {
                return currReduction + nextServices
            }
            return currReduction
        })
        
        let servicesCBUUID = self._convertServicesListToCBUUID(services)
        
        if (self.debug) {
            NSLog("Scanning for peripherals... (services: \(servicesCBUUID))")
        }
        
        self._clearFoundedDevices();
        self.filters = filters
        centralManager.scanForPeripherals(withServices: servicesCBUUID, options: nil)
    }
    private func stopScanForPeripherals() {
        if self.centralManager.state == .poweredOn {
            self.centralManager.stopScan()
        }
        self._clearFoundedDevices()
    }

    private func _convertServicesListToCBUUID(_ services: [String]) -> [CBUUID] {
        return services.map {
            servStr -> CBUUID? in
            guard let uuid = UUID(uuidString: servStr.uppercased()) else {
                return nil
            }
            return CBUUID(nsuuid: uuid)
            }.filter{$0 != nil}.map{$0!};
    }

    private func _peripheral(_ peripheral: CBPeripheral, isIncludedBy filters: [[String: AnyObject]]) -> Bool {
        for filter in filters {

            if let name = filter["name"] as? String {
                guard peripheral.name == name else {
                    continue
                }
            }
            if let namePrefix = filter["namePrefix"] as? String {
                guard
                    let pname = peripheral.name,
                    pname.hasPrefix(namePrefix)
                else {
                    continue
                }
            }
            // All the checks passed, don't need to check another filter.
            return true
        }
        return false
    }
}


extension WBManager {
    
    private func deviceWasSelected(_ device: WBDevice) {
        self.devicesByExternalUUID[device.deviceId] = device;
        self.devicesByInternalUUID[device.internalUUID] = device;
    }
    
    private func _clearFoundedDevices() {
        self.foundedDevices = []
    }
    private func didFoundDevice(_ device: WBDevice) {
        device.view = requestDeviceTransaction?.webView
        foundedDevices.append(device)
    }
    
    private var canStartScan: Status {
        var state: Status = .StatusBluetoothOn
        if self.centralManager.isScanning {
            state = .StatusAlreadyScanning
        }
        if self.centralManager.state != .poweredOn {
            if self.centralManager.state == .unauthorized {
                state = .StatusBluetoothUnauthorized
            } else {
                state = .StatusBluetoothOff
            }
        }
        return state
    }
    
    private func setupScanTimer(timeout: Int) {
        guard timeout > 0 else {return}
        scanTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self , selector: #selector(self.timerIsFired), userInfo: nil, repeats: false)
    }
    
    @objc private func timerIsFired(){
        clearScanTimer()
        handleFoundedDevices()
    }
    
    private func clearScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }
    
    private func handleFoundedDevices() {
        guard let device = sortDevices().first else {
            self.requestDeviceTransaction?.resolveAsFailure(withMessage: Status.StatusNoDevices.rawValue)
            return
        }
        deviceWasSelected(device)
        requestDeviceTransaction?.resolveAsSuccess(withObject: device)
    }
    
    
    private func sortDevices() -> [WBDevice] {
        var sortedDevices = foundedDevices
        if (foundedDevices.count > 1){
            sortedDevices = foundedDevices.sorted {
                return (Int($0.adData.rssi) ?? 0) > (Int($1.adData.rssi) ?? 0)
            }
        }
        return sortedDevices
    }
}
