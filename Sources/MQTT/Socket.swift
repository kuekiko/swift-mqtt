//
//  Socket.swift
//  swift-mqtt
//
//  Created by supertext on 2025/3/7.
//

import Foundation
import Network

protocol SocketDelegate:AnyObject{
    func socket(_ socket:Socket,didReceive error:Error)
    func socket(_ socket:Socket,didReceive packet:Packet)
}
final class Socket:@unchecked Sendable{
    private let queue = DispatchQueue(label: "mqtt.socket.queue")
    private let config:Config
    private var header:UInt8 = 0
    private var length:Int = 0
    private var multiply = 1
    private let endpoint:Endpoint
    @Safely private var conn:NWConnection?
    weak var delegate:SocketDelegate?
    
    // 新增：防止重复通知机制
    private struct ErrorNotification {
        let errorKey: String
        let time: Date
    }
    @Safely private var lastNotifiedError: ErrorNotification?
    private let errorDebounceInterval: TimeInterval = 1.0
    
    init(endpoint:Endpoint,config:Config){
        self.config = config
        self.endpoint = endpoint
    }
    deinit{
        stop()
    }
    func stop(){
        self.$conn.write { conn in
            conn?.cancel()
            conn = nil
        }
        // 重置错误状态
        self.$lastNotifiedError.write { $0 = nil }
    }
    func start(){
        if self.$conn.write({ conn in
            if let _ = conn?.queue{ return false }
            let params = endpoint.params(config: config)
            conn = NWConnection.init(to: params.0, using: params.1)
            conn?.stateUpdateHandler = {[weak self] state in
                self?.handle(state: state)
            }
            conn?.start(queue: queue)
            return true
        }){
            // 重置错误状态
            self.$lastNotifiedError.write { $0 = nil }
            
            if isws{
                readMessage()
            }else{
                readHeader()
            }
        }
    }
    func send(data:Data)->Promise<Void>{
        guard let conn else{ 
            let error = MQTTError.unconnected
            // 未初始化也是连接错误，通知 delegate
            notifyDelegateIfConnectionError(error)
            return Promise(error)
        }
        let promise = Promise<Void>()
        conn.send(content: data,contentContext: .mqtt(isws), completion: .contentProcessed({ [weak self] error in
            if let error{
                Logger.error("SOCKET SEND: \(data.count) bytes failed. error:\(error)")
                
                // 核心修复：检查是否是连接级错误，如果是则通知 delegate 触发重连
                self?.notifyDelegateIfConnectionError(error)
                
                promise.done(error)
            }else{
                promise.done(())
            }
        }))
        return promise
    }
    
    private func handle(state:NWConnection.State){
        switch state{
        case .cancelled:
            // This is the network telling us we're closed. We don't need to actually do anything here
            // 重置错误状态
            self.$lastNotifiedError.write { $0 = nil }
            break
        case .failed(let error):
            // The connection has failed for some reason.
            // 状态变化错误也通过防重复机制通知
            notifyDelegateIfConnectionError(error)
        case .ready:
            // Ok connection is ready. But we don't need to do anything at all.
            // 连接成功，重置错误状态
            self.$lastNotifiedError.write { $0 = nil }
            break
        case .preparing:
            // This just means connections are being actively established. We have no specific action here.
            break
        case .setup:
            //
            break
        case .waiting(let error):
            // Perhaps nothing will happen, but here we can safely treat this as an error and there is no harm in doing so.
            // waiting 状态错误也通过防重复机制
            notifyDelegateIfConnectionError(error)
        default:
            break
        }
    }
    
    // 新增：判断是否是连接级错误（需要触发重连的错误）
    private func isConnectionError(_ error: Error) -> Bool {
        // POSIXError 检查
        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ENOTCONN:      // Socket is not connected ← 核心问题！
                return true
            case .EPIPE:         // Broken pipe
                return true
            case .ECONNRESET:    // Connection reset by peer
                return true
            case .ETIMEDOUT:     // Connection timed out
                return true
            case .ENETDOWN:      // Network is down
                return true
            case .ENETUNREACH:   // Network is unreachable
                return true
            case .EHOSTDOWN:     // Host is down
                return true
            case .EHOSTUNREACH:  // No route to host
                return true
            case .ECONNABORTED:  // Connection abort
                return true
            case .ECONNREFUSED:  // Connection refused
                return true
            default:
                return false
            }
        }
        
        // NWError 检查
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return isConnectionError(POSIXError(code))
            default:
                return false
            }
        }
        
        // MQTTError 检查
        if case MQTTError.unconnected = error {
            return true
        }
        
        return false
    }
    
    // 新增：防重复通知 + 连接错误检测
    private func notifyDelegateIfConnectionError(_ error: Error) {
        // 1. 检查是否是连接级错误
        guard isConnectionError(error) else {
            // 不是连接错误，不通知 delegate（让上层通过 Promise 处理）
            return
        }
        
        // 2. 防重复通知检查
        let errorKey = "\(type(of: error)).\(error.localizedDescription)"
        let now = Date()
        
        let shouldNotify = self.$lastNotifiedError.write { lastError -> Bool in
            if let last = lastError {
                if last.errorKey == errorKey && now.timeIntervalSince(last.time) < errorDebounceInterval {
                    Logger.debug("SOCKET: Debouncing duplicate connection error")
                    return false
                }
            }
            // 更新最后通知的错误
            lastError = ErrorNotification(errorKey: errorKey, time: now)
            return true
        }
        
        // 3. 通知 delegate
        if shouldNotify {
            Logger.warning("SOCKET: Connection error detected, notifying delegate for reconnection")
            delegate?.socket(self, didReceive: error)
        }
    }
    
    private func readHeader(){
        self.reset()
        self.readData(1) {[weak self] result in
            if let self{
                self.header = result[0]
                self.readLength()
            }
        }
    }
    private func readLength(){
        self.readData(1) {[weak self] result in
            guard let self else{ return }
            let byte = result[0]
            self.length += Int(byte & 0x7f) * self.multiply
            if byte & 0x80 != 0{
                let result = self.multiply.multipliedReportingOverflow(by: 0x80)
                if result.overflow {
                    self.delegate?.socket(self, didReceive: MQTTError.decodeError(.varintOverflow))
                    return
                }
                self.multiply = result.partialValue
                return self.readLength()
            }
            if self.length > 0{
                return self.readPayload()
            }
            self.dispath(data: Data())
        }
    }
    
    private func readPayload(){
        self.readData(length) {[weak self] data in
            self?.dispath(data: data)
        }
    }
    private func dispath(data:Data){
        guard let type = PacketType(rawValue: header) ?? PacketType(rawValue: header & 0xF0) else {
            self.delegate?.socket(self, didReceive: MQTTError.decodeError(.unrecognisedPacketType))
            return
        }
        let incoming:IncomingPacket = .init(type: type, flags: self.header & 0xF, remainingData: .init(data: data))
        do {
            self.delegate?.socket(self, didReceive: try incoming.packet(with: self.config.version))
        } catch {
            self.delegate?.socket(self, didReceive: error)
        }
        self.readHeader()
    }
    private func readData(_ length:Int,finish:(@Sendable (Data)->Void)?){
        guard let conn else { return }
        conn.receive(minimumIncompleteLength: length, maximumLength: length, completion: {[weak self] content, contentContext, isComplete, error in
            guard let self else{
                return
            }
            if let error{
                self.delegate?.socket(self, didReceive: error)
                return
            }
            guard let data = content,data.count == length else{
                let code:MQTTError.Decode = isComplete ? .streamIsComplete : .unexpectedDataLength
                self.delegate?.socket(self, didReceive: MQTTError.decodeError(code))
                return
            }
            // if we get correct data,we dispatch it! even if the stream has already been completed.
            finish?(data)
        })
    }
    private func readMessage(){
        guard let conn else { return }
        conn.receiveMessage {[weak self] content, contentContext, isComplete, error in
            guard let self else{ return }
            if let error{
                self.delegate?.socket(self, didReceive: error)
                return
            }
            guard let data = content else{
                self.delegate?.socket(self, didReceive: MQTTError.decodeError(.unexpectedDataLength))
                return
            }
            do {
                var buffer = DataBuffer(data: data)
                let incoming = try IncomingPacket.read(from: &buffer)
                let message = try incoming.packet(with: self.config.version)
                self.delegate?.socket(self, didReceive: message)
            }catch{
                self.delegate?.socket(self, didReceive: error)
            }
            self.readMessage()
        }
    }
    private func reset(){
        header = 0
        length = 0
        multiply = 1
    }
    private var isws:Bool{
        switch endpoint.type{
        case.ws,.wss:
            return true
        default:
            return false
        }
    }
}

extension NWConnection.ContentContext{
    static func mqtt(_ isws:Bool)->NWConnection.ContentContext{
        if isws{
            return .wsMQTTContext
        }
        return .mqttContext
    }
    private static var mqttContext:NWConnection.ContentContext = {
        return .init(identifier: "swift-mqtt")
    }()
    private static var wsMQTTContext:NWConnection.ContentContext = {
        return .init(identifier: "swift-mqtt",metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
    }()
}
