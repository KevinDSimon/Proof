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

    /// The flags in the order Lightroom shows them.
    static let flags: [PhotoMetadata.Flag] = [.flagged, .unflagged, .rejected]

    static func title(of flag: PhotoMetadata.Flag) -> String {
        switch flag {
        case .flagged: "Flagged"
        case .unflagged: "Unflagged"
        case .rejected: "Rejected"
        }
    }

    static func title(ofRating rating: Int) -> String {
        switch rating {
        case 0: "No Stars"
        case 1: "1 Star"
        default: "\(rating) Stars"
        }
    }

    static let unsavedNote = "Changes aren't saved to the photo yet."
}

/// The Edit toolbar's star buttons, packed closer than separate toolbar items would be. Clicking
/// the current rating clears it.
struct StarButtons: View {
    let rating: Int
    let setRating: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    setRating(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(RatingBadges.title(ofRating: star)) (\(star)). \(RatingBadges.unsavedNote)")
                .accessibilityLabel(RatingBadges.title(ofRating: star))
                .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
    }
}

/// The Edit toolbar's Flagged, Unflagged and Rejected buttons, packed closely, with the current
/// flag on a gray backing as the system marks a selected toolbar button.
struct FlagButtons: View {
    let flag: PhotoMetadata.Flag
    let setFlag: (PhotoMetadata.Flag) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RatingBadges.flags, id: \.self) { option in
                Button {
                    setFlag(option)
                } label: {
                    FlagIcon(flag: option)
                        .frame(width: 28, height: 24)
                        .background {
                            if option == flag { Capsule().fill(.quaternary) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(RatingBadges.title(of: option)). \(RatingBadges.unsavedNote)")
                .accessibilityLabel(RatingBadges.title(of: option))
                .accessibilityAddTraits(option == flag ? .isSelected : [])
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
    }
}
