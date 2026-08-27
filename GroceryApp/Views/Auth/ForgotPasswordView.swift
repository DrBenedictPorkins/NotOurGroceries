import SwiftUI
import Amplify
import AWSCognitoAuthPlugin

struct ForgotPasswordView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @State private var email = ""
    @State private var confirmationCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isCodeSent = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            ScrollView {
                VStack(spacing: 32) {
                    headerSection
                        .padding(.top, 80)

                    if isCodeSent {
                        confirmResetView
                    } else {
                        requestCodeView
                    }

                    Spacer(minLength: 50)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .neonGlow(color: DesignSystem.Colors.neonCyan)

            Text("Reset Password")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text(isCodeSent ? "Enter the code sent to your email" : "Enter your email to receive a reset code")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Request Code View

    private var requestCodeView: some View {
        VStack(spacing: 24) {
            CustomTextField(
                placeholder: "Email",
                text: $email,
                icon: "envelope.fill",
                keyboardType: .emailAddress,
                autocapitalization: .never,
                contentType: .username
            )

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }

            if let success = successMessage {
                Text(success)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.success)
                    .multilineTextAlignment(.center)
            }

            Button(action: requestResetCode) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "envelope.badge.fill")
                        Text("Send Reset Code")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.accentGradient)
                )
            }
            .disabled(isLoading)

            Button("Back to Sign In") {
                onDismiss()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.neonCyan)
        }
        .padding(24)
        .background(glassCard)
    }

    // MARK: - Confirm Reset View

    private var confirmResetView: some View {
        VStack(spacing: 24) {
            CustomTextField(
                placeholder: "Confirmation Code",
                text: $confirmationCode,
                icon: "number",
                keyboardType: .numberPad,
                contentType: .oneTimeCode
            )

            CustomTextField(
                placeholder: "New Password",
                text: $newPassword,
                icon: "lock.fill",
                isSecure: true,
                contentType: .newPassword
            )

            CustomTextField(
                placeholder: "Confirm Password",
                text: $confirmPassword,
                icon: "lock.fill",
                isSecure: true,
                contentType: .newPassword
            )

            Text("At least 6 characters")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }

            if let success = successMessage {
                Text(success)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.success)
                    .multilineTextAlignment(.center)
            }

            Button(action: confirmReset) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Reset Password")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.accentGradient)
                )
            }
            .disabled(isLoading)

            HStack(spacing: 16) {
                Button("Resend Code") {
                    requestResetCode()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.neonCyan)
                .disabled(isLoading)

                Text("|")
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                Button("Back to Sign In") {
                    onDismiss()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.neonCyan)
            }
        }
        .padding(24)
        .background(glassCard)
    }

    // MARK: - Glass Card

    private var glassCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func requestResetCode() {
        guard !email.isEmpty else {
            errorMessage = "Please enter your email address"
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await amplifyService.resetPassword(for: email)
                isCodeSent = true
                successMessage = "Reset code sent to \(email)"
            } catch {
                errorMessage = parseAuthError(error)
            }
            isLoading = false
        }
    }

    private func confirmReset() {
        guard !confirmationCode.isEmpty else {
            errorMessage = "Please enter the confirmation code"
            return
        }

        guard !newPassword.isEmpty else {
            errorMessage = "Please enter a new password"
            return
        }

        guard newPassword == confirmPassword else {
            errorMessage = "Passwords do not match"
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await amplifyService.confirmResetPassword(
                    for: email,
                    with: newPassword,
                    confirmationCode: confirmationCode
                )

                // We're holding a valid email and the password we just set, so
                // making the user type both again is pure friction. Sign them in.
                do {
                    try await amplifyService.signIn(email: email, password: newPassword)
                    successMessage = "Password reset. Signing you in..."
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onDismiss()
                } catch {
                    // Reset worked even if auto sign-in didn't — say so, and let
                    // them in the normal way rather than implying the reset failed.
                    successMessage = "Password reset. Please sign in."
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onDismiss()
                }
            } catch {
                errorMessage = parseAuthError(error)
            }
            isLoading = false
        }
    }

    // MARK: - Error Parsing

    private func parseAuthError(_ error: Error) -> String {
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

    private func parseCognitoError(_ error: AWSCognitoAuthError) -> String {
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
            return "Reset code has expired. Please request a new one"
        case .codeMismatch:
            return "Invalid reset code. Please try again"
        case .userNotConfirmed:
            return "Please confirm your account with the code sent to your email"
        case .limitExceeded:
            return "Too many attempts. Please wait a moment and try again"
        case .passwordResetRequired:
            return "Password reset required. Please reset your password"
        case .resourceNotFound:
            return "Service temporarily unavailable. Please try again"
        default:
            return "Password reset failed. Please try again"
        }
    }
}

#Preview {
    ForgotPasswordView(onDismiss: {})
        .environmentObject(AmplifyService.shared)
}
