import ProofKit
import SwiftUI

extension View {
    /// Marks a thumbnail with what other apps recorded in XMP: the flag in the top-right corner
    /// and the stars in the bottom-left, as Lightroom does. Apply it to the image itself so the
    /// badges sit on the photo's corners rather than the cell's. White on a dark backing keeps
    /// them readable on any photo without adding color. Stars are one star and the count, which
    /// fits even a narrow portrait thumbnail in the filmstrip.
    func ratingBadges(_ metadata: PhotoMetadata?, size: CGFloat) -> some View {
        overlay(alignment: .topTrailing) {
            if let symbol = metadata.flatMap({ RatingBadges.flagSymbol($0.flag) }) {
                Image(systemName: symbol)
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

enum RatingBadges {
    /// Rejected uses Lightroom's crossed-out flag. Unflagged shows nothing on a thumbnail.
    static func flagSymbol(_ flag: PhotoMetadata.Flag) -> String? {
        switch flag {
        case .flagged: "flag.fill"
        case .rejected: "flag.slash.fill"
        case .unflagged: nil
        }
    }

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
}

/// The current photo's stars and flag in the Edit toolbar. Read-only: Proof shows what other apps
/// recorded but doesn't write XMP yet.
struct RatingDisplay: View {
    let metadata: PhotoMetadata?

    var body: some View {
        let rating = metadata?.rating ?? 0
        let flag = metadata?.flag ?? .unflagged
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? .primary : .tertiary)
                }
            }
            Image(systemName: RatingBadges.flagSymbol(flag) ?? "flag")
                .foregroundStyle(flag == .unflagged ? .tertiary : .primary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .help("Rating and flag from other apps. Proof doesn't change them yet.")
        .accessibilityElement()
        .accessibilityLabel(accessibilityText(rating: rating, flag: flag))
    }

    private func accessibilityText(rating: Int, flag: PhotoMetadata.Flag) -> String {
        let stars = rating == 0 ? "No stars" : rating == 1 ? "1 star" : "\(rating) stars"
        return "\(stars), \(flag == .unflagged ? "unflagged" : flag.rawValue)"
    }
}
