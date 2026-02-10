//
//  LocalVoltsAuthService.swift
//  Powston
//
//  Cognito authentication via REST for LocalVolts
//  POST to https://market.localvolts.com/Login
//

import Foundation

class LocalVoltsAuthService {

    static let shared = LocalVoltsAuthService()

    private let loginURL = URL(string: "https://market.localvolts.com/Login")!

    private init() {}

    // MARK: - Token Response

    struct TokenResponse: Codable {
        let jwtIdToken: String
        let jwtAccessToken: String
        let jwtRefreshToken: String
        let strSub: String          // Cognito UUID
        let strUsername: String
    }

    // MARK: - Login

    func login(username: String, password: String) async throws -> TokenResponse {
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "username": username,
            "password": password
        ]

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AuthError.invalidCredentials
        case 403:
            throw AuthError.accountLocked
        case 429:
            throw AuthError.rateLimited
        default:
            // Try to parse error message from response
            if let errorMessage = parseErrorMessage(from: data) {
                throw AuthError.serverError(message: errorMessage)
            }
            throw AuthError.unexpectedStatus(code: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            print("❌ LocalVolts auth decode failed: \(error)")
            throw AuthError.decodingFailed(underlying: error)
        }
    }

    // MARK: - Token Refresh

    func refreshToken(refreshToken: String) async throws -> TokenResponse {
        // LocalVolts may use a different endpoint for refresh
        // For now, throw notImplemented - implement when needed
        throw AuthError.refreshNotSupported
    }

    // MARK: - Helper

    private func parseErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Codable {
            let message: String?
            let error: String?
        }

        guard let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return nil
        }

        return errorResponse.message ?? errorResponse.error
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case invalidCredentials
        case accountLocked
        case rateLimited
        case invalidResponse
        case unexpectedStatus(code: Int)
        case serverError(message: String)
        case decodingFailed(underlying: Error)
        case refreshNotSupported

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Invalid username or password"
            case .accountLocked:
                return "Account is locked. Please contact LocalVolts support."
            case .rateLimited:
                return "Too many login attempts. Please wait and try again."
            case .invalidResponse:
                return "Invalid response from LocalVolts server"
            case .unexpectedStatus(let code):
                return "Unexpected server response (status: \(code))"
            case .serverError(let message):
                return "Server error: \(message)"
            case .decodingFailed:
                return "Failed to parse server response"
            case .refreshNotSupported:
                return "Token refresh not supported - please re-authenticate"
            }
        }
    }
}
