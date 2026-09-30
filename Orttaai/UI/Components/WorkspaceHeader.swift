// WorkspaceHeader.swift
// Orttaai

import SwiftUI

extension EnvironmentValues {
    /// False where the window's toolbar isn't the page's to use (the
    /// standalone Settings window's toolbar belongs to its tab view); pages
    /// then draw their header inline above their content.
    @Entry var workspaceHeaderInToolbar = true

    /// Shows or hides the main window's sidebar. The shell provides it and
    /// removes the system toggle, whose glass capsule doesn't fit the app;
    /// every page header then leads with a plain toggle icon.
    @Entry var workspaceSidebarToggle: (() -> Void)? = nil
}

extension View {
    /// Places the page title, with optional controls beside it (such as
    /// section tabs) and actions at the trailing edge, in the window's
    /// toolbar strip instead of spending content height on a header.
    func workspaceHeader<Leading: View, Trailing: View>(
        _ title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(WorkspaceHeaderModifier(title: title, leading: leading(), trailing: trailing()))
    }

    func workspaceHeader<Leading: View>(
        _ title: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        workspaceHeader(title, leading: leading, trailing: { EmptyView() })
    }

    func workspaceHeader(_ title: String) -> some View {
        workspaceHeader(title, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

private struct WorkspaceHeaderModifier<Leading: View, Trailing: View>: ViewModifier {
    let title: String
    let leading: Leading
    let trailing: Trailing
    @Environment(\.workspaceHeaderInToolbar) private var inToolbar
    @Environment(\.workspaceSidebarToggle) private var toggleSidebar

    private var hasTrailing: Bool { Trailing.self != EmptyView.self }

    func body(content: Content) -> some View {
        if inToolbar {
            if #available(macOS 26.0, *) {
                // macOS 26 wraps toolbar items in a glass capsule; the header
                // keeps the app's own styling instead.
                content
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            titleRow
                        }
                        .sharedBackgroundVisibility(.hidden)

                        if hasTrailing {
                            // Pushes the actions to the trailing edge.
                            ToolbarSpacer(.flexible)

                            ToolbarItem(placement: .primaryAction) {
                                trailing
                                    .labelStyle(.titleAndIcon)
                                    .padding(.trailing, Spacing.sm)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        }
                    }
            } else {
                content
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            titleRow
                        }

                        if hasTrailing {
                            ToolbarItem(placement: .primaryAction) {
                                trailing
                                    .labelStyle(.titleAndIcon)
                                    .padding(.trailing, Spacing.sm)
                            }
                        }
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.md) {
                    titleRow
                    Spacer(minLength: Spacing.md)
                    trailing
                }
                .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
                .padding(.vertical, Spacing.md)

                content
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: Spacing.lg) {
            if inToolbar, let toggleSidebar {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show or hide the sidebar")
                .accessibilityLabel("Toggle sidebar")
            }

            Text(title)
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            leading
        }
    }
}
