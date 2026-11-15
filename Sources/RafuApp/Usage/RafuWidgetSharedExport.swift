// The pure usage types (`UsageWindow`, `UsagePace`, `UsageDisplayMode`,
// `UsageRingPalette`, `UsageRingLevel`, `UsageWindowPresentation`, the ring
// cluster and its builder) live in `RafuWidgetShared` so the WidgetKit
// extension draws with the same rules. Re-exporting the module keeps every
// `RafuApp` file, and every test that imports `RafuApp`, compiling against
// the same names without its own import.
@_exported import RafuWidgetShared
