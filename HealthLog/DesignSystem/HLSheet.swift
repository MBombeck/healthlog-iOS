import SwiftUI

/// Canonical sheet-presentation behaviour for HealthLog.
///
/// Before this token every `.sheet`/`.fullScreenCover` site re-spelled its own
/// `.presentationDetents([…])` + `.presentationDragIndicator(…)` pair, which had
/// drifted into four different combinations across ~27 files (some sheets had no
/// detent or no drag indicator at all). `HLSheetSize` + `hlSheetPresentation`
/// collapse that into a single, named contract so every sheet feels the same.
///
/// The named sizes encode *intent*, not raw detents — call-sites pick the
/// behaviour they want and the token maps it onto the right `PresentationDetent`
/// set, so a future detent-policy change is a one-line edit here.
public enum HLSheetSize: Equatable, Sendable {
    /// Opens at half-height, draggable to full. Use for quick pickers and
    /// short content where the underlying screen should stay visible behind
    /// (capture confirms, score detail, history detail).
    case standard

    /// Half-height only — single detent, not draggable to full. Use for
    /// compact pickers that should never grow.
    ///
    /// v0.14.1 W-CAPTURE-GAP note: the central Erfassen picker no longer uses
    /// this — a fixed `.medium` left a dead gap below its 3–4 short rows, so
    /// `CapturePickerSheet` now self-sizes to a content-fitted `.height`
    /// detent. Prefer that pattern for any other short, content-driven picker.
    case compact

    /// Full-height only — single detent. Use for long forms / editors where
    /// keyboard avoidance + multi-field layout would be cramped at `.medium`
    /// (medication editors, target editor, coach conversation). This is the
    /// app's default and matches Apple's own Health "Add Data" sheet.
    case form

    /// As tall as its content — single detent at the height the caller
    /// measured. Use for a short list of choices whose number varies, where
    /// half the screen would leave a gap below the last row. The caller owns
    /// the measuring and passes an estimate until the first measure lands.
    case fitted(height: CGFloat)

    /// A form that is full height on the phone, like ``form``, and as tall
    /// as its content in a form sheet, so a short form leaves no empty room
    /// below its last section. `height` is what the form measured, bar
    /// included; `nil` until it has, and then it stands at the form size.
    case formMeasured(height: CGFloat?)

    /// A `fullScreenCover`. It takes the whole window in every size class,
    /// so the presentation gets neither detents nor a sizing.
    case cover

    /// The presentation detents this size resolves to in a compact window.
    public var detents: Set<PresentationDetent> {
        switch self {
        case .standard: [.medium, .large]
        case .compact: [.medium]
        case .form, .formMeasured, .cover: [.large]
        case let .fitted(height): [.height(height)]
        }
    }
}

/// How a sheet of a given ``HLSheetSize`` is presented in the size class of
/// the window that presents it.
///
/// The system decides between a bottom sheet and a form sheet by that size
/// class; the scaffold follows it. A compact window keeps the detents and the
/// grabber of today. A regular window (iPad, the open Duo) gets a form sheet:
/// long forms at the system's form size, short pickers fitted to their
/// height, since detents mean nothing there.
public enum HLSheetSizing: Equatable, Sendable {
    /// Bottom sheet with the size's detents and a visible grabber.
    case detents(Set<PresentationDetent>)
    /// Form sheet at the system's form size.
    case form
    /// Form sheet as tall as its content, at the form width.
    case formFitted
    /// Form sheet at the system's own form size, centred, one detent. For a
    /// sheet that grows in a compact window: neither the page height nor a
    /// half detent, which set the mood check-in low in the window.
    case formSystem
    /// Form sheet at the form width and a height the content measured
    /// itself, bar included. A fitted form sheet leaves the bar out of a
    /// scrolling content's height and cuts off the last row.
    case formHeight(CGFloat)
    /// Nothing set: a full screen cover.
    case unset

    /// The presentation of `size` in a window of `sizeClass`. A window that
    /// reports no size class is treated as compact, as it was before.
    ///
    /// A sheet that `grows` (it moves between its detents itself, like the
    /// mood check-in once an entry is made) is a form sheet at the system's
    /// form size in a regular window, from the start: no detent change there.
    public static func resolve(
        _ size: HLSheetSize,
        sizeClass: UserInterfaceSizeClass?,
        grows: Bool = false
    ) -> HLSheetSizing {
        if size == .cover { return .unset }
        guard sizeClass == .regular else { return .detents(size.detents) }
        // The annotate panel fits the system's form sheet; more scrolls.
        if grows { return .formSystem }
        switch size {
        case .form: return .form
        case .standard, .compact: return .formFitted
        case let .fitted(height): return .formHeight(height)
        case let .formMeasured(height): return height.map { .formHeight($0) } ?? .form
        case .cover: return .unset
        }
    }

    /// The one detent of a form sheet whose height the content measured. A
    /// form sheet still honours a `.large` detent: given the bottom sheet's
    /// detents it stood at full form height whatever was measured.
    public var formDetent: PresentationDetent? {
        switch self {
        case let .formHeight(height): .height(height)
        // A form sheet given a half detent stood at half height, low in the window.
        case .formSystem: .large
        default: nil
        }
    }

    /// The detents to give the presentation: the measured one for a
    /// measured form sheet, the size's own otherwise.
    public func detents(for size: HLSheetSize) -> Set<PresentationDetent> {
        formDetent.map { [$0] } ?? size.detents
    }

    /// Whether the grabber shows. Only a bottom sheet can be dragged.
    public var showsDragIndicator: Bool {
        if case .detents = self { return true }
        return false
    }
}

public extension EnvironmentValues {
    /// The horizontal size class of the window, set once at its root.
    /// A sheet's own environment reports the size class of the sheet, not of
    /// the window that presents it, so the sheet presentation reads this.
    @Entry var hlPresentingSizeClass: UserInterfaceSizeClass?

    /// Whether the sheet this view stands in can be dragged away (a bottom
    /// sheet with a grabber). A form sheet cannot, so a sheet without a bar
    /// of its own shows a close button there.
    @Entry var hlSheetIsDraggable: Bool = true

    /// Whether this view stands in a sheet. A list there tells the side a
    /// system bar covers from its safe area, not from where it stands in the
    /// window: a sheet never starts at the window's edge.
    @Entry var hlPresentedInSheet: Bool = false
}

/// The system sizing a ``HLSheetSizing`` stands for, as one type. The value
/// changes with the size class while the modifier chain stays the same, so a
/// sheet that is open while the window changes class (a fold, a resize)
/// keeps its content and its input.
struct HLSheetPresentationSizing: PresentationSizing {
    let sizing: HLSheetSizing

    /// The size of a long form sheet: the form's width, the taller of the
    /// form's and the page's height.
    nonisolated static func tallForm(form: ProposedViewSize, page: ProposedViewSize) -> ProposedViewSize {
        let height: CGFloat? = switch (form.height, page.height) {
        case let (form?, page?): max(form, page)
        case let (form, page): form ?? page
        }
        return ProposedViewSize(width: form.width, height: height)
    }

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let form = FormPresentationSizing.form.proposedSize(for: root, context: context)
        return switch sizing {
        case .form:
            // A long form at the form width and the page height: at the
            // system's form height a 13-inch iPad cut the medication and
            // profile forms off at 60 % with the rest of the screen empty.
            Self.tallForm(form: form, page: PagePresentationSizing.page.proposedSize(for: root, context: context))
        case .formFitted:
            FormPresentationSizing.form.fitted(horizontal: false, vertical: true).proposedSize(for: root, context: context)
        case .formSystem:
            form
        case let .formHeight(height):
            // Never taller than the system's form sheet.
            ProposedViewSize(width: form.width, height: min(height, form.height ?? height))
        case .detents, .unset:
            AutomaticPresentationSizing.automatic.proposedSize(for: root, context: context)
        }
    }
}

// MARK: - Sheet behavior tokens

public enum HLSheet {
    /// v0.4.0 decision: present at .large only. Prevents the
    /// medium→keyboard-promote-to-large glitch reported by User-Report #4.
    /// Mirrors `HLSheetSize.form` — kept as a named alias for call-sites and
    /// the regression guard that anchor against the raw detent set.
    public static let detents: Set<PresentationDetent> = HLSheetSize.form.detents
    /// Drag-indicator visibility default for canonical sheets.
    public static let dragIndicator: Visibility = .visible
    /// Recommended focus delay so focus fires AFTER the sheet has settled.
    /// 600ms covers Apple's spring-settle window on real ProMotion devices: on
    /// an iPhone 16 Pro the spring takes ~400-550ms, and focus fired earlier
    /// makes the keyboard rise snap the remaining travel ("half-open → pause →
    /// full-with-keyboard"). 600ms is imperceptible to the user.
    public static let focusDelay: Duration = .milliseconds(600)
    /// Room for a sheet's bar above content that measured itself, with a
    /// touch to spare: too little would cut the last row into a scroll.
    public static let barAllowance: CGFloat = 52

    /// The height of a form sheet around a scrolling form: its rows, the
    /// inset above them (the bar and the page's top margin) and the page's
    /// bottom margin. The bottom inset is not read: it holds the keyboard,
    /// and a sheet that grew with it would move the keyboard's overlap and
    /// rock. Where the top inset does not hold the bar, the bar allowance
    /// stands in for it.
    public static func formHeight(contentHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        let top = max(topInset, HLLayout.pageTop + barAllowance)
        return (contentHeight + top + HLLayout.pageBottom).rounded(.up)
    }

    /// Whether a sheet puts the keyboard up as it opens. A bottom sheet does.
    /// In a form sheet the iPad's number pad pops over the fields above the
    /// focused one, the bar and the labels included, so there the field waits
    /// for a tap.
    public static func focusesOnOpen(presentingSizeClass: UserInterfaceSizeClass?) -> Bool {
        HLSheetSizing.resolve(.form, sizeClass: presentingSizeClass).showsDragIndicator
    }
}

public extension View {
    /// Focuses `focus` once the sheet has settled (``HLSheet/focusDelay``),
    /// in a bottom sheet only (``HLSheet/focusesOnOpen(presentingSizeClass:)``).
    func hlFocusOnSettle(_ focus: FocusState<Bool>.Binding) -> some View {
        modifier(HLFocusOnSettle(focus: focus))
    }
}

private struct HLFocusOnSettle: ViewModifier {
    let focus: FocusState<Bool>.Binding

    @Environment(\.hlPresentingSizeClass) private var presentingSizeClass
    @Environment(\.horizontalSizeClass) private var ownSizeClass

    func body(content: Content) -> some View {
        content.task {
            guard HLSheet.focusesOnOpen(presentingSizeClass: presentingSizeClass ?? ownSizeClass) else { return }
            try? await Task.sleep(for: HLSheet.focusDelay)
            guard !Task.isCancelled else { return }
            focus.wrappedValue = true
        }
    }
}

public extension View {
    /// Applies the canonical sheet presentation: the detents for `size` plus a
    /// visible drag indicator. Route every user-dismissible sheet through this
    /// so detents + the dismiss affordance stay consistent app-wide.
    ///
    /// Background / corner-radius treatment stays orthogonal — sites that need
    /// the opaque Home-Compliance platter keep their own
    /// `.presentationBackground(HLColor.surface)`.
    ///
    /// - Parameter size: the intent-named sheet size; defaults to `.form`
    ///   (full-height) to match the app's heavy-form default.
    ///
    /// In a regular window the sheet becomes a form sheet instead
    /// (``HLSheetSizing``).
    func hlSheetPresentation(_ size: HLSheetSize = .form) -> some View {
        modifier(HLSheetPresentationModifier(size: size, selection: nil))
    }

    /// The same presentation for a sheet that moves between the detents of
    /// `size` on its own, for instance one that grows once an entry is made.
    /// `selection` holds the detent the sheet stands at and must be one of
    /// `size.detents`. The detents only move in a compact window.
    func hlSheetPresentation(_ size: HLSheetSize, selection: Binding<PresentationDetent>) -> some View {
        modifier(HLSheetPresentationModifier(size: size, selection: selection))
    }
}

/// Applies the ``HLSheetSizing`` for the presenting window. Only values change
/// with the size class, never the views, so the sheet's state survives a
/// change of class. Detents are given in every class; a form sheet ignores
/// them.
private struct HLSheetPresentationModifier: ViewModifier {
    let size: HLSheetSize
    let selection: Binding<PresentationDetent>?

    @Environment(\.hlPresentingSizeClass) private var presentingSizeClass
    @Environment(\.horizontalSizeClass) private var ownSizeClass

    private var sizing: HLSheetSizing {
        HLSheetSizing.resolve(size, sizeClass: presentingSizeClass ?? ownSizeClass, grows: selection != nil)
    }

    /// The sheet's own detent choice where it moves between detents (a
    /// bottom sheet); a measured form sheet stands at its one detent.
    private func detentSelection(_ selection: Binding<PresentationDetent>) -> Binding<PresentationDetent> {
        guard let fixed = sizing.formDetent else { return selection }
        return Binding(get: { fixed }, set: { _ in })
    }

    /// The grabber only where the sheet can be dragged. A form sheet given
    /// detents would otherwise show one on `.automatic`.
    private var dragIndicator: Visibility {
        sizing.showsDragIndicator ? HLSheet.dragIndicator : .hidden
    }

    func body(content: Content) -> some View {
        if size == .cover {
            content
        } else if let selection {
            content
                .environment(\.hlSheetIsDraggable, sizing.showsDragIndicator)
                .environment(\.hlPresentedInSheet, true)
                .presentationDetents(sizing.detents(for: size), selection: detentSelection(selection))
                .presentationDragIndicator(dragIndicator)
                .presentationSizing(HLSheetPresentationSizing(sizing: sizing))
        } else {
            content
                .environment(\.hlSheetIsDraggable, sizing.showsDragIndicator)
                .environment(\.hlPresentedInSheet, true)
                .presentationDetents(sizing.detents(for: size))
                .presentationDragIndicator(dragIndicator)
                .presentationSizing(HLSheetPresentationSizing(sizing: sizing))
        }
    }
}

public extension View {
    /// The head of every sheet for a sheet that brings its own
    /// `NavigationStack` instead of ``HLSheetScaffold`` (the mood check-in,
    /// which owns its growing detent): the close button leading and `title`
    /// inline in the bar, in every size class.
    func hlSheetHead(title: LocalizedStringKey) -> some View {
        modifier(HLSheetHead(title: title))
    }
}

private struct HLSheetHead: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel(HLSheetBar.closeLabel(for: .closeOnly))
                        .accessibilityIdentifier(HLSheetBar.closeIdentifier)
                }
            }
    }
}

public extension HLSheetSize {
    /// A short sheet as tall as its scrolling content plus the bar, so a few
    /// lines of text never open a full-height sheet with empty room below.
    /// Until the content measured itself (`0`) it stands at `fallback`. A
    /// content taller than the window is held at the large height by the
    /// system and scrolls.
    static func content(measuredHeight: CGFloat, fallback: HLSheetSize = .standard) -> HLSheetSize {
        guard measuredHeight > 0 else { return fallback }
        return .fitted(height: (measuredHeight + HLSheet.barAllowance).rounded(.up))
    }
}

public extension View {
    /// Reports the height of the scroll content below, for
    /// ``HLSheetSize/content(measuredHeight:fallback:)``. It reads the content
    /// size, not the frame, so a sheet that grows does not feed back into
    /// the value it was sized from.
    func hlSheetContentHeight(_ height: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { _, newHeight in
            height.wrappedValue = newHeight
        }
    }
}
