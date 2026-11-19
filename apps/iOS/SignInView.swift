import SwiftUI

/// Sign-in and registration. Local features never need an account, so the screen says how to keep using iTalk without one.
/// Only the contract's real calls exist here (`signIn`, `signUp`); anything else is described as not yet open. No success is ever simulated.
struct SignInSheet: View {
    private enum Field { case email, password }
    @Environment(AccountCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var registering = false
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var working = false
    @State private var error: String?
    @State private var recoveryNote = false
    @FocusState private var focus: Field?

    private var unavailable: Bool { center.availability == .notDeployed }
    private var emailValid: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }
    private var passwordLongEnough: Bool { password.count >= 8 }
    private var canSubmit: Bool { !unavailable && !working && emailValid && passwordLongEnough }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header.padding(.top, 36)
                if unavailable { notice("账户服务暂未开通，现在无法登录或注册。", icon: "info.circle").padding(.top, 20) }
                form.padding(.top, 28)
                if let error { notice(error, icon: "exclamationmark.triangle", tint: .orange).padding(.top, 14) }
                primaryButton.padding(.top, 20)
                secondaryActions.padding(.top, 14)
                Spacer(minLength: 28)
                footer
            }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxWidth: 460).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { backdrop.ignoresSafeArea() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).tint(.primary)
                .padding(.top, 14).padding(.trailing, 16).accessibilityLabel("关闭")
        }
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
        .alert("找回密码", isPresented: $recoveryNote) {
            Button("好", role: .cancel) {}
        } message: { Text("密码找回会随账户服务一起开放。在此之前，本机功能无需账户，也不受影响。") }
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
            LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 360)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            BrandAvatar(size: 76)
            HStack(spacing: 0) {
                Text("i").foregroundStyle(.tint); Text("Talk").foregroundStyle(.primary)
            }.font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-0.5)
            VStack(spacing: 6) {
                Text(registering ? "创建你的账户" : "欢迎回来").font(.title3.weight(.semibold)).contentTransition(.opacity)
                Text("登录后可使用云端模型和订阅，并在不同设备间保持一致。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity)
    }

    private var form: some View {
        VStack(spacing: 12) {
            field(icon: "envelope", valid: email.isEmpty || emailValid) {
                TextField("邮箱", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .email).submitLabel(.next).onSubmit { focus = .password }
                    .accessibilityIdentifier("signin.email")
            }
            field(icon: "lock", valid: password.isEmpty || passwordLongEnough || !registering) {
                HStack {
                    Group {
                        if showsPassword { TextField("密码", text: $password) } else { SecureField("密码", text: $password) }
                    }.textContentType(registering ? .newPassword : .password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .password).submitLabel(.go).onSubmit { if canSubmit { Task { await submit() } } }
                        .accessibilityIdentifier("signin.password")
                    Button { showsPassword.toggle() } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye").foregroundStyle(.secondary).frame(width: 30, height: 30)
                    }.buttonStyle(.plain).accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                }
            }
            if registering {
                HStack(spacing: 6) {
                    Image(systemName: passwordLongEnough ? "checkmark.circle.fill" : "circle").foregroundStyle(passwordLongEnough ? Color.green : .secondary)
                    Text("至少 8 位").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 4).transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: registering)
    }

    private func field<Content: View>(icon: String, valid: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
            content()
        }
        .padding(.horizontal, 16).frame(minHeight: 54)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(valid ? Color.clear : Color.orange.opacity(0.7), lineWidth: 1) }
    }

    private var primaryButton: some View {
        Button { Task { await submit() } } label: {
            ZStack {
                if working { ProgressView().tint(.white) } else { Text(registering ? "注册" : "登录").font(.headline) }
            }.frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.glassProminent).controlSize(.large).disabled(!canSubmit)
        .accessibilityIdentifier("signin.submit")
    }

    private var secondaryActions: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { registering.toggle(); error = nil }
            } label: {
                Text(registering ? "已有账户？登录" : "还没有账户？注册").font(.subheadline.weight(.medium))
            }.accessibilityIdentifier("signin.toggle")
            if !registering {
                Button("忘记密码？") { recoveryNote = true }.font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("signin.recover")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button("暂不登录，继续使用本机功能") { dismiss() }.font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("signin.skip")
            Text("本机模型、对话和记忆保存在这台设备上，无需账户，始终免费。")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private func notice(_ text: String, icon: String, tint: Color = .secondary) -> some View {
        Label { Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
            .foregroundStyle(tint).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func submit() async {
        focus = nil; working = true; error = nil
        do {
            if registering { try await center.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password) }
            else { try await center.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) }
            dismiss()
        } catch { self.error = error.localizedDescription }
        working = false
    }
}
