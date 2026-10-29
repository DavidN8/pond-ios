//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct LabsScreen: View {
    @Bindable var context: LabsScreenViewModel.Context
    
    var body: some View {
        Form {
            header
            matchaWorkspacesSection // matcha
            // matcha: named threads need the threads, so they can't be turned off while the workspaces are on.
            if !context.matchaWorkspacesEnabled {
                threadsSection
            }
            gallerySection
            knockingSection
        }
        .compoundList()
        .navigationTitle(L10n.screenLabsTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var header: some View {
        Section {
            EmptyView()
        } header: {
            VStack(spacing: 16) {
                BigIcon(icon: \.labs, style: .default)
                
                VStack(spacing: 8) {
                    Text(L10n.screenLabsHeaderTitle)
                        .foregroundColor(.compound.textPrimary)
                        .font(.compound.headingMDBold)
                        .multilineTextAlignment(.center)
                    
                    Text(L10n.screenLabsHeaderDescription)
                        .font(.compound.bodyMD)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.compound.textSecondary)
                }
                .compoundListSectionHeader()
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    /// matcha: read when a session starts, as the tabs are built once per session; Android switches them live.
    private var matchaWorkspacesSection: some View {
        Section {
            ListRow(label: .default(title: UntranslatedL10n.screenLabsEnableMatchaWorkspaces,
                                    icon: \.matchaBoard),
                    kind: .toggle($context.matchaWorkspacesEnabled))
        } footer: {
            Text(UntranslatedL10n.screenLabsEnableMatchaWorkspacesDescription)
                .compoundListSectionFooter()
        }
        .onChange(of: context.matchaWorkspacesEnabled) { _, isEnabled in
            // Threads turned off while the workspaces were off come back on, as their row did, through a cache clear.
            if isEnabled, !context.threadsEnabled {
                context.threadsEnabled = true
                context.send(viewAction: .clearCache)
            }
        }
    }
    
    private var threadsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenLabsEnableThreads,
                                    icon: \.threads),
                    kind: .toggle($context.threadsEnabled))
        } footer: {
            Text(L10n.screenLabsEnableThreadsDescription)
                .compoundListSectionFooter()
        }
        .onChange(of: context.threadsEnabled) { _, _ in
            context.send(viewAction: .clearCache)
        }
    }
    
    private var gallerySection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenLabsEnableGallery,
                                    icon: \.image),
                    kind: .toggle($context.galleryEnabled))
        } footer: {
            Text(L10n.screenLabsEnableGalleryDescription)
                .compoundListSectionFooter()
        }
    }
    
    private var knockingSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenLabsEnableKnocking,
                                    icon: \.askToJoin),
                    kind: .toggle($context.knockingEnabled))
        } footer: {
            Text(L10n.screenLabsEnableKnockingDescription)
                .compoundListSectionFooter()
        }
    }
}

// MARK: - Previews

struct LabsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = LabsScreenViewModel(labsOptions: AppSettings.volatile())
    static let withoutMatchaWorkspacesViewModel = { // matcha
        let appSettings = AppSettings.volatile()
        appSettings.matchaWorkspacesEnabled = false
        return LabsScreenViewModel(labsOptions: appSettings)
    }()
    
    static var previews: some View {
        ElementNavigationStack {
            LabsScreen(context: viewModel.context)
        }
        
        ElementNavigationStack { // matcha
            LabsScreen(context: withoutMatchaWorkspacesViewModel.context)
        }
        .previewDisplayName("Without the Matcha workspaces")
    }
}
