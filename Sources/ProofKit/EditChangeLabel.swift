import Foundation

extension EditRecipe {
    /// What the History panel calls the change from `previous` to this edit. One Basic slider
    /// names itself and its new value, as the slider shows it: "Exposure +0.30", "Contrast +10".
    /// Other changes name their card or section, such as "Curve" or "Vignette". A change across
    /// several of them, such as pasted settings, is "Several Adjustments".
    public func changeLabel(from previous: EditRecipe) -> String {
        var parts: [String] = []
        let basic = basic, old = previous.basic

        if basic.whiteBalance != old.whiteBalance {
            parts.append("White Balance: \(basic.whiteBalance.title)")
        } else if basic.temperature != old.temperature, basic.tint != old.tint {
            parts.append("White Balance")
        } else if basic.temperature != old.temperature {
            parts.append(basic.temperature.map { "Temperature \(Self.format($0, digits: 0, signed: false))" } ?? "Temperature")
        } else if basic.tint != old.tint {
            parts.append(basic.tint.map { "Tint \(Self.format($0, digits: 0, signed: true))" } ?? "Tint")
        }

        let sliders: [(String, KeyPath<BasicAdjustments, Double>, Int)] = [
            ("Exposure", \.exposure, 2), ("Contrast", \.contrast, 0), ("Highlights", \.highlights, 0),
            ("Shadows", \.shadows, 0), ("Whites", \.whites, 0), ("Blacks", \.blacks, 0),
            ("Texture", \.texture, 0), ("Clarity", \.clarity, 0), ("Dehaze", \.dehaze, 0),
            ("Vibrance", \.vibrance, 0), ("Saturation", \.saturation, 0),
        ]
        let moved = sliders.filter { basic[keyPath: $0.1] != old[keyPath: $0.1] }
        if moved.count == 1, let (title, path, digits) = moved.first {
            parts.append("\(title) \(Self.format(basic[keyPath: path], digits: digits, signed: true))")
        } else if !moved.isEmpty {
            // Auto Tone, or a reset of the Basic card.
            parts.append("Basic")
        }

        if blackAndWhite.isOn != previous.blackAndWhite.isOn {
            parts.append(blackAndWhite.isOn ? "Black & White" : "Color")
        } else if blackAndWhite != previous.blackAndWhite {
            parts.append("Black & White Mix")
        }

        if look != previous.look {
            switch (look, previous.look) {
            case (nil, _): parts.append("Look: None")
            case let (look?, old?) where look.lut == old.lut:
                parts.append("Look Strength \(Self.format(look.strength * 100, digits: 0, signed: false))%")
            case let (look?, _): parts.append("Look: \(((look.lut as NSString).lastPathComponent as NSString).deletingPathExtension)")
            }
        }

        let sections: [(String, Bool)] = [
            ("Curve", curve != previous.curve),
            ("Selective Color", selectiveColor != previous.selectiveColor),
            ("Detail", detail != previous.detail),
            ("Vignette", vignette != previous.vignette),
            ("Grain", grain != previous.grain),
            ("Halation", halation != previous.halation),
            ("Bloom", bloom != previous.bloom),
            ("Lens Corrections", lens != previous.lens),
            ("Transform", transform != previous.transform),
            ("Crop", crop != previous.crop),
            ("Masks", layers != previous.layers),
        ]
        parts += sections.filter(\.1).map(\.0)

        switch parts.count {
        case 0: return "Edit"
        case 1: return parts[0]
        default: return "Several Adjustments"
        }
    }

    /// The number as the inspector's slider shows it, with a minus sign rather than a hyphen.
    private static func format(_ value: Double, digits: Int, signed: Bool) -> String {
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        let text = String(format: "%.\(digits)f", abs(rounded))
        if rounded < 0 { return "−" + text }
        return signed && rounded > 0 ? "+" + text : text
    }
}

extension WhiteBalancePreset {
    /// The name the white balance menu shows.
    public var title: String {
        switch self {
        case .asShot: "As Shot"
        case .auto: "Auto"
        case .daylight: "Daylight"
        case .cloudy: "Cloudy"
        case .shade: "Shade"
        case .tungsten: "Tungsten"
        case .fluorescent: "Fluorescent"
        case .flash: "Flash"
        case .custom: "Custom"
        }
    }
}
