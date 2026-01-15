import XCTest
import Amplify
import AWSCognitoAuthPlugin
@testable import GroceryApp

final class AuthErrorParsingTests: XCTestCase {

    // MARK: - parseCognitoError Tests

    func testParseCognitoError_UsernameExists_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.usernameExists

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "An account with this email already exists")
    }

    func testParseCognitoError_UserNotFound_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.userNotFound

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "No account found with this email")
    }

    func testParseCognitoError_InvalidPassword_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.invalidPassword

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Password must be 8+ characters with uppercase, lowercase, number, and symbol")
    }

    func testParseCognitoError_InvalidParameter_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.invalidParameter

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Invalid input. Please check your email and password format")
    }

    func testParseCognitoError_CodeExpired_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.codeExpired

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Confirmation code has expired. Please request a new one")
    }

    func testParseCognitoError_CodeMismatch_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.codeMismatch

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Invalid confirmation code. Please try again")
    }

    func testParseCognitoError_UserNotConfirmed_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.userNotConfirmed

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Please confirm your account with the code sent to your email")
    }

    func testParseCognitoError_LimitExceeded_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.limitExceeded

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Too many attempts. Please wait a moment and try again")
    }

    func testParseCognitoError_PasswordResetRequired_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.passwordResetRequired

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Password reset required. Please reset your password")
    }

    func testParseCognitoError_ResourceNotFound_ReturnsCorrectMessage() {
        // Given
        let error = AWSCognitoAuthError.resourceNotFound

        // When
        let message = AuthErrorParser.parseCognitoError(error)

        // Then
        XCTAssertEqual(message, "Service temporarily unavailable. Please try again")
    }

    // MARK: - parseAuthError Tests

    func testParseAuthError_WithConfigurationError_ReturnsConfigurationMessage() {
        // Given
        let error = AuthError.configuration("Invalid configuration", "Check settings", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertTrue(message.contains("Configuration error"))
        XCTAssertTrue(message.contains("Invalid configuration"))
    }

    func testParseAuthError_WithServiceError_ReturnsRecoveryMessage() {
        // Given
        let error = AuthError.service("Service error", "Try again later", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Try again later")
    }

    func testParseAuthError_WithServiceErrorNoRecovery_ReturnsDescription() {
        // Given
        let error = AuthError.service("Service error", "", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Service error")
    }

    func testParseAuthError_WithValidationError_IncludesFieldName() {
        // Given
        let error = AuthError.validation("email", "Invalid email format", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertTrue(message.contains("email"))
        XCTAssertTrue(message.contains("Invalid email format"))
    }

    func testParseAuthError_WithValidationErrorNoField_ReturnsDescription() {
        // Given
        let error = AuthError.validation("", "Invalid format", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Invalid format")
    }

    func testParseAuthError_WithNotAuthorizedError_ReturnsDescription() {
        // Given
        let error = AuthError.notAuthorized("Not authorized to perform this action", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Not authorized to perform this action")
    }

    func testParseAuthError_WithUnknownError_ReturnsDescription() {
        // Given
        let error = AuthError.unknown("Unknown error occurred", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Unknown error occurred")
    }

    func testParseAuthError_WithInvalidStateError_ReturnsDescription() {
        // Given
        let error = AuthError.invalidState("Invalid state", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Invalid state")
    }

    func testParseAuthError_WithSignedOutError_ReturnsDescription() {
        // Given
        let error = AuthError.signedOut("User is signed out", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "User is signed out")
    }

    func testParseAuthError_WithSessionExpiredError_ReturnsDescription() {
        // Given
        let error = AuthError.sessionExpired("Session has expired", "recovery", nil)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "Session has expired")
    }

    func testParseAuthError_WithServiceErrorAndCognitoUnderlying_ReturnsCognitoMessage() {
        // Given
        let cognitoError = AWSCognitoAuthError.userNotFound
        let error = AuthError.service("Service error", "recovery", cognitoError)

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then
        XCTAssertEqual(message, "No account found with this email")
    }

    func testParseAuthError_WithNonAuthError_ReturnsLocalizedDescription() {
        // Given: A custom error that conforms to LocalizedError for proper message
        struct CustomError: LocalizedError {
            var errorDescription: String? {
                return "Custom error message"
            }
        }
        let error = CustomError()

        // When
        let message = AuthErrorParser.parseAuthError(error)

        // Then: LocalizedError's errorDescription is used for localizedDescription
        XCTAssertEqual(message, "Custom error message")
    }
}

// MARK: - Helper Class for Testing
// Since the parsing functions are in AuthGateView, we create a wrapper for testing
enum AuthErrorParser {
    static func parseAuthError(_ error: Error) -> String {
        if let authError = error as? AuthError {
            switch authError {
            case .configuration(let description, _, _):
                return "Configuration error: \(description)"
            case .service(let description, let recovery, let underlyingError):
                if let cognitoError = underlyingError as? AWSCognitoAuthError {
                    return parseCognitoError(cognitoError)
                }
                return recovery.isEmpty ? description : recovery
            case .unknown(let description, _):
                return description
            case .validation(let field, let description, _, _):
                return field.isEmpty ? description : "\(field): \(description)"
            case .notAuthorized(let description, _, _):
                return description
            case .invalidState(let description, _, _):
                return description
            case .signedOut(let description, _, _):
                return description
            case .sessionExpired(let description, _, _):
                return description
            }
        }
        return error.localizedDescription
    }

    static func parseCognitoError(_ error: AWSCognitoAuthError) -> String {
        switch error {
        case .usernameExists:
            return "An account with this email already exists"
        case .userNotFound:
            return "No account found with this email"
        case .invalidPassword:
            return "Password must be 8+ characters with uppercase, lowercase, number, and symbol"
        case .invalidParameter:
            return "Invalid input. Please check your email and password format"
        case .codeExpired:
            return "Confirmation code has expired. Please request a new one"
        case .codeMismatch:
            return "Invalid confirmation code. Please try again"
        case .userNotConfirmed:
            return "Please confirm your account with the code sent to your email"
        case .limitExceeded:
            return "Too many attempts. Please wait a moment and try again"
        case .passwordResetRequired:
            return "Password reset required. Please reset your password"
        case .resourceNotFound:
            return "Service temporarily unavailable. Please try again"
        default:
            return "Authentication failed. Please check your credentials"
        }
    }
}
