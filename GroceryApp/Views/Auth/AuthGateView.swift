import SwiftUI
import Amplify
import AWSCognitoAuthPlugin

struct AuthGateView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var confirmationCode = ""
    @State private var isSignUp = false
    @State private var needsConfirmation = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            ScrollView {
                VStack(spacing: 32) {
                    // Logo and title
                    logoSection
                        .padding(.top, 80)

                    // Form content
                    if needsConfirmation {
                        confirmationView
                    } else {
                        authFormView
                    }

                    Spacer(minLength: 50)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "cart.fill")
                .font(.system(size: 70))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .neonGlow(color: DesignSystem.Colors.neonCyan)

            Text("NotOurGroceries")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text("Share your shopping list with family")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
        }
    }

    // MARK: - Auth Form View

    private var authFormView: some View {
        VStack(spacing: 24) {
            // Toggle between sign in / sign up
            Picker("Auth Mode", selection: $isSignUp) {
                Text("Sign In").tag(false)
                Text("Sign Up").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            // Form fields
            VStack(spacing: 16) {
                if isSignUp {
                    CustomTextField(
                        placeholder: "Display Name",
                        text: $displayName,
                        icon: "person.fill"
                    )
                }

                CustomTextField(
                    placeholder: "Email",
                    text: $email,
                    icon: "envelope.fill",
                    keyboardType: .emailAddress,
                    autocapitalization: .never
                )

                CustomTextField(
                    placeholder: "Password",
                    text: $password,
                    icon: "lock.fill",
                    isSecure: true
                )

                if isSignUp {
                    Text("Password: 8+ chars, uppercase, lowercase, number, symbol")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }

            // Submit button
            Button(action: isSignUp ? signUp : signIn) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: isSignUp ? "person.badge.plus" : "arrow.right.circle.fill")
                        Text(isSignUp ? "Create Account" : "Sign In")
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
        }
        .padding(24)
        .background(glassCard)
    }

    // MARK: - Confirmation View

    private var confirmationView: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 50))
                .foregroundColor(DesignSystem.Colors.neonCyan)

            Text("Check your email")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("We sent a confirmation code to\n\(email)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            CustomTextField(
                placeholder: "Confirmation Code",
                text: $confirmationCode,
                icon: "number",
                keyboardType: .numberPad
            )

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
            }

            Button(action: confirmSignUp) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Confirm")
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
                needsConfirmation = false
                confirmationCode = ""
                errorMessage = nil
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.neonCyan)
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

    private func signUp() {
        guard !email.isEmpty, !password.isEmpty, !displayName.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await amplifyService.signUp(email: email, password: password, displayName: displayName)
                needsConfirmation = true
            } catch {
                errorMessage = parseAuthError(error)
            }
            isLoading = false
        }
    }

    private func confirmSignUp() {
        guard !confirmationCode.isEmpty else {
            errorMessage = "Please enter the confirmation code"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await amplifyService.confirmSignUp(email: email, code: confirmationCode)
                // After confirmation, sign in
                try await amplifyService.signIn(email: email, password: password)
                needsConfirmation = false
            } catch {
                errorMessage = parseAuthError(error)
            }
            isLoading = false
        }
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter email and password"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await amplifyService.signIn(email: email, password: password)
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
                // Check for specific Cognito errors
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

#Preview {
    AuthGateView()
        .environmentObject(AmplifyService.shared)
}
