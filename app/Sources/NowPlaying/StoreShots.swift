import AppKit
import SwiftUI

/// Renders Chrome Web Store marketing images with the real overlay views (incl. Liquid Glass).
/// `NowPlaying --store-shot <1|2|3|promo|banner|social>` opens one borderless window of the exact asset size at the
/// main screen's bottom-left; `scripts/store-assets.sh` captures it. Sample content only: no album art,
/// wallpaper or song that isn't ours.
@MainActor
enum StoreShots {
    private static var window: NSWindow?

    static func show(_ which: String) {
        let model = PlayerModel()
        model.loadPreview(from: PlayerModel())
        let (size, view): (CGSize, AnyView) = {
            switch which {
            case "2": return (CGSize(width: 1280, height: 800), AnyView(ShotLyrics(model: model)))
            case "3": return (CGSize(width: 1280, height: 800), AnyView(ShotStyles(model: model)))
            case "promo": return (CGSize(width: 440, height: 280), AnyView(PromoTile()))
            case "banner": return (CGSize(width: 1600, height: 560), AnyView(Banner(model: model)))
            case "social": return (CGSize(width: 1280, height: 640), AnyView(SocialCard(model: model)))
            case "idle": return (CGSize(width: 1280, height: 800), AnyView(ShotIdle()))
            default: return (CGSize(width: 1280, height: 800), AnyView(ShotHero(model: model)))
            }
        }()
        let origin = NSScreen.main?.frame.origin ?? .zero
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.title = "NowPlaying Store Shot"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.hasShadow = false
        w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        w.orderFrontRegardless()
        window = w
    }
}

/// Abstract backdrop standing in for a desktop.
private struct ShotBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.18), Color(red: 0.16, green: 0.10, blue: 0.26)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.98, green: 0.47, blue: 0.40)).frame(width: 620).offset(x: 380, y: 260).blur(radius: 140)
            Circle().fill(Color(red: 0.50, green: 0.26, blue: 0.85)).frame(width: 700).offset(x: -420, y: -200).blur(radius: 150)
            Circle().fill(Color(red: 0.17, green: 0.65, blue: 0.80)).frame(width: 420).offset(x: 120, y: -300).blur(radius: 130)
        }
    }
}

private struct Headline: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.72))
        }
    }
}

private struct Overlay: View {
    let model: PlayerModel
    let style: OverlayStyle
    let layout: OverlayLayout
    var size: CGSize? = nil
    var body: some View {
        let s = size ?? layout.defaultSize
        OverlayContent(model: model, layout: layout, size: s, controller: nil)
            .environment(\.overlayStyle, style)
            .environment(\.overlayPreview, true)
            .frame(width: s.width, height: s.height)
    }
}

private struct ShotHero: View {
    let model: PlayerModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ShotBackdrop()
            Headline(title: "Lyrics that float over everything",
                     subtitle: "Artwork and time-synced lyrics from YouTube and YouTube Music, in a tiny macOS overlay.")
                .frame(width: 720, alignment: .leading)
                .padding(.leading, 80).padding(.top, 90)
            Overlay(model: model, style: .glass, layout: .coverLine, size: CGSize(width: 640, height: 200))
                .position(x: 760, y: 470)
            Overlay(model: model, style: .glass, layout: .mini, size: CGSize(width: 380, height: 60))
                .position(x: 330, y: 690)
        }
    }
}

private struct ShotLyrics: View {
    let model: PlayerModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ShotBackdrop()
            Headline(title: "Sing along",
                     subtitle: "Synced lyrics and captions, with the next line\nalways one glance away.")
                .padding(.leading, 80).padding(.top, 260)
            Overlay(model: model, style: .glass, layout: .lyrics, size: CGSize(width: 400, height: 620))
                .position(x: 960, y: 400)
        }
    }
}

private struct ShotStyles: View {
    let model: PlayerModel
    var body: some View {
        ZStack(alignment: .top) {
            ShotBackdrop()
            VStack(spacing: 50) {
                Headline(title: "Make it yours", subtitle: "Glass, Tinted or Clear. Four layouts. Resize from any edge.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 80)
                HStack(spacing: 36) {
                    ForEach(OverlayStyle.allCases) { st in
                        VStack(spacing: 14) {
                            Overlay(model: model, style: st, layout: .coverLine, size: CGSize(width: 360, height: 128))
                            Text(st.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                HStack(spacing: 36) {
                    Overlay(model: model, style: .glass, layout: .cover, size: CGSize(width: 220, height: 220))
                    Overlay(model: model, style: .tinted, layout: .mini, size: CGSize(width: 360, height: 60))
                }
            }
            .padding(.top, 80)
        }
    }
}

/// Verification sheet for the idle (recently played) and paused states in every layout.
private struct ShotIdle: View {
    let idle: PlayerModel = { let m = PlayerModel(); m.loadIdlePreview(); return m }()
    let paused: PlayerModel = { let m = PlayerModel(); m.loadPreview(from: PlayerModel()); m.setPreviewPaused(); return m }()
    var body: some View {
        ZStack(alignment: .topLeading) {
            ShotBackdrop()
            VStack(alignment: .leading, spacing: 26) {
                Text("Nothing playing").font(.title2.bold()).foregroundStyle(.white)
                HStack(alignment: .top, spacing: 26) {
                    Overlay(model: idle, style: .glass, layout: .coverLine, size: CGSize(width: 400, height: 140))
                    Overlay(model: idle, style: .glass, layout: .cover, size: CGSize(width: 220, height: 220))
                    Overlay(model: idle, style: .glass, layout: .lyrics, size: CGSize(width: 300, height: 330))
                }
                HStack(alignment: .top, spacing: 26) {
                    Overlay(model: idle, style: .tinted, layout: .coverLine, size: CGSize(width: 380, height: 110))
                    Overlay(model: idle, style: .glass, layout: .mini, size: CGSize(width: 320, height: 56))
                }
                Text("Paused").font(.title2.bold()).foregroundStyle(.white)
                HStack(alignment: .top, spacing: 26) {
                    Overlay(model: paused, style: .glass, layout: .coverLine, size: CGSize(width: 400, height: 130))
                    Overlay(model: paused, style: .glass, layout: .cover, size: CGSize(width: 180, height: 180))
                }
            }
            .padding(40)
        }
    }
}

private struct PromoTile: View {
    var body: some View {
        ZStack {
            ShotBackdrop()
            HStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now Playing").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Floating lyrics\nfor YouTube on Mac").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

/// Wordmark lockup: app icon, name and tagline.
private struct Lockup: View {
    var iconSize: CGFloat = 112
    var tagline = "Floating lyrics & captions for YouTube on your Mac"
    var body: some View {
        HStack(spacing: iconSize * 0.22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Now Playing").font(.system(size: iconSize * 0.56, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(red: 1.0, green: 0.83, blue: 0.78)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text(tagline).font(.system(size: iconSize * 0.2, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

/// README header (docs/assets/banner.png).
private struct Banner: View {
    let model: PlayerModel
    var body: some View {
        ZStack(alignment: .leading) {
            ShotBackdrop()
            Lockup().padding(.leading, 90).offset(y: -40)
            HStack(spacing: 10) {
                ForEach(["YouTube", "YouTube Music", "macOS 14+", "Apple Silicon · Intel"], id: \.self) { t in
                    Text(t).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                }
            }
            .padding(.leading, 90).offset(y: 95)
            Overlay(model: model, style: .glass, layout: .coverLine, size: CGSize(width: 540, height: 170))
                .position(x: 1230, y: 235)
            Overlay(model: model, style: .tinted, layout: .mini, size: CGSize(width: 400, height: 62))
                .position(x: 1300, y: 395)
        }
    }
}

/// GitHub social preview (docs/assets/social.png, 1280×640).
private struct SocialCard: View {
    let model: PlayerModel
    var body: some View {
        ZStack {
            ShotBackdrop()
            VStack(spacing: 46) {
                Lockup(iconSize: 104)
                Overlay(model: model, style: .glass, layout: .coverLine, size: CGSize(width: 600, height: 190))
            }
        }
    }
}
