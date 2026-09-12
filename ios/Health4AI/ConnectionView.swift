import SwiftUI

// MARK: - ConnectionView (Settings tab)

struct ConnectionView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager

    @State private var showSignIn = false
    @State private var showSignOut = false
    @State private var showErase = false
    @State private var testResult: TestResult? = nil
    @State private var isTesting = false
    var body: some View {
        NavigationStack {
            List {
                configSection
                authSection
                privacySection
                testSection
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(authManager)
                .environmentObject(syncState)
        }
        .alert("Sign Out", isPresented: $showSignOut) {
            Button("Sign Out", role: .destructive) {
                authManager.signOut()
                SyncEngine.shared.stopObserving()
                Task { @MainActor in
                    syncState.isAuthenticated = false
                    syncState.userEmail = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again to resume syncing.")
        }
        .alert("Erase Local Data and Configuration?", isPresented: $showErase) {
            Button("Erase", role: .destructive) {
                authManager.signOut()
                SyncEngine.shared.stopObserving()
                SyncEngine.shared.resetAnchors()
                BulkExportManager.shared.resetBackfill()
                syncState.eraseLocalDataAndConfiguration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this device's saved backend address, credentials, sync history, and Health4AI setup. It does not delete backend or Apple Health data, and it does not revoke HealthKit permission in iOS Settings.")
        }
    }

    // MARK: - Backend type
    //
    // The REST / Webhook picker is REMOVED for 1.0, not merely hidden behind a flag.
    // It was presented as a first-class choice and had never worked: restBearerToken,
    // restApiKeyValue and restApiKeyHeader were written here and read by nothing —
    // postSamples hardcodes the Supabase JWT, and every entry point in AppDelegate gates
    // on authManager.isSignedIn, which is "a Supabase access token exists". A tester who
    // picked REST got "No auth token found — please sign in again", pointing at a sign-in
    // this path never offers. Making it real needs the auth headers AND a new launch gate,
    // and cannot be tested without a live endpoint, so it is out of a 1.0 going to
    // strangers. ConnectionType.rest, RestAuthType, resolvedEndpointURL's branch and the
    // Keychain keys are all left intact, so re-enabling is a UI change plus that work.
    // Register D337.

    // MARK: - Config (conditional on type)

    @ViewBuilder
    private var configSection: some View {
        switch syncState.connectionType {
        case .supabase:
            supabaseConfigSection
        case .rest:
            // Unreachable: SyncState.init coerces a stored `.rest` back to `.supabase`.
            // The case stays only to keep the switch exhaustive.
            supabaseConfigSection
        }
    }

    private var supabaseConfigSection: some View {
        Section {
            LabeledContent("Project URL") {
                // "Project URL", not an example: a placeholder renders in system blue,
                // the same blue as the Sign In button, so a sample URL there read as a
                // configured value. The example lives in the footer instead.
                TextField("Project URL", text: $syncState.supabaseProjectURL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Anon Key") {
                SecureFieldToggle(placeholder: "eyJ…", userDefaultsKey: "hkb.supabaseAnonKey")
            }
        } header: {
            Text("Supabase")
        } footer: {
            // No `.tertiary`: it is not a token design.md documents, and stacked on a
            // footer's own .secondary it measured 1.29:1 against the grouped background.
            // This is also the first place a stranger can be told what the app needs —
            // onboarding never names Supabase at all.
            if syncState.supabaseProjectURL.isEmpty {
                Text("health4ai stores your health data in a Supabase project you own, "
                     + "not on our servers. Create a free project at supabase.com, then "
                     + "paste its Project URL and anon key from Project Settings → API.")
            } else {
                Text("Endpoint: \(syncState.resolvedEndpointURL)")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Auth (Supabase only)

    @ViewBuilder
    private var authSection: some View {
        if syncState.connectionType == .supabase {
            Section {
                if syncState.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Signed In")
                                .fontWeight(.medium)
                            if let email = syncState.userEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out") { showSignOut = true }
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        showSignIn = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("Sign In to Supabase")
                                .fontWeight(.medium)
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }
        }
    }

    private var privacySection: some View {
        Section {
            Button(role: .destructive) {
                showErase = true
            } label: {
                Label("Erase Local Data & Configuration", systemImage: "trash")
            }
            // `role: .destructive` tints the text but not the Label's image, so the trash
            // glyph rendered system blue beside red text. `.tint`, never `.foregroundStyle`
            // on a button — design.md rule 3.
            .tint(.red)
        } header: {
            Text("Device Privacy")
        } footer: {
            Text("Use before giving this device to someone else. Your database is never shared automatically.")
        }
    }

    // MARK: - Test connection

    private var testSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(isTesting ? "Testing…" : "Test Connection")
                }
            }
            .disabled(isTesting)

            if let result = testResult {
                // design.md colour rule 1: the semantic goes on the symbol, the words stay
                // .primary. Red/green .caption measured 3.55:1 and ~1.9:1 — both under AA,
                // and colour alone is the whole signal for a colourblind reader.
                Label {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: result.kind.symbol)
                        .foregroundStyle(result.kind.tint)
                }
            }
        } header: {
            Text("Verify")
        }
        // Footer deleted: header "Verify" + button "Test Connection" + a sentence about
        // pinging an endpoint were three statements of one idea, in mechanism words for
        // someone who typed a Project URL.
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let url = syncState.resolvedEndpointURL
        guard let endpoint = URL(string: url) else {
            testResult = TestResult(kind: .failure,
                message: "That Project URL isn't valid. It should look like https://abc123.supabase.co")
            isTesting = false
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ping": true])
        req.timeoutInterval = 10
        // Send the same credential the sync will send. Unauthenticated, this pinged the
        // ingest endpoint bare and every correctly-configured project came back 401, so
        // the test could report "authentication is required" for a connection that works.
        if let token = authManager.currentToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // One source for the outcome. `let ok = (200...299).contains(code)` used to
                // sit beside this switch, so two places decided the same fact and they
                // disagreed on 401.
                let result: TestResult
                switch code {
                case 200...299:
                    result = TestResult(kind: .ok,
                        message: "Reachable, and your credentials were accepted.")
                case 401, 403:
                    // "Sign in above" names a control that exists, is visible, and is
                    // enabled — the Sign In button is two sections up this same screen.
                    result = authManager.currentToken == nil
                        ? TestResult(kind: .info,
                            message: "Your project answered. Sign in above to finish the check.")
                        : TestResult(kind: .failure,
                            message: "Your project rejected your sign-in. Sign out and sign in again.")
                default:
                    result = TestResult(kind: .failure,
                        message: "Your project answered with HTTP \(code). Check the Project URL.")
                }
                await MainActor.run {
                    testResult = result
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    // localizedDescription is the fallback, not the first answer: "A server
                    // with the specified hostname could not be found" is Foundation talking
                    // about a URL the user typed as a Project URL.
                    let message: String
                    switch (error as? URLError)?.code {
                    case .cannotFindHost, .cannotConnectToHost, .timedOut,
                         .networkConnectionLost, .notConnectedToInternet:
                        message = "Could not reach your project. Check the Project URL."
                    default:
                        message = error.localizedDescription
                    }
                    testResult = TestResult(kind: .failure, message: message)
                    isTesting = false
                }
            }
        }
    }
}

private struct TestResult {
    /// Three outcomes, not two. With a Bool, the "reachable but not signed in yet" case —
    /// which is the FIRST thing every new tester hits, because nothing signs them in
    /// before this button — came back 401, so `success` was false and the row rendered a
    /// red ✗ next to text saying the endpoint was fine. design.md: green means verified;
    /// the converse binds just as hard, and red must mean broken.
    enum Kind {
        case ok, info, failure

        var symbol: String {
            switch self {
            case .ok:      "checkmark.circle.fill"
            case .info:    "info.circle.fill"
            case .failure: "xmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .ok:      .green
            case .info:    .blue
            case .failure: .red
            }
        }
    }

    let kind: Kind
    let message: String
}

