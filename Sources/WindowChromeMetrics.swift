import CoreGraphics

enum WindowChromeMetrics {
    static let sharedChromeBarHeight: CGFloat = 28
    static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let maximumTitlebarHeight: CGFloat = 72
    static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}

enum HeaderChromeControlMetrics {
    static let buttonSize: CGFloat = 20
    static let iconSize: CGFloat = 12
    static let iconFrameSize: CGFloat = 14
    static let cornerRadius: CGFloat = 6
    static let titlebarControlsLeadingPadding: CGFloat = 4

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}

enum RightSidebarChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    static let secondaryBarHeight: CGFloat = WindowChromeMetrics.secondaryTitlebarHeight
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 4
    static let controlHeight: CGFloat = secondaryBarHeight - (barVerticalPadding * 2)
    static let controlHorizontalPadding: CGFloat = 8
    static let controlCornerRadius: CGFloat = 5
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

enum SidebarWorkspaceListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    /// Extra breathing room between the sidebar's top button cluster and the
    /// first conversation row when the window is full-screen + sidebar expanded.
    static let fullScreenFirstRowTopBonus: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 8
    private static let baseTopScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = baseTopScrimHeight

    static func scrollTopInset(extraTopOffset: CGFloat) -> CGFloat {
        max(0, firstRowTopOffset + extraTopOffset - rowVerticalPadding)
    }

    static func topScrimHeight(extraTopOffset: CGFloat) -> CGFloat {
        baseTopScrimHeight + extraTopOffset
    }

    static func extraTopOffset(isWindowFullScreen: Bool) -> CGFloat {
        isWindowFullScreen ? fullScreenFirstRowTopBonus : 0
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    /// Zero-offset insets for sidebar surfaces without the Casper workspace
    /// search bar (extension/custom sidebars).
    static let workspaceList = SidebarWorkspaceScrollInsets.workspaceList(extraTopOffset: 0)

    // CASPER: workspace list reserves extra top inset for the search bar;
    // delete if upstream adds a sidebar search affordance.
    static func workspaceList(extraTopOffset: CGFloat) -> SidebarWorkspaceScrollInsets {
        SidebarWorkspaceScrollInsets(
            top: SidebarWorkspaceListMetrics.scrollTopInset(extraTopOffset: extraTopOffset),
            bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
        )
    }

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        max(0, viewportHeight - insets.total)
    }
}
