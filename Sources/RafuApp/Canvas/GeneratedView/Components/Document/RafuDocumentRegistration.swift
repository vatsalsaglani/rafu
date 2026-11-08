import JSONRenderCore
import JSONRenderSwiftUI

// Catalog entries for the document components, as free functions.
//
// Swift 6.4 crashes in SILGen when a static method reference (or a closure
// literal) with an `inout` parameter and a typed throw is converted to
// `@Sendable (inout Catalog) throws(CatalogError) -> Void`. A free function
// reference converts cleanly, so `RafuCatalog.documentEntries` lists these.

nonisolated func registerRafuDocMarkdown(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocMarkdown.self)
}

nonisolated func registerRafuDocMermaid(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocMermaid.self)
}

nonisolated func registerRafuDocCode(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocCode.self)
}

nonisolated func registerRafuDocCallout(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocCallout.self)
}

nonisolated func registerRafuDocChecklist(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocChecklist.self)
}

nonisolated func registerRafuDocQuestions(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocQuestions.self)
}

nonisolated func registerRafuDocFileTree(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocFileTree.self)
}

nonisolated func registerRafuDocFigure(_ catalog: inout Catalog) throws(CatalogError) {
    try catalog.register(RafuDocFigure.self)
}
