//
//  NetworkDiagnosticService.swift
//  Powston
//
//  Local network diagnostics for controller and inverter reachability

import Foundation
import Network

// MARK: - Diagnostic Result
struct NetworkTestResult: Identifiable {
    let id = UUID()
    let target: String
    let testType: TestType
    let success: Bool
    let latencyMs: Int?
    let error: String?
    
    enum TestType: String {
        case controller = "Controller"
        case modbus = "Modbus"
        case portal = "Portal"
    }
    
    var displayString: String {
        if success {
            if let ms = latencyMs {
                return "\(testType.rawValue) ✓ (\(ms)ms)"
            }
            return "\(testType.rawValue) ✓"
        } else {
            return "\(testType.rawValue) ✗"
        }
    }
}

struct DiagnosticReport {
    let controllerResult: NetworkTestResult?
    let modbusResult: NetworkTestResult?
    let portalResult: NetworkTestResult?
    let timestamp: Date
    
    var isOnLocalNetwork: Bool {
        // If we got any response (success or connection refused), we're on the network
        // Only "timeout" or "no route" means not on local network
        return controllerResult?.success == true || 
               modbusResult?.success == true || 
               portalResult?.success == true
    }
    
    var summaryString: String {
        var parts: [String] = []
        if let c = controllerResult { parts.append(c.displayString) }
        if let m = modbusResult { parts.append(m.displayString) }
        if let p = portalResult, p.success { parts.append(p.displayString) } // Only show portal if successful
        
        if parts.isEmpty {
            return "No tests available"
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Network Diagnostic Service
class NetworkDiagnosticService {
    static let shared = NetworkDiagnosticService()
    
    private let timeout: TimeInterval = 5.0
    
    func runDiagnostics(
        controllerIP: String?,
        inverterIP: String?,
        modbusPort: Int = 502
    ) async -> DiagnosticReport {
        
        async let controllerTest = testController(ip: controllerIP)
        async let modbusTest = testModbus(ip: inverterIP, port: modbusPort)
        async let portalTest = testPortal(ip: inverterIP)
        
        let (controller, modbus, portal) = await (controllerTest, modbusTest, portalTest)
        
        return DiagnosticReport(
            controllerResult: controller,
            modbusResult: modbus,
            portalResult: portal,
            timestamp: Date()
        )
    }
    
    // MARK: - TCP Connect Test (Controller)
    private func testController(ip: String?) async -> NetworkTestResult? {
        guard let ip = ip, !ip.isEmpty else { return nil }
        
        // Try common ports - we just need any response
        // Port 80 or 443 are common even if they return "connection refused"
        let result = await tcpConnect(host: ip, port: 80)
        
        return NetworkTestResult(
            target: ip,
            testType: .controller,
            success: result.success,
            latencyMs: result.latencyMs,
            error: result.error
        )
    }
    
    // MARK: - Modbus Port Test
    private func testModbus(ip: String?, port: Int) async -> NetworkTestResult? {
        guard let ip = ip, !ip.isEmpty else { return nil }
        
        let result = await tcpConnect(host: ip, port: UInt16(port))
        
        return NetworkTestResult(
            target: "\(ip):\(port)",
            testType: .modbus,
            success: result.success,
            latencyMs: result.latencyMs,
            error: result.error
        )
    }
    
    // MARK: - HTTPS Portal Test (Optional)
    private func testPortal(ip: String?) async -> NetworkTestResult? {
        guard let ip = ip, !ip.isEmpty else { return nil }
        
        let urlString = "https://\(ip)/"
        guard let url = URL(string: urlString) else { return nil }
        
        let startTime = Date()
        
        // Create session that bypasses certificate validation
        let session = URLSession(configuration: .ephemeral, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "HEAD" // Just check if it responds, don't download body
        
        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            
            if let httpResponse = response as? HTTPURLResponse {
                // Any HTTP response means the portal is up
                return NetworkTestResult(
                    target: urlString,
                    testType: .portal,
                    success: (200...499).contains(httpResponse.statusCode),
                    latencyMs: latency,
                    error: nil
                )
            }
            
            return NetworkTestResult(
                target: urlString,
                testType: .portal,
                success: false,
                latencyMs: latency,
                error: "Invalid response"
            )
        } catch {
            // Connection refused, timeout, etc. - portal not available (not necessarily an error)
            return NetworkTestResult(
                target: urlString,
                testType: .portal,
                success: false,
                latencyMs: nil,
                error: error.localizedDescription
            )
        }
    }
    
    // MARK: - TCP Connect Helper
    private func tcpConnect(host: String, port: UInt16) async -> (success: Bool, latencyMs: Int?, error: String?) {
        await withCheckedContinuation { continuation in
            let startTime = Date()
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let connection = NWConnection(to: endpoint, using: .tcp)
            
            var hasResumed = false
            let lock = NSLock()
            
            func resume(success: Bool, error: String?) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                
                connection.cancel()
                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                continuation.resume(returning: (success, success ? latency : nil, error))
            }
            
            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(success: false, error: "Timeout")
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(success: true, error: nil)
                case .failed(let error):
                    resume(success: false, error: error.localizedDescription)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
}

// MARK: - Insecure URL Session Delegate (for self-signed certs)
private class InsecureURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Accept any certificate for local network diagnostics
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
