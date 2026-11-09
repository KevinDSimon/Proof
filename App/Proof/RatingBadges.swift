import ProofKit
import SwiftUI

extension View {
    /// Marks a thumbnail with what other apps recorded in XMP: the flag in the top-right corner
    /// and the stars in the bottom-left, as Lightroom does. Apply it to the image itself so the
    /// badges sit on the photo's corners rather than the cell's. White on a dark backing keeps
    /// them readable on any photo without adding color. Stars are one star and the count, which
    /// fits even a narrow portrait thumbnail in the filmstrip. Only a flagged photo shows a flag;
    /// a rejected photo is dimmed instead, badges and all, as Lightroom does.
    func ratingBadges(_ metadata: PhotoMetadata?, size: CGFloat) -> some View {
        overlay(alignment: .topTrailing) {
            if metadata?.flag == .flagged {
                FlagIcon(flag: .flagged, size: size)
                    .badgeStyle(size: size)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let rating = metadata?.rating, rating > 0 {
                HStack(spacing: size * 0.1) {
                    Image(systemName: "star.fill")
                    Text("\(rating)").monospacedDigit()
                }
                .badgeStyle(size: size)
            }
        }
        .opacity(metadata?.flag == .rejected ? 0.35 : 1)
    }

    fileprivate func badgeStyle(size: CGFloat) -> some View {
        font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.4)
            .padding(.vertical, size * 0.3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: size * 0.35))
            .padding(size * 0.35)
            .accessibilityHidden(true)
    }
}

/// Lightroom's flag icons: a filled flag for flagged, an outlined flag for unflagged, and a filled
/// flag with an X for rejected. SF Symbols has no flag with an X, so the X is cut out of the flag.
struct FlagIcon: View {
    let flag: PhotoMetadata.Flag
    /// The point size of the surrounding font, so the X scales with the flag.
    var size: CGFloat = 12

    var body: some View {
        switch flag {
        case .flagged:
            Image(systemName: "flag.fill")
        case .unflagged:
            Image(systemName: "flag")
        case .rejected:
            Image(systemName: "flag.fill")
                .overlay(alignment: .center) {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.45, weight: .black))
                        // The flag's cloth sits above and right of the symbol's center.
                        .offset(x: size / 12, y: -size / 8)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

enum RatingBadges {
    /// The photo's name followed by its rating and flag, for VoiceOver.
    static func accessibilityLabel(name: String, metadata: PhotoMetadata?) -> String {
        guard let metadata else { return name }
        var parts = [name]
        if metadata.rating > 0 { parts.append(metadata.rating == 1 ? "1 star" : "\(metadata.rating) stars") }
        switch metadata.flag {
        case .flagged: parts.append("flagged")
        case .rejected: parts.append("rejected")
        case .unflagged: break
        }
        return parts.joined(separator: ", ")
    }

    static let readOnlyHelp = "From other apps. Proof can't change ratings or flags yet."
}

/// The current photo's stars in the Edit toolbar: filled up to the rating, outlined after.
/// Read-only until Proof writes XMP.
struct StarsDisplay: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? .primary : .tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .help(RatingBadges.readOnlyHelp)
        .accessibilityElement()
        .accessibilityLabel(rating == 0 ? "No stars" : rating == 1 ? "1 star" : "\(rating) stars")
    }
}

/// The current photo's flag in the Edit toolbar: Flagged, Unflagged and Rejected side by side,
/// with the current one inverted. Read-only until Proof writes XMP.
struct FlagDisplay: View {
    let flag: PhotoMetadata.Flag

    var body: some View {
        HStack(spacing: 2) {
            ForEach([PhotoMetadata.Flag.flagged, .unflagged, .rejected], id: \.self) { option in
                let isCurrent = option == flag
                FlagIcon(flag: option, size: 12)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 20)
                    .background {
                        if isCurrent { Capsule().fill(.primary) }
                    }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
        .help(RatingBadges.readOnlyHelp)
        .accessibilityElement()
        .accessibilityLabel(flag.rawValue.capitalized)
    }
}
