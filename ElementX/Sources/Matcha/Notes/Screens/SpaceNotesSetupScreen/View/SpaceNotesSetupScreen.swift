//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct SpaceNotesSetupScreen: View {
    @Bindable var context: SpaceNotesSetupScreenViewModel.Context
    
    var body: some View {
        FullscreenDialog(horizontalPadding: 24) {
            VStack(spacing: 24) {
                BigIcon(icon: \.document)
                row(icon: \.group, title: UntranslatedL10n.screenMatchaDocsSetupTogetherTitle, body: UntranslatedL10n.screenMatchaDocsSetupTogetherBody)
                row(icon: \.lock, title: UntranslatedL10n.screenMatchaDocsSetupEncryptedTitle, body: UntranslatedL10n.screenMatchaDocsSetupEncryptedBody)
                row(icon: \.room, title: UntranslatedL10n.screenMatchaDocsSetupRoomsTitle, body: UntranslatedL10n.screenMatchaDocsSetupRoomsBody)
            }
        } bottomContent: {
            VStack(spacing: 12) {
                if context.viewState.hasFailed {
                    Text(UntranslatedL10n.screenMatchaDocsSetupError)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Button {
                    context.send(viewAction: .turnOn)
                } label: {
                    HStack(spacing: 8) {
                        if context.viewState.isWorking {
                            ProgressView()
                        }
                        Text(context.viewState.isWorking ? UntranslatedL10n.screenMatchaDocsSetupProgress : UntranslatedL10n.screenMatchaDocsSetupAction)
                    }
                }
                .buttonStyle(.compound(.primary))
                .disabled(context.viewState.isWorking)
            }
        }
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .navigationTitle(UntranslatedL10n.screenMatchaDocsSetupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    context.send(viewAction: .close)
                } label: {
                    CompoundIcon(\.close)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(L10n.actionClose)
            }
        }
        .alert(UntranslatedL10n.screenMatchaDocsEncryptDialogTitle, isPresented: $context.isConfirmingEncryption) {
            Button(UntranslatedL10n.screenMatchaDocsEncryptDialogAction) {
                context.send(viewAction: .confirmEncryption)
            }
            Button(L10n.actionCancel, role: .cancel) { }
        } message: {
            Text(UntranslatedL10n.screenMatchaDocsEncryptDialogBody)
        }
    }
    
    private func row(icon: KeyPath<CompoundIcons, Image>, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CompoundIcon(icon)
                .foregroundStyle(.compound.iconSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
                Text(body)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

struct SpaceNotesSetupScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        preview(.init())
            .previewDisplayName("Initial")
        preview(.init(isWorking: true))
            .previewDisplayName("Working")
        preview(.init(hasFailed: true))
            .previewDisplayName("Failed")
        preview(.init(bindings: .init(isConfirmingEncryption: true)))
            .previewDisplayName("Confirm encryption")
    }
    
    static func preview(_ state: SpaceNotesSetupScreenViewState) -> some View {
        ElementNavigationStack {
            SpaceNotesSetupScreen(context: SpaceNotesSetupScreenPreviewViewModel(state: state).context)
        }
    }
}

/// A setup screen showing a fixed state, for previews.
private final class SpaceNotesSetupScreenPreviewViewModel: SpaceNotesSetupScreenViewModelType {
    init(state: SpaceNotesSetupScreenViewState) {
        super.init(initialViewState: state)
    }
}
