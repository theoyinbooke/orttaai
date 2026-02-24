// HomeLoadingView.swift
// Orttaai

import SwiftUI

struct HomeLoadingView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                headerSkeleton
                bannerSkeleton
                rowSkeleton
                trendSkeleton
                rowSkeleton
                recentSkeleton
            }
            .padding(Spacing.xxl)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading dashboard")
            .accessibilityHint("Dashboard statistics and cards are being prepared.")
        }
        .background(Color.Orttaai.bgPrimary)
    }

    private var headerSkeleton: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                DashboardSkeletonBlock(width: 180, height: 22, cornerRadius: CornerRadius.input)
                DashboardSkeletonBlock(width: 240, height: 14, cornerRadius: CornerRadius.input)
            }
            Spacer()
            HStack(spacing: Spacing.sm) {
                DashboardSkeletonBlock(width: 90, height: 28, cornerRadius: 14)
                DashboardSkeletonBlock(width: 90, height: 28, cornerRadius: 14)
                DashboardSkeletonBlock(width: 90, height: 28, cornerRadius: 14)
            }
        }
    }

    private var bannerSkeleton: some View {
        HStack(spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                DashboardSkeletonBlock(width: 280, height: 28)
                DashboardSkeletonBlock(width: 360, height: 14)
                DashboardSkeletonBlock(width: 170, height: 14)
                DashboardSkeletonBlock(width: 132, height: 34, cornerRadius: CornerRadius.button)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DashboardSkeletonBlock(width: 220, height: 120)
        }
        .padding(Spacing.xl)
        .dashboardCard()
    }

    private var rowSkeleton: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                metricCardSkeleton
                    .frame(maxWidth: .infinity)
                metricCardSkeleton
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: Spacing.lg) {
                metricCardSkeleton
                metricCardSkeleton
            }
        }
    }

    private var metricCardSkeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            DashboardSkeletonBlock(width: 130, height: 16, cornerRadius: CornerRadius.input)
            DashboardSkeletonBlock(height: 72)
            DashboardSkeletonBlock(height: 72)
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var trendSkeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            DashboardSkeletonBlock(width: 120, height: 16, cornerRadius: CornerRadius.input)
            DashboardSkeletonBlock(height: 210)
            HStack(spacing: Spacing.lg) {
                DashboardSkeletonBlock(width: 90, height: 12, cornerRadius: CornerRadius.input)
                DashboardSkeletonBlock(width: 110, height: 12, cornerRadius: CornerRadius.input)
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var recentSkeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                DashboardSkeletonBlock(width: 150, height: 16, cornerRadius: CornerRadius.input)
                Spacer()
                DashboardSkeletonBlock(width: 92, height: 26, cornerRadius: CornerRadius.button)
            }

            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        DashboardSkeletonBlock(width: 120, height: 12, cornerRadius: CornerRadius.input)
                        Spacer()
                        DashboardSkeletonBlock(width: 84, height: 12, cornerRadius: CornerRadius.input)
                    }
                    DashboardSkeletonBlock(height: 14, cornerRadius: CornerRadius.input)
                    DashboardSkeletonBlock(width: 260, height: 14, cornerRadius: CornerRadius.input)
                }
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }
}
