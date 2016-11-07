//
//  NORBluetoothManager.swift
//  nRF Toolbox
//
//  Created by Mostafa Berg on 06/05/16.
//  Copyright © 2016 Nordic Semiconductor. All rights reserved.
//

import UIKit
import CoreBluetooth
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

fileprivate func > <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l > r
  default:
    return rhs < lhs
  }
}

protocol NORBluetoothManagerDelegate {
    func didConnectPeripheral(deviceName aName : String?)
    func didDisconnectPeripheral()
    func peripheralReady()
    func peripheralNotSupported()
}

class NORBluetoothManager: NSObject, CBPeripheralDelegate, CBCentralManagerDelegate {
    
    //MARK: - Delegate Properties
    var delegate : NORBluetoothManagerDelegate?
    var logger   : NORLogger?
    
    //MARK: - Class Properties
    var UARTServiceUUID             : CBUUID?
    var UARTRXCharacteristicUUID    : CBUUID?
    var UARTTXCharacteristicUUID    : CBUUID?
    
    var centralManager              : CBCentralManager?
    var bluetoothPeripheral         : CBPeripheral?
    var uartRXCharacteristic        : CBCharacteristic?
    var uartTXCharacteristic        : CBCharacteristic?
    
    fileprivate var connected = false

    //MARK: - Implementation
    required init(withManager aManager : CBCentralManager) {
        super.init()
        // ret: instancetype
        UARTServiceUUID          = CBUUID(string: NORServiceIdentifiers.uartServiceUUIDString)
        UARTTXCharacteristicUUID = CBUUID(string: NORServiceIdentifiers.uartTXCharacteristicUUIDString)
        UARTRXCharacteristicUUID = CBUUID(string: NORServiceIdentifiers.uartRXCharacteristicUUIDString)
        centralManager = aManager
        centralManager!.delegate = self
    }
    
    //MARK: - BluetoothManager API
    func connectPeripheral(peripheral aPeripheral : CBPeripheral) {
        bluetoothPeripheral = aPeripheral
        
        // we assign the bluetoothPeripheral property after we establish a connection, in the callback
        if let name = aPeripheral.name {
            log(withLevel: .verboseLogLevel, andMessage: "Connecting to: \(name)...")
        } else {
            log(withLevel: .verboseLogLevel, andMessage: "Connecting to device...")
        }
        log(withLevel: .debugLogLevel, andMessage: "centralManager.connect(peripheral, options:nil)")
        centralManager!.connect(aPeripheral, options: nil)
    }
    
    func cancelPeripheralConnection() {
        guard bluetoothPeripheral != nil else {
            log(withLevel: .warningLogLevel, andMessage: "Peripheral not set")
            return
        }
        if connected {
            log(withLevel: .verboseLogLevel, andMessage: "Disconnecting...")
        } else {
            log(withLevel: .verboseLogLevel, andMessage: "Cancelling connection...")
        }
        log(withLevel: .debugLogLevel, andMessage: "centralManager.cancelPeripheralConnection(peripheral)")
        centralManager!.cancelPeripheralConnection(bluetoothPeripheral!)
        
        // In case the previous connection attempt failed before establishing a connection
        if !connected {
            bluetoothPeripheral = nil
            delegate?.didDisconnectPeripheral()
        }
    }
    
    func isConnected() -> Bool {
        return connected
    }
    
    func send(text aText : String) {
        /*
         * This method sends the given test to the UART RX characteristic.
         * Depending on whether the characteristic has the Write Without Response or Write properties the behaviour is different.
         * In the latter case the Long Write may be used. To enable it you have to change the flag below.
         * Otherwise, in both cases, texts longer than 20 bytes (not characters) will be splitted into up-to 20-byte packets.
         */
        guard self.uartRXCharacteristic != nil else {
            log(withLevel: .warningLogLevel, andMessage: "UART RX Characteristic not found")
            return
        }
        
        // Check what kind of Write Type is supported. By default it will try Without Response.
        var type = CBCharacteristicWriteType.withoutResponse
        if (self.uartRXCharacteristic!.properties.rawValue & CBCharacteristicProperties.write.rawValue) > 0 {
            type = CBCharacteristicWriteType.withResponse
        }

        // In case of Write Without Response the text needs to be splited in up-to 20-bytes packets.
        // When Write Request (with response) is used, the Long Write may be used. It will be handled automatically by the iOS, but must be supported on the device side.
        // If your device does support Long Write, change the flag here.
        let longWriteSupported = false
        
        // The following code will split the text to packets
        let textData = aText.data(using: String.Encoding.utf8)!
        textData.withUnsafeBytes { (u8Ptr: UnsafePointer<CChar>) in
            var buffer = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(u8Ptr))
            var len = textData.count
            
            while(len != 0){
                var part : String
                if len > 20 && (type == CBCharacteristicWriteType.withoutResponse || longWriteSupported == false) {
                    // If the text contains national letters they may be 2-byte long. It may happen that only 19 bytes can be send so that non of them is splited into 2 packets.
                    var builder = NSMutableString(bytes: buffer, length: 20, encoding: String.Encoding.utf8.rawValue)
                    if builder != nil {
                        // A 20-byte string has been created successfully
                        buffer  = buffer + 20
                        len     = len - 20
                    } else {
                        // We have to create 19-byte string. Let's ignore some stranger UTF-8 characters that have more than 2 bytes...
                        builder = NSMutableString(bytes: buffer, length: 19, encoding: String.Encoding.utf8.rawValue)
                        buffer = buffer + 19
                        len    = len - 19
                    }
                    
                    part = String(describing: builder!)
                } else {
                    let builder = NSMutableString(bytes: buffer, length: len, encoding: String.Encoding.utf8.rawValue)
                    part = String(describing: builder!)
                    len = 0
                }
                self.send(text: part, withType: type)
            }
        }
    }
    
    /**
     * Sends the given text to the UART RX characteristic using the given write type.
     */
    func send(text aText : String, withType aType : CBCharacteristicWriteType) {
        guard self.uartRXCharacteristic != nil else {
            log(withLevel: .warningLogLevel, andMessage: "UART RX Characteristic not found")
            return
        }
        
        let typeAsString = aType == .withoutResponse ? ".withoutResponse" : ".withResponse"
        let data = aText.data(using: String.Encoding.utf8)!
        
        //do some logging
        log(withLevel: .verboseLogLevel, andMessage: "Writing to characteristic: \(uartRXCharacteristic!.uuid.uuidString)")
        log(withLevel: .debugLogLevel, andMessage: "peripheral.writeValue(0x\(data.hexString), for: \(uartRXCharacteristic!.uuid.uuidString), type: \(typeAsString))")
        self.bluetoothPeripheral!.writeValue(data, for: self.uartRXCharacteristic!, type: aType)
        // The transmitted data is not available after the method returns. We have to log the text here.
        // The callback peripheral:didWriteValueForCharacteristic:error: is called only when the Write Request type was used,
        // but even if, the data is not available there.
        log(withLevel: .appLogLevel, andMessage: "\"\(aText)\" sent")
    }

    
    //MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        var state : String
        switch(central.state){
        case .poweredOn:
            state = "Powered ON"
            break
        case .poweredOff:
            state = "Powered OFF"
            break
        case .resetting:
            state = "Resetting"
            break
        case .unauthorized:
            state = "Unautthorized"
            break
        case .unsupported:
            state = "Unsupported"
            break
        case .unknown:
            state = "Unknown"
            break
        }
        
        self.log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did update state to: \(state)")
    }
    
    //MARK: - Logger API

    func log(withLevel aLevel : NORLOGLevel, andMessage aMessage : String) {
        guard logger != nil else {
            return
        }
        logger?.log(level: aLevel,message: aMessage)
    }
    
    func logError(error anError : NSError) {
        guard logger != nil else {
            return
        }
        logger?.log(level: .errorLogLevel, message: "Error \(anError.code): \(anError.localizedDescription)")
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did connect peripheral")
        if let name = peripheral.name {
            self.log(withLevel: .infoLogLevel, andMessage: "Connected to: \(name)")
        } else {
            self.log(withLevel: .infoLogLevel, andMessage: "Connected to device")
        }
        
        connected = true
        bluetoothPeripheral = peripheral
        bluetoothPeripheral!.delegate = self
        delegate?.didConnectPeripheral(deviceName: peripheral.name!)
        log(withLevel: .verboseLogLevel, andMessage: "Discovering services...")
        log(withLevel: .debugLogLevel, andMessage: "peripheral.discoverServices([\(UARTServiceUUID!.uuidString))]")
        peripheral.discoverServices([UARTServiceUUID!])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard error == nil else {
            log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did disconnect peripheral")
            logError(error: error! as NSError)
            return
        }
        log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did disconnect peripheral successfully")
        log(withLevel: .infoLogLevel, andMessage: "Disconnected")
        
        connected = false
        delegate?.didDisconnectPeripheral()
        bluetoothPeripheral!.delegate = nil
        bluetoothPeripheral = nil
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard error == nil else {
            log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did fail to connect to peripheral")
            logError(error: error! as NSError)
            return
        }
        log(withLevel: .debugLogLevel, andMessage: "[Callback] Central Manager did fail to connect to peripheral without errors")
        
        connected = false
        delegate?.didDisconnectPeripheral()
        bluetoothPeripheral!.delegate = nil
        bluetoothPeripheral = nil
    }

    //MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Service discovery failed")
            logError(error: error! as NSError)
            //TODO: Disconnect?
            return
        }
        
        log(withLevel: .infoLogLevel, andMessage: "Services discovered")
        
        for aService: CBService in peripheral.services! {
            if aService.uuid.isEqual(UARTServiceUUID) {
                log(withLevel: .verboseLogLevel, andMessage: "Nordic UART Service found")
                log(withLevel: .verboseLogLevel, andMessage: "Discovering characteristics...")
                log(withLevel: .debugLogLevel, andMessage: "peripheral.discoverCharacteristics(nil, for: \(aService.uuid.uuidString))")
                bluetoothPeripheral!.discoverCharacteristics(nil, for: aService)
                return
            }
        }
        
        //No UART service discovered
        log(withLevel: .warningLogLevel, andMessage: "UART Service not found. Try to turn bluetooth Off and On again to clear the cache.")
        delegate?.peripheralNotSupported()
        cancelPeripheralConnection()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Characteristics discovery failed")
            logError(error: error! as NSError)
            return
        }
        log(withLevel: .infoLogLevel, andMessage: "Characteristics discovered")
        
        if service.uuid.isEqual(UARTServiceUUID) {
            for aCharacteristic : CBCharacteristic in service.characteristics! {
                if aCharacteristic.uuid.isEqual(UARTTXCharacteristicUUID) {
                    log(withLevel: .verboseLogLevel, andMessage: "TX Characteristic found")
                    uartTXCharacteristic = aCharacteristic
                } else if aCharacteristic.uuid.isEqual(UARTRXCharacteristicUUID) {
                    log(withLevel: .verboseLogLevel, andMessage: "RX Characteristic found")
                    uartRXCharacteristic = aCharacteristic
                }
            }
            //Enable notifications on TX Characteristic
            if (uartTXCharacteristic != nil && uartRXCharacteristic != nil) {
                log(withLevel: .verboseLogLevel, andMessage: "Enabling notifications for \(uartTXCharacteristic!.uuid.uuidString)")
                log(withLevel: .debugLogLevel, andMessage: "peripheral.setNotifyValue(true, for: \(uartTXCharacteristic!.uuid.uuidString))")
                bluetoothPeripheral!.setNotifyValue(true, for: uartTXCharacteristic!)
            } else {
                log(withLevel: .warningLogLevel, andMessage: "UART service does not have required characteristics. Try to turn Bluetooth OFF and ON again to clear cache.")
                delegate?.peripheralNotSupported()
                cancelPeripheralConnection()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Enabling notifications failed")
            logError(error: error! as NSError)
            return
        }
        
        if characteristic.isNotifying {
            log(withLevel: .infoLogLevel, andMessage: "Notifications enabled for characteristic: \(characteristic.uuid.uuidString)")
        } else {
            log(withLevel: .infoLogLevel, andMessage: "Notifications disabled for characteristic: \(characteristic.uuid.uuidString)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Writing value to characteristic has failed")
            logError(error: error! as NSError)
            return
        }
        log(withLevel: .infoLogLevel, andMessage: "Data written to characteristic: \(characteristic.uuid.uuidString)")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Writing value to descriptor has failed")
            logError(error: error! as NSError)
            return
        }
        log(withLevel: .infoLogLevel, andMessage: "Data written to descriptor: \(descriptor.uuid.uuidString)")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            log(withLevel: .warningLogLevel, andMessage: "Updating characteristic has failed")
            logError(error: error! as NSError)
            return
        }
        
        // try to print a friendly string of received bytes if they can be parsed as UTF8
        guard let bytesReceived = characteristic.value else {
            log(withLevel: .infoLogLevel, andMessage: "Notification received from: \(characteristic.uuid.uuidString), with empty value")
            log(withLevel: .appLogLevel, andMessage: "Empty packet received")
            return
        }
        bytesReceived.withUnsafeBytes { (utf8Bytes: UnsafePointer<CChar>) in
            var len = bytesReceived.count
            if utf8Bytes[len - 1] == 0 {
                len -= 1 // if the string is null terminated, don't pass null terminator into NSMutableString constructor
            }
            
            log(withLevel: .infoLogLevel, andMessage: "Notification received from: \(characteristic.uuid.uuidString), with value: 0x\(bytesReceived.hexString)")
            if let validUTF8String = NSMutableString(bytes: utf8Bytes, length: len, encoding: String.Encoding.utf8.rawValue) {
                log(withLevel: .appLogLevel, andMessage: "\"\(validUTF8String)\" received")
            } else {
                log(withLevel: .appLogLevel, andMessage: "\"\(bytesReceived.hexString)\" received")
            }
        }
        
    }
}
