//
//  BStompClient.swift
//  Zillable
//
//  Created by Huy Bui on 4/28/16.
//  Copyright © 2016 Huy Bui. All rights reserved.
//

import UIKit
import SocketRocket

struct StompCommands {
    static let commandConnect = "CONNECT"
    static let commandSend = "SEND"
    static let commandSubscribe = "SUBSCRIBE"
    static let commandUnsubscribe = "UNSUBSCRIBE"
    static let commandBegin = "BEGIN"
    static let commandCommit = "COMMIT"
    static let commandAbort = "ABORT"
    static let commandAck = "ACK"
    static let commandNack = "NACK"
    static let commandDisconnect = "DISCONNECT"
    static let commandPing = "\n"
    
    static let controlChar = String(format: "%C", arguments: [0x00])
    
    static let ackClient = "client"
    static let ackAuto = "auto"
    static let ackClientIndividual = "client-individual"
    
    static let commandHeaderReceipt = "receipt"
    static let commandHeaderDestination = "destination"
    static let commandHeaderDestinationId = "id"
    static let commandHeaderContentLength = "content-length"
    static let commandHeaderContentType = "content-type"
    static let commandHeaderAck = "ack"
    static let commandHeaderTransaction = "transaction"
    static let commandHeaderMessageId = "message-id"
    static let commandHeaderSubscription = "subscription"
    static let commandHeaderDisconnected = "disconnected"
    static let commandHeaderHeartBeat = "heart-beat"
    static let commandHeaderAcceptVersion = "accept-version"
    
    static let responseHeaderSession = "session"
    static let responseHeaderReceiptId = "receipt-id"
    static let responseHeaderErrorMessage = "message"
    
    static let responseFrameConnected = "CONNECTED"
    static let responseFrameMessage = "MESSAGE"
    static let responseFrameReceipt = "RECEIPT"
    static let responseFrameError = "ERROR"
}

public enum StompAckMode {
    case AutoMode
    case ClientMode
    case ClientIndividual
}

public protocol BStompClientDelegate {
    
    func stompClient(client: BStompClient!, didReceiveMessageWithJSONBody jsonBody: AnyObject?, withHeader header:[String:String]?, withDestination destination: String)
    
    func stompClientDidDisconnect(client: BStompClient!)
    func stompClientWillDisconnect(client: BStompClient!, withError error: NSError)
    func stompClientDidConnect(client: BStompClient!)
    func serverDidSendReceipt(client: BStompClient!, withReceiptId receiptId: String)
    func serverDidSendError(client: BStompClient!, withErrorMessage description: String, detailedErrorMessage message: String?)
    func serverDidSendPing()
}

public class BStompClient: NSObject, SRWebSocketDelegate {
    static let sharedInstance = BStompClient()
    private override init() {}
    
    var socket: SRWebSocket?
    var sessionId: String?
    var delegate: BStompClientDelegate?
    var connectionHeaders: [String: String]?
    public var certificateCheckEnabled = true
    private var urlRequest: NSURLRequest?
    
    //zillable
    var subscriptions: [String: String] = [String: String]()
    var counter = 0
    var clientHeartBeat: String = "20000,0" // client does not want to receive heartbeats from the server
    var pinger: NSTimer?
    var ponger: NSTimer?
    var heartbeat: Bool = true
    var serverActivity: CFAbsoluteTime?
    
    public func sendJSONForDict(dict: AnyObject, toDestination destination: String) {
        do {
            let theJSONData = try NSJSONSerialization.dataWithJSONObject(dict, options: NSJSONWritingOptions())
            let theJSONText = String(data: theJSONData, encoding: NSUTF8StringEncoding)
            //print(theJSONText!)
            let header = [StompCommands.commandHeaderContentType:"application/json;charset=UTF-8"]
            sendMessage(theJSONText!, toDestination: destination, withHeaders: header, withReceipt: nil)
        } catch {
            print("error serializing JSON: \(error)")
        }
    }
    
    public func openSocketWithURLRequest(request: NSURLRequest, delegate: BStompClientDelegate) {
        self.delegate = delegate
        self.urlRequest = request
        
        openSocket()
    }
    
    public func openSocketWithURLRequest(request: NSURLRequest, delegate: BStompClientDelegate, connectionHeaders: [String: String]?) {
        self.connectionHeaders = connectionHeaders
        openSocketWithURLRequest(request, delegate: delegate)
    }
    
    private func openSocket() {
        if socket == nil || socket?.readyState == .CLOSED {
            if certificateCheckEnabled == true {
                self.socket = SRWebSocket(URLRequest: urlRequest)
            } else {
                self.socket = SRWebSocket(URLRequest: urlRequest, protocols: [], allowsUntrustedSSLCertificates: true)
            }
            
            socket!.delegate = self
            socket!.open()
        }
    }
    
    private func connect() {
        if socket?.readyState == .OPEN {
            // at the moment only anonymous logins
            self.sendFrame(StompCommands.commandConnect, header: connectionHeaders, body: nil)
        } else {
            self.openSocket()
        }
    }
    
    public func webSocket(webSocket: SRWebSocket!, didReceiveMessage message: AnyObject!) {
        serverActivity = CFAbsoluteTimeGetCurrent()
        print("didReceiveMessage")
        func processString(string: String) {
            var contents = string.componentsSeparatedByString("\n")
            if contents.first == "" {
                contents.removeFirst()
            }
            
            if let command = contents.first {
                var headers = [String: String]()
                var body = ""
                var hasHeaders  = false
                
                contents.removeFirst()
                for line in contents {
                    if hasHeaders == true {
                        body += line
                    } else {
                        if line == "" {
                            hasHeaders = true
                        } else {
                            let parts = line.componentsSeparatedByString(":")
                            if let key = parts.first {
                                headers[key] = parts.last
                            }
                        }
                    }
                }
                
                //remove garbage from body
                if body.hasSuffix("\0") {
                    body = body.stringByReplacingOccurrencesOfString("\0", withString: "")
                }
                
                receiveFrame(command, headers: headers, body: body)
            }
        }
        
        if let strData = message as? NSData {
            if let msg = String(data: strData, encoding: NSUTF8StringEncoding) {
                processString(msg)
            }
        } else if let str = message as? String {
            processString(str)
        }
    }
    
    public func webSocketDidOpen(webSocket: SRWebSocket!) {
        if (self.connectionHeaders![StompCommands.commandHeaderHeartBeat] == nil) {
            self.connectionHeaders![StompCommands.commandHeaderHeartBeat] = self.clientHeartBeat
        } else {
            self.clientHeartBeat = self.connectionHeaders![StompCommands.commandHeaderHeartBeat]!
        }
        print("webSocketDidOpen")
        connect()
    }
    
    public func webSocket(webSocket: SRWebSocket!, didFailWithError error: NSError!) {
        print("didFailWithError: \(error)")
        
        if let delegate = delegate {
            dispatch_async(dispatch_get_main_queue(),{
                delegate.serverDidSendError(self, withErrorMessage: error.domain, detailedErrorMessage: error.description)
            })
        }
    }
    
    public func webSocket(webSocket: SRWebSocket!, didCloseWithCode code: Int, reason: String!, wasClean: Bool) {
        print("didCloseWithCode \(code), reason: \(reason)")
        if let delegate = delegate {
            dispatch_async(dispatch_get_main_queue(),{
                delegate.stompClientDidDisconnect(self)
            })
        }
    }
    
    public func webSocket(webSocket: SRWebSocket!, didReceivePong pongPayload: NSData!) {
        serverActivity = CFAbsoluteTimeGetCurrent()
        //print("didReceivePong")
        print("<<< PONG")
    }
    
    private func sendFrame(command: String?, header: [String: String]?, body: AnyObject?) {
        if socket?.readyState == .OPEN {
            var frameString = ""
            if command != nil {
                frameString = command! + "\n"
            }
            
            if let header = header {
                for (key, value) in header {
                    frameString += key
                    frameString += ":"
                    frameString += value
                    frameString += "\n"
                }
            }
            
            if let body = body as? String {
                frameString += "\n"
                frameString += body
            } else if let _ = body as? NSData {
                //ak, 20151015: do we need to implemenet this?
            }
            
            if body == nil {
                frameString += "\n"
            }
            
            frameString += StompCommands.controlChar
            
            if socket?.readyState == .OPEN {
                socket?.send(frameString)
            } else {
                print("no socket connection")
                if let delegate = delegate {
                    dispatch_async(dispatch_get_main_queue(),{
                        delegate.stompClientDidDisconnect(self)
                    })
                }
            }
        }
    }
    
    private func destinationFromHeader(header: [String: String]) -> String {
        for (key, _) in header {
            if key == "destination" {
                let destination = header[key]!
                return destination
            }
        }
        return ""
    }
    
    private func dictForJSONString(jsonStr: String?) -> AnyObject? {
        if let jsonStr = jsonStr {
            do {
                if let data = jsonStr.dataUsingEncoding(NSUTF8StringEncoding) {
                    let json = try NSJSONSerialization.JSONObjectWithData(data, options: .AllowFragments)
                    return json
                }
            } catch {
                print("error serializing JSON: \(error)")
            }
        }
        return nil
    }
    
    private func receiveFrame(command: String, headers: [String: String], body: String?) {
        if command == StompCommands.responseFrameConnected {
            // Connected
            self.setupHeartBeatWithClient(self.clientHeartBeat, server: headers[StompCommands.commandHeaderHeartBeat]!)
            if let sessId = headers[StompCommands.responseHeaderSession] {
                sessionId = sessId
            }
            
            if let delegate = delegate {
                dispatch_async(dispatch_get_main_queue(),{
                    delegate.stompClientDidConnect(self)
                })
            }
        } else if command == StompCommands.responseFrameMessage {
            // Resonse
            
            if headers["content-type"]?.lowercaseString.rangeOfString("application/json") != nil {
                if let delegate = delegate {
                    dispatch_async(dispatch_get_main_queue(),{
                        delegate.stompClient(self, didReceiveMessageWithJSONBody: self.dictForJSONString(body), withHeader: headers, withDestination: self.destinationFromHeader(headers))
                    })
                }
            } else {
                // TODO: send binary data back
            }
        } else if command == StompCommands.responseFrameReceipt {
            // Receipt
            if let delegate = delegate {
                if let receiptId = headers[StompCommands.responseHeaderReceiptId] {
                    dispatch_async(dispatch_get_main_queue(),{
                        delegate.serverDidSendReceipt(self, withReceiptId: receiptId)
                    })
                }
            }
        } else if command.characters.count == 0 {
            // Pong from the server
            socket?.send(StompCommands.commandPing)
            
            if let delegate = delegate {
                dispatch_async(dispatch_get_main_queue(),{
                    delegate.serverDidSendPing()
                })
            }
        } else if command == StompCommands.responseFrameError {
            // Error
            if let delegate = delegate {
                if let msg = headers[StompCommands.responseHeaderErrorMessage] {
                    dispatch_async(dispatch_get_main_queue(),{
                        delegate.serverDidSendError(self, withErrorMessage: msg, detailedErrorMessage: body)
                    })
                }
            }
        }
    }
    
    public func sendMessage(message: String, toDestination destination: String, withHeaders headers: [String: String]?, withReceipt receipt: String?) {
        var headersToSend = [String: String]()
        if let headers = headers {
            headersToSend = headers
        }
        
        // Setting up the receipt.
        if let receipt = receipt {
            headersToSend[StompCommands.commandHeaderReceipt] = receipt
        }
        
        headersToSend[StompCommands.commandHeaderDestination] = destination
        
        // Setting up the content length.
        let contentLength = message.utf8.count
        headersToSend[StompCommands.commandHeaderContentLength] = "\(contentLength)"
        
        // Setting up content type as plain text.
        if headersToSend[StompCommands.commandHeaderContentType] == nil {
            headersToSend[StompCommands.commandHeaderContentType] = "text/plain"
        }
        
        sendFrame(StompCommands.commandSend, header: headersToSend, body: message)
    }
    
    public func subscribeToDestination(destination: String) {
        subscribeToDestination(destination, withAck: .AutoMode)
    }
    
    public func subscribeToDestination(destination: String, withAck ackMode: StompAckMode) {
        var ack = ""
        switch ackMode {
            case StompAckMode.ClientMode:
                ack = StompCommands.ackClient
                break
            case StompAckMode.ClientIndividual:
                ack = StompCommands.ackClientIndividual
                break
            default:
                ack = StompCommands.ackAuto
                break
        }
        self.counter += 1
        self.subscriptions[destination] = "sub-\(self.counter)"
        let headers = [StompCommands.commandHeaderDestination: destination, StompCommands.commandHeaderAck: ack, StompCommands.commandHeaderDestinationId: self.subscriptions[destination]!]
        
        self.sendFrame(StompCommands.commandSubscribe, header: headers, body: nil)
    }
    
    public func subscribeToDestination(destination: String, withHeader header: [String: String]) {
        var headerToSend = header
        headerToSend[StompCommands.commandHeaderDestination] = destination
        sendFrame(StompCommands.commandSubscribe, header: headerToSend, body: nil)
    }
    
    public func unsubscribeFromDestination(destination: String) {
        var headerToSend = [String: String]()
        guard let destinationId = self.subscriptions[destination] else {
            return
        }
        self.subscriptions.removeValueForKey(destination)
        headerToSend[StompCommands.commandHeaderDestinationId] = destinationId
        sendFrame(StompCommands.commandUnsubscribe, header: headerToSend, body: nil)
    }
    
    public func begin(transactionId: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderTransaction] = transactionId
        sendFrame(StompCommands.commandBegin, header: headerToSend, body: nil)
    }
    
    public func commit(transactionId: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderTransaction] = transactionId
        sendFrame(StompCommands.commandCommit, header: headerToSend, body: nil)
    }
    
    public func abort(transactionId: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderTransaction] = transactionId
        sendFrame(StompCommands.commandAbort, header: headerToSend, body: nil)
    }
    
    public func ack(messageId: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderMessageId] = messageId
        sendFrame(StompCommands.commandAck, header: headerToSend, body: nil)
    }
    
    public func ack(messageId: String, withSubscription subscription: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderMessageId] = messageId
        headerToSend[StompCommands.commandHeaderSubscription] = subscription
        sendFrame(StompCommands.commandAck, header: headerToSend, body: nil)
    }
    
    public func nack(messageId: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderMessageId] = messageId
        sendFrame(StompCommands.commandNack, header: headerToSend, body: nil)
    }
    
    public func nack(messageId: String, withSubscription subscription: String) {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandHeaderMessageId] = messageId
        headerToSend[StompCommands.commandHeaderSubscription] = subscription
        sendFrame(StompCommands.commandNack, header: headerToSend, body: nil)
    }
    
    public func disconnect() {
        var headerToSend = [String: String]()
        headerToSend[StompCommands.commandDisconnect] = String(Int(NSDate().timeIntervalSince1970))
        sendFrame(StompCommands.commandDisconnect, header: headerToSend, body: nil)
    }
    
    //heartbeat
    func sendPing(timer: NSTimer)  {
        if self.socket?.readyState != .OPEN {
            return
        }
        let buffer: [UInt8] = [0x0A]
        self.socket?.sendPing(NSData(bytes: buffer, length: 1))
        print(">>> PING");
    }
    
    func checkPong(timer: NSTimer)  {
        let userInfo = timer.userInfo as? Dictionary<String, AnyObject>
        let ttl = (userInfo!["ttl"]?.intValue)!
        
        let delta: CFAbsoluteTime = CFAbsoluteTimeGetCurrent() - serverActivity!
        
        if (delta > Double(ttl * 3)) {
            print("did not receive server activity for the last \(delta) seconds");
            //self.disconnect()
            //[self disconnect:errorHandler];
        }
    }
    
    private func setupHeartBeatWithClient(clientValues: String, server serverValues:String) {
        if (!heartbeat) {
            return
        }
        var cx: Int = 0
        var cy: Int = 0
        var sx: Int = 0
        var sy: Int = 0
        var scanner = NSScanner(string: clientValues)
        scanner.charactersToBeSkipped = NSCharacterSet(charactersInString: ", ")
        scanner.scanInteger(&cx)
        scanner.scanInteger(&cy)
        
        scanner = NSScanner(string: serverValues)
        scanner.charactersToBeSkipped = NSCharacterSet(charactersInString: ", ")
        scanner.scanInteger(&sx)
        scanner.scanInteger(&sy)
        
        let pingTTL:Double = ceil(Double(max(cx, sy)) / 1000.0)
        let pongTTL:Double = ceil(Double(max(sx, cy)) / 1000.0)
        
        print("send heart-beat every \(pingTTL) seconds")
        print("expect to receive heart-beats every \(pongTTL) seconds")
        dispatch_async(dispatch_get_main_queue(), {
                if (pingTTL > 0) {
                    self.pinger = NSTimer.scheduledTimerWithTimeInterval(pingTTL, target: self, selector: #selector(BStompClient.sendPing(_:)), userInfo: nil, repeats: true)
                }
                if (pongTTL > 0) {
                    self.ponger = NSTimer.scheduledTimerWithTimeInterval(pongTTL, target: self, selector: #selector(BStompClient.checkPong(_:)), userInfo: ["ttl": Int(pongTTL)], repeats: true)
                }
        })
    
    }

}
