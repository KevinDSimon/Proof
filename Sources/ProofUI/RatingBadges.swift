import ProofKit
import SwiftUI

public extension View {
    /// Marks a thumbnail with what other apps recorded in XMP: the flag in the top-right corner
    /// and the stars in the bottom-left, as Lightroom does. A pencil in the top-left shows the
    /// photo has an edit, which is the Edited filter's test. A stack mark before it shows the photo
    /// is one of a stack, such as a RAW and its JPEG, with the count on the first (#157). Apply it to the image itself so the
    /// badges sit on the photo's corners rather than the cell's. White on a dark backing keeps
    /// them readable on any photo without adding color. Stars are one star and the count, which
    /// fits even a narrow portrait thumbnail in the filmstrip. Only a flagged photo shows a flag;
    /// a rejected photo is dimmed instead, badges and all, as Lightroom does.
    /// `toggleStack` opens or collapses the stack from the first photo's count badge.
    func ratingBadges(_ metadata: PhotoMetadata?, isEdited: Bool, stack: StackMark? = nil,
                      isStackOpen: Bool = false, toggleStack: @escaping () -> Void = {}, size: CGFloat) -> some View {
        overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                switch stack {
                case .first(let count):
                    Button(action: toggleStack) {
                        HStack(spacing: size * 0.25) {
                            Image(systemName: "square.stack")
                            Text("\(count)").monospacedDigit()
                        }
                        .badgeStyle(size: size)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isStackOpen ? "Collapse the stack" : "Open the stack")
                case .member:
                    Image(systemName: "square.stack")
                        .badgeStyle(size: size)
                case nil:
                    EmptyView()
                }
                if isEdited {
                    Image(systemName: "pencil")
                        .badgeStyle(size: size)
                        // Beside the stack mark, the two share the corner's margin.
                        .padding(.leading, stack == nil ? 0 : -size * 0.35)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
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

    /// The photos a collapsed stack hides, peeking out above its first photo: one layer for each,
    /// up to two, each a little narrower and darker than the one in front, so the stack reads as
    /// its photos piled up. A layer without its thumbnail yet is gray. Every photo `inStack` gives
    /// up two `step`s at the top, open or collapsed, so the layers stay inside the cell and its
    /// selection outline, and opening a stack never resizes its photos. Apply it to the image,
    /// after its badges, so the layers are its width and the badges stay on the photo.
    @ViewBuilder func stackLayers(_ layers: [CGImage?], inStack: Bool, step: CGFloat) -> some View {
        if !inStack {
            self
        } else {
            background(alignment: .top) {
                ZStack(alignment: .top) {
                    // The farthest first, so the nearer layer covers it.
                    ForEach(Array(layers.prefix(2).enumerated()).reversed(), id: \.offset) { depth, image in
                        Group {
                            if let image {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color(white: 0.4)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay(Color.black.opacity(0.3 + 0.2 * Double(depth)))
                        .clipShape(.rect(cornerRadius: SelectionOutline.photoCornerRadius))
                        .scaleEffect(x: 0.92 - 0.08 * Double(depth), anchor: .top)
                        .offset(y: -step * Double(depth + 1))
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.top, step * 2)
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

/// Lightroom's flag icons: a filled flag for flagged, an outlined flag for unflagged, and a filled
/// flag with an X for rejected. SF Symbols has no flag with an X, so the X is cut out of the flag.
public struct FlagIcon: View {
    let flag: PhotoMetadata.Flag
    /// The point size of the surrounding font, so the X scales with the flag.
    var size: CGFloat = 12

    public init(flag: PhotoMetadata.Flag, size: CGFloat = 12) {
        self.flag = flag
        self.size = size
    }

    public var body: some View {
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

public enum RatingBadges {
    /// The photo's name followed by its rating, flag and whether it is edited, for VoiceOver.
    public static func accessibilityLabel(name: String, metadata: PhotoMetadata?, isEdited: Bool,
                                   stack: StackMark? = nil) -> String {
        var parts = [name]
        switch stack {
        case .first(let count): parts.append("stack of \(count)")
        case .member: parts.append("in a stack")
        case nil: break
        }
        if let metadata {
            if metadata.rating > 0 { parts.append(metadata.rating == 1 ? "1 star" : "\(metadata.rating) stars") }
            switch metadata.flag {
            case .flagged: parts.append("flagged")
            case .rejected: parts.append("rejected")
            case .unflagged: break
            }
        }
        if isEdited { parts.append("edited") }
        return parts.joined(separator: ", ")
    }

    /// The flags in the order Lightroom shows them.
    public static let flags: [PhotoMetadata.Flag] = [.flagged, .unflagged, .rejected]

    public static func title(of flag: PhotoMetadata.Flag) -> String {
        switch flag {
        case .flagged: "Flagged"
        case .unflagged: "Unflagged"
        case .rejected: "Rejected"
        }
    }

    public static func title(ofRating rating: Int) -> String {
        switch rating {
        case 0: "No Stars"
        case 1: "1 Star"
        default: "\(rating) Stars"
        }
    }
}

/// The Edit toolbar's star buttons, packed closer than separate toolbar items would be. Clicking
/// the current rating clears it.
public struct StarButtons: View {
    let rating: Int
    let setRating: (Int) -> Void

    public init(rating: Int, setRating: @escaping (Int) -> Void) {
        self.rating = rating
        self.setRating = setRating
    }

    public var body: some View {
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
                .help("\(RatingBadges.title(ofRating: star)) (\(star))")
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
public struct FlagButtons: View {
    let flag: PhotoMetadata.Flag
    let setFlag: (PhotoMetadata.Flag) -> Void

    public init(flag: PhotoMetadata.Flag, setFlag: @escaping (PhotoMetadata.Flag) -> Void) {
        self.flag = flag
        self.setFlag = setFlag
    }

    public var body: some View {
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
                .help(RatingBadges.title(of: option))
                .accessibilityLabel(RatingBadges.title(of: option))
                .accessibilityAddTraits(option == flag ? .isSelected : [])
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
    }
}

public extension Library {
    /// Opens or collapses the stack `photo` is in, with the photos it shows or hides sliding in
    /// and out, so the stack is seen to open.
    func toggleStackAnimated(of photo: PhotoReference) {
        withAnimation(.snappy(duration: 0.25)) { toggleStack(of: photo) }
    }
}
