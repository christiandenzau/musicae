import SwiftUI

struct IntegrationsTabView: View {
    @AppStorage("lastfmUsername")
    private var lastfmUsername: String = ""

    @AppStorage("scrobblingEnabled")
    private var scrobblingEnabled: Bool = true

    @AppStorage("loveSyncEnabled")
    private var loveSyncEnabled: Bool = true

    @AppStorage("onlineLyricsEnabled")
    private var onlineLyricsEnabled: Bool = false

    @AppStorage("artistInfoFetchEnabled")
    private var artistInfoFetchEnabled: Bool = false

    @State private var isAuthenticating = false
    @State private var showLoveSyncInfo = false
    @State private var showDisconnectConfirmation = false

    // MusicBrainz relations graph (#18): manual, online, rate-limited load.
    @State private var isIngestingRelations = false
    @State private var relationsStats: DatabaseManager.RelationsGraphStats?

    private var isConnected: Bool {
        !lastfmUsername.isEmpty
    }

    private var cachedLastFMAvatar: NSImage? {
        guard let data = UserDefaults.standard.data(forKey: "lastfmAvatarData"),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    var body: some View {
        Form {
            Section {
                lastfmSection
            } header: {
                Text("Last.fm")
            }

            Section {
                onlineFeaturesSection
            } header: {
                Text("Lyrics & Metadata")
            }

            Section {
                musicBrainzRelationsSection
            } header: {
                Text("MusicBrainz")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding(5)
        .task {
            relationsStats = await AppCoordinator.shared?.libraryManager.databaseManager.relationsGraphStats() ?? nil
        }
        .alert("Disconnect from Last.fm?", isPresented: $showDisconnectConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                disconnect()
            }
        } message: {
            Text("Your listening activity will no longer be scrobbled to Last.fm once you disconnect.")
        }
    }

    // MARK: - Last.fm Section

    @ViewBuilder private var lastfmSection: some View {
        if isConnected {
            connectedView
        } else {
            disconnectedView
        }
    }

    private var connectedView: some View {
        Group {
            HStack {
                Group {
                    if let avatar = cachedLastFMAvatar {
                        Image(nsImage: avatar)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: Icons.personFill)
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(lastfmUsername)
                        .font(.system(size: 13, weight: .medium))
                    Text("Connected")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }

                Spacer()

                Button {
                    showDisconnectConfirmation = true
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .cornerRadius(5)
            }
            .padding(.vertical, 4)

            Toggle("Enable scrobbling", isOn: $scrobblingEnabled)
                .help("Track your listening history on Last.fm")

            Toggle(isOn: $loveSyncEnabled) {
                HStack(spacing: 4) {
                    Text("Sync favorites as Loved tracks")

                    Button {
                        showLoveSyncInfo.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLoveSyncInfo, arrowEdge: .trailing) {
                        Text("Tracks you favorite in Musicae will be loved on Last.fm. Loved tracks on Last.fm won't sync back to Musicae.")
                            .font(.system(size: 12))
                            .padding(10)
                            .frame(width: 220)
                    }
                }
            }
        }
    }

    private var disconnectedView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not connected")
                    .font(.system(size: 13, weight: .medium))
                Text("Connect your Last.fm account to start scrobbling")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: startAuthentication) {
                if isAuthenticating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 60)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isAuthenticating)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Online Features Section

    private var onlineFeaturesSection: some View {
        Group {
            Toggle("Fetch lyrics from internet when unavailable", isOn: $onlineLyricsEnabled)
                .help("Automatically search for lyrics online when no local lyrics are found")

            Toggle("Fetch artist image and bio from internet", isOn: $artistInfoFetchEnabled)
                .help("Automatically download artist photos and bios from online sources")
                .onChange(of: artistInfoFetchEnabled) { _, enabled in
                    if enabled, let coordinator = AppCoordinator.shared {
                        ArtistBioManager.shared.fetchMissingArtistImages(using: coordinator.libraryManager)
                    }
                }
        }
    }

    // MARK: - MusicBrainz Relations Section

    /// Manual, online load of the relationship graph (#18): fetch how the library's tracks
    /// connect on MusicBrainz (releases, remixes, cover origins) and store it beside the
    /// main DB. Rate-limited to ~1 request/second, so a large library takes a while;
    /// detailed progress shows in the activity indicator, this button just reflects "running".
    private var musicBrainzRelationsSection: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track relationships")
                        .font(.system(size: 13, weight: .medium))
                    if let stats = relationsStats {
                        Text("\(stats.entities) entities · \(stats.edges) relationships")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Not loaded yet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: loadRelationships) {
                    if isIngestingRelations {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 70)
                    } else {
                        Text(relationsStats == nil ? "Load" : "Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isIngestingRelations)
            }
            .padding(.vertical, 4)

            // Long localized help string; wrapping it would change the string-catalog key.
            // swiftlint:disable:next line_length
            Text("Fetches how your tracks connect on MusicBrainz — the release each appears on, remixes, cover origins. Runs online at about one request per second, so a large library takes a while. Then use \u{201C}Relationships\u{201D} in a track\u{2019}s context menu.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private func loadRelationships() {
        guard let databaseManager = AppCoordinator.shared?.libraryManager.databaseManager else { return }
        isIngestingRelations = true
        Task {
            await databaseManager.ingestRelations()
            let stats = await databaseManager.relationsGraphStats()
            await MainActor.run {
                relationsStats = stats
                isIngestingRelations = false
            }
        }
    }

    private func startAuthentication() {
        guard let scrobbleManager = AppCoordinator.shared?.scrobbleManager,
              let authURL = scrobbleManager.authenticationURL() else {
            return
        }

        isAuthenticating = true
        NSWorkspace.shared.open(authURL)
        Logger.info("Opened Last.fm authorization page")

        // Reset authenticating state after a delay
        // The actual authentication will complete via URL scheme callback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isAuthenticating = false
        }
    }

    private func disconnect() {
        lastfmUsername = ""
        scrobblingEnabled = true
        loveSyncEnabled = true

        // Clear cached avatar
        UserDefaults.standard.removeObject(forKey: "lastfmAvatarData")

        // Clear session from Keychain
        KeychainManager.delete(key: KeychainManager.Keys.lastfmSessionKey)

        Logger.info("Disconnected from Last.fm")
        NotificationManager.shared.addMessage(.info, String(localized: "Disconnected from Last.fm"))
    }
}

#Preview {
    IntegrationsTabView()
        .frame(width: 600, height: 400)
}
