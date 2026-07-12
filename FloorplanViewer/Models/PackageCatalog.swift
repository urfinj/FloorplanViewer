import Foundation

/// The fixed set of projects seeded into the database, and the package URL for each.
nonisolated enum PackageCatalog {
    /// Official host for the sample packages.
    static let baseURL = "https://files.daerogroup.com"

    struct Spec: Sendable, Equatable {
        let id: String
        let name: String
        let url: String
    }

    static let seed: [Spec] = [
        Spec(id: "project-1", name: "Project 1", url: "\(baseURL)/samples/sample-1.tar.gz"),
        Spec(id: "project-2", name: "Project 2", url: "\(baseURL)/samples/sample-2.tar.gz"),
        Spec(id: "project-3", name: "Project 3", url: "\(baseURL)/samples/sample-3.tar.gz")
    ]
}
